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
    args = parser.parse_args()
    subprocess.run(["git", "merge-base", "--is-ancestor", args.source_sha, "HEAD"], check=True)
    paths = subprocess.check_output([
        "git", "diff", "--no-renames", "--name-only", "-z", args.source_sha, "HEAD"
    ]).decode().split("\0")
    verify(*(json.loads((args.metadata / name).read_text()) for name in ("run.json", "jobs.json", "artifact.json")),
           args.run_id, args.source_sha, args.artifact_id, args.digest, [path for path in paths if path])
    print("Signed candidate provenance verified; only acceptance tooling changed.")


if __name__ == "__main__":
    main()
