from contextlib import ExitStack
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import struct
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import uuid
import zipfile

import ci_builtin_blur_floor as floor
from ci_builtin_blur import BACKTRACE, PATHS, bind_normal_arm, owned_process, run_measured, sample_proof


def executable():
    name = b"/usr/lib/libSystem.B.dylib\0"
    length = (24 + len(name) + 7) & ~7
    commands = struct.pack("<6I", 0x32, 24, 1, 26 << 16, 27 << 16, 0)
    commands += struct.pack("<II", 0x1B, 24) + uuid.UUID(floor.UUID).bytes
    commands += struct.pack("<6I", 0xC, length, 24, 0, 0, 0) + name.ljust(length - 24, b"\0")
    return struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 3, len(commands), 0, 0) + commands


class FloorRuntimeTests(unittest.TestCase):
    def test_binary_requires_original_uuid_arm64_floor_and_only_system_imports(self):
        raw = executable()
        self.assertEqual(floor.binary_proof(raw)["imports"], ["/usr/lib/libSystem.B.dylib"])
        for label, offset, value in (("cpu", 4, 7), ("filetype", 12, 6), ("count", 16, 2),
                ("load-size", 36, 7), ("platform", 40, 2), ("floor", 44, 27 << 16),
                ("uuid", 64, 0), ("rpath", 80, 0x8000001C), ("string-offset", 88, 999)):
            mutated = bytearray(raw)
            struct.pack_into("<I", mutated, offset, value)
            with self.subTest(label=label), self.assertRaises(ValueError):
                floor.binary_proof(bytes(mutated))
        for mutated in (b"", raw[:31], raw[:-1], raw.replace(b"/usr/lib/", b"@rpath//")):
            with self.assertRaises(ValueError):
                floor.binary_proof(mutated)

    def test_archive_members_cannot_be_ambiguous_or_oversized(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("binary", b"original")
        with zipfile.ZipFile(io.BytesIO(buf.getvalue())) as z:
            self.assertEqual(floor.member(z, "binary"), b"original")
            for name, limit in (("absent", 100), ("binary", 2)):
                with self.assertRaises(ValueError):
                    floor.member(z, name, limit)

    def test_original_arguments_do_not_append_a_profile_or_enable_instrumentation(self):
        proc = Mock(pid=42)
        proc.wait.return_value = 0
        proc.poll.return_value = 0
        with tempfile.TemporaryDirectory() as temp, \
                patch("ci_builtin_blur.prepare_post_mortem", return_value={"hostUUID": "original"}), \
                patch("ci_builtin_blur.subprocess.Popen", return_value=proc) as launch, \
                patch.dict("os.environ", {}, clear=True):
            target = Path(temp) / "child"
            outcome, context = owned_process(Path("binary"), target, "measured", 1e30, original_arguments=True)
            self.assertEqual(launch.call_args.args[0], ["binary", str(target), "measured"])
            self.assertEqual(launch.call_args.kwargs["env"], {"SWIFT_BACKTRACE": BACKTRACE})
            self.assertEqual(context["argv"], launch.call_args.args[0])
            self.assertEqual(outcome, "clean")
        with self.assertRaises(ValueError):
            owned_process(Path("binary"), Path("not-created"), "measured", 1e30, "scribble", original_arguments=True)

    def test_measurement_forwards_original_arguments_and_keeps_first_failure_stop(self):
        result = dict(processesCompleted=0, roundsCompleted=0, overlappingRounds=0)
        with patch("ci_builtin_blur.time.monotonic", return_value=0), \
                patch("ci_builtin_blur.owned_process", side_effect=[("clean", {"pid": 42}), ("C", {})]) as run, \
                patch("ci_builtin_blur.intervals", return_value=4):
            run_measured(Path("binary"), Path("folder"), 1200, result, original_arguments=True)
        self.assertEqual(run.call_count, 2)
        self.assertTrue(all(call.kwargs["original_arguments"] is True for call in run.call_args_list))
        self.assertEqual(result["outcome"], "C")
        self.assertEqual(result["processesCompleted"], 1)

    def test_floor_sample_keeps_all_six_image_and_actual_stack_requirements(self):
        text = "Process: NGVBuiltinBlur [42]\nParent Process: Python [12]\n"
        text += "    + 10 CIBlurProcessor (in CoreImage)\n    +   10 MPSAutoCache::GetTempTexture (in MPSCore)\n"
        text += "\nBinary Images:\n" + "\n".join(f"0x1 - 0x2 <{value}> /System/Library/{name}" for name, value in floor.IMAGES.items())
        sample_proof(text, 42, 12, images=floor.IMAGES)
        with self.assertRaises(ValueError):
            sample_proof(text, 42, 12)
        for images in ({}, {"CoreImage": floor.IMAGES["CoreImage"]}):
            with self.assertRaises(ValueError):
                sample_proof(text, 42, 12, images=images)
        with self.assertRaises(ValueError):
            sample_proof(text.replace("CIBlurProcessor", "other"), 42, 12, images=floor.IMAGES)

    def test_historical_reference_rejects_wrong_run_job_image_or_archive(self):
        sample = "OS Version:      macOS 26.6.2 (25G83)\n" + "\n".join(
            f"0x1 - 0x2 <{value}> /System/Library/{name}" for name, value in floor.IMAGES.items() if name != "AppleParavirtGPUMetalIOGPUFamily")
        sample += "\n0x1 - 0x2 com.apple.driver.AppleParavirtGPUMetalIOGPUFamily (64.4.7 - 64.4.7) <" + floor.IMAGES["AppleParavirtGPUMetalIOGPUFamily"] + "> /System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle/Contents/MacOS/AppleParavirtGPUMetalIOGPUFamily"
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("termination/raw-control/sample.log", sample)
        raw = buf.getvalue()
        checksum = hashlib.sha256(raw).hexdigest()
        sample_hash = hashlib.sha256(sample.encode()).hexdigest()
        source = "9e93972b72f0a05b5b9a31bae10feb111a23a6b1"
        for mutation in (None, "expired", "attempt", "job", "time", "archive", "sample", "images", "version"):
            artifact = dict(id=12556008735, digest="sha256:" + checksum, expired=False,
                name="diagnostic-normal-startup", workflow_run=dict(id=40080033255, head_sha=source),
                created_at="02", updated_at="03", size_in_bytes=len(raw))
            run = dict(id=40080033255, run_attempt=1, head_sha=source, status="completed",
                repository=dict(full_name="iret77/nexgenvideo"), path=".github/workflows/ci-batch.yml")
            job = dict(id=120841910512, run_id=40080033255, run_attempt=1, head_sha=source,
                status="completed", conclusion="success", started_at="01", completed_at="04",
                name="Compile, unit tests, app and native bpy acceptance / diagnostic-startup")
            if mutation == "expired": artifact["expired"] = True
            elif mutation == "attempt": run["run_attempt"] = 2
            elif mutation == "job": job["conclusion"] = "failure"
            elif mutation == "time": artifact["created_at"] = "00"
            if mutation == "version":
                changed = sample.replace("(64.4.7 - 64.4.7)", "(65.0.0 - 65.0.0)")
                buf = io.BytesIO()
                with zipfile.ZipFile(buf, "w") as z: z.writestr("termination/raw-control/sample.log", changed)
                raw = buf.getvalue()
                checksum = hashlib.sha256(raw).hexdigest()
                sample_hash = hashlib.sha256(changed.encode()).hexdigest()
                artifact.update(digest="sha256:" + checksum, size_in_bytes=len(raw))
            records = {"actions/artifacts/12556008735": artifact, "actions/runs/40080033255": run,
                       "actions/jobs/120841910512": job}
            images = deepcopy(floor.IMAGES)
            if mutation == "images": images["CoreImage"] = "0" * 36
            def download(args, **kwargs):
                self.assertEqual(args[2], "repos/iret77/nexgenvideo/actions/artifacts/12556008735/zip")
                kwargs["stdout"].write(raw if mutation != "archive" else b"bad")
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temp, \
                    patch.object(floor, "api", side_effect=records.__getitem__), \
                    patch.object(floor.subprocess, "run", side_effect=download), \
                    patch.object(floor, "FLOOR_ARCHIVE", checksum), \
                    patch.object(floor, "FLOOR_SAMPLE", sample_hash if mutation != "sample" else "0" * 64), \
                    patch.object(floor, "IMAGES", images):
                if mutation is None:
                    floor.bind_floor_reference(Path(temp))
                else:
                    with self.assertRaises(ValueError):
                        floor.bind_floor_reference(Path(temp))

    def test_runtime_rejects_unbound_harness_before_starting_any_process(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(floor, "owned_process") as run, \
                patch.dict("os.environ", {"REPLAY_KIND": "ci-builtin-blur-floor", "GITHUB_SHA": "a" * 40}):
            root = Path(temp)
            (root / "binding.json").write_text(json.dumps({"harnessSHA": "b" * 40}))
            with self.assertRaises(ValueError):
                floor.execute(root / "evidence", root, {})
            run.assert_not_called()

    def test_platform_fails_closed_on_os_architecture_or_driver_drift(self):
        for mutation in (None, "build", "arch", "version"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temp:
                folder = Path(temp)
                (folder / "Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "wrong" if mutation == "version" else "64.4.7"}))
                outputs = {"os": "macOS26.6.2", "build": "25G83", "arch": "arm64", "model": "VirtualMac",
                    "driver": "UUID: " + floor.IMAGES["AppleParavirtGPUMetalIOGPUFamily"] + " (arm64e) /System/Library/driver\n",
                    "displays": '{"SPDisplaysDataType":[{"sppci_model":"Apple Paravirtual device"}]}'}
                if mutation in outputs: outputs[mutation] = "wrong"
                with patch.object(floor, "DRIVER", folder), patch.object(floor, "probe", side_effect=lambda folder, name, args: outputs[name]):
                    if mutation is None: floor.platform(folder)
                    else:
                        with self.assertRaises(ValueError): floor.platform(folder)

    def test_failed_platform_probe_keeps_both_original_streams(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            with patch.object(floor.subprocess, "run", return_value=Mock(returncode=1, stdout=b"original out", stderr=b"original err")):
                with self.assertRaises(ValueError): floor.probe(folder, "failure", ["tool"])
            self.assertEqual((folder / "failure.stdout").read_bytes(), b"original out")
            self.assertEqual((folder / "failure.stderr").read_bytes(), b"original err")
            with patch.object(floor.subprocess, "run", side_effect=subprocess.TimeoutExpired("tool", 40, output=b"partial", stderr=b"why")):
                with self.assertRaises(subprocess.TimeoutExpired): floor.probe(folder, "timeout", ["tool"])
            self.assertEqual((folder / "timeout.stdout").read_bytes(), b"partial")
            self.assertEqual((folder / "timeout.stderr").read_bytes(), b"why")

    def test_workflow_floor_job_only_consumes_bound_binary_and_preserves_other_modes(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/diagnostic-acceptance.yml").read_text()
        job = workflow.split("  ci-builtin-blur-floor:\n", 1)[1].split("  ci-builtin-blur:\n", 1)[0]
        self.assertIn("needs: source", job)
        self.assertIn("runs-on: macos-26", job)
        self.assertIn("ci-lint: allow-CI005", job.split("runs-on: macos-26", 1)[0].rstrip().splitlines()[-1])
        self.assertIn("ci_builtin_blur_floor.py run", job)
        self.assertIn("name: builtin-blur-floor-binding", job)
        for forbidden in ("swiftc", "xcodebuild", "swift build", "setup-xcode", "continue-on-error"):
            self.assertNotIn(forbidden, job)
        shared = workflow.split("      - name: Bind the successful release job", 1)[1].split("  ci-builtin-blur-floor:", 1)[0]
        self.assertIn("inputs.candidate_kind != 'ci-builtin-blur-floor'", shared)
        self.assertEqual(floor.FLOOR_PATHS - PATHS, {"scripts/ci_builtin_blur_floor.py", "scripts/test_ci_builtin_blur_floor.py"})

    def test_platform_records_remaining_probes_after_failure_or_missing_plist(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            def output(folder, name, args):
                if name == "os": raise ValueError("original probe failed")
                return {"build": "25G83", "arch": "arm64", "model": "VirtualMac", "displays": "{}"}[name]
            with patch.object(floor, "DRIVER", folder / "missing"), patch.object(floor, "probe", side_effect=output) as run:
                with self.assertRaises(ValueError): floor.platform(folder)
            receipt = json.loads((folder / "platform.json").read_text())
            self.assertEqual(run.call_count, 5)
            self.assertEqual(receipt["build"], "25G83")
            self.assertEqual(receipt["arch"], "arm64")
            self.assertEqual(set(receipt["errors"]), {"os", "driverVersion"})

    def test_bind_checks_inputs_original_arguments_and_exact_floor_allowlist(self):
        expected = dict(REPLAY_KIND="ci-builtin-blur-floor", CANDIDATE_RUN="40093865040",
            CANDIDATE_SOURCE=floor.SOURCE, CANDIDATE_ARTIFACT="12559669733",
            CANDIDATE_DIGEST=floor.ARCHIVE, GITHUB_SHA="a" * 40)
        for mutation in (None, *expected, "PRODUCT_SHA", "PRODUCTS_ID", "PRODUCTS_DIGEST",
                         "FAILURE_ID", "FAILURE_DIGEST", "argv", "binary"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
                folder = Path(temp) / "binding"
                env = dict(expected)
                if mutation in expected or mutation in {"PRODUCT_SHA", "PRODUCTS_ID", "PRODUCTS_DIGEST", "FAILURE_ID", "FAILURE_DIGEST"}:
                    env[mutation] = "wrong"
                stack.enter_context(patch.dict("os.environ", env, clear=True))
                source = "guard CommandLine.arguments.count == 3 else { exit(2) }"
                def command(args):
                    if args[1] == "rev-parse": return "a" * 40
                    if args[1] == "status": return ""
                    return source.replace("== 3", "== 4") if mutation == "argv" else source
                stack.enter_context(patch.object(floor, "command", side_effect=command))
                def normal(target, head, **kwargs):
                    self.assertEqual(kwargs["allowed_paths"], floor.FLOOR_PATHS)
                    self.assertEqual(kwargs["identity"], (floor.SOURCE, floor.ARCHIVE, 12559669733))
                    with zipfile.ZipFile(target / "normal-arm.zip", "w") as z: z.writestr("NGVBuiltinBlur", b"original")
                    return {"binarySHA256": "wrong" if mutation == "binary" else floor.BINARY}
                normal_call = stack.enter_context(patch.object(floor, "bind_normal_arm", side_effect=normal))
                stack.enter_context(patch.object(floor, "binary_proof", return_value={"uuid": floor.UUID}))
                stack.enter_context(patch.object(floor, "bind_floor_reference"))
                stack.enter_context(patch.object(floor, "digest", return_value="hash"))
                if mutation is None:
                    floor.bind(folder)
                    self.assertTrue((folder / "binding.json").exists())
                    normal_call.assert_called_once()
                else:
                    with self.assertRaises(ValueError): floor.bind(folder)
                    if mutation != "binary": normal_call.assert_not_called()
        for paths in (PATHS, floor.FLOOR_PATHS | {"scripts/run_macos_tests.py"}):
            with patch("ci_builtin_blur.command", side_effect=["", "\n".join(sorted(paths))]), \
                    patch("ci_builtin_blur.api") as api:
                with self.assertRaises(ValueError):
                    bind_normal_arm(Path("unused"), "a" * 40,
                        identity=(floor.SOURCE, floor.ARCHIVE, 12559669733), allowed_paths=floor.FLOOR_PATHS)
                api.assert_not_called()

    def test_execute_orders_identity_checks_and_maps_every_outcome(self):
        cases = ("N", "C", "V", "R", "calibration", "platform", "archive", "binary", "image", "sample", "sample-images")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temp, ExitStack() as stack:
                root = Path(temp)
                metadata = root / "metadata"
                metadata.mkdir()
                folder = root / "evidence"
                raw = b"original executable"
                binary_hash = hashlib.sha256(raw).hexdigest()
                image = {"uuid": floor.UUID}
                binding = dict(harnessSHA="a" * 40, harnessHashes={f: "hash" for f in floor.FLOOR_PATHS | floor.HELPERS},
                    build="25G83", images=floor.IMAGES, normalArm={"artifactSHA256": floor.ARCHIVE, "binarySHA256": binary_hash}, binary=image)
                (metadata / "binding.json").write_text(json.dumps(binding))
                with zipfile.ZipFile(metadata / "normal-arm.zip", "w") as z:
                    z.writestr("NGVBuiltinBlur", b"changed" if case == "binary" else raw)
                stack.enter_context(patch.dict("os.environ", {"REPLAY_KIND": "ci-builtin-blur-floor", "GITHUB_SHA": "a" * 40}, clear=True))
                stack.enter_context(patch.object(floor, "BINARY", binary_hash))
                stack.enter_context(patch.object(floor, "command", return_value="a" * 40))
                events = []
                def checksum(path):
                    if path.name == "normal-arm.zip":
                        events.append("archive")
                        return "wrong" if case == "archive" else floor.ARCHIVE
                    return "hash"
                stack.enter_context(patch.object(floor, "digest", side_effect=checksum))
                def platform(folder):
                    events.append("platform")
                    if case == "platform": raise ValueError("platform drift")
                stack.enter_context(patch.object(floor, "platform", side_effect=platform))
                def proof(raw):
                    events.append("image")
                    return {} if case == "image" else image
                stack.enter_context(patch.object(floor, "binary_proof", side_effect=proof))
                stack.enter_context(patch.object(floor, "probe", return_value=""))
                def calibration(binary, target, mode, deadline, **kwargs):
                    events.append("calibration")
                    self.assertTrue(kwargs["original_arguments"])
                    self.assertEqual(events[:3], ["platform", "archive", "image"])
                    target.mkdir()
                    (target / "sample.txt").write_text("OS Version: macOS 26.6.2 (" + ("wrong" if case == "sample" else "25G83") + ")\n")
                    return ("C" if case == "calibration" else "clean"), {"pid": 42, "sampleExitCode": 0}
                launch = stack.enter_context(patch.object(floor, "owned_process", side_effect=calibration))
                def sample(*args, **kwargs):
                    events.append("sample")
                    self.assertEqual(kwargs["images"], floor.IMAGES)
                    if case == "sample-images": raise ValueError("UUID drift")
                stack.enter_context(patch.object(floor, "sample_proof", side_effect=sample))
                def measure(binary, target, deadline, result, **kwargs):
                    self.assertEqual(events[-1], "sample")
                    self.assertTrue(kwargs["original_arguments"])
                    result["outcome"] = case
                measured = stack.enter_context(patch.object(floor, "run_measured", side_effect=measure))
                result = {}
                if case in {"N", "C", "V", "R", "calibration"}:
                    self.assertEqual(floor.execute(folder, metadata, result), 0 if case == "N" else 1)
                    self.assertEqual(result["outcome"], {"N": "FN", "C": "FC"}.get(case, "FV"))
                    if case == "calibration": measured.assert_not_called()
                else:
                    with self.assertRaises(ValueError): floor.execute(folder, metadata, result)
                    measured.assert_not_called()
                    if case in {"platform", "archive", "binary", "image"}: launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
