from copy import deepcopy
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import Mock, patch

from ci_builtin_blur import BACKTRACE, FAULT_IMAGES, IMAGES, environment, intervals, owned_process, run_measured, sample_proof, signature


class BuiltinBlurEvidenceTests(unittest.TestCase):
    def test_diagnostic_environment_rejects_injection_and_memory_timing_changes(self):
        self.assertEqual(environment({"PATH": "/usr/bin"})["SWIFT_BACKTRACE"], BACKTRACE)
        for key in ("NSZombieEnabled", "MallocScribble", "MTL_DEBUG_LAYER", "OBJC_DEBUG_MISSING_POOLS",
                    "DYLD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "NSDeallocateZombies", "METAL_DEVICE_WRAPPER_TYPE"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                environment({key: "1"})
        with self.assertRaises(ValueError):
            environment({"SWIFT_BACKTRACE": "disable"})

    def test_overlap_requires_complete_owned_ordered_render_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            records = [[dict(event=event, pid=42, round=0, lane=lane, begin=100 + lane, end=200 + lane, red=0.2)
                        for event in ("ready", "interval", "completed")] for lane in range(2)]
            def write():
                for lane, values in enumerate(records):
                    (folder / f"lane-{lane}.jsonl").write_text("\n".join(json.dumps(v) for v in values))
            write()
            self.assertEqual(intervals(folder, 42, 1), 1)
            records[1][1].update(begin=201, end=202)
            write()
            self.assertEqual(intervals(folder, 42, 1), 0)
            original = deepcopy(records)
            for field, value in (("pid", 99), ("lane", 0), ("round", 1), ("end", 0), ("begin", True)):
                records = deepcopy(original)
                records[1][1][field] = value
                write()
                with self.subTest(field=field), self.assertRaises(ValueError):
                    intervals(folder, 42, 1)
            records = deepcopy(original)
            records[0].pop()
            write()
            with self.assertRaises(ValueError):
                intervals(folder, 42, 1)

    def test_sample_requires_owned_process_exact_images_and_nested_allocation_stack(self):
        prefix = "Process: NGVBuiltinBlur [42]\nParent Process: Python [12]\n"
        images = "\nBinary Images:\n" + "\n".join(
            f"  0x100 - 0x200 com.apple.{name} (1) <{value.upper()}> /System/Library/{name}"
            for name, value in IMAGES.items())
        stack = "    + 10 +[CIBlurProcessor render] (in CoreImage)\n    +   10 MPSAutoCache::GetTempTexture (in MPSCore)\n"
        sample_proof(prefix + stack + images, 42, 12)
        invalid = [prefix.replace("[42]", "[43]") + stack + images,
                   prefix.replace("[12]", "[13]") + stack + images,
                   prefix + stack + images.replace(next(iter(IMAGES.values())).upper(), "0" * 36),
                   prefix + stack.replace("    +   10 MPS", "    + 10 MPS") + images,
                   prefix + stack.replace("    +   10 MPS", "\n    +   10 MPS") + images,
                   prefix + stack.replace("CIBlurProcessor", "unrelated") + images,
                   prefix + stack + "\n".join(line for line in images.splitlines() if "/Metal" not in line)]
        for text in invalid:
            with self.subTest(text=text[:120]), self.assertRaises(ValueError):
                sample_proof(text, 42, 12)

    def test_crash_signature_rejects_different_fault_driver_or_registers(self):
        images = [dict(name=name, uuid=value) for name, value in IMAGES.items()]
        images.append(dict(name="Foundation", uuid=FAULT_IMAGES["Foundation"]))
        image_index = {image["name"]: i for i, image in enumerate(images)}
        registers = [dict(value=0) for _ in range(22)]
        registers[0] = registers[21] = dict(value=12345)
        registers[16] = dict(value=0x648F22797D46D8)
        report = dict(osVersion=dict(build="26A428"), usedImages=images,
            exception=dict(signal="SIGSEGV", subtype="KERN_INVALID_ADDRESS"),
            threads=[dict(triggered=True, threadState=dict(x=registers, far=dict(value=0x648F22797D46E8)),
                frames=[dict(symbol=s, imageIndex=image_index[image], imageOffset=offset)
                        for s, image, offset in (("objc_msgSend", "Foundation", 0),
                            ("-[NSData getBytes:length:]", "Foundation", 353380),
                            ("unknown", "AppleParavirtGPUMetalIOGPUFamily", 131268),
                            ("unknown", "AppleParavirtGPUMetalIOGPUFamily", 55244),
                            ("unknown", "MPSCore", 487936),
                            ("MPSAutoCache::GetTempTexture", "MPSCore", 0),
                            ("unknown", "MPSImage", 228948),
                            ("CIBlurProcessor", "CoreImage", 0))])])
        self.assertTrue(signature(report))
        reduced = deepcopy(report)
        reduced["usedImages"] = [i for i in reduced["usedImages"] if i["name"] not in {"Metal", "IOGPU"}]
        indexes = {i["name"]: n for n, i in enumerate(reduced["usedImages"])}
        for frame in reduced["threads"][0]["frames"]:
            frame["imageIndex"] = indexes[images[frame["imageIndex"]]["name"]]
        self.assertTrue(signature(reduced))
        for change in ("uuid", "os", "signal", "far", "receiver", "missing-frame", "offset", "low-isa",
                       "two-triggered", "subtype", "order", "wrong-image"):
            altered = deepcopy(report)
            if change == "uuid": altered["usedImages"][0]["uuid"] = "0" * 36
            elif change == "os": altered["osVersion"]["build"] = "other"
            elif change == "signal": altered["exception"]["signal"] = "SIGABRT"
            elif change == "far": altered["threads"][0]["threadState"]["far"]["value"] += 1
            elif change == "receiver": altered["threads"][0]["threadState"]["x"][21] = dict(value=0)
            elif change == "missing-frame": altered["threads"][0]["frames"].pop()
            elif change == "low-isa":
                altered["threads"][0]["threadState"]["x"][16]["value"] = 123
                altered["threads"][0]["threadState"]["far"]["value"] = 139
            elif change == "two-triggered": altered["threads"].append(deepcopy(altered["threads"][0]))
            elif change == "subtype": altered["exception"]["subtype"] = "KERN_PROTECTION_FAILURE"
            elif change == "order": altered["threads"][0]["frames"][5], altered["threads"][0]["frames"][-1] = altered["threads"][0]["frames"][-1], altered["threads"][0]["frames"][5]
            elif change == "wrong-image": altered["threads"][0]["frames"][2]["imageIndex"] = image_index["Foundation"]
            else:
                for frame in altered["threads"][0]["frames"]: frame["imageOffset"] = 0
            with self.subTest(change=change):
                self.assertFalse(signature(altered))

    def test_measurement_stops_at_first_abnormal_and_never_begins_without_headroom(self):
        for outcome in ("R", "C", "V"):
            result = dict(processesCompleted=0, roundsCompleted=0, overlappingRounds=0)
            with patch("ci_builtin_blur.time.monotonic", return_value=0), \
                    patch("ci_builtin_blur.owned_process", side_effect=[("clean", {"pid": 42}), (outcome, {})]) as run, \
                    patch("ci_builtin_blur.intervals", return_value=4):
                run_measured(Path("binary"), Path("folder"), 1200, result)
            self.assertEqual(run.call_count, 2)
            self.assertEqual((result["outcome"], result["processesCompleted"], result["overlappingRounds"]), (outcome, 1, 4))
        with patch("ci_builtin_blur.time.monotonic", return_value=901), patch("ci_builtin_blur.owned_process") as run:
            result = {}
            run_measured(Path("binary"), Path("folder"), 1200, result)
            run.assert_not_called()
            self.assertEqual(result["outcome"], "V")

    def test_nonreproduction_requires_complete_exposure_and_overlap(self):
        for overlap, expected in ((4, "N"), (3, "V")):
            result = dict(processesCompleted=0, roundsCompleted=0, overlappingRounds=0)
            with patch("ci_builtin_blur.time.monotonic", return_value=0), \
                    patch("ci_builtin_blur.owned_process", return_value=("clean", {"pid": 42})) as run, \
                    patch("ci_builtin_blur.intervals", return_value=overlap):
                run_measured(Path("binary"), Path("folder"), 1200, result)
            self.assertEqual(run.call_count, 200)
            self.assertEqual((result["outcome"], result["roundsCompleted"]), (expected, 800))

    def test_timeout_reaps_only_owned_process_and_cannot_be_a_reproduction(self):
        process = Mock(pid=42)
        process.wait.side_effect = [subprocess.TimeoutExpired("owned", 300), -9]
        process.poll.return_value = -9
        with tempfile.TemporaryDirectory() as temporary, \
                patch("ci_builtin_blur.prepare_post_mortem", return_value={"hostUUID": "test"}), \
                patch("ci_builtin_blur.subprocess.Popen", return_value=process), \
                patch("ci_builtin_blur.environment", return_value={}), \
                patch("ci_builtin_blur.os.killpg") as kill, \
                patch("ci_builtin_blur.capture_post_mortem", return_value={"reports": []}):
            outcome, context = owned_process(Path("binary"), Path(temporary) / "child", "measured", 1e30)
        kill.assert_called_once_with(42, 9)
        self.assertEqual(process.wait.call_count, 2)
        self.assertTrue(context["timedOut"])
        self.assertEqual(outcome, "V")


if __name__ == "__main__":
    unittest.main()
