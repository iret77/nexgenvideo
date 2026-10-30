import argparse
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request
import zipfile

from verify_swift_test_output import ANSI


REPOSITORY = "iret77/nexgenvideo"
CHECKS = ("Enforce AppTheme", "Validate pack pipeline contracts", "Verify CI and fixture tooling")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    return subprocess.check_output(["git", *args], text=True, timeout=30).strip()


def write(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(newurl.startswith("https://"), "Evidence redirect must use HTTPS")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def read_api(path, maximum=4_000_000):
    request = urllib.request.Request("https://api.github.com/repos/" + REPOSITORY + "/" + path,
        headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    request.add_unredirected_header("Authorization", "Bearer " + os.environ["GH_TOKEN"])
    try:
        with urllib.request.build_opener(HTTPSRedirect()).open(request, timeout=45) as response:
            data = response.read(maximum + 1)
    except (OSError, urllib.error.URLError, http.client.HTTPException):
        raise ValueError("GitHub source evidence download failed") from None
    require(len(data) <= maximum, "GitHub source evidence exceeds its size bound")
    return data


def api(path):
    return json.loads(read_api(path))


def check_results(value):
    require(type(value) is dict and set(value) == set(CHECKS), "Incomplete recorded source checks")
    for name in CHECKS:
        result = value[name]
        require(type(result) is dict and set(result) == {"outcome", "conclusion"}
                and result["outcome"] == result["conclusion"] == "success",
                "Recorded source check did not pass: " + name)
    return value


def record(root):
    require(os.environ["GITHUB_EVENT_NAME"] == "pull_request", "Only PR jobs publish original source proof")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    pr = event["pull_request"]
    checkout = git("rev-parse", "HEAD")
    require(checkout == os.environ["GITHUB_SHA"], "PR checkout differs from workflow source")
    require(not git("status", "--porcelain", "--untracked-files=no"), "PR source changed during checks")
    results = check_results(json.loads(os.environ.get("NGV_SOURCE_CHECK_RESULTS", "null")))
    root.mkdir(parents=True, exist_ok=False)
    write(root / "receipt.json", {"schema": "verified-pr-source/v2", "repository": os.environ["GITHUB_REPOSITORY"],
        "runID": int(os.environ["GITHUB_RUN_ID"]), "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "pullRequest": event["number"], "headSHA": pr["head"]["sha"],
        "headRepository": pr["head"]["repo"]["full_name"], "baseRef": pr["base"]["ref"],
        "checkoutSHA": checkout, "treeSHA": git("rev-parse", "HEAD^{tree}"), "checkResults": results})


def verify_run_identity(run, jobs, run_id):
    require(run.get("id") == run_id and run.get("repository", {}).get("full_name") == REPOSITORY
            and run.get("event") == "pull_request" and run.get("path") == ".github/workflows/pr-checks.yml"
            and run.get("run_attempt") == 1 and run.get("status") == "completed"
            and run.get("conclusion") == "success" and run.get("actor", {}).get("login") == "iret77",
            "Original PR run is not a successful owned source check")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete original job inventory")
    selected = [job for job in jobs["jobs"] if job.get("name") == "Light Checks"]
    require(len(selected) == 1, "Missing or duplicate original Light Checks job")
    job = selected[0]
    require(job.get("run_id") == run_id and job.get("run_attempt") == 1
            and job.get("head_sha") == run["head_sha"] and job.get("status") == "completed"
            and job.get("conclusion") == "success", "Original PR job identity differs")
    return job


def verify_steps(job, receipt=None):
    if receipt is not None and receipt.get("schema") == "verified-pr-source/v2":
        check_results(receipt.get("checkResults"))
        require(type(job.get("steps")) is list, "Original source step inventory is missing")
        if not job["steps"]:
            return "recorded-job-context/v2"
    for name in (*CHECKS, "Record verified source checkout", "Upload verified source checkout"):
        steps = [step for step in job.get("steps", []) if step.get("name") == name]
        require(len(steps) == 1 and steps[0].get("status") == "completed"
                and steps[0].get("conclusion") == "success", "Original source step did not pass: " + name)
    return "rest-job-steps"


def original_receipt(artifact, raw, run):
    require(artifact.get("name") == f"verified-pr-source-{run['id']}-a1" and not artifact.get("expired", True)
            and artifact.get("workflow_run", {}).get("id") == run["id"]
            and artifact.get("workflow_run", {}).get("head_sha") == run["head_sha"]
            and artifact.get("size_in_bytes") == len(raw) and len(raw) <= 100_000
            and artifact.get("digest") == "sha256:" + digest(raw), "Original PR artifact differs")
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        require(archive.namelist() == ["receipt.json"] and archive.getinfo("receipt.json").file_size <= 20_000,
                "Original PR artifact contains unexpected entries")
        receipt = json.loads(archive.read("receipt.json"))
    require(receipt.get("schema") in ("verified-pr-source/v1", "verified-pr-source/v2") and receipt.get("repository") == REPOSITORY
            and receipt.get("headRepository") == REPOSITORY and receipt.get("runID") == run["id"]
            and receipt.get("attempt") == 1 and receipt.get("headSHA") == run["head_sha"],
            "Original PR receipt identity differs")
    require(type(receipt.get("pullRequest")) is int and receipt["pullRequest"] > 0
            and all(isinstance(receipt.get(key), str) and re.fullmatch(r"[a-f0-9]{40}", receipt[key])
                    for key in ("checkoutSHA", "treeSHA", "headSHA")), "Invalid original source identifiers")
    if receipt["schema"] == "verified-pr-source/v2":
        check_results(receipt.get("checkResults"))
    return receipt


def verify_tree(receipt, pr, commit, head, tree, ref):
    require(pr.get("number") == receipt["pullRequest"] and pr.get("merged") is True
            and pr.get("merge_commit_sha") == head and pr.get("head", {}).get("sha") == receipt["headSHA"]
            and pr.get("head", {}).get("repo", {}).get("full_name") == REPOSITORY
            and pr.get("base", {}).get("repo", {}).get("full_name") == REPOSITORY
            and pr.get("base", {}).get("ref") == receipt["baseRef"] == ref,
            "Current Core is not the exact original PR merge")
    require(commit.get("sha") == receipt["checkoutSHA"] and commit.get("tree", {}).get("sha") == receipt["treeSHA"] == tree,
            "The PR did not test the exact current source tree")


def test_completion(raw):
    text = raw.decode("utf-8-sig")
    lines = [re.sub(r"^\d{4}-\d\d-\d\dT[^ ]+ ", "", ANSI.sub("", line)) for line in text.splitlines()]
    summaries = [re.fullmatch(r"Ran (\d+) tests in [0-9.]+s", line) for line in lines]
    counts = [int(item[1]) for item in summaries if item]
    finals = [line for line in lines if re.match(r"^(OK(?: \(skipped=\d+\))?|FAILED.*)$", line)]
    require(len(counts) == 1 and counts[0] > 0 and len(finals) == 1
            and re.fullmatch(r"OK(?: \(skipped=\d+\))?", finals[0])
            and not any(line.startswith(("FAIL:", "ERROR:")) for line in lines), "Original PR test completion differs")
    require("python3 -m unittest discover -s scripts -p 'test_*.py' -v" in text,
            "Original PR did not run the complete tooling suite")
    skipped = re.search(r"skipped=(\d+)", finals[0])
    require(not skipped or int(skipped[1]) < counts[0], "Original PR did not execute a test")
    return {"tests": counts[0], "summary": finals[0]}


def prepare(run_id, root):
    require(run_id > 0 and os.environ["GITHUB_REPOSITORY"] == REPOSITORY, "Invalid original run or repository")
    head = os.environ["GITHUB_SHA"]
    require(git("rev-parse", "HEAD") == head and not git("status", "--porcelain", "--untracked-files=no"),
            "Core source checkout differs")
    root.mkdir(parents=True, exist_ok=False)
    run = api(f"actions/runs/{run_id}")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    job = verify_run_identity(run, jobs, run_id)
    artifacts = api(f"actions/runs/{run_id}/artifacts?per_page=100")
    require(artifacts.get("total_count") == len(artifacts.get("artifacts", [])), "Incomplete PR artifact inventory")
    selected = [item for item in artifacts["artifacts"] if item.get("name") == f"verified-pr-source-{run_id}-a1"]
    require(len(selected) == 1, "Missing or duplicate source proof artifact")
    artifact = api(f"actions/artifacts/{selected[0]['id']}")
    require(artifact.get("id") == selected[0]["id"], "Original artifact lookup differs")
    raw = read_api(f"actions/artifacts/{artifact['id']}/zip", 100_000)
    receipt = original_receipt(artifact, raw, run)
    step_proof = verify_steps(job, receipt)
    pr = api(f"pulls/{receipt['pullRequest']}")
    commit = api(f"git/commits/{receipt['checkoutSHA']}")
    verify_tree(receipt, pr, commit, head, git("rev-parse", "HEAD^{tree}"), os.environ["GITHUB_REF_NAME"])
    log = read_api(f"actions/jobs/{job['id']}/logs")
    result = test_completion(log)
    (root / "original-proof.zip").write_bytes(raw)
    (root / "original-job.log").write_bytes(log)
    write(root / "receipt.json", {"schema": "core-pr-source-composition/v1", "sourceSHA": head,
        "runID": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "originalRun": run, "originalJobs": jobs, "originalArtifact": artifact, "originalReceipt": receipt,
        "originalCheckoutCommit": commit, "originalPR": pr, "originalResult": result,
        "originalLogSHA256": digest(log), "reusedSteps": list(CHECKS), "originalStepProof": step_proof})
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("verified=true\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("action", choices=("record", "prepare"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-id", type=int)
    args = parser.parse_args()
    if args.action == "record":
        record(args.output)
    else:
        require(args.run_id is not None, "Original PR run ID is required")
        prepare(args.run_id, args.output)
