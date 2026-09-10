import io
import json
import subprocess
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from ci_watch import failure_excerpt, main, seconds, summarize


class CIWatchTests(unittest.TestCase):
    def test_runner_seconds_sum_jobs_and_exclude_queue_time(self):
        run = dict(id=1, run_attempt=2, head_sha="sha", conclusion="success", html_url="url",
                   run_started_at="2026-09-10T12:00:00Z", updated_at="2026-09-10T12:02:00Z")
        jobs = [dict(name=name, conclusion="success", started_at="2026-09-10T12:01:00Z",
                     completed_at="2026-09-10T12:02:00Z", steps=[]) for name in ("build", "ui")]
        report = summarize(run, jobs)
        self.assertEqual(report["runner_seconds"], 120)
        self.assertEqual(report["elapsed_seconds"], 120)
        self.assertEqual(seconds(None, None), 0)

    def test_failure_excerpt_keeps_error_context_and_bounds_output(self):
        log = "\n".join(["compile"] * 1000 + ["file.swift:3 error: bad type", "source context"] + ["tail"] * 1000)
        excerpt = failure_excerpt(log)
        self.assertIn("error: bad type", excerpt)
        self.assertIn("source context", excerpt)
        self.assertLessEqual(len(excerpt.splitlines()), 60)

    def invoke(self, replies):
        with patch("sys.argv", ["ci_watch.py", "1", "--sha", "expected"]), \
             patch("ci_watch.subprocess.check_output", side_effect=replies), \
             patch("ci_watch.time.sleep"), redirect_stdout(io.StringIO()) as output:
            return main(), output.getvalue()

    def test_three_api_errors_fail_visibly(self):
        code, output = self.invoke([subprocess.CalledProcessError(1, "gh")] * 3)
        self.assertEqual(code, 2)
        self.assertIn("3/3", output)

    def test_wrong_commit_is_never_accepted(self):
        with self.assertRaisesRegex(ValueError, "requested commit"):
            self.invoke([json.dumps(dict(head_sha="other", status="completed"))])

    def test_empty_jobs_are_not_success(self):
        with self.assertRaisesRegex(ValueError, "missing or unfinished"):
            self.invoke([
                json.dumps(dict(head_sha="expected", status="completed", run_attempt=1)),
                json.dumps(dict(jobs=[], total_count=0)),
            ])

    def test_cancelled_run_returns_failure(self):
        code, output = self.invoke([
            json.dumps(dict(id=1, head_sha="expected", status="completed", run_attempt=1,
                            conclusion="cancelled", html_url="url", run_started_at=None, updated_at=None)),
            json.dumps(dict(jobs=[dict(id=2, name="build", status="completed", conclusion="cancelled",
                                     started_at=None, completed_at=None)], total_count=1)),
            "cancelled",
        ])
        self.assertEqual(code, 1)
        self.assertIn('"conclusion": "cancelled"', output)


if __name__ == "__main__":
    unittest.main()
