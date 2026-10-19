import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

from assemble_bpy_source_closure import AssemblyProgress, fetch


class Response(io.BytesIO):
    def __init__(self, data, length=None):
        super().__init__(data)
        self.headers = {"Content-Length": str(len(data) if length is None else length)}


class SourceDownloadTests(unittest.TestCase):
    def test_public_source_request_identifies_client_without_changing_url(self):
        url = "https://download.blender.org/source/blender-5.2.2.tar.xz"
        data = b"pinned source bytes"
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "source.tar"
            with patch("assemble_bpy_source_closure.urllib.request.urlopen", return_value=Response(data)) as download:
                fetch(url, destination, hashlib.sha256(data).hexdigest())
            request = download.call_args.args[0]
            self.assertEqual(request.full_url, url)
            self.assertEqual(request.get_method(), "GET")
            self.assertEqual(request.get_header("User-agent"),
                             "NexGenVideo-source-closure/1 (+https://github.com/iret77/nexgenvideo)")
            self.assertIsNone(request.data)
            self.assertEqual(download.call_args.kwargs, {"timeout": 120})
            self.assertEqual(destination.read_bytes(), data)

    def test_only_transient_failure_retries_before_verified_publish(self):
        data = b"actual pinned source"
        digest = hashlib.sha256(data).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "source.tar"
            with patch("assemble_bpy_source_closure.urllib.request.urlopen", side_effect=[
                urllib.error.HTTPError("https://example.test/source", 503, "Unavailable", {}, None),
                Response(data),
            ]) as download, patch("assemble_bpy_source_closure.time.sleep") as sleep:
                result = fetch("https://example.test/source", destination, digest)
            self.assertEqual(download.call_count, 2)
            sleep.assert_called_once_with(5)
            self.assertEqual(destination.read_bytes(), data)
            self.assertEqual(result, {"sha256": digest, "size": len(data)})
            self.assertFalse(destination.with_name("source.tar.partial").exists())

    def test_missing_source_and_hash_drift_do_not_retry_or_replace_verified_file(self):
        for response in [urllib.error.HTTPError("https://example.test/source", 404, "Not Found", {}, None),
                         Response(b"changed upstream bytes")]:
            with self.subTest(response=response), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory) / "source.tar"
                destination.write_bytes(b"previous verified source")
                with patch("assemble_bpy_source_closure.urllib.request.urlopen", side_effect=[response]) as download, \
                        patch("assemble_bpy_source_closure.time.sleep") as sleep:
                    with self.assertRaises((urllib.error.HTTPError, ValueError)):
                        fetch("https://example.test/source", destination, hashlib.sha256(b"expected").hexdigest())
                self.assertEqual(download.call_count, 1)
                sleep.assert_not_called()
                self.assertEqual(destination.read_bytes(), b"previous verified source")

    def test_truncated_transfer_retries_and_repeated_timeout_stops(self):
        data = b"complete"
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "source.tar"
            with patch("assemble_bpy_source_closure.urllib.request.urlopen", side_effect=[
                Response(b"truncated", length=100), Response(data),
            ]) as download, patch("assemble_bpy_source_closure.time.sleep"):
                fetch("https://example.test/source", destination, hashlib.sha256(data).hexdigest())
                self.assertEqual(download.call_count, 2)
            with patch("assemble_bpy_source_closure.urllib.request.urlopen", side_effect=TimeoutError()) as download, \
                    patch("assemble_bpy_source_closure.time.sleep") as sleep:
                with self.assertRaises(TimeoutError):
                    fetch("https://example.test/source", destination, hashlib.sha256(data).hexdigest())
                self.assertEqual(download.call_count, 3)
                self.assertEqual(sleep.call_count, 2)
            self.assertEqual(destination.read_bytes(), data)

    def test_failed_progress_preserves_exact_completed_sources_without_distribution_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = b'{"pinned":"actual source"}\n'
            sources = [{"component": "wheel:bpy", "sha256": "a" * 64, "size": 123}]
            with self.assertRaisesRegex(ValueError, "missing notice"):
                with AssemblyProgress(root, lock) as progress:
                    progress.update(stage="distribution-evidence", completedSources=sources)
                    raise ValueError("missing notice")
            result = json.loads((root / "assembly-progress.json").read_text())
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["stage"], "distribution-evidence")
            self.assertEqual(result["completedSources"], sources)
            self.assertEqual(result["runtimeLockSHA256"], hashlib.sha256(lock).hexdigest())
            self.assertFalse(result["publicDistributionAuthorized"])

    def test_completed_assembly_does_not_authorize_distribution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with AssemblyProgress(root, b"{}") as progress:
                progress.update(stage="archive-written", noticeComplete=False, correspondenceComplete=False)
            result = json.loads((root / "assembly-progress.json").read_text())
            self.assertEqual(result["status"], "assembled")
            self.assertFalse(result["noticeComplete"])
            self.assertFalse(result["correspondenceComplete"])
            self.assertFalse(result["publicDistributionAuthorized"])


if __name__ == "__main__":
    unittest.main()
