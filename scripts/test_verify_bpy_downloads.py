import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

from assemble_bpy_source_closure import AssemblyProgress, blender_dependencies, fetch, source_download_url


class Response(io.BytesIO):
    def __init__(self, data, length=None):
        super().__init__(data)
        self.headers = {"Content-Length": str(len(data) if length is None else length)}


class SourceDownloadTests(unittest.TestCase):
    def test_gmp_uses_official_gnu_archive_with_unchanged_upstream_hash(self):
        url = "https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz"
        mirror = "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
        data = b"pinned GMP source"
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "gmp.tar.xz"
            with patch("assemble_bpy_source_closure.urllib.request.urlopen", return_value=Response(data)) as download:
                result = fetch(url, destination, hashlib.md5(data).hexdigest(), "MD5")
            self.assertEqual(download.call_args.args[0].full_url, mirror)
            self.assertEqual(result, {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
            with patch("assemble_bpy_source_closure.urllib.request.urlopen", return_value=Response(b"changed mirror")), \
                    patch("assemble_bpy_source_closure.time.sleep") as sleep:
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    fetch(url, destination, hashlib.md5(data).hexdigest(), "MD5")
            sleep.assert_not_called()
            self.assertEqual(destination.read_bytes(), data)

    def test_source_mirror_does_not_rewrite_other_hosts_or_releases(self):
        for url in ("https://gmplib.org/download/gmp/gmp-6.2.1.tar.xz",
                    "https://example.test/download/gmp/gmp-6.3.0.tar.xz"):
            with self.subTest(url=url):
                self.assertEqual(source_download_url(url), url)

    def test_official_sqlite_sha1_declaration_is_preserved(self):
        manifest = """
set(SQLITE_VERSION 3.51.3)
set(SQLLITE_LONG_VERSION 3510300)
set(SQLITE_URI https://www.sqlite.org/2026/sqlite-autoconf-${SQLLITE_LONG_VERSION}.tar.gz)
set(SQLITE_HASH d917ad1cde07987643571f0f5b55dd954fa8dee3)
set(SQLITE_HASH_TYPE SHA1)
set(SQLITE_FILE sqlite-autoconf-${SQLLITE_LONG_VERSION}.tar.gz)
"""
        dependency, = blender_dependencies(manifest)
        self.assertEqual(dependency["key"], "SQLITE")
        self.assertEqual(dependency["upstreamHashType"], "SHA1")
        self.assertEqual(dependency["upstreamHash"], "d917ad1cde07987643571f0f5b55dd954fa8dee3")
        self.assertEqual(dependency["url"], "https://www.sqlite.org/2026/sqlite-autoconf-3510300.tar.gz")
        with self.assertRaisesRegex(ValueError, "unsupported Blender dependency hash: SQLITE=UNKNOWN"):
            blender_dependencies(manifest.replace("SHA1", "UNKNOWN"))

    def test_legacy_upstream_hash_is_checked_and_source_receipt_uses_sha256(self):
        data = b"pinned upstream source"
        for algorithm in ("SHA1", "MD5", "SHA256"):
            with self.subTest(algorithm=algorithm), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory) / "source.tar"
                expected = hashlib.new(algorithm.lower(), data).hexdigest()
                with patch("assemble_bpy_source_closure.urllib.request.urlopen", return_value=Response(data)):
                    result = fetch("https://example.test/source", destination, expected, algorithm)
                self.assertEqual(result, {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
                with patch("assemble_bpy_source_closure.urllib.request.urlopen", return_value=Response(b"changed")), \
                        patch("assemble_bpy_source_closure.time.sleep") as sleep:
                    with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                        fetch("https://example.test/source", destination, expected, algorithm)
                sleep.assert_not_called()
                self.assertEqual(destination.read_bytes(), data)

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


class RetainedSourceTests(unittest.TestCase):
    def test_resume_rechecks_bytes_and_current_original_pin_without_download(self):
        import assemble_bpy_source_closure as assembly
        data = b"original verified source"
        expected = hashlib.sha256(data).hexdigest()
        def write_source(url, destination, pin, algorithm):
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            return {"sha256": expected, "size": len(data)}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(assembly, "fetch", side_effect=write_source):
                initial = assembly.SourceDownloads(root, b"{}")
                path, _ = initial.get(
                    "component", "https://example.test/source", expected, "SHA256", "source.tar")
                carried, _ = initial.get(
                    "previous-only", "https://example.test/previous", expected, "SHA256", "previous.tar")
            with patch.object(assembly, "fetch") as download:
                resume = assembly.SourceDownloads(root, b'{"metadata":"changed"}')
                resumed, _ = resume.get(
                    "component", "https://example.test/source", expected, "SHA256", "source.tar")
                self.assertEqual(resumed.read_bytes(), data)
                download.assert_not_called()
            record = json.loads((root / "verified-sources.json").read_text())
            self.assertEqual(record["runtimeLockSHA256Scope"], "current-producer-context-only")
            self.assertEqual(record["runtimeLockSHA256"], hashlib.sha256(b'{"metadata":"changed"}').hexdigest())
            self.assertEqual(record["currentPinValidatedPaths"], [str(path.relative_to(root))])
            self.assertEqual(record["carriedOverCandidatePaths"], [str(carried.relative_to(root))])
            self.assertEqual(carried.read_bytes(), data)
            with patch.object(assembly, "fetch", side_effect=write_source):
                fresh, _ = resume.get(
                    "fresh", "https://example.test/fresh", expected, "SHA256", "fresh.tar")
            record = json.loads((root / "verified-sources.json").read_text())
            self.assertEqual(record["currentPinValidatedPaths"],
                             sorted(str(p.relative_to(root)) for p in (path, fresh)))
            self.assertEqual(record["carriedOverCandidatePaths"], [str(carried.relative_to(root))])
            path.write_bytes(b"substituted source bytes")
            record = json.loads((root / "verified-sources.json").read_text())
            record["downloads"][0].update(sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                                          size=path.stat().st_size)
            (root / "verified-sources.json").write_text(json.dumps(record))
            with patch.object(assembly, "fetch") as download:
                with self.assertRaisesRegex(ValueError, "current original pin"):
                    assembly.SourceDownloads(root, b"{}").get(
                        "component", "https://example.test/source", expected, "SHA256", "source.tar")
                download.assert_not_called()
            record = json.loads((root / "verified-sources.json").read_text())
            self.assertEqual(record["currentPinValidatedPaths"], [])
            self.assertNotIn(str(path.relative_to(root)), record["carriedOverCandidatePaths"])
            self.assertEqual(carried.read_bytes(), data)

    def test_wrong_size_pin_never_keeps_a_current_validation_label(self):
        import assemble_bpy_source_closure as assembly
        data = b"verified original source"
        expected = hashlib.sha256(data).hexdigest()
        def write_source(url, destination, pin, algorithm):
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            return {"sha256": expected, "size": len(data)}
        for retained in (False, True):
            with self.subTest(retained=retained), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                cache = assembly.SourceDownloads(root, b"{}")
                args = ("component", "https://example.test/source", expected, "SHA256", "source.tar")
                if retained:
                    with patch.object(assembly, "fetch", side_effect=write_source):
                        cache.get(*args, expected_size=len(data))
                    cache = assembly.SourceDownloads(root, b'{"metadata":"changed"}')
                    with patch.object(assembly, "fetch") as download:
                        cache.get(*args, expected_size=len(data))
                        download.assert_not_called()
                with patch.object(assembly, "fetch", side_effect=write_source) as download:
                    with self.assertRaisesRegex(ValueError, "size.*current original pin"):
                        cache.get(*args, expected_size=len(data) + 1)
                    self.assertEqual(download.call_count, 0 if retained else 1)
                record = json.loads((root / "verified-sources.json").read_text())
                self.assertEqual(record["downloads"], [])
                self.assertEqual(record["currentPinValidatedPaths"], [])
                self.assertEqual(record["carriedOverCandidatePaths"], [])
                paths = list((root / "verified-sources").iterdir())
                self.assertEqual(len(paths), 1)
                self.assertEqual(paths[0].read_bytes(), data)

    def test_download_failures_keep_bytes_and_observe_later_sources(self):
        import assemble_bpy_source_closure as assembly
        data = b"verified bytes"
        expected = hashlib.sha256(data).hexdigest()
        versions = b"trusted versions manifest"
        def dependency(key):
            return {"key": key, "name": key, "version": "1", "url": "https://example.test/" + key,
                    "upstreamHash": expected, "upstreamHashType": "SHA256", "filename": key + ".tar",
                    "license": "MIT", "copyright": None, "buildTimeOnly": None, "homepage": None}
        def source(name):
            return {"name": name, "version": "1", "license": "MIT",
                    "source": {"url": "https://example.test/" + name, "sha256": expected, "license": "MIT"}}
        lock = {"wheels": [source("bpy"), source("other")], "pythonBuildInputs": [],
                "runtime": {**source("runtime"), "sourceCommit": "pinned"},
                "bpyWheelLayout": {"officialBuildManifestSHA256": hashlib.sha256(versions).hexdigest()},
                "sourceCompanions": {"path": "companions.json"}}
        calls = []
        def download(url, destination, pin, algorithm):
            calls.append(url)
            if url.endswith("FIRST"):
                raise urllib.error.URLError(TimeoutError())
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            return {"sha256": expected, "size": len(data)}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock_path = root / "lock.json"
            lock_path.write_text(json.dumps(lock))
            (root / "companions.json").write_text("{}")
            output = root / "output"
            with patch.object(assembly, "LOCK_PATH", lock_path), patch.object(assembly, "ROOT", root), \
                    patch.object(assembly, "load_companions", return_value=[]), \
                    patch.object(assembly, "fetch", side_effect=download), \
                    patch.object(assembly, "member_bytes", return_value=versions), \
                    patch.object(assembly, "blender_dependencies", return_value=[dependency("FIRST"), dependency("LATER")]), \
                    patch("sys.argv", ["assemble", "--output-directory", str(output)]):
                with self.assertRaisesRegex(ValueError, "incomplete.*FIRST"):
                    assembly.main()
            self.assertIn("https://example.test/LATER", calls)
            self.assertIn("https://example.test/other", calls)
            record = json.loads((output / "verified-sources.json").read_text())
            self.assertEqual(len(record["downloads"]), 4)
            for item in record["downloads"]:
                self.assertEqual((output / item["path"]).read_bytes(), data)
            self.assertFalse(record["sourceClosureComplete"])
            self.assertFalse(record["publicDistributionAuthorized"])
            progress = json.loads((output / "assembly-progress.json").read_text())
            self.assertEqual(progress["status"], "failed")
            self.assertEqual(progress["failedSources"][0]["component"], "blender-release-dependency:FIRST")
            self.assertFalse((output / "NexGenVideo-bpy-5.2.2-corresponding-source.tar").exists())

    def test_untrusted_blender_pin_stops_before_other_sources(self):
        import assemble_bpy_source_closure as assembly
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock_path = root / "lock.json"
            lock_path.write_text(json.dumps({"wheels": [{"name": "bpy", "version": "1", "license": "GPL",
                "source": {"url": "https://example.test/blender", "sha256": "0" * 64}}]}))
            with patch.object(assembly, "LOCK_PATH", lock_path), \
                    patch.object(assembly, "load_companions", return_value=[]), \
                    patch.object(assembly, "fetch", side_effect=ValueError("checksum mismatch")) as download, \
                    patch.object(assembly, "blender_dependencies") as dependencies, \
                    patch("sys.argv", ["assemble", "--output-directory", str(root / "output")]):
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    assembly.main()
            self.assertEqual(download.call_count, 1)
            dependencies.assert_not_called()


if __name__ == "__main__":
    unittest.main()
