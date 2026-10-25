from copy import deepcopy
import json
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import ci_builtin_blur_preheat as probe


ROOT = Path(__file__).resolve().parents[1]


def records(folder, pid=42, arm="cold", overlap=True):
    folder.mkdir(parents=True)
    (folder / "stdout.log").write_text("completed 4 rounds\n")
    (folder / "stderr.log").write_text("")
    for lane in (0, 1):
        values = []
        for index in range(4):
            base = dict(pid=pid, lane=lane, round=index)
            start = index * 100 + (1 if lane == 0 or overlap else 50)
            values += [dict(base, event="ready"), dict(base, event="interval", begin=start, end=start+10),
                       dict(base, event="completed", red=0.1)]
        (folder / f"lane-{lane}.jsonl").write_text("\n".join(json.dumps(v) for v in values)+"\n")
    if arm == "warm":
        warm = folder / "warmup"
        warm.mkdir()
        values = [dict(pid=pid, lane=0, round=-1, event="ready"),
            dict(pid=pid, lane=0, round=-1, event="interval", begin=1, end=2),
            dict(pid=pid, lane=0, round=-1, event="completed", red=0.1)]
        (warm / "lane-0.jsonl").write_text("\n".join(json.dumps(v) for v in values)+"\n")


class PreheatTests(unittest.TestCase):
    def test_swift_semaphores_cannot_dispose_below_their_creation_value(self):
        text = (ROOT/probe.SWIFT).read_text()
        values = re.findall(r"DispatchSemaphore\(value:\s*([^)]*)\)", text)
        self.assertTrue(values)
        self.assertTrue(all(value.strip() == "0" for value in values))
        warm = text.split('if arm == "warm" {', 1)[1].split("let start =", 1)[0]
        self.assertLess(warm.index("go.signal()"), warm.index("render(round: -1"))
        self.assertIn("go: go)", warm)

    def test_abnormal_phase_distinguishes_warmup_from_measured_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)/"child"
            records(root, arm="warm")
            context = dict(pid=42, arm="warm")
            self.assertEqual(probe.abnormal_phase(root, context), "later-rounds")
            for lane in (0, 1): (root/f"lane-{lane}.jsonl").write_text("")
            self.assertEqual(probe.abnormal_phase(root, context), "after-warmup-before-measured-ready")
            (root/"warmup/lane-0.jsonl").write_text("")
            self.assertEqual(probe.abnormal_phase(root, context), "warmup-incomplete")
            context["timedOut"] = True
            self.assertEqual(probe.abnormal_phase(root, context), "timeout")
            context = dict(pid=42, arm="cold")
            self.assertEqual(probe.abnormal_phase(root, context), "round-zero-incomplete")

    def test_report_collection_copies_only_bound_original_bytes_and_classifies_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/"child").mkdir()
            (root/"native").mkdir()
            report = json.loads((ROOT/probe.FIXTURE).read_text())["report"]
            report.update(pid=42, parentPid=12, procLaunch="1970-01-01 00:01:40.0500 +0000",
                captureTime="1970-01-01 00:01:40.5000 +0000", procPath="/test/NGVBuiltinBlur")
            raw = b'{"bug_type":"309"}\n' + json.dumps(report).encode()
            path = root/"native/NGVBuiltinBlur-owned.ips"
            path.write_bytes(raw)
            context = dict(pid=42, parentPID=12, exitCode=-11, launchEarliest=100, launchLatest=100.1,
                exitObserved=101, hostUUID=report["usedImages"][0]["uuid"], directories=[str(root/"native")])
            with patch.object(probe.time, "monotonic", side_effect=iter(range(100))), patch.object(probe.time, "sleep"):
                result = probe.collect_reports(root, [("child", context)], 1200)
            self.assertEqual((root/"child/owned.ips").read_bytes(), raw)
            self.assertTrue(result["reports"]["child"]["targetFault"])
            self.assertEqual(result["missingPIDs"], [])

    def test_classifier_matches_original_floor_report_and_rejects_other_images_or_paths(self):
        fixture = json.loads((ROOT / probe.FIXTURE).read_text())
        self.assertEqual(fixture["originalReportSHA256"], probe.REPORT)
        report = fixture["report"]
        self.assertTrue(probe.target_fault(report))
        for mutation in ("os", "uuid", "foreign-frame", "not-triggered", "no-blur", "no-getBytes", "wrong-order"):
            bad = deepcopy(report)
            if mutation == "os": bad["osVersion"]["build"] = "26A428"
            if mutation == "uuid":
                for i in bad["usedImages"]:
                    if i.get("name") == "MPSCore": i["uuid"] = "foreign"
            if mutation == "foreign-frame": bad["threads"][0]["frames"][0]["imageIndex"] = -1
            if mutation == "not-triggered": bad["threads"][0]["triggered"] = False
            if mutation in {"no-blur", "no-getBytes"}:
                token = "CIBlurProcessor" if mutation == "no-blur" else "getBytes:length:"
                bad["threads"][0]["frames"] = [f for f in bad["threads"][0]["frames"] if token not in f.get("symbol", "")]
            if mutation == "wrong-order": bad["threads"][0]["frames"].reverse()
            with self.subTest(mutation=mutation): self.assertFalse(probe.target_fault(bad))

    def test_sdk_binding_detects_new_sdk_even_with_same_deployment_floor(self):
        load = struct.pack("<6I", 0x32, 24, 1, 26 << 16, 27 << 16, 0)
        raw = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, len(load), 0, 0) + load
        self.assertEqual(probe.build_version(raw), [1, 26 << 16, 27 << 16])
        newer = bytearray(raw)
        struct.pack_into("<I", newer, 48, 28 << 16)
        self.assertNotEqual(probe.build_version(newer), probe.build_version(raw))
        for bad in (raw[:31], raw[:-1], raw[:36]+struct.pack("<I", 8)+raw[40:]):
            with self.assertRaises(ValueError): probe.build_version(bad)

    def test_process_records_abnormal_exit_without_per_crash_capture(self):
        process = Mock(pid=42)
        process.wait.return_value = -11
        process.poll.return_value = -11
        with tempfile.TemporaryDirectory() as temp, patch.object(probe.subprocess, "Popen", return_value=process) as popen, \
                patch.object(probe.time, "sleep") as settle, patch.dict("os.environ", {}, clear=True):
            folder = Path(temp) / "child"
            result = probe.launch(Path("binary"), folder, "warm", {"parentPID": 12}, 1e30)
            self.assertEqual(result["exitCode"], -11)
            self.assertEqual(popen.call_args.args[0][-3:], ["measured", "normal", "warm"])
            self.assertEqual(json.loads((folder / "exit.json").read_text())["pid"], 42)
            settle.assert_called_once_with(0.1)

    def test_timeout_kills_only_owned_group_and_remains_abnormal(self):
        process = Mock(pid=42)
        process.wait.side_effect = [subprocess.TimeoutExpired("binary", 300), -9]
        process.poll.return_value = -9
        with tempfile.TemporaryDirectory() as temp, patch.object(probe.subprocess, "Popen", return_value=process), \
                patch.object(probe.os, "killpg") as kill, patch.object(probe.time, "sleep"), patch.dict("os.environ", {}, clear=True):
            result = probe.launch(Path("binary"), Path(temp)/"child", "cold", {}, 1e30)
            self.assertTrue(result["timedOut"])
            self.assertEqual(result["exitCode"], -9)
            self.assertEqual(kill.call_args.args[0], 42)

    def test_first_round_exposure_does_not_infer_overlap_from_readiness(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)/"child"
            records(root)
            self.assertTrue(probe.round_zero(root, 42))
            with self.assertRaises(ValueError): probe.round_zero(root, 99)
            (root/"lane-1.jsonl").write_text(json.dumps(dict(event="ready", pid=42, round=0, lane=1))+"\n")
            self.assertIsNone(probe.round_zero(root, 42))

    def test_missing_report_is_abnormal_and_never_a_target_fault(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(probe, "PER_ARM", 2):
            root = Path(temp)
            children = []
            for index, arm in enumerate(["cold", "warm", "warm", "cold"]):
                name = f"p{index}"
                records(root/name, 42+index, arm)
                children.append((name, dict(pid=42+index, arm=arm, exitCode=-11 if index == 0 else 0)))
            result = probe.summarize(root, children, {"reports": {}}, [])
            self.assertTrue(result["valid"])
            self.assertEqual(result["counts"]["cold"]["abnormal"], 1)
            self.assertEqual(result["counts"]["cold"]["unknownAbnormal"], 1)
            self.assertEqual(result["counts"]["cold"]["targetFaults"], 0)
            self.assertEqual(result["outcome"], "inconclusive")
            children[1][1]["exitCode"] = 2
            result = probe.summarize(root, children, {"reports": {}}, [])
            self.assertEqual(result["outcome"], "warm-arm-abnormal")
            result = probe.summarize(root, children[:-1], {"reports": {}}, [])
            self.assertFalse(result["valid"])
            self.assertIsNone(result["oneSidedFisherP"])

    def test_association_requires_verified_faults_and_exposure_in_each_arm(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(probe, "PER_ARM", 10):
            root = Path(temp)
            children, reports = [], {"reports": {}}
            for index, arm in enumerate(["cold", "warm"]*10):
                name = f"p{index}"
                records(root/name, 42+index, arm)
                fault = arm == "cold" and index < 14
                children.append((name, dict(pid=42+index, arm=arm, exitCode=-11 if fault else 0)))
                if fault: reports["reports"][name] = {"targetFault": True}
            result = probe.summarize(root, children, reports, [])
            self.assertEqual(result["outcome"], "association-candidate")
            self.assertLess(result["oneSidedFisherP"], 0.01)
            with patch.object(probe, "round_zero", return_value=False):
                result = probe.summarize(root, children, reports, [])
            self.assertEqual(result["outcome"], "inconclusive")
            self.assertFalse(result["exposureValid"])

    def test_report_collection_preserves_missing_and_rejects_foreign_ownership(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            report_dir = root/"native"
            report_dir.mkdir()
            (root/"child").mkdir()
            raw = b'{"bug_type":"309"}\n{"pid":42}'
            (report_dir/"NGVBuiltinBlur-a.ips").write_bytes(raw)
            context = dict(pid=42, exitCode=-11, directories=[str(report_dir)])
            ticks = iter([0, 0, 0, 0, 1, 1, 1, 2, 61])
            with patch.object(probe.time, "monotonic", side_effect=lambda: next(ticks, 61)), \
                    patch.object(probe.time, "sleep"), patch.object(probe, "owned_crash_report", side_effect=ValueError("foreign")):
                result = probe.collect_reports(root, [("child", context)], 1200)
            self.assertEqual(result["reports"], {})
            self.assertEqual(result["missingPIDs"], [42])
            self.assertFalse((root/"child/owned.ips").exists())

    def test_binding_rejects_other_source_execution_or_changed_dependency(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            value = dict(baseSHA=probe.BASE, harnessSHA="a"*40, workflowRun="123", attempt="1",
                hashes={name:"digest" for name in probe.CHANGED | probe.DEPENDENCIES})
            (root/"binding.json").write_text(json.dumps(value))
            env=dict(REPLAY_KIND=probe.MODE, GITHUB_SHA="a"*40, GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1")
            with patch.dict("os.environ", env, clear=True), patch.object(probe, "command", return_value="a"*40), \
                    patch.object(probe, "digest", return_value="digest"):
                self.assertEqual(probe.bound(root), value)
                for key in ("GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "REPLAY_KIND"):
                    with patch.dict("os.environ", {key:"other"}), self.assertRaises(ValueError): probe.bound(root)
                with patch.object(probe, "digest", return_value="changed"), self.assertRaises(ValueError): probe.bound(root)

    def test_workflow_compiles_only_standalone_and_runs_floor_after_build(self):
        text = (ROOT/".github/workflows/diagnostic-acceptance.yml").read_text()
        build = text.split("  ci-builtin-blur-preheat-build:\n")[1].split("  ci-builtin-blur-preheat:\n")[0]
        run = text.split("  ci-builtin-blur-preheat:\n")[1].split("  ci-app-test:\n")[0]
        self.assertIn("runs-on: macrunner", build)
        self.assertIn("needs: source", build)
        self.assertIn("ci_builtin_blur_preheat.py compile", build)
        self.assertIn("needs: ci-builtin-blur-preheat-build", run)
        self.assertIn("runs-on: macos-26", run)
        self.assertIn("ci_builtin_blur_preheat.py run", run)
        self.assertNotIn("continue-on-error", build+run)
        self.assertNotIn("setup-xcode", run)


if __name__ == "__main__":
    unittest.main()
