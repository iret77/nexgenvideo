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

from run_bpy_owned_child_probe import cases_complete


RUN = 40357018456
SOURCE = "2d65040785079e6fc9e979f5abc652a652c0bf68"
ARTIFACT = 12667180578
ARCHIVE = "9c9f55ed5ef5e56c6d4c64cb74ae04e057423feaa011085e19a18a2e887b02da"
BINARY = "1028895799eaf9c6acfdc3ddaba4f69214306ab855c1e8572f6ccd61b8da2f4a"
ALLOWED = {".github/workflows/native-acceptance-probes.yml", "scripts/run_bpy_owned_child_probe.py",
           "scripts/resume_bpy_owned_child_probe.py", "scripts/test_bpy_owned_child_probe.py",
           "scripts/test_resume_bpy_owned_child_probe.py", "scripts/test_native_test_python_workflow.py"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        require(newurl.startswith("https://"), "Artifact redirect is not HTTPS")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def api_bytes(path):
    request = urllib.request.Request("https://api.github.com/repos/iret77/nexgenvideo/" + path,
        headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"})
    request.add_unredirected_header("Authorization", "Bearer " + os.environ["GH_TOKEN"])
    try:
        with urllib.request.build_opener(HTTPSRedirect()).open(request, timeout=45) as response:
            data = response.read(1_000_001)
    except (OSError, urllib.error.URLError, http.client.HTTPException):
        raise ValueError("Original GitHub evidence download failed") from None
    require(len(data) <= 1_000_000, "Original GitHub evidence exceeds its size bound")
    return data


def api(path):
    return json.loads(api_bytes(path))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify_producer(run, jobs, artifact):
    require(run.get("id") == RUN and run.get("head_sha") == SOURCE and run.get("run_attempt") == 1
            and run.get("event") == "workflow_dispatch" and run.get("status") == "completed"
            and run.get("conclusion") == "failure" and run.get("path") == ".github/workflows/native-acceptance-probes.yml"
            and run.get("head_branch") == "iret77/activity-approval-layout"
            and run.get("actor", {}).get("login") == "iret77"
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo", "Original producer differs")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete original job inventory")
    selected = [job for job in jobs["jobs"] if job.get("name") == "owned-child"]
    require(len(selected) == 1, "Original native job is missing or duplicated")
    job = selected[0]
    require(job.get("id") == 121692113899 and job.get("run_id") == RUN
            and job.get("run_attempt") == 1 and job.get("head_sha") == SOURCE
            and job.get("conclusion") == "failure" and job.get("status") == "completed", "Original job differs")
    expected = {"Verify output capture on the failed producer platform": "success",
                "Compile reviewed owned-child implementation and diagnostic": "success",
                "Record exact source, environment and signal lifecycle": "failure"}
    for name, conclusion in expected.items():
        steps = [step for step in job.get("steps", []) if step.get("name") == name]
        require(len(steps) == 1 and steps[0].get("conclusion") == conclusion, "Original step differs: " + name)
    require(artifact.get("id") == ARTIFACT and not artifact.get("expired", True)
            and artifact.get("name") == "owned-child-diagnostic-40357018456"
            and artifact.get("size_in_bytes") == 20309 and artifact.get("digest") == "sha256:" + ARCHIVE
            and artifact.get("workflow_run", {}).get("id") == RUN
            and artifact.get("workflow_run", {}).get("head_sha") == SOURCE, "Original artifact differs")


def unpack(raw, expected_tests):
    require(len(raw) == 20309 and sha(raw) == ARCHIVE, "Original archive bytes differ")
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate archive entries")
        binary = archive.read("owned-child/probe")
        receipt = json.loads(archive.read("owned-child/receipt.json"))
        events = archive.read("owned-child/events.jsonl")
        capture = archive.read("owned-child/capture-tests.log")
    require(sha(binary) == BINARY and receipt.get("binarySHA256") == BINARY
            and receipt.get("sourceSHA") == SOURCE and receipt.get("runID") == str(RUN)
            and receipt.get("attempt") == "1" and receipt.get("completed") is False
            and receipt.get("timedOut") is False, "Original binary receipt differs")
    require(cases_complete([json.loads(line) for line in events.decode().splitlines() if line]),
            "Original twelve C cases are incomplete")
    text = capture.decode()
    found = re.findall(r"(?m)^(test_\w+) \(test_run_macos_tests\.[^)]+\) \.\.\. (\w+)$", text)
    require(len(found) == len(expected_tests) == 43 and {name for name, _ in found} == set(expected_tests)
            and all(result == "ok" for _, result in found)
            and re.findall(r"(?m)^Ran (\d+) tests in [0-9.]+s$", text) == ["43"]
            and re.findall(r"(?m)^(?:OK.*|FAILED.*)$", text) == ["OK"], "Original capture suite differs")
    return binary, receipt, events, capture


def prepare(run_id, root):
    require(run_id == str(RUN), "Only the exact retained diagnostic can be continued")
    head = os.environ["GITHUB_SHA"]
    require(subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() == head, "Checkout differs")
    subprocess.run(["git", "merge-base", "--is-ancestor", SOURCE, head], check=True, timeout=30)
    changed = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", SOURCE, head], text=True).splitlines()
    require(set(changed) <= ALLOWED, "Compiled or capture-test inputs changed")
    require(not subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], text=True).strip(),
            "Tracked source is dirty")
    run, jobs, artifact = api(f"actions/runs/{RUN}"), api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100"), api(f"actions/artifacts/{ARTIFACT}")
    verify_producer(run, jobs, artifact)
    raw = api_bytes(f"actions/artifacts/{ARTIFACT}/zip")
    expected = re.findall(r"^    def (test_\w+)\(", Path("scripts/test_run_macos_tests.py").read_text(), re.M)
    binary, receipt, events, capture = unpack(raw, expected)
    for key, path in (("ownedChildSHA256", "Sources/BpySupervisorPOSIX/OwnedChild.c"),
                      ("probeSourceSHA256", "scripts/bpy_owned_child_probe.c")):
        require(sha(Path(path).read_bytes()) == receipt[key], "Retained binary source differs: " + path)
    require(subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip() == receipt["macOS"]
            and subprocess.check_output(["xcodebuild", "-version"], text=True).strip() == receipt["xcode"],
            "Retained probe platform differs")
    root.mkdir(parents=True, exist_ok=True)
    require(not (root / "probe").exists(), "Probe destination already exists")
    (root / "probe").write_bytes(binary)
    (root / "probe").chmod(0o755)
    (root / "original-cases.jsonl").write_bytes(events)
    (root / "original-capture-tests.log").write_bytes(capture)
    (root / "retained-producer.json").write_text(json.dumps({"run": run, "jobs": jobs, "artifact": artifact}, indent=2) + "\n")
    (root / "retained-binary.json").write_text(json.dumps({"schema": "owned-child-binary/v1",
        "sourceSHA": head, "producerRun": RUN, "producerAttempt": 1, "producerSource": SOURCE,
        "artifactID": ARTIFACT, "archiveSHA256": ARCHIVE, "binarySHA256": BINARY,
        "originalCasesSHA256": sha(events), "originalCaptureSHA256": sha(capture),
        "originalReceipt": receipt, "reusedCaptureTests": 43, "changedPaths": changed}, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.run_id, args.output)
