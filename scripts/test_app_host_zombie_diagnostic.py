import ctypes
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import Mock, patch

from app_host_zombie_diagnostic import RUsageV4, ZombieCapture, diagnostic_environment, probe_child_stdio, sample_image_records, selected_environment, zombie_environment
import run_macos_tests as driver


COMMAND = ["/fixture/NexGenVideoAppKitTestHost", "--event-stream-version", "0"]
IMAGE_UUID = "28e32694-8c96-33f4-9ebc-ab10afa8977b"


def arguments(environment, command=COMMAND):
    return (struct.pack("=i", len(command)) + command[0].encode() + b"\0\0\0"
            + b"\0".join(value.encode() for value in command) + b"\0"
            + b"\0".join(environment) + b"\0\0")


class Reader:
    def __init__(self, environment=None, command=COMMAND):
        self.environment = environment if environment is not None else [b"NSZombieEnabled=YES"]
        self.identity = IMAGE_UUID
        self.started = 321
        self.calls = []
        self.command = command

    def usage(self, pid):
        self.calls.append(pid)
        return {"imageUUID": self.identity, "startAbsoluteTime": self.started,
                "residentBytes": 123456, "lifetimePeakPhysicalFootprintBytes": 234567}

    def arguments(self, pid):
        self.calls.append(pid)
        return arguments(self.environment, self.command)


class ZombieDiagnosticTests(unittest.TestCase):
    def test_native_image_sample_requires_owned_pid_parent_and_actual_binary_images(self):
        sample = "Process: NexGenVideoAppKitTestHost [123]\nParent Process: Python [45]\n\nBinary Images:\n"
        sample += "  0x1000 - 0x2000 CoreImage (27) <" + IMAGE_UUID.upper() + "> /System/CoreImage\n"
        self.assertEqual(sample_image_records(sample, 123, 45), [{"uuid": IMAGE_UUID, "path": "/System/CoreImage"}])
        for altered in (sample.replace("[123]", "[124]"), sample.replace("[45]", "[46]"),
                        sample.split("\nBinary Images:")[0], sample.replace("0x1000", "not-an-image")):
            with self.assertRaises(ValueError):
                sample_image_records(altered, 123, 45)

    def test_native_image_capture_waits_for_glow_completion_and_checks_lifetime_after_sampling(self):
        for replaced in (False, True, "timeout"):
            with self.subTest(replaced=replaced), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                reader = Reader()
                capture = ZombieCapture(123, COMMAND,
                    {"hostUUID": IMAGE_UUID, "hostSHA256": "b" * 64, "hostExecutable": COMMAND[0]},
                    folder, "a" * 40, reader=reader, profile="app-reproduction")
                capture.sample()
                methods = ["neutralIsNoOp", "bleedsLightIntoNeighbors", "warmthTintsTheBleedRed"]
                records = [{"kind": "event", "payload": {"kind": "testEnded",
                    "testID": "NexGenVideoTests.GlowKernelTests/" + method + "()/Glow.swift:1:1",
                    "instant": {"since1970": 1}}} for method in methods]
                path = folder / "events.jsonl"
                path.write_text("\n".join(json.dumps(value) for value in records[:2]) + "\n")
                def sample(command, **kwargs):
                    self.assertEqual(command, ["/usr/bin/sample", "123", "1", "-file", str(folder / "owned-images.sample.txt")])
                    self.assertEqual(kwargs["timeout"], 60)
                    if replaced == "timeout":
                        raise subprocess.TimeoutExpired(command, 60)
                    text = "Process: NexGenVideoAppKitTestHost [123]\nParent Process: Python [" + str(os.getpid()) + "]\n\nBinary Images:\n"
                    text += "  0x1000 - 0x2000 CoreImage (27) <" + IMAGE_UUID + "> /System/CoreImage\n"
                    (folder / "owned-images.sample.txt").write_text(text)
                    if replaced is True:
                        reader.started += 1
                    return subprocess.CompletedProcess(command, 0)
                with patch("app_host_zombie_diagnostic.subprocess.run", side_effect=sample) as run:
                    capture.capture_images_after_glow()
                    run.assert_not_called()
                    self.assertNotIn("loadedImageCapture", capture.receipt)
                    path.write_text("\n".join(json.dumps(value) for value in records) + '\n{"partial":')
                    capture.capture_images_after_glow()
                    run.assert_called_once()
                    capture.capture_images_after_glow()
                    run.assert_called_once()
                result = capture.receipt["loadedImageCapture"]
                self.assertEqual(result["status"], "unavailable" if replaced else "verified")
                if not replaced:
                    self.assertEqual(result["images"], [{"uuid": IMAGE_UUID, "path": "/System/CoreImage"}])

    def test_child_stdio_preflight_rejects_noise_nonzero_and_timeout_before_app_execution(self):
        for noise, code, timeout in ((None, 0, False), ("stdout", 0, False), ("stderr", 0, False),
                                     (None, 9, False), (None, -9, True)):
            with self.subTest(noise=noise, code=code, timeout=timeout), tempfile.TemporaryDirectory() as directory:
                process = Mock(pid=123)
                process.wait.side_effect = [subprocess.TimeoutExpired("probe", 15), -9] if timeout else [code]
                def launch(command, **kwargs):
                    self.assertEqual(command[:2], ["/bin/sh", "-c"])
                    self.assertEqual(kwargs["env"]["DYLD_PRINT_LIBRARIES"], "1")
                    self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
                    self.assertTrue(kwargs["start_new_session"])
                    self.assertEqual(kwargs["env"]["DYLD_PRINT_TO_FILE"],
                                     str((Path(directory) / "child-stdio-probe/dyld-images.log").resolve()))
                    if noise:
                        kwargs[noise].write(b"unexpected output\n")
                    return process
                with patch("app_host_zombie_diagnostic.subprocess.Popen", side_effect=launch), \
                        patch("app_host_zombie_diagnostic.os.killpg") as kill:
                    if noise or code or timeout:
                        with self.assertRaises(ValueError):
                            probe_child_stdio({"DYLD_PRINT_LIBRARIES": "1"}, directory)
                    else:
                        self.assertEqual(probe_child_stdio({"DYLD_PRINT_LIBRARIES": "1"}, directory)["status"], "passed")
                    self.assertEqual(kill.call_count, int(timeout))
                    self.assertEqual(process.wait.call_count, 2 if timeout else 1)
                receipt = json.loads((Path(directory) / "child-stdio-probe/receipt.json").read_text())
                self.assertEqual(receipt["exitCode"], code)
                self.assertEqual(receipt["timedOut"], timeout)
                self.assertFalse(receipt["loaderLogPresent"])

    def test_full_app_profile_preserves_loader_only_activation_and_pid_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            log_path = Path(directory) / "dyld-images.log"
            expected = {"DYLD_PRINT_LIBRARIES": "1", "DYLD_PRINT_TO_FILE": str(log_path.resolve())}
            self.assertEqual(diagnostic_environment({}, "app-reproduction", log_path), expected)
            capture = ZombieCapture(123, COMMAND,
                {"hostUUID": IMAGE_UUID, "hostSHA256": "b" * 64, "hostExecutable": COMMAND[0]},
                Path(directory), "a" * 40,
                reader=Reader([key.encode() + b"=" + value.encode() for key, value in expected.items()]), profile="app-reproduction")
            capture.start()
            result = capture.finish()
            self.assertEqual(result["status"], "verified")
            self.assertEqual(result["profile"], "app-reproduction")
            self.assertEqual(json.loads((Path(directory) / "app-diagnostic.json").read_text()), result)
            self.assertEqual(result["environment"], {**expected, "otherDiagnosticVariablesPresent": False})
            for values in ([b"DYLD_PRINT_LIBRARIES=1"], [b"DYLD_PRINT_LIBRARIES=1", b"DYLD_PRINT_TO_FILE=/wrong/log"]):
                with self.assertRaises(ValueError):
                    selected_environment(arguments(values), COMMAND, "app-reproduction", log_path)
            log_path.write_text("occupied")
            with self.assertRaises(ValueError):
                diagnostic_environment({}, "app-reproduction", log_path)
        for path in (None, "relative/log"):
            with self.assertRaises(ValueError):
                diagnostic_environment({}, "app-reproduction", path)

    def test_glow_profile_observes_loader_logging_without_memory_or_metal_switches(self):
        environment = {"PATH": "/fixture", "GITHUB_SHA": "a" * 40}
        self.assertEqual(diagnostic_environment(environment, "glow-reproduction"),
                         {**environment, "DYLD_PRINT_LIBRARIES": "1"})
        raw = arguments([b"TOKEN=private-value", b"DYLD_PRINT_LIBRARIES=1"])
        self.assertEqual(selected_environment(raw, COMMAND, "glow-reproduction"),
                         {"DYLD_PRINT_LIBRARIES": "1", "otherDiagnosticVariablesPresent": False})
        for extra in (b"NSZombieEnabled=YES", b"MallocStackLogging=1", b"MTL_DEBUG_LAYER=1",
                      b"DYLD_INSERT_LIBRARIES=private-value", b"DYLD_PRINT_LIBRARIES=1", b"DYLD_PRINT_APIS=1"):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                selected_environment(arguments([b"DYLD_PRINT_LIBRARIES=1", extra]), COMMAND, "glow-reproduction")
        with self.assertRaises(ValueError):
            selected_environment(arguments([b"DYLD_PRINT_LIBRARIES=0"]), COMMAND, "glow-reproduction")
        with self.assertRaises(ValueError):
            diagnostic_environment(environment, "unknown")

    def test_glow_capture_keeps_actual_pid_identity_and_the_selected_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            reader = Reader([b"DYLD_PRINT_LIBRARIES=1"])
            capture = ZombieCapture(123, COMMAND,
                {"hostUUID": IMAGE_UUID, "hostSHA256": "b" * 64, "hostExecutable": COMMAND[0]},
                Path(directory), "a" * 40, reader=reader, profile="glow-reproduction")
            capture.start()
            result = capture.finish()
            self.assertEqual(result["status"], "verified")
            self.assertEqual(result["profile"], "glow-reproduction")
            self.assertEqual(json.loads((Path(directory) / "glow-diagnostic.json").read_text()), result)
            self.assertFalse((Path(directory) / "zombie-diagnostic.json").exists())

    def test_unrelated_environment_is_never_returned_or_interpreted_as_a_switch(self):
        result = selected_environment(arguments([b"TOKEN=private-value", b"NSZombieEnabled=YES",
                                                  b"OTHER= NSZombieEnabled=NO"]), COMMAND)
        self.assertEqual(result, {"NSZombieEnabled": "YES", "otherDiagnosticVariablesPresent": False})
        with self.assertRaises(ValueError):
            selected_environment(arguments([b"OTHER= NSZombieEnabled=YES"]), COMMAND)

    def test_only_one_exact_zombie_switch_is_accepted(self):
        variants = [[], [b"NSZombieEnabled=NO"], [b"NSZombieEnabled=YES"] * 2]
        variants += [[b"NSZombieEnabled=YES", extra] for extra in (
            b"MTL_DEBUG_LAYER=0", b"MTL_SHADER_VALIDATION=1", b"MallocStackLogging=1",
            b"NSDeallocateZombies=YES", b"DYLD_INSERT_LIBRARIES=private-value",
            b"METAL_DEVICE_WRAPPER_TYPE=1", b"OBJC_DEBUG_MISSING_POOLS=YES")]
        for variant in variants:
            with self.subTest(variant=variant), self.assertRaises(ValueError) as error:
                selected_environment(arguments(variant), COMMAND)
            self.assertNotIn("private-value", str(error.exception))

    def test_argument_or_executable_substitution_and_truncation_are_rejected(self):
        good = arguments([b"NSZombieEnabled=YES"])
        variants = [b"", good[:3], good[:-2], struct.pack("=i", 9000) + good[4:],
                    struct.pack("=i", 2) + good[4:],
                    good.replace(b"/fixture/", b"/changed/", 1),
                    good.replace(b"--event-stream-version", b"--other-stream-version")]
        for value in variants:
            with self.subTest(length=len(value)), self.assertRaises(ValueError):
                selected_environment(value, COMMAND)

    def test_environment_injection_cannot_hide_an_existing_diagnostic(self):
        original = {"PATH": "/fixture", "GITHUB_SHA": "a" * 40}
        self.assertEqual(zombie_environment(original), {**original, "NSZombieEnabled": "YES"})
        self.assertNotIn("NSZombieEnabled", original)
        for key in ("NSZombieEnabled", "MallocScribble", "MTL_DEBUG_LAYER", "NSDeallocateZombies"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                zombie_environment({**original, key: ""})

    def test_public_rusage_v4_layout_keeps_the_lifetime_peak_field(self):
        self.assertEqual(ctypes.sizeof(RUsageV4), 296)
        self.assertEqual(RUsageV4.ri_proc_start_abstime.offset, 80)
        self.assertEqual(RUsageV4.ri_lifetime_max_phys_footprint.offset, 240)

    def capture(self, directory, reader):
        return ZombieCapture(123, COMMAND, {"hostUUID": IMAGE_UUID, "hostSHA256": "b" * 64, "hostExecutable": COMMAND[0]},
                             Path(directory), "a" * 40, reader=reader)

    def test_capture_binds_one_pid_image_and_start_and_retains_only_selected_data(self):
        with tempfile.TemporaryDirectory() as directory:
            reader = Reader([b"TOKEN=private-value", b"NSZombieEnabled=YES"])
            capture = self.capture(directory, reader)
            capture.start()
            result = capture.finish()
            self.assertEqual(result["status"], "verified")
            self.assertEqual(result["pid"], 123)
            self.assertEqual(result["startAbsoluteTime"], 321)
            self.assertEqual(result["lifetimePeakPhysicalFootprintBytes"], 234567)
            self.assertEqual(result["maximumObservedResidentBytes"], 123456)
            self.assertEqual(set(reader.calls), {123})
            self.assertFalse(capture.thread.is_alive())
            raw = (Path(directory) / "zombie-diagnostic.json").read_text()
            self.assertNotIn("private-value", raw)
            self.assertNotIn("TOKEN", raw)
            self.assertEqual(json.loads(raw), result)

    def test_unreadable_activation_cannot_be_reported_as_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            capture = self.capture(directory, Reader([b"NSZombieEnabled=private-value"]))
            capture.start()
            result = capture.finish()
            self.assertEqual(result["status"], "unavailable")
            self.assertIsNone(capture.thread)
            self.assertNotIn("private-value", json.dumps(result))

    def test_real_post_mortem_identity_shape_binds_the_native_uuid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = root / "NexGenVideoAppKitTestHost"
            header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
            host.write_bytes(header + struct.pack("<2I", 0x1B, 24) + uuid.UUID(IMAGE_UUID).bytes)
            with patch.object(driver, "report_directories", return_value=[]), \
                    patch.object(driver, "watchdog_report_directory", return_value=root / "absent"):
                identity = driver.prepare_post_mortem(host)
            self.assertEqual(identity["hostUUID"], IMAGE_UUID)
            self.assertEqual(len(identity["hostSHA256"]), 64)
            command = [str(host), *COMMAND[1:]]
            reader = Reader(command=command)
            reader.identity = IMAGE_UUID.upper()
            capture = ZombieCapture(123, command, identity, root, "a" * 40, reader=reader)
            capture.start()
            result = capture.finish()
            self.assertEqual(result["status"], "verified")
            self.assertEqual(result["hostUUID"], IMAGE_UUID)

    def test_zero_birth_identity_is_rejected_before_environment_sampling(self):
        with tempfile.TemporaryDirectory() as directory:
            reader = Reader()
            reader.started = 0
            capture = self.capture(directory, reader)
            capture.start()
            result = capture.finish()
            self.assertNotEqual(result["status"], "verified")
            self.assertEqual(reader.calls, [123])

    def test_replaced_process_or_image_stops_sampling_and_invalidates_evidence(self):
        for field, value in (("identity", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), ("started", 999)):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                reader = Reader()
                capture = self.capture(directory, reader)
                capture.start()
                setattr(reader, field, value)
                result = capture.finish()
                self.assertEqual(result["status"], "identity-mismatch")
                self.assertFalse(capture.thread.is_alive())

    def test_unavailable_memory_after_activation_invalidates_the_diagnostic_without_leaking_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            reader = Reader()
            capture = self.capture(directory, reader)
            capture.start()
            with patch.object(reader, "usage", side_effect=OSError(1, "private-value")):
                result = capture.finish()
            self.assertEqual(result["status"], "memory-unavailable")
            self.assertFalse(capture.thread.is_alive())
            self.assertNotIn("private-value", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
