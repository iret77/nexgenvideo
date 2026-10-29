import copy
import hashlib
import json
from pathlib import Path
import unittest

from verify_bpy_library_evidence import validate_library_evidence


class OfficialLibraryEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(__file__).resolve().parents[1]
        self.lock = json.loads((self.root / "Runtime/bpy/runtime-lock.json").read_text())
        self.payloads = {
            key: (self.root / item["path"]).read_bytes()
            for key, item in self.lock["bpyWheelLayout"]["officialLibraryEvidence"].items()
        }

    def evidence(self):
        return json.loads(self.payloads["correspondence"])

    def replace_evidence(self, evidence):
        self.payloads["correspondence"] = json.dumps(evidence).encode()
        self.lock["bpyWheelLayout"]["officialLibraryEvidence"]["correspondence"]["sha256"] = hashlib.sha256(
            self.payloads["correspondence"]
        ).hexdigest()

    def test_complete_evidence_matches_independent_record(self):
        records = {item["wheelPath"]: (item["sha256"], item["size"]) for item in self.evidence()["libraries"]}
        result = validate_library_evidence(self.lock, self.payloads, records)
        self.assertEqual(len(result["libraries"]), 43)

    def test_other_dependency_version_does_not_prove_this_family(self):
        lock = copy.deepcopy(self.lock)
        family = next(item for item in lock["bpyWheelLayout"]["candidateSourceFamilies"] if item["name"] == "SDL")
        family["version"] = "3.1.13.1"
        with self.assertRaisesRegex(ValueError, "native family"):
            validate_library_evidence(lock, self.payloads)

    def test_rehashed_pointer_cannot_substitute_other_bytes(self):
        evidence = self.evidence()
        item = evidence["libraries"][0]
        item["pointer"] = item["pointer"].replace(item["sha256"], "0" * 64)
        item["pointerSHA256"] = hashlib.sha256(item["pointer"].encode()).hexdigest()
        self.replace_evidence(evidence)
        with self.assertRaisesRegex(ValueError, "LFS pointer"):
            validate_library_evidence(self.lock, self.payloads)

    def test_duplicate_library_cannot_cover_missing_inventory(self):
        evidence = self.evidence()
        evidence["libraries"][-1] = evidence["libraries"][0]
        self.replace_evidence(evidence)
        with self.assertRaisesRegex(ValueError, "exact native inventory"):
            validate_library_evidence(self.lock, self.payloads)

    def test_wheel_record_is_checked_independently(self):
        records = {item["wheelPath"]: (item["sha256"], item["size"]) for item in self.evidence()["libraries"]}
        path = next(iter(records))
        records[path] = ("0" * 64, records[path][1])
        with self.assertRaisesRegex(ValueError, "wheel RECORD"):
            validate_library_evidence(self.lock, self.payloads, records)


if __name__ == "__main__":
    unittest.main()
