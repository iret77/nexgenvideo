import binascii
import hashlib
import json
import os
import signal
import struct
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock
import zlib
from pathlib import Path

import render_agent_chat_spec


def write_process_fixture(directory):
    browser = directory / "fixture-browser"
    browser.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
        import json, os, signal, subprocess, sys, time
        from pathlib import Path
        args = sys.argv[1:]
        profile = Path(next(arg.split("=", 1)[1] for arg in args if arg.startswith("--user-data-dir=")))
        mode = next((arg.split("=", 1)[1] for arg in args if arg.startswith("--fixture-mode=")), "inspect")
        observation = {"args": args, "pid": os.getpid(), "group": os.getpgrp(),
                       "session": os.getsid(0), "stdin": sys.stdin.read(),
                       "profile": str(profile), "mode": profile.stat().st_mode & 0o777,
                       "initialEntries": list(profile.iterdir())}
        if mode in ("descendant", "timeout"):
            ready = profile / "child-ready"
            child_code = "import pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text('ready'); time.sleep(60)"
            child = subprocess.Popen([sys.executable, "-c", child_code, str(ready)], stdin=subprocess.DEVNULL)
            deadline = time.monotonic() + 2
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            if not ready.exists():
                raise RuntimeError("owned child did not become ready")
            observation["child"] = child.pid
        print(json.dumps(observation), flush=True)
        print("fixture stderr before exit or timeout", file=sys.stderr, flush=True)
        if mode == "nonzero":
            os.write(1, b"O" * 262144)
            os.write(2, b"E" * 262144)
            sys.exit(7)
        if mode == "timeout":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(60)
        '''))
    browser.chmod(0o700)
    return str(browser)


def process_running(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()[0] != "Z"
    except (FileNotFoundError, ProcessLookupError):
        return False


def png_chunk(kind, payload):
    checksum = binascii.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def write_rgb_png(path, width, height, pixel):
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(pixel(x, y))
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(rows))
        + png_chunk(b"IEND", b"")
    )


class AgentChatSpecRendererTests(unittest.TestCase):
    def test_process_observation_distinguishes_exit_from_unreadable_state(self):
        for error in (FileNotFoundError(), ProcessLookupError()):
            with self.subTest(error=type(error).__name__), mock.patch.object(Path, "read_text", side_effect=error):
                self.assertFalse(process_running(123))
        for state in ("R", "S", "Z"):
            with self.subTest(state=state), mock.patch.object(Path, "read_text", return_value=f"123 (fixture) {state} 1 1"):
                self.assertEqual(process_running(123), state != "Z")
        with mock.patch.object(Path, "read_text", side_effect=PermissionError()):
            with self.assertRaises(PermissionError):
                process_running(123)

    @unittest.skipUnless(sys.platform == "linux", "Process fixtures target the Linux UI runner")
    def test_browser_calls_use_private_profiles_closed_stdin_and_common_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            browser = write_process_fixture(root)
            profiles = []
            for index, arguments in enumerate((["--dump-dom"], ["--screenshot=fixture.png"])):
                diagnostic = root / f"capture-{index}"
                observation = json.loads(render_agent_chat_spec.run_browser(
                    browser, "file:///fixture.html", diagnostic, arguments))
                profiles.append(observation["profile"])
                self.assertEqual(observation["stdin"], "")
                self.assertEqual(observation["mode"], 0o700)
                self.assertEqual(observation["initialEntries"], [])
                self.assertEqual(observation["pid"], observation["group"])
                self.assertEqual(observation["pid"], observation["session"])
                for flag in ("--headless=new", "--no-first-run", "--disable-background-networking"):
                    self.assertIn(flag, observation["args"])
                self.assertIn(arguments[0], observation["args"])
                self.assertFalse(Path(observation["profile"]).exists())
                request = json.loads((diagnostic / "request.json").read_text())
                result = json.loads((diagnostic / "result.json").read_text())
                self.assertEqual(request["timeoutSeconds"], 45)
                self.assertEqual(result["exitCode"], 0)
                self.assertTrue(result["cleanup"]["rootReaped"])
                for stream in ("stdout", "stderr"):
                    raw = (diagnostic / f"{stream}.log").read_bytes()
                    self.assertEqual(result[stream]["bytes"], len(raw))
                    self.assertEqual(result[stream]["sha256"], hashlib.sha256(raw).hexdigest())
            self.assertNotEqual(*profiles)

    @unittest.skipUnless(sys.platform == "linux", "Process fixtures target the Linux UI runner")
    def test_nonzero_browser_retains_large_direct_output_without_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            diagnostic = root / "capture"
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                render_agent_chat_spec.run_browser(write_process_fixture(root), "file:///fixture.html",
                    diagnostic, ["--fixture-mode=nonzero"], timeout=3)
            self.assertEqual(raised.exception.returncode, 7)
            result = json.loads((diagnostic / "result.json").read_text())
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["exitCode"], 7)
            self.assertTrue(result["cleanup"]["rootReaped"])
            self.assertGreater((diagnostic / "stdout.log").stat().st_size, 262144)
            self.assertGreater((diagnostic / "stderr.log").stat().st_size, 262144)
            self.assertEqual((diagnostic / "stdout.log").read_text().count('"initialEntries"'), 1)

    @unittest.skipUnless(sys.platform == "linux", "Process fixtures target the Linux UI runner")
    def test_timeout_and_success_cleanup_owned_descendants_without_touching_foreign_process(self):
        sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                browser = write_process_fixture(root)
                for mode in ("descendant", "timeout"):
                    with self.subTest(mode=mode):
                        diagnostic = root / mode
                        try:
                            started = time.monotonic()
                            if mode == "timeout":
                                with self.assertRaises(subprocess.TimeoutExpired):
                                    render_agent_chat_spec.run_browser(browser, "file:///fixture.html",
                                        diagnostic, [f"--fixture-mode={mode}"], timeout=3)
                            else:
                                render_agent_chat_spec.run_browser(browser, "file:///fixture.html",
                                    diagnostic, [f"--fixture-mode={mode}"], timeout=3)
                            self.assertLess(time.monotonic() - started, 10)
                            result = json.loads((diagnostic / "result.json").read_text())
                            observation = json.loads((diagnostic / "stdout.log").read_text())
                            self.assertEqual(result["status"], "timed-out" if mode == "timeout" else "process-exited")
                            self.assertTrue(result["cleanup"]["rootReaped"])
                            signals = result["cleanup"]["signals"]
                            self.assertTrue(any(row["signal"] == signal.SIGKILL and row["status"] == "sent" for row in signals))
                            self.assertTrue(all(row["processGroup"] == observation["pid"] > 0 for row in signals))
                            deadline = time.monotonic() + 2
                            while process_running(observation["child"]) and time.monotonic() < deadline:
                                time.sleep(0.01)
                            self.assertFalse(process_running(observation["child"]))
                            self.assertFalse(Path(observation["profile"]).exists())
                            self.assertIn("fixture stderr", (diagnostic / "stderr.log").read_text())
                            self.assertIsNone(sentinel.poll())
                        finally:
                            receipt = diagnostic / "result.json"
                            if receipt.exists():
                                group = json.loads(receipt.read_text()).get("processGroup")
                                if group is not None and group > 0:
                                    try:
                                        os.killpg(group, signal.SIGKILL)
                                    except ProcessLookupError:
                                        pass
        finally:
            sentinel.terminate()
            try:
                sentinel.wait(timeout=2)
            except subprocess.TimeoutExpired:
                sentinel.kill()
                sentinel.wait(timeout=2)

    def test_profile_and_launch_errors_still_produce_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            diagnostic = root / "profile-failure"
            with mock.patch.object(render_agent_chat_spec.tempfile, "TemporaryDirectory", side_effect=OSError("fixture")):
                with self.assertRaises(OSError):
                    render_agent_chat_spec.run_browser("missing-browser", "file:///fixture.html", diagnostic, [])
            result = json.loads((diagnostic / "result.json").read_text())
            self.assertEqual(result["failureType"], "OSError")
            self.assertEqual(result["cleanup"]["scope"], "not-started")
            diagnostic = root / "launch-failure"
            with self.assertRaises(FileNotFoundError):
                render_agent_chat_spec.run_browser(str(root / "absent-browser"), "file:///fixture.html", diagnostic, [])
            result = json.loads((diagnostic / "result.json").read_text())
            self.assertEqual(result["failureType"], "FileNotFoundError")
            request = json.loads((diagnostic / "request.json").read_text())
            profile = next(arg.split("=", 1)[1] for arg in request["command"] if arg.startswith("--user-data-dir="))
            self.assertFalse(Path(profile).exists())
            self.assertTrue((diagnostic / "stdout.log").is_file())
            self.assertTrue((diagnostic / "stderr.log").is_file())

    @unittest.skipUnless(sys.platform == "linux", "Process fixtures target the Linux UI runner")
    def test_browser_wait_cancellation_is_retained_and_propagated(self):
        wait = subprocess.Popen.wait
        interrupted = False
        def interrupt_once(process, *args, **kwargs):
            nonlocal interrupted
            if not interrupted:
                interrupted = True
                raise KeyboardInterrupt("fixture cancellation")
            return wait(process, *args, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            diagnostic = root / "capture"
            with mock.patch.object(subprocess.Popen, "wait", interrupt_once):
                with self.assertRaises(KeyboardInterrupt):
                    render_agent_chat_spec.run_browser(write_process_fixture(root), "file:///fixture.html", diagnostic, [])
            result = json.loads((diagnostic / "result.json").read_text())
            self.assertEqual(result["failureType"], "KeyboardInterrupt")
            self.assertTrue(result["cleanup"]["rootReaped"])
            self.assertTrue((diagnostic / "stdout.log").is_file())
            self.assertTrue((diagnostic / "stderr.log").is_file())

    @unittest.skipUnless(sys.platform == "linux", "Process fixtures target the Linux UI runner")
    def test_cleanup_wait_interrupt_still_kills_owned_child_and_is_propagated(self):
        sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        wait = subprocess.Popen.wait
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                browser = write_process_fixture(root)
                for mode in ("descendant", "timeout"):
                    with self.subTest(mode=mode):
                        diagnostic = root / mode
                        calls = 0
                        def interrupt_cleanup_once(process, *args, **kwargs):
                            nonlocal calls
                            calls += 1
                            if calls == 2:
                                raise KeyboardInterrupt("fixture cleanup cancellation")
                            return wait(process, *args, **kwargs)
                        try:
                            with mock.patch.object(subprocess.Popen, "wait", interrupt_cleanup_once):
                                with self.assertRaisesRegex(KeyboardInterrupt, "fixture cleanup cancellation"):
                                    render_agent_chat_spec.run_browser(browser, "file:///fixture.html",
                                        diagnostic, [f"--fixture-mode={mode}"], timeout=3)
                            self.assertGreaterEqual(calls, 3)
                            result = json.loads((diagnostic / "result.json").read_text())
                            observation = json.loads((diagnostic / "stdout.log").read_text())
                            self.assertEqual(result["cleanup"]["errorType"], "KeyboardInterrupt")
                            self.assertTrue(result["cleanup"]["rootReaped"])
                            self.assertEqual(result["status"], "timed-out" if mode == "timeout" else "process-exited")
                            deadline = time.monotonic() + 2
                            while process_running(observation["child"]) and time.monotonic() < deadline:
                                time.sleep(0.01)
                            self.assertFalse(process_running(observation["child"]))
                            self.assertFalse(Path(observation["profile"]).exists())
                            self.assertIn("fixture stderr", (diagnostic / "stderr.log").read_text())
                            self.assertIsNone(sentinel.poll())
                        finally:
                            output = diagnostic / "stdout.log"
                            if output.exists() and output.stat().st_size:
                                observation = json.loads(output.read_text())
                                if process_running(observation["child"]):
                                    try:
                                        os.killpg(observation["group"], signal.SIGKILL)
                                    except ProcessLookupError:
                                        pass
        finally:
            sentinel.terminate()
            try:
                sentinel.wait(timeout=2)
            except subprocess.TimeoutExpired:
                sentinel.kill()
                sentinel.wait(timeout=2)

    def test_blank_capture_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "blank.png"
            write_rgb_png(path, 20, 20, lambda _x, _y: (9, 10, 12))
            with self.assertRaisesRegex(RuntimeError, "appears blank"):
                render_agent_chat_spec.validate_visual_content(path)

    def test_visually_populated_capture_is_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "populated.png"
            write_rgb_png(
                path,
                20,
                20,
                lambda x, y: ((x * 17) % 256, (y * 19) % 256, ((x + y) * 13) % 256),
            )
            render_agent_chat_spec.validate_visual_content(path)

    def test_normative_document_declares_the_complete_capture_matrix(self):
        repository = Path(__file__).resolve().parent.parent
        source = repository / "docs/ui/agent-chat.html"
        self.assertEqual(
            render_agent_chat_spec.declared_states(source),
            render_agent_chat_spec.STATES,
        )

    def test_capture_dom_requires_ready_state_and_all_agent_widths(self):
        state = "empty"
        content = (
            '<body data-capture-state="empty" data-render-ready="true">'
            '<section data-state-section="empty">'
            '<article aria-label="240 point Agent panel, Empty"></article>'
            '<article aria-label="400 point Agent panel, Empty"></article>'
            '<article aria-label="640 point Agent panel, Empty"></article>'
            "</section></body>"
        )
        render_agent_chat_spec.validate_capture_dom(content, state)
        with self.assertRaisesRegex(RuntimeError, "did not reach"):
            render_agent_chat_spec.validate_capture_dom(
                content.replace('data-render-ready="true"', ""),
                state,
            )

    def test_reduce_motion_capture_requires_an_explicit_dom_marker(self):
        state = "stress"
        content = (
            '<body data-capture-state="stress" data-render-ready="true" '
            'data-reduce-motion="true">'
            '<section data-state-section="stress">'
            '<article aria-label="240 point Agent panel, Stress"></article>'
            '<article aria-label="400 point Agent panel, Stress"></article>'
            '<article aria-label="640 point Agent panel, Stress"></article>'
            "</section></body>"
        )
        render_agent_chat_spec.validate_capture_dom(content, state, True)
        with self.assertRaisesRegex(RuntimeError, "did not reach"):
            render_agent_chat_spec.validate_capture_dom(
                content.replace('data-reduce-motion="true"', ""),
                state,
                True,
            )


if __name__ == "__main__":
    unittest.main()
