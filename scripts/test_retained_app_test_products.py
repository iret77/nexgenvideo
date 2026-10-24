import copy
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import struct
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
import urllib.error
import zipfile

import retained_app_test_products as replay


SHA = "a" * 40
PRODUCT = "b" * 40
IMAGE_UUID = "28e32694-8c96-33f4-9ebc-ab10afa8977b"


def put(archive, name, data=b"", mode=stat.S_IFREG | 0o644):
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = mode << 16
    archive.writestr(info, data)


def metadata_bytes():
    name = b"com.apple.xcode.CreatedByBuildSystem\0"
    start = 120 + ((11 + len(name) + 3) & ~3)
    data = bytearray(start + 4)
    struct.pack_into(">II16sH", data, 0, 0x00051607, 0x00020000, b"Mac OS X        ", 2)
    struct.pack_into(">6I", data, 26, 9, 50, len(data) - 50, 2, len(data), 0)
    struct.pack_into(">8I2H", data, 84, 0x41545452, 0, len(data), start, 4, 0, 0, 0, 0, 1)
    struct.pack_into(">IIHB", data, 120, start, 4, 0, len(name))
    data[131:131 + len(name)] = name
    data[start:] = b"true"
    return bytes(data)


class RetainedProductsTests(unittest.TestCase):
    def archive(self, path, extra=None):
        with zipfile.ZipFile(path, "w") as archive:
            put(archive, "Debug/", mode=stat.S_IFDIR | 0o755)
            put(archive, "Debug/host", b"original executable", stat.S_IFREG | 0o755)
            put(archive, "Debug/current", b"host", stat.S_IFLNK | 0o777)
            if extra:
                extra(archive)

    def test_restored_bytes_permissions_and_symlinks_must_all_match(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.archive(root / "products.zip")
            records = replay.manifest(root / "products.zip")
            actual = root / "Debug"
            actual.mkdir(mode=0o755)
            (actual / "host").write_bytes(b"original executable")
            (actual / "host").chmod(0o755)
            (actual / "current").symlink_to("host")
            replay.verify_tree(actual, records)
            (actual / "host").write_bytes(b"substituted executable")
            with self.assertRaises(ValueError):
                replay.verify_tree(actual, records)
            (actual / "host").write_bytes(b"original executable")
            (actual / "host").chmod(0o644)
            with self.assertRaises(ValueError):
                replay.verify_tree(actual, records)
            (actual / "host").chmod(0o755)
            (actual / "extra").write_bytes(b"unexpected")
            with self.assertRaises(ValueError):
                replay.verify_tree(actual, records)

    def test_archive_rejects_escape_collision_linked_parent_and_special_files(self):
        additions = [
            lambda z: put(z, "../outside", b"escape"),
            lambda z: put(z, "/outside", b"escape"),
            lambda z: put(z, "Debug/Host", b"collision"),
            lambda z: put(z, "Debug/current/child", b"linked parent"),
            lambda z: put(z, "Debug/escape", b"../../outside", stat.S_IFLNK | 0o777),
            lambda z: put(z, "Debug/escape", b"/outside", stat.S_IFLNK | 0o777),
            lambda z: put(z, "Debug/socket", b"", stat.S_IFSOCK | 0o755),
            lambda z: put(z, "Other/file", b"unexpected root"),
            lambda z: put(z, "__MACOSX/not-appledouble", b"unknown metadata"),
        ]
        for number, addition in enumerate(additions):
            with self.subTest(number=number), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "archive.zip"
                self.archive(path, addition)
                with self.assertRaises(ValueError):
                    replay.manifest(path)

    def test_appledouble_attributes_are_restored_on_the_original_target(self):
        for sidecar in ("Debug/._host", "__MACOSX/Debug/._host"):
            with self.subTest(sidecar=sidecar), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "products.zip"
                self.archive(path, lambda z: put(z, sidecar, metadata_bytes()))
                records = replay.manifest(path)
                self.assertEqual(set(records), {"Debug", "Debug/host", "Debug/current"})
                self.assertEqual(records["Debug/host"]["xattrs"], {"com.apple.xcode.CreatedByBuildSystem": b"true".hex()})

    def test_appledouble_rejects_malformed_entries_and_ambiguous_targets(self):
        original = metadata_bytes()
        changes = [lambda d: d.__setitem__(slice(0, 4), b"bad!"),
                   lambda d: struct.pack_into(">H", d, 24, 3),
                   lambda d: struct.pack_into(">I", d, 120, len(d) + 1),
                   lambda d: struct.pack_into(">I", d, 124, len(d)),
                   lambda d: d.__setitem__(130, 255),
                   lambda d: d.__setitem__(slice(84, 88), b"bad!")]
        for change in changes:
            data = bytearray(original)
            change(data)
            with self.assertRaises(ValueError):
                replay.appledouble_attributes(bytes(data))
        for target in ("missing", "current"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "products.zip"
                self.archive(path, lambda z: put(z, "Debug/._" + target, original))
                with self.assertRaises(ValueError):
                    replay.manifest(path)

    def test_restored_attribute_bytes_must_match_and_extra_attributes_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o755)
            records = {"Debug": {"kind": "directory", "mode": 0o755,
                                  "xattrs": {"com.apple.xcode.CreatedByBuildSystem": b"true".hex()}}}
            with patch.object(replay, "read_xattrs", return_value={"com.apple.xcode.CreatedByBuildSystem": b"true".hex()}):
                replay.verify_tree(root, records)
            for names, value in (([], b"true"), (["com.apple.xcode.CreatedByBuildSystem"], b"false"), (["extra"], b"true")):
                with patch.object(replay, "read_xattrs", return_value={name: value.hex() for name in names}), \
                        self.assertRaises(ValueError):
                    replay.verify_tree(root, records)

    def test_darwin_attributes_use_native_nofollow_and_preserve_exact_bytes(self):
        for attributes in ({}, {b"com.apple.xcode.CreatedByBuildSystem": b"true"},
                           {b"com.apple.xcode.CreatedByBuildSystem": b"false", b"extra": b""}):
            calls = []

            def transfer(data, buffer, size):
                if buffer is not None and size:
                    ctypes.memmove(buffer, data, len(data))
                return len(data)

            def names(path, buffer, size, options):
                calls.append(("names", path, options))
                return transfer(b"".join(name + b"\0" for name in attributes), buffer, size)

            def value(path, name, buffer, size, position, options):
                calls.append(("value", path, options, position))
                return transfer(attributes[name], buffer, size)

            library = SimpleNamespace(listxattr=Mock(side_effect=names), getxattr=Mock(side_effect=value))
            with patch.object(replay.sys, "platform", "darwin"), patch.object(replay.ctypes, "CDLL", return_value=library), \
                    patch.object(os, "listxattr", side_effect=AssertionError("Linux API on Darwin")):
                self.assertEqual(replay.read_xattrs(Path("/fixture/link")), {name.decode(): data.hex() for name, data in attributes.items()})
            self.assertTrue(all(call[1:3] == (b"/fixture/link", 1) for call in calls))
            self.assertTrue(all(call[3] == 0 for call in calls if call[0] == "value"))
            self.assertIs(library.listxattr.restype, ctypes.c_ssize_t)
            self.assertIs(library.getxattr.restype, ctypes.c_ssize_t)

    def test_darwin_attribute_errors_size_changes_and_unsupported_platform_fail(self):
        for results, error in (([-1], OSError), ([2, -1], OSError), ([2, 1], ValueError), ([65537], ValueError)):
            library = SimpleNamespace(listxattr=Mock(side_effect=results), getxattr=Mock())
            with patch.object(replay.sys, "platform", "darwin"), patch.object(replay.ctypes, "CDLL", return_value=library), \
                    self.assertRaises(error):
                replay.read_xattrs(Path("/fixture"))
        def names(path, buffer, size, options):
            if buffer is not None:
                ctypes.memmove(buffer, b"key\0", 4)
            return 4
        for results, error in (([-1], OSError), ([2, -1], OSError), ([2, 1], ValueError)):
            library = SimpleNamespace(listxattr=Mock(side_effect=names), getxattr=Mock(side_effect=results))
            with patch.object(replay.sys, "platform", "darwin"), patch.object(replay.ctypes, "CDLL", return_value=library), \
                    self.assertRaises(error):
                replay.read_xattrs(Path("/fixture"))
        with patch.object(replay.sys, "platform", "unsupported"), self.assertRaises(ValueError):
            replay.read_xattrs(Path("/fixture"))

    def test_artifact_download_does_not_forward_credentials_or_accept_substitute_bytes(self):
        data = b"original archive bytes"
        artifact = {"id": 20, "size_in_bytes": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
        for returned, valid in ((data, True), (b"x" * len(data), False), (data + b"extra", False)):
            requests = []

            def open_request(request, timeout):
                requests.append(request)
                if len(requests) == 1:
                    raise urllib.error.HTTPError(request.full_url, 302, "Found",
                        {"Location": "https://artifact.example/bytes?signed=private"}, None)
                response = io.BytesIO(returned)
                response.status = 200
                return response

            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, GH_TOKEN="private-token"), \
                    patch.object(replay.urllib.request, "build_opener", return_value=SimpleNamespace(open=open_request)):
                target = Path(directory) / "artifact.zip"
                if valid:
                    replay.download(artifact, target)
                    self.assertEqual(target.read_bytes(), data)
                else:
                    with self.assertRaises(ValueError):
                        replay.download(artifact, target)
            self.assertEqual(requests[0].get_header("Authorization"), "Bearer private-token")
            self.assertIsNone(requests[1].get_header("Authorization"))

    def test_artifact_redirects_fail_closed_without_leaking_signed_urls(self):
        artifact = {"id": 20, "size_in_bytes": 1, "digest": "sha256:" + "a" * 64}
        for target, second in (("http://artifact.example/private", None),
                               ("https://user:password@artifact.example/private", None),
                               ("https://artifact.example/private?signed=secret", urllib.error.URLError("signed=secret"))):
            redirect = urllib.error.HTTPError("https://api.github.com/fixture", 302, "Found", {"Location": target}, None)
            opener = SimpleNamespace(open=Mock(side_effect=[redirect, second]))
            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, GH_TOKEN="private-token"), \
                    patch.object(replay.urllib.request, "build_opener", return_value=opener):
                with self.assertRaises(ValueError) as error:
                    replay.download(artifact, Path(directory) / "artifact.zip")
                self.assertNotIn("secret", str(error.exception))
                self.assertNotIn("password", str(error.exception))
        self.assertIsNone(replay.NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://example.com"))

    def test_original_execution_requires_executed_compiled_bytes_and_source_identity(self):
        binaries = {name: {"sha256": "c" * 64, "uuidOutput": "UUID: " + IMAGE_UUID} for name in (
            "NexGenVideoAppKitTestHost", "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests")}
        compiled = {"productSourceSHA": PRODUCT, "harnessSourceSHA": SHA, "binRoot": "/original/Debug", "binaries": binaries}
        execution = {"buildSourceSHA": PRODUCT, "harnessSourceSHA": SHA}
        receipt = {"pid": 42, "sourceSHA": SHA, "abiSucceeded": True, "completed": True,
                   "hostExecutable": "/original/Debug/NexGenVideoAppKitTestHost",
                   "bundleBinary": "/original/Debug/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"}
        diagnostic = {"pid": 42, "status": "verified", "profile": "zombies", "sourceSHA": SHA, "harnessSourceSHA": SHA,
                      "productSourceSHA": PRODUCT, "environment": {"NSZombieEnabled": "YES", "otherDiagnosticVariablesPresent": False},
                      "memoryErrors": [], "sampleCount": 2, "hostSHA256": "c" * 64, "hostUUID": IMAGE_UUID}
        suite = {"productSourceSHA": PRODUCT, "sourceSHA": SHA, "harnessSourceSHA": SHA, "completed": True,
                 "scope": "app-swift-testing", "filter": "", "phases": [{"exitCode": 0, "status": "verified-execution",
                 "pid": 42, "diagnostic": diagnostic, "originalHostReceipt": receipt}]}
        wrapper = {"runID": "10", "sourceSHA": SHA, "testExitCode": 0, "effectiveExitCode": 0}
        replay.verify_execution(compiled, execution, suite, wrapper, PRODUCT, SHA, 10)
        for target, key, value in ((compiled, "productSourceSHA", SHA), (execution, "buildSourceSHA", SHA),
                                   (suite, "filter", "GlowKernelTests"), (wrapper, "runID", "11"),
                                   (wrapper, "effectiveExitCode", 139), (diagnostic, "pid", 43),
                                   (diagnostic, "hostSHA256", "d" * 64), (diagnostic, "hostUUID", "0" * 36),
                                   (diagnostic, "sampleCount", 1), (diagnostic, "memoryErrors", ["failed"]),
                                   (receipt, "hostExecutable", "/substitute/host"), (receipt, "abiSucceeded", False)):
            previous = target[key]
            target[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                replay.verify_execution(compiled, execution, suite, wrapper, PRODUCT, SHA, 10)
            target[key] = previous

    def producer(self):
        run = {"id": 10, "repository": {"full_name": "iret77/nexgenvideo"}, "head_sha": SHA,
               "run_attempt": 1, "path": ".github/workflows/diagnostic-acceptance.yml",
               "event": "workflow_dispatch", "status": "completed", "conclusion": "success"}
        names = ["Preserve the reviewed harness and bind the original test source",
                 "Compile unchanged original native test products", "Retain compiled products before diagnostic execution",
                 "Diagnose the original full App SwiftTesting backend once", "Verify diagnostic completion and unchanged source",
                 "Upload original App diagnostic evidence", "Upload retained native test products"]
        jobs = {"total_count": 2, "jobs": [{"name": name, "run_id": 10, "run_attempt": 1, "head_sha": SHA,
                "status": "completed", "conclusion": "success", "steps": [
                    {"name": step, "status": "completed", "conclusion": "success"} for step in names]}
                for name in ("source", "ci-app-test")]}
        return run, jobs

    def test_producer_requires_original_attempt_source_steps_and_complete_job_inventory(self):
        run, jobs = self.producer()
        self.assertEqual(replay.verify_producer(run, jobs, SHA)["name"], "ci-app-test")
        changes = [lambda r, j: r.update(run_attempt=2), lambda r, j: r.update(head_sha=PRODUCT),
                   lambda r, j: r.update(conclusion="failure"), lambda r, j: j.update(total_count=3),
                   lambda r, j: j["jobs"][1].update(head_sha=PRODUCT),
                   lambda r, j: j["jobs"][1]["steps"][2].update(conclusion="skipped"),
                   lambda r, j: j["jobs"][1]["steps"].pop(),
                   lambda r, j: j["jobs"][0].update(name="ci-app-test")]
        for number, change in enumerate(changes):
            with self.subTest(number=number):
                original, inventory = copy.deepcopy(run), copy.deepcopy(jobs)
                change(original, inventory)
                with self.assertRaises(ValueError):
                    replay.verify_producer(original, inventory, SHA)

    def test_artifact_must_be_created_by_the_exact_successful_producer_attempt(self):
        run = {"id": 10, "head_sha": SHA}
        job = {"started_at": "2026-10-24T01:30:00Z", "completed_at": "2026-10-24T01:40:00Z"}
        artifact = {"id": 20, "name": "products", "digest": "sha256:" + "c" * 64, "expired": False,
                    "workflow_run": {"id": 10, "head_sha": SHA}, "created_at": "2026-10-24T01:35:00Z",
                    "updated_at": "2026-10-24T01:39:00Z", "expires_at": "2999-01-01T00:00:00Z"}
        replay.verify_artifact(artifact, run, job, 20, "c" * 64, "products")
        for key, value in (("id", 21), ("name", "other"), ("digest", "sha256:" + "d" * 64), ("expired", True),
                           ("created_at", "2026-10-24T01:20:00Z"), ("updated_at", "2026-10-24T01:41:00Z"),
                           ("expires_at", "2000-01-01T00:00:00Z"), ("workflow_run", {"id": 11, "head_sha": SHA})):
            with self.subTest(key=key), self.assertRaises(ValueError):
                replay.verify_artifact({**artifact, key: value}, run, job, 20, "c" * 64, "products")

    def evidence(self, root):
        metadata, evidence = root / "metadata", root / "evidence"
        metadata.mkdir()
        phase_folder = evidence / "hosted-suite/app-swift-testing"
        phase_folder.mkdir(parents=True)
        binary_root = root / "Debug"
        binaries = {name: {"sha256": "c" * 64, "uuidOutput": "UUID: " + IMAGE_UUID} for name in (
            "NexGenVideoAppKitTestHost", "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests")}
        binding = {"harnessSHA": SHA, "productSHA": PRODUCT,
                   "compiled": {"binRoot": str(binary_root), "binaries": binaries},
                   "systemImages": {"CoreImage": {"path": "/System/CoreImage", "uuid": IMAGE_UUID}},
                   "originalProductImages": {name: IMAGE_UUID for name in (
                       "NexGenVideoAppKitTestHost", "NexGenVideoTests", "libNexGenEngine.dylib")}}
        replay.write(metadata / "binding.json", binding)
        replay.write(metadata / "restored-manifest.json", {})
        ended = ["NexGenVideoTests.GlowKernelTests/" + name + "()/GlowKernelTests.swift:1:1" for name in
                 ("neutralIsNoOp", "bleedsLightIntoNeighbors", "warmthTintsTheBleedRed")]
        phase = {"exitCode": 0, "status": "verified-execution", "pid": 42,
                 "diagnostic": {"status": "verified", "profile": "glow-reproduction", "pid": 42,
                    "sourceSHA": SHA, "harnessSourceSHA": SHA, "productSourceSHA": PRODUCT,
                    "hostSHA256": "c" * 64, "hostUUID": IMAGE_UUID, "memoryErrors": [], "sampleCount": 2,
                    "environment": {"DYLD_PRINT_LIBRARIES": "1", "otherDiagnosticVariablesPresent": False}},
                 "originalHostReceipt": {"pid": 42, "abiSucceeded": True, "completed": True, "sourceSHA": SHA,
                     "hostExecutable": str(binary_root / "NexGenVideoAppKitTestHost"),
                     "bundleBinary": str(binary_root / "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests")},
                 "events": {"endedFunctionIDs": ended, "functionExecutions": 3}}
        suite = {"sourceSHA": SHA, "harnessSourceSHA": SHA, "productSourceSHA": PRODUCT, "completed": True,
                 "scope": "app-swift-testing", "filter": "GlowKernelTests", "binPath": str(binary_root),
                 "testExecutions": 3, "phases": [phase]}
        replay.write(evidence / "hosted-suite/suite.json", suite)
        replay.write(evidence / "run.json", {"testExitCode": 0, "effectiveExitCode": 0, "sourceSHA": SHA, "runID": "30"})
        events = [{"kind": "event", "payload": {"testID": identity, "kind": kind,
                   "instant": {"since1970": index + offset}}} for index, identity in enumerate(ended)
                  for kind, offset in (("testStarted", 0), ("testEnded", 4))]
        (phase_folder / "events.jsonl").write_text("\n".join(json.dumps(value) for value in events) + "\n")
        images = ["/System/CoreImage", str(binary_root / "libNexGenEngine.dylib"), *(str(binary_root / name) for name in binaries)]
        (phase_folder / "console.log").write_text("\n".join("dyld[42]: <" + IMAGE_UUID + "> " + name for name in images))
        return metadata, evidence, suite

    def test_completion_requires_exact_exposure_pid_loader_images_and_source(self):
        with tempfile.TemporaryDirectory() as directory:
            metadata, evidence, suite = self.evidence(Path(directory))
            with patch.object(replay, "command", return_value=PRODUCT), patch.object(replay, "verify_tree"), \
                    patch.dict(os.environ, GITHUB_SHA=SHA, GITHUB_RUN_ID="30"):
                replay.verify_replay(metadata, evidence)
                result = json.loads((evidence / "interpretation.json").read_text())
                self.assertFalse(result["coreAcceptance"])
                self.assertFalse(result["failureRateInference"])
                for change in (lambda s: s.update(productSourceSHA=SHA), lambda s: s.update(filter="OtherTests"),
                               lambda s: s.update(testExecutions=4), lambda s: s.update(harnessSourceSHA=PRODUCT),
                               lambda s: s["phases"][0]["diagnostic"].update(pid=43),
                               lambda s: s["phases"][0]["diagnostic"].update(hostSHA256="d" * 64),
                               lambda s: s["phases"][0]["originalHostReceipt"].update(completed=False),
                               lambda s: s["phases"][0]["events"]["endedFunctionIDs"].pop()):
                    altered = copy.deepcopy(suite)
                    change(altered)
                    replay.write(evidence / "hosted-suite/suite.json", altered)
                    with self.assertRaises(ValueError):
                        replay.verify_replay(metadata, evidence)
                replay.write(evidence / "hosted-suite/suite.json", suite)
                binding_path = metadata / "binding.json"
                binding = json.loads(binding_path.read_text())
                original_binding = copy.deepcopy(binding)
                binding["originalProductImages"]["libNexGenEngine.dylib"] = "11111111-1111-1111-1111-111111111111"
                replay.write(binding_path, binding)
                with self.assertRaises(ValueError):
                    replay.verify_replay(metadata, evidence)
                replay.write(binding_path, original_binding)
                event_path = evidence / "hosted-suite/app-swift-testing/events.jsonl"
                original_events = event_path.read_text()
                serial = [json.loads(line) for line in original_events.splitlines()]
                for index, record in enumerate(serial):
                    record["payload"]["instant"]["since1970"] = index
                event_path.write_text("\n".join(json.dumps(record) for record in serial))
                with self.assertRaises(ValueError):
                    replay.verify_replay(metadata, evidence)
                event_path.write_text(original_events)
                console = evidence / "hosted-suite/app-swift-testing/console.log"
                original = console.read_text()
                for value in (original.replace("dyld[42]", "dyld[43]"), original.replace(IMAGE_UUID, "c" * 36), ""):
                    console.write_text(value)
                    with self.assertRaises(ValueError):
                        replay.verify_replay(metadata, evidence)


if __name__ == "__main__":
    unittest.main()
