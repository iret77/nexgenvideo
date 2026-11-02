import copy
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import yaml

import app_host_zombie_diagnostic as profiles
import capture_render_review_test_diagnostic as capture
import film_review_context_diagnostic as context
import run_macos_tests as driver


class FilmReviewContextTests(unittest.TestCase):
    def complete_fixture(self):
        harness, image = "a" * 40, "28e32694-8c96-33f4-9ebc-ab10afa8977b"
        binary = "/original/.build/out/Products/Debug"
        identities = sorted([context.original.TEST_ID] + [
            "NexGenVideoTests.ExportQueueTests/context" + str(i) + "()/Queue.swift:1:1" for i in range(40)])
        compiled = dict(sourceSHA=context.PRODUCT, binaries={"NexGenVideoAppKitTestHost":
            dict(sha256="b" * 64, uuidOutput="UUID: " + image + " (arm64)")})
        binding = dict(productSHA=context.PRODUCT, harnessSHA=harness, expectedFunctionIDs=identities,
                       compiled=compiled, originalBinRoot=binary)
        receipt = dict(pid=123, parentPID=122, sourceSHA=harness, hostExecutable=binary + "/NexGenVideoAppKitTestHost",
                       bundleBinary=binary + "/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests")
        diagnostic = dict(pid=123, parentPID=122, profile="film-review-context", status="verified",
            hostSHA256="b" * 64, hostUUID=image, sourceSHA=harness, harnessSourceSHA=harness,
            productSourceSHA=context.PRODUCT, memoryErrors=[], sampleCount=2,
            environment={"NGV_FILM_REVIEW_EXPORT_DIAGNOSTIC": "1", "otherDiagnosticVariablesPresent": False})
        phase = dict(pid=123, status="verified-execution", diagnostic=diagnostic, originalHostReceipt=receipt,
            exitCode=0, outputCapture=dict(originalExitCode=0, eof=True),
            events=dict(startedFunctionIDs=identities, endedFunctionIDs=identities, functionExecutions=41))
        suite = dict(binPath=binary, completed=True, scope="app-swift-testing", phases=[phase],
            sourceSHA=harness, harnessSourceSHA=harness, productSourceSHA=context.PRODUCT,
            filter=profiles.FILM_REVIEW_CONTEXT_FILTER, testExecutions=41)
        wrapper = dict(runID="17", sourceSHA=harness, testExitCode=0, effectiveExitCode=0)
        stages = ["capture.begin", "slot.acquired", "session.prepared", "session.begin", "session.returned",
                  "states.ended", "post.effects", "post.review", "post.binding", "post.size", "heartbeat",
                  "capture.export.returned", "capture.verify.returned", "capture.committed"]
        rows = []
        for index in range(4):
            instance, export = index + 1, "capture-" + str(index)
            rows.append(dict(stage="compositor.created", exportID="unbound", instance=instance))
            for stage in stages:
                row = dict(stage=stage, exportID=export, uptime=len(rows), cancelled=False)
                if stage == "capture.begin":
                    row.update(opacities=[0.5 if index == 3 else 1.0],
                               sources=[dict(originKind="external" if index in (0, 3) else "pipeline")])
                if stage == "heartbeat":
                    row.update(compositor=instance, nativeState="exporting:0.0", ledger=[dict(instance=instance,
                        started=240, frame=240, error=0, cancelled=0, pending=0, dropped=0)])
                rows.append(row)
            rows.append(dict(stage="compositor.destroyed", exportID="unbound", instance=instance, ownerPending=0))
        return dict(binding=binding, restored=dict(binRoot=binary), suite=suite, wrapper=wrapper, rows=rows)

    def write_fixture(self, root, fixture, console=None):
        metadata, evidence = root / "metadata", root / "evidence"
        metadata.mkdir()
        host = evidence / "hosted-suite/app-swift-testing"
        host.mkdir(parents=True)
        for name, data in (("binding.json", fixture["binding"]), ("restore.json", fixture["restored"]),
                           ("restored-manifest.json", {})):
            (metadata / name).write_text(json.dumps(data))
        (evidence / "hosted-suite/suite.json").write_text(json.dumps(fixture["suite"]))
        (evidence / "run.json").write_text(json.dumps(fixture["wrapper"]))
        raw = console if console is not None else "\n".join("[film-review-export] " + json.dumps(row) for row in fixture["rows"]).encode()
        (host / "console.log").write_bytes(raw)
        return metadata, evidence

    def test_original_host_binding_rejects_each_broken_identity_or_execution_path(self):
        fixture = self.complete_fixture()
        suite, compiled = fixture["suite"], fixture["binding"]["compiled"]
        phase = suite["phases"][0]
        phase["diagnostic"].update(profile="film-review-export", sourceSHA=context.PRODUCT, harnessSourceSHA=context.PRODUCT)
        phase["originalHostReceipt"]["sourceSHA"] = context.PRODUCT
        self.assertEqual(context.executed_product_root(suite, compiled, "film-review-export", context.PRODUCT), suite["binPath"])
        for change in ("sha", "uuid", "root", "bundle", "profile", "environment"):
            altered = copy.deepcopy(suite)
            phase = altered["phases"][0]
            if change == "sha": phase["diagnostic"]["hostSHA256"] = "c" * 64
            if change == "uuid": phase["diagnostic"]["hostUUID"] = "00000000-0000-0000-0000-000000000000"
            if change == "root": altered["binPath"] = "/different/Debug"
            if change == "bundle": phase["originalHostReceipt"]["bundleBinary"] = "/elsewhere/test"
            if change == "profile": phase["diagnostic"]["profile"] = "film-review-context"
            if change == "environment": phase["diagnostic"]["environment"]["extra"] = "1"
            with self.subTest(change=change), self.assertRaises(ValueError):
                context.executed_product_root(altered, compiled, "film-review-export", context.PRODUCT)

    def test_changed_original_root_is_rejected_before_product_download(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            binding = dict(productSHA=context.PRODUCT, harnessSHA="a" * 40, kind="ci-film-review-context",
                selection=profiles.FILM_REVIEW_CONTEXT_FILTER, originalBinRoot="/other/.build/out/Products/Debug",
                compiled=dict(productVersion="27.0", buildVersion="26A428", xcode="Xcode 27"))
            (folder / "binding.json").write_text(json.dumps(binding))
            with patch.dict(os.environ, dict(GITHUB_SHA="a" * 40, REPLAY_KIND="ci-film-review-context", GITHUB_WORKSPACE=directory)), \
                    patch.object(context, "command", side_effect=[context.PRODUCT, "27.0", "26A428", "Xcode 27"]), \
                    patch.object(context, "api") as api, patch.object(context, "download") as download, self.assertRaises(ValueError):
                context.restore(folder)
            api.assert_not_called()
            download.assert_not_called()

    def test_complete_context_and_single_mutation_rejections(self):
        for change in ("none", "executions", "root", "bundle", "environment", "profile", "uuid", "wrapper",
                       "order", "commit", "started", "pending", "three-captures", "four-external"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                fixture = self.complete_fixture()
                phase = fixture["suite"]["phases"][0]
                captures = [r for r in fixture["rows"] if r["stage"] == "capture.begin"]
                if change == "executions": phase["events"]["functionExecutions"] = 42
                if change == "root": fixture["suite"]["binPath"] = "/other/.build/out/Products/Debug"
                if change == "bundle": phase["originalHostReceipt"]["bundleBinary"] = "/other/test"
                if change == "environment": phase["diagnostic"]["environment"]["extra"] = "1"
                if change == "profile": phase["diagnostic"]["profile"] = "film-review-export"
                if change == "uuid": phase["diagnostic"]["hostUUID"] = "00000000-0000-0000-0000-000000000000"
                if change == "wrapper": fixture["wrapper"]["effectiveExitCode"] = 1
                if change == "order": captures[0]["opacities"], captures[3]["opacities"] = [0.5], [1.0]
                if change == "commit": fixture["rows"] = [r for r in fixture["rows"] if not (r["exportID"] == "capture-0" and r["stage"] == "capture.committed")]
                if change in ("started", "pending"):
                    next(r for r in fixture["rows"] if r["stage"] == "heartbeat")["ledger"][0][change] = 241 if change == "started" else 1
                if change == "three-captures": fixture["rows"] = [r for r in fixture["rows"] if r["exportID"] != "capture-1"]
                if change == "four-external":
                    for r in captures: r["sources"] = [dict(originKind="external")]
                metadata, evidence = self.write_fixture(Path(directory), fixture)
                with patch.dict(os.environ, dict(GITHUB_SHA="a" * 40, GITHUB_RUN_ID="17")), patch.object(context, "verify_tree"):
                    self.assertEqual(context.verify(metadata, evidence), 0 if change == "none" else 1)
                result = json.loads((evidence / "context-interpretation.json").read_text())
                self.assertFalse(result["coreAcceptance"])
                self.assertFalse(result["releaseAcceptance"])
                if change == "none":
                    self.assertTrue(all(c["lastBoundary"] == "capture.committed" and c["statesEnded"]["present"] for c in result["captures"].values()))
                    self.assertEqual(result["ledger"]["unbalanced"], [])

    def test_torn_mixed_and_invalid_utf8_output_keep_later_valid_markers(self):
        for case in ("torn", "utf8", "mixed"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                fixture = self.complete_fixture()
                lines = [("[film-review-export] " + json.dumps(row)).encode() for row in fixture["rows"]]
                if case == "torn": lines.insert(3, b'[film-review-export] {"stage":')
                if case == "utf8": lines.insert(3, b'\xff')
                if case == "mixed": lines[0] = b'unterminated stdout' + lines[0]
                metadata, evidence = self.write_fixture(Path(directory), fixture, b'\n'.join(lines))
                with patch.dict(os.environ, dict(GITHUB_SHA="a" * 40, GITHUB_RUN_ID="17")), patch.object(context, "verify_tree"):
                    self.assertEqual(context.verify(metadata, evidence), 1 if case == "torn" else 0)
                self.assertEqual(json.loads((evidence / "context-markers.json").read_text()), fixture["rows"])
                result = json.loads((evidence / "context-interpretation.json").read_text())
                self.assertEqual(result["malformedMarkers"], 1 if case == "torn" else 0)
                self.assertIn("capture-3", result["lastHeartbeats"])

    def test_stall_summary_names_last_real_boundary_and_prior_unfinished_receiver(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = self.complete_fixture()
            fixture["suite"]["completed"] = False
            stages = ("capture.begin", "slot.acquired", "session.prepared", "session.begin", "heartbeat")
            fixture["rows"] = [r for r in fixture["rows"] if r["exportID"] == "capture-0" and r["stage"] in stages]
            heartbeat = next(r for r in fixture["rows"] if r["stage"] == "heartbeat")
            heartbeat["ledger"].append(dict(instance=99, started=1, frame=0, error=0, cancelled=0, pending=1, dropped=0))
            fixture["rows"].append(copy.deepcopy(heartbeat))
            metadata, evidence = self.write_fixture(Path(directory), fixture)
            with patch.object(context, "verify_tree"):
                self.assertEqual(context.verify(metadata, evidence), 1)
            result = json.loads((evidence / "context-interpretation.json").read_text())
            self.assertEqual(result["captures"]["capture-0"]["lastBoundary"], "session.begin")
            self.assertFalse(result["captures"]["capture-0"]["sessionReturned"])
            self.assertFalse(result["captures"]["capture-0"]["statesEnded"]["present"])
            self.assertEqual([r["instance"] for r in result["ledger"]["unbalanced"]], [99])

    def test_original_inventory_requires_the_failed_method_and_exact_bounded_count(self):
        identities = [context.original.TEST_ID] + [
            "NexGenVideoTests.ExportQueueTests/context" + str(i) + "()/Queue.swift:1:1" for i in range(40)]
        rows = [dict(kind="test", payload=dict(kind="function", id=i)) for i in identities]
        rows.append(dict(kind="test", payload=dict(kind="function", id="NexGenVideoTests.Unrelated/test()/U.swift:1:1")))
        self.assertEqual(context.selected_inventory(rows), sorted(identities))
        for changed in (rows[1:], rows + [rows[1]], rows[:-2]):
            with self.assertRaises(ValueError):
                context.selected_inventory(changed)

    def test_context_driver_and_capture_reject_broader_or_fresh_product_modes(self):
        command = ["python3", str(Path(capture.__file__).with_name("run_macos_tests.py")),
                   "--cache-path", "/unused", "--scope", "app-swift-testing", "--app-diagnostic", "film-review-context",
                   "--filter", profiles.FILM_REVIEW_CONTEXT_FILTER, "--bin-root", "/retained",
                   "--product-source-sha", context.PRODUCT, "--evidence", "/evidence"]
        capture.validate_framework_selection(1, 0, True, True, command)
        for change in ({"filter": ""}, {"bin_root": None}, {"scope": "all"},
                       {"configuration": "release"}, {"scratch_path": "/fresh"}, {"swiftc_flag": ["-O"]}):
            args = SimpleNamespace(scope="app-swift-testing", app_diagnostic="film-review-context",
                product_source_sha=context.PRODUCT, bin_root=Path("/retained"),
                filter=profiles.FILM_REVIEW_CONTEXT_FILTER, configuration="debug", scratch_path=None, swiftc_flag=[])
            for key, value in change.items():
                setattr(args, key, value)
            with self.subTest(change=change), patch.dict(os.environ, {"GITHUB_SHA": "a" * 40}, clear=True), \
                    self.assertRaises(driver.VerificationError):
                driver.run(args)
        for flag, value in (("--filter", "ExportQueueTests"), ("--bin-root", "relative")):
            changed = list(command)
            changed[changed.index(flag) + 1] = value
            with self.assertRaises(ValueError):
                capture.validate_framework_selection(1, 0, True, True, changed)
        self.assertEqual(profiles.profile_environment("film-review-context"), {"NGV_FILM_REVIEW_EXPORT_DIAGNOSTIC": "1"})

    def test_wrong_producer_inputs_fail_before_git_network_or_filesystem_admission(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(context, "command") as command, \
                patch.object(context, "api") as api, patch.dict(os.environ, {}, clear=True):
            folder = Path(directory) / "uncreated"
            with self.assertRaises(ValueError):
                context.source(folder)
            command.assert_not_called()
            api.assert_not_called()
            self.assertFalse(folder.exists())

    def test_wrong_native_os_fails_before_download_or_product_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "binding.json").write_text(json.dumps(dict(productSHA=context.PRODUCT, harnessSHA="a" * 40,
                kind="ci-film-review-context", selection=profiles.FILM_REVIEW_CONTEXT_FILTER,
                compiled=dict(productVersion="27.0", buildVersion="26A428", xcode="Xcode 27"))))
            with patch.dict(os.environ, {"GITHUB_SHA": "a" * 40, "REPLAY_KIND": "ci-film-review-context"}), \
                    patch.object(context, "command", side_effect=[context.PRODUCT, "26.0"]), \
                    patch.object(context, "api") as api, patch.object(context, "download") as download, \
                    self.assertRaises(ValueError):
                context.restore(folder)
            api.assert_not_called()
            download.assert_not_called()

    def test_launch_failure_still_retains_an_incomplete_context_interpretation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = root / "metadata"
            metadata.mkdir()
            self.assertEqual(context.verify(metadata, root / "evidence"), 1)
            result = json.loads((root / "evidence/context-interpretation.json").read_text())
            self.assertEqual(result["status"], "incomplete-context")
            self.assertFalse(result["coreAcceptance"])
            self.assertFalse(result["releaseAcceptance"])
            self.assertEqual(json.loads((root / "evidence/context-markers.json").read_text()), [])

    def test_native_context_job_reuses_products_and_invokes_one_owned_host_selection(self):
        root = Path(__file__).resolve().parents[1]
        workflow = yaml.safe_load((root / ".github/workflows/diagnostic-acceptance.yml").read_text())
        job = workflow["jobs"]["ci-film-review-context"]
        self.assertEqual(job["runs-on"], "macrunner")
        scripts = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertNotIn("swift build", scripts)
        self.assertNotIn("swift test", scripts)
        runs = [step for step in job["steps"] if step.get("name") == "Run only the bounded native export context once"]
        self.assertEqual(len(runs), 1)
        self.assertIn("--app-diagnostic film-review-context", runs[0]["run"])
        self.assertIn("--bin-root", runs[0]["run"])
        self.assertIn("--swift-testing-runs 1 --xctest-runs 0", runs[0]["run"])
        self.assertIn("--without-runloop-probe --app-only", runs[0]["run"])


if __name__ == "__main__":
    unittest.main()
