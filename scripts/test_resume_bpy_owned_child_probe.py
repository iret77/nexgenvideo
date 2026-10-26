from copy import deepcopy
from contextlib import ExitStack
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import zipfile

import resume_bpy_owned_child_probe as resume
from test_bpy_owned_child_probe import completed_cases


def producer():
    run = {"id": resume.RUN, "head_sha": resume.SOURCE, "run_attempt": 1, "event": "workflow_dispatch",
           "status": "completed", "conclusion": "failure", "path": ".github/workflows/native-acceptance-probes.yml",
           "head_branch": "iret77/activity-approval-layout", "actor": {"login": "iret77"},
           "repository": {"full_name": "iret77/nexgenvideo"}}
    steps = [{"name": name, "conclusion": conclusion} for name, conclusion in (
        ("Verify output capture on the failed producer platform", "success"),
        ("Compile reviewed owned-child implementation and diagnostic", "success"),
        ("Record exact source, environment and signal lifecycle", "failure"))]
    job = {"id": 121692113899, "name": "owned-child", "run_id": resume.RUN, "run_attempt": 1,
           "head_sha": resume.SOURCE, "status": "completed", "conclusion": "failure", "steps": steps}
    artifact = {"id": resume.ARTIFACT, "expired": False, "name": "owned-child-diagnostic-40357018456",
                "size_in_bytes": 20309, "digest": "sha256:" + resume.ARCHIVE,
                "workflow_run": {"id": resume.RUN, "head_sha": resume.SOURCE}}
    return run, {"total_count": 1, "jobs": [job]}, artifact


class RetainedOwnedChildProbeTests(unittest.TestCase):
    def test_only_exact_original_producer_and_successful_prerequisites_are_accepted(self):
        original = producer()
        resume.verify_producer(*original)
        for index, key, value in ((0, "head_sha", "a" * 40), (0, "run_attempt", 2), (0, "event", "push"),
                                  (0, "conclusion", "success"), (0, "actor", {"login": "other"}),
                                  (1, "total_count", 2), (2, "expired", True), (2, "digest", "sha256:wrong")):
            with self.subTest(index=index, key=key):
                changed = deepcopy(original)
                changed[index][key] = value
                with self.assertRaises(ValueError):
                    resume.verify_producer(*changed)
        for index in range(3):
            changed = deepcopy(original)
            changed[1]["jobs"][0]["steps"][index]["conclusion"] = "skipped"
            with self.assertRaises(ValueError):
                resume.verify_producer(*changed)

    def archive(self, change=None):
        names = [f"test_fixture_{index}" for index in range(43)]
        binary = b"retained fixture binary"
        receipt = {"sourceSHA": resume.SOURCE, "runID": str(resume.RUN), "attempt": "1",
                   "binarySHA256": hashlib.sha256(binary).hexdigest(), "completed": False, "timedOut": False}
        records = completed_cases()
        text = "\n".join(f"{name} (test_run_macos_tests.HostedTestDriverTests.{name}) ... ok" for name in names)
        members = {"owned-child/probe": binary, "owned-child/receipt.json": json.dumps(receipt).encode(),
                   "owned-child/events.jsonl": "\n".join(json.dumps(item) for item in records).encode(),
                   "owned-child/capture-tests.log": (text + "\nRan 43 tests in 6.355s\n\nOK\n").encode()}
        if change:
            change(members)
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, value in members.items():
                archive.writestr(name, value)
        with zipfile.ZipFile(data, "a") as archive:
            archive.comment = b"x" * (20309 - len(data.getvalue()))
        raw = data.getvalue()
        return raw, names, hashlib.sha256(binary).hexdigest()

    def test_archive_requires_original_binary_all_cases_and_all_capture_tests(self):
        raw, names, binary = self.archive()
        with patch.object(resume, "ARCHIVE", hashlib.sha256(raw).hexdigest()), patch.object(resume, "BINARY", binary):
            result = resume.unpack(raw, names)
            self.assertEqual(hashlib.sha256(result[0]).hexdigest(), binary)
            with self.assertRaises(ValueError):
                resume.unpack(raw[:-1], names)
            with self.assertRaises(ValueError):
                resume.unpack(raw, names[:-1])

    def test_partial_or_failed_original_evidence_is_rejected(self):
        changes = (
            lambda m: m.update({"owned-child/probe": b"changed"}),
            lambda m: m.update({"owned-child/events.jsonl": b'{"stage":"complete","cases":12}'}),
            lambda m: m.update({"owned-child/capture-tests.log": m["owned-child/capture-tests.log"].replace(b"... ok", b"... skipped", 1)}),
            lambda m: m.update({"owned-child/receipt.json": m["owned-child/receipt.json"].replace(b'"attempt": "1"', b'"attempt": "2"')}),
        )
        for change in changes:
            raw, names, binary = self.archive(change)
            with patch.object(resume, "ARCHIVE", hashlib.sha256(raw).hexdigest()), patch.object(resume, "BINARY", binary):
                with self.assertRaises(ValueError):
                    resume.unpack(raw, names)

    def prepare_fixture(self, failure=None):
        def add_source(members):
            receipt = json.loads(members["owned-child/receipt.json"])
            receipt.update(ownedChildSHA256=resume.sha(b"child source"),
                           probeSourceSHA256=resume.sha(b"probe source"), macOS="27.0", xcode="Xcode 27.0")
            members["owned-child/receipt.json"] = json.dumps(receipt).encode()
        raw, names, binary = self.archive(add_source)
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            fixture = Path(directory)
            root = fixture / "output"
            files = {"Sources/BpySupervisorPOSIX/OwnedChild.c": b"child source",
                     "scripts/bpy_owned_child_probe.c": b"probe source",
                     "scripts/test_run_macos_tests.py": "\n".join(f"    def {name}(self): pass" for name in names).encode()}
            for name, data in files.items():
                path = fixture / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            if failure == "destination":
                root.mkdir()
                (root / "probe").write_bytes(b"do not replace")
            if failure == "source":
                (fixture / "Sources/BpySupervisorPOSIX/OwnedChild.c").write_bytes(b"changed")
            def output(command, **kwargs):
                if command[:2] == ["git", "rev-parse"]:
                    return "wrong" if failure == "head" else "a" * 40
                if command[:2] == ["git", "diff"]:
                    return "Sources/Changed.c" if failure == "path" else "scripts/run_bpy_owned_child_probe.py"
                if command[:2] == ["git", "status"]:
                    return " M source" if failure == "dirty" else ""
                if command[0] == "sw_vers":
                    return "27.1" if failure == "platform" else "27.0"
                if command[0] == "xcodebuild":
                    return "wrong" if failure == "xcode" else "Xcode 27.0"
                raise AssertionError(command)
            stack.enter_context(patch.object(resume, "ARCHIVE", resume.sha(raw)))
            stack.enter_context(patch.object(resume, "BINARY", binary))
            stack.enter_context(patch.object(resume, "Path", side_effect=lambda name: fixture / name))
            stack.enter_context(patch.dict(os.environ, GITHUB_SHA="a" * 40))
            stack.enter_context(patch.object(resume.subprocess, "check_output", side_effect=output))
            ancestor = stack.enter_context(patch.object(resume.subprocess, "run",
                side_effect=subprocess.CalledProcessError(1, "git") if failure == "ancestor" else None))
            stack.enter_context(patch.object(resume, "api", side_effect=producer()))
            stack.enter_context(patch.object(resume, "api_bytes", return_value=raw))
            if failure:
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    resume.prepare(str(resume.RUN), root)
                if failure == "destination":
                    self.assertEqual((root / "probe").read_bytes(), b"do not replace")
                else:
                    self.assertFalse((root / "probe").exists())
                return
            resume.prepare(str(resume.RUN), root)
            ancestor.assert_called_once_with(["git", "merge-base", "--is-ancestor", resume.SOURCE, "a" * 40],
                                             check=True, timeout=30)
            self.assertEqual(resume.sha((root / "probe").read_bytes()), binary)
            self.assertEqual((root / "probe").stat().st_mode & 0o777, 0o755)
            evidence = json.loads((root / "retained-binary.json").read_text())
            self.assertEqual(evidence["sourceSHA"], "a" * 40)
            self.assertEqual(evidence["producerSource"], resume.SOURCE)
            self.assertEqual(evidence["reusedCaptureTests"], 43)
            self.assertEqual(evidence["originalCasesSHA256"], resume.sha((root / "original-cases.jsonl").read_bytes()))
            self.assertEqual(evidence["originalCaptureSHA256"], resume.sha((root / "original-capture-tests.log").read_bytes()))
            self.assertEqual(json.loads((root / "retained-producer.json").read_text())["run"]["id"], resume.RUN)

    def test_prepare_restores_exact_bytes_and_keeps_producer_and_harness_separate(self):
        self.prepare_fixture()

    def test_prepare_rejects_unbound_checkout_inputs_platform_or_destination(self):
        for failure in ("head", "ancestor", "path", "dirty", "source", "platform", "xcode", "destination"):
            with self.subTest(failure=failure):
                self.prepare_fixture(failure)

    def test_api_preserves_binary_bytes_and_does_not_forward_authorization(self):
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b"PK\x00\x1b\xff"
        opener = MagicMock()
        opener.open.return_value = response
        with patch.dict(os.environ, GH_TOKEN="synthetic-test-only"), \
                patch.object(resume.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(resume.api_bytes("actions/artifacts/1/zip"), b"PK\x00\x1b\xff")
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "https://api.github.com/repos/iret77/nexgenvideo/actions/artifacts/1/zip")
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 45)
        self.assertEqual(request.get_header("Authorization"), "Bearer synthetic-test-only")
        redirected = resume.HTTPSRedirect().redirect_request(request, None, 302, "Found", {}, "https://example.test/artifact")
        self.assertFalse(redirected.has_header("Authorization"))
        with self.assertRaises(ValueError):
            resume.HTTPSRedirect().redirect_request(request, None, 302, "Found", {}, "http://example.test/artifact")

    def test_api_failure_does_not_report_signed_urls_or_accept_oversize_response(self):
        opener = MagicMock()
        with patch.dict(os.environ, GH_TOKEN="synthetic-test-only"), \
                patch.object(resume.urllib.request, "build_opener", return_value=opener):
            for error in (OSError("sensitive-signed-url"), resume.http.client.IncompleteRead(b"private", 100)):
                opener.open.side_effect = error
                with self.assertRaisesRegex(ValueError, "^Original GitHub evidence download failed$"):
                    resume.api_bytes("actions/artifacts/1/zip")
            opener.open.side_effect = None
            opener.open.return_value.__enter__.return_value.read.return_value = b"x" * 1_000_001
            with self.assertRaisesRegex(ValueError, "size bound"):
                resume.api_bytes("actions/artifacts/1/zip")


if __name__ == "__main__":
    unittest.main()
