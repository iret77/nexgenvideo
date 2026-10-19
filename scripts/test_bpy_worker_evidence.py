import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from uuid import uuid4

from bpy_worker_evidence import validate


class WorkerEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.exits = [{
            "exitCode": code,
            "source": f"import os\nos.write(1, b'UNTRUSTED_EXIT_REACHED\\n')\nos._exit({code})",
            "response": {"ok": True, "jobID": str(uuid4()), "state": "failed", "outputs": [],
                         "message": f"worker reported exit {code} without an observed resource limit",
                         "stdout": "UNTRUSTED_EXIT_REACHED\n", "jobFingerprint": str(code % 10) * 64},
        } for code in (71, 72)]
        self.result = {"schema": "nexgenvideo/bpy-runtime-acceptance/2",
                       "untrustedExitEvidenceFile": "native-untrusted-exits.json",
                       "rlimitASAllocationDenied": True, "outOfMemoryState": "failed"}

    def write(self):
        data = json.dumps(self.exits).encode()
        (self.directory / "native-untrusted-exits.json").write_bytes(data)
        self.result["untrustedExitEvidenceSHA256"] = hashlib.sha256(data).hexdigest()
        (self.directory / "result.json").write_text(json.dumps(self.result))

    def test_controls(self):
        self.write()
        self.assertEqual(validate(self.directory)["untrustedExits"], [71, 72])

    def test_native_limit_claim_missing_marker_duplicate_job_and_wrong_source_fail(self):
        for change in (lambda: self.exits[0]["response"].update(state="resourceLimited"),
                       lambda: self.exits[0]["response"].update(stdout=""),
                       lambda: self.exits[1]["response"].update(jobID=self.exits[0]["response"]["jobID"]),
                       lambda: self.exits[0].update(source="raise MemoryError()"),
                       lambda: self.exits[0].update(exitCode=True),
                       lambda: self.result.update(rlimitASAllocationDenied=False)):
            with self.subTest(change=change):
                original_exits, original_result = json.dumps(self.exits), json.dumps(self.result)
                change()
                self.write()
                with self.assertRaises(ValueError):
                    validate(self.directory)
                self.exits, self.result = json.loads(original_exits), json.loads(original_result)

    def test_changed_retained_bytes_fail(self):
        self.write()
        (self.directory / "native-untrusted-exits.json").write_bytes(b"[]")
        with self.assertRaisesRegex(ValueError, "bytes"):
            validate(self.directory)


if __name__ == "__main__":
    unittest.main()
