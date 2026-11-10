import json
import os
import plistlib
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import yaml

import release_dmg_probe as probe
import verify_dmg_copy as dmg_copy
import plan_dmg_capacity as sizing


ROOT = Path(__file__).resolve().parents[1]


class ReleaseDmgPackagingTests(unittest.TestCase):
    def test_compiled_dmg_keeps_all_app_mount_checks_and_requires_exact_pack_copy_admission(self):
        for rejected in (False, True):
            with self.subTest(rejected=rejected), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app, pack, dmg, guide = root / 'NexGenVideo.app', root / 'musicvideo.ngvpack', root / 'current.dmg', root / 'Install NexGenVideo.txt'
                app.mkdir(); pack.mkdir(); dmg.write_bytes(b'dmg'); guide.write_text('Reviewed guide')
                (app / 'app').write_bytes(b'current app'); (pack / 'pack').write_bytes(b'qualified pack')
                calls, copies = [], []

                def command(*args):
                    calls.append(args)
                    if args[:2] == ('hdiutil', 'attach'):
                        mount = Path(args[-1])
                        shutil.copytree(app, mount / app.name); shutil.copytree(pack, mount / pack.name)
                        shutil.copy2(guide, mount / guide.name)
                        (mount / '.DS_Store').write_bytes(b'layout'); (mount / '.background.png').write_bytes(b'branding')
                        (mount / 'Applications').symlink_to('/Applications')

                def admit(bundle, context, **kwargs):
                    copies.append((bundle, context, kwargs))
                    self.assertEqual(dmg_copy.tree_digest(bundle), dmg_copy.tree_digest(pack))
                    if rejected: raise ValueError('Changed copy or missing qualified parent')

                with patch.dict(os.environ, NGV_COMPILED_APP_RELEASE='true'), patch.object(dmg_copy, 'command', side_effect=command), \
                        patch('compiled_app_release.verify_pack_copy', side_effect=admit):
                    if rejected:
                        with self.assertRaises(ValueError): dmg_copy.verify(app, dmg, pack, guide)
                    else:
                        result = dmg_copy.verify(app, dmg, pack, guide)
                        self.assertEqual(result['sourceAppTreeSHA256'], result['mountedAppTreeSHA256'])
                self.assertEqual(len(copies), 1)
                self.assertEqual(copies[0][1:], ('dmg-copy', {'dmg': dmg}))
                self.assertTrue(any(row[:2] == ('hdiutil', 'verify') for row in calls))
                self.assertTrue(any(row[:2] == ('hdiutil', 'attach') for row in calls))
                self.assertTrue(any(row[:2] == ('hdiutil', 'detach') for row in calls))
                self.assertTrue(any(row[0] == 'codesign' and row[-1] == str(app) for row in calls))
                self.assertFalse(any(row[0] in ('codesign', 'xcrun') and row[-1].endswith('.ngvpack') for row in calls))

    def test_joint_dmg_capacity_and_layout_bind_the_external_pack_without_embedding_it_in_the_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, pack = root / 'NexGenVideo.app', root / 'musicvideo.ngvpack'
            guide = root / 'Install NexGenVideo.txt'
            guide.write_text('Install the app, then install the external format pack.')
            app.mkdir(); pack.mkdir()
            (app / 'app').write_bytes(b'app')
            (pack / 'pack').write_bytes(b'separately signed pack')
            geometry = {'freeBytes': 2**40, 'totalBytes': 2**40, 'blockBytes': 4096, 'imageBytes': 2**40 + 4096}
            with patch.object(sizing, 'measure', return_value=geometry):
                legacy = sizing.plan(app)
                joint = sizing.plan(app, pack, guide)
            self.assertGreater(joint['payloadBytes'], legacy['payloadBytes'])
            self.assertEqual(joint['schema'], 'release-dmg-capacity-plan/v2')
            self.assertEqual(joint['packPath'], str(pack.resolve()))
            self.assertEqual(joint['packTreeSHA256'], dmg_copy.tree_digest(pack))
            plan = root / 'capacity.json'
            plan.write_text(json.dumps(joint))
            with patch.dict(os.environ, DMG_APP=str(app), DMG_PACK=str(pack), DMG_GUIDE=str(guide), DMG_CAPACITY_PLAN=str(plan)):
                settings = runpy.run_path(str(ROOT / 'scripts/dmg-settings.py'))
                self.assertEqual(settings['files'], [str(app), str(pack), str(guide)])
                self.assertIn(pack.name, settings['icon_locations'])
                self.assertIn(guide.name, settings['icon_locations'])
                for change in ({'schema': 'release-dmg-capacity-plan/v1'}, {'packPath': str(app)}, {'packTreeSHA256': 'invalid'}):
                    plan.write_text(json.dumps({**joint, **change}))
                    with self.assertRaises(ValueError): runpy.run_path(str(ROOT / 'scripts/dmg-settings.py'))
            self.assertFalse(any(p.suffix == '.ngvpack' for p in app.rglob('*')))

    def test_joint_dmg_rejects_missing_changed_unsigned_or_unnotarized_external_pack(self):
        for mutation in (None, 'missing', 'bytes', 'symlink', 'signature', 'notarization', 'missing-guide', 'changed-guide'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app, pack, image = root / 'NexGenVideo.app', root / 'musicvideo.ngvpack', root / 'NexGenVideo.dmg'
                guide = root / 'Install NexGenVideo.txt'
                guide.write_text('Install the app, then install the external format pack.')
                app.mkdir(); pack.mkdir(); image.write_bytes(b'dmg')
                (app / 'app').write_bytes(b'app'); (pack / 'pack').write_bytes(b'original signed pack')
                def command(*args):
                    if args[:2] == ('hdiutil', 'attach'):
                        mounted = Path(args[-1])
                        shutil.copytree(app, mounted / app.name)
                        (mounted / '.DS_Store').write_bytes(b'layout')
                        (mounted / '.background.png').write_bytes(b'branding')
                        (mounted / 'Applications').symlink_to('/Applications')
                        if mutation != 'missing-guide':
                            (mounted / guide.name).write_bytes(b'changed' if mutation == 'changed-guide' else guide.read_bytes())
                        if mutation == 'symlink': (mounted / pack.name).symlink_to(pack, target_is_directory=True)
                        elif mutation != 'missing':
                            shutil.copytree(pack, mounted / pack.name)
                            if mutation == 'bytes': (mounted / pack.name / 'pack').write_bytes(b'changed')
                    if mutation == 'signature' and args[0] == 'codesign' and args[-1].endswith(pack.name):
                        raise subprocess.CalledProcessError(1, args)
                    if mutation == 'notarization' and args[:3] == ('xcrun', 'stapler', 'validate'):
                        raise subprocess.CalledProcessError(1, args)
                with patch.object(dmg_copy, 'command', side_effect=command):
                    if mutation:
                        with self.assertRaises((ValueError, subprocess.CalledProcessError)): dmg_copy.verify(app, image, pack, guide)
                    else:
                        result = dmg_copy.verify(app, image, pack, guide)
                        self.assertEqual(result['schema'], 'release-dmg-copy/v2')
                        self.assertEqual(result['sourcePackTreeSHA256'], result['mountedPackTreeSHA256'])
                        self.assertIn(pack.name, [row['name'] for row in result['volumeInventory']])
                        self.assertIn(guide.name, [row['name'] for row in result['volumeInventory']])

    def test_large_bundle_uses_apfs_and_verifies_copy_before_signing(self):
        with tempfile.TemporaryDirectory() as directory:
            plan_file = Path(directory) / "capacity.json"
            plan_file.write_text(json.dumps({"schema": "release-dmg-capacity-plan/v1", "capacityVerified": True,
                "appPath": "/example/NexGenVideo.app", "imageSizeSectors": 10000000}))
            with patch.dict(os.environ, DMG_APP="/example/NexGenVideo.app", DMG_CAPACITY_PLAN=str(plan_file)):
                settings = runpy.run_path(str(ROOT / "scripts/dmg-settings.py"))
                self.assertEqual(settings["size"], "10000000b")
                plan_file.write_text(json.dumps({"capacityVerified": False}))
                with self.assertRaises(ValueError): runpy.run_path(str(ROOT / "scripts/dmg-settings.py"))
        self.assertEqual(settings["filesystem"], "APFS")
        self.assertEqual(settings["format"], "UDZO")
        self.assertEqual(settings["files"], ["/example/NexGenVideo.app"])
        text = (ROOT / "scripts/bundle.sh").read_text()
        body = text.split("build_dmg() {", 1)[1].split("notarize_dmg() {", 1)[0]
        self.assertLess(body.index("plan_dmg_capacity.py"), body.index('"$DMGBUILD_BIN" -s'))
        self.assertLess(body.index('"$DMGBUILD_BIN" -s'), body.index("verify_dmg_copy.py"))
        self.assertLess(body.index("verify_dmg_copy.py"), body.index('codesign --force --timestamp'))
        self.assertIn('python3 "$ROOT/scripts/verify_dmg_copy.py" "$APP" "$DMG"', body)

    def test_dmg_verification_rejects_missing_changed_or_invalid_code(self):
        for mutation in (None, "missing", "bytes", "mode", "signature", ".DS_Store",
                         ".background.png", "Applications", "busy", "detachfailure"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = root / "NexGenVideo.app"
                (app / "Contents/MacOS").mkdir(parents=True)
                (app / "Contents/MacOS/NexGenVideo").write_bytes(b"complete-signed-app")
                image = root / "NexGenVideo.dmg"
                image.write_bytes(b"disk-image")
                calls = []
                def command(*args):
                    calls.append(args)
                    if args[:2] == ("hdiutil", "attach"):
                        mounted = Path(args[-1]) / app.name
                        if mutation != "missing": shutil.copytree(app, mounted)
                        for name in (".DS_Store", ".background.png"):
                            if mutation != name: (Path(args[-1]) / name).write_bytes(b"installer")
                        if mutation != "Applications": (Path(args[-1]) / "Applications").symlink_to("/Applications")
                        if mutation == "bytes": (mounted / "Contents/MacOS/NexGenVideo").write_bytes(b"truncated")
                        if mutation == "mode": (mounted / "Contents/MacOS/NexGenVideo").chmod(0o700)
                    if args[0] == "codesign" and mutation == "signature" and args[-1] != str(app):
                        raise subprocess.CalledProcessError(1, args)
                    if args[:2] == ("hdiutil", "detach") and (mutation == "detachfailure" or
                            mutation == "busy" and sum(c[:2] == ("hdiutil", "detach") for c in calls) <= 2):
                        raise subprocess.CalledProcessError(1, args)
                with patch.object(dmg_copy, "command", side_effect=command), patch.object(dmg_copy.time, "sleep"):
                    if mutation and mutation != "busy":
                        with self.assertRaises((ValueError, subprocess.CalledProcessError)) as error:
                            dmg_copy.verify(app, image)
                        if mutation in ("bytes", "mode", "missing"):
                            self.assertIn("Contents/MacOS/NexGenVideo", str(error.exception))
                            self.assertIn('"source":', str(error.exception))
                            self.assertIn('"mounted":', str(error.exception))
                    else:
                        result = dmg_copy.verify(app, image)
                        self.assertEqual(result["sourceAppTreeSHA256"], result["mountedAppTreeSHA256"])
                        self.assertIs(result["deepSignaturesVerified"], True)
                        self.assertIn("Applications", [entry["name"] for entry in result["volumeInventory"]])
                self.assertTrue(any(args[:2] == ("hdiutil", "detach") for args in calls))
                if mutation == "busy": self.assertEqual(sum(c[:2] == ("hdiutil", "detach") for c in calls), 3)
                if mutation == "detachfailure": self.assertEqual(calls[-1][:3], ("hdiutil", "detach", "-force"))
                self.assertTrue(all("--sign" not in args for args in calls))

    def test_probe_binds_existing_signed_payload_without_building(self):
        producer = {"id": probe.RUN, "head_sha": probe.SOURCE, "repository": {"full_name": "iret77/nexgenvideo"},
                    "actor": {"login": "iret77"}, "path": ".github/workflows/release.yml", "event": "workflow_dispatch",
                    "run_attempt": 1, "status": "completed", "conclusion": "failure"}
        job = {"name": "release-build", "head_sha": probe.SOURCE, "labels": ["macrunner"], "conclusion": "success",
               "run_id": probe.RUN, "run_attempt": 1, "status": "completed",
               "started_at": "2026-11-02T10:00:00Z", "completed_at": "2026-11-02T12:00:00Z",
               "steps": [{"name": name, "conclusion": "success"} for name in
                   ("Build and sign app", "Retain signed build input", "Retain signed build proof")]}
        jobs = {"total_count": 1, "jobs": [job]}
        artifact = {"id": probe.ARTIFACT, "name": "release-signed-input-" + probe.SOURCE,
                    "digest": "sha256:" + probe.DIGEST, "expired": False,
                    "workflow_run": {"id": probe.RUN, "head_sha": probe.SOURCE},
                    "created_at": "2026-11-02T11:00:00Z", "updated_at": "2026-11-02T11:00:01Z",
                    "expires_at": "2100-01-01T00:00:00Z"}
        self.assertEqual(probe.validate(producer, jobs, artifact), job)
        for key, value in (("head_sha", "b" * 40), ("run_attempt", 2), ("actor", {"login": "foreign"})):
            with self.subTest(key=key), self.assertRaises(ValueError):
                probe.validate(dict(producer, **{key: value}), jobs, artifact)
        for key, value in (("expired", True), ("id", 1), ("digest", "sha256:" + "0" * 64)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                probe.validate(producer, jobs, dict(artifact, **{key: value}))
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            source = base / "original/NexGenVideo.app"
            (source / "Contents/MacOS").mkdir(parents=True)
            info = {"CFBundleShortVersionString": "1.8.0", "CFBundleVersion": "105",
                    "NGVSourceCommit": probe.SOURCE, "NGVPluginCatalogURL": "https://example.test/catalog.json"}
            (source / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            (source / "Contents/MacOS/NexGenVideo").write_bytes(b"signed")
            app_zip = base / "App.zip"
            with zipfile.ZipFile(app_zip, "w") as archive:
                for file in source.rglob("*"):
                    archive.write(file, file.relative_to(source.parent))
            expected = probe.tree_digest(source)
            for mutation in (None, "tree", "identity", "background"):
                with self.subTest(inspect=mutation):
                    root = base / str(mutation)
                    root.mkdir()
                    manifest = {"appTreeSHA256": "0" * 64 if mutation == "tree" else expected,
                        "identity": dict(probe.identity(source.parent)), "files": {"NexGenVideo.zip": {
                            "bytes": app_zip.stat().st_size, "sha256": probe.checksum(app_zip)}}}
                    if mutation == "identity": manifest["identity"]["build"] = "999"
                    payload = base / (str(mutation) + ".zip")
                    with zipfile.ZipFile(payload, "w") as archive:
                        archive.writestr("manifest.json", json.dumps(manifest))
                        archive.write(app_zip, "NexGenVideo.zip")
                    signed_digest = probe.checksum(payload)
                    metadata = dict(artifact, digest="sha256:" + signed_digest, size_in_bytes=payload.stat().st_size)
                    (root / "binding.json").write_text(json.dumps({"schema": "release-dmg-probe-binding/v1",
                        "productSourceSHA": probe.SOURCE, "harnessSourceSHA": "a" * 40,
                        "producer": producer, "job": job}))
                    commands = []
                    def run(args, **kwargs):
                        commands.append(args)
                        self.assertEqual(kwargs["timeout"], probe.NATIVE_TIMEOUT)
                        if args[0] == "ditto": shutil.copytree(source, root / source.name)
                        if args[0] == "dmgbuild": (root / "NexGenVideo.dmg").write_bytes(b"complete")
                    is_file = Path.is_file
                    with patch.dict(os.environ, GITHUB_SHA="a" * 40, DMGBUILD_BIN="dmgbuild"), \
                         patch.object(probe, "DIGEST", signed_digest), patch.object(probe, "api", return_value=metadata), \
                         patch.object(probe, "download", side_effect=lambda _, dest: shutil.copyfile(payload, dest)), \
                         patch.object(probe, "verify_manifest", return_value=manifest), \
                         patch.object(probe.subprocess, "run", side_effect=run), \
                         patch.object(probe.subprocess, "check_output", return_value=json.dumps({"packages": {"dmgbuild": "1.6.7"}})), \
                         patch.object(probe, "plan", return_value={"capacityVerified": True}), \
                         patch.object(probe, "verify", return_value={"phaseSeconds": {}}), \
                         patch.object(Path, "is_file", autospec=True, side_effect=lambda p:
                             False if mutation == "background" and p.name == "dmg-background.png" else is_file(p)):
                        if mutation:
                            with self.assertRaises(ValueError): probe.inspect(root)
                            self.assertFalse(any(c[0] == "dmgbuild" for c in commands))
                            if mutation != "background": self.assertFalse(any(c[0] == "xcrun" for c in commands))
                        else:
                            probe.inspect(root)
                            result = json.loads((root / "report/result.json").read_text())
                            self.assertEqual(result["restoredAppTreeSHA256"], expected)
                            self.assertIs(result["qualified"], False)
                            self.assertTrue(any(c[:3] == ("xcrun", "stapler", "validate") for c in commands))
            measurement = base / "measurement"
            measurement.mkdir()
            commands = []
            def measure_run(args, **kwargs):
                commands.append(args)
                if list(args[:2]) == ["hdiutil", "create"]: Path(args[-1]).write_bytes(b"empty-image")
            with patch.dict(os.environ, GITHUB_SHA="a" * 40), patch.object(probe.subprocess, "run", side_effect=measure_run):
                probe.capacity(source, measurement)
            measured = json.loads((measurement / "report/capacity.json").read_text())
            self.assertEqual(measured["restoredAppTreeSHA256"], expected)
            self.assertEqual(measured["fileCount"], 2)
            self.assertIs(measured["copyPerformed"], False)
            self.assertIs(measured["qualified"], False)
            self.assertFalse(any(args[0] in ("ditto", "dmgbuild", "xcrun") for args in commands))

    def test_capacity_planner_preserves_real_free_space_reserve(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "NexGenVideo.app"
            app.mkdir()
            with (app / "payload").open("wb") as payload: payload.truncate(500 * 1024**2)
            overhead = 209753600 + 12197888
            def measure(sectors):
                return {"freeBytes": sectors * 512 - overhead, "totalBytes": sectors * 512,
                        "imageBytes": sectors * 512, "blockBytes": 4096}
            with patch.object(sizing, "measure", side_effect=measure) as measured:
                result = sizing.plan(app)
            self.assertTrue(result["capacityVerified"])
            self.assertEqual(result["reserveBytes"], 128 * 1024**2)
            self.assertEqual(len(result["attempts"]), measured.call_count)
            self.assertEqual(measured.call_count, 2)
            self.assertGreaterEqual(result["attempts"][-1]["freeBytes"], result["payloadBytes"] + result["reserveBytes"])
            self.assertEqual(result["imageSizeSectors"], result["attempts"][-1]["requestedSectors"])

    def test_capacity_planner_fails_closed_when_volume_does_not_grow(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "NexGenVideo.app"
            app.mkdir()
            with patch.object(sizing, "measure", return_value={"freeBytes": 0, "totalBytes": 4096,
                    "blockBytes": 4096, "imageBytes": 8192}) as measured:
                with self.assertRaisesRegex(ValueError, "did not reach"):
                    sizing.plan(app)
            self.assertLessEqual(measured.call_count, 8)
            sizes = [call.args[0] for call in measured.call_args_list]
            self.assertGreater(len(sizes), 1)
            self.assertTrue(all(after > before for before, after in zip(sizes, sizes[1:])))

    def test_capacity_planner_outgrows_measured_apfs_metadata_tail(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "NexGenVideo.app"
            app.mkdir()
            with (app / "payload").open("wb") as payload: payload.truncate(500 * 1024**2)
            overheads = [221843456, 222261248, 222277632]
            calls = []
            def measure(sectors):
                index = len(calls)
                overhead = overheads[min(index, 2)] + max(0, index - 2) * 16384
                calls.append(sectors)
                return {"freeBytes": sectors * 512 - overhead, "totalBytes": sectors * 512 - 209753600,
                        "imageBytes": sectors * 512, "blockBytes": 4096}
            with patch.object(sizing, "measure", side_effect=measure):
                result = sizing.plan(app)
            self.assertGreaterEqual(result["attempts"][-1]["freeBytes"], result["requiredFreeBytes"])
            self.assertEqual(result["reserveBytes"], 128 * 1024**2)
            self.assertTrue(all(attempt["freeBytes"] < result["requiredFreeBytes"] for attempt in result["attempts"][:-1]))
            self.assertLessEqual(len(calls), 8)

    def test_capacity_planner_rejects_invalid_measured_volume(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "NexGenVideo.app"
            app.mkdir()
            valid = {"freeBytes": 4096, "totalBytes": 8192, "blockBytes": 4096, "imageBytes": 16384}
            for key, value in [("freeBytes", -1), ("freeBytes", True), ("freeBytes", 12288),
                               ("totalBytes", 32768), ("blockBytes", 0), ("imageBytes", 0)]:
                with self.subTest(key=key, value=value), patch.object(sizing, "measure", return_value=valid | {key: value}), \
                        self.assertRaisesRegex(ValueError, "Invalid DMG capacity measurement"):
                    sizing.plan(app)

    def test_signing_preflight_keeps_normal_mode_and_scoped_probe(self):
        text = (ROOT / ".github/workflows/signing-preflight.yml").read_text()
        workflow = yaml.safe_load(text)
        for trigger in ("workflow_dispatch", "workflow_call"):
            definition = workflow[True][trigger]["inputs"]["dmg_copy_probe"]
            self.assertEqual(definition["type"], "boolean")
            self.assertIs(definition["default"], False)
            self.assertEqual(workflow[True][trigger]["inputs"]["dmg_probe_mode"]["default"], "copy")
        jobs = workflow["jobs"]
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertNotIn("permissions", jobs["preflight"])
        for name in ("source", "dmg-copy-probe"):
            self.assertEqual(jobs[name]["permissions"], {"contents": "read", "actions": "read"})
        self.assertEqual(jobs["preflight"]["if"], "${{ !inputs.dmg_copy_probe }}")
        self.assertEqual(jobs["dmg-copy-probe"]["runs-on"], "macrunner")
        self.assertEqual(jobs["dmg-copy-probe"]["needs"], "source")
        self.assertEqual(jobs["dmg-copy-probe"]["timeout-minutes"], 15)
        steps = jobs["dmg-copy-probe"]["steps"]
        uses = [step.get("uses") for step in steps]
        selected = uses.index("./.github/actions/setup-native-test-python")
        self.assertLess(selected, uses.index("./.github/actions/setup-xcode-27"))
        self.assertLess(selected, next(i for i, s in enumerate(steps) if s.get("name") == "Prepare pinned DMG tooling"))
        native = "\n".join(step.get("run", "") for step in jobs["dmg-copy-probe"]["steps"])
        self.assertIn("release_dmg_probe.py inspect", native)
        forbidden = r"swift build|xcodebuild|notarytool|--sign|NexGenVideo\.app/Contents/MacOS|Contents/MacOS/"
        self.assertNotRegex(native, forbidden)
        self.assertNotIn("secrets.", json.dumps(jobs["dmg-copy-probe"]))
        source = (ROOT / "scripts/release_dmg_probe.py").read_text()
        self.assertNotRegex(source, forbidden)
        gate = (ROOT / "scripts/verify_dmg_copy.py").read_text()
        self.assertNotRegex(gate, forbidden)
        self.assertEqual(probe.NATIVE_TIMEOUT, dmg_copy.NATIVE_TIMEOUT)
        self.assertEqual(probe.NATIVE_TIMEOUT, 900)
        self.assertIn("timeout=NATIVE_TIMEOUT", source)
        self.assertIn("timeout=NATIVE_TIMEOUT", gate)
        self.assertNotIn("180", source + gate)
        self.assertIn("notarizationSubmitted=False", source)


if __name__ == "__main__":
    unittest.main()
