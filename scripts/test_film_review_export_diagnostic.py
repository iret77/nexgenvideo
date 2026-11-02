import copy
import contextlib
import io
import json
import os
import sys
from pathlib import Path
import tempfile
import unittest
import yaml
from unittest.mock import patch
from unittest.mock import Mock

import app_host_zombie_diagnostic as profiles
import capture_render_review_test_diagnostic as capture
import film_review_export_diagnostic as film
import run_macos_tests as driver


class FilmReviewDiagnosticTests(unittest.TestCase):
    def test_wrong_runtime_os_stops_before_products_or_the_original_test_are_loaded(self):
        root = Path(__file__).resolve().parents[1]
        workflow = yaml.safe_load((root / ".github/workflows/diagnostic-acceptance.yml").read_text())
        steps = workflow["jobs"]["ci-film-review-export"]["steps"]
        retain = next(step for step in steps if step.get("name") == "Retain compiled products before diagnostic execution")
        program = retain["run"].split("python3 -I - <<'PY'\n", 1)[1].split("\nPY", 1)[0]
        with patch("subprocess.check_output", side_effect=["26.0\n", "26A-test\n"]) as query, \
                patch.dict(os.environ, {}, clear=True), self.assertRaises(AssertionError):
            exec(compile(program, "retained-products-heredoc", "exec"), {})
        self.assertEqual(query.call_count, 2)

    def test_real_process_path_observes_the_film_review_profile_and_finishes_its_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "console.log"
            observation = dict(diagnosticProfile="film-review-export", hostUUID="test", hostSHA256="test")
            observer = Mock()
            observer.finish.return_value = {"status": "verified", "fixture": "owned-profile-dispatch-only"}
            with patch.object(driver, "ZombieCapture", return_value=observer) as constructor, \
                    contextlib.redirect_stdout(io.StringIO()):
                code, pid = driver.run_process([sys.executable, "-c", "print('targeted child')"], log,
                                               dict(os.environ, GITHUB_SHA="a" * 40), observation)
            self.assertEqual(code, 0)
            constructor.assert_called_once()
            self.assertEqual(constructor.call_args.args[0], pid)
            self.assertEqual(constructor.call_args.kwargs["profile"], "film-review-export")
            observer.start.assert_called_once()
            observer.finish.assert_called_once()
            self.assertEqual(observation["diagnostic"], observer.finish.return_value)
            self.assertEqual(log.read_text(), "targeted child\n")
            with self.assertRaises(ChildProcessError):
                os.waitpid(pid, os.WNOHANG)

    def original(self):
        run = dict(id=film.RUN, head_sha=film.BASE, repository={"full_name": "iret77/nexgenvideo"},
                   path=".github/workflows/ci-batch.yml", event="workflow_dispatch", status="completed", conclusion="failure")
        artifact = dict(id=film.ARTIFACT, workflow_run=dict(id=film.RUN, head_sha=film.BASE),
                        name="render-review-test-diagnostic-" + str(film.RUN), digest="sha256:" + film.DIGEST, expired=False)
        events = []
        for identity in [film.TEST_ID] + ["NexGenVideoTests.Fixture/test" + str(i) + "()/Fixture.swift:1:1" for i in range(3659)]:
            events.append(dict(kind="test", payload=dict(kind="function", id=identity)))
            events.append(dict(kind="event", payload=dict(kind="testStarted", testID=identity)))
            if identity != film.TEST_ID:
                events.append(dict(kind="event", payload=dict(kind="testEnded", testID=identity)))
        return run, artifact, events

    def test_original_binding_rejects_another_run_archive_or_pending_method(self):
        run, artifact, events = self.original()
        film.verify_original(run, artifact, events)
        for key, value in (("id", film.RUN + 1), ("head_sha", "a" * 40), ("conclusion", "success")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                film.verify_original(dict(run, **{key: value}), artifact, events)
        for key, value in (("id", film.ARTIFACT + 1), ("digest", "sha256:" + "a" * 64), ("expired", True)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                film.verify_original(run, dict(artifact, **{key: value}), events)
        for change in ("ended", "other-pending", "issue"):
            altered = copy.deepcopy(events)
            if change == "ended":
                altered.append(dict(kind="event", payload=dict(kind="testEnded", testID=film.TEST_ID)))
            elif change == "other-pending":
                for row in altered:
                    if row["payload"].get("id") == film.TEST_ID:
                        row["payload"]["id"] = "different"
                    if row["payload"].get("testID") == film.TEST_ID:
                        row["payload"]["testID"] = "different"
            else:
                altered.append(dict(kind="event", payload=dict(kind="issueRecorded")))
            with self.subTest(change=change), self.assertRaises(ValueError):
                film.verify_original(run, artifact, altered)

    def command(self, selected=film.FILM_REVIEW_FILTER):
        return ["python3", str(Path(capture.__file__).with_name("run_macos_tests.py")),
                "--cache-path", "/cache", "--scope", "app-swift-testing", "--app-diagnostic", "film-review-export",
                "--filter", selected, "--product-source-sha", "a" * 40, "--evidence", "/evidence"]

    def test_capture_rejects_other_filters_backends_profiles_and_retained_products(self):
        capture.validate_framework_selection(1, 0, True, True, self.command())
        for command in (self.command(""), self.command("ExportTests"), self.command() + ["--bin-root", "/retained"],
                        self.command() + ["--filter", film.FILM_REVIEW_FILTER]):
            with self.subTest(command=command), self.assertRaises(ValueError):
                capture.validate_framework_selection(1, 0, True, True, command)
        for swift, xctest, without in ((2, 0, True), (1, 1, True), (1, 0, False)):
            with self.assertRaises(ValueError):
                capture.validate_framework_selection(swift, xctest, True, without, self.command())

    def test_owned_profile_never_coexists_with_ambient_diagnostic_switches(self):
        selected = profiles.diagnostic_environment({"GITHUB_ACTIONS": "true"}, "film-review-export")
        self.assertEqual(selected, {"GITHUB_ACTIONS": "true", "NGV_FILM_REVIEW_EXPORT_DIAGNOSTIC": "1"})
        for profile in ("zombies", "glow-reproduction", "film-review-export"):
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                profiles.diagnostic_environment(selected, profile)
        args = type("Args", (), dict(scope="all", app_diagnostic=None, product_source_sha=None, bin_root=None))()
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "GITHUB_SHA": "a" * 40,
                                    "NGV_FILM_REVIEW_EXPORT_DIAGNOSTIC": "1"}), self.assertRaises(driver.VerificationError):
            driver.run(args)

    def test_driver_rejects_broader_selection_before_launch_or_evidence_creation(self):
        for change in ({"filter": "ExportTests"}, {"scope": "all"}, {"bin_root": Path("/retained")},
                       {"configuration": "release"}, {"swiftc_flag": ["-O"]}):
            args = type("Args", (), dict(scope="app-swift-testing", app_diagnostic="film-review-export",
                product_source_sha="a" * 40, bin_root=None, filter=film.FILM_REVIEW_FILTER,
                configuration="debug", scratch_path=None, swiftc_flag=[]))()
            for key, value in change.items():
                setattr(args, key, value)
            with self.subTest(change=change), patch.dict(os.environ, {"GITHUB_SHA": "a" * 40}, clear=True), \
                    self.assertRaises(driver.VerificationError):
                driver.run(args)

    def test_incomplete_capture_or_unfinished_request_cannot_be_reported_as_passing(self):
        for state in ("passed", "unfinished-request", "missing-capture", "wrong-method"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                host = root / "hosted-suite/app-swift-testing"
                host.mkdir(parents=True)
                stages = ["capture.begin", "slot.acquired", "session.prepared", "session.begin", "session.returned",
                          "post.effects", "post.review", "post.binding", "post.size", "heartbeat",
                          "capture.export.returned", "capture.verify.returned", "capture.committed"]
                rows = []
                for index in range(2 if state != "missing-capture" else 1):
                    for stage in stages:
                        row = dict(stage=stage, exportID=str(index), opacities=[0.5] if index else [1.0])
                        if stage == "heartbeat":
                            row.update(compositor=index + 1, ledger=[dict(instance=index + 1, started=240,
                                frame=239 if state == "unfinished-request" else 240, error=0, cancelled=0,
                                pending=1 if state == "unfinished-request" else 0, dropped=0)])
                        rows.append(row)
                (host / "console.log").write_text("\n".join("[film-review-export] " + json.dumps(row) for row in rows))
                phase = dict(exitCode=0, diagnostic=dict(status="verified"), events=dict(
                    startedFunctionIDs=[film.TEST_ID], endedFunctionIDs=[film.TEST_ID if state != "wrong-method" else "other"]))
                suite = dict(sourceSHA="a" * 40, harnessSourceSHA="a" * 40, productSourceSHA="a" * 40,
                    filter=film.FILM_REVIEW_FILTER, scope="app-swift-testing", completed=True, phases=[phase])
                (root / "hosted-suite/suite.json").write_text(json.dumps(suite))
                with patch.dict(os.environ, {"GITHUB_SHA": "a" * 40}):
                    self.assertEqual(film.interpret(root), 0 if state == "passed" else 1)
                report = json.loads((root / "interpretation.json").read_text())
                self.assertFalse(report["coreAcceptance"])
                self.assertFalse(report["releaseAcceptance"])

    def test_missing_inputs_and_torn_or_mixed_markers_always_preserve_interpretation(self):
        marker = dict(stage="heartbeat", exportID="owned-export", uptime=1, ledger=[])
        for case in ("missing-console", "missing-suite", "torn", "mixed"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                host = root / "hosted-suite/app-swift-testing"
                host.mkdir(parents=True)
                if case != "missing-console":
                    raw = ("unterminated stdout" if case == "mixed" else "")
                    raw += "[film-review-export] " + json.dumps(marker) + "\n"
                    if case == "torn":
                        raw += '[film-review-export] {"stage":\n'
                    (host / "console.log").write_text(raw)
                if case != "missing-suite":
                    (root / "hosted-suite/suite.json").write_text("{}")
                self.assertEqual(film.interpret(root), 1)
                report = json.loads((root / "interpretation.json").read_text())
                kept = json.loads((root / "export-markers.json").read_text())
                self.assertEqual(report["malformedMarkers"], 1 if case == "torn" else 0)
                self.assertEqual(kept, [] if case == "missing-console" else [marker])
                if kept:
                    self.assertEqual(report["lastMarkers"]["owned-export"], marker)
                    self.assertEqual(report["lastHeartbeats"]["owned-export"], marker)
                self.assertFalse(report["coreAcceptance"])


if __name__ == "__main__":
    unittest.main()
