import hashlib
import json
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs/production-knowledge/ai-film-production-3.1.1"
RUNTIME = ROOT / "Engine/Sources/NexGenEngine/Resources/ProductionKnowledge"


class ProductionKnowledgeMaterializationTests(unittest.TestCase):
    def read(self, path):
        return json.loads(path.read_text())

    def test_every_section_has_an_effective_runtime_disposition(self):
        ledger = self.read(SOURCE / "runtime-ledger.json")["sections"]
        contracts = {item["id"]: item for item in self.read(SOURCE / "application-contracts.json")}

        self.assertEqual(len(ledger), 254)
        self.assertEqual(sum(len(item["units"]) for item in ledger), 631)
        for item in ledger:
            contract = contracts[item["applicationContract"]]
            expected = "provenance-only" if contract["id"] == "packaging" else "runtime-active"
            self.assertEqual(item["consumerStatus"], expected)
            self.assertEqual(item["runtimeConsumers"], contract["runtimeConsumers"])
            self.assertTrue(item["activation"])
            self.assertTrue(item["verification"])
            self.assertTrue(item["disposition"])
            self.assertNotIn("pending", json.dumps(item).lower())

        index = self.read(SOURCE / "index.json")
        self.assertEqual(
            {item["id"]: item["runtimeStatus"] for item in index},
            {item["sectionID"]: item["consumerStatus"] for item in ledger},
        )

    def test_runtime_libraries_are_complete_and_phase_scoped(self):
        manifest = self.read(RUNTIME / "manifest.json")
        resources = {
            item["id"]: item
            for item in manifest["resources"]
            if item["id"].startswith("film-production-")
        }
        self.assertEqual(len(resources), 21)
        self.assertIn("film-production-blueprints", resources)

        total = 0
        libraries = {}
        for resource_id, resource in resources.items():
            path = RUNTIME / resource["path"]
            data = path.read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), resource["sha256"])
            library = json.loads(data)
            libraries[resource_id] = library
            total += len(library["entries"])
        self.assertEqual(total, 296)
        self.assertEqual(len(libraries["film-production-blueprints"]["entries"]), 42)
        self.assertEqual(len(libraries["film-production-genre-baselines"]["entries"]), 15)

        workflows = {
            item["id"]: item
            for item in libraries["film-production-workflows"]["entries"]
        }
        self.assertNotIn("brief", workflows["workflows-0979effa719d"]["applicability"]["phases"])
        self.assertIn("review", workflows["workflows-0979effa719d"]["applicability"]["phases"])
        self.assertIn("analysis", workflows["workflows-4d964bcaead8"]["applicability"]["phases"])
        self.assertNotIn("render", libraries["film-production-readme"]["applicability"]["phases"])

    def test_authoring_bundle_integrity(self):
        result = subprocess.run(
            ["python3", str(SOURCE / "validate_corpus.py")],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
