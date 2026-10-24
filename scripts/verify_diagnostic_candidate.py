import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile


HARNESS_PATHS = {
    ".github/workflows/diagnostic-acceptance.yml",
    "scripts/hang_diagnostic_acceptance.py",
    "scripts/verify_diagnostic_candidate.py",
    "scripts/test_diagnostic_acceptance.py",
}
CI_HARNESS_PATHS = HARNESS_PATHS | {
    ".github/workflows/ci.yml",
    ".github/workflows/bpy-runtime-acceptance.yml",
    "scripts/verify_bpy_bundle.sh",
    "scripts/verify_macho_dependencies.py",
    "scripts/test_verify_macho_dependencies.py",
}

BPY_DIAGNOSTIC_PATHS = {
    ".github/workflows/diagnostic-acceptance.yml",
    "scripts/verify_diagnostic_candidate.py",
    "scripts/test_diagnostic_acceptance.py",
    "scripts/bpy_open_diagnostic.py",
    "scripts/test_bpy_open_diagnostic.py",
}

APP_DIAGNOSTIC_PATHS = {
    ".github/workflows/diagnostic-acceptance.yml",
    "scripts/verify_diagnostic_candidate.py",
    "scripts/test_diagnostic_acceptance.py",
    "scripts/run_macos_tests.py",
    "scripts/test_run_macos_tests.py",
    "scripts/app_host_zombie_diagnostic.py",
    "scripts/test_app_host_zombie_diagnostic.py",
    "scripts/capture_render_review_test_diagnostic.py",
    "scripts/test_swift_test_failure_propagation.py",
}


def verify_app_diagnostic(run, jobs, artifact, run_id, source_sha, artifact_id, digest, changed_paths):
    if (not re.fullmatch(r"[0-9a-f]{40}", source_sha)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or run.get("id") != run_id or run.get("head_sha") != source_sha
            or run.get("path") != ".github/workflows/ci-batch.yml"
            or run.get("event") != "workflow_dispatch" or run.get("status") != "completed"
            or run.get("conclusion") != "failure"
            or run.get("repository", {}).get("full_name") != "iret77/nexgenvideo"
            or type(run.get("run_attempt")) is not int or run["run_attempt"] < 1):
        raise ValueError("candidate must be a completed failed CI batch")
    if jobs.get("total_count") != len(jobs.get("jobs", [])):
        raise ValueError("incomplete candidate job inventory")
    prefix = "Compile, unit tests, app and native bpy acceptance / "

    def job(name, conclusion):
        found = [item for item in jobs["jobs"] if item.get("name") == prefix + name]
        if (len(found) != 1 or found[0].get("status") != "completed"
                or found[0].get("conclusion") != conclusion
                or found[0].get("run_id") != run_id or found[0].get("head_sha") != source_sha
                or found[0].get("run_attempt") != run["run_attempt"]):
            raise ValueError("unexpected candidate job identity or result: " + name)
        return found[0]

    for name in ("Light Checks", "Agent UI Evidence", "bpy-source / source"):
        job(name, "success")
    producer = job("Build & Test", "failure")
    steps = producer.get("steps", [])
    for name, conclusion in (("Build", "success"), ("Verify build did not mutate tracked source", "success"),
                             ("Stage test runtime inputs", "success"), ("Test", "failure"),
                             ("Upload render review test diagnosis", "success"),
                             ("Upload .app artifact", "skipped")):
        found = [step for step in steps if step.get("name") == name]
        if (len(found) != 1 or found[0].get("status") != "completed"
                or found[0].get("conclusion") != conclusion):
            raise ValueError("candidate failure is not isolated to native tests")
    if [step.get("name") for step in steps if step.get("conclusion") == "failure"] != ["Test"]:
        raise ValueError("additional producer step failure")
    if (artifact.get("id") != artifact_id
            or artifact.get("name") != f"render-review-test-diagnostic-{run_id}"
            or artifact.get("expired") is not False or artifact.get("digest") != "sha256:" + digest
            or artifact.get("workflow_run", {}).get("id") != run_id
            or artifact.get("workflow_run", {}).get("head_sha") != source_sha):
        raise ValueError("candidate diagnostic artifact provenance mismatch")
    try:
        instant = lambda value: datetime.fromisoformat(value.replace("Z", "+00:00"))
        if not (instant(producer["started_at"]) <= instant(artifact["created_at"])
                <= instant(artifact["updated_at"]) <= instant(producer["completed_at"])
                and instant(artifact["expires_at"]) > datetime.now(timezone.utc)):
            raise ValueError("diagnostic artifact is not bound to the producer attempt")
    except (KeyError, TypeError) as error:
        raise ValueError("missing diagnostic production timestamps") from error
    if set(changed_paths) - APP_DIAGNOSTIC_PATHS:
        raise ValueError("only the exact App diagnostic harness allowlist may change")


def verify_app_crash_archive(path, run_id, source_sha, digest):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    if checksum.hexdigest() != digest:
        raise ValueError("original diagnostic archive digest mismatch")
    with zipfile.ZipFile(path) as archive:
        def read(name):
            entries = [entry for entry in archive.infolist() if entry.filename == name]
            if len(entries) != 1 or entries[0].file_size > 4 * 1024 * 1024:
                raise ValueError("missing, duplicated or oversized original diagnostic record")
            return json.loads(archive.read(entries[0]))

        original = read("run.json")
        suite = read("hosted-suite/suite.json")
        phases = suite.get("phases", [])
        if (original.get("runID") != str(run_id) or original.get("sourceSHA") != source_sha
                or original.get("testExitCode") != 139 or original.get("effectiveExitCode") != 139
                or suite.get("sourceSHA") != source_sha or suite.get("completed") is not False
                or suite.get("scope") != "all" or suite.get("filter") != ""
                or [phase.get("name") for phase in phases] != ["xctest", "engine-swift-testing", "app-swift-testing"]
                or any(phase.get("exitCode") != 0 or phase.get("status") != "verified-execution"
                       or phase.get("framework", {}).get("passed") is not True for phase in phases[:2])
                or phases[-1].get("exitCode") != -11 or phases[-1].get("status") != "failed"):
            raise ValueError("original archive does not prove the isolated App SIGSEGV")
        receipt = read("hosted-suite/app-swift-testing/post-mortem/receipt.json")
        if (receipt.get("status") != "bound-report-captured" or receipt.get("originalExitCode") != -11
                or receipt.get("ownedChild", {}).get("pid") != phases[-1].get("pid")
                or not receipt.get("reports")):
            raise ValueError("original App crash has no owned report binding")


def verify_bpy_diagnostic(run, jobs, artifact, run_id, source_sha, artifact_id, digest, changed_paths):
    if (not re.fullmatch(r"[0-9a-f]{40}", source_sha)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or run.get("id") != run_id or run.get("head_sha") != source_sha
            or run.get("path") != ".github/workflows/ci-batch.yml"
            or run.get("event") != "workflow_dispatch" or run.get("status") != "completed"
            or run.get("conclusion") != "failure"
            or run.get("repository", {}).get("full_name") != "iret77/nexgenvideo"
            or type(run.get("run_attempt")) is not int or run["run_attempt"] < 1):
        raise ValueError("candidate must be a completed failed CI batch")
    if jobs.get("total_count") != len(jobs.get("jobs", [])):
        raise ValueError("incomplete candidate job inventory")
    prefix = "Compile, unit tests, app and native bpy acceptance / "

    def job(name, conclusion):
        found = [item for item in jobs["jobs"] if item.get("name") == prefix + name]
        if (len(found) != 1 or found[0].get("status") != "completed"
                or found[0].get("conclusion") != conclusion
                or found[0].get("run_id") != run_id or found[0].get("head_sha") != source_sha
                or found[0].get("run_attempt") != run["run_attempt"]):
            raise ValueError("unexpected candidate job identity or result: " + name)
        return found[0]

    for name in ("Light Checks", "Agent UI Evidence", "bpy-source / source", "diagnostic-startup"):
        job(name, "success")
    producer = job("Build & Test", "success")
    failed = job("bpy-runtime / runtime", "failure")
    expected = {
        "Relocate the exact app and prepare denied resources": "success",
        "Prove pre-lease and post-exec host-crash cleanup": "failure",
        "Prepare the independent retained Bible YAML parser": "skipped",
        "Run real bpy acceptance without ambient Blender or Python": "skipped",
    }
    steps = failed.get("steps", [])
    for name, conclusion in expected.items():
        found = [step for step in steps if step.get("name") == name]
        if (len(found) != 1 or found[0].get("status") != "completed"
                or found[0].get("conclusion") != conclusion):
            raise ValueError("unexpected bpy failure stage")
    if [step.get("name") for step in steps if step.get("conclusion") == "failure"] != [
            "Prove pre-lease and post-exec host-crash cleanup"]:
        raise ValueError("additional bpy step failure")
    if (artifact.get("id") != artifact_id or artifact.get("name") != "NexGenVideo-app"
            or artifact.get("expired") is not False or artifact.get("digest") != "sha256:" + digest
            or artifact.get("workflow_run", {}).get("id") != run_id
            or artifact.get("workflow_run", {}).get("head_sha") != source_sha):
        raise ValueError("candidate artifact provenance mismatch")
    try:
        instant = lambda value: datetime.fromisoformat(value.replace("Z", "+00:00"))
        if not (instant(producer["started_at"]) <= instant(artifact["created_at"])
                <= instant(artifact["updated_at"]) <= instant(producer["completed_at"])
                and instant(artifact["expires_at"]) > datetime.now(timezone.utc)):
            raise ValueError("artifact is not bound to the successful producer attempt")
    except (KeyError, TypeError) as error:
        raise ValueError("missing artifact production timestamps") from error
    if set(changed_paths) - BPY_DIAGNOSTIC_PATHS:
        raise ValueError("only the exact bpy diagnostic harness allowlist may change")


def verify_ci(run, jobs, artifact, run_id, source_sha, artifact_id, digest, changed_paths):
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("invalid candidate identity")
    if (run.get("id") != run_id or run.get("head_sha") != source_sha
            or run.get("path") != ".github/workflows/ci-batch.yml"
            or run.get("event") != "workflow_dispatch" or run.get("status") != "completed"
            or run.get("repository", {}).get("full_name") != "iret77/nexgenvideo"
            or type(run.get("run_attempt")) is not int or run["run_attempt"] != 1):
        raise ValueError("candidate must be a completed CI batch")
    if jobs.get("total_count") != len(jobs.get("jobs", [])):
        raise ValueError("incomplete candidate job inventory")
    prefix = "Compile, unit tests, app and native bpy acceptance / "

    def require_job(name, conclusion):
        matches = [job for job in jobs["jobs"] if job.get("name") == prefix + name]
        if (len(matches) != 1 or matches[0].get("conclusion") != conclusion
                or matches[0].get("status") != "completed"):
            raise ValueError(f"candidate job has an unexpected result: {name}")
        job = matches[0]
        if (job.get("run_id") != run_id or job.get("head_sha") != source_sha
                or job.get("run_attempt") != run["run_attempt"]):
            raise ValueError("candidate job has a different execution identity")
        return job

    for name in ("Light Checks", "Build & Test", "bpy-source / source", "Agent UI Evidence"):
        require_job(name, "success")
    steps = require_job("diagnostic-startup", "failure").get("steps", [])
    names = [step.get("name") for step in steps]
    required = ["Prove shipped build 97 misses normal recorder startup",
                "Verify normal startup and disabled preference",
                "Exercise native Export Cancel, Retry and Reveal actions",
                "Verify generation batch pricing recovery on macOS 26",
                "Verify helper recovery during active work"]
    if any(names.count(name) != 1 for name in required):
        raise ValueError("candidate diagnostic steps are missing or duplicated")
    indices = [names.index(name) for name in required]
    helper = steps[indices[-1]]
    if (indices != sorted(indices) or helper.get("conclusion") != "failure"
            or helper.get("status") != "completed"
            or any(step.get("conclusion") != "success" or step.get("status") != "completed"
                   for step in steps[:indices[-1]])):
        raise ValueError("candidate diagnostic failure is not isolated to helper recovery")
    if (artifact.get("id") != artifact_id or artifact.get("name") != "NexGenVideo-app"
            or artifact.get("expired") is not False or artifact.get("digest") != f"sha256:{digest}"
            or artifact.get("workflow_run", {}).get("id") != run_id
            or artifact.get("workflow_run", {}).get("head_sha") != source_sha):
        raise ValueError("candidate artifact provenance mismatch")
    if set(changed_paths) - CI_HARNESS_PATHS:
        raise ValueError("application or build inputs changed; retained CI app cannot be used")


def verify(run, jobs, artifact, run_id, source_sha, artifact_id, digest, changed_paths):
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("invalid candidate identity")
    if (run["id"] != run_id or run["head_sha"] != source_sha
            or run["path"] != ".github/workflows/release.yml"
            or run["event"] != "workflow_dispatch" or run["head_branch"] != "main"
            or run["status"] != "completed"
            or run["repository"]["full_name"] != "iret77/nexgenvideo"):
        raise ValueError("candidate must be a completed main-branch release build")
    releases = [job for job in jobs["jobs"] if job["name"] == "release"]
    if jobs["total_count"] != len(jobs["jobs"]) or len(releases) != 1 or releases[0]["conclusion"] != "success":
        raise ValueError("candidate release job did not succeed")
    if (artifact["id"] != artifact_id or artifact["name"] != "diagnostic-release-evidence"
            or artifact["expired"] or artifact["digest"] != f"sha256:{digest}"
            or artifact["workflow_run"]["id"] != run_id
            or artifact["workflow_run"]["head_sha"] != source_sha):
        raise ValueError("candidate artifact provenance mismatch")
    if set(changed_paths) - HARNESS_PATHS:
        raise ValueError("application or build inputs changed; a new signed build is required")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id", type=int)
    parser.add_argument("source_sha")
    parser.add_argument("artifact_id", type=int)
    parser.add_argument("digest")
    parser.add_argument("metadata", type=Path)
    parser.add_argument("--candidate-kind", choices=("signed-release", "ci-runtime", "ci-bpy-open-diagnostic", "ci-app-test-diagnostic"), default="signed-release")
    parser.add_argument("--crash-archive", type=Path)
    args = parser.parse_args()
    if (args.candidate_kind == "ci-app-test-diagnostic") != (args.crash_archive is not None):
        parser.error("only the App diagnostic requires its original crash archive")
    subprocess.run(["git", "merge-base", "--is-ancestor", args.source_sha, "HEAD"], check=True)
    paths = subprocess.check_output([
        "git", "diff", "--no-renames", "--name-only", "-z", args.source_sha, "HEAD"
    ]).decode().split("\0")
    verifier = {"signed-release": verify, "ci-runtime": verify_ci,
                "ci-bpy-open-diagnostic": verify_bpy_diagnostic,
                "ci-app-test-diagnostic": verify_app_diagnostic}[args.candidate_kind]
    verifier(*(json.loads((args.metadata / name).read_text()) for name in ("run.json", "jobs.json", "artifact.json")),
           args.run_id, args.source_sha, args.artifact_id, args.digest, [path for path in paths if path])
    if args.crash_archive is not None:
        verify_app_crash_archive(args.crash_archive, args.run_id, args.source_sha, args.digest)
    harness_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    (args.metadata / "harness.json").write_text(json.dumps({
        "candidateKind": args.candidate_kind, "buildSourceSHA": args.source_sha,
        "harnessSourceSHA": harness_sha, "changedPaths": sorted(path for path in paths if path),
    }, indent=2) + "\n")
    print(f"{args.candidate_kind} candidate provenance verified; only acceptance tooling changed.")


if __name__ == "__main__":
    main()
