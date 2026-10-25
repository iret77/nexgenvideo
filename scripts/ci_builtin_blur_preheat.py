import argparse
from copy import deepcopy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import struct
import subprocess
import time
import zipfile

from ci_builtin_blur import (api, command, digest, environment, intervals, memory_activity,
    owned_process, sample_proof, save)
from ci_builtin_blur_floor import BINARY, IMAGES, member, platform
from run_macos_tests import owned_crash_report, prepare_post_mortem


BASE = "466884537857f979fb6f64c5a260efee057ef527"
RUN = 40223322077
ARTIFACT = 12610461267
ARCHIVE = "fb5c457e9442862985bc504e23c815fd8cc59dba032e328cbf66199a6ae4639b"
REPORT = "220d840d9656f0f32adcb6adf6528ebc44376e2d50a4f2ea118ccd1ee35b2b1c"
MODE = "ci-builtin-blur-preheat"
SWIFT = "scripts/ci_builtin_blur.swift"
FIXTURE = "scripts/fixtures/builtin-blur-floor-chain.json"
CHANGED = {SWIFT, FIXTURE, ".github/workflows/diagnostic-acceptance.yml",
    "scripts/ci_builtin_blur_preheat.py", "scripts/test_ci_builtin_blur_preheat.py"}
DEPENDENCIES = {"scripts/ci_builtin_blur.py", "scripts/ci_builtin_blur_floor.py",
    "scripts/run_macos_tests.py", "scripts/app_host_zombie_diagnostic.py",
    "scripts/verify_diagnostic_candidate.py", "scripts/verify_swift_test_output.py",
    ".github/actions/setup-xcode-27/action.yml"}
PER_ARM = 400
FAULT_IMAGES = {k: v for k, v in IMAGES.items() if k != "IOGPU"}
FAULT_IMAGES["Foundation"] = "91dace39-fa28-3191-818d-1fcc6a0e615a"


def projection(report):
    return {"osVersion": {"build": report["osVersion"]["build"]},
        "usedImages": [{key: value for key, value in image.items() if key in {"name", "uuid"}}
                       for image in report["usedImages"]],
        "threads": [{"triggered": True, "frames": [{key: value for key, value in frame.items()
            if key in {"imageIndex", "imageOffset", "symbol", "symbolLocation"}}
            for frame in thread["frames"]]} for thread in report["threads"] if thread.get("triggered")]}


def target_fault(report):
    try:
        images = report["usedImages"]
        if report["osVersion"]["build"] != "25G83" or any(
                not any(i.get("name") == name and i.get("uuid", "").lower() == value for i in images)
                for name, value in FAULT_IMAGES.items()):
            return False
        threads = [t for t in report["threads"] if t.get("triggered")]
        if len(threads) != 1:
            return False
        frames = []
        for frame in threads[0]["frames"]:
            index = frame["imageIndex"]
            if type(index) is not int or not 0 <= index < len(images):
                return False
            frames.append((images[index].get("name"), frame.get("symbol", "")))
        expected = [("Foundation", "getBytes:length:"), ("AppleParavirtGPUMetalIOGPUFamily", ""),
            ("MPSCore", "GetTempTexture"), ("MPSImage", ""), ("CoreImage", "CIBlurProcessor")]
        cursor = 0
        for name, symbol in frames:
            if name == expected[cursor][0] and expected[cursor][1] in symbol:
                cursor += 1
                if cursor == len(expected):
                    return True
        return False
    except (KeyError, TypeError, IndexError):
        return False


def build_version(raw):
    if len(raw) < 32:
        raise ValueError("Truncated Mach-O")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", raw)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x0100000C, 2) or not 0 < size <= len(raw) - 32:
        raise ValueError("Expected thin arm64 executable")
    offset, found = 32, []
    for _ in range(count):
        if offset + 8 > 32 + size:
            raise ValueError("Truncated command")
        cmd, length = struct.unpack_from("<II", raw, offset)
        if length < 8 or length % 8 or offset + length > 32 + size:
            raise ValueError("Invalid command size")
        if cmd == 0x32:
            if length < 24:
                raise ValueError("Truncated build version")
            found.append(list(struct.unpack_from("<3I", raw, offset + 8)))
        offset += length
    if offset != 32 + size or len(found) != 1 or found[0][:2] != [1, 26 << 16]:
        raise ValueError("Unexpected platform or deployment floor")
    return found[0]


def verify_producer(run, jobs, artifact):
    if (run.get("id") != RUN or run.get("head_sha") != BASE or run.get("run_attempt") != 1
            or run.get("repository", {}).get("full_name") != "iret77/nexgenvideo"
            or run.get("path") != ".github/workflows/diagnostic-acceptance.yml"
            or run.get("head_branch") != "iret77/activity-approval-layout"
            or run.get("event") != "workflow_dispatch" or run.get("actor", {}).get("login") != "iret77"
            or run.get("status") != "completed" or run.get("conclusion") != "failure"
            or jobs.get("total_count") != len(jobs.get("jobs", []))
            or artifact.get("id") != ARTIFACT or artifact.get("expired") is not False
            or artifact.get("name") != f"builtin-blur-floor-{RUN}-a1"
            or artifact.get("digest") != "sha256:" + ARCHIVE
            or artifact.get("workflow_run", {}).get("id") != RUN
            or artifact["workflow_run"].get("head_sha") != BASE):
        raise ValueError("Original floor producer identity differs")
    for name, identity, conclusion in (("source", 121259393484, "success"),
            ("ci-builtin-blur-floor", 121259474529, "failure")):
        selected = [j for j in jobs["jobs"] if j.get("name") == name]
        if len(selected) != 1:
            raise ValueError("Original producer job missing or ambiguous")
        job = selected[0]
        if (job.get("id") != identity or job.get("run_id") != RUN or job.get("run_attempt") != 1
                or job.get("head_sha") != BASE or job.get("status") != "completed"
                or job.get("conclusion") != conclusion):
            raise ValueError("Original job identity differs")
        if name != "source" and (not job["started_at"] <= artifact["created_at"] <= artifact["updated_at"] <= job["completed_at"]
                or [s["name"] for s in job["steps"] if s["conclusion"] == "failure"]
                != ["Run original executable on the product floor"]):
            raise ValueError("Original artifact or failure step differs")


def bind(folder):
    folder.mkdir()
    expected = {"REPLAY_KIND": MODE, "CANDIDATE_RUN": str(RUN), "CANDIDATE_SOURCE": BASE,
                "CANDIDATE_ARTIFACT": str(ARTIFACT), "CANDIDATE_DIGEST": ARCHIVE}
    if any(os.environ.get(k) != v for k, v in expected.items()) or any(os.environ.get(k)
            for k in ("PRODUCT_SHA", "PRODUCTS_ID", "PRODUCTS_DIGEST", "FAILURE_ID", "FAILURE_DIGEST")):
        raise ValueError("Comparison inputs differ")
    head = command(["git", "rev-parse", "HEAD"]).strip()
    if head != os.environ["GITHUB_SHA"] or command(["git", "status", "--porcelain"]).strip():
        raise ValueError("Dirty or unbound checkout")
    command(["git", "merge-base", "--is-ancestor", BASE, head])
    if set(command(["git", "diff", "--no-renames", "--name-only", BASE, head]).splitlines()) != CHANGED:
        raise ValueError("Comparison changed files outside its exact diagnostic scope")
    old = command(["git", "show", BASE + ":" + SWIFT])
    if old.split("guard CommandLine.arguments.count")[0] != Path(SWIFT).read_text().split("guard [4, 5]")[0]:
        raise ValueError("Measured render function changed")
    run, jobs, artifact = api(f"actions/runs/{RUN}"), api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100"), api(f"actions/artifacts/{ARTIFACT}")
    verify_producer(run, jobs, artifact)
    save(folder / "producer.json", dict(run=run, jobs=jobs, artifact=artifact))
    archive = folder / "original-floor.zip"
    with archive.open("xb") as out:
        subprocess.run(["gh", "api", f"repos/iret77/nexgenvideo/actions/artifacts/{ARTIFACT}/zip"],
            stdin=subprocess.DEVNULL, stdout=out, timeout=120, check=True)
    if digest(archive) != ARCHIVE or archive.stat().st_size != artifact["size_in_bytes"]:
        raise ValueError("Original floor archive bytes differ")
    with zipfile.ZipFile(archive) as z:
        result = json.loads(member(z, "result.json"))
        context = json.loads(member(z, "process-020/exit.json"))
        raw = member(z, "process-020/post-mortem/owned-host-0.ips")
        binary = member(z, "NGVBuiltinBlur")
        if (result.get("outcome") != "FC" or context.get("exitCode") != -11
                or hashlib.sha256(raw).hexdigest() != REPORT
                or hashlib.sha256(binary).hexdigest() != BINARY or context.get("hostSHA256") != BINARY):
            raise ValueError("Original floor fault differs")
        owned_crash_report(raw, context)
        report = json.loads(raw.split(b"\n", 1)[1])
        if projection(report) != json.loads(Path(FIXTURE).read_text())["report"] or not target_fault(report):
            raise ValueError("Classifier fixture differs from original fault bytes")
    save(folder / "binding.json", {"harnessSHA": head, "baseSHA": BASE, "originalSDK": build_version(binary),
        "hashes": {name: digest(Path(name)) for name in sorted(CHANGED | DEPENDENCIES)},
        "workflowRun": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "originalAbnormalChildSeconds": context["exitObserved"] - context["launchLatest"],
        "diagnosticOnly": True, "productAcceptance": False})


def bound(metadata):
    value = json.loads((metadata / "binding.json").read_text())
    if (os.environ["REPLAY_KIND"] != MODE or value["baseSHA"] != BASE
            or value["harnessSHA"] != os.environ["GITHUB_SHA"]
            or value["harnessSHA"] != command(["git", "rev-parse", "HEAD"]).strip()
            or value["workflowRun"] != os.environ["GITHUB_RUN_ID"]
            or value["attempt"] != os.environ["GITHUB_RUN_ATTEMPT"]
            or set(value["hashes"]) != CHANGED | DEPENDENCIES):
        raise ValueError("Cross-job source or execution binding differs")
    for name, checksum in value["hashes"].items():
        if digest(Path(name)) != checksum:
            raise ValueError("Reviewed source bytes differ")
    return value


def compile_binary(folder, metadata):
    value = bound(metadata)
    folder.mkdir()
    xcode = command(["xcodebuild", "-version"]).strip()
    if xcode != "Xcode 27.0\nBuild version 27A266a" or command(["uname", "-m"]).strip() != "arm64":
        raise ValueError("Original compiler toolchain differs")
    binary = folder / "NGVBuiltinBlur"
    args = ["xcrun", "swiftc", "-g", "-Onone", "-swift-version", "6", "-target", "arm64-apple-macos26.0", SWIFT, "-o", str(binary)]
    with (folder / "compile.log").open("xb") as out:
        subprocess.run(args, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, timeout=120, check=True)
    if build_version(binary.read_bytes()) != value["originalSDK"]:
        raise ValueError("Compiled platform/minOS/SDK differs from original executable")
    save(folder / "binary.json", {"sha256": digest(binary), "harnessSHA": value["harnessSHA"],
        "bindingSHA256": digest(metadata / "binding.json"), "command": args, "xcode": xcode,
        "swift": command(["xcrun", "swiftc", "--version"]), "sourceSHA256": digest(Path(SWIFT)),
        "uuid": command(["dwarfdump", "--uuid", str(binary)]), "productCode": False})


def launch(binary, folder, arm, identity, deadline):
    folder.mkdir()
    for lane in range(2):
        (folder / f"lane-{lane}.jsonl").touch(exist_ok=False)
    context = deepcopy(identity)
    context["launchEarliest"] = time.time()
    args = [str(binary), str(folder), "measured", "normal", arm]
    with (folder / "stdout.log").open("xb") as out, (folder / "stderr.log").open("xb") as err:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
            env=environment(os.environ), start_new_session=True)
        context.update(pid=process.pid, launchLatest=time.time(), arm=arm, argv=args)
        save(folder / "launch.json", context)
        try:
            code = process.wait(timeout=min(300, max(0.1, deadline - time.monotonic() - 60)))
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait(timeout=5)
            context["timedOut"] = True
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
    context.update(exitCode=code, exitObserved=time.time())
    save(folder / "exit.json", context)
    time.sleep(0.1)
    return context


def stable_report(path, identity):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("Report is no longer a regular file")
        raw = stream.read(8 * 1024 * 1024 + 1)
        after = os.fstat(stream.fileno())
    if any((s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns) != identity for s in (before, after)) or len(raw) != identity[2]:
        raise ValueError("Report changed during read")
    return raw


def collect_reports(folder, children, deadline):
    pending = {c["pid"]: (name, c) for name, c in children if c["exitCode"] != 0}
    receipt = {"reports": {}, "errors": [], "candidateStatus": {}, "windowSeconds": 60}
    if not pending:
        save(folder / "reports.json", receipt)
        return receipt
    end = min(deadline, time.monotonic() + 60)
    previous, copied = {}, set()
    directories = [Path(p) for p in children[0][1]["directories"]]
    while time.monotonic() < end and pending:
        current = {}
        for directory in directories:
            try:
                paths = directory.iterdir()
                for path in paths:
                    if time.monotonic() >= end:
                        break
                    if not path.name.startswith("NGVBuiltinBlur") or path.suffix != ".ips" or str(path) in copied:
                        continue
                    if len(current) >= 2048:
                        receipt["errors"].append("Crash candidate bound reached; remaining reports unknown")
                        break
                    try:
                        info = path.lstat()
                        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 8 * 1024 * 1024:
                            raise ValueError("Not a bounded regular report")
                        key = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                        current[str(path)] = key
                        if previous.get(str(path)) != key:
                            receipt["candidateStatus"][str(path)] = "Waiting for stable bytes"
                            continue
                        raw = stable_report(path, key)
                        report = json.loads(raw.split(b"\n", 1)[1])
                        if not isinstance(report, dict):
                            raise ValueError("IPS body is not an object")
                        selected = pending.get(report.get("pid"))
                        if not selected:
                            raise ValueError("Not a pending owned child")
                        name, context = selected
                        proof = owned_crash_report(raw, context)
                        (folder / name / "owned.ips").write_bytes(raw)
                        receipt["reports"][name] = {"sha256": hashlib.sha256(raw).hexdigest(), **proof,
                            "targetFault": context["exitCode"] == -11 and target_fault(report)}
                        receipt["candidateStatus"][str(path)] = "Bound original report copied"
                        copied.add(str(path))
                        del pending[context["pid"]]
                    except (OSError, KeyError, ValueError, TypeError, IndexError) as error:
                        receipt["candidateStatus"][str(path)] = str(error)
            except OSError as error:
                if len(receipt["errors"]) < 128:
                    receipt["errors"].append(str(error))
        previous = current
        if pending:
            time.sleep(min(1, max(0, end - time.monotonic())))
    receipt["missingPIDs"] = sorted(pending)
    save(folder / "reports.json", receipt)
    return receipt


def round_zero(folder, pid):
    pairs = []
    for lane in range(2):
        records = [json.loads(line) for line in (folder / f"lane-{lane}.jsonl").read_text().splitlines()]
        if len(records) < 2:
            return None
        ready, interval = records[:2]
        if ([ready.get("event"), interval.get("event")] != ["ready", "interval"]
                or any(r.get("pid") != pid or r.get("lane") != lane or r.get("round") != 0 for r in (ready, interval))
                or type(interval.get("begin")) is not int or type(interval.get("end")) is not int
                or not 0 < interval["begin"] < interval["end"]):
            raise ValueError("Round zero identity or interval differs")
        pairs.append((interval["begin"], interval["end"]))
    return max(x[0] for x in pairs) < min(x[1] for x in pairs)


def abnormal_phase(folder, context):
    if context.get("timedOut"):
        return "timeout"
    lanes = [[json.loads(line) for line in (folder / f"lane-{lane}.jsonl").read_text().splitlines()]
             for lane in (0, 1)]
    if context["arm"] == "warm":
        path = folder / "warmup/lane-0.jsonl"
        warm = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        if not any(r.get("event") == "completed" and r.get("pid") == context["pid"]
                   and r.get("round") == -1 for r in warm):
            return "warmup-incomplete"
        if not any(r.get("event") == "ready" for lane in lanes for r in lane):
            return "after-warmup-before-measured-ready"
    if not all(any(r.get("event") == "completed" and r.get("round") == 0 for r in lane) for lane in lanes):
        return "round-zero-incomplete"
    return "later-rounds"


def summarize(folder, children, reports, invalid):
    counts = {arm: dict(processes=0, abnormal=0, targetFaults=0, unknownAbnormal=0,
        clean=0, completeFirstRounds=0, overlappingFirstRounds=0, overlappingRounds=0,
        abnormalPhases={phase: 0 for phase in ("warmup-incomplete", "after-warmup-before-measured-ready",
            "round-zero-incomplete", "later-rounds", "timeout")}) for arm in ("cold", "warm")}
    for name, c in children:
        count = counts[c["arm"]]
        count["processes"] += 1
        if c["exitCode"] != 0:
            count["abnormal"] += 1
            count["targetFaults"] += bool(reports.get("reports", {}).get(name, {}).get("targetFault"))
            count["unknownAbnormal"] += name not in reports.get("reports", {})
        try:
            if c["exitCode"] != 0:
                count["abnormalPhases"][abnormal_phase(folder / name, c)] += 1
            memory_activity((folder / name / "stderr.log").read_text(errors="replace"), c["pid"], "normal")
            overlap = round_zero(folder / name, c["pid"])
            if overlap is not None:
                count["completeFirstRounds"] += 1
                count["overlappingFirstRounds"] += overlap
            if c["exitCode"] == 0:
                count["overlappingRounds"] += intervals(folder / name, c["pid"], 4)
                if (folder / name / "stdout.log").read_text().strip() != "completed 4 rounds":
                    raise ValueError("Process completion receipt differs")
                if c["arm"] == "warm":
                    warm = [json.loads(line) for line in (folder / name / "warmup/lane-0.jsonl").read_text().splitlines()]
                    if (len(warm) != 3 or [x.get("event") for x in warm] != ["ready", "interval", "completed"]
                            or any(x.get("round") != -1 or x.get("lane") != 0 or x.get("pid") != c["pid"] for x in warm)
                            or type(warm[1].get("begin")) is not int or type(warm[1].get("end")) is not int
                            or not 0 < warm[1]["begin"] < warm[1]["end"]
                            or not isinstance(warm[2].get("red"), (float, int)) or not 0 < warm[2]["red"] <= 1):
                        raise ValueError("Warmup did not prove its render/readback")
                count["clean"] += 1
        except (OSError, ValueError, TypeError, KeyError) as error:
            invalid.append({"process": name, "error": str(error)})
    complete = len(children) == PER_ARM * 2 and all(c["processes"] == PER_ARM for c in counts.values())
    exposure = all(c["completeFirstRounds"] > 0 and c["clean"] > 0
        and c["overlappingFirstRounds"] / c["completeFirstRounds"] >= 0.8
        and c["overlappingRounds"] / (c["clean"] * 4) >= 0.8 for c in counts.values())
    a, b = counts["cold"]["abnormal"], counts["warm"]["abnormal"]
    total = a + b
    p = (sum(math.comb(PER_ARM, k) * math.comb(PER_ARM, total-k)
        for k in range(a, min(PER_ARM, total) + 1) if 0 <= total-k <= PER_ARM)
        / math.comb(2 * PER_ARM, total)) if complete else None
    valid = complete and not invalid
    outcome = "invalid" if not valid else "inconclusive"
    if valid and b:
        outcome = "warm-arm-abnormal"
    elif valid and exposure and counts["cold"]["targetFaults"] >= 7:
        outcome = "association-candidate"
    return {"diagnosticOnly": True, "productAcceptance": False, "outcome": outcome,
        "valid": valid, "complete": complete, "exposureValid": exposure, "counts": counts,
        "armsWithoutCleanProcesses": [arm for arm, c in counts.items() if c["clean"] == 0],
        "oneSidedFisherP": p, "invalidEvidence": invalid,
        "limits": "Association only for this exact graph/image; no causal attribution, product fix or automatic retry. Missing IPS remains abnormal, never clean."}


def execute(folder, metadata, products):
    start = time.monotonic()
    deadline = start + 1200
    value = bound(metadata)
    environment(os.environ)
    if any(k.startswith(("CI_", "METAL_", "_Malloc", "MALLOC_")) for k in os.environ):
        raise ValueError("Ambient rendering overrides")
    folder.mkdir()
    binary = products / "NGVBuiltinBlur"
    proof = json.loads((products / "binary.json").read_text())
    if (proof["harnessSHA"] != value["harnessSHA"] or proof["bindingSHA256"] != digest(metadata / "binding.json")
            or proof["sha256"] != digest(binary) or proof["sourceSHA256"] != digest(Path(SWIFT))
            or build_version(binary.read_bytes()) != value["originalSDK"]):
        raise ValueError("Transferred executable binding differs")
    binary.chmod(0o755)
    platform(folder)
    command(["codesign", "--verify", "--strict", str(binary)])
    outcome, calibration = owned_process(binary, folder / "calibration", "calibration", deadline)
    if outcome != "clean" or calibration.get("sampleExitCode") != 0 or calibration.get("sampleTimedOut"):
        raise ValueError("Calibration failed; no measured cohort started")
    sample_proof((folder / "calibration/sample.txt").read_text(), calibration["pid"], os.getpid(), images=IMAGES)
    identity = prepare_post_mortem(binary)
    if identity.get("preparationError") or not identity.get("hostUUID"):
        raise ValueError("Cannot bind comparison child identity")
    children, invalid = [], []
    for index, arm in enumerate(["cold", "warm", "warm", "cold"] * (PER_ARM // 2)):
        if deadline - time.monotonic() < 300:
            invalid.append({"error": "Original 300-second remaining-time guard reached"})
            break
        name = f"process-{index:03d}"
        context = launch(binary, folder / name, arm, identity, deadline)
        children.append((name, context))
    if len({c["pid"] for _, c in children}) != len(children):
        invalid.append({"error": "PID reused within the fixed cohort"})
    reports = collect_reports(folder, children, deadline)
    result = summarize(folder, children, reports, invalid)
    result.update(elapsedSeconds=time.monotonic() - start, binarySHA256=digest(binary),
        harnessSHA=value["harnessSHA"], executionRun=value["workflowRun"], executionAttempt=value["attempt"])
    save(folder / "result.json", result)
    print(json.dumps(result))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("bind", "compile", "run"))
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--products", type=Path)
    args = parser.parse_args()
    try:
        if args.mode == "bind":
            bind(args.evidence.resolve())
        elif args.mode == "compile":
            compile_binary(args.evidence.resolve(), args.metadata.resolve())
        else:
            raise SystemExit(execute(args.evidence.resolve(), args.metadata.resolve(), args.products.resolve()))
    except Exception as error:
        args.evidence.mkdir(parents=True, exist_ok=True)
        save(args.evidence / "failure.json", {"diagnosticOnly": True, "productAcceptance": False,
            "outcome": "invalid", "error": str(error)})
        raise
