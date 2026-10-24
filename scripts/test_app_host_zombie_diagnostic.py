import ctypes
import json
from pathlib import Path
import struct
import tempfile
import unittest
import uuid
from unittest.mock import patch

from app_host_zombie_diagnostic import RUsageV4, ZombieCapture, diagnostic_environment, selected_environment, zombie_environment
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
