import copy
import unittest

from pack_recovery_owner_acceptance import require_pack_pair
from prepare_settings_pack_artifacts import (
    PREVIEW_COMMIT, PREVIEW_PROFILE, PREVIEW_RELEASE, PREVIEW_SHA256,
    STABLE_PROFILE, baseline_assets, require_baseline,
)


class PublishedPackProfileTests(unittest.TestCase):
    def asset(self, version):
        return {"id": 12, "name": "musicvideo-" + version + ".ngvpack.zip", "created_at": "2026-10-18T12:00:00Z"}

    def test_default_keeps_newest_compatible_selection_and_explicit_stable_pin_does_not_fallback(self):
        release = {"tag_name": "plugins", "assets": [self.asset("0.5.0"), self.asset("0.5.8"), self.asset("0.5.9")]}
        self.assertEqual([a["name"] for a in baseline_assets(release, "0.6.0")],
                         ["musicvideo-0.5.9.ngvpack.zip", "musicvideo-0.5.8.ngvpack.zip", "musicvideo-0.5.0.ngvpack.zip"])
        self.assertEqual(baseline_assets(release, "0.6.0", requested_version="0.5.8"), [release["assets"][1]])
        release["assets"].pop(1)
        with self.assertRaises(ValueError):
            baseline_assets(release, "0.6.0", requested_version="0.5.8")

    def test_preview_requires_its_named_release_and_one_exact_original_version(self):
        release = {"tag_name": PREVIEW_RELEASE, "assets": [self.asset("0.5.8"), self.asset("0.5.16")]}
        self.assertEqual(baseline_assets(release, "0.6.0", PREVIEW_PROFILE), [release["assets"][1]])
        for defect in ("foreign-release", "missing", "duplicate", "substitute"):
            changed = copy.deepcopy(release)
            if defect == "foreign-release": changed["tag_name"] = "plugins"
            elif defect == "missing": changed["assets"].pop()
            elif defect == "duplicate": changed["assets"].append(self.asset("0.5.16"))
            with self.subTest(defect=defect), self.assertRaises(ValueError):
                baseline_assets(changed, "0.6.0", PREVIEW_PROFILE,
                                requested_version="0.5.8" if defect == "substitute" else None)

    def pair(self):
        baseline = {"id": "musicvideo", "version": "0.5.16", "projectSchema": "musicvideo/2.0.0",
                    "minAppVersion": "1.7.2", "engineContract": 11, "infoSHA256": "1" * 64,
                    "zipPath": "/synthetic/original-preview.zip"}
        target = {"id": "musicvideo", "version": "0.6.0", "projectSchema": "musicvideo/3.0.0",
                  "engineContract": 12, "zipPath": "/synthetic/current.zip"}
        pair = {"schema": "actual-settings-pack-pair/v1", "baselineProfile": PREVIEW_PROFILE,
                "baseline": baseline, "target": target, "rewrittenBundleMetadata": False,
                "publishedBaselineSHA256": "sha256:" + PREVIEW_SHA256, "targetArchiveSHA256": "2" * 64,
                "publishedBaseline": {"repository": "iret77/nexgenvideo", "releaseTag": PREVIEW_RELEASE,
                    "releaseID": 11, "assetID": 12, "assetName": "musicvideo-0.5.16.ngvpack.zip",
                    "digest": "sha256:" + PREVIEW_SHA256, "sourceCommit": PREVIEW_COMMIT}}
        return pair, baseline, target

    def test_preview_pin_cannot_be_replaced_by_current_or_rewritten_metadata(self):
        _, baseline, _ = self.pair()
        require_baseline(PREVIEW_PROFILE, baseline, PREVIEW_SHA256)
        for field, value in (("version", "0.5.8"), ("projectSchema", "musicvideo/3.0.0"),
                             ("minAppVersion", "1.8.0"), ("engineContract", 12)):
            changed = {**baseline, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                require_baseline(PREVIEW_PROFILE, changed, PREVIEW_SHA256)
        with self.assertRaises(ValueError):
            require_baseline(PREVIEW_PROFILE, baseline, "0" * 64)

    def test_recovery_receipt_binds_actual_zips_profile_release_and_source(self):
        pair, baseline, target = self.pair()
        require_pack_pair(pair, baseline, target, PREVIEW_SHA256, "2" * 64, PREVIEW_PROFILE)
        changes = [("baselineProfile", STABLE_PROFILE), ("targetArchiveSHA256", "3" * 64),
                   ("rewrittenBundleMetadata", True), ("publishedBaselineSHA256", "sha256:" + "0" * 64)]
        for field, value in changes:
            changed = {**pair, field: value}
            with self.subTest(field=field), self.assertRaises(ValueError):
                require_pack_pair(changed, baseline, target, PREVIEW_SHA256, "2" * 64, PREVIEW_PROFILE)
        for field, value in (("releaseTag", "plugins"), ("sourceCommit", "0" * 40),
                             ("assetName", "musicvideo-0.5.8.ngvpack.zip"), ("repository", "foreign/repo"),
                             ("assetID", 0), ("releaseID", True), ("digest", "sha256:" + "0" * 64)):
            changed = copy.deepcopy(pair); changed["publishedBaseline"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                require_pack_pair(changed, baseline, target, PREVIEW_SHA256, "2" * 64, PREVIEW_PROFILE)
        for actual_baseline, actual_target in (({**baseline, "infoSHA256": "9" * 64}, target),
                                               (baseline, {**target, "version": "0.6.1"})):
            with self.assertRaises(ValueError):
                require_pack_pair(pair, actual_baseline, actual_target, PREVIEW_SHA256, "2" * 64, PREVIEW_PROFILE)


if __name__ == "__main__":
    unittest.main()
