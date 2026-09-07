import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from analyze_hang_diagnostics import analyze


class DiagnosticAnalysisTests(unittest.TestCase):
    def test_checksums_and_unfinished_operation(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            name = "events-000000000001.json"
            data = json.dumps([dict(sequence=1, uptime=1, operation="markdown", correlation=0, end=False, values=[])]).encode()
            (folder / name).write_bytes(data)
            (folder / "checksums.json").write_text(json.dumps({name: hashlib.sha256(data).hexdigest()}))
            report = analyze(folder)
            self.assertEqual(report["unfinishedOperations"][0]["operation"], "markdown")
            (folder / name).write_bytes(b"[]")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                analyze(folder)

    def test_export_path_cannot_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / "export"
            folder.mkdir()
            (folder.parent / "outside").write_bytes(b"private")
            (folder / "checksums.json").write_text(json.dumps({"../outside": "unused"}))
            with self.assertRaisesRegex(ValueError, "escapes export"):
                analyze(folder)
