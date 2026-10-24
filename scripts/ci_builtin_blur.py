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

from app_host_zombie_diagnostic import diagnostic_key
from run_macos_tests import prepare_post_mortem, capture_post_mortem
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


def environment(source):
    if any(diagnostic_key(key.encode()) or key.startswith("DYLD_") for key in source):
        raise ValueError("Ambient diagnostic changes would invalidate the experiment")
    if source.get("SWIFT_BACKTRACE", BACKTRACE) != BACKTRACE:
        raise ValueError("Unexpected Swift backtrace settings")
    return dict(source, SWIFT_BACKTRACE=BACKTRACE)


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
    changed = set(command(["git", "diff", "--name-only", source, head]).splitlines())
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
    save(folder / "binding.json", {"harnessSHA": head, "productSHA": source,
        "producerRunID": run_id, "producerAttempt": run["run_attempt"],
        "artifactID": artifact_id, "artifactSHA256": checksum,
        "harnessHashes": {name: digest(Path(name)) for name in sorted(PATHS)},
        "diagnosticOnly": True, "processes": 200, "roundsPerProcess": 4,
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


def sample_proof(text, pid, parent):
    if (not re.search(r"^Process:\s+NGVBuiltinBlur \[" + str(pid) + r"\]$", text, re.M)
            or not re.search(r"^Parent Process:\s+.+ \[" + str(parent) + r"\]$", text, re.M)):
        raise ValueError("Sample is not the owned calibration process")
    if any(not re.search(r"^.*<" + value + r">.*(?:/|\s)" + re.escape(name) + r"(?:\s|$)",
                        text, re.M | re.I) for name, value in IMAGES.items()):
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


def owned_process(binary, folder, mode, deadline):
    folder.mkdir()
    for lane in range(2):
        (folder / f"lane-{lane}.jsonl").touch(exist_ok=False)
    context = prepare_post_mortem(binary)
    if context.get("preparationError") or not context.get("hostUUID"):
        raise ValueError("Cannot establish original executable identity")
    context["launchEarliest"] = time.time()
    sampler = None
    with (folder / "stdout.log").open("xb") as out, (folder / "stderr.log").open("xb") as err:
        process = subprocess.Popen([str(binary), str(folder), mode], stdin=subprocess.DEVNULL,
                                   stdout=out, stderr=err, env=environment(os.environ), start_new_session=True)
        context.update(pid=process.pid, launchLatest=time.time())
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
    if code != 0:
        receipt = capture_post_mortem(folder / "post-mortem", context, code)
        reports = [json.loads((folder / "post-mortem" / item["file"]).read_bytes().split(b"\n", 1)[1])
                   for item in receipt.get("reports", [])]
        save(folder / "crash-images.json", [{name: [i for i in report.get("usedImages", []) if i.get("name") == name]
             for name in (*FAULT_IMAGES, "Metal", "IOGPU")} for report in reports])
        if context.get("timedOut") or not reports:
            return "V", context
        return "R" if code == -11 and any(signature(report) for report in reports) else "C", context
    return "clean", context


def run_measured(binary, folder, deadline, result):
    for index in range(200):
        if deadline - time.monotonic() < 300:
            result.update(outcome="V", reason="Time box leaves insufficient time for another process")
            break
        current = folder / f"process-{index:03d}"
        outcome, context = owned_process(binary, current, "measured", deadline)
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
    environment(os.environ)
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
    outcome, calibration = owned_process(binary, folder / "calibration", "calibration", deadline)
    result["outcome"] = outcome
    if outcome == "clean":
        if calibration.get("sampleExitCode") != 0 or calibration.get("sampleTimedOut"):
            raise ValueError("Calibration sample incomplete")
        sample_proof((folder / "calibration/sample.txt").read_text(), calibration["pid"], os.getpid())
        run_measured(binary, folder, deadline, result)
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
