import copy
from contextlib import chdir
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import yaml

import release_checkpoint as checkpoint
import release_native_proof as native
from run_macos_tests import VerificationError
from test_release_workflow import active_publication_steps, condition_enabled


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release.yml"
SOURCE = "a" * 40
UUID = "12345678-1234-1234-1234-123456789abc"


class ReleaseRecoveryTests(unittest.TestCase):
    def original(self):
        run = {"id": native.RUN, "head_sha": native.SOURCE, "repository": {"full_name": checkpoint.REPOSITORY},
               "path": ".github/workflows/release.yml", "actor": {"login": "iret77"},
               "event": "workflow_dispatch", "run_attempt": 1, "status": "completed", "conclusion": "cancelled"}
        names = ("Build the exact release test configuration", "Stage release test runtime inputs",
                 "Test the exact release configuration", "Upload release test evidence",
                 "Verify release build did not mutate tracked source", "Verify release tests did not mutate tracked source")
        job = {"id": native.JOB, "run_id": native.RUN, "run_attempt": 1, "head_sha": native.SOURCE,
               "name": "release", "labels": ["macrunner"], "status": "completed", "conclusion": "cancelled",
               "started_at": "2026-11-02T10:00:00Z", "completed_at": "2026-11-02T12:00:00Z",
               "steps": [{"name": name, "conclusion": "success"} for name in names] + [
                   {"name": "Notarize app and build signed, notarized DMG", "conclusion": "cancelled"}]}
        return run, {"total_count": 1, "jobs": [job]}

    def suite(self, root):
        files = {}
        phases = []
        for name, count, skips in (("xctest", 48, 0), ("engine-swift-testing", 896, 14),
                                   ("app-swift-testing", 3663, 8)):
            swift = name != "xctest"
            if swift:
                console = "◇ Test run started.\n" + f"✔ Test run with {count} tests in 1 suite passed after 1 second.\n"
                module = "NexGenEngineTests" if name.startswith("engine") else "NexGenVideoTests"
                records = [{"version": 0, "kind": "event", "payload": {"kind": "runStarted"}}]
                for index in range(count + skips):
                    identity = f"{module}/test{index}"
                    records.append({"version": 0, "kind": "test", "payload": {"kind": "function", "id": identity,
                                    "sourceLocation": {"fileID": module + "/Fixture.swift"}}})
                    kinds = ("testStarted", "testEnded") if index < count else ("testSkipped",)
                    for kind in kinds:
                        records.append({"version": 0, "kind": "event", "payload": {"kind": kind, "testID": identity}})
                records.append({"version": 0, "kind": "event", "payload": {"kind": "runEnded"}})
                event_data = "".join(json.dumps(record) + "\n" for record in records).encode()
                event_path = root / (name + ".jsonl")
                event_path.write_bytes(event_data)
                events = native.swift_events(event_path, module)
                files[name + "/events.jsonl"] = event_data
            else:
                console = "Test Suite 'All tests' started at now.\n"
                console += "".join(f"Test Case 'Fixture.test{index}' passed\n" for index in range(count))
                console += "Test Suite 'All tests' passed at now.\n"
                console += "Test Suite 'All tests' started at now.\nTest Suite 'All tests' passed at now.\n"
            log = root / (name + ".log")
            log.write_text(console)
            phase = {"name": name, "status": "verified-execution", "exitCode": 0,
                     "outputCapture": {"originalExitCode": 0, "eof": True}, "command": ["test-host"],
                     "framework": native.assess_output(log, swift_testing_runs=int(swift), xctest_runs=0 if swift else 2)}
            if swift:
                phase["events"] = events
            else:
                phase["testCaseExecutions"] = count
            files[name + "/console.log"] = console.encode()
            phases.append(phase)
        host = {"sourceSHA": native.SOURCE, "pid": 99, "recordingError": None, "error": None,
                **dict.fromkeys(("mainThread", "applicationRunningAtStart", "started", "completed",
                                 "abiSucceeded", "runReturnedAfterCompletion"), True)}
        phases[2].update(pid=99, originalHostReceipt=host)
        files["app-swift-testing/host-receipt.json"] = json.dumps(host).encode()
        files["app-swift-testing/watchdog/owned.json"] = json.dumps({"processID": 99,
            "operatingSystem": "Version 27.0 (Build 26A428)"}).encode()
        suite = {"schema": 1, "sourceSHA": native.SOURCE, "configuration": "release", "scope": "all",
                 "filter": "", "completed": True, "scratchPath": "/temporary/release-tests", "testExecutions": 4607,
                 "phases": phases, "combinedFrameworks": {"passed": True}}
        return suite, files

    def suite_zip(self, root, suite, files):
        path = root / "suite.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("evidence/suite.json", json.dumps(suite))
            for name, data in files.items():
                archive.writestr("evidence/" + name, data)
        return path

    def artifact(self, run, name, path, identity=123):
        return {"id": identity, "name": name, "digest": "sha256:" + checkpoint.checksum(path),
                "size_in_bytes": path.stat().st_size, "expired": False,
                "workflow_run": {"id": run["id"], "head_sha": run["head_sha"]},
                "created_at": "2026-11-02T11:00:00Z", "updated_at": "2026-11-02T11:00:01Z",
                "expires_at": "2100-01-01T00:00:00Z"}

    def signed(self, root):
        app = root / "original/NexGenVideo.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        executable = app / "Contents/MacOS/NexGenVideo"
        executable.write_bytes(b"exact-signed-production-app")
        executable.chmod(0o755)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.8.0",
            "CFBundleVersion": "105", "NGVSourceCommit": SOURCE,
            "NGVPluginCatalogURL": "https://example.test/catalog.json"}))
        payload = root / "original"
        with zipfile.ZipFile(payload / "NexGenVideo.zip", "w") as archive:
            for path in sorted(app.rglob("*")):
                archive.write(path, path.relative_to(payload).as_posix())
        for filename, entry in (("plugins.tar.gz", "plugins/musicvideo.ngvpack/pack"),
                                ("symbols.tar.gz", "NexGenVideo.dSYM/Contents/symbols")):
            with tarfile.open(payload / filename, "w:gz") as archive:
                data = b"retained-companion"
                item = tarfile.TarInfo(entry)
                item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
        (payload / "bpy-source-receipt.json").write_text('{"qualified":true}\n')
        manifest = {"schema": "release-signed-input/v1", "repository": checkpoint.REPOSITORY,
                    "sourceSHA": SOURCE, "runID": 123, "attempt": 1,
                    "identity": checkpoint.identity(payload), "appTreeSHA256": checkpoint.tree_digest(app),
                    "nativeEvidence": {"schema": "fresh-release-tests/v1", "suite": {"sourceSHA": SOURCE,
                        "completed": True, "scope": "all", "configuration": "release", "filter": ""}},
                    "files": {name: {"bytes": (payload / name).stat().st_size,
                                     "sha256": checkpoint.checksum(payload / name)} for name in checkpoint.FILES}}
        checkpoint.write(payload / "manifest.json", manifest)
        archive_path = root / "signed.zip"
        with zipfile.ZipFile(archive_path, "w") as archive:
            for name in (*checkpoint.FILES, "manifest.json"):
                archive.write(payload / name, name)
        return manifest, archive_path

    def restore_fixture(self, root, manifest, archive):
        binding = root / "binding"
        binding.mkdir()
        artifact = self.artifact({"id": 123, "head_sha": SOURCE}, "signed", archive)
        checkpoint.write(binding / "binding.json", {"schema": "release-signed-binding/v1", "sourceSHA": SOURCE,
            "producer": {"id": 123}, "artifact": artifact, "manifest": manifest})
        return binding

    def fake_mac(self, *args):
        if args[0] == "/usr/bin/ditto":
            with zipfile.ZipFile(args[-2]) as archive:
                archive.extractall(args[-1])
                for item in archive.infolist():
                    mode = stat.S_IMODE(item.external_attr >> 16)
                    if mode:
                        (Path(args[-1]) / item.filename).chmod(mode)
        else:
            self.assertEqual(args[:3], ("codesign", "--verify", "--strict"))

    def notary_run(self, root, run_id, context, app_tree, dmg, plugins, restored=False):
        root.mkdir()
        run = {"id": run_id, "head_sha": SOURCE, "repository": {"full_name": checkpoint.REPOSITORY},
               "path": ".github/workflows/release.yml", "event": "workflow_dispatch", "run_attempt": 1,
               "actor": {"login": "iret77"}, "status": "completed", "conclusion": "failure"}
        job = {"name": "release", "head_sha": SOURCE, "run_id": run_id, "run_attempt": 1,
               "labels": ["macrunner"], "status": "completed", "conclusion": "failure",
               "started_at": "2026-11-02T10:00:00Z", "completed_at": "2026-11-02T12:00:00Z",
               "steps": [{"name": name, "conclusion": result} for name, result in (
                   ("Build and sign DMG", "skipped" if restored else "success"),
                   ("Restore saved notarization and DMG", "success" if restored else "skipped"),
                   ("Record DMG before notarization", "success"), ("Retain DMG before notarization", "success"))]}
        state = root / "state.zip"
        digest = checkpoint.checksum(dmg)
        with zipfile.ZipFile(state, "w") as archive:
            archive.writestr("context.json", json.dumps(context))
            archive.writestr(digest + ".json", json.dumps({"schema": "release-notary/v1", "sourceSHA": SOURCE,
                              "sha256": digest, "submissionID": UUID}))
        payload = root / "dmg.zip"
        manifest = {"schema": "release-dmg-checkpoint/v1", "context": context, "appTreeSHA256": app_tree,
                    "files": {name: {"bytes": path.stat().st_size, "sha256": checkpoint.checksum(path)}
                              for name, path in (("NexGenVideo.dmg", dmg), ("plugins.tar.gz", plugins))}}
        with zipfile.ZipFile(payload, "w") as archive:
            archive.writestr("dmg-checkpoint.json", json.dumps(manifest))
            archive.write(dmg, "NexGenVideo.dmg")
            archive.write(plugins, "plugins.tar.gz")
        state_item = self.artifact(run, "release-notary-state-" + SOURCE, state, run_id * 10)
        dmg_item = self.artifact(run, "release-dmg-input-" + SOURCE, payload, run_id * 10 + 1)
        responses = {f"actions/runs/{run_id}": run,
            f"actions/runs/{run_id}/attempts/1/jobs?per_page=100": {"total_count": 1, "jobs": [job]},
            f"actions/runs/{run_id}/artifacts?per_page=100": {"total_count": 2, "artifacts": [state_item, dmg_item]},
            f"actions/artifacts/{state_item['id']}": state_item, f"actions/artifacts/{dmg_item['id']}": dmg_item}
        sources = {state_item["id"]: state, dmg_item["id"]: payload}
        return responses, sources, job

    def test_native_reuse_accepts_exact_completed_release_evidence(self):
        run, jobs = self.original()
        self.assertEqual(native.verify_original(run, jobs)["id"], native.JOB)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            suite, files = self.suite(root)
            archive_path = self.suite_zip(root, suite, files)
            with zipfile.ZipFile(archive_path) as archive:
                proof = native.verify_suite(archive, root)
            self.assertEqual((proof["executions"], proof["skips"]), (4607, 22))
            self.assertEqual([p["executions"] for p in proof["backends"]], [48, 896, 3663])

    def test_native_reuse_rejects_wrong_run_or_artifact(self):
        run, jobs = self.original()
        for field, value in (("id", 1), ("head_sha", SOURCE), ("run_attempt", 2),
                             ("actor", {"login": "someone"}), ("conclusion", "success")):
            with self.subTest(field=field):
                changed = dict(run, **{field: value})
                with self.assertRaises(ValueError):
                    native.verify_original(changed, jobs)
        for key, value in (("labels", ["macos-latest"]), ("head_sha", SOURCE), ("run_attempt", 2)):
            changed = copy.deepcopy(jobs)
            changed["jobs"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                native.verify_original(run, changed)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "payload"
            path.write_bytes(b"original")
            item = self.artifact(run, "release-test-evidence", path, native.ARTIFACT)
            digest = checkpoint.checksum(path)
            native.verify_artifact(item, run, jobs["jobs"][0], native.ARTIFACT, digest, item["name"])
            for key, value in (("expired", True), ("digest", "sha256:" + "0" * 64), ("id", 3),
                               ("workflow_run", {"id": 1, "head_sha": native.SOURCE})):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    native.verify_artifact(dict(item, **{key: value}), run, jobs["jobs"][0],
                                           native.ARTIFACT, digest, item["name"])

    def test_native_reuse_rejects_failed_filtered_or_incomplete_suite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            suite, files = self.suite(root)
            mutations = []
            for key, value in (("completed", False), ("filter", "only-one"), ("scope", "app-swift-testing"),
                               ("configuration", "debug"), ("testExecutions", 4606)):
                changed = copy.deepcopy(suite)
                changed[key] = value
                mutations.append((key, changed, files))
            for backend in range(3):
                for key, value in (("exitCode", 1), ("status", "reused")):
                    changed = copy.deepcopy(suite)
                    changed["phases"][backend][key] = value
                    mutations.append((f"{backend}-{key}", changed, files))
                changed = copy.deepcopy(suite)
                changed["phases"][backend]["outputCapture"]["eof"] = False
                mutations.append((f"{backend}-eof", changed, files))
            changed_files = dict(files)
            changed_files["app-swift-testing/events.jsonl"] = files["app-swift-testing/events.jsonl"].rsplit(b"\n", 2)[0] + b"\n"
            mutations.append(("missing-native-completion", suite, changed_files))
            for index, (name, changed, data) in enumerate(mutations):
                target = root / str(index)
                target.mkdir()
                archive_path = self.suite_zip(target, changed, data)
                with self.subTest(name=name), zipfile.ZipFile(archive_path) as archive, self.assertRaises((ValueError, VerificationError)):
                    native.verify_suite(archive, target)

    def test_native_reuse_rejects_changed_native_inputs(self):
        text = WORKFLOW.read_text()
        for path in ("Sources/NexGenVideo/App.swift", "Tests/NexGenVideoTests/Test.swift", "Package.resolved",
                     "Package.swift", "plugins/musicvideo.json", "scripts/run_macos_tests.py", ".bpy-runtime.lock.json"):
            def command(*args):
                if args[1] == "rev-parse": return SOURCE
                if args[1] == "diff": return path
                if args[1] == "status": return ""
                return text
            with self.subTest(path=path), patch.object(native, "command", side_effect=command), \
                    patch.object(native.subprocess, "run"), self.assertRaises(ValueError):
                native.verify_sources(SOURCE)
        def unchanged(*args):
            return {"rev-parse": SOURCE, "diff": "scripts/notarize.sh", "status": "", "show": text}[args[1]]
        with patch.object(native, "command", side_effect=unchanged), patch.object(native.subprocess, "run"):
            self.assertEqual(native.verify_sources(SOURCE), ["scripts/notarize.sh"])

    def test_native_reuse_requires_matching_environment(self):
        expected = {"os": "Version 27.0 (Build 26A428)", "xcode": "Xcode 27.0\nBuild version 27A266a", "python": "3.13.17"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "original.zip").write_bytes(b"pinned-original")
            digest = checkpoint.checksum(root / "original.zip")
            checkpoint.write(root / "receipt.json", {"schema": "release-native-reuse/v1", "sourceSHA": SOURCE,
                "artifactSHA256": digest, "proof": expected})
            outputs = {("sw_vers", "-productVersion"): "27.0", ("sw_vers", "-buildVersion"): "26A428",
                       ("xcodebuild", "-version"): expected["xcode"]}
            with patch.dict(os.environ, GITHUB_SHA=SOURCE), patch.object(native, "DIGEST", digest), \
                    patch.object(native.platform, "machine", return_value="arm64"), \
                    patch.object(native.platform, "python_version", return_value=expected["python"]), \
                    patch.object(native, "command", side_effect=lambda *args: outputs[args]):
                native.environment(root)
                for key in outputs:
                    old = outputs[key]
                    outputs[key] = "changed"
                    with self.subTest(key=key), self.assertRaises(ValueError): native.environment(root)
                    outputs[key] = old
                with patch.object(native.platform, "python_version", return_value="3.14.0"), self.assertRaises(ValueError):
                    native.environment(root)
                with patch.object(native.platform, "machine", return_value="x86_64"), self.assertRaises(ValueError):
                    native.environment(root)

    def test_workflow_fixture_projection_rejects_changed_publication_guards(self):
        text = WORKFLOW.read_text()
        original = native.workflow_observations(text)
        for name in ("Reject open release blockers", "Inspect or resume release publication"):
            start = text.index("name: " + name + "\n")
            end = text.index("\n      - ", start)
            step = text[start:end]
            changed = step.replace("inputs.artifact_only == false", "true")
            self.assertNotEqual(native.workflow_observations(text[:start] + changed + text[end:]), original)
        for word in ("gh label list", "gh label view", "--repo iret77/nexgenvideo", "scripts/publish_release_metadata.sh",
                     "python3 scripts/update_appcast.py"):
            changed = text.replace(word, "changed") if word in text else text + "\n# " + word + "\n"
            self.assertNotEqual(native.workflow_observations(changed), original)

    def test_signed_input_roundtrips_exact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, archive = self.signed(root)
            binding = self.restore_fixture(root, manifest, archive)
            environment = dict(GITHUB_SHA=SOURCE, REL_VERSION="1.8.0", GITHUB_ENV=str(root / "env"),
                               PLUGIN_CATALOG_URL="https://example.test/catalog.json",
                               GITHUB_RUN_ID="456", NOTARY_STATE_DIR=str(root / "notary"))
            with chdir(root), patch.dict(os.environ, environment), patch.object(checkpoint, "run", side_effect=self.fake_mac) as commands, \
                    patch.object(checkpoint, "download", side_effect=lambda item, destination: shutil.copyfile(archive, destination)):
                checkpoint.restore(binding)
            self.assertEqual((root / ".build/NexGenVideo.zip").read_bytes(), (root / "original/NexGenVideo.zip").read_bytes())
            self.assertEqual(checkpoint.tree_digest(root / ".build/NexGenVideo.app"), manifest["appTreeSHA256"])
            self.assertEqual((root / ".build/plugins/musicvideo.ngvpack/pack").read_bytes(), b"retained-companion")
            self.assertIn("BUILD_NUMBER=105\n", (root / "env").read_text())
            self.assertEqual(json.loads((root / "notary/context.json").read_text())["buildRunID"], 123)
            self.assertFalse(any(call.args[0] == "swift" for call in commands.call_args_list))

    def test_signed_input_rejects_foreign_source_or_producer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, archive = self.signed(root)
            checkpoint.verify_manifest(manifest, SOURCE, 123)
            for key, value in (("sourceSHA", "b" * 40), ("runID", 999), ("attempt", 2), ("repository", "other/repo")):
                with self.subTest(key=key), self.assertRaises(ValueError):
                    checkpoint.verify_manifest(dict(manifest, **{key: value}), SOURCE, 123)
            run = {"id": 123, "head_sha": SOURCE, "repository": {"full_name": checkpoint.REPOSITORY},
                   "path": ".github/workflows/release.yml", "event": "workflow_dispatch", "run_attempt": 1,
                   "actor": {"login": "iret77"}, "status": "completed"}
            with patch.dict(os.environ, GITHUB_SHA=SOURCE, GITHUB_REPOSITORY=checkpoint.REPOSITORY, GITHUB_RUN_ID="456"):
                for key, value in (("head_sha", "b" * 40), ("path", "ci.yml"), ("run_attempt", 2), ("status", "in_progress")):
                    with self.subTest(key=key), patch.object(checkpoint, "api", return_value=dict(run, **{key: value})), \
                            self.assertRaises(ValueError):
                        checkpoint.prepare(123, root / key)
                prefix = "release-signed-input-" + SOURCE
                proof = root / "proof.zip"
                with zipfile.ZipFile(proof, "w") as zipped:
                    zipped.writestr("manifest.json", json.dumps(manifest))
                payload_item = self.artifact(run, prefix, archive, 100)
                proof_item = self.artifact(run, prefix + "-proof", proof, 101)
                job = {"name": "release-build", "head_sha": SOURCE, "conclusion": "success", "labels": ["macrunner"],
                       "started_at": "2026-11-02T10:00:00Z", "completed_at": "2026-11-02T12:00:00Z"}
                responses = {"actions/runs/123": run, "actions/runs/123/attempts/1/jobs?per_page=100": {"total_count": 1, "jobs": [job]},
                    "actions/runs/123/artifacts?per_page=100": {"total_count": 2, "artifacts": [payload_item, proof_item]},
                    "actions/artifacts/100": payload_item, "actions/artifacts/101": proof_item}
                with patch.object(checkpoint, "api", side_effect=responses.__getitem__), \
                        patch.object(checkpoint, "download", side_effect=lambda item, destination: shutil.copyfile(proof, destination)):
                    checkpoint.prepare(123, root / "prepared")
                    recorded = json.loads((root / "prepared/binding.json").read_text())
                    self.assertEqual(recorded["artifact"], payload_item)
                    self.assertEqual(recorded["manifest"], manifest)
                    job["conclusion"] = "failure"
                    with self.assertRaises(ValueError): checkpoint.prepare(123, root / "failed-builder")
                job["conclusion"] = "success"
                packaging = dict(job, name="release")
                responses["actions/runs/123/attempts/1/jobs?per_page=100"] = {"total_count": 2, "jobs": [job, packaging]}
                state = root / "notary-state.zip"
                context = {"schema": "release-notary-context/v1", "repository": checkpoint.REPOSITORY,
                           "sourceSHA": SOURCE, "runID": 123, "buildRunID": 123}
                journal = {"schema": "release-notary/v1", "sourceSHA": SOURCE, "sha256": "c" * 64, "submissionID": UUID}
                sources = {100: archive, 101: proof, 102: state}
                for with_journal in (False, True):
                    with zipfile.ZipFile(state, "w") as zipped:
                        zipped.writestr("context.json", json.dumps(context))
                        if with_journal: zipped.writestr("c" * 64 + ".json", json.dumps(journal))
                    item = self.artifact(run, "release-notary-state-" + SOURCE, state, 102)
                    responses["actions/runs/123/artifacts?per_page=100"] = {"total_count": 3,
                        "artifacts": [payload_item, proof_item, item]}
                    responses["actions/artifacts/102"] = item
                    target = root / ("journal-present" if with_journal else "context-only")
                    with patch.object(checkpoint, "api", side_effect=responses.__getitem__), \
                            patch.object(checkpoint, "download", side_effect=lambda item, destination: shutil.copyfile(sources[item["id"]], destination)):
                        if with_journal:
                            with self.assertRaisesRegex(ValueError, "notary_progress_run_id"): checkpoint.prepare(123, target)
                            self.assertFalse((target / "binding.json").exists())
                            with patch.dict(os.environ, GITHUB_RUN_ID="123"):
                                checkpoint.prepare(123, root / "same-run")
                            saved = root / "saved-notary"
                            saved.mkdir()
                            shutil.copyfile(state, saved / "state.zip")
                            checkpoint.write(saved / "notary-binding.json", {"schema": "release-notary-binding/v1",
                                "context": context, "producer": {"id": 123}, "stateArtifact": item})
                            with patch.dict(os.environ, RELEASE_NOTARY_BINDING=str(saved)):
                                checkpoint.prepare(123, root / "verified-notary")
                        else:
                            checkpoint.prepare(123, target)
                            self.assertTrue((target / "binding.json").exists())

    def test_signed_input_rejects_modified_or_escaping_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest, archive = self.signed(root)
            binding = self.restore_fixture(root, manifest, archive)
            archive.write_bytes(archive.read_bytes() + b"tampered")
            with patch.dict(os.environ, GITHUB_SHA=SOURCE), \
                    patch.object(checkpoint, "download", side_effect=lambda item, destination: shutil.copyfile(archive, destination)), \
                    patch.object(checkpoint, "run") as commands, self.assertRaises(ValueError):
                checkpoint.restore(binding)
            commands.assert_not_called()
            for index, name in enumerate(("../outside", "/absolute", "other.app/file")):
                path = root / f"escape{index}.zip"
                with zipfile.ZipFile(path, "w") as zipped: zipped.writestr(name, b"bad")
                with self.subTest(name=name), self.assertRaises(ValueError): checkpoint.validate_app_zip(path)
            path = root / "link.zip"
            with zipfile.ZipFile(path, "w") as zipped:
                link = zipfile.ZipInfo("NexGenVideo.app/Contents/link")
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                zipped.writestr(link, "../../../outside")
            with self.assertRaises(ValueError): checkpoint.validate_app_zip(path)
            path = root / "escape.tar.gz"
            with tarfile.open(path, "w:gz") as tar:
                item = tarfile.TarInfo("../outside")
                item.size = 3
                tar.addfile(item, io.BytesIO(b"bad"))
            with self.assertRaises(ValueError): checkpoint.extract_tar(path, root, {"plugins"})
            for index, kind in enumerate((tarfile.SYMTYPE, tarfile.LNKTYPE)):
                path = root / f"tar-link{index}.tar.gz"
                with tarfile.open(path, "w:gz") as tar:
                    item = tarfile.TarInfo("plugins/escape")
                    item.type = kind
                    item.linkname = "../NexGenVideo.app" if kind == tarfile.SYMTYPE else "NexGenVideo.app/Contents/Info.plist"
                    tar.addfile(item)
                with self.subTest(kind=kind), self.assertRaises(ValueError):
                    checkpoint.extract_tar(path, root, {"plugins"})
            self.assertFalse((root / "outside").exists())

    def test_resume_keeps_completed_build_and_tests(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        jobs = workflow["jobs"]
        self.assertEqual(jobs["release"]["needs"], ["release-gate", "release-build"])
        for name in ("release-build", "bpy-source"):
            condition = jobs[name]["if"]
            self.assertIn("inputs.signed_build_run_id == ''", condition)
            self.assertIn("inputs.notary_progress_run_id == ''", condition)
        steps = {step.get("name"): step for step in jobs["release-build"]["steps"]}
        for name in ("Build the exact release test configuration", "Stage release test runtime inputs", "Test the exact release configuration"):
            self.assertEqual(steps[name]["if"], "inputs.completed_release_tests_run_id == ''")
        self.assertNotIn("notarize", "\n".join(step.get("run", "") for step in steps.values()).lower())
        packaging = "\n".join(step.get("run", "") for step in jobs["release"]["steps"])
        self.assertNotIn("swift build", packaging)
        self.assertNotIn("run_macos_tests.py", packaging)
        self.assertIn("release_checkpoint.py restore", packaging)
        bundle = (ROOT / "scripts/bundle.sh").read_text()
        phase_exit = bundle.index('if [ "$MODE" = "notarize-app" ] ||')
        self.assertLess(phase_exit, bundle.index('swift build', phase_exit))
        self.assertIn("exit 0", bundle[phase_exit:bundle.index('swift build', phase_exit)])
        def ancestors(name):
            needs = jobs[name].get("needs", [])
            if isinstance(needs, str): needs = [needs]
            return set(needs).union(*(ancestors(parent) for parent in needs))
        for name, job in jobs.items():
            if "release" not in ancestors(name):
                continue
            direct = job["needs"] if isinstance(job["needs"], list) else [job["needs"]]
            for artifact_only in (True, False):
                expected = artifact_only if name in ("chat-hang-replay", "musicvideo-analysis-acceptance") else not artifact_only if name == "publish" else True
                with self.subTest(job=name, artifact_only=artifact_only):
                    self.assertEqual(condition_enabled(job.get("if"), artifact_only, artifact_only,
                                                      ancestry_success=False), expected)
                    if expected:
                        for failed in direct:
                            self.assertFalse(condition_enabled(job.get("if"), artifact_only, artifact_only,
                                ancestry_success=False, needs_results={failed: "failure"}), (name, failed))

    def test_notary_journal_binds_payload_and_submission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tool = root / "notarytool"
            tool.write_text('#!/bin/bash\nprintf "%s\\n" "$1" >> "$CALLS"\n'
                            f'if [ "$1" = submit ]; then echo \'{{"id":"{UUID}"}}\'; '
                            'elif [ "$1" = wait ]; then echo \'{"status":"Accepted"}\'; fi\n')
            tool.chmod(0o755)
            artifact = root / "artifact.zip"
            artifact.write_bytes(b"signed-input")
            calls = root / "calls"
            state = root / "notary"
            environment = dict(os.environ, NOTARYTOOL_BIN=str(tool), NOTARY_KEY_FILE="fake.p8", NOTARY_KEY_ID="key",
                               NOTARY_ISSUER="issuer", NOTARY_STATE_DIR=str(state), NOTARY_RETRY_DELAY_SECONDS="0",
                               CALLS=str(calls), GITHUB_SHA=SOURCE)
            def execute():
                return subprocess.run(["bash", str(ROOT / "scripts/notarize.sh"), str(artifact)], env=environment,
                                      stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
            self.assertEqual(execute().returncode, 0)
            self.assertEqual(execute().returncode, 0)
            self.assertEqual(calls.read_text().splitlines(), ["submit", "wait", "wait"])
            journal = state / (checkpoint.checksum(artifact) + ".json")
            receipt = json.loads(journal.read_text())
            self.assertEqual(receipt["submissionID"], UUID)
            for key, value in (("sha256", "0" * 64), ("sourceSHA", "b" * 40), ("submissionID", "invalid")):
                checkpoint.write(journal, dict(receipt, **{key: value}))
                with self.subTest(key=key): self.assertNotEqual(execute().returncode, 0)
            checkpoint.write(journal, receipt)
            artifact.write_bytes(b"new-payload")
            self.assertEqual(execute().returncode, 0)
            self.assertEqual(calls.read_text().splitlines(), ["submit", "wait", "wait", "submit", "wait"])
            base = root / "chain"
            base.mkdir()
            manifest, _ = self.signed(base)
            shutil.copytree(base / "original/NexGenVideo.app", base / ".build/NexGenVideo.app")
            dmg = base / "original/NexGenVideo.dmg"
            dmg.write_bytes(b"same-signed-dmg-before-Apple-wait")
            old_context = {"schema": "release-notary-context/v1", "repository": checkpoint.REPOSITORY,
                           "sourceSHA": SOURCE, "buildRunID": 123, "runID": 321}
            current = dict(old_context, runID=456)
            state = base / "notary"
            state.mkdir()
            checkpoint.write(state / "context.json", current)
            responses, sources, job = self.notary_run(base / "first", 321, old_context,
                manifest["appTreeSHA256"], dmg, base / "original/plugins.tar.gz")
            def fake_mac(*args):
                if args[:2] == ("hdiutil", "attach"):
                    shutil.copytree(base / "original/NexGenVideo.app", Path(args[-1]) / "NexGenVideo.app")
                elif args[:2] == ("hdiutil", "detach"):
                    return
                elif args[0] == "ditto":
                    shutil.copytree(args[1], args[2], dirs_exist_ok=True)
                else:
                    self.assertEqual(args[0], "tar")
                    subprocess.run(args, check=True, stdin=subprocess.DEVNULL, timeout=10)
            environment = dict(GITHUB_SHA=SOURCE, NOTARY_STATE_DIR=str(state), GITHUB_OUTPUT=str(base / "output"))
            with chdir(base), patch.dict(os.environ, environment), patch.object(checkpoint, "api", side_effect=responses.__getitem__), \
                    patch.object(checkpoint, "download", side_effect=lambda item, destination: shutil.copyfile(sources[item["id"]], destination)), \
                    patch.object(checkpoint, "run", side_effect=fake_mac):
                binding = base / "first-binding"
                checkpoint.prepare_notary(321, binding)
                checkpoint.restore_notary(binding)
                self.assertEqual((base / ".build/NexGenVideo.dmg").read_bytes(), dmg.read_bytes())
                self.assertIn("dmg_present=true\n", (base / "output").read_text())
                next_checkpoint = base / "next-dmg"
                checkpoint.create_dmg(next_checkpoint)
                next_manifest = json.loads((next_checkpoint / "dmg-checkpoint.json").read_text())
                self.assertEqual(next_manifest["context"], current)
                self.assertEqual((next_checkpoint / "NexGenVideo.dmg").read_bytes(), dmg.read_bytes())
                second_responses, second_sources, second_job = self.notary_run(base / "second", 456, current,
                    manifest["appTreeSHA256"], next_checkpoint / "NexGenVideo.dmg", next_checkpoint / "plugins.tar.gz", restored=True)
                responses.update(second_responses)
                sources.update(second_sources)
                checkpoint.prepare_notary(456, base / "second-binding")
                second_job["steps"][1]["conclusion"] = "failure"
                with self.assertRaises(ValueError): checkpoint.prepare_notary(456, base / "bad-restore")
                (binding / "state.zip").write_bytes(b"tampered-state")
                with self.assertRaises(ValueError): checkpoint.restore_notary(binding)

    def test_release_stages_keep_all_acceptance_and_publication_guards(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        jobs = workflow["jobs"]
        for job in jobs.values():
            if "runs-on" in job and job["runs-on"] != "ubuntu-24.04":
                self.assertEqual(job["runs-on"], "macrunner")
            for key in ("env", "if", "runs-on", "timeout-minutes", "concurrency"):
                self.assertNotRegex(json.dumps(job.get(key)), r"\$\{\{[^}]*\b(?:runner|env|steps|job)\.", key)
        build = {step.get("name"): step for step in jobs["release-build"]["steps"]}
        package = {step.get("name"): step for step in jobs["release"]["steps"]}
        for name in ("Record signed build before notarization", "Retain signed build input", "Retain signed build proof"):
            self.assertNotIn("if", build[name])
        names = [step.get("name") for step in jobs["release"]["steps"]]
        self.assertLess(names.index("Resolve version + mode"), names.index("Restore exact signed build"))
        self.assertIn('echo "NOTARY_STATE_DIR=$RUNNER_TEMP/release-notary-state" >> "$GITHUB_ENV"',
                      package["Resolve version + mode"]["run"])
        self.assertLess(names.index("Retain DMG before notarization"), names.index("Notarize and staple DMG"))
        self.assertEqual(names.index("Retain notarization submissions"), names.index("Notarize and staple DMG") + 1)
        for step in jobs["release"]["steps"][names.index("Retain notarization submissions") + 1:]:
            self.assertNotRegex(step.get("run", ""), r"notarize\.sh|bundle\.sh[^\n]*--notarize-")
        for name in ("Record DMG before notarization", "Retain DMG before notarization"):
            self.assertNotIn("if", package[name])
        self.assertEqual(package["Retain notarization submissions"]["if"], "always() && steps.signed-input.outcome == 'success'")
        self.assertTrue(package["Retain notarization submissions"]["with"]["path"].endswith("/*.json"))
        for name in ("Notarize and staple downloadable format packs", "Notarize and staple app", "Notarize and staple DMG"):
            self.assertEqual(package[name]["timeout-minutes"], 20)
        for name in ("Verify the exact DMG users install", "Transfer the verified installed DMG app for workspace acceptance",
                     "Bind the exact DMG for the external user journey", "Notarize and staple DMG"):
            self.assertNotIn("if", package[name])
            self.assertNotIn("continue-on-error", package[name])
        for name in ("bpy-runtime", "diagnostic-acceptance", "external-user-acceptance"):
            self.assertEqual(jobs[name]["needs"], "release")
            self.assertTrue(condition_enabled(jobs[name].get("if"), True, True))
        self.assertEqual(active_publication_steps(workflow, True, True), [])
        self.assertEqual(active_publication_steps(workflow, True, True, resumed=True), [])


if __name__ == "__main__":
    unittest.main()
