from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import ci_builtin_blur_preheat as common
import ci_glow_context as glow
from test_ci_builtin_blur_preheat import records


ROOT = Path(__file__).resolve().parents[1]


class GlowContextTests(unittest.TestCase):
    def test_generated_functions_preserve_original_gpu_render_body_and_production_context(self):
        generated, receipt = glow.generated_source(ROOT)
        source = (ROOT/glow.TEST_SOURCE).read_text()
        original = source[source.index("    private func spot() throws -> CIImage {"):source.index("    @Test func neutralIsNoOp() throws {")]
        self.assertIn(original.replace("#require(", "required("), generated)
        self.assertEqual(receipt["fixtureFunctionsSHA256"], hashlib.sha256(original.encode()).hexdigest())
        context_source = (ROOT/glow.COMPOSITOR).read_text()
        context = context_source[context_source.index("    static let ciContext: CIContext = {"):context_source.index("    private let queue =")]
        self.assertIn(context, generated)
        self.assertEqual(receipt["contextInitializerSHA256"], hashlib.sha256(context.encode()).hexdigest())
        self.assertNotIn("#require(", generated)
        self.assertNotIn("@production-", generated)
        self.assertIn("func required(_ condition: Bool", generated)
        self.assertIn("guard condition else", generated)
        self.assertIn("queue.makeCommandBuffer()", generated)
        self.assertIn("command.waitUntilCompleted()", generated)
        self.assertIn("renderTask.waitUntilCompleted()", generated)

    def test_generation_rejects_changed_or_ambiguous_source_boundaries(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in (glow.TEST_SOURCE, glow.COMPOSITOR, glow.TEMPLATE):
                (root/name).parent.mkdir(parents=True, exist_ok=True)
                (root/name).write_bytes((ROOT/name).read_bytes())
            glow.generated_source(root)
            tests = (root/glow.TEST_SOURCE).read_text()
            for changed in (tests.replace("private let n = 48", "private let n = 64"),
                            tests + "\n    private func spot() throws -> CIImage {", tests.replace("private func spot", "private func other")):
                (root/glow.TEST_SOURCE).write_text(changed)
                with self.assertRaises(ValueError): glow.generated_source(root)
            (root/glow.TEST_SOURCE).write_text(tests)
            (root/glow.TEMPLATE).write_text((root/glow.TEMPLATE).read_text().replace("// @production-fixture-functions", "// missing"))
            with self.assertRaises(ValueError): glow.generated_source(root)

    def test_shader_is_actual_product_code_and_never_an_approximation_or_warmup(self):
        generated, _ = glow.generated_source(ROOT)
        self.assertIn("GlowKernel.apply", generated)
        self.assertNotIn('applyingFilter("CIColorMatrix"', generated)
        self.assertNotIn("prepareRender(", generated)
        self.assertNotIn('arm == "warm"', generated)
        self.assertIn("SHA256.hash(data: library)", generated)
        self.assertIn("Bundle.main.resourceURL?.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path", generated)

    def test_successful_producer_rejects_stale_source_attempt_or_failed_job(self):
        run = dict(id=glow.RUN, run_attempt=1, head_sha=glow.BASE,
            path=".github/workflows/diagnostic-acceptance.yml", repository=dict(full_name="iret77/nexgenvideo"),
            event="workflow_dispatch", actor=dict(login="iret77"), head_branch="iret77/activity-approval-layout",
            status="completed", conclusion="success")
        jobs = dict(total_count=3, jobs=[dict(name=name, id=identity, run_id=glow.RUN, run_attempt=1,
            head_sha=glow.BASE, status="completed", conclusion="success") for name, identity in
            (("source",121287224134),("ci-builtin-blur-preheat-build",121287289686),("ci-builtin-blur-preheat",121287456513))])
        self.assertEqual(len(glow.verify_run(run, jobs)), 3)
        for key, value in (("run_attempt",2),("head_sha","other"),("conclusion","failure"),("event","pull_request")):
            with self.subTest(key=key), self.assertRaises(ValueError): glow.verify_run(dict(run, **{key:value}), jobs)
        for key, value in (("run_attempt",2),("head_sha","other"),("conclusion","failure"),("id",1)):
            bad = deepcopy(jobs);bad["jobs"][2][key] = value
            with self.subTest(jobKey=key), self.assertRaises(ValueError): glow.verify_run(run, bad)

    def test_artifact_download_checks_producer_interval_and_exact_bytes(self):
        raw = b"bound archive"
        checksum = hashlib.sha256(raw).hexdigest()
        artifact = dict(id=123, name="original", expired=False, digest="sha256:"+checksum,
            workflow_run=dict(id=glow.RUN, head_sha=glow.BASE), created_at="02", updated_at="03", size_in_bytes=len(raw))
        for change in (None, "expired", "time", "bytes"):
            with tempfile.TemporaryDirectory() as temp:
                value = deepcopy(artifact)
                if change == "expired": value["expired"] = True
                if change == "time": value["created_at"] = "00"
                def download(args, **kwargs): kwargs["stdout"].write(b"wrong" if change == "bytes" else raw)
                with patch.object(glow, "api", return_value=value), patch.object(glow.subprocess, "run", side_effect=download):
                    if change is None:
                        self.assertEqual(glow.download(Path(temp), (123,checksum), "original", dict(started_at="01",completed_at="04")).read_bytes(), raw)
                    else:
                        with self.assertRaises(ValueError): glow.download(Path(temp), (123,checksum), "original", dict(started_at="01",completed_at="04"))

    def test_shared_context_summary_never_requires_or_infers_a_warmup(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(common, "PER_ARM", 2):
            root = Path(temp)
            children = []
            for index, arm in enumerate(("separate","shared","shared","separate")):
                name = f"p{index}"
                records(root/name, 42+index)
                children.append((name, dict(pid=42+index, arm=arm, exitCode=0)))
            result = common.summarize(root, children, {"reports":{}}, [], arms=("separate","shared"))
            self.assertTrue(result["valid"])
            self.assertTrue(result["exposureValid"])
            self.assertEqual(result["outcome"], "inconclusive")
            children[1][1]["exitCode"] = -11
            result = common.summarize(root, children, {"reports":{}}, [], arms=("separate","shared"))
            self.assertEqual(glow.interpretation(result), "inconclusive")
            self.assertEqual(result["counts"]["shared"]["unknownAbnormal"], 1)
            self.assertEqual(result["counts"]["shared"]["abnormalPhases"]["later-rounds"], 1)

    def test_compiler_uses_product_shader_and_original_swift_sources(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp);metadata=root/"metadata";metadata.mkdir()
            (metadata/"binding.json").write_text("{}")
            binding=dict(harnessSHA="a"*40, generatedSHA256="generated", originalSDK=[1,26<<16,27<<16],
                compilation=glow.compilation_contract(ROOT))
            def command(args):
                return "Xcode 27.0\nBuild version 27A266a" if args[0]=="xcodebuild" else "arm64" if args[0]=="uname" else "tool identity"
            def compile(args, **kwargs):
                if args[0] == "xcrun":
                    Path(args[-1]).write_bytes(b"compiled")
                elif "--sign" in args:
                    seal=root/"products"/glow.SEAL
                    seal.parent.mkdir();seal.write_bytes(b"seal")
                    (root/"products"/glow.BINARY).write_bytes(b"signed")
                else:
                    self.assertTrue((root/"products"/glow.SEAL).exists())
            with patch.object(glow, "bound", return_value=binding), patch.object(glow,"command",side_effect=command), \
                    patch.object(glow.subprocess,"run",side_effect=compile) as calls, patch.object(glow,"build_version",return_value=binding["originalSDK"]):
                glow.compile_products(root/"products",metadata)
            args=[c.args[0] for c in calls.call_args_list]
            self.assertEqual(args[0][:5], ["xcrun","metal","-c","-fcikernel",glow.METAL])
            self.assertEqual(args[1][:3], ["xcrun","metallib","-cikernel"])
            self.assertIn(glow.KERNEL,args[2]);self.assertIn(glow.LOADER,args[2])
            proof=json.loads((root/"products/binary.json").read_text())
            self.assertEqual(set(proof["files"]),glow.BUNDLE_FILES)
            self.assertEqual(proof["files"][glow.BINARY],hashlib.sha256(b"signed").hexdigest())
            self.assertEqual(args[3][:4],["codesign","--force","--sign","-"])
            self.assertEqual(args[4][:3],["codesign","--verify","--strict"])

    def test_decision_table_requires_control_faults_and_exposure_before_interpretation(self):
        for valid, exposure, target, abnormal, expected in (
            (False,True,10,0,"invalid"), (True,True,6,0,"inconclusive"),
            (True,True,6,1,"inconclusive"), (True,False,7,1,"inconclusive"),
            (True,True,7,1,"shared-arm-abnormal"), (True,True,7,0,"association-candidate")):
            with self.subTest(valid=valid,exposure=exposure,target=target,abnormal=abnormal):
                self.assertEqual(glow.interpretation(dict(valid=valid,exposureValid=exposure,
                    counts=dict(separate=dict(targetFaults=target),shared=dict(abnormal=abnormal)))),expected)

    def test_compilation_contract_rejects_language_floor_and_shader_staging_drift(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            for name in (glow.PACKAGE,glow.METAL_SCRIPT,"scripts/bundle.sh","scripts/stage_test_runtime.sh"):
                (root/name).parent.mkdir(parents=True,exist_ok=True)
                (root/name).write_bytes((ROOT/name).read_bytes())
            contract=glow.compilation_contract(root)
            self.assertIn("6",contract["swiftFlags"])
            self.assertEqual(contract["target"],"arm64-apple-macos26.0")
            for name,old,new in ((glow.PACKAGE,"swift-tools-version: 6.2","swift-tools-version: 5.9"),
                (glow.PACKAGE,"platforms: [.macOS(.v26)]","platforms: [.macOS(.v27)]"),
                (glow.PACKAGE,"targets: [","swiftSettings: [], targets: ["),
                (glow.METAL_SCRIPT,"-fcikernel","-ffast-math"),
                ("scripts/stage_test_runtime.sh","compile_metal_resources.sh","different.sh")):
                original=(root/name).read_text();(root/name).write_text(original.replace(old,new))
                with self.subTest(name=name,old=old),self.assertRaises(ValueError):glow.compilation_contract(root)
                (root/name).write_text(original)

    def test_resource_receipt_rejects_missing_wrong_bytes_and_changed_shader(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);expected=dict(metallibSHA256="original",bytes=42)
            for value in (None,dict(expected,bytes=41),dict(expected,metallibSHA256="other"),expected):
                if value is not None:(root/"resources.json").write_text(json.dumps(value))
                if value==expected:glow.resource_proof(root,expected)
                else:
                    with self.assertRaises((ValueError,OSError)):glow.resource_proof(root,expected)

    def test_bound_rejects_changed_generated_source_dependency_and_execution(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);metadata=root/"metadata";metadata.mkdir()
            for name in glow.CHANGED|glow.DEPENDENCIES:
                (root/name).parent.mkdir(parents=True,exist_ok=True);(root/name).write_bytes((ROOT/name).read_bytes())
            generated,fragments=glow.generated_source(root)
            (metadata/"main.swift").write_text(generated)
            binding=dict(harnessSHA="a"*40,baseSHA=glow.BASE,workflowRun="123",attempt="1",
                hashes={n:glow.digest(root/n) for n in glow.CHANGED|glow.DEPENDENCIES},fragments=fragments,
                generatedSHA256=glow.digest(metadata/"main.swift"),compilation=glow.compilation_contract(root),
                appFailureSource=glow.APP_FAILURE_SOURCE,appProductInputsUnchanged=sorted(glow.PRODUCT_INPUTS))
            (metadata/"binding.json").write_text(json.dumps(binding))
            env=dict(REPLAY_KIND=glow.MODE,GITHUB_SHA="a"*40,GITHUB_RUN_ID="123",GITHUB_RUN_ATTEMPT="1")
            real_digest=glow.digest
            def digest(path):return real_digest(path if path.is_absolute() else root/path)
            with patch.dict(os.environ,env),patch.object(glow.Path,"cwd",return_value=root), \
                    patch.object(glow,"digest",side_effect=digest),patch.object(glow,"command",return_value="a"*40):
                self.assertEqual(glow.bound(metadata),binding)
                for path in (metadata/"main.swift",root/glow.KERNEL,root/glow.PACKAGE):
                    original=path.read_bytes();path.write_bytes(original+b"\nchanged")
                    with self.subTest(path=path),self.assertRaises(ValueError):glow.bound(metadata)
                    path.write_bytes(original)
                with patch.dict(os.environ,GITHUB_RUN_ATTEMPT="2"),self.assertRaises(ValueError):glow.bound(metadata)

    def test_bind_rejects_unexpected_files_and_changed_original_product_before_download(self):
        env=dict(REPLAY_KIND=glow.MODE,CANDIDATE_RUN=str(glow.RUN),CANDIDATE_SOURCE=glow.BASE,
            CANDIDATE_ARTIFACT=str(glow.RUNTIME[0]),CANDIDATE_DIGEST=glow.RUNTIME[1],GITHUB_SHA="a"*40,
            PRODUCT_SHA="",PRODUCTS_ID="",PRODUCTS_DIGEST="",FAILURE_ID="",FAILURE_DIGEST="")
        for extra,product_changed in ((True,False),(False,True)):
            with tempfile.TemporaryDirectory() as temp:
                def command(args):
                    if args[1]=="rev-parse":return "a"*40
                    if "--name-only" in args:return "\n".join(glow.CHANGED|({"Sources/Unexpected.swift"} if extra else set()))
                    if "--quiet" in args and product_changed:raise ValueError("Original product input changed")
                    return ""
                with patch.dict(os.environ,env),patch.object(glow,"command",side_effect=command),patch.object(glow,"api") as api:
                    with self.assertRaises(ValueError):glow.bind(Path(temp)/"binding")
                    api.assert_not_called()

    def test_swift_cli_rejects_warmup_and_unknown_modes(self):
        source=(ROOT/glow.TEMPLATE).read_text()
        self.assertIn('guard [4, 5].contains(CommandLine.arguments.count)',source)
        self.assertIn('CommandLine.arguments[3] == "normal"',source)
        self.assertIn('guard calibration || CommandLine.arguments[2] == "measured"',source)
        self.assertIn('guard ["separate", "shared"].contains(arm), !calibration || arm == "separate"',source)

    def test_runtime_checks_bundle_before_launch_and_counts_bad_resource_receipt_as_invalid(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);products=root/"products";metadata=root/"metadata";metadata.mkdir()
            (metadata/"binding.json").write_text("{}")
            for name in glow.BUNDLE_FILES:
                path=products/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(name.encode())
            binding=dict(harnessSHA="a"*40,generatedSHA256="generated",originalSDK=[1,26<<16,27<<16],workflowRun="123",attempt="1")
            proof=dict(harnessSHA=binding["harnessSHA"],generatedSHA256="generated",bindingSHA256=glow.digest(metadata/"binding.json"),
                files={name:glow.digest(products/name) for name in glow.BUNDLE_FILES})
            (products/"binary.json").write_text(json.dumps(proof))
            expected=dict(metallibSHA256=proof["files"][glow.LIBRARY],bytes=(products/glow.LIBRARY).stat().st_size)
            events=[]
            def calibration(binary,folder,mode,deadline):
                events.append("calibration");folder.mkdir();(folder/"sample.txt").write_text("sample")
                (folder/"resources.json").write_text(json.dumps(expected))
                return "clean",dict(pid=42,sampleExitCode=0)
            def launch(binary,folder,arm,identity,deadline):
                events.append("child");folder.mkdir()
                value=dict(expected,metallibSHA256="wrong") if folder.name=="process-000" else expected
                (folder/"resources.json").write_text(json.dumps(value))
                return dict(pid=int(folder.name.split("-")[1])+100,arm=arm,exitCode=0)
            def summary(folder,children,reports,invalid,**kwargs):
                self.assertEqual(len(children),800)
                self.assertEqual(len(invalid),1)
                self.assertEqual(invalid[0]["process"],"process-000")
                return dict(valid=not invalid,exposureValid=True,counts=dict(separate=dict(targetFaults=7),shared=dict(abnormal=0)))
            def command(args):
                self.assertEqual(args,["codesign","--verify","--strict",str(products/glow.APP)])
                events.append("signature")
                return ""
            with patch.object(glow,"bound",return_value=binding),patch.object(glow,"build_version",return_value=binding["originalSDK"]), \
                patch.object(glow,"platform",side_effect=lambda _:events.append("platform")),patch.object(glow,"command",side_effect=command), \
                patch.object(glow,"owned_process",side_effect=calibration),patch.object(glow,"sample_proof"), \
                patch.object(glow,"prepare_post_mortem",return_value=dict(hostUUID="uuid")),patch.object(glow,"launch",side_effect=launch), \
                patch.object(glow,"collect_reports",return_value={}),patch.object(glow,"summarize",side_effect=summary),patch("builtins.print"):
                self.assertEqual(glow.execute(root/"runtime",metadata,products),1)
            self.assertEqual(events[:4],["platform","signature","calibration","child"])
            self.assertEqual(json.loads((root/"runtime/result.json").read_text())["outcome"],"invalid")

    def test_workflow_preserves_exact_source_build_runtime_order(self):
        text=(ROOT/".github/workflows/diagnostic-acceptance.yml").read_text()
        build=text.split("  ci-glow-context-build:\n")[1].split("  ci-glow-context:\n")[0]
        runtime=text.split("  ci-glow-context:\n")[1].split("  ci-app-test:\n")[0]
        self.assertIn("needs: source",build)
        self.assertIn("runs-on: macrunner",build)
        self.assertIn("setup-xcode-27",build)
        self.assertIn("needs: ci-glow-context-build",runtime)
        self.assertIn("runs-on: macos-26",runtime)
        self.assertNotIn("setup-xcode-27",runtime)
        self.assertNotIn("continue-on-error",build+runtime)
        self.assertIn("ci_glow_context.py bind",text)


if __name__ == "__main__":
    unittest.main()
