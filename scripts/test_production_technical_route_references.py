"""Synthetic route-reference controls; these are not native acceptance evidence."""
import json
from pathlib import Path
import tempfile
import unittest

from production_technical_owner_evidence import digest, snapshot
from test_production_technical_owner_evidence import encoded, technical_fixture


class TechnicalRouteReferenceTests(unittest.TestCase):
    def test_unbound_header_route_is_refused_after_rehash(self):
        for artifact in ("promotion", "decodedProjection"):
            with self.subTest(artifact=artifact), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                native = {"interactions": [], "screenshots": []}
                row = technical_fixture(root, native)["before"]
                snapshot(root, row, "before", "first-shot")
                relative = "routes/unbound.json"
                name = "technical-before/" + relative
                data = encoded({"shot_id": "unbound-shot", "offering": {"catalog_model_id": "other-model"}})
                (root / name).write_bytes(data)
                row["files"][name] = digest(data)
                path = row[artifact]
                value = json.loads((root / path).read_bytes())
                value["header"]["inputs"].append({"id": "unbound-route", "path": relative,
                    "role": "core.production-route", "sha256": digest(data)})
                data = encoded(value)
                (root / path).write_bytes(data)
                row["files"][path] = digest(data)
                with self.assertRaisesRegex(ValueError, "route references differ from their bindings"):
                    snapshot(root, row, "before", "first-shot")

    def test_bound_route_missing_from_both_headers_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = {"interactions": [], "screenshots": []}
            row = technical_fixture(root, native)["before"]
            snapshot(root, row, "before", "first-shot")
            promotion = json.loads((root / row["promotion"]).read_bytes())
            omitted = promotion["routes"][0]["route"]["path"]
            for artifact in ("promotion", "decodedProjection"):
                path = row[artifact]
                value = json.loads((root / path).read_bytes())
                value["header"]["inputs"] = [reference for reference in value["header"]["inputs"]
                    if reference["path"] != omitted]
                data = encoded(value)
                (root / path).write_bytes(data)
                row["files"][path] = digest(data)
            with self.assertRaisesRegex(ValueError, "route references differ from their bindings"):
                snapshot(root, row, "before", "first-shot")
