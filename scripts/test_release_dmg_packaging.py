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


ROOT = Path(__file__).resolve().parents[1]


class ReleaseDmgPackagingTests(unittest.TestCase):
    def test_large_bundle_uses_apfs_and_verifies_copy_before_signing(self):
        with patch.dict(os.environ, DMG_APP="/example/NexGenVideo.app"):
            settings = runpy.run_path(str(ROOT / "scripts/dmg-settings.py"))
        self.assertEqual(settings["filesystem"], "APFS")
        self.assertEqual(settings["format"], "UDZO")
        self.assertEqual(settings["files"], ["/example/NexGenVideo.app"])
        text = (ROOT / "scripts/bundle.sh").read_text()
        body = text.split("build_dmg() {", 1)[1].split("notarize_dmg() {", 1)[0]
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

    def test_signing_preflight_keeps_normal_mode_and_scoped_probe(self):
        text = (ROOT / ".github/workflows/signing-preflight.yml").read_text()
        workflow = yaml.safe_load(text)
        for trigger in ("workflow_dispatch", "workflow_call"):
            definition = workflow[True][trigger]["inputs"]["dmg_copy_probe"]
            self.assertEqual(definition["type"], "boolean")
            self.assertIs(definition["default"], False)
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
