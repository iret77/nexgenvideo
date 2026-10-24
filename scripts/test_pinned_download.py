import hashlib
import http.client
import errno
import io
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

import pinned_download as transfer
import reuse_bpy_binary_evidence as reuse


class Response(io.BytesIO):
    def __init__(self, data, status=200, headers=None, failure=None):
        super().__init__(data)
        self.status = status
        self.headers = headers or {}
        self.failure = failure

    def read(self, size=-1):
        if self.tell() == len(self.getvalue()) and self.failure is not None:
            raise self.failure
        return super().read(size)


class PinnedDownloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.data = b"original immutable bytes"
        self.artifact = {"id": 42, "size_in_bytes": len(self.data),
                         "digest": "sha256:" + hashlib.sha256(self.data).hexdigest()}
        sleep = patch.object(transfer.time, "sleep")
        sleep.start(); self.addCleanup(sleep.stop)

    def fetch(self, responses, name="artifact.zip", artifact=None):
        artifact = artifact or self.artifact
        with patch.object(reuse, "source_response", side_effect=responses) as response:
            path = reuse.download(artifact, self.root / name)
            return path, response.call_args_list

    def remainder(self, offset):
        return Response(self.data[offset:], 206, {
            "Content-Range": f"bytes {offset}-{len(self.data) - 1}/{len(self.data)}",
            "Content-Length": str(len(self.data) - offset)})

    def test_reset_and_truncated_response_resume_only_received_bytes(self):
        for index, failure in enumerate((ConnectionResetError(54, "reset"), None,
                                         http.client.IncompleteRead(b"discarded", 10))):
            with self.subTest(failure=type(failure).__name__):
                path, calls = self.fetch([Response(self.data[:5], failure=failure), self.remainder(5)], str(index))
                self.assertEqual(path.read_bytes(), self.data)
                self.assertEqual([call.args[1] for call in calls], [0, 5])

    def test_server_ignoring_range_replaces_partial_instead_of_appending(self):
        path, calls = self.fetch([Response(self.data[:5]), Response(self.data)])
        self.assertEqual(path.read_bytes(), self.data)
        self.assertEqual([call.args[1] for call in calls], [0, 5])

    def test_wrong_ranges_lengths_encodings_and_unsolicited_partial_fail_closed(self):
        variants = [Response(self.data[5:], 206, {"Content-Range": value}) for value in (
            "bytes 0-22/23", "bytes 5-22/*", "bytes 5-22/24", "bytes 5-4/23", "items 5-22/23")]
        variants += [Response(self.data, headers={"Content-Length": "999"}),
                     Response(self.data, headers={"Content-Encoding": "gzip"}),
                     Response(self.data, status=204)]
        for index, bad in enumerate(variants):
            with self.subTest(index=index), patch.object(reuse, "source_response", side_effect=[Response(self.data[:5]), bad]) as response:
                with self.assertRaises(ValueError):
                    reuse.download(self.artifact, self.root / str(index))
                self.assertEqual(response.call_count, 2)
        with self.assertRaisesRegex(ValueError, "unexpected response"):
            self.fetch([self.remainder(0)], "unsolicited")

    def test_size_and_digest_mismatch_never_retry_or_claim_success(self):
        for index, data in enumerate((self.data + b"extra", b"x" * len(self.data))):
            with self.subTest(index=index), patch.object(reuse, "source_response", return_value=Response(data)) as response:
                with self.assertRaises(ValueError):
                    reuse.download(self.artifact, self.root / str(index))
                self.assertEqual(response.call_count, 1)

    def test_permanent_error_is_not_retried_and_signed_url_is_withheld(self):
        for code in (401, 403, 404, 410, 416):
            error = urllib.error.HTTPError("https://storage.invalid/?secret=value", code, "secret=value", {}, None)
            with self.subTest(code=code), patch.object(reuse, "source_response", side_effect=error) as response:
                with self.assertRaises(ValueError) as failure:
                    reuse.download(self.artifact, self.root / str(code))
                self.assertNotIn("secret", str(failure.exception))
                self.assertEqual(response.call_count, 1)

    def test_transient_http_error_retries_the_exact_artifact(self):
        error = urllib.error.HTTPError("https://storage.invalid/?secret=value", 503, "secret=value", {}, None)
        path, calls = self.fetch([error, Response(self.data)])
        self.assertEqual(path.read_bytes(), self.data)
        self.assertEqual([call.args[1] for call in calls], [0, 0])

    def test_disk_failure_is_not_a_network_retry(self):
        for error in (OSError(errno.ENOSPC, "disk full"), TimeoutError("sink timeout")):
            with self.subTest(error=type(error).__name__), \
                    patch.object(Path, "open") as destination, \
                    patch.object(reuse, "source_response", return_value=Response(self.data)) as response:
                sink = destination.return_value.__enter__.return_value
                sink.tell.return_value = 0
                sink.write.side_effect = error
                with self.assertRaises(type(error)):
                    reuse.download(self.artifact, self.root / "disk")
                self.assertEqual(response.call_count, 1)

    def test_transient_errors_have_three_attempt_limit(self):
        with patch.object(reuse, "source_response", side_effect=TimeoutError()) as response:
            with self.assertRaisesRegex(ValueError, "TimeoutError"):
                reuse.download(self.artifact, self.root / "timeout")
            self.assertEqual(response.call_count, 3)

    def test_retry_exhausting_deadline_stops_before_another_request(self):
        with patch.object(transfer.time, "monotonic", side_effect=[0, 0, 1501]), \
                patch.object(reuse, "source_response", side_effect=ConnectionResetError()) as response:
            with self.assertRaisesRegex(ValueError, "deadline"):
                reuse.download(self.artifact, self.root / "deadline")
            self.assertEqual(response.call_count, 1)

    def test_python39_socket_timeout_retries_direct_and_wrapped_errors(self):
        class LegacySocketTimeout(OSError):
            pass
        for index, error in enumerate((LegacySocketTimeout(), urllib.error.URLError(LegacySocketTimeout()))):
            with self.subTest(index=index), patch.object(transfer.socket, "timeout", LegacySocketTimeout):
                path, calls = self.fetch([error, Response(self.data)], "legacy-" + str(index))
                self.assertEqual(path.read_bytes(), self.data)
                self.assertEqual(len(calls), 2)

    def test_malformed_signed_redirect_does_not_leak_from_value_error(self):
        location = "https://storage.invalid/?signature=secret"
        redirect = urllib.error.HTTPError("https://api.github.com", 302, "redirect", {"Location": location}, None)
        with patch.dict("os.environ", GH_TOKEN="repository-secret"), \
                patch.object(reuse.urllib.request, "build_opener") as factory:
            factory.return_value.open.side_effect = [redirect, ValueError(location)]
            with self.assertRaises(ValueError) as error:
                reuse.download(self.artifact, self.root / "invalid")
            self.assertNotIn("secret", str(error.exception))
            self.assertNotIn("storage.invalid", str(error.exception))
            self.assertEqual(factory.return_value.open.call_count, 2)

    def test_existing_destination_is_not_replaced_or_trusted(self):
        path = self.root / "existing"; path.write_bytes(self.data)
        with patch.object(reuse, "source_response") as response, self.assertRaises(FileExistsError):
            reuse.download(self.artifact, path)
        response.assert_not_called()
        self.assertEqual(path.read_bytes(), self.data)

    def test_each_resume_gets_new_redirect_without_forwarding_credentials(self):
        locations = ["https://storage.invalid/first?signature=one", "https://storage.invalid/second?signature=two"]
        redirects = [urllib.error.HTTPError("https://api.github.com", 302, "redirect", {"Location": url}, None)
                     for url in locations]
        replies = [redirects[0], Response(self.data[:5], failure=ConnectionResetError()), redirects[1], self.remainder(5)]
        with patch.dict("os.environ", GH_TOKEN="repository-secret"), \
                patch.object(reuse.urllib.request, "build_opener") as factory:
            opener = factory.return_value
            opener.open.side_effect = replies
            path = reuse.download(self.artifact, self.root / "redirected")
            self.assertEqual(path.read_bytes(), self.data)
            requests = [call.args[0] for call in opener.open.call_args_list]
            self.assertEqual(len(requests), 4)
            for request in requests[::2]:
                self.assertEqual(request.full_url, "https://api.github.com/repos/iret77/nexgenvideo/actions/artifacts/42/zip")
                self.assertEqual(request.get_header("Authorization"), "Bearer repository-secret")
            for request, location in zip(requests[1::2], locations):
                self.assertEqual(request.full_url, location)
                self.assertIsNone(request.get_header("Authorization"))
                self.assertEqual(request.get_header("Accept-encoding"), "identity")
            self.assertIsNone(requests[1].get_header("Range"))
            self.assertEqual(requests[3].get_header("Range"), "bytes=5-")


if __name__ == "__main__":
    unittest.main()
