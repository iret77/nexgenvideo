from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
import zipfile
from unittest.mock import Mock, patch

from run_macos_tests import owned_crash_report

from ci_builtin_blur import (BACKTRACE, FAULT_IMAGES, IMAGES, PATHS, bind_normal_arm, crash_outcome,
    environment, intervals, memory_activity, owned_process, run_measured, sample_proof, selected_profile,
    shared_chain, signature)


class BuiltinBlurEvidenceTests(unittest.TestCase):
    def test_scribble_profile_injects_only_owned_flags_and_never_trusts_ambient_flags(self):
        self.assertEqual(environment({"PATH": "/usr/bin"}, "scribble"), {
            "PATH": "/usr/bin", "SWIFT_BACKTRACE": BACKTRACE,
            "MallocScribble": "1", "MallocDebugReport": "stderr"})
        for key in ("MallocScribble", "MallocDebugReport", "MallocPreScribble", "MallocStackLogging", "DYLD_LIBRARY_PATH"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                environment({key: "1"}, "scribble")
        for kind, expected in (("ci-builtin-blur", "normal"), ("ci-builtin-blur-scribble", "scribble")):
            with patch.dict("os.environ", {"REPLAY_KIND": kind}):
                self.assertEqual(selected_profile(), expected)
        with patch.dict("os.environ", {"REPLAY_KIND": "ci-runtime"}), self.assertRaises(ValueError):
            selected_profile()
        with self.assertRaises(ValueError):
            environment({}, "unknown")

    def test_activation_requires_one_native_banner_for_the_owned_pid(self):
        banner = "NGVBuiltinBlur(42,0x123abc) malloc: enabling scribbling to detect mods to free blocks\n"
        self.assertEqual(memory_activity(banner, 42, "scribble")["activationBannerCount"], 1)
        for text in ("", banner.replace("42,", "43,"), banner + banner, banner.replace("NGVBuiltinBlur", "other"),
                     banner.replace("0x123abc", "invalid"), "echo " + banner, banner.replace("enabling", "disabled")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                memory_activity(text, 42, "scribble")
        self.assertEqual(memory_activity("", 42, "normal")["activationBannerCount"], 0)
        with self.assertRaises(ValueError):
            memory_activity(banner, 42, "normal")

    @staticmethod
    def shared_report():
        images = [dict(name=name, uuid=value) for name, value in FAULT_IMAGES.items()]
        images.append(dict(name="libobjc.A.dylib", uuid="unbound"))
        index = {image["name"]: i for i, image in enumerate(images)}
        frames = [dict(symbol=symbol, imageIndex=index[name], imageOffset=offset) for name, offset, symbol in (
            ("libobjc.A.dylib", 0, "objc_class::realizeIfNeeded"),
            ("libobjc.A.dylib", 1, "object_getIndexedIvars"),
            ("Foundation", 353396, "-[NSData(NSData) getBytes:length:]"),
            ("AppleParavirtGPUMetalIOGPUFamily", 131268, "unknown"),
            ("AppleParavirtGPUMetalIOGPUFamily", 55244, "unknown"),
            ("MPSCore", 487936, "unknown"),
            ("MPSCore", 487512, "MPSAutoCache::GetTempTexture"),
            ("MPSImage", 229648, "unknown"),
            ("CoreImage", 1186196, "+[CIBlurProcessor render]"))]
        return dict(osVersion=dict(build="26A428"), usedImages=images,
            exception=dict(signal="SIGSEGV", subtype="KERN_INVALID_ADDRESS"),
            threads=[dict(triggered=True, frames=frames, threadState=dict(far=dict(value=0),
                x=[dict(value=0) for _ in range(22)]))])

    def test_shared_chain_is_separate_from_original_signature_and_requires_exact_bound_frames(self):
        original = self.shared_report()
        self.assertTrue(shared_chain(original))
        self.assertFalse(signature(original))
        self.assertEqual(crash_outcome(-11, [original], "normal"), "C")
        self.assertEqual(crash_outcome(-11, [original], "scribble"), "G")
        for mutation in ("uuid", "offset", "image", "signal", "os", "two-faults", "adjacency", "missing-blur", "bool-index", "order"):
            report = deepcopy(original)
            frames = report["threads"][0]["frames"]
            if mutation == "uuid": report["usedImages"][0]["uuid"] = "0" * 36
            elif mutation == "offset": frames[2]["imageOffset"] = 353401
            elif mutation == "image": frames[3]["imageIndex"] = frames[2]["imageIndex"]
            elif mutation == "signal": report["exception"]["signal"] = "SIGABRT"
            elif mutation == "os": report["osVersion"]["build"] = "wrong"
            elif mutation == "two-faults": report["threads"].append(deepcopy(report["threads"][0]))
            elif mutation == "adjacency": frames.insert(3, dict(symbol="other", imageIndex=0))
            elif mutation == "missing-blur": frames.pop()
            elif mutation == "bool-index": frames[3]["imageIndex"] = True
            elif mutation == "order": frames[6], frames[8] = frames[8], frames[6]
            with self.subTest(mutation=mutation):
                self.assertFalse(shared_chain(report))

    def test_scribble_pattern_preserves_raw_and_masked_evidence_without_accepting_unrelated_crashes(self):
        report = self.shared_report()
        state = report["threads"][0]["threadState"]
        state["far"]["value"] = 0x5555555555555555
        self.assertEqual(crash_outcome(-11, [report], "scribble"), "F")
        report["exception"]["signal"] = "SIGBUS"
        self.assertEqual(crash_outcome(-10, [report], "scribble"), "F")
        self.assertEqual(crash_outcome(-11, [report], "scribble"), "C")
        state["far"]["value"] = 0
        state["x"][16]["value"] = 0x5555555555555555
        self.assertEqual(crash_outcome(-10, [report], "scribble"), "F")
        state["x"][16]["value"] = 0x0055555555555550
        self.assertEqual(crash_outcome(-10, [report], "scribble"), "G")
        report["threads"][0]["frames"][0]["symbol"] = "objc_msgSend"
        self.assertEqual(crash_outcome(-10, [report], "scribble"), "F")
        state["x"][16]["value"] = 0
        for value in (0x0055555555555560, 0x555555555570, 0x555555560, 0x5555555555D0):
            state["far"]["value"] = value
            self.assertEqual(crash_outcome(-10, [report], "scribble"), "F")
        for value in (0, 0x55555555, 0x55555555554F, 0x5555555555D1, 0x555555555650, True):
            state["far"]["value"] = value
            self.assertEqual(crash_outcome(-10, [report], "scribble"), "G")
        state["far"]["value"] = 0
        state["x"][20]["value"] = 0x5555555555555555
        self.assertEqual(crash_outcome(-10, [report], "scribble"), "F")
        report["threads"][0]["frames"].pop()
        self.assertEqual(crash_outcome(-10, [report], "scribble"), "C")
        self.assertEqual(crash_outcome(-11, [], "scribble"), "V")
        self.assertEqual(crash_outcome(-11, [report, report], "scribble"), "V")

    def test_normal_arm_binding_rejects_wrong_producer_archive_source_and_owned_crash(self):
        source, head, uuid = "a" * 40, "b" * 40, "12345678-1234-1234-1234-123456789abc"
        source_bytes, executable = b"normal source", b"normal binary"
        sha = lambda data: hashlib.sha256(data).hexdigest()
        for change in (None, "attempt", "source", "run", "actor", "branch", "artifact-name", "expired", "job", "step", "time", "digest",
                       "size", "paths", "result", "binary", "source-bytes", "pid", "uuid", "chain", "receipt"):
            report = self.shared_report()
            report.update(pid=42, parentPid=12, procLaunch="1970-01-01T00:16:40Z", captureTime="1970-01-01T00:16:41Z")
            report["usedImages"].append(dict(name="NGVBuiltinBlur", uuid=uuid))
            context = dict(pid=42, parentPID=12, launchEarliest=1000, launchLatest=1000.1,
                exitObserved=1002, exitCode=-11, hostSHA256=sha(executable), hostUUID=uuid)
            binary = dict(sha256=sha(executable), sourceSHA256=sha(source_bytes), productCode=False,
                uuid=f"UUID: {uuid} (arm64) /original/NGVBuiltinBlur")
            result = dict(outcome="C", productAcceptance=False, abnormalProcess=42)
            run = dict(id=40093865040, head_branch="iret77/activity-approval-layout", actor=dict(login="iret77"),
                run_attempt=1, head_sha=source, path=".github/workflows/diagnostic-acceptance.yml",
                repository=dict(full_name="iret77/nexgenvideo"), event="workflow_dispatch", status="completed", conclusion="failure")
            job_list = [dict(name=name, conclusion=conclusion, run_attempt=1, run_id=40093865040, head_sha=source,
                status="completed", started_at="01", completed_at="05", steps=[dict(conclusion="failure",
                    name="Compile and execute bounded standalone blur experiment")])
                for name, conclusion in (("source", "success"), ("ci-builtin-blur", "failure"))]
            if change == "attempt": run["run_attempt"] = 2
            elif change == "source": run["head_sha"] = head
            elif change == "run": run["id"] = 123
            elif change == "actor": run["actor"]["login"] = "other"
            elif change == "branch": run["head_branch"] = "other"
            elif change == "job": job_list[1]["head_sha"] = head
            elif change == "step": job_list[1]["steps"][0]["name"] = "Upload"
            elif change == "time": job_list[1]["completed_at"] = "01"
            elif change == "result": result["outcome"] = "N"
            elif change == "binary": binary["sha256"] = "0" * 64
            elif change == "source-bytes": binary["sourceSHA256"] = "0" * 64
            elif change == "pid": report["pid"] = 99
            elif change == "uuid": context["hostUUID"] = "0" * 36
            elif change == "chain": report["threads"][0]["frames"].pop()
            ips = json.dumps(dict(bug_type="309")).encode() + b"\n" + json.dumps(report).encode()
            receipt = dict(status="bound-report-captured", reports=[dict(sha256=sha(ips))])
            if change == "receipt": receipt["reports"][0]["sha256"] = "0" * 64
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, "w") as z:
                for name, value in (("binary.json", binary), ("result.json", result),
                        ("process-042/exit.json", context), ("process-042/post-mortem/receipt.json", receipt)):
                    z.writestr(name, json.dumps(value))
                z.writestr("NGVBuiltinBlur", executable)
                z.writestr("process-042/post-mortem/owned-host-0.ips", ips)
            raw = archive.getvalue()
            artifact = dict(workflow_run=dict(id=40093865040, head_sha=source), name="builtin-blur-40093865040-a1", id=456,
                digest="sha256:" + sha(raw), expired=False, created_at="02", updated_at="03", size_in_bytes=len(raw))
            if change == "artifact-name": artifact["name"] = "other"
            elif change == "expired": artifact["expired"] = True
            elif change == "digest": artifact["digest"] = "sha256:" + "0" * 64
            elif change == "size": artifact["size_in_bytes"] += 1
            env = dict(PRODUCT_SHA=source, PRODUCTS_ID="456", PRODUCTS_DIGEST=sha(raw))
            records = {"actions/artifacts/456": artifact, "actions/runs/40093865040": run,
                       "actions/runs/40093865040/attempts/1/jobs?per_page=100": dict(total_count=2, jobs=job_list)}
            def fake_command(args):
                return "\n".join(PATHS if change != "paths" else {"Sources/Product.swift"}) if args[1] == "diff" else ""
            def download(args, **kwargs):
                self.assertEqual(args, ["gh", "api", "repos/iret77/nexgenvideo/actions/artifacts/456/zip"])
                kwargs["stdout"].write(raw)
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary, \
                    patch.dict("os.environ", env), patch("ci_builtin_blur.api", side_effect=records.__getitem__), \
                    patch("ci_builtin_blur.command", side_effect=fake_command), \
                    patch("ci_builtin_blur.subprocess.run", side_effect=download), \
                    patch("ci_builtin_blur.subprocess.check_output", return_value=source_bytes):
                if change is None:
                    self.assertEqual(bind_normal_arm(Path(temporary), head)["artifactSHA256"], sha(raw))
                else:
                    with self.assertRaises(ValueError):
                        bind_normal_arm(Path(temporary), head)

    def test_retained_normal_crash_projection_keeps_original_c_and_owned_binding(self):
        # Projection of artifact12559669733 IPS65a6f89b; paths omitted and image indices remapped.
        report = json.loads(r'''{
  "pid": 1063,
  "parentPid": 925,
  "procLaunch": "2026-10-24 12:49:04.6282 +0000",
  "captureTime": "2026-10-24 12:49:04.6805 +0000",
  "osVersion": {
    "build": "26A428"
  },
  "exception": {
    "codes": "0x0000000000000001, 0x0000000000000000",
    "rawCodes": [
      1,
      0
    ],
    "type": "EXC_BAD_ACCESS",
    "signal": "SIGSEGV",
    "subtype": "KERN_INVALID_ADDRESS at 0x0000000000000000"
  },
  "usedImages": [
    {
      "name": "NGVBuiltinBlur",
      "uuid": "eca195c6-44b0-4751-ad17-facb4e8f32bf"
    },
    {
      "name": "AppleParavirtGPUMetalIOGPUFamily",
      "uuid": "dcf34873-17ed-339e-9007-daa8138d85ea"
    },
    {
      "name": "MPSCore",
      "uuid": "95e809a5-cd68-36b9-8c22-5b11055368d4"
    },
    {
      "name": "MPSImage",
      "uuid": "d09927cc-5c30-3542-ac58-dac8507b7e10"
    },
    {
      "name": "CoreImage",
      "uuid": "374bb926-bf7c-3439-843c-d6e5f0d518f6"
    },
    {
      "name": "Foundation",
      "uuid": "4317f7c6-73d2-3be9-b010-f318f1198a1b"
    },
    {
      "name": "libsystem_pthread.dylib",
      "uuid": "5a1828c3-cbc2-3b85-bd07-c8ed10021a41"
    },
    {
      "name": "libobjc.A.dylib",
      "uuid": "c0680df6-9900-3c29-a071-95a031686ef8"
    }
  ],
  "threads": [
    {
      "triggered": true,
      "threadState": {
        "far": {
          "value": 0
        },
        "x": [
          {
            "value": 0
          },
          {
            "value": 8422799904,
            "objc-selector": "bytes"
          },
          {
            "value": 6138360816
          },
          {
            "value": 16
          },
          {
            "value": 516017100224
          },
          {
            "value": 516017097152
          },
          {
            "value": 1
          },
          {
            "value": 18446744072367376383
          },
          {
            "value": 0
          },
          {
            "value": 8422799904,
            "objc-selector": "bytes"
          },
          {
            "value": 516295701352
          },
          {
            "value": 7
          },
          {
            "value": 4
          },
          {
            "value": 516012819888
          },
          {
            "value": 8176028873,
            "symbolLocation": 1,
            "symbol": "OBJC_CLASS_$__NSInlineData"
          },
          {
            "value": 8176028872,
            "symbolLocation": 0,
            "symbol": "OBJC_CLASS_$__NSInlineData"
          },
          {
            "value": 6464933900,
            "symbolLocation": 0,
            "symbol": "object_getIndexedIvars"
          },
          {
            "value": 8205401800
          },
          {
            "value": 0
          },
          {
            "value": 0
          },
          {
            "value": 0
          },
          {
            "value": 516017806400
          },
          {
            "value": 516017096704
          },
          {
            "value": 516013923968
          },
          {
            "value": 6138361104
          },
          {
            "value": 0
          },
          {
            "value": 1464
          },
          {
            "value": 6138361728
          },
          {
            "value": 4337307120
          }
        ]
      },
      "frames": [
        {
          "imageOffset": 143664,
          "symbol": "objc_class::realizeIfNeeded()",
          "imageIndex": 7
        },
        {
          "imageOffset": 53352,
          "symbol": "object_getIndexedIvars",
          "imageIndex": 7
        },
        {
          "imageOffset": 353396,
          "symbol": "-[NSData(NSData) getBytes:length:]",
          "imageIndex": 5
        },
        {
          "imageOffset": 131268,
          "imageIndex": 1
        },
        {
          "imageOffset": 55244,
          "imageIndex": 1
        },
        {
          "imageOffset": 487936,
          "imageIndex": 2
        },
        {
          "imageOffset": 487512,
          "symbol": "MPSAutoCache::GetTempTexture(MPSPixelInfo const*, MTLSize const*, MTLTextureDescriptor*, bool, TextureSizeAndAlign*, bool)",
          "imageIndex": 2
        },
        {
          "imageOffset": 229648,
          "imageIndex": 3
        },
        {
          "imageOffset": 300692,
          "imageIndex": 3
        },
        {
          "imageOffset": 118628,
          "imageIndex": 3
        },
        {
          "imageOffset": 1186196,
          "symbol": "+[CIBlurProcessor processWithInputs:arguments:output:error:]",
          "imageIndex": 4
        },
        {
          "imageOffset": 1378156,
          "symbol": "__75+[CIImageProcessorKernel applyWithExtent:inputs:arguments:tileRects:error:]_block_invoke.219",
          "imageIndex": 4
        },
        {
          "imageOffset": 3177492,
          "symbol": "CI::ProcessorNode::render(CI::TileTask*, CI::Context*, std::__1::vector<CI::intermediate_t const*, std::__1::allocator<CI::intermediate_t const*>> const&, std::__1::vector<CI::intermediate_t const*, std::__1::allocator<CI::intermediate_t const*>> const&, CI::RenderDestination const*, CGRect const&, int) const",
          "imageIndex": 4
        },
        {
          "imageOffset": 2822780,
          "symbol": "CI::Context::render_processor_node(CI::RenderDestination const*, CI::TileTask*, CI::parentROI const&, __IOSurface*, id<MTLTexture>)",
          "imageIndex": 4
        },
        {
          "imageOffset": 2794532,
          "symbol": "CI::MetalContext::render_node(CI::RenderDestination const*, CI::TileTask*, CI::parentROI const&, CGRect const&, id<MTLTexture>*, __CVBuffer**, __IOSurface**, unsigned long)",
          "imageIndex": 4
        },
        {
          "imageOffset": 2801240,
          "symbol": "CI::MetalContext::render_intermediate_node(CI::TileTask*, CI::parentROI const&, CI::intermediate_t*, bool, void () block_pointer)",
          "imageIndex": 4
        },
        {
          "imageOffset": 2815608,
          "symbol": "CI::Context::recursive_render(CI::RenderDestination const*, CI::TileTask*, CI::roiKey const&, CI::Node const*, bool)",
          "imageIndex": 4
        },
        {
          "imageOffset": 2816004,
          "symbol": "CI::Context::recursive_render(CI::RenderDestination const*, CI::TileTask*, CI::roiKey const&, CI::Node const*, bool)",
          "imageIndex": 4
        },
        {
          "imageOffset": 2820152,
          "symbol": "CI::Context::render(CI::ProgramNode*, CGRect const&, CI::RenderDestination const*)",
          "imageIndex": 4
        },
        {
          "imageOffset": 3290020,
          "symbol": "invocation function for block in CI::image_render(char const*, CI::Context*, CI::Image*, CI::RenderDestination const*)",
          "imageIndex": 4
        },
        {
          "imageOffset": 3309944,
          "symbol": "CI::recursive_tile(CI::RenderTask*, CI::Context*, CI::RenderDestination const*, char const*, CI::GraphWithDepth, CGRect const&, CI::PixelFormat, CI::output_swizzle_info const&, CI::TileTask* (CI::ProgramNode*, CGRect) block_pointer)",
          "imageIndex": 4
        },
        {
          "imageOffset": 3289356,
          "symbol": "CI::tile_node_graph(CI::Context*, CI::RenderDestination const*, char const*, CI::GraphWithDepth, CGRect const&, CI::PixelFormat, CI::output_swizzle_info const&, CI::TileTask* (CI::ProgramNode*, CGRect) block_pointer)",
          "imageIndex": 4
        },
        {
          "imageOffset": 3288272,
          "symbol": "CI::image_render(char const*, CI::Context*, CI::Image*, CI::RenderDestination const*)",
          "imageIndex": 4
        },
        {
          "imageOffset": 3272776,
          "symbol": "CI::RenderToTexture<CI::Texture>::render_to_texture(CI::Image*, CI::Context*, CGSize const&, CI::Texture) const",
          "imageIndex": 4
        },
        {
          "imageOffset": 3273960,
          "symbol": "CI::RenderToMTLTexture::render(CI::Image*, CI::Context*) const",
          "imageIndex": 4
        },
        {
          "imageOffset": 108252,
          "symbol": "-[CIRenderDestination _render:withContext:]",
          "imageIndex": 4
        },
        {
          "imageOffset": 105976,
          "symbol": "-[CIContext(CIRenderDestination) _startTaskToRender:toDestination:forPrepareRender:forClear:error:]",
          "imageIndex": 4
        },
        {
          "imageOffset": 102956,
          "symbol": "-[CIContext(CIRenderDestination) startTaskToRender:fromRect:toDestination:atPoint:error:]",
          "imageIndex": 4
        },
        {
          "imageOffset": 16504,
          "symbol": "render(round:lane:folder:ready:go:)",
          "imageIndex": 0
        },
        {
          "imageOffset": 10592,
          "symbol": "closure #1 in closure #3 in ",
          "imageIndex": 0
        },
        {
          "imageOffset": 42092,
          "symbol": "partial apply for closure #1 in closure #3 in ",
          "imageIndex": 0
        },
        {
          "imageOffset": 21632,
          "symbol": "autoreleasepool<A, B>(invoking:)",
          "imageIndex": 0
        },
        {
          "imageOffset": 9936,
          "symbol": "closure #3 in ",
          "imageIndex": 0
        },
        {
          "imageOffset": 24584,
          "symbol": "thunk for @escaping @callee_guaranteed @Sendable () -> ()",
          "imageIndex": 0
        },
        {
          "imageOffset": 2167228,
          "symbol": "__NSThread__block_start__",
          "imageIndex": 5
        },
        {
          "imageOffset": 27904,
          "symbol": "_pthread_start",
          "imageIndex": 6
        },
        {
          "imageOffset": 7404,
          "symbol": "thread_start",
          "imageIndex": 6
        }
      ]
    }
  ]
}''')
        context = {'pid': 1063, 'parentPID': 925, 'launchEarliest': 1792846144.628018, 'launchLatest': 1792846144.629327, 'exitObserved': 1792846144.6662982, 'hostUUID': 'eca195c6-44b0-4751-ad17-facb4e8f32bf'}
        raw = b'{"bug_type":"309"}\n' + json.dumps(report).encode()
        owned_crash_report(raw, context)
        self.assertTrue(shared_chain(report))
        self.assertFalse(signature(report))
        self.assertEqual(crash_outcome(-11, [report], "normal"), "C")
        self.assertEqual(crash_outcome(-11, [report], "scribble"), "G")

    def test_scribble_process_passes_profile_and_stops_on_missing_activation(self):
        for enabled in (True, False):
            process = Mock(pid=42)
            process.wait.return_value = 0
            process.poll.return_value = 0
            with tempfile.TemporaryDirectory() as temporary:
                def launch(args, **kwargs):
                    self.assertEqual(args[-2:], ["measured", "scribble"])
                    self.assertEqual(kwargs["env"]["MallocScribble"], "1")
                    self.assertEqual(kwargs["env"]["MallocDebugReport"], "stderr")
                    if enabled:
                        kwargs["stderr"].write(b"NGVBuiltinBlur(42,0x123) malloc: enabling scribbling to detect mods to free blocks\n")
                    return process
                with patch("ci_builtin_blur.prepare_post_mortem", return_value={"hostUUID": "test"}), \
                        patch("ci_builtin_blur.subprocess.Popen", side_effect=launch), \
                        patch.dict("os.environ", {}, clear=True):
                    outcome, _ = owned_process(Path("binary"), Path(temporary) / "child", "measured", 1e30, "scribble")
                self.assertEqual(outcome, "clean" if enabled else "V")

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
        for outcome in ("R", "F", "G", "C", "V"):
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
