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

from bpy_runtime_acceptance import capture_open_logs, collect_hangs, diagnostic_error, stop_open_capture, supervise, verify_crash, verify_storage_scope


class StorageScopeProofTests(unittest.TestCase):
    binary = Path("/fixture/NexGenVideo.app/Contents/MacOS/NexGenVideo")

    def events(self, stale=True):
        session, owner = str(uuid.uuid4()), str(uuid.uuid4())
        digest = "a" * 64
        common = f"session={session} owner={owner}"
        messages = [
            (456, f"open.prepared {common} pid=456 start=42"),
            (123, f"open.preparation session={session} servicePID=456 serviceStart=42"),
            (123, f"bookmark.resolve id={session} attempt=1 stale=false file=true pathMatches=true sha256={digest} volumeMatch=equal"),
            (456, f"open.beforeScope {common} pid=456 errno=1"),
            (456, f"open.check {common} pid=456 start=42 stale={str(stale).lower()} file=true pathMatches=true sha256={digest} volumeMatch=equal"),
            (456, f"open.validated {common} pid=456 start=42 sha256={digest}"),
            (456, f"open.result {common} ok=true"),
        ]
        return [dict(processID=pid, eventMessage=message, machTimestamp=index + 1,
                     subsystem="de.h5ventures.nexgenvideo" + (".bpy-service" if pid == 456 else ""),
                     category="open-diagnostic" if pid == 456 else "bpy-open",
                     processImagePath=(str(self.binary) if pid == 123 else
                         "/fixture/NexGenVideo.app/Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/MacOS/NexGenVideoBpyService"))
                for index, (pid, message) in enumerate(messages)]

    def check(self, events):
        return verify_storage_scope("Filtering the log data using predicate\n" +
            "\n".join(json.dumps(event) for event in events), dict(pid=123), self.binary)

    def test_actual_boundary_evidence_accepts_either_receiver_freshness(self):
        for stale in (False, True):
            proof = self.check(self.events(stale))
            self.assertEqual(proof["receiverStale"], stale)
            self.assertEqual(proof["preScopeErrno"], 1)

    def test_missing_duplicated_foreign_or_reordered_events_cannot_prove_the_boundary(self):
        for index in range(7):
            for mutation in ("missing", "duplicate", "pid", "image", "category", "time"):
                with self.subTest(index=index, mutation=mutation):
                    events = self.events()
                    if mutation == "missing":
                        del events[index]
                    elif mutation == "duplicate":
                        events.append(dict(events[index]))
                    elif mutation == "pid":
                        events[index]["processID"] = 999
                    elif mutation == "image":
                        events[index]["processImagePath"] = "/foreign/NexGenVideo"
                    elif mutation == "category":
                        events[index]["category"] = "foreign"
                    else:
                        events[index]["machTimestamp"] = events[(index + 1) % len(events)]["machTimestamp"]
                    with self.assertRaises((AssertionError, KeyError, ValueError)):
                        self.check(events)

    def test_preexisting_access_wrong_identity_or_failed_open_is_rejected(self):
        for index, old, new in ((3, "errno=1", "errno=0"), (3, "errno=1", "errno=2"),
                               (4, "file=true", "file=false"), (4, "pathMatches=true", "pathMatches=false"),
                               (4, "volumeMatch=equal", "volumeMatch=different"),
                               (5, "sha256=" + "a" * 64, "sha256=" + "b" * 64),
                               (5, "start=42", "start=43"), (6, "ok=true", "ok=false")):
            with self.subTest(index=index, new=new):
                events = self.events()
                events[index]["eventMessage"] = events[index]["eventMessage"].replace(old, new)
                with self.assertRaises(AssertionError):
                    self.check(events)

    def test_host_refresh_must_finish_fresh_and_malformed_capture_is_not_ignored(self):
        events = self.events()
        refresh = dict(events[2])
        events[2]["eventMessage"] = events[2]["eventMessage"].replace("stale=false", "stale=true")
        refresh["eventMessage"] = refresh["eventMessage"].replace("attempt=1", "attempt=2")
        events.insert(3, refresh)
        for index, event in enumerate(events):
            event["machTimestamp"] = index + 1
        self.check(events)
        for text in ("malformed", "{bad json}"):
            with self.assertRaises(ValueError):
                verify_storage_scope(text, dict(pid=123), self.binary)


class OpenCaptureTests(unittest.TestCase):
    def test_isolated_runtime_entrypoint_keeps_working_without_local_imports(self):
        script = Path(__file__).with_name("bpy_runtime_acceptance.py")
        result = subprocess.run([sys.executable, "-I", str(script), "--help"],
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_probe_failure_is_preserved_and_capture_is_reaped(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            process = mock.Mock(pid=123, returncode=-signal.SIGTERM)
            process.poll.side_effect = [None, None, None, -signal.SIGTERM]
            with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                 mock.patch("bpy_runtime_acceptance.time.sleep"), \
                 mock.patch("bpy_runtime_acceptance.stop_open_capture") as stop:
                with self.assertRaisesRegex(AssertionError, "original probe failure"):
                    with capture_open_logs(output):
                        raise AssertionError("original probe failure")
            stop.assert_called_once_with(process)
            receipt = json.loads((output / "open-capture.json").read_text())
            self.assertTrue(receipt["reaped"])
            self.assertFalse(receipt["stoppedEarly"])

    def test_early_capture_exit_does_not_pass_as_complete(self):
        for during_probe in (False, True):
            with self.subTest(during_probe=during_probe), tempfile.TemporaryDirectory() as temporary:
                process = mock.Mock(pid=123, returncode=1)
                process.poll.side_effect = [None if during_probe else 1, None if during_probe else 1, 1, 1]
                with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                     mock.patch("bpy_runtime_acceptance.time.sleep"), \
                     mock.patch("bpy_runtime_acceptance.stop_open_capture"):
                    with self.assertRaisesRegex(AssertionError, "stream"):
                        with capture_open_logs(Path(temporary)):
                            self.assertTrue(during_probe)
                receipt = json.loads((Path(temporary) / "open-capture.json").read_text())
                self.assertTrue(receipt["stoppedEarly"])

    def test_cleanup_escalates_only_the_owned_process_group(self):
        process = mock.Mock(pid=123)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("owned log", 5), -signal.SIGKILL]
        with mock.patch("bpy_runtime_acceptance.subprocess.run") as signal_process:
            stop_open_capture(process)
        self.assertEqual([call.args[0] for call in signal_process.call_args_list], [
            ["/usr/bin/sudo", "-n", "/bin/kill", "-TERM", "--", "-123"],
            ["/usr/bin/sudo", "-n", "/bin/kill", "-KILL", "--", "-123"],
        ])
        self.assertEqual(process.wait.call_count, 2)

    def test_cancellation_during_cleanup_is_recorded_after_reaping(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = mock.Mock(pid=123, returncode=-signal.SIGTERM)
            process.poll.side_effect = [None, None, None, -signal.SIGTERM]
            original_handler = signal.getsignal(signal.SIGTERM)

            def stop(_process):
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)

            with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                 mock.patch("bpy_runtime_acceptance.time.sleep"), \
                 mock.patch("bpy_runtime_acceptance.stop_open_capture", side_effect=stop):
                with self.assertRaisesRegex(InterruptedError, "cleanup"):
                    with capture_open_logs(Path(temporary)):
                        pass
            self.assertEqual(signal.getsignal(signal.SIGTERM), original_handler)
            receipt = json.loads((Path(temporary) / "open-capture.json").read_text())
            self.assertEqual(receipt["cancelled"], [signal.SIGTERM])
            self.assertTrue(receipt["reaped"])

    def test_cleanup_failure_keeps_the_original_error_and_records_both_states(self):
        for body_fails in (False, True):
            with self.subTest(body_fails=body_fails), tempfile.TemporaryDirectory() as temporary:
                process = mock.Mock(pid=123, returncode=None)
                process.poll.return_value = None
                with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                     mock.patch("bpy_runtime_acceptance.time.sleep"), \
                     mock.patch("bpy_runtime_acceptance.stop_open_capture", side_effect=RuntimeError("capture stuck")):
                    with self.assertRaisesRegex(AssertionError, "original failure" if body_fails else "cleanup failed"):
                        with capture_open_logs(Path(temporary)):
                            if body_fails:
                                raise AssertionError("original failure")
                receipt = json.loads((Path(temporary) / "open-capture.json").read_text())
                self.assertFalse(receipt["reaped"])
                self.assertIn("capture stuck", receipt["cleanupErrors"][0])

    def test_receipt_write_failure_does_not_replace_the_probe_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = mock.Mock(pid=123, returncode=0)
            process.poll.side_effect = [None, None, None, 0]
            with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                 mock.patch("bpy_runtime_acceptance.time.sleep"), \
                 mock.patch("bpy_runtime_acceptance.stop_open_capture"), \
                 mock.patch("bpy_runtime_acceptance.Path.write_text", side_effect=OSError("disk failure")):
                with self.assertRaisesRegex(AssertionError, "original failure"):
                    with capture_open_logs(Path(temporary)):
                        raise AssertionError("original failure")

    def test_exit_race_and_signal_timeout_still_wait_and_escalate(self):
        for signal_timeout in (False, True):
            with self.subTest(signal_timeout=signal_timeout):
                process = mock.Mock(pid=123)
                process.poll.return_value = None
                process.wait.side_effect = ([subprocess.TimeoutExpired("owned log", 5), 0]
                                            if signal_timeout else [0])
                with mock.patch("bpy_runtime_acceptance.subprocess.run") as kill:
                    kill.side_effect = ([subprocess.TimeoutExpired("signal", 5), mock.Mock(returncode=1)]
                                        if signal_timeout else [mock.Mock(returncode=1)])
                    stop_open_capture(process)
                self.assertEqual(process.wait.call_count, 2 if signal_timeout else 1)
                self.assertTrue(all(call.kwargs["check"] is False for call in kill.call_args_list))

    def test_final_log_delivery_is_drained_before_capture_is_stopped(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = mock.Mock(pid=123, returncode=-signal.SIGTERM)
            process.poll.side_effect = [None, None, None, -signal.SIGTERM]
            events = []
            with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                 mock.patch("bpy_runtime_acceptance.time.sleep", side_effect=lambda delay: events.append(delay)), \
                 mock.patch("bpy_runtime_acceptance.stop_open_capture", side_effect=lambda _: events.append("stop")):
                with capture_open_logs(Path(temporary)):
                    events.append("probe")
            self.assertEqual(events, [0.5, "probe", 2, "stop"])


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
