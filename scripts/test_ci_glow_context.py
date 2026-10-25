from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import ci_builtin_blur_preheat as common
import ci_glow_context as glow
from test_ci_builtin_blur_preheat import records, workflow_job


ROOT = Path(__file__).resolve().parents[1]


class GlowContextTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.original.cleanup)
        cls.root = Path(cls.original.name)
        for name in glow.CHANGED | glow.DEPENDENCIES:
            path = cls.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / name).read_bytes())
        fixture = (ROOT / "scripts/fixtures/glow-context-original-compositor.swift").read_bytes()
        if hashlib.sha256(fixture).hexdigest() != "e5c89675d215ab4fff07f6c519a50434565a975fa477d050110074ee3eec81da":
            raise AssertionError("Historical producer compositor fixture changed")
        (cls.root / glow.COMPOSITOR).write_bytes(fixture)

    def test_historical_generator_rejects_replaced_product_context(self):
        with self.assertRaisesRegex(ValueError, "boundary changed or is ambiguous"):
            glow.generated_source(ROOT)

    def test_generated_functions_preserve_original_gpu_render_body_and_production_context(self):
        generated, receipt = glow.generated_source(self.root)
        source = (self.root/glow.TEST_SOURCE).read_text()
        original = source[source.index("    private func spot() throws -> CIImage {"):source.index("    @Test func neutralIsNoOp() throws {")]
        self.assertIn(original.replace("#require(", "required("), generated)
        self.assertEqual(receipt["fixtureFunctionsSHA256"], hashlib.sha256(original.encode()).hexdigest())
        context_source = (self.root/glow.COMPOSITOR).read_text()
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
                (root/name).write_bytes((self.root/name).read_bytes())
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
        generated, _ = glow.generated_source(self.root)
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

    def test_shader_rebuild_reuses_executable_and_calls_shared_product_compiler(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);metadata=root/"metadata";metadata.mkdir()
            (metadata/"binding.json").write_text("{}")
            with zipfile.ZipFile(metadata/"glow-context-products.zip","w") as archive:
                for name in glow.ORIGINAL_BUNDLE_FILES:archive.writestr(name,b"original")
                for name in ("Contents/Info.plist","Contents/Resources/DWARF/NGVBuiltinBlur",
                             "Contents/Resources/Relocations/aarch64/NGVBuiltinBlur.yml"):
                    archive.writestr(glow.APP+".dSYM/"+name,b"symbols")
            binding=dict(harnessSHA="a"*40,generatedSHA256=glow.GLOW_GENERATED_SHA,originalSDK=[1,26<<16,27<<16],
                originalGlow=dict(files={glow.BINARY:glow.GLOW_BINARY_SHA}))
            def command(args):
                return "Xcode 27.0\nBuild version 27A266a" if args[0]=="xcodebuild" else "arm64" if args[0]=="uname" else ""
            def compile(args,**kwargs):
                if args[0]==str((ROOT/glow.METAL_SCRIPT).resolve()):
                    self.assertEqual(args[1],str((ROOT/"Metal").resolve()))
                    for name in glow.SHADER_FILES:
                        (root/"products"/name).write_bytes(b"MTLBair64_v28-apple-macosx26.0.0\0")
                elif "--sign" in args:
                    self.assertEqual((root/"products"/glow.BINARY).read_bytes(),b"original")
                    self.assertEqual((root/"products"/glow.INFO).read_bytes(),b"original")
                    self.assertEqual([p.name for p in (root/"products"/glow.APP/"Contents/MacOS").iterdir()],["NGVBuiltinBlur"])
                    self.assertEqual((root/"products"/(glow.APP+".dSYM/Contents/Resources/DWARF/NGVBuiltinBlur")).read_bytes(),b"symbols")
                    seal=root/"products"/glow.SEAL;seal.parent.mkdir();seal.write_bytes(b"seal")
                    (root/"products"/glow.BINARY).write_bytes(b"resigned")
                else:self.assertTrue((root/"products"/glow.SEAL).exists())
            def toolchain(folder,sdk):
                self.assertEqual(sdk,binding["originalSDK"][2]);(folder/"toolchain.json").write_text("{}");return {}
            identity=dict(uuid=glow.GLOW_UUID,unsignedSHA256="same-code",buildVersion=binding["originalSDK"])
            with patch.object(glow,"bound",return_value=binding),patch.object(glow,"command",side_effect=command), \
                patch.object(glow.subprocess,"run",side_effect=compile) as calls, \
                patch.object(glow,"unsigned_code_identity",return_value=identity) as identities, \
                patch.object(glow,"toolchain_identity",side_effect=toolchain):
                glow.compile_products(root/"products",metadata)
            args=[c.args[0] for c in calls.call_args_list]
            self.assertEqual(len(args),4)
            self.assertEqual(args[0][0],str((ROOT/glow.METAL_SCRIPT).resolve()))
            self.assertFalse(any("swiftc" in command for command in args))
            self.assertEqual(identities.call_count,2)
            self.assertEqual(args[1][:4],["codesign","--force","--sign","-"])
            self.assertEqual(args[2][:3],["codesign","--verify","--strict"])
            proof=json.loads((root/"products/binary.json").read_text())
            self.assertEqual(set(proof["files"]),glow.BUNDLE_FILES)
            self.assertEqual(set(proof["shaderTargets"]),glow.SHADER_FILES)
            self.assertEqual(proof["files"][glow.BINARY],hashlib.sha256(b"resigned").hexdigest())
            self.assertEqual(proof["executableSourceSHA"],glow.GLOW_BUILD_SOURCE)
            self.assertEqual(proof["unsignedCodeIdentity"],identity)

    def test_shader_target_gate_rejects_newer_missing_and_mixed_targets(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            for name in glow.SHADER_FILES:
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
                path.write_bytes(b"MTLBair64_v28-apple-macosx26.0.0\0")
            self.assertEqual(set(glow.shader_targets(root)),glow.SHADER_FILES)
            for raw in (b"MTLBair64_v29-apple-macosx27.0.0",b"MTLBno target",b"MTLBair64_v28-apple-macosx26.0.0\0air64_v29-apple-macosx27.0.0"):
                (root/glow.LIBRARY).write_bytes(raw)
                with self.assertRaises(ValueError):glow.shader_targets(root)

    def test_unsigned_identity_checks_uuid_and_hashes_signature_removed_copy(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);binary=root/"binary";binary.write_bytes(b"signed")
            def command(args):
                if args[0]=="dwarfdump":return "UUID: "+glow.GLOW_UUID+" (arm64) "+str(binary)
                self.assertEqual(args[:2],["codesign","--remove-signature"])
                Path(args[2]).write_bytes(b"unsigned-code");return ""
            with patch.object(glow,"command",side_effect=command),patch.object(glow,"build_version",return_value=[1,26<<16,27<<16]):
                identity=glow.unsigned_code_identity(binary,root/"copy")
                self.assertEqual(identity["unsignedSHA256"],hashlib.sha256(b"unsigned-code").hexdigest())
                self.assertEqual(binary.read_bytes(),b"signed")
            with patch.object(glow,"command",return_value="UUID: foreign (arm64) binary"),self.assertRaises(ValueError):
                glow.unsigned_code_identity(binary,root/"bad")

    def test_calibration_log_rejects_loader_error_foreign_process_and_capture_failure(self):
        child=dict(pid=42,hostExecutable="/owned/app",launchEarliest=1000,exitObserved=1031)
        event=dict(processID=42,processImagePath="/owned/app",processImageUUID=glow.GLOW_UUID,eventMessage="kernel loaded")
        for change in (None,"kernel","pid","command"):
            with tempfile.TemporaryDirectory() as temp:
                root=Path(temp);value=dict(event)
                if change=="kernel":value["eventMessage"]="Cannot initialize kernel with given library data."
                if change=="pid":value["processID"]=43
                def run(args,**kwargs):
                    self.assertIn("42",args);self.assertIn("--predicate",args)
                    kwargs["stdout"].write(json.dumps([value]).encode())
                    return type("Result",(),dict(returncode=1 if change=="command" else 0))()
                with patch.object(glow.subprocess,"run",side_effect=run):
                    if change is None:glow.coreimage_log(root,child)
                    else:
                        with self.assertRaises(ValueError):glow.coreimage_log(root,child)
                self.assertEqual(json.loads((root/"coreimage.json").read_text()),[value])
                self.assertTrue((root/"coreimage-receipt.json").exists())

    def test_reused_executable_requires_successful_exact_build_inside_failed_run(self):
        run=dict(id=glow.GLOW_BUILD_RUN,run_attempt=1,head_sha=glow.GLOW_BUILD_SOURCE,
            repository=dict(full_name="iret77/nexgenvideo"),event="workflow_dispatch",actor=dict(login="iret77"),
            head_branch="iret77/activity-approval-layout",path=".github/workflows/diagnostic-acceptance.yml",
            status="completed",conclusion="failure")
        job=dict(id=121305704232,run_id=glow.GLOW_BUILD_RUN,run_attempt=1,head_sha=glow.GLOW_BUILD_SOURCE,
            name="ci-glow-context-build",status="completed",conclusion="success")
        for changed in (None,"head_sha","run_attempt","conclusion"):
            with tempfile.TemporaryDirectory() as temp:
                value=dict(job)
                if changed:value[changed]=2 if changed=="run_attempt" else "wrong"
                with patch.object(glow,"api",side_effect=[run,value]),patch.object(glow,"download") as download, \
                    patch.object(glow,"original_glow",return_value={"verified":True}):
                    if changed:
                        with self.assertRaises(ValueError):glow.bind_original_glow(Path(temp))
                        download.assert_not_called()
                    else:
                        self.assertEqual(glow.bind_original_glow(Path(temp)),{"verified":True})
                        self.assertEqual(download.call_args.kwargs,dict(run_id=glow.GLOW_BUILD_RUN,source_sha=glow.GLOW_BUILD_SOURCE))

    def test_shader_build_correction_rejects_any_additional_product_build_change(self):
        corrected=(self.root/glow.METAL_SCRIPT).read_text()
        original=corrected.replace(" -mmacosx-version-min=26.0", "")
        with tempfile.TemporaryDirectory() as temp, patch.object(glow,"command",return_value=original):
            root=Path(temp);path=root/glow.METAL_SCRIPT;path.parent.mkdir(parents=True)
            path.write_text(corrected)
            receipt=glow.require_shader_floor_correction(root)
            self.assertEqual(receipt["originalSHA256"],hashlib.sha256(original.encode()).hexdigest())
            self.assertEqual(receipt["correctedSHA256"],glow.digest(path))
            for content in (original,corrected.replace("26.0","27.0"),corrected+"\necho changed\n"):
                path.write_text(content)
                with self.assertRaises(ValueError):glow.require_shader_floor_correction(root)

    def test_toolchain_allows_equivalent_environment_but_rejects_effective_drift(self):
        developer="/Applications/Xcode_27.app/Contents/Developer"
        compiler=developer+"/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        sdk=developer+"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.sdk"
        value=dict(environment=dict(SDKROOT=sdk,TOOLCHAINS="com.apple.dt.toolchain.XcodeDefault",MACOSX_DEPLOYMENT_TARGET="26.0"),
            xcrun="/usr/bin/xcrun",developer=developer,swiftc=compiler,selectedSDK=sdk,defaultSDK=sdk,sdkVersion="27.0",
            metal="/private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.1.266.1.fixture/Metal.xctoolchain/usr/bin/metal",
            metalVersion="Apple metal version 32023.921 (metalfe-32023.921.6)")
        value["metallib"]=str(Path(value["metal"]).with_name("air-lld"))
        glow.validate_toolchain(value,27<<16)
        for key,bad in (("xcrun","/other/xcrun"),("swiftc","/other/swiftc"),("selectedSDK","/other/SDK"),
                ("defaultSDK","/other/SDK"),("sdkVersion","26.0"),("metalVersion","other"),("metal","/other/metal"),
                ("metallib","/other/air-lld")):
            with self.subTest(key=key),self.assertRaises(ValueError):glow.validate_toolchain(dict(value,**{key:bad}),27<<16)
        for key,bad in (("MACOSX_DEPLOYMENT_TARGET","27.0"),("MACOSX_DEPLOYMENT_TARGET","garbage"),
                ("NGV_XCRUN","/other/xcrun"),("SWIFT_EXEC","/other/swiftc")):
            changed=deepcopy(value);changed["environment"][key]=bad
            with self.subTest(envKey=key,bad=bad),self.assertRaises(ValueError):glow.validate_toolchain(changed,27<<16)

    def test_toolchain_records_actual_selection_before_rejecting_it(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            def command(args):
                if args==["xcode-select","-p"]:return "/Applications/Xcode_27.app/Contents/Developer"
                if args==["xcrun","--show-sdk-version"]:return "27.0"
                return "/wrong/selection"
            with patch.dict(os.environ,SDKROOT="/wrong/SDK",TOOLCHAINS="custom"), \
                    patch.object(glow,"command",side_effect=command),patch.object(glow.shutil,"which",return_value="/usr/bin/xcrun"):
                with self.assertRaises(ValueError):glow.toolchain_identity(root,27<<16)
            value=json.loads((root/"toolchain.json").read_text())
            self.assertEqual(value["environment"]["SDKROOT"],"/wrong/SDK")
            self.assertEqual(value["environment"]["TOOLCHAINS"],"custom")
            self.assertEqual(value["swiftc"],"/wrong/selection")
            self.assertFalse(value["errors"])

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
                (root/name).write_bytes((self.root/name).read_bytes())
            contract=glow.compilation_contract(root)
            self.assertIn("6",contract["swiftFlags"])
            self.assertEqual(contract["target"],"arm64-apple-macos26.0")
            for name,old,new in ((glow.PACKAGE,"swift-tools-version: 6.2","swift-tools-version: 5.9"),
                (glow.PACKAGE,"platforms: [.macOS(.v26)]","platforms: [.macOS(.v27)]"),
                (glow.PACKAGE,"targets: [","swiftSettings: [], targets: ["),
                (glow.METAL_SCRIPT,"-fcikernel","-ffast-math"),
                (glow.METAL_SCRIPT,"-mmacosx-version-min=26.0","-mmacosx-version-min=27.0"),
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
                (root/name).parent.mkdir(parents=True,exist_ok=True);(root/name).write_bytes((self.root/name).read_bytes())
            generated,fragments=glow.generated_source(root)
            (metadata/"main.swift").write_text(generated)
            original_shader=(self.root/glow.METAL_SCRIPT).read_text().replace(" -mmacosx-version-min=26.0", "")
            with patch.object(glow,"command",return_value=original_shader):
                shader_correction=glow.require_shader_floor_correction(root)
            binding=dict(harnessSHA="a"*40,baseSHA=glow.BASE,workflowRun="123",attempt="1",
                hashes={n:glow.digest(root/n) for n in glow.CHANGED|glow.DEPENDENCIES},fragments=fragments,
                generatedSHA256=glow.digest(metadata/"main.swift"),compilation=glow.compilation_contract(root),
                appFailureSource=glow.APP_FAILURE_SOURCE,appProductInputsUnchanged=sorted(glow.UNCHANGED_PRODUCT_INPUTS),
                shaderBuildCorrection=shader_correction,originalGlow={},executableSourceSHA=glow.GLOW_BUILD_SOURCE)
            (metadata/"binding.json").write_text(json.dumps(binding))
            env=dict(REPLAY_KIND=glow.MODE,GITHUB_SHA="a"*40,GITHUB_RUN_ID="123",GITHUB_RUN_ATTEMPT="1")
            real_digest=glow.digest
            def digest(path):return real_digest(path if path.is_absolute() else root/path)
            def command(args):
                if args != ["git","rev-parse","HEAD"]:raise AssertionError("Runtime checkout has no historical objects")
                return "a"*40
            with patch.dict(os.environ,env),patch.object(glow.Path,"cwd",return_value=root), \
                    patch.object(glow,"digest",side_effect=digest), \
                    patch.object(glow,"command",side_effect=command), \
                    patch.object(glow,"original_glow",return_value={}):
                self.assertEqual(glow.bound(metadata),binding)
                tampered=deepcopy(binding);tampered["shaderBuildCorrection"]["originalSHA256"]="foreign"
                (metadata/"binding.json").write_text(json.dumps(tampered))
                with self.assertRaises(ValueError):glow.bound(metadata)
                (metadata/"binding.json").write_text(json.dumps(binding))
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
        source=(self.root/glow.TEMPLATE).read_text()
        self.assertIn('guard [4, 5].contains(CommandLine.arguments.count)',source)
        self.assertIn('CommandLine.arguments[3] == "normal"',source)
        self.assertIn('guard calibration || CommandLine.arguments[2] == "measured"',source)
        self.assertIn('guard ["separate", "shared"].contains(arm), !calibration || arm == "separate"',source)
        self.assertIn('rgb.0.isFinite, rgb.1.isFinite, rgb.2.isFinite, rgb.0 > 0, rgb.0 <= 1',source)

    def test_runtime_checks_bundle_before_launch_and_counts_bad_resource_receipt_as_invalid(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);products=root/"products";metadata=root/"metadata";metadata.mkdir()
            (metadata/"binding.json").write_text("{}")
            for name in glow.BUNDLE_FILES:
                path=products/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(name.encode())
            binding=dict(harnessSHA="a"*40,generatedSHA256="generated",originalSDK=[1,26<<16,27<<16],workflowRun="123",attempt="1")
            proof=dict(harnessSHA=binding["harnessSHA"],generatedSHA256="generated",bindingSHA256=glow.digest(metadata/"binding.json"),
                files={name:glow.digest(products/name) for name in glow.BUNDLE_FILES},executableSourceSHA=glow.GLOW_BUILD_SOURCE,
                originalExecutableSHA256=glow.GLOW_BINARY_SHA,unsignedCodeIdentity=dict(uuid=glow.GLOW_UUID),shaderTargets={})
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
                patch.object(glow,"coreimage_log"),patch.object(glow,"shader_targets",return_value={}), \
                patch.object(glow,"prepare_post_mortem",return_value=dict(hostUUID="uuid")),patch.object(glow,"launch",side_effect=launch), \
                patch.object(glow,"collect_reports",return_value={}),patch.object(glow,"summarize",side_effect=summary),patch("builtins.print"):
                self.assertEqual(glow.execute(root/"runtime",metadata,products),1)
            self.assertEqual(events[:4],["platform","signature","calibration","child"])
            self.assertEqual(json.loads((root/"runtime/result.json").read_text())["outcome"],"invalid")

    def test_workflow_preserves_exact_source_build_runtime_order(self):
        text=(self.root/".github/workflows/diagnostic-acceptance.yml").read_text()
        build=workflow_job(text,"ci-glow-context-build")
        runtime=workflow_job(text,"ci-glow-context")
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
