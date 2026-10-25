"""Bound, standalone Core Image experiment; never a product acceptance gate."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import zipfile

from app_host_zombie_diagnostic import diagnostic_key
from run_macos_tests import prepare_post_mortem, capture_post_mortem, owned_crash_report
from verify_diagnostic_candidate import verify_app_diagnostic, verify_app_crash_archive


PATHS = {".github/workflows/diagnostic-acceptance.yml", "scripts/ci_builtin_blur.py",
         "scripts/ci_builtin_blur.swift", "scripts/test_ci_builtin_blur.py"}
IMAGES = {
    "AppleParavirtGPUMetalIOGPUFamily": "dcf34873-17ed-339e-9007-daa8138d85ea",
    "IOGPU": "3959324f-d63d-3387-8e97-238f27a76b74",
    "CoreImage": "374bb926-bf7c-3439-843c-d6e5f0d518f6",
    "MPSCore": "95e809a5-cd68-36b9-8c22-5b11055368d4",
    "MPSImage": "d09927cc-5c30-3542-ac58-dac8507b7e10",
    "Metal": "b0bc74fe-7080-347d-92ee-38195058ccce",
}
FAULT_IMAGES = {name: value for name, value in IMAGES.items() if name not in {"Metal", "IOGPU"}}
FAULT_IMAGES["Foundation"] = "4317f7c6-73d2-3be9-b010-f318f1198a1b"
BACKTRACE = "enable=yes,interactive=no,demangle=yes,cache=no"


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args, timeout=40):
    return subprocess.check_output(args, stdin=subprocess.DEVNULL, timeout=timeout, text=True)


def api(path):
    return json.loads(command(["gh", "api", "repos/iret77/nexgenvideo/" + path]))


def environment(source, profile="normal"):
    if profile not in {"normal", "scribble"}:
        raise ValueError("Unknown memory diagnostic profile")
    if any(diagnostic_key(key.encode()) or key.startswith("DYLD_") for key in source):
        raise ValueError("Ambient diagnostic changes would invalidate the experiment")
    if source.get("SWIFT_BACKTRACE", BACKTRACE) != BACKTRACE:
        raise ValueError("Unexpected Swift backtrace settings")
    result = dict(source, SWIFT_BACKTRACE=BACKTRACE)
    if profile == "scribble":
        result["MallocScribble"] = "1"
        result["MallocDebugReport"] = "stderr"
    return result


def selected_profile():
    kind = os.environ["REPLAY_KIND"]
    if kind not in {"ci-builtin-blur", "ci-builtin-blur-scribble"}:
        raise ValueError("Unexpected workflow mode")
    return "scribble" if kind.endswith("-scribble") else "normal"


def bind_normal_arm(folder, head, *, identity=None, allowed_paths=PATHS):
    source, checksum, artifact_id = identity or (
        os.environ["PRODUCT_SHA"], os.environ["PRODUCTS_DIGEST"], int(os.environ["PRODUCTS_ID"]))
    if not re.fullmatch(r"[0-9a-f]{40}", source) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("Malformed normal-arm identity")
    command(["git", "merge-base", "--is-ancestor", source, head])
    if set(command(["git", "diff", "--no-renames", "--name-only", source, head]).splitlines()) != allowed_paths:
        raise ValueError("Normal-arm continuation differs from its exact diagnostic file list")
    artifact = api(f"actions/artifacts/{artifact_id}")
    run_id = artifact["workflow_run"]["id"]
    run = api(f"actions/runs/{run_id}")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    if (run_id != 40093865040 or run.get("id") != run_id
            or run.get("head_branch") != "iret77/activity-approval-layout"
            or run.get("actor", {}).get("login") != "iret77"
            or run.get("run_attempt") != 1 or run.get("head_sha") != source
            or run.get("path") != ".github/workflows/diagnostic-acceptance.yml"
            or run.get("repository", {}).get("full_name") != "iret77/nexgenvideo"
            or run.get("event") != "workflow_dispatch" or run.get("status") != "completed"
            or run.get("conclusion") != "failure" or jobs.get("total_count") != len(jobs["jobs"])
            or artifact.get("name") != f"builtin-blur-{run_id}-a1"
            or artifact.get("id") != artifact_id or artifact.get("digest") != "sha256:" + checksum
            or artifact.get("expired") is not False or artifact["workflow_run"].get("head_sha") != source):
        raise ValueError("Normal-arm producer or artifact differs")
    producer = None
    for name, conclusion in (("source", "success"), ("ci-builtin-blur", "failure")):
        found = [j for j in jobs["jobs"] if j.get("name") == name]
        if (len(found) != 1 or found[0].get("run_attempt") != 1 or found[0].get("run_id") != run_id
                or found[0].get("head_sha") != source or found[0].get("status") != "completed"
                or found[0].get("conclusion") != conclusion):
            raise ValueError("Normal-arm job identity differs")
        if name == "ci-builtin-blur":
            producer = found[0]
    if ([s["name"] for s in producer["steps"] if s["conclusion"] == "failure"]
            != ["Compile and execute bounded standalone blur experiment"]
            or not producer["started_at"] <= artifact["created_at"] <= artifact["updated_at"] <= producer["completed_at"]):
        raise ValueError("Normal-arm failure or artifact attempt differs")
    archive = folder / "normal-arm.zip"
    with archive.open("xb") as stream:
        subprocess.run(["gh", "api", f"repos/iret77/nexgenvideo/actions/artifacts/{artifact_id}/zip"],
                       stdin=subprocess.DEVNULL, stdout=stream, check=True, timeout=120)
    if archive.stat().st_size != artifact["size_in_bytes"] or digest(archive) != checksum:
        raise ValueError("Normal-arm archive digest differs")
    with zipfile.ZipFile(archive) as original:
        def raw(name):
            entries = [i for i in original.infolist() if i.filename == name]
            if len(entries) != 1 or entries[0].file_size > 4 * 1024 * 1024:
                raise ValueError("Missing or oversized normal-arm record")
            return original.read(entries[0])
        result = json.loads(raw("result.json"))
        binary = json.loads(raw("binary.json"))
        source_bytes = subprocess.check_output(["git", "show", source + ":scripts/ci_builtin_blur.swift"], timeout=40)
        if (result.get("outcome") != "C" or result.get("productAcceptance") is not False
                or binary.get("productCode") is not False
                or binary.get("sourceSHA256") != hashlib.sha256(source_bytes).hexdigest()
                or binary.get("sha256") != hashlib.sha256(raw("NGVBuiltinBlur")).hexdigest()):
            raise ValueError("Normal-arm binary/source/result proof differs")
        index = result.get("abnormalProcess")
        if type(index) is not int or not 0 <= index < 200:
            raise ValueError("Missing abnormal process index")
        prefix = f"process-{index:03d}/"
        context = json.loads(raw(prefix + "exit.json"))
        receipt = json.loads(raw(prefix + "post-mortem/receipt.json"))
        if (context.get("exitCode") != -11 or context.get("hostSHA256") != binary["sha256"]
                or receipt.get("status") != "bound-report-captured" or len(receipt.get("reports", [])) != 1):
            raise ValueError("Normal-arm owned crash proof differs")
        report_bytes = raw(prefix + "post-mortem/owned-host-0.ips")
        if receipt["reports"][0].get("sha256") != hashlib.sha256(report_bytes).hexdigest():
            raise ValueError("Normal-arm crash receipt differs")
        uuids = re.findall(r"UUID: ([0-9a-fA-F-]{36}) \(arm64\)", binary.get("uuid", ""))
        if len(uuids) != 1 or context.get("hostUUID") != uuids[0].lower():
            raise ValueError("Normal-arm crash executable UUID differs")
        owned_crash_report(report_bytes, context)
        report = json.loads(report_bytes.split(b"\n", 1)[1])
        if not shared_chain(report):
            raise ValueError("Normal-arm crash is not on the declared shared allocation path")
    proof = {"runID": run_id, "attempt": 1, "sourceSHA": source, "artifactID": artifact_id,
             "artifactSHA256": checksum, "binarySHA256": binary["sha256"], "result": result}
    save(folder / "normal-arm-producer.json", {"run": run, "jobs": jobs, "artifact": artifact})
    return proof


def bind(folder):
    folder.mkdir()
    run_id, source = int(os.environ["CANDIDATE_RUN"]), os.environ["CANDIDATE_SOURCE"]
    artifact_id, checksum = int(os.environ["CANDIDATE_ARTIFACT"]), os.environ["CANDIDATE_DIGEST"]
    if not re.fullmatch(r"[0-9a-f]{40}", source) or not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("Malformed source or artifact digest")
    head = command(["git", "rev-parse", "HEAD"]).strip()
    if head != os.environ["GITHUB_SHA"] or command(["git", "status", "--porcelain"]).strip():
        raise ValueError("Unbound or dirty harness checkout")
    command(["git", "merge-base", "--is-ancestor", source, head])
    changed = set(command(["git", "diff", "--no-renames", "--name-only", source, head]).splitlines())
    if changed != PATHS:
        raise ValueError("Standalone experiment must change exactly its four harness files")
    run = api(f"actions/runs/{run_id}")
    jobs = api(f"actions/runs/{run_id}/attempts/{run['run_attempt']}/jobs?per_page=100")
    artifact = api(f"actions/artifacts/{artifact_id}")
    verify_app_diagnostic(run, jobs, artifact, run_id, source, artifact_id, checksum, [])
    for name, value in (("producer", run), ("jobs", jobs), ("artifact", artifact)):
        save(folder / (name + ".json"), value)
    archive = folder / "original-diagnostic.zip"
    with archive.open("xb") as stream:
        subprocess.run(["gh", "api", f"repos/iret77/nexgenvideo/actions/artifacts/{artifact_id}/zip"],
                       stdin=subprocess.DEVNULL, stdout=stream, check=True, timeout=120)
    verify_app_crash_archive(archive, run_id, source, checksum)
    profile = selected_profile()
    normal_arm = bind_normal_arm(folder, head) if profile == "scribble" else None
    save(folder / "binding.json", {"harnessSHA": head, "productSHA": source,
        "producerRunID": run_id, "producerAttempt": run["run_attempt"],
        "artifactID": artifact_id, "artifactSHA256": checksum,
        "harnessHashes": {name: digest(Path(name)) for name in sorted(PATHS)},
        "diagnosticOnly": True, "profile": profile, "normalArm": normal_arm,
        "processes": 200, "roundsPerProcess": 4,
        "executionSeconds": 1200, "perProcessSeconds": 300,
        "calibrationSeconds": 30, "calibrationMaxRounds": 10000,
        "scope": "Built-in filters only; not an App replay or Core acceptance"})


def intervals(folder, pid, rounds):
    lanes = []
    for lane in range(2):
        records = [json.loads(line) for line in (folder / f"lane-{lane}.jsonl").read_text().splitlines()]
        if len(records) != rounds * 3:
            raise ValueError("Incomplete render records")
        values = []
        for index in range(rounds):
            ready, interval, done = records[index * 3:index * 3 + 3]
            if ([item.get("event") for item in (ready, interval, done)] != ["ready", "interval", "completed"]
                    or any(item.get("pid") != pid or item.get("lane") != lane or item.get("round") != index
                           for item in (ready, interval, done))
                    or type(interval.get("begin")) is not int or type(interval.get("end")) is not int
                    or not 0 < interval["begin"] < interval["end"]
                    or not isinstance(done.get("red"), (int, float)) or not 0 < done["red"] <= 1):
                raise ValueError("Render identity, timestamps or readback invalid")
            values.append((interval["begin"], interval["end"]))
        lanes.append(values)
    return sum(max(a[0], b[0]) < min(a[1], b[1]) for a, b in zip(*lanes))


def sample_proof(text, pid, parent, *, images=IMAGES):
    if set(images) != set(IMAGES):
        raise ValueError("Calibration requires all six system images")
    if (not re.search(r"^Process:\s+NGVBuiltinBlur \[" + str(pid) + r"\]$", text, re.M)
            or not re.search(r"^Parent Process:\s+.+ \[" + str(parent) + r"\]$", text, re.M)):
        raise ValueError("Sample is not the owned calibration process")
    if any(not re.search(r"^.*<" + value + r">.*(?:/|\s)" + re.escape(name) + r"(?:\s|$)",
                        text, re.M | re.I) for name, value in images.items()):
        raise ValueError("Sample does not prove all six exact system images")
    blur_depth = None
    for line in text.splitlines():
        frame = re.match(r"^([ |+!:]*)([0-9]+) (.+)", line)
        if not frame:
            blur_depth = None
            continue
        depth, symbol = len(frame[1]), frame[3]
        if blur_depth is not None and depth <= blur_depth:
            blur_depth = None
        if "CIBlurProcessor" in symbol:
            blur_depth = depth
        elif blur_depth is not None and "MPSAutoCache::GetTempTexture" in symbol:
            return
    raise ValueError("Sample does not establish the blur/MPS allocation path")


def signature(report):
    images = report.get("usedImages", [])
    if (report.get("osVersion", {}).get("build") != "26A428"
            or any(not any(i.get("name") == name and i.get("uuid", "").lower() == value for i in images)
                   for name, value in FAULT_IMAGES.items())):
        return False
    threads = [t for t in report.get("threads", []) if t.get("triggered")]
    if len(threads) != 1:
        return False
    thread = threads[0]
    frames = thread.get("frames", [])
    referenced = {images[f["imageIndex"]].get("name") for f in frames
                  if type(f.get("imageIndex")) is int and 0 <= f["imageIndex"] < len(images)}
    if not set(FAULT_IMAGES) <= referenced:
        return False
    names = [f.get("symbol", "") for f in frames]
    if len(frames) < 7 or not names[0].startswith("objc_msgSend") or "getBytes:length:" not in names[1]:
        return False
    for index, name, offset in ((1, "Foundation", 353380),
                                (2, "AppleParavirtGPUMetalIOGPUFamily", 131268),
                                (3, "AppleParavirtGPUMetalIOGPUFamily", 55244),
                                (4, "MPSCore", 487936)):
        image_index = frames[index].get("imageIndex", -1)
        if (type(image_index) is not int or not 0 <= image_index < len(images)
                or images[image_index].get("name") != name or frames[index].get("imageOffset") != offset):
            return False
    cache = next((i for i, name in enumerate(names) if "MPSAutoCache::GetTempTexture" in name), -1)
    blur = next((i for i, name in enumerate(names) if "CIBlurProcessor" in name), -1)
    state = thread.get("threadState", {})
    registers = state.get("x", [])
    far = state.get("far", {}).get("value", 0)
    return (report.get("exception", {}).get("signal") == "SIGSEGV"
            and "KERN_INVALID_ADDRESS" in report.get("exception", {}).get("subtype", "")
            and len(registers) > 21 and far - 16 == registers[16].get("value")
            and registers[0].get("value") == registers[21].get("value")
            and registers[16].get("value", 0) >> 48 != 0
            and 4 < cache < blur)


def shared_chain(report):
    images = report.get("usedImages", [])
    threads = [t for t in report.get("threads", []) if t.get("triggered")]
    if (report.get("osVersion", {}).get("build") != "26A428" or len(threads) != 1
            or report.get("exception", {}).get("signal") not in {"SIGSEGV", "SIGBUS"}):
        return False
    frames = threads[0].get("frames", [])
    def frame_at(index, name, offset=None, symbol=None):
        if not 0 <= index < len(frames):
            return False
        frame = frames[index]
        image_index = frame.get("imageIndex")
        return (type(image_index) is int and 0 <= image_index < len(images)
                and images[image_index].get("name") == name
                and images[image_index].get("uuid", "").lower() == FAULT_IMAGES[name]
                and (offset is None or frame.get("imageOffset") == offset)
                and (symbol is None or symbol in frame.get("symbol", "")))
    data = [i for i in range(len(frames)) if frame_at(i, "Foundation", symbol="getBytes:length:")
            and type(frames[i].get("imageOffset")) is int and 353376 <= frames[i]["imageOffset"] <= 353400]
    if len(data) != 1:
        return False
    start = data[0]
    if not (frame_at(start + 1, "AppleParavirtGPUMetalIOGPUFamily", 131268)
            and frame_at(start + 2, "AppleParavirtGPUMetalIOGPUFamily", 55244)
            and frame_at(start + 3, "MPSCore", 487936)):
        return False
    cache = [i for i in range(start + 4, len(frames))
             if frame_at(i, "MPSCore", 487512, "MPSAutoCache::GetTempTexture")]
    blur = [i for i in range(start + 4, len(frames))
            if frame_at(i, "CoreImage", 1186196, "CIBlurProcessor")]
    return (len(cache) == len(blur) == 1 and cache[0] < blur[0]
            and any(frame_at(i, "MPSImage") for i in range(cache[0] + 1, blur[0])))


def scribble_pattern(report):
    thread = next(t for t in report["threads"] if t.get("triggered"))
    state = thread.get("threadState", {})
    values = {"far": state.get("far", {}).get("value")}
    registers = state.get("x", [])
    values.update({f"x{index}": item.get("value") for index, item in enumerate(registers[:29])})
    raw, low_mask = 0x5555555555555555, 0xFFFFFFFFFFFF
    bases = {raw & mask & low_mask for mask in (0x007FFFFFFFFFFFF8, 0x00007FFFFFFFFFF8, 0x0000000FFFFFFFF8)}
    objc_send = thread.get("frames", [{}])[0].get("symbol", "").startswith("objc_msgSend")
    matches = {}
    for name, value in values.items():
        if type(value) is not int or not 0 <= value < 2**64:
            continue
        pattern = None
        if value == raw:
            pattern = "raw-repeated-byte"
        elif name == "far" and any(0 <= (value & low_mask) - base <= 128 for base in bases):
            pattern = "masked-pointer-plus-bounded-offset"
        elif name == "x16" and objc_send and value & low_mask in bases:
            pattern = "masked-isa-at-objc-msgSend"
        if pattern:
            matches[name] = {"value": value, "pattern": pattern}
    return matches


def memory_activity(text, pid, profile):
    matches = re.findall(r"^NGVBuiltinBlur\((\d+),0x[0-9a-fA-F]+\) malloc: "
                         r"enabling scribbling to detect mods to free blocks\r?$", text, re.M)
    if profile == "scribble":
        if matches != [str(pid)]:
            raise ValueError("Missing, duplicate or foreign libmalloc activation banner")
    elif profile != "normal" or matches:
        raise ValueError("Unexpected memory diagnostic activity")
    return {"profile": profile, "pid": pid, "activationBannerCount": len(matches)}


def crash_outcome(code, reports, profile):
    if len(reports) != 1:
        return "V"
    report = reports[0]
    if profile == "normal":
        return "R" if code == -11 and signature(report) else "C"
    if profile != "scribble":
        raise ValueError("Unknown memory diagnostic profile")
    expected = {-11: "SIGSEGV", -10: "SIGBUS"}.get(code)
    if expected is None or report.get("exception", {}).get("signal") != expected or not shared_chain(report):
        return "C"
    return "F" if scribble_pattern(report) else "G"


def owned_process(binary, folder, mode, deadline, profile="normal", *, original_arguments=False):
    if original_arguments and profile != "normal":
        raise ValueError("Original executable only supports the normal profile")
    folder.mkdir()
    for lane in range(2):
        (folder / f"lane-{lane}.jsonl").touch(exist_ok=False)
    context = prepare_post_mortem(binary)
    if context.get("preparationError") or not context.get("hostUUID"):
        raise ValueError("Cannot establish original executable identity")
    context["launchEarliest"] = time.time()
    sampler = None
    with (folder / "stdout.log").open("xb") as out, (folder / "stderr.log").open("xb") as err:
        args = [str(binary), str(folder), mode] + ([] if original_arguments else [profile])
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, env=environment(os.environ, profile), start_new_session=True)
        context.update(pid=process.pid, launchLatest=time.time(), argv=args)
        save(folder / "launch.json", context)
        try:
            if mode == "calibration":
                with (folder / "sample.stdout").open("xb") as sample_out, (folder / "sample.stderr").open("xb") as sample_err:
                    sampler = subprocess.Popen(["/usr/bin/sample", str(process.pid), "20", "1", "-file", str(folder / "sample.txt")],
                        stdin=subprocess.DEVNULL, stdout=sample_out, stderr=sample_err)
            code = process.wait(timeout=min(300, max(0.1, deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait(timeout=5)
            context["timedOut"] = True
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            if sampler is not None:
                try:
                    context["sampleExitCode"] = sampler.wait(timeout=25)
                except subprocess.TimeoutExpired:
                    sampler.kill()
                    context["sampleExitCode"] = sampler.wait(timeout=5)
                    context["sampleTimedOut"] = True
                sample = folder / "sample.txt"
                save(folder / "sample-receipt.json", {"exitCode": context["sampleExitCode"],
                    "timedOut": context.get("sampleTimedOut", False),
                    "bytes": sample.stat().st_size if sample.exists() else None,
                    "sha256": digest(sample) if sample.exists() else None, "pid": process.pid})
    context.update(exitObserved=time.time(), exitCode=code)
    save(folder / "exit.json", context)
    reports = []
    if code != 0:
        receipt = capture_post_mortem(folder / "post-mortem", context, code)
        reports = [json.loads((folder / "post-mortem" / item["file"]).read_bytes().split(b"\n", 1)[1])
                   for item in receipt.get("reports", [])]
        save(folder / "crash-images.json", [{name: [i for i in report.get("usedImages", []) if i.get("name") == name]
             for name in (*FAULT_IMAGES, "Metal", "IOGPU")} for report in reports])
        save(folder / "crash-classification.json", [{"originalSignatureMatch": signature(report),
            "sharedChainMatch": shared_chain(report),
            "scribblePattern": scribble_pattern(report) if shared_chain(report) else {}}
            for report in reports])
    try:
        activity = memory_activity((folder / "stderr.log").read_text(errors="replace"), process.pid, profile)
    except ValueError as error:
        save(folder / "memory-activity.json", {"profile": profile, "pid": process.pid, "error": str(error)})
        return "V", context
    save(folder / "memory-activity.json", activity)
    if context.get("timedOut"):
        return "V", context
    return (crash_outcome(code, reports, profile) if code != 0 else "clean"), context


def run_measured(binary, folder, deadline, result, profile="normal", *, original_arguments=False):
    for index in range(200):
        if deadline - time.monotonic() < 300:
            result.update(outcome="V", reason="Time box leaves insufficient time for another process")
            break
        current = folder / f"process-{index:03d}"
        outcome, context = owned_process(binary, current, "measured", deadline, profile,
                                         original_arguments=original_arguments)
        result["outcome"] = outcome
        if outcome != "clean":
            result["abnormalProcess"] = index
            break
        result["overlappingRounds"] += intervals(current, context["pid"], 4)
        result["processesCompleted"] += 1
        result["roundsCompleted"] += 4
    else:
        result["outcome"] = "N" if result["overlappingRounds"] >= 640 else "V"


def execute(folder, metadata, result):
    folder.mkdir()
    binding = json.loads((metadata / "binding.json").read_text())
    if command(["git", "rev-parse", "HEAD"]).strip() != binding["harnessSHA"]:
        raise ValueError("Checkout differs from source validation")
    if binding["harnessSHA"] != os.environ["GITHUB_SHA"]:
        raise ValueError("Workflow source differs")
    for name, checksum in binding["harnessHashes"].items():
        if digest(Path(name)) != checksum:
            raise ValueError("Reviewed harness file changed")
    profile = selected_profile()
    if binding.get("profile") != profile or (profile == "scribble" and not binding.get("normalArm")):
        raise ValueError("Diagnostic profile differs from source binding")
    environment(os.environ, profile)
    result["profile"] = profile
    platform = {"os": command(["sw_vers"]), "xcode": command(["xcodebuild", "-version"]),
                "swift": command(["xcrun", "swiftc", "--version"]), "arch": command(["uname", "-m"]).strip()}
    save(folder / "platform.json", platform)
    if (command(["sw_vers", "-buildVersion"]).strip() != "26A428"
            or platform["xcode"].strip() != "Xcode 27.0\nBuild version 27A266a" or platform["arch"] != "arm64"):
        raise ValueError("Platform differs from both original failures")
    binary = folder / "NGVBuiltinBlur"
    args = ["xcrun", "swiftc", "-g", "-Onone", "-swift-version", "6", "-target", "arm64-apple-macos26.0",
            "scripts/ci_builtin_blur.swift", "-o", str(binary)]
    with (folder / "compile.log").open("xb") as out:
        subprocess.run(args, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, check=True, timeout=120)
    save(folder / "binary.json", {"sha256": digest(binary), "uuid": command(["dwarfdump", "--uuid", str(binary)]),
         "command": args, "sourceSHA256": digest(Path("scripts/ci_builtin_blur.swift")), "productCode": False})
    start = time.monotonic()
    deadline = start + 1200
    outcome, calibration = owned_process(binary, folder / "calibration", "calibration", deadline, profile)
    result["outcome"] = outcome
    if outcome == "clean":
        if calibration.get("sampleExitCode") != 0 or calibration.get("sampleTimedOut"):
            raise ValueError("Calibration sample incomplete")
        sample_proof((folder / "calibration/sample.txt").read_text(), calibration["pid"], os.getpid())
        run_measured(binary, folder, deadline, result, profile)
    elif profile == "scribble":
        result.update(outcome="V", calibrationOutcome=outcome, reason="Calibration did not complete")
    result["elapsedSeconds"] = time.monotonic() - start
    save(folder / "result.json", result)
    print(json.dumps(result))
    return 0 if result["outcome"] == "N" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("bind", "run"))
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--metadata", type=Path)
    args = parser.parse_args()
    result = {"outcome": "V", "diagnosticOnly": True, "productAcceptance": False,
              "processesCompleted": 0, "roundsCompleted": 0, "overlappingRounds": 0}
    try:
        if args.mode == "bind":
            bind(args.evidence.resolve())
        else:
            raise SystemExit(execute(args.evidence.resolve(), args.metadata.resolve(), result))
    except Exception as error:
        args.evidence.mkdir(exist_ok=True, parents=True)
        result.update(outcome="V", error=str(error))
        save(args.evidence / "failure.json", {"outcome": "V", "diagnosticOnly": True,
                                              "error": str(error), "at": datetime.now(timezone.utc).isoformat()})
        raise
    finally:
        if args.mode == "run":
            args.evidence.mkdir(exist_ok=True, parents=True)
            save(args.evidence / "result.json", result)
