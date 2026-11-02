"""Bind one failed native export and interpret its diagnostic-only replay."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

from app_host_zombie_diagnostic import FILM_REVIEW_FILTER

BASE = "0d991d3bd23b0f1eb62bac7fdfe102fe4df34d9f"
RUN = 41366151985
ARTIFACT = 13109352050
DIGEST = "3bf3e356352e5d57151b244545aa71ec1b31570b997cea7a35d4df4304efcee3"
TEST = "Tests/NexGenVideoTests/Agent/PipelineProductionSequenceReviewStoreTests.swift"
TEST_DIGEST = "c549034f74b2e5654995e2053b85c2c4f4a129c206856dda277990eba46636a3"
TEST_ID = "NexGenVideoTests." + FILM_REVIEW_FILTER + "()/PipelineProductionSequenceReviewStoreTests.swift:24:6"
PATHS = {
    ".github/workflows/diagnostic-acceptance.yml",
    "Sources/NexGenVideo/Agent/Pipeline/PipelineProductionSequenceReviewStore.swift",
    "Sources/NexGenVideo/Compositing/CustomVideoCompositor.swift",
    "Sources/NexGenVideo/Export/ExportService.swift",
    "Sources/NexGenVideo/Export/FilmReviewExportDiagnostic.swift",
    "scripts/app_host_zombie_diagnostic.py", "scripts/run_macos_tests.py",
    "scripts/capture_render_review_test_diagnostic.py", "scripts/film_review_export_diagnostic.py",
    "scripts/test_film_review_export_diagnostic.py",
    "scripts/test_native_test_python_workflow.py",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_original(run, artifact, events):
    require(run.get("id") == RUN and run.get("head_sha") == BASE
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("path") == ".github/workflows/ci-batch.yml"
            and run.get("event") == "workflow_dispatch" and run.get("status") == "completed"
            and run.get("conclusion") == "failure", "Original failed run differs")
    require(artifact.get("id") == ARTIFACT and artifact.get("workflow_run", {}).get("id") == RUN
            and artifact["workflow_run"].get("head_sha") == BASE
            and artifact.get("name") == "render-review-test-diagnostic-" + str(RUN)
            and artifact.get("digest") == "sha256:" + DIGEST and artifact.get("expired") is False,
            "Original diagnostic archive identity differs")
    starts, ends = Counter(), Counter()
    functions = {row["payload"]["id"] for row in events
                 if row.get("kind") == "test" and row.get("payload", {}).get("kind") == "function"}
    issues = run_ends = 0
    for row in events:
        event = row.get("payload", {}) if row.get("kind") == "event" else {}
        kind = event.get("kind")
        identity = event.get("testID", "")
        if kind == "issueRecorded":
            issues += 1
        if kind == "runEnded":
            run_ends += 1
        if identity in functions:
            if kind == "testStarted":
                starts[identity] += 1
            if kind == "testEnded":
                ends[identity] += 1
    require(sum(starts.values()) == 3660 and sum(ends.values()) == 3659
            and starts - ends == Counter({TEST_ID: 1}) and not ends - starts
            and issues == run_ends == 0, "The original unfinished native method differs")


def command(argv):
    return subprocess.check_output(argv, stdin=subprocess.DEVNULL, timeout=120)


def bind(folder):
    require(os.environ.get("GITHUB_REPOSITORY") == "iret77/nexgenvideo", "Repository differs")
    for key, value in {"CANDIDATE_RUN": str(RUN), "CANDIDATE_SOURCE": BASE,
                       "CANDIDATE_ARTIFACT": str(ARTIFACT), "CANDIDATE_DIGEST": DIGEST}.items():
        require(os.environ.get(key) == value, "Original input differs: " + key)
    sha = command(["git", "rev-parse", "HEAD"]).decode().strip()
    require(sha == os.environ.get("GITHUB_SHA"), "Diagnostic checkout differs")
    require(command(["git", "show", "-s", "--format=%P", sha]).decode().strip() == BASE,
            "Diagnostic must be a direct child of the failed source")
    changed = set(command(["git", "diff", "--name-only", "-z", BASE, sha]).decode().split("\0")) - {""}
    require(changed == PATHS, "Diagnostic changed an unreviewed path or is incomplete")
    require(hashlib.sha256(Path(TEST).read_bytes()).hexdigest() == TEST_DIGEST, "Original test changed")
    require(not command(["git", "status", "--porcelain", "--untracked-files=no"]).strip(), "Checkout is dirty")
    folder.mkdir(parents=True, exist_ok=False)
    api = ["gh", "api", "repos/iret77/nexgenvideo/actions/"]
    run = json.loads(command(api[:-1] + [api[-1] + "runs/" + str(RUN)]))
    artifact = json.loads(command(api[:-1] + [api[-1] + "artifacts/" + str(ARTIFACT)]))
    archive = command(api[:-1] + [api[-1] + "artifacts/" + str(ARTIFACT) + "/zip"])
    require(hashlib.sha256(archive).hexdigest() == DIGEST, "Original archive bytes differ")
    archive_path = folder / "original.zip"
    archive_path.write_bytes(archive)
    with zipfile.ZipFile(archive_path) as zipped:
        raw_events = zipped.read("hosted-suite/app-swift-testing/events.jsonl")
    verify_original(run, artifact, [json.loads(line) for line in raw_events.splitlines()])
    record = {"diagnosticSourceSHA": sha, "parentSHA": BASE, "originalRun": RUN,
              "originalArtifact": ARTIFACT, "originalArchiveSHA256": DIGEST,
              "originalEventsSHA256": hashlib.sha256(raw_events).hexdigest(),
              "testSHA256": TEST_DIGEST, "filter": FILM_REVIEW_FILTER, "coreAcceptance": False,
              "changedPaths": sorted(changed)}
    for name, data in (("run.json", run), ("artifact.json", artifact), ("binding.json", record)):
        (folder / name).write_text(json.dumps(data, indent=2) + "\n")


def interpret(folder):
    folder.mkdir(parents=True, exist_ok=True)
    records = []
    report = {"coreAcceptance": False, "releaseAcceptance": False,
              "status": "incomplete-diagnostic", "rootCause": "not-established", "malformedMarkers": 0}
    try:
        console = folder / "hosted-suite/app-swift-testing/console.log"
        for line in console.read_text(errors="replace").splitlines():
            for fragment in line.split("[film-review-export] ")[1:]:
                try:
                    row, _ = json.JSONDecoder().raw_decode(fragment.lstrip())
                    require(isinstance(row, dict) and isinstance(row.get("exportID"), str)
                            and isinstance(row.get("stage"), str), "Malformed marker object")
                    records.append(row)
                except ValueError:
                    report["malformedMarkers"] += 1
        require(report["malformedMarkers"] == 0, "Native output contains malformed diagnostic markers")
        suite = json.loads((folder / "hosted-suite/suite.json").read_text())
        require(suite["sourceSHA"] == suite["harnessSourceSHA"] == suite["productSourceSHA"]
                == os.environ.get("GITHUB_SHA") and suite["filter"] == FILM_REVIEW_FILTER
                and suite["scope"] == "app-swift-testing" and suite["completed"] is True,
                "Owned native execution is incomplete")
        require(len(suite["phases"]) == 1, "More than one backend ran")
        phase = suite["phases"][0]
        require(phase["exitCode"] == 0 and phase["diagnostic"]["status"] == "verified"
                and phase["events"]["startedFunctionIDs"] == phase["events"]["endedFunctionIDs"] == [TEST_ID],
                "Exact original test did not complete once")
        captures = [row for row in records if row["stage"] == "capture.begin"]
        require(len(captures) == 2, "Both original captures are required")
        stages = ["capture.begin", "slot.acquired", "session.prepared", "session.begin", "session.returned",
                  "post.effects", "post.review", "post.binding", "post.size", "capture.export.returned",
                  "capture.verify.returned", "capture.committed"]
        for capture in captures:
            rows = [row for row in records if row["exportID"] == capture["exportID"]]
            require([row["stage"] for row in rows if row["stage"] in stages] == stages,
                    "Capture did not cross every original boundary")
            instances = {row["compositor"] for row in rows if row["stage"] == "heartbeat" and row["compositor"]}
            require(bool(instances), "No session compositor identity was observed")
            last = [row for row in rows if row["stage"] == "heartbeat"][-1]
            ledger = {row["instance"]: row for row in last["ledger"]}
            for instance in instances:
                item = ledger[instance]
                require(item["started"] > 0 and item["started"] == item["frame"] + item["error"] + item["cancelled"]
                        and item["pending"] == item["dropped"] == 0, "Compositor request accounting differs")
        require(0.5 in captures[1]["opacities"] and 0.5 not in captures[0]["opacities"], "Capture order differs")
        report["status"] = "isolated-original-test-passed-cause-not-proven"
    except (OSError, TypeError, KeyError, IndexError, ValueError) as error:
        report["limitation"] = str(error)
    report["markerCount"] = len(records)
    report["lastMarkers"] = {row["exportID"]: row for row in records}
    report["lastHeartbeats"] = {row["exportID"]: row for row in records if row["stage"] == "heartbeat"}
    (folder / "export-markers.json").write_text(json.dumps(records, indent=2) + "\n")
    (folder / "interpretation.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["status"].startswith("isolated-original-test-passed") else 1


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("action", choices=("bind", "interpret"))
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    if args.action == "bind":
        bind(args.evidence)
        return 0
    return interpret(args.evidence)


if __name__ == "__main__":
    raise SystemExit(main())
