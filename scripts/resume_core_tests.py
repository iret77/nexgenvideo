"""Carry verified Core backends across harness-only changes, then complete normal App tests."""
import argparse
import hashlib
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
    "scripts/test_swiftpm_dependency_cache.py", "scripts/resume_core_source_checks.py",
    "scripts/test_resume_core_source_checks.py",
    "scripts/test_ci_workflow.py", "scripts/test_verified_pr_source_checks.py",
}
BUILD_JOB = "Compile, unit tests, app and native bpy acceptance / Build & Test"
TIMEOUT_SOURCE = "0d991d3bd23b0f1eb62bac7fdfe102fe4df34d9f"
TIMEOUT_RUN = 41366151985
TIMEOUT_DIGEST = "3bf3e356352e5d57151b244545aa71ec1b31570b997cea7a35d4df4304efcee3"
CONTEXT_RUN = 41390599748
CONTEXT_SOURCE = "bf55cd2cee1f808f4ddf995132aed82dd6b80699"
CONTEXT_PRODUCT = "21160564f484cbd9aaa1a563d561077e523a03ab"
CONTEXT_ARTIFACT = 13117531199
CONTEXT_DIGEST = "0dda9c73da9de95853cca890eab496417bf5d6a2418539d634056980299e2477"


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


def verify_backends(archive, root, source, timeout=False):
    suite = archive_json(archive, "hosted-suite/suite.json")
    require(suite.get("schema") == 1 and suite.get("sourceSHA") == source
            and suite.get("scope") == "all" and suite.get("configuration") == "debug"
            and not suite.get("filter") and not suite.get("scratchPath")
            and suite.get("completed") is False
            and [p.get("name") for p in suite.get("phases", [])]
            == ["xctest", "engine-swift-testing", "app-swift-testing"], "Original suite selection differs")
    app = suite["phases"][2]
    require((timeout and app.get("status") == "running" and "exitCode" not in app)
            or (not timeout and app.get("status") == "failed" and app.get("exitCode", 0) != 0),
            "Original App phase did not fail or match the pinned interrupted timeout")
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
    return suite, proofs


def verify_archive(root, source):
    with zipfile.ZipFile(root / "original.zip") as archive:
        timeout = source == TIMEOUT_SOURCE and checksum(root / "original.zip") == TIMEOUT_DIGEST
        suite, proofs = verify_backends(archive, root, source, timeout=timeout)
        discovery = inventory(archive_bytes(archive, "hosted-suite/app-swift-testing/events.jsonl"))
        if timeout:
            return {"backends": proofs, "appInventory": discovery, "os": timeout_platform(archive, suite, root)}
        raw = archive_bytes(archive, "hosted-suite/app-swift-testing/post-mortem/owned-host-0.ips").decode()
        decoder = json.JSONDecoder()
        header, end = decoder.raw_decode(raw)
        crash, _ = decoder.raw_decode(raw[end:].lstrip())
        require(header.get("app_name") == "NexGenVideoAppKitTestHost"
                and crash.get("pid") == suite["phases"][2].get("pid"), "Original platform report is not owned")
        return {"backends": proofs, "appInventory": discovery, "os": crash["osVersion"]}


def timeout_platform(archive, suite, root):
    capture = archive_json(archive, "appkit-host-stale/capture-receipt.json")
    status = archive_json(archive, "appkit-host-stale-status.json")
    snapshot = archive_bytes(archive, "appkit-host-stale/suite-original.json")
    sample = archive_bytes(archive, "appkit-host-stale/sample.txt")
    target = capture["target"]
    command = suite["phases"][2]["command"]
    wrapper = archive_json(archive, "run.json")
    require(wrapper["runID"] == str(TIMEOUT_RUN) and wrapper["sourceSHA"] == TIMEOUT_SOURCE
            and wrapper["status"] == "running" and json.loads(snapshot) == suite
            and status["suiteSHA256"] == hashlib.sha256(snapshot).hexdigest()
            and status["target"] == target and status["rootIdentity"]["pid"] == target["parentPID"]
            == capture["driverPID"] == status["driverPID"]
            and capture["status"] == "capture-returned" and capture["returnCode"] == 0
            and capture["originalRunningCommand"] == status["originalRunningCommand"] == command
            and command == [str(Path(suite["binPath"]) / "NexGenVideoAppKitTestHost"), "--event-stream-version", "0"]
            and target["executable"] == command[0] and type(target["pid"]) is int and target["pid"] > 0
            and capture["sampleSHA256"] == hashlib.sha256(sample).hexdigest()
            and capture["sampleBytes"] == len(sample), "Interrupted timeout sample is not bound to its original host")
    text = sample.decode()
    require(re.search(rf"(?m)^Process:\s+NexGenVideoAppKitTestHost \[{target['pid']}\]$", text)
            and re.search(rf"(?m)^Parent Process:\s+Python \[{target['parentPID']}\]$", text)
            and "##[error]The action 'Test' has timed out after 30 minutes." in (root / "original-job.log").read_text(),
            "Original owned sample or action timeout evidence differs")
    platform = re.findall(r"(?m)^OS Version:\s+(macOS [0-9.]+) \(([^)]+)\)$", text)
    require(len(platform) == 1, "Original timeout platform is ambiguous")
    return {"train": platform[0][0], "build": platform[0][1]}


def inventory_producer(run, jobs):
    if run.get("id") != CONTEXT_RUN:
        return verify_producer(run, jobs, run["head_sha"]), f"app-zombie-diagnostic-{run['id']}-a1"
    require(run.get("head_sha") == CONTEXT_SOURCE and run.get("run_attempt") == 1
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("path") == ".github/workflows/diagnostic-acceptance.yml"
            and run.get("event") == "workflow_dispatch" and run.get("status") == "completed"
            and run.get("conclusion") == "success"
            and jobs.get("total_count") == len(jobs.get("jobs", [])), "Completed context producer differs")
    matches = [j for j in jobs["jobs"] if j.get("name") == "ci-film-review-context"]
    require(len(matches) == 1, "Missing or duplicate completed context job")
    job = matches[0]
    require(job.get("run_id") == CONTEXT_RUN and job.get("head_sha") == CONTEXT_SOURCE
            and job.get("run_attempt") == 1 and job.get("status") == "completed"
            and job.get("conclusion") == "success", "Completed context job identity differs")
    for name in ("Restore exact compiled products without rebuilding", "Reproduce the original App process context once",
                 "Preserve App context interpretation and unchanged products", "Verify unchanged context product source"):
        require(sum(s.get("name") == name and s.get("conclusion") == "success" for s in job["steps"]) == 1,
                "Completed context step differs: " + name)
    return job, f"film-review-context-diagnostic-{CONTEXT_RUN}-a1"


def context_inventory(root, binding, source, failure_artifact, job, name):
    artifact = binding["artifact"]
    require(source == TIMEOUT_SOURCE and failure_artifact.get("id") == 13109352050
            and failure_artifact.get("digest") == "sha256:" + TIMEOUT_DIGEST
            and artifact.get("id") == CONTEXT_ARTIFACT and checksum(root / "inventory.zip") == CONTEXT_DIGEST,
            "Completed context inventory is not bound to the original timeout")
    verify_artifact(artifact, binding["run"], job, CONTEXT_ARTIFACT, CONTEXT_DIGEST, name)
    with zipfile.ZipFile(root / "inventory.zip") as archive:
        original = archive_json(archive, "film-review-context-binding/binding.json")
        suite = archive_json(archive, "film-review-context/hosted-suite/suite.json")
        wrapper = archive_json(archive, "film-review-context/run.json")
        phase = suite["phases"][0]
        require(original["originalFailureRun"] == TIMEOUT_RUN and original["originalFailureDigest"] == TIMEOUT_DIGEST
                and original["harnessSHA"] == suite["sourceSHA"] == suite["harnessSourceSHA"] == CONTEXT_SOURCE
                and original["productSHA"] == suite["productSourceSHA"] == CONTEXT_PRODUCT
                and original["coreAcceptance"] is original["releaseAcceptance"] is False
                and suite["completed"] is True and len(suite["phases"]) == 1
                and suite["scope"] == "app-swift-testing" and suite["filter"] == ".*"
                and phase["status"] == "verified-execution" and phase["exitCode"] == 0
                and phase["outputCapture"]["eof"] is True and phase["outputCapture"]["originalExitCode"] == 0
                and wrapper["sourceSHA"] == CONTEXT_SOURCE and wrapper["runID"] == str(CONTEXT_RUN)
                and wrapper["testExitCode"] == wrapper["effectiveExitCode"] == 0,
                "Completed diagnostic inventory is incomplete or belongs to another execution")
        path = root / "inventory-events.jsonl"
        path.write_bytes(archive_bytes(archive, "film-review-context/hosted-suite/app-swift-testing/events.jsonl"))
        events = swift_events(path, "NexGenVideoTests")
        require(events == phase["events"] and events["discoveredFunctionIDs"] == original["expectedDiscoveredFunctionIDs"]
                and events["startedFunctionIDs"] == events["endedFunctionIDs"] == original["expectedFunctionIDs"]
                and events["skippedFunctionIDs"] == original["expectedSkippedFunctionIDs"]
                and len(events["discoveredFunctionIDs"]) == 3668 and events["functionExecutions"] == 3660
                and len(events["skippedFunctionIDs"]) == 8, "Completed original App inventory differs")
        return {"functions": events["discoveredFunctionIDs"], "skips": events["skippedFunctionIDs"]}


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
    job, name = inventory_producer(run, binding["jobs"])
    if run["id"] == CONTEXT_RUN:
        return context_inventory(root, binding, source, failure_artifact, job, name)
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
    _, inventory_name = inventory_producer(inventory_run, inventory_jobs)
    listing = api(f"actions/runs/{inventory_run_id}/artifacts?per_page=100")
    require(listing.get("total_count") == len(listing.get("artifacts", [])), "Incomplete inventory artifact list")
    matches = [a for a in listing["artifacts"] if a.get("name") == inventory_name]
    require(len(matches) == 1, "Missing or duplicate completed App inventory")
    download(matches[0], root / "inventory.zip")
    binding = {"run": inventory_run, "jobs": inventory_jobs, "artifact": matches[0]}
    full_inventory = verify_inventory(root, binding, run["head_sha"], artifact)
    original_inventory = proof["appInventory"]
    skips_match = (full_inventory["skips"] == original_inventory["skips"] if inventory_run_id == CONTEXT_RUN
                   else set(original_inventory["skips"]) <= set(full_inventory["skips"]))
    require(full_inventory["functions"] == original_inventory["functions"] and skips_match,
            "App discovery changed after original failure")
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
    complete_app(root, suite_root, capture_root, verify_local(root))


def complete_app(root, suite_root, capture_root, receipt, identity=lambda value: value):
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
    def identities(values):
        result = [identity(value) for value in values]
        require(len(result) == len(set(result)), "App identity normalization collides")
        return sorted(result)
    require(events == phase.get("events") and identities(events["discoveredFunctionIDs"]) == identities(original["functions"])
            and identities(events["skippedFunctionIDs"]) == identities(original["skips"])
            and set(identities(events["endedFunctionIDs"])) == set(identities(original["functions"])) - set(identities(original["skips"]))
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
