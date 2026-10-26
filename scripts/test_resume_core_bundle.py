import copy
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch
import zipfile

import resume_core_bundle as resume
import test_resume_core_tests as fixtures


ROOT = Path(__file__).resolve().parents[1]
SOURCE, HEAD = "a" * 40, "b" * 40


def write_archive(path, files):
    with zipfile.ZipFile(path, "w") as archive:
        for name, value in files.items():
            archive.writestr(name, json.dumps(value) if isinstance(value, dict) else value)


def full_fixture(root, change=None):
    engine, engine_proof = fixtures.native_events("NexGenEngineTests")
    app, app_proof = fixtures.native_events("NexGenVideoTests")
    host = {"pid": 42, "parentPID": 43, "sourceSHA": SOURCE, "eventRecordCount": 5,
            "hostExecutable": "/Debug/NexGenVideoAppKitTestHost",
            "bundleBinary": "/Debug/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests",
            "getterImagePath": "/Applications/Xcode_27.app/Testing.framework/Testing",
            "entryPointImagePath": "/Applications/Xcode_27.app/Testing.framework/Testing",
            **{k: True for k in ("started", "completed", "abiSucceeded", "mainThread",
                                 "applicationRunningAtStart", "runReturnedAfterCompletion")}}
    suite = {"schema": 1, "sourceSHA": SOURCE, "scope": "all", "configuration": "debug", "filter": "",
             "scratchPath": None, "completed": True, "binPath": "/Debug", "testExecutions": 3,
             "combinedFrameworks": fixtures.framework(2, 2), "phases": [
        {"name": "xctest", "status": "verified-execution", "exitCode": 0, "command": ["swift", "test"],
         "testCaseExecutions": 1, "framework": fixtures.framework(0, 2)},
        {"name": "engine-swift-testing", "status": "verified-execution", "exitCode": 0,
         "command": ["swift", "test"], "events": engine_proof, "framework": fixtures.framework(1, 0)},
        {"name": "app-swift-testing", "status": "verified-execution", "exitCode": 0, "pid": 42,
         "command": ["/Debug/NexGenVideoAppKitTestHost"], "events": app_proof,
         "framework": fixtures.framework(1, 0), "originalHostReceipt": copy.deepcopy(host)}]}
    args = ["python3", "scripts/run_macos_tests.py", "--cache-path", "/cache", "--evidence", "/evidence"]
    capture = {"sourceSHA": SOURCE, "runID": "123", "status": "test-process-exited", "testExitCode": 0,
               "effectiveExitCode": 0, "command": args, "actualCommand": args[:], "originalCommand": args[:],
               "outputCompletion": fixtures.framework(2, 2), "runLoopProbe": {"swiftTestPID": 43, "status": "not-requested"}}
    report = {"processID": 42, "operatingSystem": "Version 27.0 (Build 26A428)", "stallSeconds": 8.8}
    raw_report = json.dumps(report)
    files = {"hosted-suite/suite.json": suite, "run.json": capture,
             "hosted-suite/xctest/console.log": fixtures.XCTEST,
             "hosted-suite/engine-swift-testing/console.log": fixtures.SWIFT,
             "hosted-suite/engine-swift-testing/events.jsonl": engine,
             "hosted-suite/app-swift-testing/console.log": fixtures.SWIFT,
             "hosted-suite/app-swift-testing/events.jsonl": app,
             "hosted-suite/app-swift-testing/host-receipt.json": host,
             "hosted-suite/combined.log": fixtures.XCTEST + fixtures.SWIFT * 2,
             "hosted-suite/app-swift-testing/swiftc-path.stdout":
                 "/Applications/Xcode_27.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc\n",
             "hosted-suite/app-swift-testing/watchdog/report.json": raw_report,
             "hosted-suite/app-swift-testing/watchdog/receipt.json": {"reports": [
                 {"file": "report.json", "processID": 42, "sha256": hashlib.sha256(raw_report.encode()).hexdigest()}]}}
    if change:
        change(suite, capture, host, files)
    write_archive(root / "tests.zip", files)
    return files


def producer_fixture():
    names = ["Run actions/checkout@v4", "Verify retained backends against this checkout and native toolchain",
             "Verify native app signing with nested runtime content", "Build", "Verify build did not mutate tracked source",
             "Stage test runtime inputs", "Test", "Upload Core backend composition", "Upload render review test diagnosis",
             "Upload blockout orientation evidence", "HDR export QC", "Upload HDR export QC evidence", "Upload Lottie export evidence",
             "Verify tests did not mutate tracked source", "Run actions/download-artifact@v4", resume.FAILED,
             "Stage the verified bpy runtime", "Bundle (debug, ad-hoc signed)"]
    workflow = "  build_test:\n" + "".join("      - name: " + n + "\n" for n in names) + "  diagnostic-startup:\n"
    run = {"id": 123, "head_sha": SOURCE, "run_attempt": 1, "status": "completed", "conclusion": "failure",
           "repository": {"full_name": "iret77/nexgenvideo"}, "head_repository": {"full_name": "iret77/nexgenvideo"},
           "event": "workflow_dispatch", "path": ".github/workflows/ci-batch.yml"}
    jobs = []
    for index, suffix in enumerate(("Light Checks", "Agent UI Evidence", "bpy-source / source", "Build & Test", "Merge Gate")):
        steps = []
        if suffix == "Light Checks":
            steps = [{"name": n, "conclusion": "success"} for n in (
                "Require distributable bpy before app transfer", "Enforce AppTheme", "Validate pack pipeline contracts", "Verify CI and fixture tooling")]
        if suffix == "Build & Test":
            steps = [{"name": n, "conclusion": "failure" if n == resume.FAILED else
                      "skipped" if n in resume.SKIPPED or i > names.index(resume.FAILED) else "success"}
                     for i, n in enumerate(names)]
        jobs.append({"id": 456 + index, "name": resume.PREFIX + suffix, "run_id": 123, "run_attempt": 1,
                     "head_sha": SOURCE, "status": "completed", "conclusion": "failure" if index >= 3 else "success", "steps": steps})
    return run, {"total_count": len(jobs), "jobs": jobs}, workflow


class FullCoreContinuationTests(unittest.TestCase):
    def test_composition_binds_transferred_bytes_without_relabeling_original_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); evidence = root / "evidence"; evidence.mkdir()
            app = root / "build/NexGenVideo.app"; app.mkdir(parents=True)
            app.with_suffix(".zip").write_bytes(b"current app archive")
            transfer = root / "workspace-transfer"; transfer.mkdir()
            (transfer / "workspace-ui.tar.gz").write_bytes(b"current workspace archive")
            tree = "c" * 64
            workspace = {"schema": "nexgenvideo/workspace-ui-input/1", "sourceSHA": HEAD, "appTreeSHA256": tree,
                         "archiveSHA256": hashlib.sha256(b"current workspace archive").hexdigest()}
            public = json.loads((ROOT / "Runtime/bpy/runtime-lock.json").read_text())["distributionClosure"]["publicSourceAsset"]
            source = {"schema": "nexgenvideo/bpy-source-receipt/1", "sourceSHA": HEAD, "publicSourceAsset": public,
                      "origin": {"kind": "actions", "producer": public["producer"]},
                      "validation": {"archiveSHA256": public["sha256"], "manifestSHA256": public["manifestSHA256"]}}
            source_path = app.parent / "bpy-source/bpy-source-receipt.json"; source_path.parent.mkdir()
            receipt = {"sourceSHA": HEAD, "runID": "456", "attempt": "1", "originalRun": {"id": 123, "head_sha": SOURCE},
                       "originalExecution": {"runID": 123, "jobID": 459, "attempt": 1, "sourceSHA": SOURCE}}
            (evidence / "receipt.json").write_text(json.dumps(receipt))
            def restore():
                (transfer / "workspace-ui-input.json").write_text(json.dumps(workspace))
                (transfer / "workspace-ui.tar.gz").write_bytes(b"current workspace archive")
                source_path.write_text(json.dumps(source))
                (transfer / "bpy-source-receipt.json").write_bytes(source_path.read_bytes())
            with patch.object(resume, "verify", return_value=receipt), patch.object(resume, "command", return_value=tree), \
                    patch.dict(os.environ, RUNNER_TEMP=str(root), GITHUB_STEP_SUMMARY=str(root / "summary")):
                restore(); resume.finish(evidence, app)
                completed = json.loads((evidence / "completed.json").read_text())
                self.assertEqual(completed["originalExecution"]["sourceSHA"], SOURCE)
                self.assertEqual(completed["currentExecution"]["sourceSHA"], HEAD)
                self.assertEqual(completed["appZipSHA256"], hashlib.sha256(b"current app archive").hexdigest())
                self.assertEqual(completed["workspace"], workspace)
                self.assertEqual(completed["bpySourceReceiptSHA256"], hashlib.sha256(source_path.read_bytes()).hexdigest())
                mutations = [lambda: (transfer / "workspace-ui.tar.gz").write_bytes(b"changed"),
                             lambda: (transfer / "workspace-ui-input.json").write_text(json.dumps({**workspace, "sourceSHA": SOURCE})),
                             lambda: (transfer / "workspace-ui-input.json").write_text(json.dumps({**workspace, "appTreeSHA256": "d" * 64})),
                             lambda: source_path.write_text(json.dumps({**source, "sourceSHA": SOURCE})),
                             lambda: (transfer / "bpy-source-receipt.json").write_bytes(b"different")]
                for index, mutation in enumerate(mutations):
                    restore(); mutation()
                    with self.subTest(index=index), self.assertRaises(ValueError):
                        resume.finish(evidence, app)

    def test_missing_owned_os_identity_is_rejected_before_native_allocation(self):
        def remove_os(suite, capture, host, files):
            path = "hosted-suite/app-swift-testing/watchdog/report.json"
            report = json.loads(files[path]); report.pop("operatingSystem")
            files[path] = json.dumps(report)
            files["hosted-suite/app-swift-testing/watchdog/receipt.json"]["reports"][0]["sha256"] = hashlib.sha256(files[path].encode()).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); full_fixture(root, remove_os)
            with self.assertRaisesRegex(ValueError, "OS identity"):
                resume.native_proof(root, SOURCE, 123)

    def test_hdr_requires_its_designated_filter_owned_execution_and_exact_movie(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = full_fixture(root)
            suite = copy.deepcopy(files["hosted-suite/suite.json"])
            phase = suite["phases"][2]
            events, proof = fixtures.native_events("NexGenVideoTests")
            events = events.replace(".Example/", ".HDRExportTests/")
            proof = json.loads(json.dumps(proof).replace(".Example/", ".HDRExportTests/"))
            phase.update(events=proof, command=["/Debug/NexGenVideoAppKitTestHost", "--filter", "HDRExportTests"])
            suite.update(scope="app-swift-testing", filter="HDRExportTests", phases=[phase], testExecutions=1)
            movie = b"retained original HDR movie"
            qc = {"schema": "delivery-hdr-qc/v1", "passed": True, "output_sha256": hashlib.sha256(movie).hexdigest(),
                  "reference_frames": [{"out_of_range_pixel_count": 0}] * 4}
            payload = {"hosted-suite/suite.json": suite, "hdr-reference.mov": movie, "hdr-qc.v1.json": qc,
                       "hosted-suite/app-swift-testing/console.log": fixtures.SWIFT,
                       "hosted-suite/app-swift-testing/events.jsonl": events,
                       "hosted-suite/app-swift-testing/host-receipt.json": phase["originalHostReceipt"]}
            write_archive(root / "hdr.zip", payload)
            self.assertEqual(resume.hdr_proof(root, SOURCE)["movieSHA256"], qc["output_sha256"])
            changes = [lambda p: p["hosted-suite/suite.json"].update(filter=""),
                       lambda p: p["hosted-suite/suite.json"].update(completed=False),
                       lambda p: p.update({"hdr-reference.mov": b"changed"}),
                       lambda p: p["hdr-qc.v1.json"].update(passed=False),
                       lambda p: p["hdr-qc.v1.json"]["reference_frames"][0].update(out_of_range_pixel_count=1),
                       lambda p: p["hosted-suite/app-swift-testing/host-receipt.json"].update(parentPID=0)]
            for index, change in enumerate(changes):
                invalid = copy.deepcopy(payload); change(invalid); write_archive(root / "hdr.zip", invalid)
                with self.subTest(index=index), self.assertRaises(ValueError):
                    resume.hdr_proof(root, SOURCE)

    def test_reconstruction_rejects_another_compiler_platform_or_diagnostic_profile(self):
        values = ["Xcode 27.0\nBuild version 27A266a", "Apple Swift version 6.4", "/Xcode/swiftc", "arm64", "27.0", "26A428"]
        receipt = {"toolchain": {"xcode": values[0], "swift": values[1]},
                   "nativeProof": {"compilerPath": values[2], "watchdog": {"operatingSystem": "Version 27.0 (Build 26A428)"}}}
        with patch.object(resume, "command", side_effect=values), patch.dict(os.environ, {}, clear=True):
            resume.verify_platform(receipt)
        for index in range(len(values)):
            changed = values[:]; changed[index] = "different"
            with self.subTest(index=index), patch.object(resume, "command", side_effect=changed), \
                    patch.dict(os.environ, {}, clear=True), self.assertRaises(ValueError):
                resume.verify_platform(receipt)
        with patch.dict(os.environ, {"NSZombieEnabled": "YES"}, clear=True), \
                patch.object(resume, "command") as command, self.assertRaisesRegex(ValueError, "diagnostic"):
            resume.verify_platform(receipt)
        command.assert_not_called()

    def test_current_binding_and_required_plan_refuse_before_reading_original_proofs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = {"schema": "core-full-resume/v1", "sourceSHA": HEAD, "runID": "456", "attempt": "1"}
            for field, value in (("sourceSHA", SOURCE), ("runID", "789"), ("attempt", "2")):
                (root / "receipt.json").write_text(json.dumps({**record, field: value}))
                with self.subTest(field=field), patch.dict(os.environ, GITHUB_SHA=HEAD, GITHUB_RUN_ID="456", GITHUB_RUN_ATTEMPT="1"), \
                        patch.object(resume, "source_binding") as binding, self.assertRaisesRegex(ValueError, "another execution"):
                    resume.verify(root)
                binding.assert_not_called()
            for values in (("false", "true", "true"), ("true", "false", "true"), ("true", "true", "false")):
                with patch("sys.argv", ["resume", "verify", "--evidence", str(root), "--plan", *values]), \
                        patch.object(resume, "verify") as verify, self.assertRaisesRegex(ValueError, "all Core branches"):
                    resume.main()
                verify.assert_not_called()

    def test_full_native_original_is_reused_only_with_all_aggregates_and_owned_normal_host(self):
        changes = [lambda s, c, h, f: s.update(filter="One"), lambda s, c, h, f: s.update(scope="app-swift-testing"),
                   lambda s, c, h, f: s.update(productSourceSHA=SOURCE), lambda s, c, h, f: s.update(completed=False),
                   lambda s, c, h, f: s.update(sourceSHA=HEAD), lambda s, c, h, f: s.update(testExecutions=2),
                   lambda s, c, h, f: s["phases"][1].update(exitCode=1),
                   lambda s, c, h, f: s["phases"][2].update(diagnostic="zombies"),
                   lambda s, c, h, f: c.update(effectiveExitCode=1), lambda s, c, h, f: c.update(runID="456"),
                   lambda s, c, h, f: c["actualCommand"].extend(["--filter", "One"]),
                   lambda s, c, h, f: c["runLoopProbe"].update(swiftTestPID=44),
                   lambda s, c, h, f: h.update(pid=99), lambda s, c, h, f: h.update(abiSucceeded=False),
                   lambda s, c, h, f: f.update({"hosted-suite/combined.log": fixtures.XCTEST + fixtures.SWIFT}),
                   lambda s, c, h, f: f.update({"hosted-suite/app-swift-testing/events.jsonl":
                                               f["hosted-suite/app-swift-testing/events.jsonl"].rsplit("\n", 2)[0] + "\n"}),
                   lambda s, c, h, f: f.update({"hosted-suite/app-swift-testing/watchdog/report.json":
                                               json.dumps({"processID": 99, "operatingSystem": "Version 27.0 (Build other)"})})]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); full_fixture(root)
            self.assertEqual(resume.native_proof(root, SOURCE, 123)["executions"], 3)
            for index, change in enumerate(changes):
                full_fixture(root, change)
                with self.subTest(index=index), self.assertRaises((ValueError, resume.VerificationError)):
                    resume.native_proof(root, SOURCE, 123)

    def test_original_attempt_and_ordered_failure_boundary_are_required(self):
        run, jobs, workflow = producer_fixture()
        self.assertEqual(resume.producer(run, jobs, workflow)["Build & Test"]["id"], 459)
        for key, value in (("run_attempt", 2), ("conclusion", "success"), ("status", "in_progress"),
                           ("path", ".github/workflows/diagnostic-acceptance.yml"), ("event", "push")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                resume.producer({**run, key: value}, jobs, workflow)
        for name in ("Test", "HDR export QC", "Build", "Run actions/download-artifact@v4", "Bundle (debug, ad-hoc signed)"):
            changed = copy.deepcopy(jobs)
            next(s for s in changed["jobs"][3]["steps"] if s["name"] == name)["conclusion"] = "failure"
            with self.subTest(step=name), self.assertRaises(ValueError):
                resume.producer(run, changed, workflow)
        changed = copy.deepcopy(jobs)
        changed["jobs"][3]["steps"][3:5] = reversed(changed["jobs"][3]["steps"][3:5])
        with self.assertRaisesRegex(ValueError, "ordered"):
            resume.producer(run, changed, workflow)

    def test_harness_allowlist_cannot_hide_native_inputs_or_recursive_origins(self):
        for path in ("Sources/Example.swift", "Tests/Example.swift", "Package.resolved", "Package.swift", "Runtime/bpy/runtime-lock.json",
                     "scripts/bundle.sh", "scripts/run_macos_tests.py", "scripts/stage_bpy_runtime.sh", "scripts/external-gui/acceptance.py"):
            with self.subTest(path=path), patch.object(resume, "command", side_effect=[HEAD, path]), \
                    patch.object(resume.subprocess, "run"), self.assertRaises(ValueError):
                resume.source_binding(SOURCE, HEAD)
        original = "run: " + resume.BUILD
        for match in (0, 2):
            with patch.object(resume, "command", side_effect=[HEAD, "scripts/pinned_download.py", "", original]), \
                    patch.object(resume.subprocess, "run", return_value=subprocess.CompletedProcess([], match)), \
                    self.assertRaisesRegex(ValueError, "native input"):
                resume.source_binding(SOURCE, HEAD)
        with patch.object(resume, "command", side_effect=[HEAD, "", "", original + " resume_core_bundle.py"]), \
                patch.object(resume.subprocess, "run"), self.assertRaisesRegex(ValueError, "Recursive"):
            resume.source_binding(SOURCE, HEAD)

    def test_artifact_bytes_expiry_and_job_interval_are_rechecked(self):
        now = datetime.now(timezone.utc)
        instant = lambda hours: (now + timedelta(hours=hours)).isoformat()
        run = {"id": 123, "head_sha": SOURCE}
        job = {"started_at": instant(-3), "completed_at": instant(-1)}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); records = {}
            for key, (name, _) in resume.ARTIFACTS.items():
                data = key.encode(); (root / (key + ".zip")).write_bytes(data)
                records[key] = {"id": 1, "name": name.format(run=123), "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                                "size_in_bytes": len(data), "expired": False, "expires_at": instant(24),
                                "created_at": instant(-2), "updated_at": instant(-2), "workflow_run": {"id": 123, "head_sha": SOURCE}}
            receipt = {"originalRun": run, "artifacts": records}
            jobs = {"Build & Test": job, "Agent UI Evidence": job}
            resume.check_artifacts(root, receipt, jobs)
            for key, value in (("expired", True), ("expires_at", instant(1)), ("created_at", instant(-5)),
                               ("size_in_bytes", 100), ("digest", "sha256:" + "0" * 64)):
                changed = copy.deepcopy(receipt); changed["artifacts"]["tests"][key] = value
                with self.subTest(key=key), self.assertRaises(ValueError):
                    resume.check_artifacts(root, changed, jobs)

    def test_dispatch_full_resume_is_exclusive_and_initial_only(self):
        text = (ROOT / ".github/workflows/ci-batch.yml").read_text()
        code = textwrap.dedent(text.split("          python3 - <<'PYTHON'\n", 1)[1].split("          PYTHON", 1)[0])
        defaults = {"NGV_MODE": "initial", "NGV_FOLLOWUP": "none", "NGV_RUNTIME_RUN": "", "NGV_QUALIFICATION_RUN": "",
                    "NGV_SOURCE_RUN": "", "NGV_SETTINGS_SCOPE": "all", "NGV_INTERFACE_SCALE": "all", "NGV_TEST_BUNDLE_RUN": "",
                    "NGV_COMPLETED_BACKENDS": "", "NGV_APP_INVENTORY": "", "NGV_SOURCE_CHECKS": "", "NGV_COMPLETED_FULL": "123"}
        changes = [({}, True)] + [({key: value}, False) for key, value in (
            ("NGV_COMPLETED_FULL", "0"), ("NGV_COMPLETED_FULL", "x"), ("NGV_MODE", "followup"), ("NGV_MODE", "qualification"),
            ("NGV_COMPLETED_BACKENDS", "123"), ("NGV_APP_INVENTORY", "123"), ("NGV_SOURCE_CHECKS", "123"),
            ("NGV_QUALIFICATION_RUN", "123"), ("NGV_SOURCE_RUN", "123"))]
        with tempfile.TemporaryDirectory() as directory:
            for change, good in changes:
                with self.subTest(change=change):
                    result = subprocess.run(["python3", "-c", code], env={**os.environ, **defaults, **change,
                        "GITHUB_OUTPUT": str(Path(directory) / "output")}, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode == 0, good, result.stderr)

    def test_workflow_reuses_proofs_without_relabeling_or_bypassing_remaining_gates(self):
        text = (ROOT / ".github/workflows/ci.yml").read_text()
        mac = text.split("  build_test:\n", 1)[1].split("  diagnostic-startup:\n", 1)[0]
        self.assertLess(mac.index("      - name: Build\n"), mac.index("uses: ./.github/actions/prepare-bpy-source"))
        self.assertLess(mac.index("uses: ./.github/actions/prepare-bpy-source"), mac.index("      - name: Stage test runtime inputs\n"))
        self.assertIn("needs.bpy-source.result == 'success' || needs.bpy-source.result == 'skipped'", mac)
        self.assertIn("run: " + resume.BUILD, mac)
        for name in ("Stage test runtime inputs", "Test", "HDR export QC", "Upload render review test diagnosis",
                     "Upload blockout orientation evidence", "Upload HDR export QC evidence", "Upload Lottie export evidence"):
            step = mac.split("      - name: " + name + "\n", 1)[1].split("      - ", 1)[0]
            self.assertIn("inputs.completed_full_core_run_id == ''", step)
        for name in ("Stage the verified bpy runtime", "Bundle (debug, ad-hoc signed)", "Verify app architecture and minimum macOS",
                     "Upload .app artifact", "Transfer the same app and pack for workspace acceptance"):
            step = mac.split("      - name: " + name + "\n", 1)[1].split("      - ", 1)[0]
            self.assertNotIn("completed_full_core_run_id", step)
        source = text.split("  source_gate:\n", 1)[1].split("  ui_render:\n", 1)[0]
        tooling = source.split("      - name: Verify CI and fixture tooling\n", 1)[1].split("      - name:", 1)[0]
        self.assertNotIn("completed_full_core_run_id", tooling)
        self.assertIn("python3 -m unittest discover -s scripts -p 'test_*.py'", tooling)
        self.assertIn('--plan "$BUILD_REQUIRED" "$BUNDLE_REQUIRED" "$UI_REQUIRED"', source)
        self.assertIn("resume_core_bundle.py finish", mac)
        self.assertIn("name: core-full-completion-${{ github.run_id }}-a${{ github.run_attempt }}", mac)


if __name__ == "__main__":
    unittest.main()
