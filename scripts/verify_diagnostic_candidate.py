import argparse
import json
from pathlib import Path
import re
import subprocess


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
    parser.add_argument("--candidate-kind", choices=("signed-release", "ci-runtime"), default="signed-release")
    args = parser.parse_args()
    subprocess.run(["git", "merge-base", "--is-ancestor", args.source_sha, "HEAD"], check=True)
    paths = subprocess.check_output([
        "git", "diff", "--no-renames", "--name-only", "-z", args.source_sha, "HEAD"
    ]).decode().split("\0")
    verifier = verify_ci if args.candidate_kind == "ci-runtime" else verify
    verifier(*(json.loads((args.metadata / name).read_text()) for name in ("run.json", "jobs.json", "artifact.json")),
           args.run_id, args.source_sha, args.artifact_id, args.digest, [path for path in paths if path])
    harness_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    (args.metadata / "harness.json").write_text(json.dumps({
        "candidateKind": args.candidate_kind, "buildSourceSHA": args.source_sha,
        "harnessSourceSHA": harness_sha, "changedPaths": sorted(path for path in paths if path),
    }, indent=2) + "\n")
    print(f"{args.candidate_kind} candidate provenance verified; only acceptance tooling changed.")


if __name__ == "__main__":
    main()
