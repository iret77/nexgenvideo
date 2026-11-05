import unittest
from pathlib import Path
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from unittest.mock import Mock, patch

from app_termination_acceptance import MODES, capture_pid, main, run_case, source_identity, verify


class TerminationEvidenceTests(unittest.TestCase):
    source = "a" * 40

    def events(self, names):
        return [dict(event=name, pid=123, sourceSHA=self.source, uptime=float(index * 4))
                for index, name in enumerate(names)]

    def completed(self):
        return self.events(["boot", "request-accepted", "should-terminate", "reply-later", "cleanup-start", "cleanup-resumed",
                            "cleanup-done", "will-terminate", "process-exit"])

    def test_requires_normal_exit_after_completed_async_cleanup(self):
        events = self.completed()
        verify("task", events, 123, self.source, 0)
        with self.assertRaisesRegex(AssertionError, "exit normally"):
            verify("task", events, 123, self.source, -15)
        for missing in ("cleanup-resumed", "cleanup-done", "process-exit"):
            with self.subTest(missing=missing), self.assertRaisesRegex(AssertionError, "proof"):
                verify("task", [event for event in events if event["event"] != missing], 123, self.source, 0)

    def test_exit_before_cleanup_is_rejected(self):
        events = self.completed()
        events[-1], events[-3] = events[-3], events[-1]
        with self.assertRaisesRegex(AssertionError, "order"):
            verify("task", events, 123, self.source, 0)

    def test_cancel_requires_survival_and_refuses_a_committed_restart(self):
        events = self.events(["boot", "request-accepted", "should-terminate", "reply-later", "cancelled", "alive-after-cancel",
                              "should-terminate", "reply-later", "cleanup-start", "cleanup-resumed", "cleanup-done",
                              "will-terminate", "process-exit"])
        verify("relaunch-cancel", events, 123, self.source, 0)
        with self.assertRaisesRegex(AssertionError, "unapproved restart"):
            verify("relaunch-cancel", events + self.events(["relaunch-commit"]), 123, self.source, 0)
        events[5]["uptime"] = events[4]["uptime"] + 0.1
        with self.assertRaisesRegex(AssertionError, "former forced-exit"):
            verify("cancel", events, 123, self.source, 0)

    def test_control_requires_a_real_wait_before_cleanup(self):
        events = self.events(["boot", "should-terminate"])
        verify("raw-control", events, 123, self.source, None, True)
        with self.assertRaisesRegex(AssertionError, "did not reproduce"):
            verify("raw-control", events, 123, self.source, 0)
        with self.assertRaisesRegex(AssertionError, "entered async cleanup"):
            verify("raw-control", events + self.events(["cleanup-start"]), 123, self.source, None, True)

    def test_foreign_source_or_process_is_rejected(self):
        events = self.completed()
        with self.assertRaisesRegex(AssertionError, "foreign-source"):
            verify("task", events, 123, "b" * 40, 0)
        foreign = dict(events[-1], pid=456)
        with self.assertRaisesRegex(AssertionError, "second application"):
            verify("task", events + [foreign], 123, self.source, 0)

    def test_retained_source_is_explicit_and_never_rewrites_the_harness(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ, {"GITHUB_SHA": "b" * 40}):
            app = Path(root) / "App.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"NGVSourceCommit": self.source}))
            self.assertEqual(source_identity(app, self.source), (self.source, "b" * 40))
            self.assertEqual(os.environ["GITHUB_SHA"], "b" * 40)
            with self.assertRaisesRegex(AssertionError, "App source differs"):
                source_identity(app)
            for source in ("", "a" * 39, "A" * 40, "a" * 41):
                with self.subTest(source=source), self.assertRaisesRegex(AssertionError, "source binding"):
                    source_identity(app, source)

    def test_cli_foreign_app_source_fails_before_any_native_process(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / "App.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/NexGenVideo").touch()
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"NGVSourceCommit": "c" * 40}))
            output = Path(root) / "output"
            args = ["termination", str(app), "--output", str(output), "--product-source", self.source]
            with patch.object(sys, "argv", args), patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "GITHUB_SHA": "b" * 40}), \
                    patch("app_termination_acceptance.run_case") as run:
                with self.assertRaisesRegex(AssertionError, "App source differs"):
                    main()
                run.assert_not_called()
                self.assertFalse(output.exists())

    def test_cli_default_same_source_keeps_all_eight_modes(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / "App.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/NexGenVideo").touch()
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"NGVSourceCommit": self.source}))
            output = Path(root) / "output"
            with patch.object(sys, "argv", ["termination", str(app), "--output", str(output)]), \
                    patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "GITHUB_SHA": self.source}), \
                    patch("app_termination_acceptance.run_case") as run:
                main()
                self.assertEqual([call.args[2] for call in run.call_args_list], list(MODES))
                self.assertTrue(all(call.args[3] == self.source for call in run.call_args_list))

    def test_failed_source_guard_preserves_the_actual_process_observation(self):
        process = Mock(pid=123, returncode=0)
        process.wait.return_value = 0
        process.poll.return_value = 0
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            events = self.completed()

            def started(*args, **kwargs):
                (directory / "task/events.jsonl").write_text("\n".join(json.dumps(event) for event in events) + "\n")
                return process

            with patch("app_termination_acceptance.subprocess.Popen", side_effect=started), \
                    patch.dict(os.environ, {"GITHUB_SHA": "b" * 40}):
                with self.assertRaisesRegex(AssertionError, "foreign-source"):
                    run_case(directory / "App.app/Contents/MacOS/NexGenVideo", directory, "task", "b" * 40)
            observation = json.loads((directory / "task/observation.json").read_text())
            self.assertEqual(observation["returncode"], 0)
            self.assertIs(observation["timedOut"], False)
            self.assertEqual(observation["events"], events)
            self.assertEqual(observation["sourceSHA"], "b" * 40)
            self.assertEqual(observation["harnessSourceSHA"], "b" * 40)
            self.assertFalse((directory / "task/result.json").exists())

    def test_duplicate_quit_must_be_coalesced_and_native_reentry_must_return(self):
        events = self.events(["boot", "request-accepted", "should-terminate", "reply-later", "duplicate-rejected", "duplicate-rejected",
                              "cleanup-start", "native-duplicate", "should-terminate",
                              "reply-cancel", "native-duplicate-returned", "cleanup-resumed", "cleanup-done",
                              "will-terminate", "process-exit"])
        verify("duplicate", events, 123, self.source, 0)
        with self.assertRaisesRegex(AssertionError, "re-entry did not return"):
            verify("duplicate", [event for event in events if event["event"] != "native-duplicate-returned"],
                   123, self.source, 0)
        events[4]["event"] = "duplicate-accepted"
        with self.assertRaisesRegex(AssertionError, "accepted"):
            verify("duplicate", events, 123, self.source, 0)

    def test_native_entry_coalescing_requires_complete_cleanup(self):
        events = self.events(["boot", "request-accepted", "duplicate-rejected", "should-terminate", "reply-later",
                              "native-duplicate", "native-duplicate-returned", "duplicate-rejected", "cleanup-start",
                              "cleanup-resumed", "cleanup-done", "will-terminate", "process-exit"])
        verify("duplicate", events, 123, self.source, 0)
        failed = self.events(["boot", "request-accepted", "duplicate-rejected", "should-terminate", "reply-later",
                              "native-duplicate", "will-terminate", "process-exit"])
        with self.assertRaisesRegex(AssertionError, "proof"):
            verify("duplicate", failed, 123, self.source, 0)

    def test_sample_uses_one_owned_pid_and_bounded_symbolication_time(self):
        with tempfile.TemporaryDirectory() as root, patch("app_termination_acceptance.subprocess.run") as run:
            capture_pid(123, Path(root), "sample")
            self.assertEqual(run.call_args.args[0], ["/usr/bin/sample", "123", "3", "-mayDie", "-file", str(Path(root) / "sample.log")])
            self.assertGreater(run.call_args.kwargs["timeout"], 3)
            self.assertLessEqual(run.call_args.kwargs["timeout"], 60)
            self.assertTrue(run.call_args.kwargs["check"])

    def test_failed_capture_is_not_retried_and_original_process_is_reaped(self):
        process = Mock(pid=123, returncode=None)
        process.wait.side_effect = [subprocess.TimeoutExpired("app", 10), -9]
        process.poll.return_value = None
        with tempfile.TemporaryDirectory() as root, \
                patch("app_termination_acceptance.subprocess.Popen", return_value=process), \
                patch("app_termination_acceptance.capture", side_effect=subprocess.TimeoutExpired("sample", 30)) as capture:
            with self.assertRaises(subprocess.TimeoutExpired):
                run_case(Path(root) / "app", Path(root), "raw-control", self.source)
            capture.assert_called_once()
            process.kill.assert_called_once()
            self.assertEqual(process.wait.call_count, 2)
            self.assertEqual(process.wait.call_args.kwargs["timeout"], 5)
            self.assertTrue((Path(root) / "raw-control/failure.json").is_file())

    def test_relaunch_requires_cleanup_commit_normal_exit_and_one_exact_child(self):
        events = self.events(["boot", "should-terminate", "reply-later", "cleanup-start", "cleanup-resumed",
                              "cleanup-done", "will-terminate", "relaunch-commit", "reopener-started", "process-exit"])
        events[8]["childPID"] = 456
        child = self.events(["boot", "reopened", "should-terminate", "reply-later", "cleanup-start",
                             "cleanup-resumed", "cleanup-done", "will-terminate", "process-exit"])
        for event in child:
            event.update(pid=456, uptime=event["uptime"] + 50)
        events += child
        verify("relaunch", events, 123, self.source, 0)
        import copy
        mutations = []
        value = copy.deepcopy(events); value[6], value[7] = value[7], value[6]; mutations.append(value)
        value = copy.deepcopy(events); value[8], value[9] = value[9], value[8]; mutations.append(value)
        value = copy.deepcopy(events); value[11]["uptime"] = 0; mutations.append(value)
        value = copy.deepcopy(events); value[8]["childPID"] = 123; mutations.append(value)
        value = copy.deepcopy(events); value.append(dict(value[-1], pid=789)); mutations.append(value)
        value = copy.deepcopy(events); value.append(dict(value[11])); mutations.append(value)
        mutations.append(copy.deepcopy(events[:10]))
        value = copy.deepcopy(events); value.append(dict(value[8], event="reopener-failed")); mutations.append(value)
        for index, value in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(AssertionError):
                verify("relaunch", value, 123, self.source, 0)


if __name__ == "__main__":
    unittest.main()
