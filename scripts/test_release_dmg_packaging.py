import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import unittest
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
        for mutation in (None, "missing", "bytes", "mode", "signature"):
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
                        if mutation == "bytes": (mounted / "Contents/MacOS/NexGenVideo").write_bytes(b"truncated")
                        if mutation == "mode": (mounted / "Contents/MacOS/NexGenVideo").chmod(0o700)
                    if args[0] == "codesign" and mutation == "signature" and args[-1] != str(app):
                        raise subprocess.CalledProcessError(1, args)
                with patch.object(dmg_copy, "command", side_effect=command):
                    if mutation:
                        with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                            dmg_copy.verify(app, image)
                    else:
                        result = dmg_copy.verify(app, image)
                        self.assertEqual(result["sourceAppTreeSHA256"], result["mountedAppTreeSHA256"])
                        self.assertIs(result["deepSignaturesVerified"], True)
                self.assertTrue(any(args[:2] == ("hdiutil", "detach") for args in calls))
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

    def test_signing_preflight_keeps_normal_mode_and_scoped_probe(self):
        text = (ROOT / ".github/workflows/signing-preflight.yml").read_text()
        workflow = yaml.safe_load(text)
        for trigger in ("workflow_dispatch", "workflow_call"):
            definition = workflow[True][trigger]["inputs"]["dmg_copy_probe"]
            self.assertEqual(definition["type"], "boolean")
            self.assertIs(definition["default"], False)
        jobs = workflow["jobs"]
        self.assertEqual(jobs["preflight"]["if"], "${{ !inputs.dmg_copy_probe }}")
        self.assertEqual(jobs["dmg-copy-probe"]["runs-on"], "macrunner")
        self.assertEqual(jobs["dmg-copy-probe"]["needs"], "source")
        self.assertEqual(jobs["dmg-copy-probe"]["timeout-minutes"], 15)
        native = "\n".join(step.get("run", "") for step in jobs["dmg-copy-probe"]["steps"])
        self.assertIn("release_dmg_probe.py inspect", native)
        self.assertNotRegex(native, r"swift build|xcodebuild|notarytool|--sign|NexGenVideo/Contents/MacOS")
        self.assertNotIn("secrets.", json.dumps(jobs["dmg-copy-probe"]))
        source = (ROOT / "scripts/release_dmg_probe.py").read_text()
        self.assertNotRegex(source, r"swift build|xcodebuild|notarytool|--sign")
        self.assertIn("notarizationSubmitted=False", source)


if __name__ == "__main__":
    unittest.main()
