#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import time
from datetime import datetime


REPOSITORY = "iret77/nexgenvideo"


def seconds(start, end):
    if not start or not end:
        return 0
    return max(0, int((datetime.fromisoformat(end.replace("Z", "+00:00")) - datetime.fromisoformat(start.replace("Z", "+00:00"))).total_seconds()))


def summarize(run, jobs):
    rows = []
    for job in jobs:
        rows.append(dict(
            name=job["name"], conclusion=job["conclusion"], labels=job.get("labels", []),
            runner_seconds=seconds(job["started_at"], job["completed_at"]),
            steps=[dict(name=step["name"], seconds=seconds(step.get("started_at"), step.get("completed_at")))
                   for step in job.get("steps", []) if step.get("started_at") != step.get("completed_at")],
        ))
    return dict(
        run=run["id"], attempt=run["run_attempt"], sha=run["head_sha"],
        conclusion=run["conclusion"], url=run["html_url"],
        elapsed_seconds=seconds(run["run_started_at"], run["updated_at"]),
        runner_seconds=sum(row["runner_seconds"] for row in rows), jobs=rows,
    )


def failure_excerpt(log, limit=60):
    raw_lines = log.splitlines()
    lines = [re.sub(r"\x1b\[[0-9;]*m", "", line) for line in raw_lines]
    failures = []
    for index, line in enumerate(lines):
        if "\x1b[36;1m" in raw_lines[index] or "✔" in line or "◇" in line:
            continue
        if re.search(r"✘|recorded an issue|Expectation failed|unexpected signal code|##\[error\]|::error|\berror: (?!none)", line, re.I):
            failures.append(index)
    selected = set(failures[:limit])
    for index in failures:
        for neighbor in range(max(0, index - 1), min(len(lines), index + 4)):
            if len(selected) < limit:
                selected.add(neighbor)
    for index in range(max(0, len(lines) - 12), len(lines)):
        if len(selected) < limit:
            selected.add(index)
    return "\n".join(lines[index][:800] for index in sorted(selected))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run", type=int)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--interval", type=int, default=60)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--gh-command", nargs="+", default=["gh"])
    args = parser.parse_args()
    if not 10 <= args.interval <= 60 or args.timeout < 1 or args.run < 1:
        parser.error("interval must be 10–60 seconds; timeout and run must be positive")

    def gh(*command):
        return subprocess.check_output([*args.gh_command, *command], text=True, stderr=subprocess.PIPE, timeout=60)

    def api(endpoint):
        return json.loads(gh("api", f"repos/{REPOSITORY}/{endpoint}"))

    deadline = time.monotonic() + args.timeout
    errors = 0
    while time.monotonic() < deadline:
        try:
            run = api(f"actions/runs/{args.run}")
        except (subprocess.SubprocessError, OSError, ValueError) as error:
            errors += 1
            print(json.dumps(dict(error=f"CI status unavailable ({errors}/3): {error}")), flush=True)
            if errors == 3:
                return 2
        else:
            errors = 0
            if run["head_sha"] != args.sha:
                raise ValueError("CI run does not match the requested commit")
            if run["status"] == "completed":
                jobs = []
                page = 1
                while True:
                    batch = api(f"actions/runs/{args.run}/attempts/{run['run_attempt']}/jobs?per_page=100&page={page}")
                    jobs.extend(batch["jobs"])
                    if len(jobs) >= batch["total_count"]:
                        break
                    if not batch["jobs"]:
                        raise ValueError("incomplete CI jobs response")
                    page += 1
                if not jobs or any(job["status"] != "completed" for job in jobs):
                    raise ValueError("completed CI run has missing or unfinished jobs")
                print(json.dumps(summarize(run, jobs)), flush=True)
                for job in jobs:
                    if job["conclusion"] not in ("success", "skipped", "neutral"):
                        try:
                            log = gh("run", "view", str(args.run), "--repo", REPOSITORY, "--job", str(job["id"]), "--log-failed")
                            print(json.dumps(dict(job=job["name"], failure_excerpt=failure_excerpt(log))), flush=True)
                        except (subprocess.SubprocessError, OSError) as error:
                            print(json.dumps(dict(job=job["name"], error=f"Failure log unavailable: {error}")), flush=True)
                return 0 if run["conclusion"] == "success" else 1
        time.sleep(min(args.interval, max(0, deadline - time.monotonic())))
    print(json.dumps(dict(error="CI monitoring timed out", run=args.run)), flush=True)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"CI monitoring failed: {error}") from error
