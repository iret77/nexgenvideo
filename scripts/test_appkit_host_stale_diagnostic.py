import io
import json
from pathlib import Path
import subprocess
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock

import capture_render_review_test_diagnostic as diagnostic


class AppKitHostStaleDiagnosticTests(unittest.TestCase):
    def identity(self, pid, parent, executable, started="original start"):
        return dict(pid=pid, parentPID=parent, started=started, executable=executable)

    def setup_fixture(self, root):
        host = self.identity(43, 42, str(root / "built/NexGenVideoAppKitTestHost"))
        driver = self.identity(42, 40, "/selected/python3")
        folder = root / "hosted-suite"
        events = folder / "app-swift-testing/events.jsonl"
        events.parent.mkdir(parents=True)
        raw_events = b'{"kind":"event","payload":{"kind":"runStarted"}}\n{"unfinished":'
        events.write_bytes(raw_events)
        suite = {"phases": [{"name": "app-swift-testing", "status": "running",
                             "command": [host["executable"], "--event-stream-version", "0"]}]}
        raw_suite = (json.dumps(suite, indent=3) + "\n").encode()
        (folder / "suite.json").write_bytes(raw_suite)
        command = ["python3", str(Path(diagnostic.__file__).with_name("run_macos_tests.py")),
                   "--evidence", str(folder)]
        return host, driver, events, raw_events, raw_suite, command

    def test_capture_keeps_raw_events_and_command_stderr_and_checks_identity_before_each_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host, driver, events, original, suite, _ = self.setup_fixture(root)
            calls = []

            def command(argv, **kwargs):
                calls.append((argv, kwargs["timeout"]))
                kwargs["stdout"].write(b"original diagnostic stderr\xff\r\n")
                if argv[0] == "/usr/bin/sample":
                    Path(argv[-1]).write_bytes(b"original sample stack")
                return subprocess.CompletedProcess(argv, 0)

            with mock.patch.object(diagnostic, "process_tree", return_value=({42: driver, 43: host}, {43})) as tree, \
                 mock.patch.object(diagnostic.subprocess, "run", side_effect=command), \
                 mock.patch.object(diagnostic.os, "kill") as kill, mock.patch.object(diagnostic.os, "killpg") as killpg:
                output = root / "diagnostic"
                diagnostic.capture_appkit_host(host, 42, driver, output, suite, events, {})
            self.assertEqual(tree.call_count, 2)
            self.assertEqual([row[0][0] for row in calls], ["/usr/bin/sample", "/usr/bin/vmmap"])
            self.assertEqual([row[1] for row in calls], [15, 15])
            self.assertEqual(calls[0][0][2], "3")
            self.assertEqual((output / "events-original.jsonl").read_bytes(), original)
            self.assertEqual((output / "suite-original.json").read_bytes(), suite)
            self.assertEqual(events.read_bytes(), original)
            self.assertEqual((output / "sample-command.log").read_bytes(), b"original diagnostic stderr\xff\r\n")
            status = json.loads((root / "diagnostic-status.json").read_text())
            self.assertTrue(status["eventsSnapshot"]["completeAtOpenSize"])
            self.assertEqual(status["eventsSnapshot"]["capturedBytes"], len(original))
            kill.assert_not_called(); killpg.assert_not_called()

    def test_reused_or_unowned_pid_and_changed_root_are_never_sampled(self):
        for mismatch in ("reused-pid", "unowned-pid", "changed-root"):
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                host, driver, events, _, suite, _ = self.setup_fixture(root)
                observed_host = dict(host, started="new start") if mismatch == "reused-pid" else host
                observed_root = dict(driver, started="new root") if mismatch == "changed-root" else driver
                owned = set() if mismatch == "unowned-pid" else {43}
                with mock.patch.object(diagnostic, "process_tree", return_value=({42: observed_root, 43: observed_host}, owned)), \
                     mock.patch.object(diagnostic.subprocess, "run") as command:
                    diagnostic.capture_appkit_host(host, 42, driver, root / "diagnostic", suite, events, {})
                command.assert_not_called()

    def test_pid_is_rechecked_after_sample_before_vmmap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host, driver, events, _, suite, _ = self.setup_fixture(root)
            replaced = dict(host, started="reused during sample")
            with mock.patch.object(diagnostic, "process_tree", side_effect=[({42: driver, 43: host}, {43}),
                     ({42: driver, 43: replaced}, {43})]), \
                 mock.patch.object(diagnostic.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as command:
                diagnostic.capture_appkit_host(host, 42, driver, root / "diagnostic", suite, events, {})
            self.assertEqual(command.call_count, 1)
            self.assertEqual(command.call_args.args[0][0], "/usr/bin/sample")
            self.assertIn("identity changed", json.loads((root / "diagnostic-status.json").read_text())["vmmapError"])

    def test_native_byte_progress_delays_capture_and_trigger_is_once_without_suite_pid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host, driver, events, _, _, command = self.setup_fixture(root)
            now = [0.0]
            with mock.patch.object(diagnostic.time, "monotonic", side_effect=lambda: now[0]), \
                 mock.patch.object(diagnostic, "process_tree", return_value=({42: driver, 43: host}, {43})), \
                 mock.patch.object(diagnostic.threading, "Thread") as thread:
                watcher = diagnostic.AppKitHostStaleObservation(root, 42, command, driver, mock.Mock())
                now[0] = 1; watcher.tick()
                now[0] = 170; events.write_bytes(events.read_bytes() + b"next native record\n"); watcher.tick()
                now[0] = 349; watcher.tick(); thread.assert_not_called()
                now[0] = 350; watcher.tick()
                now[0] = 1000; watcher.tick()
                self.assertTrue(watcher.finish()["captureAttempted"])
                thread.assert_called_once()
                thread.return_value.start.assert_called_once()
                thread.return_value.join.assert_called_once()
                self.assertEqual(thread.call_args.kwargs["args"][0], host)

    def test_startup_root_exec_transition_is_bound_once_without_accepting_reused_root(self):
        for mismatch in (None, "started", "parentPID", "pid", "later-exec"):
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                host, driver, _, _, _, command = self.setup_fixture(root)
                launch = dict(driver, executable="/initial/python3-launcher")
                current = dict(driver)
                if mismatch in {"parentPID", "pid"}:
                    current[mismatch] += 1
                elif mismatch == "started":
                    current["started"] = "different process start"
                rows = {42: current, 43: host}
                now = [0.0]
                with mock.patch.object(diagnostic.time, "monotonic", side_effect=lambda: now[0]), \
                     mock.patch.object(diagnostic, "process_tree", side_effect=lambda _: (rows, {43})), \
                     mock.patch.object(diagnostic.threading, "Thread") as thread:
                    watcher = diagnostic.AppKitHostStaleObservation(root, 42, command, launch, mock.Mock())
                    now[0] = 1; watcher.tick()
                    if mismatch == "later-exec":
                        rows[42] = dict(driver, executable="/unrelated/later-executable")
                    now[0] = 181; watcher.tick()
                    if mismatch is None:
                        thread.assert_called_once()
                        self.assertEqual(thread.call_args.kwargs["args"][2], driver)
                        self.assertEqual(watcher.bound_root_identity, driver)
                        self.assertEqual(watcher.root_identity, launch)
                    else:
                        thread.assert_not_called()

    def test_malformed_suite_cannot_create_a_diagnostic_target(self):
        for suite in ([], 7, {"phases": None}, {"phases": [3]}):
            with self.subTest(suite=suite), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                _, driver, _, _, _, command = self.setup_fixture(root)
                (root / "hosted-suite/suite.json").write_text(json.dumps(suite))
                watcher = diagnostic.AppKitHostStaleObservation(root, 42, command, driver, mock.Mock())
                with mock.patch.object(diagnostic, "process_tree") as tree, \
                     mock.patch.object(diagnostic.threading, "Thread") as thread:
                    watcher.tick()
                tree.assert_not_called(); thread.assert_not_called()

    def test_worker_directory_failure_is_recorded_without_running_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host, driver, events, _, suite, _ = self.setup_fixture(root)
            with mock.patch.object(diagnostic.subprocess, "run") as command, \
                 mock.patch.object(diagnostic.Path, "mkdir", side_effect=PermissionError("fixture mkdir denied")):
                diagnostic.capture_appkit_host(host, 42, driver, root / "diagnostic", suite, events, {})
            command.assert_not_called()
            status = json.loads((root / "diagnostic-status.json").read_text())
            self.assertEqual(status["status"], "capture-unavailable-or-partial")
            self.assertIn("fixture mkdir denied", status["error"])

    def test_live_worker_status_write_failure_after_sample_is_joined_before_observer_closes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host, driver, events, _, suite, _ = self.setup_fixture(root)
            started, release, sampled = threading.Event(), threading.Event(), threading.Event()
            worker_errors, commands = [], []
            evidence = root / "evidence"
            status_path = evidence / "appkit-host-stale-status.json"
            original_write = Path.write_text

            def write(path, text, *args, **kwargs):
                if path == status_path and sampled.is_set():
                    raise PermissionError("status write denied after sample")
                return original_write(path, text, *args, **kwargs)

            def command(argv, **kwargs):
                commands.append(argv[0])
                if argv[0] == "/usr/bin/sample":
                    started.set()
                    if not release.wait(timeout=5):
                        raise RuntimeError("fixture shutdown did not release the live worker")
                    sampled.set()
                return subprocess.CompletedProcess(argv, 0)

            class Watcher:
                def __init__(self, folder, pid, command, identity, record):
                    def worker():
                        try:
                            diagnostic.capture_appkit_host(host, 42, driver, folder / "appkit-host-stale",
                                suite, events, {}, record)
                        except BaseException as error:
                            worker_errors.append(error)
                    self.worker = threading.Thread(target=worker)
                    self.worker.start()
                    if not started.wait(timeout=5):
                        release.set()
                        self.worker.join(timeout=5)
                        raise RuntimeError("fixture sample worker did not start")

                def tick(self):
                    pass

                def finish(self):
                    release.set()
                    self.worker.join(timeout=5)
                    if self.worker.is_alive():
                        raise RuntimeError("fixture worker failed to finish")
                    return {"captureAttempted": True}

            process = mock.Mock(pid=42)
            process.poll.return_value = None
            process.wait.return_value = 7
            key = SimpleNamespace(fd=9, fileobj=process.stdout)
            selector, registered = mock.Mock(), {9: key}
            selector.get_map.side_effect = lambda: registered
            selector.select.side_effect = lambda timeout: [(key, 1)] if registered else []
            selector.unregister.side_effect = lambda _: registered.clear()
            def read(_fd, _count):
                process.poll.return_value = 7
                return b""
            argv = ["diagnostic", "--evidence", str(evidence), "--log", str(root / "test.log"),
                    "--swift-testing-runs", "2", "--xctest-runs", "2", "--without-runloop-probe", "--", "original-command"]
            with mock.patch.object(diagnostic.sys, "argv", argv), mock.patch.object(diagnostic.sys, "platform", "linux"), \
                 mock.patch.object(diagnostic.subprocess, "Popen", return_value=process), \
                 mock.patch.object(diagnostic.subprocess, "run", side_effect=command), \
                 mock.patch.object(diagnostic.Path, "write_text", new=write), \
                 mock.patch.object(diagnostic.selectors, "DefaultSelector", return_value=selector), \
                 mock.patch.object(diagnostic.os, "read", side_effect=read), \
                 mock.patch.object(diagnostic, "process_tree", return_value=({42: driver, 43: host}, {43})), \
                 mock.patch.object(diagnostic, "AppKitHostStaleObservation", Watcher):
                code = diagnostic.main()
            self.assertEqual(code, 7)
            self.assertFalse(worker_errors)
            self.assertTrue(sampled.is_set())
            self.assertEqual(commands, ["/usr/bin/sample", "/usr/bin/vmmap"])
            records = [json.loads(row) for row in (evidence / "process-events.jsonl").read_text().splitlines()]
            self.assertTrue(any(row["event"] == "appkit-host-stale-status-write-unavailable" for row in records))

    def test_wrapper_preserves_original_merged_stderr_raw_bytes_and_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = b"original stderr\xff\x00\r\npartial original stderr"
            output = SimpleNamespace(buffer=io.BytesIO())
            process = mock.Mock(pid=42)
            process.poll.return_value = None
            process.wait.return_value = 7
            key = SimpleNamespace(fd=9, fileobj=process.stdout)
            selector = mock.Mock()
            registered = {9: key}
            selector.get_map.side_effect = lambda: registered
            selector.select.side_effect = lambda timeout: [(key, 1)] if registered else []
            selector.unregister.side_effect = lambda _: registered.clear()
            chunks = iter([original, b""])

            def read(_fd, _count):
                block = next(chunks)
                if not block: process.poll.return_value = 7
                return block

            observation = mock.Mock(probe_loads=[])
            argv = ["diagnostic", "--evidence", str(root / "evidence"), "--log", str(root / "test.log"),
                    "--swift-testing-runs", "2", "--xctest-runs", "2", "--without-runloop-probe", "--", "original-command"]
            with mock.patch.object(diagnostic.sys, "argv", argv), mock.patch.object(diagnostic.sys, "stdout", output), \
                 mock.patch.object(diagnostic.subprocess, "Popen", return_value=process) as popen, \
                 mock.patch.object(diagnostic.selectors, "DefaultSelector", return_value=selector), \
                 mock.patch.object(diagnostic.os, "read", side_effect=read), \
                 mock.patch.object(diagnostic, "process_tree", return_value=({}, set())), \
                 mock.patch.object(diagnostic, "TestProcessObservation", return_value=observation):
                code = diagnostic.main()
            self.assertEqual(code, 7)
            popen.assert_called_once()
            self.assertEqual(popen.call_args.args[0], ["original-command"])
            self.assertEqual(output.buffer.getvalue(), original)
            self.assertEqual((root / "test.log").read_bytes(), original)
