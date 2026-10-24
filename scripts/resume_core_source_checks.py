"""Complete a failed cache-inventory check without repeating unchanged source checks."""
import argparse
import ast
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from retained_app_test_products import api, checksum, require, write
from resume_core_tests import command
from verify_swift_test_output import ANSI


ALLOWED = {".github/workflows/ci.yml", ".github/workflows/ci-batch.yml", "scripts/resume_core_tests.py",
           "scripts/test_swiftpm_dependency_cache.py", "scripts/resume_core_source_checks.py",
           "scripts/test_resume_core_source_checks.py"}
FAILED_TEST = "test_swiftpm_dependency_cache.SwiftPMDependencyCacheTests.test_every_swiftpm_workflow_uses_the_shared_cache_contract"
WORKFLOW_TESTS = ("test_ci_workflow", "test_resume_core_tests", "test_swift_test_failure_propagation",
                  FAILED_TEST, "test_swiftpm_dependency_cache.SwiftPMDependencyCacheTests.test_build_products_are_never_cached")
PASSED_STEPS = ("Bind completed Core backends before allocating Mac jobs", "Transfer original completed backend evidence",
                "Classify changes", "Require distributable bpy before app transfer", "Enforce AppTheme", "Validate pack pipeline contracts")


def verify_jobs(run, jobs):
    require(run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("path") == ".github/workflows/ci-batch.yml" and run.get("event") == "workflow_dispatch"
            and run.get("head_branch") == "iret77/activity-approval-layout"
            and run.get("run_attempt") == 1 and run.get("status") == "completed" and run.get("conclusion") == "failure",
            "Source continuation requires its original failed Core batch")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete original job inventory")
    selected = [j for j in jobs["jobs"] if j.get("name") == "Compile, unit tests, app and native bpy acceptance / Light Checks"]
    require(len(selected) == 1, "Missing or duplicate original source job")
    job = selected[0]
    require(job.get("run_id") == run["id"] and job.get("run_attempt") == 1 and job.get("head_sha") == run["head_sha"]
            and job.get("status") == "completed" and job.get("conclusion") == "failure", "Original source job identity differs")
    for name in (*PASSED_STEPS, "Verify CI and fixture tooling"):
        steps = [s for s in job.get("steps", []) if s.get("name") == name]
        expected = "failure" if name == "Verify CI and fixture tooling" else "success"
        require(len(steps) == 1 and steps[0].get("conclusion") == expected, "Original source check differs: " + name)
    return job


def original_result(text):
    lines = [re.sub(r"^\ufeff?\d{4}-\d\d-\d\dT[^ ]+ ", "", ANSI.sub("", line)) for line in text.splitlines()]
    failures = [re.fullmatch(r"FAIL: [^ ]+ \(([^)]+)\)", line).group(1)
                for line in lines if re.fullmatch(r"FAIL: [^ ]+ \(([^)]+)\)", line)]
    require(failures == [FAILED_TEST] and not any(line.startswith("ERROR:") for line in lines),
            "Original Linux run has another failure or error")
    summaries = [re.fullmatch(r"Ran (\d+) tests in [0-9.]+s", line) for line in lines]
    totals = [int(match[1]) for match in summaries if match]
    finals = [line for line in lines if line.startswith(("FAILED (", "OK"))]
    require(len(totals) == 1 and totals[0] > 4 and finals == ["FAILED (failures=1, skipped=3)"],
            "Original Linux completion is incomplete or ambiguous")
    require("python3 -m unittest discover -s scripts -p 'test_*.py'" in lines, "Original job did not select all tooling tests")
    return {"total": totals[0], "passed": totals[0] - 4, "skipped": 3, "failed": [FAILED_TEST]}


def verify_source(source, head):
    require(re.fullmatch(r"[a-f0-9]{40}", source) and re.fullmatch(r"[a-f0-9]{40}", head), "Invalid source identity")
    require(command(["git", "rev-parse", "HEAD"]) == head, "Source checkout differs")
    subprocess.run(["git", "merge-base", "--is-ancestor", source, head], stdin=subprocess.DEVNULL, check=True, timeout=30)
    changed = command(["git", "diff", "--name-only", "--no-renames", source, head]).splitlines()
    require(set(changed) <= ALLOWED, "Unrelated source check inputs changed")
    require(not command(["git", "status", "--porcelain", "--untracked-files=no"]), "Source checkout is dirty")
    original = command(["git", "show", source + ":.github/workflows/ci.yml"])
    require("scripts/resume_core_source_checks.py" not in original, "Recursive source continuation is unsupported")
    repo = Path(__file__).resolve().parents[1]
    for path in ("scripts/resume_core_tests.py", "scripts/test_swiftpm_dependency_cache.py"):
        if path in changed:
            verify_reused_test_inputs(path, command(["git", "show", source + ":" + path]), (repo / path).read_text())
    return changed


def verify_reused_test_inputs(path, before, after):
    old, new = ast.parse(before), ast.parse(after)
    if path == "scripts/resume_core_tests.py":
        def declaration(tree):
            matches = [node for node in tree.body if isinstance(node, ast.Assign)
                       and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)
                       and node.targets[0].id == "HARNESS_PATHS"]
            require(len(matches) == 1, "Core allowlist declaration is ambiguous")
            return matches[0]
        original, current = declaration(old), declaration(new)
        added = {"scripts/test_swiftpm_dependency_cache.py", "scripts/resume_core_source_checks.py",
                 "scripts/test_resume_core_source_checks.py"}
        require(ast.literal_eval(current.value) == ast.literal_eval(original.value) | added,
                "Core allowlist changed beyond the reviewed source-check continuation")
        current.value = original.value
    else:
        matches = [node for node in ast.walk(new) if isinstance(node, ast.Set)
                   and any(isinstance(item, ast.Constant) and item.value == "diagnostic-acceptance.yml" for item in node.elts)]
        require(len(matches) == 1, "Cache workflow correction is missing or ambiguous")
        matches[0].elts = [item for item in matches[0].elts
                          if not isinstance(item, ast.Constant) or item.value != "diagnostic-acceptance.yml"]
    require(ast.dump(old) == ast.dump(new), "A previously tested implementation or cache assertion changed")


def prepare(run_id, root):
    root.mkdir(parents=True, exist_ok=False)
    run = api(f"actions/runs/{run_id}")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    job = verify_jobs(run, jobs)
    head = os.environ["GITHUB_SHA"]
    changed = verify_source(run["head_sha"], head)
    log = root / "original-linux.log"
    with log.open("xb") as output:
        subprocess.run(["gh", "api", "--allow-escape-sequences", f"repos/iret77/nexgenvideo/actions/jobs/{job['id']}/logs"],
                       stdin=subprocess.DEVNULL, stdout=output, check=True, timeout=120)
    result = original_result(log.read_text())
    write(root / "receipt.json", {"schema": "core-source-resume/v1", "sourceSHA": head,
          "runID": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
          "originalRun": run, "originalJobs": jobs, "originalResult": result, "changedPaths": changed,
          "originalLogSHA256": checksum(log), "reusedSteps": list(PASSED_STEPS)})


def verify(root):
    receipt = json.loads((root / "receipt.json").read_text())
    require(receipt.get("schema") == "core-source-resume/v1" and receipt.get("sourceSHA") == os.environ.get("GITHUB_SHA")
            and receipt.get("runID") == os.environ.get("GITHUB_RUN_ID")
            and receipt.get("attempt") == os.environ.get("GITHUB_RUN_ATTEMPT"), "Source receipt belongs to another execution")
    verify_jobs(receipt["originalRun"], receipt["originalJobs"])
    require(verify_source(receipt["originalRun"]["head_sha"], receipt["sourceSHA"]) == receipt["changedPaths"],
            "Source changes differ from receipt")
    require(checksum(root / "original-linux.log") == receipt["originalLogSHA256"]
            and original_result((root / "original-linux.log").read_text()) == receipt["originalResult"]
            and receipt["reusedSteps"] == list(PASSED_STEPS), "Original source proof differs")
    return receipt


def successful_tests(text):
    summaries = re.findall(r"(?m)^Ran (\d+) tests? in [0-9.]+s$", text)
    require(len(summaries) == 1 and int(summaries[0]) > 0
            and re.findall(r"(?m)^(?:OK.*|FAILED.*)$", text) == ["OK"]
            and not re.search(r"(?m)^(?:FAIL|ERROR):", text), "Current selected test output is incomplete or failed")
    return int(summaries[0])


def run_selected(root):
    receipt = verify(root)
    repo = Path(__file__).resolve().parents[1]
    selections = [(repo, [sys.executable, "-m", "unittest", "discover", "-s", "scripts", "-p", "test_resume_core_source_checks.py"]),
                  (repo / "scripts", [sys.executable, "-m", "unittest", *WORKFLOW_TESTS])]
    results = []
    for index, (cwd, args) in enumerate(selections):
        log = root / f"selected-{index}.log"
        with log.open("xb") as output:
            result = subprocess.run(args, cwd=cwd, stdin=subprocess.DEVNULL, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=180)
        text = log.read_text()
        print(text, flush=True)
        require(result.returncode == 0, "Selected source tests failed; original successful tests were not repeated")
        results.append({"command": args, "cwd": str(cwd), "testCount": successful_tests(text), "logSHA256": checksum(log)})
    write(root / "completed.json", {"schema": "core-source-completion/v1", "sourceSHA": receipt["sourceSHA"],
          "originalRunID": receipt["originalRun"]["id"], "originalSourceSHA": receipt["originalRun"]["head_sha"],
          "originalResult": receipt["originalResult"], "newSelections": results,
          "reusedChecks": list(PASSED_STEPS), "note": "Original failed run remains failed; unchanged successful source checks are reused."})


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("action", choices=("prepare", "run"))
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--run-id", type=int)
    args = parser.parse_args()
    if args.action == "prepare":
        require(args.run_id and args.run_id > 0, "Original failed source run is required")
        prepare(args.run_id, args.evidence)
    else:
        run_selected(args.evidence)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        raise SystemExit("Source continuation failed: " + str(error))
