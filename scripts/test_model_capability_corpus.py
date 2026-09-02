import json
import re
import unittest
from pathlib import Path
from urllib.parse import urlparse

from scripts import model_capability_corpus as generator


ROOT = Path(__file__).resolve().parents[1]
CORPUS_PATH = (
    ROOT
    / "Sources/NexGenVideo/Resources/ModelCapabilities/model-capability-corpus-v1.json"
)


class ModelCapabilityCorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.corpus = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))
        cls.rows = generator.coverage_rows(cls.corpus)

    def profile(self, family, variant, version, modality):
        identity = {
            "family_id": family,
            "variant_id": variant,
            "version_id": version,
            "modality": modality,
        }
        return next(
            profile
            for profile in self.corpus["knowledge_base"]["profiles"]
            if profile["identity"] == identity
        )

    @staticmethod
    def field(profile, field_id):
        for bucket in profile["fields"].values():
            if field_id in bucket:
                return bucket[field_id]
        raise AssertionError(f"missing field {field_id}: {profile['identity']}")

    def test_generated_corpus_and_report_are_current(self):
        rendered = generator.rendered()
        for path, expected in rendered.items():
            self.assertEqual(path.read_text(encoding="utf-8"), expected)

    def test_every_offline_registry_and_checked_in_catalog_id_is_classified(self):
        inventory = self.corpus["inventory"]
        classified = {entry["catalog_model_id"] for entry in inventory}
        offline = {
            entry["catalog_model_id"]
            for entry in inventory
            if "offline_registry" in entry["origins"]
        }

        registry_calls = {
            "Sources/NexGenVideo/Generation/Providers/FalModelRegistry.swift": (
                "image",
                "imageEdit",
                "video",
                "videoRef",
                "videoRange",
                "audio",
                "upscale",
            ),
            "Sources/NexGenVideo/Generation/Providers/RunwayModelRegistry.swift": (
                "image",
                "video",
                "videoEdit",
            ),
            "Sources/NexGenVideo/Generation/Providers/MarbleModelRegistry.swift": (
                "world",
            ),
        }
        for relative_path, calls in registry_calls.items():
            source = (ROOT / relative_path).read_text(encoding="utf-8")
            pattern = rf"\b(?:{'|'.join(calls)})\(\s*\"([^\"]+)\""
            identifiers = set(re.findall(pattern, source))
            self.assertGreater(len(identifiers), 0, relative_path)
            self.assertEqual(identifiers - offline, set(), relative_path)

        google_source = (
            ROOT / "Sources/NexGenVideo/Generation/Providers/GoogleModelRegistry.swift"
        ).read_text(encoding="utf-8")
        google_ids = set(re.findall(r'\bid:\s*"([^"]+)"', google_source))
        self.assertEqual(google_ids - offline, set())

        catalog_ids = {
            entry["id"]
            for entry in json.loads((ROOT / "catalog/models.json").read_text())
        }
        self.assertEqual(catalog_ids - classified, set())
        for catalog_id in catalog_ids:
            self.assertTrue(
                any(
                    entry["catalog_model_id"] == catalog_id
                    and "catalog/models.json" in entry["origins"]
                    for entry in inventory
                )
            )

    def test_coverage_is_complete_and_provider_aliases_are_canonical(self):
        counts = {
            resolution: sum(
                row["actual_resolution"] == resolution for row in self.rows
            )
            for resolution in ("exact", "inherited", "defensive")
        }
        self.assertEqual(len(self.rows), 87)
        self.assertEqual(
            counts,
            {"exact": 75, "inherited": 1, "defensive": 11},
        )
        self.assertTrue(
            all(row["actual_resolution"] == row["expected_resolution"] for row in self.rows)
        )
        self.assertEqual(
            len({row["provider_qualified_alias"] for row in self.rows}),
            len(self.rows),
        )
        for row in self.rows:
            self.assertEqual(
                row["provider_qualified_alias"],
                f"{row['provider']}::{row['provider_model_id']}",
            )

        aliases = {
            entry["catalog_model_id"]: entry["identity"]
            for entry in self.corpus["knowledge_base"]["aliases"]
        }
        for row in self.rows:
            if row["expected_resolution"] != "exact":
                continue
            expected_identity = {
                "family_id": row["family_id"],
                "variant_id": row["variant_id"],
                "version_id": row["version_id"],
                "modality": row["modality"],
            }
            for alias in (
                row["catalog_model_id"],
                row["provider_model_id"],
                row["provider_qualified_alias"],
            ):
                self.assertEqual(aliases[alias], expected_identity)

    def test_seedance_2_5_keeps_hard_limits_separate_from_reliable_capacity(self):
        profile = self.profile("seedance", "reference-to-video", "2.5", "video")
        expected_limits = {
            "video.reference_images": 30,
            "video.reference_videos": 10,
            "video.reference_audios": 10,
            "video.total_references": 50,
        }
        for field_id, expected in expected_limits.items():
            field = self.field(profile, field_id)
            self.assertEqual(field["value"], expected)
            self.assertEqual(field["semantics"], "hard_api_limit")
        self.assertEqual(
            self.field(profile, "common.resolutions")["value"],
            ["480p", "720p"],
        )
        visible = self.field(profile, "video.visible_characters")
        self.assertEqual(visible["value"], 5)
        self.assertEqual(visible["semantics"], "reliable_capacity")
        self.assertTrue(
            all(evidence["kind"] == "empirical" for evidence in visible["evidence"])
        )

    def test_minimax_h3_uses_published_capacity_without_inventing_figure_count(self):
        profile = self.profile("minimax-h3", "ref2va", "3", "video")
        expected_limits = {
            "video.reference_images": 9,
            "video.reference_videos": 3,
            "video.reference_audios": 3,
            "video.total_references": 12,
        }
        for field_id, expected in expected_limits.items():
            field = self.field(profile, field_id)
            self.assertEqual(field["value"], expected)
            self.assertEqual(field["semantics"], "hard_api_limit")
        present_fields = set().union(
            *(set(bucket) for bucket in profile["fields"].values())
        )
        self.assertNotIn("video.visible_characters", present_fields)
        gaps = next(
            entry["fields"]
            for entry in self.corpus["profile_gaps"]
            if entry["identity"] == profile["identity"]
        )
        self.assertIn("video.visible_characters", gaps)
        self.assertIn("No primary source", gaps["video.visible_characters"])

    def test_future_and_unknown_fixtures_are_explicitly_conservative(self):
        fixtures = {
            entry["catalog_model_id"]: entry
            for entry in self.corpus["inventory"]
            if entry["fixture"]
        }
        self.assertEqual(
            fixtures["fixture/seedance-3.0/reference-to-video"]["expected_resolution"],
            "inherited",
        )
        self.assertEqual(
            fixtures["fixture/hupfntrupfn"]["expected_resolution"],
            "defensive",
        )
        self.assertTrue(all(entry["availability"] == "research-needed" for entry in fixtures.values()))

    def test_stale_and_conflicting_evidence_remain_visible(self):
        self.assertEqual(sum(row["stale"] for row in self.rows), 3)
        self.assertEqual(sum(row["conflicting"] for row in self.rows), 4)
        self.assertTrue(all(row["research_needed"] for row in self.rows if row["stale"] or row["conflicting"]))
        report = generator.REPORT_PATH.read_text(encoding="utf-8")
        self.assertIn("| Stale | Conflicting | Research-needed | Unclassified |", report)
        self.assertIn("| 87 | 85 | 75 | 1 | 11 | 3 | 4 |", report)

    def test_field_evidence_is_primary_dated_and_confident(self):
        primary_titles = {
            source["title"] for source in self.corpus["sources"] if source["primary"]
        }
        for profile in self.corpus["knowledge_base"]["profiles"]:
            for bucket in profile["fields"].values():
                for field in bucket.values():
                    self.assertGreater(len(field["evidence"]), 0)
                    self.assertTrue(
                        any(
                            evidence["source_title"] in primary_titles
                            for evidence in field["evidence"]
                        )
                    )
                    for evidence in field["evidence"]:
                        self.assertRegex(evidence["observed_at"], r"^\d{4}-\d{2}-\d{2}$")
                        self.assertGreaterEqual(evidence["confidence"], 0)
                        self.assertLessEqual(evidence["confidence"], 1)

    def test_confirmed_defensive_numeric_policy_is_data(self):
        defaults = self.corpus["defensive_defaults"]
        self.assertEqual(defaults["owner_confirmation"], "confirmed")
        self.assertEqual(
            defaults["table"],
            {
                "character_and_primary_reference_counts": 1,
                "image_outputs_per_request": 1,
                "other_integer_counts": 0,
                "duration_minimum_seconds": 0,
                "duration_maximum_seconds": 30,
                "booleans": False,
                "sets": [],
            },
        )

    def test_inventory_research_uses_free_metadata_only(self):
        generator_source = Path(generator.__file__).read_text(encoding="utf-8")
        self.assertNotRegex(
            generator_source,
            r"\b(?:requests|urlopen|subprocess|fal_client|queue\.submit)\b",
        )
        for source in self.corpus["sources"]:
            if not source["url"]:
                continue
            parsed = urlparse(source["url"])
            if parsed.netloc == "api.fal.ai":
                self.assertEqual(parsed.path, "/v1/models")
                self.assertIn("endpoint_id=", parsed.query)
        unavailable = {
            entry["provider"] for entry in self.corpus["unavailable_inventories"]
        }
        self.assertEqual(unavailable, {"higgsfield", "openart"})


if __name__ == "__main__":
    unittest.main()
