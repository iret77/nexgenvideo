"""Carry verified Core backends across harness-only changes, then complete normal App tests."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

from retained_app_test_products import api, archive_bytes, archive_json, checksum, download, require, verify_artifact, verify_execution, verify_producer, write
from run_macos_tests import swift_events, VerificationError, XCTEST_START
from verify_swift_test_output import ANSI, assess_output
from app_host_zombie_diagnostic import diagnostic_key


HARNESS_PATHS = {
    ".github/workflows/ci.yml", ".github/workflows/ci-batch.yml",
    ".github/workflows/diagnostic-acceptance.yml", "scripts/resume_core_tests.py",
    "scripts/test_resume_core_tests.py", "scripts/app_host_zombie_diagnostic.py",
    "scripts/capture_render_review_test_diagnostic.py", "scripts/retained_app_test_products.py",
    "scripts/run_macos_tests.py", "scripts/test_app_host_zombie_diagnostic.py",
    "scripts/test_diagnostic_acceptance.py", "scripts/test_retained_app_test_products.py",
    "scripts/test_run_macos_tests.py", "scripts/test_swift_test_failure_propagation.py",
    "scripts/verify_diagnostic_candidate.py",
}
BUILD_JOB = "Compile, unit tests, app and native bpy acceptance / Build & Test"


def command(args):
    return subprocess.check_output(args, stdin=subprocess.DEVNULL, text=True, timeout=60).strip()


def verify_sources(source, head):
    require(all(re.fullmatch(r"[a-f0-9]{40}", value) for value in (source, head)), "Invalid source identity")
    require(command(["git", "rev-parse", "HEAD"]) == head, "Checkout differs from Actions source")
    subprocess.run(["git", "merge-base", "--is-ancestor", source, head], check=True,
                   stdin=subprocess.DEVNULL, timeout=30)
    changed = command(["git", "diff", "--name-only", "--no-renames", source, head]).splitlines()
    require(set(changed) <= HARNESS_PATHS, "Product, test, dependency, build or runtime input changed")
    require(not command(["git", "status", "--porcelain", "--untracked-files=no"]), "Tracked checkout is dirty")
    return changed


def verify_jobs(run, jobs):
    require(run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("path") == ".github/workflows/ci-batch.yml"
            and run.get("event") == "workflow_dispatch" and run.get("run_attempt") == 1
            and run.get("status") == "completed" and run.get("conclusion") == "failure",
            "Resume requires an original completed failed Core batch")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete original job list")
    matches = [job for job in jobs["jobs"] if job.get("name") == BUILD_JOB]
    require(len(matches) == 1, "Missing or duplicate original Core job")
    job = matches[0]
    require(job.get("run_id") == run["id"] and job.get("run_attempt") == 1
            and job.get("head_sha") == run["head_sha"] and job.get("status") == "completed"
            and job.get("conclusion") == "failure", "Original Core job identity differs")
    expected = {"Build": "success", "Stage test runtime inputs": "success",
                "Verify build did not mutate tracked source": "success", "Test": "failure",
                "Verify native app signing with nested runtime content": "success",
                "Upload render review test diagnosis": "success"}
    for name, conclusion in expected.items():
        steps = [step for step in job.get("steps", []) if step.get("name") == name]
        require(len(steps) == 1 and steps[0].get("conclusion") == conclusion,
                "Original Core step was not completed as required: " + name)
    return job


def inventory(raw):
    records = [json.loads(line) for line in raw.splitlines()]
    functions = [r["payload"]["id"] for r in records
                 if r.get("kind") == "test" and r["payload"].get("kind") == "function"]
    require(functions and len(functions) == len(set(functions))
            and all(name.startswith("NexGenVideoTests.") for name in functions), "Invalid original App discovery")
    skipped = {r["payload"]["testID"] for r in records
               if r.get("kind") == "event" and r["payload"].get("kind") == "testSkipped"}
    return {"functions": sorted(functions), "skips": sorted(set(functions) & skipped)}


def verify_archive(root, source):
    with zipfile.ZipFile(root / "original.zip") as archive:
        suite = archive_json(archive, "hosted-suite/suite.json")
        require(suite.get("schema") == 1 and suite.get("sourceSHA") == source
                and suite.get("scope") == "all" and suite.get("configuration") == "debug"
                and not suite.get("filter") and not suite.get("scratchPath")
                and suite.get("completed") is False
                and [p.get("name") for p in suite.get("phases", [])]
                == ["xctest", "engine-swift-testing", "app-swift-testing"], "Original suite selection differs")
        require(suite["phases"][2].get("status") == "failed"
                and suite["phases"][2].get("exitCode", 0) != 0, "Original App phase did not fail")
        proofs = []
        for phase, swift, xctest in ((suite["phases"][0], 0, 2), (suite["phases"][1], 1, 0)):
            require(phase.get("status") == "verified-execution" and phase.get("exitCode") == 0
                    and "--filter" not in phase.get("command", [])
                    and not any(v.startswith("--filter=") for v in phase.get("command", [])),
                    "Original backend is failed, incomplete or filtered")
            log = root / (phase["name"] + ".log")
            log.write_bytes(archive_bytes(archive, "hosted-suite/" + phase["name"] + "/console.log"))
            framework = assess_output(log, swift_testing_runs=swift, xctest_runs=xctest)
            require(framework["passed"] and framework == phase.get("framework"), "Original framework proof differs")
            proof = {"name": phase["name"], "framework": framework, "logSHA256": checksum(log)}
            if xctest:
                count = sum(bool(XCTEST_START.fullmatch(ANSI.sub("", line))) for line in log.read_text().splitlines())
                require(count > 0 and count == phase.get("testCaseExecutions"), "Original XCTest execution count differs")
                proof["testCaseExecutions"] = count
            else:
                events = root / "engine-events.jsonl"
                events.write_bytes(archive_bytes(archive, "hosted-suite/engine-swift-testing/events.jsonl"))
                parsed = swift_events(events, "NexGenEngineTests")
                require(parsed == phase.get("events") and parsed["functionExecutions"] > 0
                        and set(parsed["discoveredFunctionIDs"]) == set(parsed["endedFunctionIDs"]) | set(parsed["skippedFunctionIDs"]),
                        "Original Engine inventory is incomplete")
                proof.update(events=parsed, eventsSHA256=checksum(events))
            proofs.append(proof)
        discovery = inventory(archive_bytes(archive, "hosted-suite/app-swift-testing/events.jsonl"))
        raw = archive_bytes(archive, "hosted-suite/app-swift-testing/post-mortem/owned-host-0.ips").decode()
        decoder = json.JSONDecoder()
        header, end = decoder.raw_decode(raw)
        crash, _ = decoder.raw_decode(raw[end:].lstrip())
        require(header.get("app_name") == "NexGenVideoAppKitTestHost"
                and crash.get("pid") == suite["phases"][2].get("pid"), "Original platform report is not owned")
        return {"backends": proofs, "appInventory": discovery, "os": crash["osVersion"]}


def toolchain(log):
    lines = [ANSI.sub("", line) for line in log.splitlines()]
    swift = [line.split("Z ", 1)[-1] for line in lines if re.search(r"Z Apple Swift version ", line)]
    xcode = re.findall(r"Xcode Versions: ([0-9.]+) \(([^)]+)\) \[Apple Silicon\] \(Selected\)", log)
    require(len(swift) == 1 and len(xcode) == 1, "Original toolchain is ambiguous")
    return {"swift": swift[0], "xcode": "Xcode " + xcode[0][0] + "\nBuild version " + xcode[0][1]}


def swift_identity(output):
    versions = [line for line in output.splitlines() if line.startswith("Apple Swift version ")]
    require(len(versions) == 1, "Current Swift compiler identity is ambiguous")
    return versions[0]


def verify_inventory(root, binding, source, failure_artifact):
    run, artifact = binding["run"], binding["artifact"]
    job = verify_producer(run, binding["jobs"], run["head_sha"])
    verify_sources(run["head_sha"], os.environ["GITHUB_SHA"])
    verify_artifact(artifact, run, job, artifact["id"], checksum(root / "inventory.zip"),
                    f"app-zombie-diagnostic-{run['id']}-a1")
    with zipfile.ZipFile(root / "inventory.zip") as archive:
        compiled = archive_json(archive, "candidate-metadata/compiled-products.json")
        execution = archive_json(archive, "candidate-metadata/diagnostic-execution.json")
        suite = archive_json(archive, "app-zombie-diagnostic/hosted-suite/suite.json")
        wrapper = archive_json(archive, "app-zombie-diagnostic/run.json")
        verify_execution(compiled, execution, suite, wrapper, source, run["head_sha"], run["id"])
        require(execution.get("originalArtifactID") == str(failure_artifact["id"])
                and execution.get("originalArtifactSHA256") == failure_artifact["digest"].removeprefix("sha256:"),
                "Completed inventory is not anchored to the original failed Core")
        path = root / "inventory-events.jsonl"
        path.write_bytes(archive_bytes(archive, "app-zombie-diagnostic/hosted-suite/app-swift-testing/events.jsonl"))
        events = swift_events(path, "NexGenVideoTests")
        require(events == suite["phases"][0]["events"]
                and set(events["discoveredFunctionIDs"]) == set(events["endedFunctionIDs"]) | set(events["skippedFunctionIDs"]),
                "Completed inventory has unexecuted tests")
        return {"functions": events["discoveredFunctionIDs"], "skips": events["skippedFunctionIDs"]}


def prepare(run_id, inventory_run_id, root):
    root.mkdir(parents=True, exist_ok=False)
    run = api(f"actions/runs/{run_id}")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    job = verify_jobs(run, jobs)
    head = os.environ["GITHUB_SHA"]
    changed = verify_sources(run["head_sha"], head)
    listing = api(f"actions/runs/{run_id}/artifacts?per_page=100")
    require(listing.get("total_count") == len(listing.get("artifacts", [])), "Incomplete original artifact list")
    matches = [a for a in listing["artifacts"] if a.get("name") == f"render-review-test-diagnostic-{run_id}"]
    require(len(matches) == 1, "Missing or duplicate original diagnostic artifact")
    artifact = matches[0]
    digest = artifact.get("digest", "").removeprefix("sha256:")
    require(re.fullmatch(r"[a-f0-9]{64}", digest), "Original artifact has no GitHub digest")
    verify_artifact(artifact, run, job, artifact["id"], digest, matches[0]["name"])
    download(artifact, root / "original.zip")
    with (root / "original-job.log").open("xb") as output:
        subprocess.run(["gh", "api", "--allow-escape-sequences",
                        f"repos/iret77/nexgenvideo/actions/jobs/{job['id']}/logs"],
                       stdin=subprocess.DEVNULL, stdout=output, check=True, timeout=120)
    proof = verify_archive(root, run["head_sha"])
    inventory_run = api(f"actions/runs/{inventory_run_id}")
    inventory_jobs = api(f"actions/runs/{inventory_run_id}/attempts/1/jobs?per_page=100")
    verify_producer(inventory_run, inventory_jobs, inventory_run["head_sha"])
    listing = api(f"actions/runs/{inventory_run_id}/artifacts?per_page=100")
    require(listing.get("total_count") == len(listing.get("artifacts", [])), "Incomplete inventory artifact list")
    matches = [a for a in listing["artifacts"] if a.get("name") == f"app-zombie-diagnostic-{inventory_run_id}-a1"]
    require(len(matches) == 1, "Missing or duplicate completed App inventory")
    download(matches[0], root / "inventory.zip")
    binding = {"run": inventory_run, "jobs": inventory_jobs, "artifact": matches[0]}
    full_inventory = verify_inventory(root, binding, run["head_sha"], artifact)
    require(full_inventory["functions"] == proof["appInventory"]["functions"]
            and set(proof["appInventory"]["skips"]) <= set(full_inventory["skips"]), "App discovery changed after original failure")
    receipt = {"schema": "core-backend-resume/v1", "sourceSHA": head,
               "runID": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
               "originalSourceSHA": run["head_sha"], "originalRun": run, "originalJobs": jobs,
               "artifact": artifact, "changedPaths": changed, "proof": proof,
               "inventoryBinding": binding, "completedAppInventory": full_inventory,
               "toolchain": toolchain((root / "original-job.log").read_text()),
               "jobLogSHA256": checksum(root / "original-job.log")}
    write(root / "receipt.json", receipt)


def verify_local(root, platform=True):
    receipt = json.loads((root / "receipt.json").read_text())
    require(receipt.get("schema") == "core-backend-resume/v1"
            and receipt.get("sourceSHA") == os.environ.get("GITHUB_SHA")
            and receipt.get("runID") == os.environ.get("GITHUB_RUN_ID")
            and receipt.get("attempt") == os.environ.get("GITHUB_RUN_ATTEMPT"), "Resume receipt belongs to another execution")
    run, artifact = receipt["originalRun"], receipt["artifact"]
    job = verify_jobs(run, receipt["originalJobs"])
    require(receipt["originalSourceSHA"] == run["head_sha"], "Original source binding differs")
    require(verify_sources(run["head_sha"], receipt["sourceSHA"]) == receipt["changedPaths"], "Source changes differ")
    verify_artifact(artifact, run, job, artifact["id"], checksum(root / "original.zip"),
                    f"render-review-test-diagnostic-{run['id']}")
    require(checksum(root / "original-job.log") == receipt["jobLogSHA256"]
            and toolchain((root / "original-job.log").read_text()) == receipt["toolchain"], "Original toolchain evidence changed")
    require(verify_archive(root, run["head_sha"]) == receipt["proof"], "Original backend proof changed")
    require(verify_inventory(root, receipt["inventoryBinding"], run["head_sha"], artifact)
            == receipt["completedAppInventory"], "Completed App inventory changed")
    if platform:
        require(not any(diagnostic_key(key.encode()) for key in os.environ), "Normal Core resume cannot enable a diagnostic profile")
        actual = {"swift": swift_identity(command(["swift", "--version"])),
                  "xcode": command(["xcodebuild", "-version"])}
        require(actual == receipt["toolchain"] and command(["uname", "-m"]) == "arm64"
                and "macOS " + command(["sw_vers", "-productVersion"]) == receipt["proof"]["os"]["train"]
                and command(["sw_vers", "-buildVersion"]) == receipt["proof"]["os"]["build"],
                "Current platform or compiler differs from retained successful backends")
    return receipt


def finish(root, suite_root, capture_root):
    receipt = verify_local(root)
    suite = json.loads((suite_root / "suite.json").read_text())
    capture = json.loads((capture_root / "run.json").read_text())
    require(suite.get("sourceSHA") == receipt["sourceSHA"] and suite.get("completed") is True
            and suite.get("scope") == "app-swift-testing" and suite.get("configuration") == "debug"
            and not suite.get("filter") and not suite.get("scratchPath")
            and "productSourceSHA" not in suite and len(suite.get("phases", [])) == 1,
            "Current normal full App suite is incomplete or differs")
    phase = suite["phases"][0]
    require(phase.get("name") == "app-swift-testing" and phase.get("exitCode") == 0
            and phase.get("status") == "verified-execution" and "diagnostic" not in phase,
            "Current App native execution failed or was instrumented")
    events = swift_events(suite_root / "app-swift-testing/events.jsonl", "NexGenVideoTests")
    original = receipt["completedAppInventory"]
    require(events == phase.get("events") and events["discoveredFunctionIDs"] == original["functions"]
            and events["skippedFunctionIDs"] == original["skips"]
            and set(events["endedFunctionIDs"]) == set(original["functions"]) - set(original["skips"])
            and events["functionExecutions"] == len(events["endedFunctionIDs"]), "Current App inventory differs")
    framework = assess_output(suite_root / "combined.log", swift_testing_runs=1, xctest_runs=0)
    require(framework["passed"] and framework == suite.get("combinedFrameworks"), "Current App framework did not complete")
    host = json.loads((suite_root / "app-swift-testing/host-receipt.json").read_text())
    require(host == phase.get("originalHostReceipt") and host.get("pid") == phase.get("pid")
            and type(host.get("parentPID")) is int and host["parentPID"] > 0
            and host["parentPID"] == capture.get("runLoopProbe", {}).get("swiftTestPID")
            and host.get("hostExecutable") == str(Path(suite["binPath"]) / "NexGenVideoAppKitTestHost")
            and host.get("bundleBinary") == str(Path(suite["binPath"]) / "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests")
            and host.get("sourceSHA") == receipt["sourceSHA"]
            and all(host.get(k) is True for k in ("mainThread", "applicationRunningAtStart", "started", "completed", "abiSucceeded", "runReturnedAfterCompletion"))
            and host.get("error") is None and host.get("recordingError") is None
            and host.get("eventRecordCount") == events["recordCount"], "Current owned host ABI proof differs")
    require(capture.get("testExitCode") == 0 and capture.get("effectiveExitCode") == 0
            and capture.get("status") == "test-process-exited"
            and capture.get("sourceSHA") == receipt["sourceSHA"], "Current capture wrapper failed")
    write(root / "completed.json", {"schema": "core-backend-completion/v1", "sourceSHA": receipt["sourceSHA"],
          "originalSourceSHA": receipt["originalSourceSHA"], "originalRunID": receipt["originalRun"]["id"],
          "reusedBackends": receipt["proof"]["backends"], "currentApp": suite,
          "currentAppSuiteSHA256": checksum(suite_root / "suite.json"),
          "currentCaptureSHA256": checksum(capture_root / "run.json"),
          "frameworkRuns": {"swiftTesting": 2, "xctest": 2},
          "note": "Original failed run stays failed; only its successful backends are reused. No native UX or DMG acceptance."})


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("action", choices=("prepare", "verify", "finish"))
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--inventory-run-id", type=int)
    parser.add_argument("--suite", type=Path)
    parser.add_argument("--capture", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        require(args.run_id and args.run_id > 0 and args.inventory_run_id and args.inventory_run_id > 0,
                "Positive original Core and completed inventory runs are required")
        prepare(args.run_id, args.inventory_run_id, args.evidence)
    elif args.action == "verify":
        verify_local(args.evidence)
    else:
        require(args.suite and args.capture, "Current suite and capture evidence are required")
        finish(args.evidence, args.suite, args.capture)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, VerificationError) as error:
        raise SystemExit("Core resume verification failed: " + str(error))
