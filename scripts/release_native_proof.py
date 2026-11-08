import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact, write
from run_macos_tests import swift_events
from verify_swift_test_output import assess_output, ANSI


RUN = 41440677172
JOB = 125262180754
SOURCE = "9e8dd19ae54c398995391366e34b76d51e710709"
ARTIFACT = 13141549041
DIGEST = "898f086aefebc06b6d6603bc59f64e4442c6013639be79ad0a296f7e49d7cb36"
HARNESS_PATHS = {
    ".github/workflows/release.yml", "scripts/release_native_proof.py",
    "scripts/release_checkpoint.py", "scripts/test_release_recovery.py",
    "scripts/release_signing_environment.sh",
    "scripts/bundle.sh", "scripts/notarize.sh", "scripts/test_notarize.py",
    "scripts/test_release_workflow.py", "docs/CI_EFFICIENCY.md",
    "scripts/test_native_test_python_workflow.py",
    "scripts/dmg-settings.py", "scripts/verify_dmg_copy.py", "scripts/release_dmg_probe.py",
    "scripts/test_release_dmg_packaging.py", ".github/workflows/signing-preflight.yml",
    "scripts/plan_dmg_capacity.py",
}


def command(*args):
    return subprocess.check_output(args, stdin=subprocess.DEVNULL, text=True, timeout=40).strip()


def workflow_observations(text):
    steps = text.split("\n      - ")
    result = {}
    for name in ("Reject open release blockers", "Inspect or resume release publication"):
        matches = [step for step in steps if step.startswith("name: " + name + "\n")]
        require(len(matches) == 1, "Publication fixture step is missing or duplicated")
        result[name] = [line.strip() for line in matches[0].splitlines()
                        if line.startswith("        if: ")]
    for value in ("gh label list", "--repo iret77/nexgenvideo", "gh label view",
                  "scripts/publish_release_metadata.sh", "python3 scripts/update_appcast.py"):
        result[value] = value in text
    return result


def verify_sources(head):
    require(re.fullmatch(r"[a-f0-9]{40}", head) is not None, "Invalid current source")
    require(command("git", "rev-parse", "HEAD") == head, "Current checkout differs")
    subprocess.run(["git", "merge-base", "--is-ancestor", SOURCE, head],
                   stdin=subprocess.DEVNULL, check=True, timeout=30)
    changed = command("git", "diff", "--name-only", "--no-renames", SOURCE, head).splitlines()
    require(set(changed) <= HARNESS_PATHS, "Native code, test, dependency or runtime input changed")
    require(not command("git", "status", "--porcelain", "--untracked-files=no"), "Tracked source is dirty")
    before = command("git", "show", SOURCE + ":.github/workflows/release.yml")
    after = Path(".github/workflows/release.yml").read_text()
    require(workflow_observations(before) == workflow_observations(after),
            "Native publication tests observe different workflow inputs")
    return changed


def verify_original(run, jobs):
    require(run.get("id") == RUN and run.get("head_sha") == SOURCE
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("path") == ".github/workflows/release.yml"
            and run.get("actor", {}).get("login") == "iret77"
            and run.get("event") == "workflow_dispatch" and run.get("run_attempt") == 1
            and run.get("status") == "completed" and run.get("conclusion") == "cancelled",
            "Original Release execution differs")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete original jobs")
    matches = [job for job in jobs["jobs"] if job.get("id") == JOB and job.get("name") == "release"]
    require(len(matches) == 1, "Original Release job is missing")
    job = matches[0]
    require(job.get("run_id") == RUN and job.get("run_attempt") == 1
            and job.get("head_sha") == SOURCE and job.get("labels") == ["macrunner"]
            and job.get("status") == "completed" and job.get("conclusion") == "cancelled",
            "Original Release job identity differs")
    for name in ("Build the exact release test configuration", "Stage release test runtime inputs",
                 "Test the exact release configuration", "Upload release test evidence",
                 "Verify release build did not mutate tracked source",
                 "Verify release tests did not mutate tracked source"):
        steps = [step for step in job.get("steps", []) if step.get("name") == name]
        require(len(steps) == 1 and steps[0].get("conclusion") == "success",
                "Original Release test stage did not pass: " + name)
    failures = [step["name"] for step in job["steps"] if step.get("conclusion") in ("failure", "cancelled")]
    require(failures == ["Notarize app and build signed, notarized DMG"],
            "Original Release failed outside notarization")
    return job


def verify_suite(archive, root):
    names = [name for name in archive.namelist() if name.rsplit("/", 1)[-1] == "suite.json"]
    require(len(names) == 1, "Original suite is ambiguous")
    prefix = names[0][:-len("suite.json")]
    suite = json.loads(archive_bytes(archive, names[0]))
    require(suite.get("schema") == 1 and suite.get("sourceSHA") == SOURCE
            and suite.get("configuration") == "release" and suite.get("scope") == "all"
            and suite.get("filter") == "" and suite.get("completed") is True
            and isinstance(suite.get("scratchPath"), str) and suite["scratchPath"].endswith("/release-tests")
            and suite.get("testExecutions") == 4607
            and not any(key in suite for key in ("productSourceSHA", "harnessSourceSHA", "retainedBackends")),
            "Original full Release suite differs")
    phases = suite.get("phases", [])
    require([phase.get("name") for phase in phases] ==
            ["xctest", "engine-swift-testing", "app-swift-testing"], "Incomplete original backends")
    proofs = []
    for phase, executions, skips in zip(phases, (48, 896, 3663), (0, 14, 8)):
        capture = phase.get("outputCapture", {})
        require(phase.get("status") == "verified-execution" and phase.get("exitCode") == 0
                and capture.get("originalExitCode") == 0 and capture.get("eof") is True
                and not any(value.startswith("--filter") for value in phase.get("command", [])),
                "Original backend is failed, filtered or incomplete")
        folder = root / phase["name"]
        folder.mkdir()
        log = folder / "console.log"
        log.write_bytes(archive_bytes(archive, prefix + phase["name"] + "/console.log"))
        swift = phase["name"] != "xctest"
        framework = assess_output(log, swift_testing_runs=int(swift), xctest_runs=0 if swift else 2)
        require(framework["passed"] and framework == phase.get("framework"), "Original framework result differs")
        if swift:
            events = folder / "events.jsonl"
            events.write_bytes(archive_bytes(archive, prefix + phase["name"] + "/events.jsonl"))
            parsed = swift_events(events, "NexGenEngineTests" if executions == 896 else "NexGenVideoTests")
            require(parsed == phase.get("events") and parsed["functionExecutions"] == executions
                    and len(parsed["skippedFunctionIDs"]) == skips
                    and set(parsed["discoveredFunctionIDs"]) ==
                    set(parsed["endedFunctionIDs"]) | set(parsed["skippedFunctionIDs"]),
                    "Original native inventory differs")
        else:
            passed = re.findall(r"Test Case '([^']+)' passed", log.read_text())
            require(len(passed) == len(set(passed)) == phase.get("testCaseExecutions") == executions,
                    "Original XCTest inventory differs")
        proofs.append({"name": phase["name"], "executions": executions, "skips": skips,
                       "logSHA256": checksum(log)})
    host = json.loads(archive_bytes(archive, prefix + "app-swift-testing/host-receipt.json"))
    require(host == phases[2].get("originalHostReceipt") and host.get("sourceSHA") == SOURCE
            and host.get("pid") == phases[2].get("pid") and host.get("recordingError") is None
            and host.get("error") is None and all(host.get(key) is True for key in
                ("mainThread", "applicationRunningAtStart", "started", "completed",
                 "abiSucceeded", "runReturnedAfterCompletion")), "Original App ABI execution differs")
    watchdogs = []
    for name in archive.namelist():
        if name.startswith(prefix + "app-swift-testing/watchdog/") and name.endswith(".json"):
            report = json.loads(archive_bytes(archive, name))
            if report.get("processID") == host["pid"] and isinstance(report.get("operatingSystem"), str):
                watchdogs.append(report["operatingSystem"])
    require(len(set(watchdogs)) == 1, "Original owned OS evidence is missing")
    require(suite.get("combinedFrameworks", {}).get("passed") is True, "Original aggregate did not pass")
    return {"backends": proofs, "executions": 4607, "skips": 22, "os": watchdogs[0]}


def prepare(run_id, root):
    from release_test_repair import RUN as REPAIR_RUN, prepare as prepare_repair
    if run_id == REPAIR_RUN:
        return prepare_repair(root, run_id)
    require(run_id == RUN and os.environ["GITHUB_REPOSITORY"] == "iret77/nexgenvideo",
            "Only the pinned completed Release suite can resume")
    head = os.environ["GITHUB_SHA"]
    changed = verify_sources(head)
    root.mkdir(parents=True, exist_ok=False)
    run = api(f"actions/runs/{RUN}")
    jobs = api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100")
    job = verify_original(run, jobs)
    artifact = api(f"actions/artifacts/{ARTIFACT}")
    verify_artifact(artifact, run, job, ARTIFACT, DIGEST, "release-test-evidence")
    download(artifact, root / "original.zip")
    require(checksum(root / "original.zip") == DIGEST, "Original Release archive changed")
    with zipfile.ZipFile(root / "original.zip") as archive:
        proof = verify_suite(archive, root)
    from verified_pr_source_checks import read_api
    raw = read_api(f"actions/jobs/{JOB}/logs", 4_000_000)
    (root / "original-job.log").write_bytes(raw)
    text = ANSI.sub("", raw.decode())
    xcode = re.findall(r"Xcode Versions: ([0-9.]+) \(([^)]+)\) \[Apple Silicon\] \(Selected\)", text)
    require(len(xcode) == 1, "Original Xcode identity is ambiguous")
    proof["xcode"] = "Xcode " + xcode[0][0] + "\nBuild version " + xcode[0][1]
    python = re.findall(r"Successfully set up CPython \(([^)]+)\)", text)
    require(len(python) == 1, "Original Python identity is ambiguous")
    proof["python"] = python[0]
    receipt = {"schema": "release-native-reuse/v1", "sourceSHA": head,
               "originalSourceSHA": SOURCE, "originalRun": run, "originalJob": job,
               "artifact": artifact, "artifactSHA256": DIGEST, "changedPaths": changed,
               "proof": proof, "originalLogSHA256": checksum(root / "original-job.log")}
    write(root / "receipt.json", receipt)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("verified=true\n")


def environment(root):
    receipt = json.loads((root / "receipt.json").read_text())
    require(receipt.get("schema") == "release-native-reuse/v1"
            and receipt.get("sourceSHA") == os.environ["GITHUB_SHA"]
            and receipt.get("artifactSHA256") == DIGEST
            and checksum(root / "original.zip") == DIGEST, "Release test binding differs")
    current = {"os": "Version " + command("sw_vers", "-productVersion")
               + " (Build " + command("sw_vers", "-buildVersion") + ")",
               "xcode": command("xcodebuild", "-version"), "architecture": platform.machine(),
               "python": platform.python_version()}
    require(current["architecture"] == "arm64" and
            all(current[key] == receipt["proof"][key] for key in ("os", "xcode", "python")),
            "Original Release test OS, Xcode or Python differs")
    write(root / "current-environment.json", current)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("operation", choices=("prepare", "environment"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--run-id", type=int)
    args = parser.parse_args()
    if args.operation == "prepare":
        prepare(args.run_id, args.root)
    else:
        environment(args.root)
