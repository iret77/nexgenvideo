import json
import os
from pathlib import Path
import subprocess
import signal
import tempfile
import unittest
from unittest import mock

import capture_render_review_test_diagnostic as diagnostic


class RunloopProbePreparationTests(unittest.TestCase):
    def test_unavailable_preparation_preserves_original_single_test_command(self):
        for failure in ("foreign-dyld", "compile", "architecture", "thin-arm64", "thin-arm64e", "unknown-architecture", "manifest", "timeout", "missing-loader", "wrong-pid", "malformed-loader", "null-executable", "numeric-executable", "list-executable", "object-executable"):
            with self.subTest(failure=failure):
                receipt, overrides, calls, command = self.prepare(failure)
                self.assertEqual(receipt["status"], "unavailable")
                self.assertEqual(overrides, {})
                self.assertNotIn("actualCommand", receipt)
                self.assertNotIn("swiftExecutable", receipt)
                self.assertEqual(command, ["swift", "test", "--cache-path", "dependency cache", "--skip-build"])
                self.assertLessEqual(sum(call[0] == "manifest" for call in calls), 1)
                self.assertFalse(any("test" in call[1][1:] for call in calls))
                if failure == "foreign-dyld":
                    self.assertEqual(calls, [])
                    self.assertEqual(os.environ.get("DYLD_INSERT_LIBRARIES"), self.original_dyld)

    def test_manifest_timeout_cleans_only_its_own_new_process_group(self):
        receipt, overrides, calls, _ = self.prepare("timeout")
        self.assertEqual(overrides, {})
        self.assertEqual([call[1] for call in calls if call[0] == "killpg"],
                         [[4242, signal.SIGTERM], [4242, signal.SIGKILL]])
        self.assertTrue(next(call[2] for call in calls if call[0] == "manifest"))
        self.assertEqual([row["signal"] for row in receipt["manifestTimeoutCleanup"]],
                         [int(signal.SIGTERM), int(signal.SIGKILL)])

    def test_manifest_cleanup_waits_are_bounded_even_if_root_does_not_exit(self):
        process = mock.Mock(pid=4242)
        process.wait.side_effect = subprocess.TimeoutExpired("manifest", 3)
        with mock.patch.object(diagnostic.os, "killpg") as killpg:
            records = diagnostic.stop_manifest_process_group(process)
        self.assertEqual(killpg.call_args_list,
                         [mock.call(4242, signal.SIGTERM), mock.call(4242, signal.SIGKILL)])
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=3), mock.call(timeout=3)])
        self.assertEqual([row["rootWait"] for row in records], ["timed-out", "timed-out"])

    def test_prepared_probe_requires_actual_manifest_load_and_rebinds_test_argv(self):
        receipt, overrides, calls, command = self.prepare(None)
        self.assertEqual(receipt["status"], "prepared-test-helper-load-not-yet-proven")
        self.assertEqual(receipt["manifestPreparationExitCode"], 0)
        self.assertEqual(receipt["manifestPreparationLoaderReceipt"]["pid"], 4242)
        compile_command = next(call[1] for call in calls if call[0] == "compile")
        self.assertEqual([compile_command[index + 1] for index, arg in enumerate(compile_command) if arg == "-arch"],
                         ["arm64", "arm64e"])
        architecture = next(call[1] for call in calls if call[0] == "architecture")
        self.assertEqual(architecture[2], "-archs")
        self.assertEqual(receipt["architectures"], ["arm64", "arm64e"])
        manifest = next(call[1] for call in calls if call[0] == "manifest")
        self.assertEqual(manifest[1:3], ["package", "--package-path"])
        self.assertEqual(manifest[-3:], ["--manifest-cache", "none", "dump-package"])
        self.assertEqual(overrides["NGV_CF_RUNLOOP_PROBE_PARENT_PID"], str(os.getpid()))
        self.assertEqual(overrides["NGV_CF_RUNLOOP_PROBE_ROOT_PID"], "")
        self.assertEqual(overrides["NGV_CF_RUNLOOP_PROBE_ARGC"], str(len(command)))
        self.assertEqual([overrides[f"NGV_CF_RUNLOOP_PROBE_ARG_{index}"] for index in range(len(command))],
                         receipt["actualCommand"])
        self.assertEqual(receipt["actualCommand"][1:], command[1:])

    def prepare(self, failure):
        calls = []
        command = ["swift", "test", "--cache-path", "dependency cache", "--skip-build"]
        self.original_dyld = os.environ.get("DYLD_INSERT_LIBRARIES")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "evidence"
            evidence.mkdir()
            binary = root / ".build/debug/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"test fixture")
            workflow = root / ".github/workflows/ci.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("test fixture\n")
            swift = root / "swift"
            swift.write_bytes(b"not executed")
            swift.chmod(0o700)

            def run(arguments, **kwargs):
                if arguments[-1] == "--show-sdk-path":
                    return subprocess.CompletedProcess(arguments, 1, "", "fixture has no SDK")
                if "clang" in arguments:
                    calls.append(("compile", arguments))
                    if failure != "compile":
                        Path(arguments[-1]).write_bytes(b"not a real dylib")
                    return subprocess.CompletedProcess(arguments, 1 if failure == "compile" else 0)
                if "lipo" in arguments:
                    calls.append(("architecture", arguments))
                    architectures = {"thin-arm64": "arm64\n", "thin-arm64e": "arm64e\n",
                                     "unknown-architecture": "arm64 unknown(16777228,2)\n"}
                    return subprocess.CompletedProcess(arguments, 1 if failure == "architecture" else 0,
                                                       architectures.get(failure, "arm64 arm64e\n"), "")
                return subprocess.CompletedProcess(arguments, 0, str(swift) + "\n", "")

            class ManifestProcess:
                pid = 4242
                returncode = 1 if failure == "manifest" else 0

                def __init__(self, arguments, **kwargs):
                    calls.append(("manifest", arguments, kwargs.get("start_new_session")))
                    if failure != "missing-loader":
                        row = {"event": "probe-root-init", "pid": 1 if failure == "wrong-pid" else self.pid,
                               "parentPID": os.getpid(), "initialLaunchMatched": True,
                               "injectionCleanup": "retained-own-root-library",
                               "loadedLibrary": kwargs["env"]["DYLD_INSERT_LIBRARIES"],
                               "executable": str(swift)}
                        invalid = {"null-executable": None, "numeric-executable": 7,
                                   "list-executable": [], "object-executable": {}}
                        if failure in invalid:
                            row["executable"] = invalid[failure]
                        path = evidence / f"runloop-probe-root-{self.pid}.jsonl"
                        path.write_text("1\n" if failure == "malformed-loader" else json.dumps(row) + "\n")
                    self.wait_count = 0

                def __enter__(self):
                    return self

                def __exit__(self, *args):
                    return False

                def wait(self, timeout=None):
                    self.wait_count += 1
                    if failure == "timeout" and self.wait_count == 1:
                        raise subprocess.TimeoutExpired("manifest", timeout)
                    return self.returncode

                def kill(self):
                    calls.append(("kill-owned-manifest", []))

            environment = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "iret77/nexgenvideo"}
            if failure == "foreign-dyld":
                environment["DYLD_INSERT_LIBRARIES"] = "/foreign/probe.dylib"
            with mock.patch.dict(os.environ, environment, clear=True), \
                    mock.patch.object(diagnostic.sys, "platform", "darwin"), \
                    mock.patch.object(diagnostic.Path, "cwd", return_value=root), \
                    mock.patch.object(diagnostic.subprocess, "run", side_effect=run), \
                    mock.patch.object(diagnostic.subprocess, "Popen", ManifestProcess), \
                    mock.patch.object(diagnostic.os, "killpg", side_effect=lambda pid, sig: calls.append(("killpg", [pid, sig]))):
                receipt, overrides = diagnostic.prepare_runloop_probe(evidence, command)
                if failure == "foreign-dyld":
                    self.assertEqual(os.environ["DYLD_INSERT_LIBRARIES"], "/foreign/probe.dylib")
            return receipt, overrides, calls, command


if __name__ == "__main__":
    unittest.main()
