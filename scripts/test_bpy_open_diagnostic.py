import json
from contextlib import ExitStack
from pathlib import Path
import signal
import tempfile
import time
import unittest
from unittest import mock

from bpy_open_diagnostic import child_samples, command, observe_files, owned_report, read_regular, run, sanitized_lease, stop_owned, stop_samples, unified_control, verdict


class OriginalObservationTests(unittest.TestCase):
    def test_sample_attribution_requires_exact_parent_and_executable(self):
        rows = b" 321 123 100 Fri Oct 23 20:52:36 2026 /usr/bin/sample\n 322 456 100 Fri Oct 23 20:52:36 2026 /usr/bin/sample\n 323 123 100 Fri Oct 23 20:52:36 2026 /tmp/sample\n"
        self.assertEqual(child_samples(rows, 123), {321: "Fri Oct 23 20:52:36 2026"})

    def test_sample_cleanup_never_signals_another_group_or_reused_identity(self):
        samples = {321: "Fri Oct 23 20:52:36 2026"}
        with mock.patch("bpy_open_diagnostic.os.getpgid", return_value=999), \
                mock.patch("bpy_open_diagnostic.os.kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "identity changed"):
                stop_samples(samples, 123)
            kill.assert_not_called()
        with mock.patch("bpy_open_diagnostic.os.getpgid", return_value=123), \
                mock.patch("bpy_open_diagnostic.subprocess.run", return_value=mock.Mock(stdout=b"another process")), \
                mock.patch("bpy_open_diagnostic.os.kill") as kill:
            with self.assertRaisesRegex(RuntimeError, "identity changed"):
                stop_samples(samples, 123)
            kill.assert_not_called()

    def test_only_fresh_owned_regular_reports_are_eligible(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "hang.json"
            raw = b'{"processID":123,"sampleStatus":"pending"}'
            path.write_bytes(raw)
            self.assertEqual(owned_report(path, 123, time.time() - 1), raw)
            self.assertIsNone(owned_report(path, 456, time.time() - 1))
            self.assertIsNone(owned_report(path, 123, time.time() + 1))
            link = root / "link.json"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                owned_report(link, 123, 0)
            with self.assertRaises(ValueError):
                read_regular(path, 2)
            with self.assertRaises(ValueError):
                read_regular(root, 100)

    def test_later_report_and_original_sample_replace_pending_without_losing_original(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            logs = home / "Library/Logs/NexGenVideo"
            logs.mkdir(parents=True)
            output = home / "output"
            output.mkdir()
            path = logs / "owned-main-thread-hang.json"
            pending = b'{"processID":123,"sampleStatus":"pending","sampleFilenameIfAvailable":"owned.sample.txt"}'
            completed = pending.replace(b'"pending"', b'"completed"')
            path.write_bytes(pending)
            seen = {}
            started = time.time() - 1
            with mock.patch("bpy_open_diagnostic.Path.home", return_value=home):
                observe_files(output, 123, started, seen)
                self.assertEqual((output / path.name).read_bytes(), pending)
                path.write_bytes(completed)
                (logs / "owned.sample.txt").write_bytes(b"actual original sample")
                observe_files(output, 123, started, seen)
                observe_files(output, 123, started, seen)
            self.assertEqual((output / path.name).read_bytes(), completed)
            self.assertEqual((output / "owned.sample.txt").read_bytes(), b"actual original sample")
            originals = [p.read_bytes() for p in output.glob("*-owned-main-thread-hang.json")]
            self.assertCountEqual(originals, [pending, completed])

    def test_report_cannot_select_a_sample_outside_its_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            logs = home / "Library/Logs/NexGenVideo"
            logs.mkdir(parents=True)
            output = home / "output"
            output.mkdir()
            target = home / "secret.sample.txt"
            target.write_text("not evidence")
            for name in (str(target), "../../secret.sample.txt", "linked.sample.txt"):
                (logs / "owned-main-thread-hang.json").write_text(json.dumps(
                    dict(processID=123, sampleFilenameIfAvailable=name)))
                if name == "linked.sample.txt":
                    (logs / name).symlink_to(target)
                with mock.patch("bpy_open_diagnostic.Path.home", return_value=home):
                    observe_files(output, 123, 0, {})
            self.assertFalse(list(output.glob("*.sample.txt")))

    def test_storage_observation_never_retains_capability_bookmark_or_foreign_owner(self):
        value = dict(ownerPID=123, servicePID=456, unknown="private", lease=dict(
            mountPath="/fixture/mount", bookmark="sensitive-capability", device=1, capacityBytes=2))
        self.assertIsNone(sanitized_lease(json.dumps(value), 999))
        result = sanitized_lease(json.dumps(value), 123)
        self.assertEqual(result["servicePID"], 456)
        self.assertEqual(result["lease"]["mountPath"], "/fixture/mount")
        self.assertNotIn("sensitive-capability", json.dumps(result))
        self.assertNotIn("unknown", result)

    def test_diagnostic_never_grants_runtime_acceptance(self):
        for code in (None, 0, 1, -9, 124):
            for complete in (False, True):
                result = verdict(code, dict(filesystem=complete, unified=True), False, host_pid=123 if code is not None else None)
                self.assertFalse(result["runtimeAcceptance"])
                self.assertEqual(result["instrumentsComplete"], complete)
                self.assertEqual(result["probeVerdict"], "NOT_RUN" if code is None else "NOT_REPRODUCED" if code == 0 else "FAIL")
        self.assertEqual(verdict(0, dict(ok=True), True, host_pid=123)["probeVerdict"], "FAIL")
        self.assertEqual(verdict(-15, dict(ok=False), False, host_pid=123,
                                 observer_terminated=True)["probeVerdict"], "INCONCLUSIVE_OBSERVER_TERMINATED")

    def test_unified_positive_control_requires_exact_json_process_identity(self):
        line = lambda pid, message: json.dumps(dict(processID=pid, eventMessage=message)).encode() + b"\n"
        self.assertFalse(unified_control(line(1234, "main-thread watchdog started"), 123))
        self.assertFalse(unified_control(line(123, "other event"), 123))
        self.assertTrue(unified_control(b"header\n" + line(123, "main-thread watchdog started"), 123))


class DiagnosticLifecycleTests(unittest.TestCase):
    def exercise(self, scenario):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as patches:
            root = Path(temporary)
            output = root / "evidence"
            probe_output = root / "original-temp/evidence/host-crash-before-authorization"
            processes = []
            handlers = {}
            ticks = 0

            def start(args, **kwargs):
                process = mock.Mock(pid=100 + len(processes), returncode=None)
                process.poll.side_effect = lambda: process.returncode
                process.wait.side_effect = lambda timeout: process.returncode
                processes.append((args, process))
                if "fs_usage" in " ".join(args) and scenario == "trace-start-failure":
                    process.returncode = 1
                if "bpy_runtime_acceptance.py" in " ".join(args):
                    self.assertEqual(args[args.index("--output") + 1], str(probe_output))
                    self.assertEqual(kwargs["env"]["EXPECTED_SOURCE"], "a" * 40)
                    self.assertEqual(kwargs["env"]["NGV_BPY_DIAGNOSTIC_DEADLINE"], args[args.index("--deadline") + 1])
                    probe_output.mkdir(parents=True)
                    (probe_output / "process.json").write_text(json.dumps(
                        dict(pid=123, sourceSHA="a" * 40, mode="before-authorization")))
                    if scenario == "completed":
                        process.returncode = 0
                return process

            def stop(process, privileged=False, signalled=False):
                if scenario == "cleanup-signal":
                    handlers[signal.SIGTERM](signal.SIGTERM, None)
                if process.returncode is None:
                    process.returncode = -15
                return process.returncode

            def sleep(seconds):
                nonlocal ticks
                if seconds == 0.5 and scenario in ("loop-failure", "cleanup-signal"):
                    raise RuntimeError("observer failure")
                if seconds == 0.5 and scenario == "trace-exit-during-probe":
                    ticks += 1
                    if ticks == 1:
                        processes[0][1].returncode = 1
                    else:
                        processes[-1][1].returncode = 1

            patches.enter_context(mock.patch("bpy_open_diagnostic.subprocess.Popen", side_effect=start))
            patches.enter_context(mock.patch("bpy_open_diagnostic.subprocess.run", return_value=mock.Mock(returncode=0, stdout=b"")))
            patches.enter_context(mock.patch("bpy_open_diagnostic.time.sleep", side_effect=sleep))
            patches.enter_context(mock.patch("bpy_open_diagnostic.signal.signal", side_effect=lambda sig, handler: handlers.update({sig: handler})))
            patches.enter_context(mock.patch("bpy_open_diagnostic.os.killpg"))
            signaler = patches.enter_context(mock.patch("bpy_open_diagnostic.signal_owned"))
            stopper = patches.enter_context(mock.patch("bpy_open_diagnostic.stop_owned", side_effect=stop))
            sample_cleanup = patches.enter_context(mock.patch("bpy_open_diagnostic.stop_samples", return_value=[]))
            patches.enter_context(mock.patch("bpy_open_diagnostic.observe_files"))
            patches.enter_context(mock.patch("bpy_open_diagnostic.command", return_value=0))
            self.assertEqual(run(root / "app", output, "a" * 40, probe_output), 1)
            value = json.loads((output / "evidence-verdict.json").read_text())
            self.assertEqual(value["probeOutput"], str(probe_output))
            return value, processes, signaler.call_args_list, stopper.call_count, sample_cleanup.call_count

    def test_occupied_probe_output_refuses_before_any_process_launch(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch("bpy_open_diagnostic.subprocess.Popen") as popen:
            root = Path(temporary)
            probe_output = root / "probe"
            probe_output.mkdir()
            with self.assertRaisesRegex(ValueError, "occupied original"):
                run(root / "app", root / "diagnostic", "a" * 40, probe_output)
            popen.assert_not_called()

    def test_trace_failure_does_not_launch_or_claim_a_failed_product(self):
        value, processes, _, stops, _ = self.exercise("trace-start-failure")
        self.assertEqual(len(processes), 2)
        self.assertEqual(value["probeVerdict"], "NOT_RUN")
        self.assertEqual(stops, 2)

    def test_successful_probe_is_still_diagnostic_only(self):
        value, _, _, _, samples = self.exercise("completed")
        self.assertEqual(value["probeVerdict"], "NOT_REPRODUCED")
        self.assertFalse(value["runtimeAcceptance"])
        self.assertEqual(samples, 1)

    def test_observer_failure_stops_owned_processes_without_claiming_reproduction(self):
        value, processes, signals, stops, samples = self.exercise("loop-failure")
        self.assertEqual(value["probeVerdict"], "INCONCLUSIVE_OBSERVER_TERMINATED")
        self.assertEqual(stops, 3)
        self.assertEqual(samples, 1)
        self.assertIn(mock.call(processes[-1][1], signal.SIGTERM, False), signals)
        self.assertIn(mock.call(processes[0][1], signal.SIGTERM, True), signals)

    def test_second_cancellation_does_not_skip_cleanup_or_verdict(self):
        value, _, _, stops, samples = self.exercise("cleanup-signal")
        self.assertEqual(stops, 3)
        self.assertEqual(samples, 1)
        self.assertTrue(any("signal during cleanup" in error for error in value["errors"]))

    def test_trace_loss_does_not_interrupt_the_probe_or_claim_complete_instruments(self):
        value, _, _, _, _ = self.exercise("trace-exit-during-probe")
        self.assertEqual(value["probeVerdict"], "FAIL")
        self.assertFalse(value["observerTerminated"])
        self.assertFalse(value["instrumentControls"]["filesystem"])
        self.assertIsNotNone(value["traceStoppedAt"])

    def test_privileged_timeout_signals_the_owned_group_and_reaps_it(self):
        process = mock.Mock(pid=321, returncode=-15)
        process.poll.return_value = None
        with mock.patch("bpy_open_diagnostic.subprocess.run") as native_kill:
            stop_owned(process, True)
        self.assertEqual(native_kill.call_args.args[0], ["sudo", "-n", "/bin/kill", "-TERM", "--", "-321"])
        process.wait.assert_called_once_with(timeout=5)

    def test_supplementary_command_timeout_uses_group_cleanup(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch("bpy_open_diagnostic.subprocess.Popen") as popen, \
                mock.patch("bpy_open_diagnostic.stop_owned") as stop:
            popen.return_value.wait.side_effect = subprocess.TimeoutExpired("log", 2)
            self.assertEqual(command(["sudo", "-n", "log", "show"], Path(temporary) / "log", 2), 124)
            stop.assert_called_once_with(popen.return_value, privileged=True)


if __name__ == "__main__":
    unittest.main()
