import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

from app_host_zombie_diagnostic import diagnostic_key
from retained_app_test_products import api, archive_bytes, archive_json, checksum, download, require, verify_artifact, write
from resume_core_tests import command, complete_app, inventory, swift_identity, toolchain, verify_backends, verify_jobs
from run_macos_tests import swift_events, VerificationError


RUN = 40254944746
SOURCE = "7ebcff8c1d934b94109d7afb0d62ba46ad8b0f99"
ARTIFACT = 12623426261
DIGEST = "d88da45fa25364136de136a84ed1fb0bd8942cb7f30f8ea9346a72d4b8cde443"
LOG_DIGEST = "b41468a98d6d2f5d4307c82c033b1815f44c5a228aac3f1a50e94b8d6c8d8b70"
TESTS = {
    "Tests/NexGenVideoTests/Agent/AgentTranscriptLayoutPolicyTests.swift":
        "6f728e7c60ce665e80460180597c07ff934bff763eacd8c0245680427c03b96a",
    "Tests/NexGenVideoTests/Agent/RecognizedLyricsContextTests.swift":
        "5bed2d51e8ce0719b11fa0771594eaf66d0d4d8c11b6705586f1a682fec2cc41",
}
HARNESS = {
    ".github/workflows/ci.yml", ".github/workflows/ci-batch.yml",
    "scripts/resume_core_app_assertions.py", "scripts/test_resume_core_app_assertions.py",
    "scripts/resume_core_tests.py", "scripts/capture_render_review_test_diagnostic.py",
}
FAILURES = Counter({
    "NexGenVideoTests.AgentTranscriptLayoutPolicyTests/runningTranscriptActivityRetainsAnActiveStatusIndicator()/AgentTranscriptLayoutPolicyTests.swift:159:6": 2,
    "NexGenVideoTests.RecognizedLyricsContextTests/contextDelivery()/RecognizedLyricsContextTests.swift:10:6": 1,
})


def verify_sources(head):
    require(re.fullmatch(r"[a-f0-9]{40}", head) and command(["git", "rev-parse", "HEAD"]) == head,
            "Checkout differs from Actions source")
    subprocess.run(["git", "merge-base", "--is-ancestor", SOURCE, head], check=True,
                   stdin=subprocess.DEVNULL, timeout=30)
    changed = command(["git", "diff", "--name-only", "--no-renames", SOURCE, head]).splitlines()
    require(set(TESTS) <= set(changed) <= HARNESS | set(TESTS), "Unreviewed product or execution input changed")
    require(all(checksum(Path(path)) == digest for path, digest in TESTS.items()), "Test corrections differ from reviewed bytes")
    require(not command(["git", "status", "--porcelain", "--untracked-files=no"]), "Tracked checkout is dirty")
    return changed


def test_identity(value):
    prefix, separator, location = value.rpartition("/")
    if separator and location.split(":", 1)[0] in {Path(path).name for path in TESTS}:
        require(re.fullmatch(r"[A-Za-z]+Tests\.swift:[1-9][0-9]*:[1-9][0-9]*", location), "Invalid edited test location")
        return prefix + "/" + location.split(":", 1)[0]
    return value


def verify_original(root):
    require(checksum(root / "original.zip") == DIGEST, "Original archive differs from pinned failure")
    with zipfile.ZipFile(root / "original.zip") as archive:
        suite, proofs = verify_backends(archive, root, SOURCE)
        require(proofs[0]["testCaseExecutions"] == 47 and proofs[1]["events"]["functionExecutions"] == 896
                and len(proofs[1]["events"]["discoveredFunctionIDs"]) == 910
                and len(proofs[1]["events"]["skippedFunctionIDs"]) == 14,
                "Original successful backend counts differ")
        phase = suite["phases"][2]
        host = archive_json(archive, "hosted-suite/app-swift-testing/host-receipt.json")
        capture = archive_json(archive, "run.json")
        require(phase.get("exitCode") == 1 and host.get("abiSucceeded") is False
                and host.get("sourceSHA") == SOURCE and host.get("pid") == phase.get("pid")
                and host.get("parentPID") == capture.get("runLoopProbe", {}).get("swiftTestPID")
                and all(host.get(key) is True for key in ("mainThread", "applicationRunningAtStart", "started", "completed", "runReturnedAfterCompletion"))
                and host.get("error") is None and host.get("recordingError") is None
                and capture.get("sourceSHA") == SOURCE and capture.get("testExitCode") == 1
                and capture.get("effectiveExitCode") == 1 and capture.get("status") == "test-process-exited",
                "Original App did not return the recorded completed failure")
        raw = archive_bytes(archive, "hosted-suite/app-swift-testing/events.jsonl")
        records = [json.loads(line) for line in raw.splitlines()]
        require(records and all(record.get("version") == "6.4.0" for record in records), "Original event schema changed")
        failures = Counter()
        lifecycle = []
        for record in records:
            event = record.get("payload", {})
            if record.get("kind") == "event" and event.get("kind") == "issueRecorded":
                issue = event.get("issue", {})
                require(issue.get("isFailure") is True and issue.get("isKnown") is False
                        and issue.get("severity") == "error", "Unexpected original issue")
                failures[event.get("testID")] += 1
            else:
                lifecycle.append(record)
        require(failures == FAILURES and host.get("eventRecordCount") == len(records), "Original assertion failures differ")
        # The derived stream proves completion only; the original assertions remain failed.
        lifecycle_path = root / "original-app-lifecycle-only.jsonl"
        lifecycle_path.write_text("".join(json.dumps(record) + "\n" for record in lifecycle))
        events = swift_events(lifecycle_path, "NexGenVideoTests")
        require(events["functionExecutions"] == 3520
                and len(events["discoveredFunctionIDs"]) == 3528 and len(events["skippedFunctionIDs"]) == 8
                and set(events["discoveredFunctionIDs"]) == set(events["endedFunctionIDs"]) | set(events["skippedFunctionIDs"]),
                "Original App inventory did not finish")
        return {"backends": proofs, "completedAppInventory": inventory(raw),
                "originalAppStatus": "failed", "originalIssues": dict(failures),
                "lifecycleOnly": events}


def verify_binding(root, receipt):
    run, artifact = receipt["originalRun"], receipt["artifact"]
    job = verify_jobs(run, receipt["originalJobs"])
    require(run.get("id") == RUN and run.get("head_sha") == SOURCE and artifact.get("id") == ARTIFACT,
            "Wrong original producer or artifact")
    verify_artifact(artifact, run, job, ARTIFACT, DIGEST, f"render-review-test-diagnostic-{RUN}")
    require(checksum(root / "original-job.log") == LOG_DIGEST, "Original job log changed")
    log = (root / "original-job.log").read_text()
    require(toolchain(log) == receipt["toolchain"], "Original compiler identity changed")
    platforms = re.findall(r"OS Information: macOS ([0-9.]+) \(([^)]+)\)", log)
    require(platforms == [("27.0", "26A428")], "Original platform identity differs")
    require(verify_original(root) == receipt["proof"], "Original evidence changed")


def prepare(run_id, root):
    require(run_id == RUN, "Only the reviewed assertion-failure incident can resume")
    root.mkdir(parents=True, exist_ok=False)
    run = api(f"actions/runs/{RUN}")
    jobs = api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100")
    job = verify_jobs(run, jobs)
    require(run["head_sha"] == SOURCE, "Original source differs")
    head = os.environ["GITHUB_SHA"]
    changed = verify_sources(head)
    artifact = api(f"actions/artifacts/{ARTIFACT}")
    verify_artifact(artifact, run, job, ARTIFACT, DIGEST, f"render-review-test-diagnostic-{RUN}")
    download(artifact, root / "original.zip")
    with (root / "original-job.log").open("xb") as output:
        subprocess.run(["gh", "api", "--allow-escape-sequences",
                        f"repos/iret77/nexgenvideo/actions/jobs/{job['id']}/logs"],
                       stdin=subprocess.DEVNULL, stdout=output, check=True, timeout=120)
    proof = verify_original(root)
    receipt = {"schema": "core-app-assertion-resume/v1", "sourceSHA": head,
               "runID": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
               "originalSourceSHA": SOURCE, "originalRun": run, "originalJobs": jobs,
               "artifact": artifact, "changedPaths": changed, "proof": proof,
               "completedAppInventory": proof["completedAppInventory"],
               "toolchain": toolchain((root / "original-job.log").read_text())}
    verify_binding(root, receipt)
    write(root / "receipt.json", receipt)


def verify_local(root, platform=True):
    receipt = json.loads((root / "receipt.json").read_text())
    require(receipt.get("schema") == "core-app-assertion-resume/v1"
            and receipt.get("sourceSHA") == os.environ.get("GITHUB_SHA")
            and receipt.get("runID") == os.environ.get("GITHUB_RUN_ID")
            and receipt.get("attempt") == os.environ.get("GITHUB_RUN_ATTEMPT")
            and receipt.get("originalSourceSHA") == SOURCE, "Continuation belongs to another execution")
    require(verify_sources(receipt["sourceSHA"]) == receipt["changedPaths"], "Source binding changed")
    verify_binding(root, receipt)
    require(receipt["completedAppInventory"] == receipt["proof"]["completedAppInventory"], "App inventory changed")
    if platform:
        require(not any(diagnostic_key(key.encode()) for key in os.environ), "Normal continuation cannot enable diagnostics")
        actual = {"swift": swift_identity(command(["swift", "--version"])),
                  "xcode": command(["xcodebuild", "-version"])}
        require(actual == receipt["toolchain"] and command(["uname", "-m"]) == "arm64"
                and command(["sw_vers", "-productVersion"]) == "27.0"
                and command(["sw_vers", "-buildVersion"]) == "26A428", "Platform or compiler changed")
    return receipt


def finish(root, suite_root, capture_root):
    complete_verified_app(root, suite_root, capture_root, verify_local(root))


def complete_verified_app(root, suite_root, capture_root, receipt):
    records = [json.loads(line) for line in (suite_root / "app-swift-testing/events.jsonl").read_bytes().splitlines()]
    require(records and all(record.get("version") == "6.4.0" for record in records), "Current event schema differs from original")
    complete_app(root, suite_root, capture_root, receipt, identity=test_identity)
    completed = json.loads((root / "completed.json").read_text())
    completed.update(schema="core-app-assertion-completion/v1", originalAppStatus="failed",
                     continuationKind="pinned-app-assertion-correction", correctedTests=TESTS,
                     normalizedCoordinates=sorted(TESTS), originalArtifactID=ARTIFACT,
                     originalArtifactSHA256=DIGEST, originalIssues=receipt["proof"]["originalIssues"])
    write(root / "completed.json", completed)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("action", choices=("prepare", "verify", "finish"))
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--suite", type=Path)
    parser.add_argument("--capture", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        prepare(args.run_id, args.evidence)
    elif args.action == "verify":
        verify_local(args.evidence)
    else:
        require(args.suite and args.capture, "Current App and wrapper evidence are required")
        finish(args.evidence, args.suite, args.capture)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, VerificationError) as error:
        raise SystemExit("App assertion continuation failed: " + str(error))
