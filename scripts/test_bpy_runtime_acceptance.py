import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

from bpy_runtime_acceptance import collect_hangs, diagnostic_error, supervise, verify_crash


class HostCrashProofTests(unittest.TestCase):
    source = "a" * 40

    def proof(self, mode):
        value = dict(schema=1, pid=123, sourceSHA=self.source, state="running", mode=mode,
                     jobID=str(uuid.uuid4()), supervisorPID=456)
        if mode == "before-authorization":
            value["authorizationID"] = str(uuid.uuid4())
        else:
            value["workerPID"] = 789
        return value

    def test_requires_actual_sigkill_at_both_declared_stages(self):
        for mode in ("before-authorization", "after-authorization"):
            proof = self.proof(mode)
            verify_crash(proof, mode, 123, self.source, -signal.SIGKILL)
            for status in (0, 1, 70, -signal.SIGTERM, -signal.SIGABRT):
                with self.subTest(mode=mode, status=status), self.assertRaisesRegex(AssertionError, "intentional SIGKILL"):
                    verify_crash(proof, mode, 123, self.source, status)

    def test_rejects_foreign_identity_and_unreached_stage(self):
        proof = self.proof("before-authorization")
        for key, value in (("pid", 124), ("sourceSHA", "b" * 40), ("schema", 2),
                           ("state", "failed"), ("mode", "after-authorization"), ("supervisorPID", 123)):
            modified = dict(proof, **{key: value})
            with self.subTest(key=key), self.assertRaises(AssertionError):
                verify_crash(modified, "before-authorization", 123, self.source, -signal.SIGKILL)

    def test_pre_authorization_requires_lease_without_a_worker(self):
        proof = self.proof("before-authorization")
        for key, value in (("authorizationID", "bad-id"), ("workerPID", 789)):
            modified = dict(proof, **{key: value})
            with self.subTest(key=key), self.assertRaises((AssertionError, ValueError)):
                verify_crash(modified, "before-authorization", 123, self.source, -signal.SIGKILL)

    def test_post_authorization_requires_distinct_worker_without_pending_lease(self):
        proof = self.proof("after-authorization")
        for key, value in (("workerPID", None), ("workerPID", 123), ("workerPID", 456),
                           ("authorizationID", str(uuid.uuid4()))):
            modified = copy.deepcopy(proof)
            modified[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(AssertionError):
                verify_crash(modified, "after-authorization", 123, self.source, -signal.SIGKILL)


class SupervisionTests(unittest.TestCase):
    source = "a" * 40

    def test_diagnostic_write_ignores_disk_errors_but_preserves_ci_cancellation(self):
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch("bpy_runtime_acceptance.Path.write_text", side_effect=OSError("disk failure")):
                diagnostic_error(Path(temporary), "sample", ValueError("capture failed"))
            with mock.patch("bpy_runtime_acceptance.Path.write_text", side_effect=InterruptedError("CI stop")):
                with self.assertRaisesRegex(InterruptedError, "CI stop"):
                    diagnostic_error(Path(temporary), "sample", ValueError("capture failed"))

    def executable(self, root, source):
        binary = root / "owned-app"
        binary.write_text("#!" + sys.executable + "\n" + source)
        binary.chmod(0o755)
        return binary

    def test_runtime_nonzero_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch("bpy_runtime_acceptance.sample_owned"):
            root = Path(temporary)
            binary = self.executable(root, "raise SystemExit(7)\n")
            with mock.patch("bpy_runtime_acceptance.Path.home", return_value=root / "home"):
                with self.assertRaisesRegex(AssertionError, "status 7"):
                    supervise(binary, root / "evidence", "runtime", self.source, 3)
            failure = json.loads((root / "evidence/process-failure.json").read_text())
            self.assertIn("status 7", failure["error"])

    def test_deadline_records_failure_and_reaps_its_child(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch("bpy_runtime_acceptance.sample_owned"):
            root = Path(temporary)
            binary = self.executable(root, "import time\ntime.sleep(30)\n")
            with mock.patch("bpy_runtime_acceptance.Path.home", return_value=root / "home"):
                with self.assertRaisesRegex(AssertionError, "timed out"):
                    supervise(binary, root / "evidence", "runtime", self.source, 0.05)
            failure = json.loads((root / "evidence/process-failure.json").read_text())
            try:
                with self.assertRaises(ProcessLookupError):
                    os.kill(failure["pid"], 0)
            finally:
                try:
                    os.kill(failure["pid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_sampler_or_report_copy_failure_cannot_change_a_successful_app_result(self):
        for failure_kind in ("sample", "copy"):
            with self.subTest(failure_kind=failure_kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                home = root / "home"
                hangs = home / "Library/Logs/NexGenVideo"
                hangs.mkdir(parents=True)
                binary = self.executable(root, """import json, os, time
from pathlib import Path
path = Path(os.environ['NGV_TEST_HANG_DIRECTORY']) / 'owned-main-thread-hang.json'
temporary = path.with_suffix('.partial')
temporary.write_text(json.dumps(dict(processID=os.getpid())))
os.replace(temporary, path)
time.sleep(0.3)
""")
                sample_error = subprocess.TimeoutExpired("sample", 30) if failure_kind == "sample" else None
                with mock.patch.dict(os.environ, NGV_TEST_HANG_DIRECTORY=str(hangs)), \
                     mock.patch("bpy_runtime_acceptance.Path.home", return_value=home), \
                     mock.patch("bpy_runtime_acceptance.sample_owned", side_effect=sample_error) as sampler:
                    if failure_kind == "copy":
                        with mock.patch("bpy_runtime_acceptance.Path.write_bytes", side_effect=OSError("capture disk failure")):
                            supervise(binary, root / "evidence", "runtime", self.source, 3)
                    else:
                        supervise(binary, root / "evidence", "runtime", self.source, 3)
                        sampler.assert_called_once()
                result = json.loads((root / "evidence/process-result.json").read_text())
                self.assertEqual(result["returncode"], 0)
                self.assertTrue((root / "evidence/hang-1-error.json").is_file())
                error = json.loads((root / "evidence/hang-1-error.json").read_text())["error"]
                self.assertIn("timed out" if failure_kind == "sample" else "capture disk failure", error)
                self.assertFalse((root / "evidence/process-failure.json").exists())

    def test_foreign_pid_report_never_triggers_sampling(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hangs = root / "Library/Logs/NexGenVideo"
            hangs.mkdir(parents=True)
            (hangs / "foreign-main-thread-hang.json").write_text(json.dumps(dict(processID=456)))
            process = mock.Mock(pid=123)
            captured = set()
            with mock.patch("bpy_runtime_acceptance.Path.home", return_value=root), \
                 mock.patch("bpy_runtime_acceptance.sample_owned") as sampler:
                collect_hangs(process, root, time.time() - 1, captured)
            sampler.assert_not_called()
            self.assertFalse(captured)

    def test_a_report_read_in_progress_is_retried_without_consuming_a_sample_slot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hangs = root / "Library/Logs/NexGenVideo"
            hangs.mkdir(parents=True)
            path = hangs / "owned-main-thread-hang.json"
            path.write_text("{")
            captured = set()
            process = mock.Mock(pid=123)
            with mock.patch("bpy_runtime_acceptance.Path.home", return_value=root), \
                 mock.patch("bpy_runtime_acceptance.sample_owned") as sampler:
                collect_hangs(process, root, time.time() - 1, captured)
                self.assertFalse(captured)
                sampler.assert_not_called()
                path.write_text(json.dumps(dict(processID=123)))
                collect_hangs(process, root, time.time() - 1, captured)
                sampler.assert_called_once()
                self.assertEqual(captured, {path})

    def test_ci_interruption_during_sampling_is_not_swallowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hangs = root / "home/Library/Logs/NexGenVideo"
            hangs.mkdir(parents=True)
            binary = self.executable(root, """import json, os, time
from pathlib import Path
path = Path(os.environ['NGV_TEST_HANG_DIRECTORY']) / 'owned-main-thread-hang.json'
temporary = path.with_suffix('.partial')
temporary.write_text(json.dumps(dict(processID=os.getpid())))
os.replace(temporary, path)
time.sleep(30)
""")
            with mock.patch.dict(os.environ, NGV_TEST_HANG_DIRECTORY=str(hangs)), \
                 mock.patch("bpy_runtime_acceptance.Path.home", return_value=root / "home"), \
                 mock.patch("bpy_runtime_acceptance.sample_owned", side_effect=InterruptedError("CI stop")):
                with self.assertRaisesRegex(InterruptedError, "CI stop"):
                    supervise(binary, root / "evidence", "runtime", self.source, 3)
            failure = json.loads((root / "evidence/process-failure.json").read_text())
            self.assertEqual(failure["error"], "CI stop")
            with self.assertRaises(ProcessLookupError):
                os.kill(failure["pid"], 0)

    def test_metadata_write_failure_still_reaps_the_started_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = self.executable(root, "import time\ntime.sleep(30)\n")
            children = []
            original_popen = subprocess.Popen
            original_write = Path.write_text

            def spawn(*args, **kwargs):
                process = original_popen(*args, **kwargs)
                children.append(process)
                return process

            def write(path, *args, **kwargs):
                if path.name == "process.json":
                    raise OSError("metadata write failed")
                return original_write(path, *args, **kwargs)

            try:
                with mock.patch("bpy_runtime_acceptance.subprocess.Popen", side_effect=spawn), \
                     mock.patch("bpy_runtime_acceptance.Path.write_text", new=write), \
                     mock.patch("bpy_runtime_acceptance.sample_owned"):
                    with self.assertRaisesRegex(OSError, "metadata write failed"):
                        supervise(binary, root / "evidence", "runtime", self.source, 3)
                self.assertEqual(len(children), 1)
                self.assertIsNotNone(children[0].poll())
                self.assertTrue((root / "evidence/process-failure.json").is_file())
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
