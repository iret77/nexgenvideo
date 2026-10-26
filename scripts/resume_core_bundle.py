import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

from app_host_zombie_diagnostic import diagnostic_key
from consume_bpy_distributable_source import public_asset, require_receipt
from retained_app_test_products import api, archive_bytes, archive_json, checksum, download, require, verify_artifact, write
from resume_core_tests import command, swift_identity, toolchain
from run_macos_tests import swift_events, VerificationError, XCTEST_START
from verify_swift_test_output import ANSI, assess_output


PREFIX = "Compile, unit tests, app and native bpy acceptance / "
ALLOWED = {".github/workflows/ci.yml", ".github/workflows/ci-batch.yml",
           "scripts/reuse_bpy_binary_evidence.py", "scripts/pinned_download.py",
           "scripts/test_verify_bpy_binary_reuse.py", "scripts/test_pinned_download.py",
           "scripts/resume_core_bundle.py", "scripts/test_resume_core_bundle.py"}
PASSED = {"Verify native app signing with nested runtime content", "Build",
          "Verify build did not mutate tracked source", "Stage test runtime inputs", "Test",
          "Upload render review test diagnosis", "Upload blockout orientation evidence",
          "HDR export QC", "Upload HDR export QC evidence", "Upload Lottie export evidence",
          "Verify tests did not mutate tracked source"}
SKIPPED = {"Verify retained backends against this checkout and native toolchain", "Upload Core backend composition"}
FAILED = "Run ./.github/actions/prepare-bpy-source"
BUILD = 'swift build --cache-path "$NGV_SWIFTPM_CACHE_PATH" --build-tests'
ARTIFACTS = {"tests": ("render-review-test-diagnostic-{run}", "Build & Test"),
             "hdr": ("hdr-export-qc", "Build & Test"),
             "ui": ("agent-chat-spec-{run}", "Agent UI Evidence"),
             "lottie": ("lottie-export-evidence", "Build & Test"),
             "blockout": ("blockout-orientation-evidence", "Build & Test")}


def source_binding(source, head):
    require(all(re.fullmatch(r"[a-f0-9]{40}", x) for x in (source, head)), "Invalid source identity")
    require(command(["git", "rev-parse", "HEAD"]) == head, "Checkout differs from current execution")
    subprocess.run(["git", "merge-base", "--is-ancestor", source, head], stdin=subprocess.DEVNULL,
                   check=True, timeout=30)
    changed = command(["git", "diff", "--name-only", "--no-renames", source, head]).splitlines()
    require(set(changed) <= ALLOWED, "Product, tests, dependency, build or runtime input changed")
    require(not command(["git", "status", "--porcelain", "--untracked-files=no"]), "Tracked checkout is dirty")
    original = command(["git", "show", source + ":.github/workflows/ci.yml"])
    require("resume_core_bundle.py" not in original, "Recursive full Core continuation is unsupported")
    require('run: ' + BUILD in original and 'run: ' + BUILD in Path(".github/workflows/ci.yml").read_text(),
            "Original and reconstructed compilation commands differ")
    patterns = sorted(ALLOWED | {Path(p).name for p in ALLOWED})
    result = subprocess.run(["git", "grep", "-n", "-F", "-f", "-", head, "--", "Sources", "Tests",
                             "Engine", "Plugins", "*.swift", "Package.swift",
                             "scripts/stage_test_runtime.sh", "scripts/run_macos_tests.py"],
                            input="\n".join(patterns) + "\n", text=True, capture_output=True, timeout=30)
    require(result.returncode == 1, "A continuation path is a native input, or input inspection failed")
    return changed, original


def step_names(workflow):
    section = workflow.split("  build_test:\n", 1)[1].split("  diagnostic-startup:\n", 1)[0]
    return [m[2] if m[1] == "name" else "Run " + m[2]
            for m in re.finditer(r"(?m)^      - (name|uses): (.+)$", section)]


def producer(run, listing, workflow):
    require(run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("head_repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("path") == ".github/workflows/ci-batch.yml"
            and run.get("event") == "workflow_dispatch" and run.get("run_attempt") == 1
            and run.get("status") == "completed" and run.get("conclusion") == "failure",
            "Full continuation needs an original failed Core attempt 1")
    require(listing.get("total_count") == len(listing.get("jobs", [])), "Incomplete original job list")
    jobs = {}
    for suffix, conclusion in (("Light Checks", "success"), ("Agent UI Evidence", "success"),
                               ("bpy-source / source", "success"), ("Build & Test", "failure")):
        matches = [j for j in listing["jobs"] if j.get("name") == PREFIX + suffix]
        require(len(matches) == 1, "Missing or duplicate original job: " + suffix)
        job = matches[0]
        require(job.get("run_id") == run["id"] and job.get("run_attempt") == 1
                and job.get("head_sha") == run["head_sha"] and job.get("status") == "completed"
                and job.get("conclusion") == conclusion, "Original job identity or outcome differs")
        jobs[suffix] = job
    failed_jobs = {j["name"] for j in listing["jobs"] if j.get("conclusion") == "failure"}
    require(failed_jobs == {PREFIX + "Build & Test", PREFIX + "Merge Gate"}, "Another original job failed")
    require(not any(j.get("conclusion") in {"cancelled", "timed_out", "action_required"} for j in listing["jobs"]),
            "Original execution was incomplete")
    for job in listing["jobs"]:
        if job.get("name", "").startswith((PREFIX + "diagnostic-startup", PREFIX + "bpy-runtime")):
            require(job.get("conclusion") == "skipped", "Runtime already ran in the original producer")
    steps = jobs["Build & Test"]["steps"]
    ordinary = [s for s in steps if s["name"] not in {"Set up job", "Complete job"}
                and not s["name"].startswith("Post ")]
    require([s["name"] for s in ordinary] == step_names(workflow), "Original ordered step ledger differs from source")
    require([s["name"] for s in steps if s.get("conclusion") == "failure"] == [FAILED], "Another original step failed")
    boundary = next(i for i, s in enumerate(ordinary) if s["name"] == FAILED)
    for step in ordinary[:boundary]:
        name, conclusion = step["name"], step.get("conclusion")
        if name in SKIPPED:
            require(conclusion == "skipped", "Original run was a backend continuation")
        elif name == "Save resolved dependencies after successful build":
            require(conclusion in {"success", "skipped"}, "Original dependency cache did not complete")
        elif name == "Run actions/download-artifact@v4":
            expected = "success" if ordinary.index(step) == boundary - 1 else "skipped"
            require(conclusion == expected, "Original receipt or continuation download differs")
        else:
            require(conclusion == "success", "Original prerequisite did not pass: " + name)
    require(PASSED <= {s["name"] for s in ordinary[:boundary]}, "Missing original native prerequisites")
    require(all(s.get("conclusion") == "skipped" for s in ordinary[boundary + 1:]), "Original bundling already ran")
    for name in ("Require distributable bpy before app transfer", "Enforce AppTheme", "Validate pack pipeline contracts",
                 "Verify CI and fixture tooling"):
        found = [s for s in jobs["Light Checks"]["steps"] if s["name"] == name]
        require(len(found) == 1 and found[0].get("conclusion") == "success", "Original source check did not pass")
    return jobs


def host_proof(host, phase, suite, events, source):
    require(host == phase.get("originalHostReceipt") and host.get("sourceSHA") == source
            and type(host.get("pid")) is int and host["pid"] > 0 and host["pid"] == phase.get("pid")
            and type(host.get("parentPID")) is int and host["parentPID"] > 0
            and host.get("hostExecutable") == str(Path(suite["binPath"]) / "NexGenVideoAppKitTestHost")
            and host.get("bundleBinary") == str(Path(suite["binPath"]) / "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests")
            and all(host.get(k) is True for k in ("started", "completed", "abiSucceeded", "mainThread",
                                                "applicationRunningAtStart", "runReturnedAfterCompletion"))
            and host.get("eventRecordCount") == events["recordCount"]
            and host.get("error") is None and host.get("recordingError") is None,
            "Original owned host proof is incomplete or foreign")


def phase_proof(archive, phase, folder, selection=""):
    name = phase["name"]
    require(phase.get("status") == "verified-execution" and phase.get("exitCode") == 0
            and "diagnostic" not in phase, "Original phase did not complete normally")
    args = phase.get("command", [])
    if not selection:
        require(not any(a == "--filter" or a.startswith("--filter=") for a in args), "Original main phase was filtered")
    log = folder / (name + ".log")
    log.write_bytes(archive_bytes(archive, "hosted-suite/" + name + "/console.log"))
    framework = assess_output(log, swift_testing_runs=0 if name == "xctest" else 1,
                              xctest_runs=2 if name == "xctest" else 0)
    require(framework["passed"] and framework == phase.get("framework"), "Original framework proof differs")
    if name == "xctest":
        count = sum(bool(XCTEST_START.fullmatch(ANSI.sub("", line).rstrip("\r\n"))) for line in log.read_text().split("\n"))
        require(count > 0 and count == phase.get("testCaseExecutions"), "Original XCTest inventory differs")
        return {"executions": count, "framework": framework}
    path = folder / (name + ".events.jsonl")
    path.write_bytes(archive_bytes(archive, "hosted-suite/" + name + "/events.jsonl"))
    events = swift_events(path, "NexGenEngineTests" if name == "engine-swift-testing" else "NexGenVideoTests")
    require(events == phase.get("events") and events["functionExecutions"] > 0
            and set(events["discoveredFunctionIDs"]) == set(events["endedFunctionIDs"]) | set(events["skippedFunctionIDs"])
            and events["functionExecutions"] == len(events["endedFunctionIDs"]), "Original native inventory is incomplete")
    return {"executions": events["functionExecutions"], "framework": framework, "events": events}


def native_proof(root, source, run_id):
    folder = root / "parsed"; folder.mkdir(exist_ok=True)
    with zipfile.ZipFile(root / "tests.zip") as archive:
        suite = archive_json(archive, "hosted-suite/suite.json")
        capture = archive_json(archive, "run.json")
        require(suite.get("schema") == 1 and suite.get("sourceSHA") == source and suite.get("completed") is True
                and suite.get("scope") == "all" and suite.get("configuration") == "debug"
                and suite.get("filter") == "" and suite.get("scratchPath") is None
                and "productSourceSHA" not in suite and [p.get("name") for p in suite.get("phases", [])]
                == ["xctest", "engine-swift-testing", "app-swift-testing"], "Original full normal selection differs")
        require(capture.get("sourceSHA") == source and capture.get("runID") == str(run_id)
                and capture.get("status") == "test-process-exited"
                and capture.get("testExitCode") == capture.get("effectiveExitCode") == 0
                and capture.get("command") == capture.get("actualCommand") == capture.get("originalCommand"),
                "Original wrapper did not complete normally")
        args = capture["actualCommand"]
        require(len(args) == 6 and args[:2] == ["python3", "scripts/run_macos_tests.py"]
                and args[2] == "--cache-path" and args[4] == "--evidence", "Original command selected a different profile")
        phases = [phase_proof(archive, phase, folder) for phase in suite["phases"]]
        require(suite.get("testExecutions") == sum(p["executions"] for p in phases), "Original execution count differs")
        combined = folder / "combined.log"; combined.write_bytes(archive_bytes(archive, "hosted-suite/combined.log"))
        framework = assess_output(combined, swift_testing_runs=2, xctest_runs=2)
        require(framework["passed"] and framework == suite.get("combinedFrameworks") == capture.get("outputCompletion"),
                "Original four aggregates did not finish")
        host = archive_json(archive, "hosted-suite/app-swift-testing/host-receipt.json")
        host_proof(host, suite["phases"][2], suite, phases[2]["events"], source)
        require(host["parentPID"] == capture.get("runLoopProbe", {}).get("swiftTestPID")
                and capture.get("runLoopProbe", {}).get("status") == "not-requested", "Original parent or normal profile differs")
        watchdog = archive_json(archive, "hosted-suite/app-swift-testing/watchdog/receipt.json")
        reports = watchdog.get("reports", [])
        require(len(reports) == 1 and reports[0].get("processID") == host["pid"], "Original OS report is not owned")
        raw = archive_bytes(archive, "hosted-suite/app-swift-testing/watchdog/" + reports[0]["file"])
        report = json.loads(raw)
        require(hashlib.sha256(raw).hexdigest() == reports[0]["sha256"] and report.get("processID") == host["pid"],
                "Original watchdog bytes differ")
        require(re.fullmatch(r"Version [0-9.]+ \(Build \w+\)", report.get("operatingSystem", "")),
                "Original owned OS identity is missing or malformed")
        compiler = archive_bytes(archive, "hosted-suite/app-swift-testing/swiftc-path.stdout").decode().strip()
        require(compiler == "/Applications/Xcode_27.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
                and all(host[k].startswith("/Applications/Xcode_27.app/") for k in ("getterImagePath", "entryPointImagePath")),
                "Original selected test toolchain differs")
    return {"executions": suite["testExecutions"], "phases": phases, "framework": framework,
            "host": host, "compilerPath": compiler, "watchdog": report, "watchdogCause": "UNKNOWN"}


def hdr_proof(root, source):
    folder = root / "parsed-hdr"; folder.mkdir(exist_ok=True)
    with zipfile.ZipFile(root / "hdr.zip") as archive:
        suite = archive_json(archive, "hosted-suite/suite.json")
        require(suite.get("sourceSHA") == source and suite.get("completed") is True
                and suite.get("scope") == "app-swift-testing" and suite.get("configuration") == "debug"
                and suite.get("filter") == "HDRExportTests" and suite.get("scratchPath") is None
                and "productSourceSHA" not in suite and len(suite.get("phases", [])) == 1, "Original HDR profile differs")
        phase = suite["phases"][0]
        require(phase.get("name") == "app-swift-testing" and phase.get("command", [])[-2:] == ["--filter", "HDRExportTests"],
                "Original HDR command differs")
        proof = phase_proof(archive, phase, folder, "HDRExportTests")
        require(suite.get("testExecutions") == proof["executions"]
                and all(name.startswith("NexGenVideoTests.HDRExportTests/") for name in proof["events"]["endedFunctionIDs"]),
                "Original HDR execution inventory differs")
        host = archive_json(archive, "hosted-suite/app-swift-testing/host-receipt.json")
        host_proof(host, phase, suite, proof["events"], source)
        qc = archive_json(archive, "hdr-qc.v1.json")
        movie = hashlib.sha256(archive_bytes(archive, "hdr-reference.mov")).hexdigest()
        require(qc.get("schema") == "delivery-hdr-qc/v1" and qc.get("passed") is True
                and qc.get("output_sha256") == movie and len(qc.get("reference_frames", [])) == 4
                and all(f.get("out_of_range_pixel_count") == 0 for f in qc["reference_frames"]), "Original HDR pixels or movie differ")
        return {"movieSHA256": movie, "qc": qc, "executions": proof["executions"]}


def check_artifacts(root, receipt, jobs):
    run = receipt["originalRun"]
    for key, (name, job_name) in ARTIFACTS.items():
        artifact = receipt["artifacts"].get(key)
        if artifact is None:
            require(key in {"lottie", "blockout"}, "Missing required original artifact")
            continue
        path = root / (key + ".zip")
        verify_artifact(artifact, run, jobs[job_name], artifact["id"], checksum(path), name.format(run=run["id"]))
        require(path.stat().st_size == artifact["size_in_bytes"], "Original artifact size differs")
        require(datetime.fromisoformat(artifact["expires_at"].replace("Z", "+00:00")) > datetime.now(timezone.utc) + timedelta(hours=12),
                "Original evidence expires too soon")


def prepare(run_id, root):
    from resume_core_completed_app import RUN, prepare as prepare_completed_app
    if run_id == RUN:
        return prepare_completed_app(root)
    root.mkdir(parents=True, exist_ok=False)
    run = api(f"actions/runs/{run_id}")
    require(run.get("id") == run_id, "Original run identity differs")
    changed, workflow = source_binding(run["head_sha"], os.environ["GITHUB_SHA"])
    listing = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    jobs = producer(run, listing, workflow)
    artifacts = api(f"actions/runs/{run_id}/artifacts?per_page=100")
    require(artifacts.get("total_count") == len(artifacts.get("artifacts", [])), "Incomplete artifact inventory")
    selected = {}
    for key, (name, job_name) in ARTIFACTS.items():
        found = [a for a in artifacts["artifacts"] if a.get("name") == name.format(run=run_id)]
        if not found and key in {"lottie", "blockout"}:
            selected[key] = None; continue
        require(len(found) == 1, "Missing or duplicate original artifact: " + key)
        item = found[0]
        require(type(item.get("size_in_bytes")) is int and 0 < item["size_in_bytes"] <= 64 * 1024 * 1024,
                "Original evidence size is invalid")
        verify_artifact(item, run, jobs[job_name], item["id"], item.get("digest", "").removeprefix("sha256:"), name.format(run=run_id))
        download(item, root / (key + ".zip")); selected[key] = item
    with (root / "original-job.log").open("xb") as output:
        subprocess.run(["gh", "api", "--allow-escape-sequences",
                        f"repos/iret77/nexgenvideo/actions/jobs/{jobs['Build & Test']['id']}/logs"],
                       stdin=subprocess.DEVNULL, stdout=output, check=True, timeout=120)
    receipt = {"schema": "core-full-resume/v1", "sourceSHA": os.environ["GITHUB_SHA"],
               "runID": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
               "originalRun": run, "originalJobs": listing, "changedPaths": changed, "artifacts": selected,
               "originalExecution": {"runID": run_id, "jobID": jobs["Build & Test"]["id"], "attempt": 1, "sourceSHA": run["head_sha"]}}
    check_artifacts(root, receipt, jobs)
    receipt["nativeProof"] = native_proof(root, run["head_sha"], run_id)
    receipt["hdrProof"] = hdr_proof(root, run["head_sha"])
    log = (root / "original-job.log").read_text()
    require("NGV_HDR_RUNTIME_QC: 1" in ANSI.sub("", log), "Original HDR runtime profile is unproven")
    receipt["toolchain"] = toolchain(log)
    require("(Selected)\t/Applications/Xcode_27.app" in log, "Original pre-selection compiler cannot bind the selected Xcode")
    receipt["jobLogSHA256"] = checksum(root / "original-job.log")
    require(api(f"actions/runs/{run_id}").get("run_attempt") == 1, "Original producer was rerun during binding")
    write(root / "receipt.json", receipt)


def verify(root, native=False):
    receipt = json.loads((root / "receipt.json").read_text())
    if receipt.get("schema") == "core-completed-app-resume/v1":
        from resume_core_completed_app import verify as verify_completed_app
        return verify_completed_app(root, native=native)
    require(receipt.get("schema") == "core-full-resume/v1" and receipt.get("sourceSHA") == os.environ.get("GITHUB_SHA")
            and receipt.get("runID") == os.environ.get("GITHUB_RUN_ID")
            and receipt.get("attempt") == os.environ.get("GITHUB_RUN_ATTEMPT"), "Full continuation belongs to another execution")
    run = receipt["originalRun"]
    changed, workflow = source_binding(run["head_sha"], receipt["sourceSHA"])
    require(changed == receipt["changedPaths"], "Bound harness changes differ")
    jobs = producer(run, receipt["originalJobs"], workflow)
    require(receipt.get("originalExecution") == {"runID": run["id"], "jobID": jobs["Build & Test"]["id"],
                                               "attempt": 1, "sourceSHA": run["head_sha"]},
            "Original execution label differs from its producer")
    check_artifacts(root, receipt, jobs)
    require(native_proof(root, run["head_sha"], run["id"]) == receipt["nativeProof"], "Original native proof changed")
    require(hdr_proof(root, run["head_sha"]) == receipt["hdrProof"], "Original HDR proof changed")
    require(checksum(root / "original-job.log") == receipt["jobLogSHA256"]
            and toolchain((root / "original-job.log").read_text()) == receipt["toolchain"], "Original toolchain log changed")
    if native:
        verify_platform(receipt)
    return receipt


def verify_platform(receipt):
    print(json.dumps({"verifierPython": sys.version, "verifierExecutable": sys.executable}), flush=True)
    require(not any(diagnostic_key(k.encode()) for k in os.environ), "Reconstruction cannot enable a diagnostic profile")
    require(command(["xcodebuild", "-version"]) == receipt["toolchain"]["xcode"]
            and swift_identity(command(["xcrun", "swift", "--version"])) == receipt["toolchain"]["swift"]
            and command(["xcrun", "--find", "swiftc"]) == receipt["nativeProof"]["compilerPath"]
            and command(["uname", "-m"]) == "arm64", "Reconstruction compiler or architecture changed")
    version, build = command(["sw_vers", "-productVersion"]), command(["sw_vers", "-buildVersion"])
    require(f"Version {version} (Build {build})" == receipt["nativeProof"]["watchdog"]["operatingSystem"],
            "Reconstruction OS differs from original tests")


def finish(root, app):
    receipt = verify(root, native=True)
    require(app.is_dir(), "Reconstructed app is missing")
    tree = command(["python3", "scripts/external-gui/acceptance.py", "tree-sha256", "--app", str(app)])
    require(re.fullmatch(r"[a-f0-9]{64}", tree), "Reconstructed app tree identity is invalid")
    transfer = Path(os.environ["RUNNER_TEMP"]) / "workspace-transfer"
    workspace = json.loads((transfer / "workspace-ui-input.json").read_text())
    require(workspace.get("schema") == "nexgenvideo/workspace-ui-input/1"
            and workspace.get("sourceSHA") == receipt["sourceSHA"] and workspace.get("appTreeSHA256") == tree
            and workspace.get("archiveSHA256") == checksum(transfer / "workspace-ui.tar.gz"),
            "Transferred workspace archive differs from the reconstructed app")
    source_path = app.parent / "bpy-source/bpy-source-receipt.json"
    source_receipt = json.loads(source_path.read_text())
    public = public_asset(json.loads(Path("Runtime/bpy/runtime-lock.json").read_text()))
    require_receipt(source_receipt, public, receipt["sourceSHA"])
    require(checksum(source_path) == checksum(transfer / "bpy-source-receipt.json"),
            "Transferred bpy source receipt differs from the bundle receipt")
    result = {"schema": "core-full-completion/v1", "originalExecution": receipt["originalExecution"],
              "currentExecution": {"runID": receipt["runID"], "attempt": receipt["attempt"], "sourceSHA": receipt["sourceSHA"]},
              "verifierPython": {"version": sys.version, "executable": sys.executable},
              "appTreeSHA256": tree, "buildCommand": BUILD, "receiptSHA256": checksum(root / "receipt.json"),
              "appZipSHA256": checksum(app.with_suffix(".zip")), "workspace": workspace,
              "workspaceReceiptSHA256": checksum(transfer / "workspace-ui-input.json"),
              "bpySourceReceiptSHA256": checksum(source_path),
              "reconstructed": "Identical product source and toolchain; objects are not byte-proven against original tested objects",
              "reused": receipt.get("reused", ["full native tests", "native signing fixtures", "HDR QC", "Agent UI rendering", "unchanged static source gates"]),
              "limitations": "Original Glow SIGSEGV, watchdog and Current93 helper65s timeout causes UNKNOWN. "
                             "b95 cross-process bpy acceptance remains unproven until the current runtime job passes. "
                             "No native UX or RC-DMG qualification. No release/tag/catalog authorization."}
    origin = f"Native tests reused from run {receipt['originalRun']['id']} at {receipt['originalRun']['head_sha']}. "
    if receipt.get("schema") == "core-completed-app-resume/v1":
        from resume_core_completed_app import finish_evidence
        result.update(finish_evidence(root, receipt))
        backend = result['backendExecution']
        origin = (f"App tests reused from run {receipt['originalRun']['id']} at {receipt['originalRun']['head_sha']}; "
                  f"XCTest/Engine from run {backend['runID']} at {backend['sourceSHA']}. Fresh HDR QC passed in this execution. ")
    write(root / "completed.json", result)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(origin +
                      "The current app was reconstructed with unchanged product source and toolchain; original object-byte identity is unproven. "
                      "All bundle/runtime gates remain required.\n")


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("action", choices=("prepare", "verify", "finish"))
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--native", action="store_true")
    parser.add_argument("--plan", nargs=3)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        require(args.run_id and args.run_id > 0, "A positive original full Core run is required")
        prepare(args.run_id, args.evidence)
    elif args.action == "verify":
        if args.plan is not None:
            require(args.plan == ["true", "true", "true"], "Full continuation requires all Core branches")
        verify(args.evidence, native=args.native)
    else:
        require(args.app is not None, "A reconstructed app is required")
        finish(args.evidence, args.app)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, VerificationError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        raise SystemExit(f"Full Core continuation refused: {error}")
