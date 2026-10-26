from copy import deepcopy
from datetime import datetime, timezone, timedelta
from pathlib import Path
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

from bpy_open_diagnostic import capture_predicate
from bpy_resource_diagnostic import (ALLOWED, ARTIFACT, DIGEST, RUN, SIZE, SOURCE, TREE,
                                     archive_receipt, download_bytes, inspect, orphan_pattern, placement,
                                     resource_control, survivors, verify_inputs, verify_origin)


class ResourceDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.run = dict(id=RUN, head_sha=SOURCE, path=".github/workflows/ci-batch.yml",
                        event="workflow_dispatch", status="completed", conclusion="failure", run_attempt=1,
                        repository=dict(full_name="iret77/nexgenvideo"),
                        head_repository=dict(full_name="iret77/nexgenvideo"))
        prefix = "Compile, unit tests, app and native bpy acceptance / "
        jobs = [dict(id=100+i, name=prefix+name, status="completed", conclusion="success",
                     run_id=RUN, run_attempt=1, head_sha=SOURCE)
                for i, name in enumerate(("Light Checks", "Agent UI Evidence", "bpy-source / source",
                                          "diagnostic-startup", "Build & Test", "bpy-runtime / runtime"))]
        jobs[-2].update(id=121407415150, started_at="2026-10-26T05:00:00Z", completed_at="2026-10-26T05:20:00Z")
        jobs[-1].update(id=121411720766, conclusion="failure", steps=[
            dict(name=name, status="completed", conclusion=result) for name, result in (
                ("Relocate the exact app and prepare denied resources", "success"),
                ("Prove pre-lease and post-exec host-crash cleanup", "failure"),
                ("Prepare the independent retained Bible YAML parser", "skipped"),
                ("Run real bpy acceptance without ambient Blender or Python", "skipped"))])
        self.jobs = dict(total_count=len(jobs), jobs=jobs)
        self.artifact = dict(id=ARTIFACT, name="NexGenVideo-app", expired=False,
                             digest="sha256:"+DIGEST, size_in_bytes=SIZE,
                             workflow_run=dict(id=RUN, head_sha=SOURCE),
                             created_at="2026-10-26T05:19:04Z", updated_at="2026-10-26T05:19:04Z",
                             expires_at="2099-01-01T00:00:00Z")

    def check(self, changed=ALLOWED):
        verify_origin(self.run, self.jobs, self.artifact, changed)

    def test_only_original_successful_build_and_failed_bpy_attempt_can_supply_app(self):
        self.check()
        for target, key, value in [(self.run, "run_attempt", 2),
                                   (self.run, "head_sha", "a"*40),
                                   (self.jobs["jobs"][-2], "id", 121407415151),
                                   (self.jobs["jobs"][-1], "id", 121411720767),
                                   (self.jobs["jobs"][-1], "conclusion", "success"),
                                   (self.artifact, "digest", "sha256:"+"0"*64),
                                   (self.artifact, "size_in_bytes", SIZE-1),
                                   (self.artifact, "expired", True),
                                   (self.run, "head_repository", dict(full_name="someone/nexgenvideo"))]:
            previous = deepcopy(target[key])
            target[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.check()
            target[key] = previous

    def test_expiring_artifact_and_changed_native_inputs_are_rejected(self):
        self.artifact["expires_at"] = (datetime.now(timezone.utc)+timedelta(hours=5)).isoformat()
        with self.assertRaises(ValueError):
            self.check()
        self.artifact["expires_at"] = "2099-01-01T00:00:00Z"
        for path in ("Sources/NexGenVideoBpyService/main.swift", "Runtime/bpy/PythonChild.entitlements",
                     "scripts/bpy_runtime_acceptance.py", "scripts/verify_diagnostic_candidate.py",
                     "scripts/external-gui/acceptance.py", "scripts/sign_app.sh"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check(ALLOWED | {path})

    def test_visible_workflow_inputs_cannot_misrepresent_fixed_diagnostic(self):
        environment = dict(CANDIDATE_RUN=str(RUN), CANDIDATE_SOURCE=SOURCE,
                           CANDIDATE_ARTIFACT=str(ARTIFACT), CANDIDATE_DIGEST=DIGEST,
                           REPLAY_KIND="ci-bpy-resource-diagnostic")
        verify_inputs(environment)
        for key in environment:
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify_inputs(dict(environment, **{key: "other"}))
        with self.assertRaises(ValueError):
            verify_inputs(dict(environment, PRODUCTS_ID="123"))

    def test_each_location_has_one_fresh_attempt_and_no_user_supplied_path(self):
        temporary, home = Path("/runner/temp"), Path("/Users/runner")
        self.assertEqual(placement("temporary", temporary, home, "123", "1"), temporary/"relocated")
        self.assertEqual(placement("home", temporary, home, "123", "1"), home/"NGV-bpy-diagnostic-123")
        self.assertEqual(placement("applications", temporary, home, "123", "1"),
                         Path("/Applications/NGV-bpy-diagnostic-123"))
        for arm, run, attempt in [("../escape", "123", "1"), ("home", "../../x", "1"),
                                   ("home", "123", "2"), ("home", "", "1")]:
            with self.assertRaises(ValueError):
                placement(arm, temporary, home, run, attempt)

    def test_orphan_identity_requires_exact_app_boundary_including_spaces(self):
        app = Path("/Users/runner/An App/NexGenVideo.app")
        raw = (f" 12 {app}/Contents/MacOS/NexGenVideo\n"
               f" 13 {app}/Contents/Resources/BpyRuntime/python/bin/python3.13\n"
               f" 14 {app}.foreign/Contents/MacOS/NexGenVideo\n"
               " 15 /other/NexGenVideo.app/Contents/MacOS/NexGenVideo\n")
        self.assertEqual([v["pid"] for v in survivors(raw, app)], [12, 13])

    def test_policy_capture_retains_original_controls_and_adds_other_denial_sources(self):
        original = capture_predicate()
        extended = capture_predicate(True)
        self.assertTrue(extended.startswith(original))
        for name in ("tccd", "syspolicyd", "amfid", "containermanagerd", "secinitd"):
            self.assertIn('"'+name+'"', extended)
        self.assertIn('subsystem == "com.apple.sandbox.reporting"', extended)

    def test_download_keeps_stderr_out_of_original_zip_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            download_bytes([sys.executable, "-c", "import os; os.write(1,b'PK original bytes'); os.write(2,b'notice')"],
                           root/"original.zip", root/"stderr.log")
            self.assertEqual((root/"original.zip").read_bytes(), b"PK original bytes")
            self.assertEqual((root/"stderr.log").read_bytes(), b"notice")

    def test_download_timeout_reaps_only_owned_child_and_does_not_retry(self):
        process = Mock()
        process.wait.side_effect = subprocess.TimeoutExpired("download", 600)
        with tempfile.TemporaryDirectory() as temporary, \
             patch("bpy_resource_diagnostic.subprocess.Popen", return_value=process) as start, \
             patch("bpy_resource_diagnostic.stop_owned") as stop:
            root = Path(temporary)
            with self.assertRaises(subprocess.TimeoutExpired):
                download_bytes(["download"], root/"original.zip", root/"stderr.log")
            start.assert_called_once()
            self.assertTrue(start.call_args.kwargs["start_new_session"])
            stop.assert_called_once_with(process)

    def test_cancellation_reaps_owned_download_before_propagating(self):
        process = Mock()
        process.wait.side_effect = InterruptedError("SIGTERM")
        with tempfile.TemporaryDirectory() as temporary, \
             patch("bpy_resource_diagnostic.subprocess.Popen", return_value=process), \
             patch("bpy_resource_diagnostic.stop_owned") as stop:
            root = Path(temporary)
            with self.assertRaises(InterruptedError):
                download_bytes(["download"], root/"original.zip", root/"stderr.log")
            stop.assert_called_once_with(process)

    def test_full_command_orphan_match_uses_portable_ere_for_location_names(self):
        app = Path("/Applications/NGV-bpy-diagnostic-123/NexGenVideo.app")
        pattern = orphan_pattern(app)
        self.assertNotIn(r"\-", pattern)
        command = str(app) + "/Contents/Helpers/NexGenVideoBpySupervisor"
        foreign = command.replace("NexGenVideo.app", "NexGenVideoXapp")
        result = subprocess.run(["grep", "-E", pattern], input=command+"\n"+foreign+"\n",
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, command+"\n")

    def test_archive_requires_nested_source_receipt_and_its_exact_bytes(self):
        receipt = json.dumps(dict(sourceSHA=SOURCE)).encode()
        def archive(name, data=receipt):
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, "w") as out:
                out.writestr("NexGenVideo.zip", b"immutable app fixture")
                out.writestr(name, data)
            return zipfile.ZipFile(stream)
        with patch("bpy_resource_diagnostic.SOURCE_RECEIPT", hashlib.sha256(receipt).hexdigest()):
            with archive("bpy-source/bpy-source-receipt.json") as value:
                self.assertEqual(archive_receipt(value), receipt)
            for path, data in [("bpy-source-receipt.json", receipt),
                               ("bpy-source/bpy-source-receipt.json", receipt+b" ")]:
                with archive(path, data) as value, self.assertRaises(ValueError):
                    archive_receipt(value)

    def test_resource_control_requires_complete_same_service_session_and_real_image(self):
        app = Path("/a/NexGenVideo.app")
        image = str(app/"Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/MacOS/NexGenVideoBpyService")
        session = "11111111-1111-1111-1111-111111111111"
        entries = [dict(processID=22, processImagePath=image, eventMessage=
                        f"open.runtime-resource session={session} pid=22 start=333 role={role} readErrno=1")
                   for role in ("pythonAlias", "pythonTarget", "supervisor", "worker", "sitePackages")]
        entries.append(dict(processID=22, processImagePath=image,
                            eventMessage=f"open.runtime-preflight session={session} pid=22 start=333 python=false"))
        encode = lambda values: b"\n".join(json.dumps(value).encode() for value in values)
        self.assertTrue(resource_control(encode(entries), app)["complete"])
        self.assertFalse(resource_control(encode(entries[:-1]), app)["complete"])
        for key, value in [("processID", 23), ("processImagePath", image.replace("/a/", "/foreign/")),
                           ("eventMessage", entries[0]["eventMessage"].replace("start=333", "start=444"))]:
            changed = deepcopy(entries)
            changed[0][key] = value
            self.assertFalse(resource_control(encode(changed), app)["complete"])

    def test_final_capture_errors_do_not_mask_probe_error_or_claim_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root/"evidence"
            evidence.mkdir()
            (evidence/"placement.json").write_text(json.dumps(dict(app="/a/NexGenVideo.app")))
            with patch.dict(os.environ, RUNNER_TEMP=str(root)), \
                 patch("bpy_resource_diagnostic.tree", side_effect=[TREE, OSError("post tree")]), \
                 patch("bpy_resource_diagnostic.observe", side_effect=RuntimeError("original probe failure")), \
                 patch("bpy_resource_diagnostic.subprocess.run", side_effect=OSError("process list")):
                with self.assertRaisesRegex(RuntimeError, "original probe failure"):
                    inspect(evidence)
            result = json.loads((evidence/"post-execution.json").read_text())
            self.assertFalse(result["runtimeAcceptance"])
            self.assertFalse(result["comparisonInstrumentsComplete"])
            self.assertIsNone(result["survivingProcesses"])
            self.assertEqual(len(result["errors"]), 3)
