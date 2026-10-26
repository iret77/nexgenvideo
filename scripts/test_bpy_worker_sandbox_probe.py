from copy import deepcopy
import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import tempfile
import unittest
from unittest.mock import Mock, patch

import bpy_worker_sandbox_payload as payload
from bpy_worker_sandbox_probe import (ARTIFACT, DIGEST, FILES, RUN, SIZE, SOURCE, entitlements,
    RETAINED_ARTIFACTS, RETAINED_NATIVE_FILES, RETAINED_RUN, RETAINED_SOURCE, execution_identity, native_sections, records,
    require_python_only_change, run_command, signal_group, tree_manifest, validate, validate_retained)


class ComponentProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 10, 27, tzinfo=datetime.timezone.utc)
        self.run = dict(id=RUN, head_sha=SOURCE, run_attempt=1, status="completed", conclusion="failure",
            event="workflow_dispatch", path=".github/workflows/ci-batch.yml", actor=dict(login="iret77"),
            repository=dict(full_name="iret77/nexgenvideo"))
        self.jobs = dict(total_count=6, jobs=[])
        for index, name in enumerate(["Light Checks", "Build & Test", "Agent UI Evidence", "bpy-source / source",
                                      "diagnostic-startup", "bpy-runtime / runtime"]):
            self.jobs["jobs"].append(dict(id=121755560581 if name == "Build & Test" else 121773449342 if index == 5 else index,
                name="Compile, unit tests, app and native bpy acceptance / " + name,
                run_id=RUN, head_sha=SOURCE, run_attempt=1, status="completed", conclusion="failure" if index == 5 else "success",
                started_at="2026-10-26T18:08:21Z", completed_at="2026-10-26T18:41:55Z",
                steps=[dict(name="Prove pre-lease and post-exec host-crash cleanup", conclusion="failure")] if index == 5 else []))
        self.artifact = dict(id=ARTIFACT, name="NexGenVideo-app", size_in_bytes=SIZE, digest="sha256:" + DIGEST,
            expired=False, workflow_run=dict(id=RUN, head_sha=SOURCE), created_at="2026-10-26T18:40:43Z",
            updated_at="2026-10-26T18:41:00Z", expires_at="2026-11-02T18:40:43Z")

    def check(self, changed=FILES):
        validate(self.run, self.jobs, self.artifact, changed, self.now)

    def test_exact_successful_producer_can_supply_only_component_fixture(self):
        self.check()

    def test_other_run_account_source_attempt_or_workflow_is_rejected(self):
        for field, value in [("id", RUN + 1), ("head_sha", "f" * 40), ("run_attempt", 2),
                             ("event", "pull_request"), ("path", ".github/workflows/release.yml"),
                             ("status", "in_progress"), ("conclusion", "success"),
                             ("actor", dict(login="another-owner")), ("repository", dict(full_name="iret77/another-repo"))]:
            with self.subTest(field=field):
                old = deepcopy(self.run)
                self.run[field] = value
                with self.assertRaises(ValueError):
                    self.check()
                self.run = old

    def test_missing_duplicated_or_unfinished_job_cannot_prove_producer(self):
        original = deepcopy(self.jobs)
        for mutate in [lambda j: j["jobs"].pop(), lambda j: j["jobs"].append(deepcopy(j["jobs"][1])),
                       lambda j: j["jobs"][1].update(conclusion="failure"),
                       lambda j: j["jobs"][1].update(status="in_progress"),
                       lambda j: j["jobs"][1].update(run_attempt=2),
                       lambda j: j["jobs"][1].update(head_sha="f" * 40)]:
            self.jobs = deepcopy(original)
            mutate(self.jobs)
            self.jobs["total_count"] = len(self.jobs["jobs"])
            with self.assertRaises(ValueError):
                self.check()

    def test_partial_job_page_is_rejected(self):
        self.jobs["total_count"] += 1
        with self.assertRaises(ValueError):
            self.check()

    def test_different_failed_stage_or_extra_failure_is_rejected(self):
        self.jobs["jobs"][-1]["steps"].append(dict(name="Other failure", conclusion="failure"))
        with self.assertRaises(ValueError):
            self.check()

    def test_wrong_artifact_identity_digest_size_or_expiry_is_rejected(self):
        original = deepcopy(self.artifact)
        for field, value in [("id", ARTIFACT + 1), ("digest", "sha256:" + "0" * 64), ("size_in_bytes", SIZE - 1),
                             ("expired", True), ("name", "workspace-ui-app"),
                             ("workflow_run", dict(id=RUN + 1, head_sha=SOURCE)),
                             ("expires_at", "2026-10-26T00:00:00Z"),
                             ("created_at", "2026-10-25T00:00:00Z"),
                             ("updated_at", "2026-10-27T00:00:00Z")]:
            self.artifact = deepcopy(original)
            self.artifact[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()

    def test_product_signing_and_runtime_changes_cannot_reuse_original_app(self):
        for path in ["Sources/NexGenVideoBpySupervisor/main.swift", "Runtime/bpy/worker.py",
                     "scripts/verify_bpy_signing.py", "scripts/bundle.sh", "Package.swift"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.check(FILES | {path})


class MemoryDiagnosticTests(unittest.TestCase):
    def test_moving_threshold_is_not_reported_as_confirmed(self):
        original = (32, 64)
        current = [original]
        seven_attempts = []

        def setter(_, pair):
            if pair != original:
                if pair[0] == 7:
                    seven_attempts.append(pair)
                if pair[0] < 8 and not (pair[0] == 7 and len(seven_attempts) == 2):
                    raise ValueError("current limit exceeds maximum limit")
            current[0] = pair

        with patch.object(payload.resource, "getrlimit", side_effect=lambda _: current[0]), \
             patch.object(payload.resource, "setrlimit", side_effect=setter), \
             patch.object(payload.resource, "getpagesize", return_value=1), \
             patch.object(payload, "emit_limit") as emit:
            payload.address_space_boundary("moving")
        summaries = [call for call in emit.call_args_list if call.args[0] == "boundary"]
        self.assertEqual(len(summaries), 1)
        self.assertFalse(summaries[0].kwargs["endpointsConfirmed"])
        self.assertEqual(current[0], original)

    def test_boundary_search_restores_limits_after_each_attempt(self):
        original = (payload.resource.RLIM_INFINITY,) * 2
        current = [original]
        attempts = []
        threshold = 16 * 1024 * 1024 * 1024

        def setter(which, pair):
            self.assertEqual(which, payload.resource.RLIMIT_AS)
            self.assertEqual(pair[1], original[1])
            if pair != original:
                self.assertEqual(current[0], original)
                attempts.append(pair)
                if pair[0] < threshold:
                    raise ValueError("current limit exceeds maximum limit")
            current[0] = pair

        with patch.object(payload.resource, "getrlimit", side_effect=lambda _: current[0]), \
             patch.object(payload.resource, "setrlimit", side_effect=setter), \
             patch.object(payload.resource, "getpagesize", return_value=16384), \
             patch.object(payload, "emit_limit"):
            lower, upper = payload.address_space_boundary("test")
        self.assertEqual(upper, threshold)
        self.assertEqual(lower, threshold - 16384)
        self.assertEqual(current[0], original)
        self.assertLessEqual(len(attempts), 64)

    def test_probe_memory_error_is_not_a_refused_allocation_pass(self):
        original = (payload.resource.RLIM_INFINITY,) * 2
        calls = []

        def setter(which, pair):
            calls.append(pair)
            if pair != original:
                raise MemoryError("probe bookkeeping failed")

        with patch.object(payload.resource, "getrlimit", return_value=original), \
             patch.object(payload.resource, "setrlimit", side_effect=setter), \
             patch.object(payload, "emit_limit"):
            with self.assertRaises(MemoryError):
                payload.address_space_boundary("test")
        self.assertEqual(calls[-1], original)

    def test_diagnostic_error_does_not_mask_original_setrlimit_failure(self):
        original_error = ValueError("current limit exceeds maximum limit")
        limits = (payload.resource.RLIM_INFINITY,) * 2
        with patch.object(payload.resource, "getrlimit", return_value=limits), \
             patch.object(payload.resource, "setrlimit", side_effect=original_error), \
             patch.object(payload, "address_space_boundary", side_effect=RuntimeError("diagnostic failed")), \
             patch.object(payload, "post_failure_map") as mapping, patch.object(payload, "emit_limit") as emit:
            with self.assertRaises(ValueError) as raised:
                payload.set_address_space_limit(6 * 1024 ** 3)
        self.assertIs(raised.exception, original_error)
        mapping.assert_not_called()
        self.assertIn("diagnostic-failure", [call.args[0] for call in emit.call_args_list])

    def test_success_does_not_probe_or_raise_the_requested_limit(self):
        with patch.object(payload.resource, "getrlimit", return_value=(123, 123)), \
             patch.object(payload.resource, "setrlimit") as setter, \
             patch.object(payload, "address_space_boundary") as boundary, \
             patch.object(payload, "post_failure_map") as mapping, patch.object(payload, "emit_limit"):
            payload.set_address_space_limit(123)
        setter.assert_called_once_with(payload.resource.RLIMIT_AS, (123, 123))
        boundary.assert_not_called()
        mapping.assert_not_called()

    def test_failed_logging_and_restore_preserve_original_limit_error(self):
        original = ValueError("current limit exceeds maximum limit")

        def emit(stage, **_):
            if stage != "before-original-call":
                raise OSError("stdout unavailable")

        with patch.object(payload.resource, "getrlimit", return_value=(-1, -1)), \
             patch.object(payload.resource, "setrlimit", side_effect=original), \
             patch.object(payload, "address_space_boundary", side_effect=OSError("restore failed")), \
             patch.object(payload, "emit_limit", side_effect=emit):
            with self.assertRaises(ValueError) as raised:
                payload.set_address_space_limit(6 * 1024 ** 3)
        self.assertIs(raised.exception, original)

    def test_permission_failure_is_not_an_address_space_lower_bracket(self):
        original = (-1, -1)

        def setter(_, pair):
            if pair != original:
                raise ValueError("not allowed to raise maximum limit")

        with patch.object(payload.resource, "getrlimit", return_value=original), \
             patch.object(payload.resource, "setrlimit", side_effect=setter), \
             patch.object(payload, "emit_limit"):
            with self.assertRaisesRegex(ValueError, "not allowed"):
                payload.address_space_boundary("permission")


class RetainedComponentTests(unittest.TestCase):
    def test_retained_native_receipts_cannot_cover_changed_native_sources(self):
        root = Path(__file__).resolve().parents[1]
        for name, digest in RETAINED_NATIVE_FILES.items():
            with self.subTest(name=name):
                self.assertEqual(hashlib.sha256((root / name).read_bytes()).hexdigest(), digest)

    def setUp(self):
        self.now = datetime.datetime(2026, 10, 27, tzinfo=datetime.timezone.utc)
        self.run = dict(id=RETAINED_RUN, head_sha=RETAINED_SOURCE, run_attempt=1, status="completed",
            conclusion="failure", event="workflow_dispatch", path=".github/workflows/native-acceptance-probes.yml",
            actor=dict(login="iret77"), repository=dict(full_name="iret77/nexgenvideo"))
        self.jobs = dict(total_count=3, jobs=[])
        for name, identifier, conclusion in [("sandbox-source", 121824433566, "success"),
                ("sandbox-build", 121824609450, "success"), ("sandbox-runtime", 121824891750, "failure")]:
            self.jobs["jobs"].append(dict(id=identifier, name=name, status="completed", conclusion=conclusion,
                run_id=RETAINED_RUN, run_attempt=1, head_sha=RETAINED_SOURCE,
                started_at="2026-10-26T20:20:00Z", completed_at="2026-10-26T20:26:00Z"))
        self.artifacts = {}
        for kind, (identifier, name, size, digest, _) in RETAINED_ARTIFACTS.items():
            self.artifacts[kind] = dict(id=identifier, name=name, size_in_bytes=size, digest="sha256:" + digest,
                expired=False, workflow_run=dict(id=RETAINED_RUN, head_sha=RETAINED_SOURCE),
                created_at="2026-10-26T20:25:00Z", updated_at="2026-10-26T20:25:00Z",
                expires_at="2026-11-25T20:25:00Z")

    def check(self):
        validate_retained(self.run, self.jobs, self.artifacts, self.now)

    def test_exact_failed_component_can_reuse_its_successful_helper(self):
        self.check()

    def test_different_run_attempt_source_workflow_or_actor_is_rejected(self):
        original = deepcopy(self.run)
        for field, value in [("id", RETAINED_RUN + 1), ("head_sha", "f" * 40), ("run_attempt", 2),
                             ("conclusion", "success"), ("status", "in_progress"), ("event", "pull_request"),
                             ("path", ".github/workflows/ci.yml"), ("actor", dict(login="another-owner")),
                             ("repository", dict(full_name="iret77/other"))]:
            self.run = deepcopy(original)
            self.run[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check()

    def test_partial_duplicate_failed_build_or_other_attempt_cannot_supply_helper(self):
        original = deepcopy(self.jobs)
        for mutate in [lambda j: j.update(total_count=4), lambda j: j["jobs"].pop(),
                       lambda j: j["jobs"].append(deepcopy(j["jobs"][1])),
                       lambda j: j["jobs"][1].update(conclusion="failure"),
                       lambda j: j["jobs"][1].update(id=999),
                       lambda j: j["jobs"][1].update(run_attempt=2),
                       lambda j: j["jobs"][1].update(head_sha="f" * 40)]:
            self.jobs = deepcopy(original)
            mutate(self.jobs)
            with self.assertRaises(ValueError):
                self.check()

    def test_substituted_expired_or_other_attempt_artifact_is_rejected(self):
        original = deepcopy(self.artifacts)
        for kind in original:
            for field, value in [("id", 999), ("name", "substituted"), ("size_in_bytes", 1),
                                 ("digest", "sha256:" + "f" * 64), ("expired", True),
                                 ("workflow_run", dict(id=RETAINED_RUN + 1, head_sha=RETAINED_SOURCE)),
                                 ("created_at", "2026-10-25T20:25:00Z"),
                                 ("updated_at", "2026-10-27T20:25:00Z"),
                                 ("expires_at", "2026-10-26T20:26:00Z")]:
                self.artifacts = deepcopy(original)
                self.artifacts[kind][field] = value
                with self.subTest(kind=kind, field=field), self.assertRaises(ValueError):
                    self.check()
        self.artifacts = {"binary": original["binary"]}
        with self.assertRaises(ValueError):
            self.check()


class NativeSectionEvidenceTests(unittest.TestCase):
    def binary(self):
        header = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 2, 1, 152, 0, 0)
        segment = struct.pack("<II16sQQQQiiII", 0x19, 152, b"__TEXT", 0, 4096, 0, 188, 5, 5, 1, 0)
        section = struct.pack("<16s16sQQ8I", b"__text", b"__TEXT", 184, 4, 184, 2, 0, 0, 0x80000400, 0, 0, 0)
        return header + segment + section + b"CODE"

    def test_only_section_identity_and_content_are_attested(self):
        self.assertEqual(native_sections(self.binary()), native_sections(self.binary() + b"signature data"))

    def test_changed_native_code_changes_section_evidence(self):
        self.assertNotEqual(native_sections(self.binary()), native_sections(self.binary()[:-4] + b"EVIL"))

    def test_malformed_header_command_section_or_payload_is_rejected(self):
        source = self.binary()
        corruptions = [source[:10], b"BAD!" + source[4:], source[:-1]]
        for offset, value in [(4, 7), (16, 999), (20, 999999), (36, 7), (96, 999)]:
            altered = bytearray(source)
            struct.pack_into("<I", altered, offset, value)
            corruptions.append(bytes(altered))
        for data in corruptions:
            with self.subTest(data=data[:40]), self.assertRaises(ValueError):
                native_sections(data)


class ExecutionAndCopyEvidenceTests(unittest.TestCase):
    def test_rerun_or_missing_current_execution_is_rejected(self):
        self.assertEqual(execution_identity({"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}),
                         dict(runID=123, runAttempt=1))
        for environment in [{}, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"},
                            {"GITHUB_RUN_ID": "0", "GITHUB_RUN_ATTEMPT": "1"},
                            {"GITHUB_RUN_ID": "invalid", "GITHUB_RUN_ATTEMPT": "1"}]:
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                execution_identity(environment)

    def test_copy_proof_detects_content_modes_links_and_extra_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "python/bin").mkdir(parents=True)
            python = root / "python/bin/python3.13"
            python.write_bytes(b"old executable signature")
            data = root / "data"
            data.write_bytes(b"original data")
            os.symlink("data", root / "link")
            original = tree_manifest(root)
            python.write_bytes(b"new executable signature")
            copied = tree_manifest(root)
            require_python_only_change(original, copied)
            mutations = [lambda m: m["data"].update(sha256="f" * 64),
                         lambda m: m["data"].update(mode=0o777),
                         lambda m: m["link"].update(target="/outside"),
                         lambda m: m.update(extra=dict(type="file")),
                         lambda m: m.pop("data"),
                         lambda m: m["python/bin/python3.13"].update(type="symlink")]
            for mutate in mutations:
                altered = deepcopy(copied)
                mutate(altered)
                with self.assertRaises(ValueError):
                    require_python_only_change(original, altered)
            data.write_bytes(b"changed data")
            with self.assertRaises(ValueError):
                require_python_only_change(original, tree_manifest(root))

    def test_absent_entitlements_are_empty_but_invalid_bytes_fail(self):
        self.assertEqual(entitlements(b""), {})
        self.assertEqual(entitlements(b" \n"), {})
        with self.assertRaises(Exception):
            entitlements(b"not a plist")

    def test_only_tagged_native_records_are_parsed(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "output.log"
            path.write_bytes(b'{Blender status text}\nNGV_COMPONENT {"pid": 123}\n')
            self.assertEqual(records(path), [dict(pid=123)])
            path.write_bytes(b'NGV_COMPONENT {bad JSON}\n')
            with self.assertRaises(json.JSONDecodeError):
                records(path)

    def test_privileged_cleanup_cannot_signal_a_foreign_group(self):
        process = Mock(pid=123)
        process.poll.return_value = None
        with patch("bpy_worker_sandbox_probe.os.killpg", side_effect=PermissionError), \
             patch("bpy_worker_sandbox_probe.os.getpgid", return_value=999), \
             patch("bpy_worker_sandbox_probe.subprocess.run") as run:
            with self.assertRaises(ValueError):
                signal_group(process, signal.SIGTERM, privileged=True)
            run.assert_not_called()

    def test_cleanup_failure_preserves_primary_error_and_process_receipt(self):
        process = Mock(pid=123, returncode=None)
        process.poll.return_value = None
        process.wait.side_effect = RuntimeError("primary interruption")
        with tempfile.TemporaryDirectory() as folder, \
             patch("bpy_worker_sandbox_probe.subprocess.Popen", return_value=process), \
             patch("bpy_worker_sandbox_probe.signal_group", side_effect=OSError("cleanup denied")):
            output = Path(folder) / "owned"
            with self.assertRaisesRegex(RuntimeError, "primary interruption"):
                run_command(["unused"], output)
            receipt = json.loads(output.with_suffix(".process.json").read_text())
            self.assertFalse(receipt["reaped"])
            self.assertIn("cleanup denied", receipt["cleanupError"])


if __name__ == "__main__":
    unittest.main()
