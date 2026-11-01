import copy
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

import bpy_runtime_acceptance as driver
from bpy_runtime_acceptance import capture_open_logs, collect_hangs, diagnostic_error, stop_open_capture, supervise, verify_crash, verify_storage_scope


class StorageScopeProofTests(unittest.TestCase):
    binary = Path("/fixture/NexGenVideo.app/Contents/MacOS/NexGenVideo")

    def events(self, stale=True, data_stale=False):
        session, owner = str(uuid.uuid4()), str(uuid.uuid4())
        common = f"session={session} owner={owner}"
        messages = [
            (456, f"open.prepared {common} pid=456 start=42"),
            (123, f"open.preparation session={session} servicePID=456 serviceStart=42"),
        ]
        scopes = []
        for role, lease, device, capacity, digest, freshness in (
                ("worker", session, 100, 2147483648, "a" * 64, stale),
                ("data", str(uuid.uuid4()), 200, 6442450944, "b" * 64, data_stale)):
            messages.append((123, f"bookmark.resolve id={lease} pair={session} role={role} device={device} "
                f"capacity={capacity} attempt=1 stale=false file=true pathMatches=true sha256={digest} volumeMatch=equal"))
            identity = f"{common} pid=456 start=42 pair={session} storage={lease} role={role}"
            scopes.extend([
                (456, f"open.beforeScope {identity} errno=1 closeErrno=0"),
                (456, f"open.check {identity} stale={str(freshness).lower()} file=true pathMatches=true sha256={digest} volumeMatch=equal"),
                (456, f"open.validated {identity} sha256={digest} device={device} capacity={capacity}"),
            ])
        messages.extend(scopes)
        diagnostics = ("lstatErrno=0 lstatType=32768 lstatMode=493 lstatFlags=0 statErrno=0 statType=32768 "
                       "statMode=493 statFlags=0 existsErrno=0 readErrno=0 executeErrno=0 openErrno=0 "
                       "closeErrno=0 foundationExecutable=1 quarantineErrno=93 quarantinePresent=0 "
                       "provenanceErrno=93 provenancePresent=0")
        for role in ("pythonAlias", "pythonTarget", "supervisor", "worker", "sitePackages"):
            fields = diagnostics + (" readlinkErrno=0 targetMatches=1" if role == "pythonAlias" else "")
            messages.append((456, f"open.runtime-resource session={session} pid=456 start=42 role={role} {fields}"))
        messages.extend([
            (456, f"open.runtime-preflight session={session} pid=456 start=42 python=true supervisor=true worker=true sitePackages=true"),
            (456, f"open.result {common} ok=true"),
        ])
        return [dict(processID=pid, eventMessage=message, machTimestamp=index + 1,
                     subsystem="de.h5ventures.nexgenvideo" + (".bpy-service" if pid == 456 else ""),
                     category="open-diagnostic" if pid == 456 else "bpy-open",
                     processImagePath=(str(self.binary) if pid == 123 else
                         "/fixture/NexGenVideo.app/Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/MacOS/NexGenVideoBpyService"))
                for index, (pid, message) in enumerate(messages)]

    def check(self, events):
        return verify_storage_scope("Filtering the log data using predicate\n" +
            "\n".join(json.dumps(event) for event in events), dict(pid=123), self.binary)

    def event(self, events, tag, role=None):
        return next(item for item in events if item["eventMessage"].startswith(tag + " ")
                    and (role is None or "role=" + role + " " in item["eventMessage"]))

    def test_actual_boundary_evidence_accepts_either_receiver_freshness(self):
        for stale in (False, True):
            for data_stale in (False, True):
                proof = self.check(self.events(stale, data_stale))
                self.assertEqual(proof["schema"], "nexgenvideo/bpy-storage-scope/2")
                self.assertEqual(set(proof["storageRoles"]), {"worker", "data"})
                for role, freshness in (("worker", stale), ("data", data_stale)):
                    self.assertEqual(proof["storageRoles"][role]["receiverStale"], freshness)
                    self.assertEqual(proof["storageRoles"][role]["preScopeErrno"], 1)

    def test_missing_duplicated_foreign_or_reordered_events_cannot_prove_the_boundary(self):
        for index in range(len(self.events())):
            for mutation in ("missing", "duplicate", "pid", "image", "category", "time"):
                with self.subTest(index=index, mutation=mutation):
                    events = self.events()
                    if mutation == "missing":
                        del events[index]
                    elif mutation == "duplicate":
                        events.append(dict(events[index]))
                    elif mutation == "pid":
                        events[index]["processID"] = 999
                    elif mutation == "image":
                        events[index]["processImagePath"] = "/foreign/NexGenVideo"
                    elif mutation == "category":
                        events[index]["category"] = "foreign"
                    else:
                        events[index]["machTimestamp"] = events[(index + 1) % len(events)]["machTimestamp"]
                    with self.assertRaises((AssertionError, KeyError, ValueError)):
                        self.check(events)

    def test_preexisting_access_wrong_identity_or_failed_open_is_rejected(self):
        for role, digest in (("worker", "a" * 64), ("data", "b" * 64)):
            for tag, old, new in (("open.beforeScope", "errno=1", "errno=0"),
                    ("open.beforeScope", "errno=1", "errno=2"), ("open.beforeScope", "closeErrno=0", "closeErrno=5"),
                    ("open.check", "file=true", "file=false"), ("open.check", "pathMatches=true", "pathMatches=false"),
                    ("open.check", "volumeMatch=equal", "volumeMatch=different"),
                    ("open.validated", "sha256=" + digest, "sha256=" + "c" * 64),
                    ("open.validated", "start=42", "start=43")):
                with self.subTest(role=role, tag=tag, new=new):
                    events = self.events()
                    event = self.event(events, tag, role)
                    event["eventMessage"] = event["eventMessage"].replace(old, new)
                    with self.assertRaises(AssertionError):
                        self.check(events)
        events = self.events()
        self.event(events, "open.result")["eventMessage"] = self.event(events, "open.result")["eventMessage"].replace("ok=true", "ok=false")
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_missing_denied_or_foreign_runtime_preflight_cannot_prove_startup(self):
        for tag, old, new in (
                ("role=pythonTarget", "executeErrno=0", "executeErrno=1"),
                ("role=pythonTarget", "foundationExecutable=1", "foundationExecutable=0"),
                ("role=pythonTarget", "statType=32768", "statType=16384"),
                ("role=pythonAlias", "readlinkErrno=0", "readlinkErrno=unknown"),
                ("role=supervisor", "start=42", "start=43"),
                ("role=worker", "openErrno=0", "omitted=0"),
                ("role=sitePackages", "provenancePresent=0", "provenancePresent=2"),
                ("open.runtime-preflight", "supervisor=true", "supervisor=false")):
            with self.subTest(tag=tag, new=new):
                events = self.events()
                event = next(item for item in events if tag in item["eventMessage"]
                    and item["eventMessage"].startswith(("open.runtime-resource ", "open.runtime-preflight ")))
                event["eventMessage"] = event["eventMessage"].replace(old, new)
                with self.assertRaises(AssertionError):
                    self.check(events)

    def test_alias_denial_remains_visible_without_weakening_target_access(self):
        events = self.events()
        alias = next(item for item in events if "role=pythonAlias" in item["eventMessage"])
        alias["eventMessage"] = alias["eventMessage"].replace("executeErrno=0", "executeErrno=1").replace(
            "foundationExecutable=1", "foundationExecutable=0")
        proof = self.check(events)
        self.assertEqual(proof["runtimeResources"]["pythonAlias"]["executeErrno"], 1)
        self.assertEqual(proof["runtimeResources"]["pythonTarget"]["executeErrno"], 0)

    def test_host_refresh_must_finish_fresh_and_malformed_capture_is_not_ignored(self):
        events = self.events()
        original = self.event(events, "bookmark.resolve", "worker")
        refresh = dict(original)
        original["eventMessage"] = original["eventMessage"].replace("stale=false", "stale=true")
        refresh["eventMessage"] = refresh["eventMessage"].replace("attempt=1", "attempt=2")
        events.insert(events.index(original) + 1, refresh)
        for index, event in enumerate(events):
            event["machTimestamp"] = index + 1
        self.check(events)
        for text in ("malformed", "{bad json}"):
            with self.assertRaises(ValueError):
                verify_storage_scope(text, dict(pid=123), self.binary)

    def test_one_volume_or_unknown_role_cannot_prove_the_storage_pair(self):
        for role in ("worker", "data"):
            events = [item for item in self.events() if "role=" + role + " " not in item["eventMessage"]
                      or item["eventMessage"].startswith("open.runtime-resource ")]
            with self.assertRaises(AssertionError):
                self.check(events)
        events = self.events()
        extra = dict(self.event(events, "open.check", "data"))
        extra["eventMessage"] = extra["eventMessage"].replace("role=data", "role=other")
        with self.assertRaises(AssertionError):
            self.check(events + [extra])
        extra = dict(self.event(events, "bookmark.resolve", "data"))
        extra["eventMessage"] = extra["eventMessage"].replace("role=data", "role=other")
        with self.assertRaises(AssertionError):
            self.check(events + [extra])

    def test_paired_lease_device_and_capacity_substitutions_are_rejected(self):
        for tag, old, new in (("open.validated", "device=200", "device=201"),
                ("open.validated", "capacity=6442450944", "capacity=6442450943"),
                ("open.check", "storage=", "storage=foreign"),
                ("bookmark.resolve", "pair=", "pair=foreign")):
            events = self.events()
            event = self.event(events, tag, "data")
            event["eventMessage"] = event["eventMessage"].replace(old, new)
            with self.assertRaises((AssertionError, ValueError)):
                self.check(events)
        events = self.events()
        for tag in ("bookmark.resolve", "open.validated"):
            event = self.event(events, tag, "data")
            event["eventMessage"] = event["eventMessage"].replace("device=200", "device=100")
        with self.assertRaises(AssertionError):
            self.check(events)

    def test_a_host_refresh_cannot_change_the_lease_or_skip_the_initial_scope(self):
        for old, new in (("device=100", "device=101"), ("file=true", "file=false"),
                         ("volumeMatch=equal", "volumeMatch=different")):
            events = self.events()
            original = self.event(events, "bookmark.resolve", "worker")
            refresh = dict(original)
            original["eventMessage"] = original["eventMessage"].replace("stale=false", "stale=true").replace(old, new)
            refresh["eventMessage"] = refresh["eventMessage"].replace("attempt=1", "attempt=2")
            events.insert(events.index(original) + 1, refresh)
            for index, event in enumerate(events):
                event["machTimestamp"] = index + 1
            with self.assertRaises(AssertionError):
                self.check(events)


class VerifierConfigurationTests(unittest.TestCase):
    def test_runtime_entrypoint_binds_exact_verifier_config_to_original_storage(self):
        session = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        job = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
        other = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
        cases = [("valid-slot-0", 0, True), ("valid-slot-1", 1, True)] + [
            (name, 0, False) for name in ["wrong-slot", "wrong-session", "wrong-job", "data-volume",
                "directory-prefix", "extra-child", "foreign-root", "foreign-executable", "foreign-data-mount",
                "foreign-storage-session", "foreign-scene-job", "wrong-source", "wrong-fingerprint",
                "missing-pair", "missing-verification", "missing-scene-job", "missing-protocol-reference", "changed-protocol"]
        ]
        for name, slot, accepted in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                app, output = root / "NexGenVideo.app", root / "evidence"
                binary = app / "Contents/MacOS/NexGenVideo"
                binary.parent.mkdir(parents=True)
                binary.write_text("native fixture is never executed")
                output.mkdir()
                worker = Path("/cache/BpyVolumes") / f"de.h5ventures.nexgenvideo.bpy-service-{slot}" / "mount"
                data = worker.parent.with_name(worker.parent.name + "-data") / "mount"
                config = str(worker / session / "jobs" / job / "verification/blender-config")
                executable = str(app / "Contents/XPCServices" / f"NexGenVideoBpyService{slot}.xpc"
                                 / "Contents/Resources/BpyRuntime/python/bin/python3.13")
                reference = {"schema": "nexgenvideo/bpy-open-session/2", "sessionID": session,
                    "storagePair": {"schema": "nexgenvideo/bpy-storage-pair/1", "id": other,
                        "worker": {"role": "worker", "pairID": other, "device": 11, "mountPath": str(worker)},
                        "data": {"role": "data", "pairID": other, "device": 22, "mountPath": str(data)}}}
                verification = {"jobID": job, "fingerprint": "f" * 64, "sessionRoot": str(data / session),
                                "blenderUserConfig": config, "executable": executable}
                scene = {"schema": "nexgenvideo/bpy-scene-acceptance/1", "sourceSHA": "a" * 40,
                    "jobID": job, "response": {"ok": True, "jobID": job, "jobFingerprint": "f" * 64}}
                paths = {"wrong-slot": config.replace("bpy-service-0/", "bpy-service-1/"),
                    "wrong-session": config.replace(session, other), "wrong-job": config.replace(job, other),
                    "data-volume": str(data / session / "jobs" / job / "verification/blender-config"),
                    "directory-prefix": str(data / session / "blender-config"), "extra-child": config + "/extra",
                    "foreign-root": "/foreign/verification/blender-config"}
                if name in paths:
                    verification["blenderUserConfig"] = paths[name]
                elif name == "foreign-executable":
                    verification["executable"] = executable.replace("BpyService0.xpc", "BpyService1.xpc")
                elif name == "foreign-data-mount":
                    reference["storagePair"]["data"]["mountPath"] = str(data).replace("service-0-data", "service-1-data")
                elif name == "foreign-storage-session":
                    reference["sessionID"] = other
                elif name == "foreign-scene-job":
                    verification["jobID"] = other
                    verification["blenderUserConfig"] = config.replace(job, other)
                elif name == "wrong-source":
                    scene["sourceSHA"] = "b" * 40
                elif name == "wrong-fingerprint":
                    scene["response"]["jobFingerprint"] = "e" * 64
                elif name == "missing-pair":
                    reference.pop("storagePair")
                protocol = {"schema": "nexgenvideo/bpy-native-protocol-evidence/4",
                    "storageReference": base64.b64encode(json.dumps(reference).encode()).decode()}
                if name == "missing-protocol-reference":
                    protocol.pop("storageReference")
                protocol_bytes = json.dumps(protocol).encode()
                result = {"trustedVerification": verification,
                          "nativeProtocolEvidenceSHA256": hashlib.sha256(protocol_bytes).hexdigest()}
                if name == "missing-verification":
                    result.pop("trustedVerification")
                elif name == "missing-scene-job":
                    scene.pop("jobID")
                if name == "changed-protocol":
                    protocol_bytes += b"\n"
                (output / "result.json").write_text(json.dumps(result))
                (output / "native-protocol-evidence.json").write_bytes(protocol_bytes)
                (output / "acceptance-scene-response.json").write_text(json.dumps(scene))
                args = ["bpy_runtime_acceptance.py", str(app), "--mode", "runtime", "--output", str(output),
                        "--source-sha", "a" * 40, "--deadline", str(time.time() + 30)]
                with mock.patch.object(sys, "argv", args), mock.patch.object(driver, "supervise") as supervised, \
                     mock.patch.object(driver.signal, "signal"):
                    if accepted:
                        driver.main()
                    else:
                        with self.assertRaises((AssertionError, KeyError, ValueError, TypeError)):
                            driver.main()
                    supervised.assert_called_once()


class OpenCaptureTests(unittest.TestCase):
    def test_isolated_runtime_entrypoint_keeps_working_without_local_imports(self):
        script = Path(__file__).with_name("bpy_runtime_acceptance.py")
        result = subprocess.run([sys.executable, "-I", str(script), "--help"],
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_probe_failure_is_preserved_and_capture_is_reaped(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            process = mock.Mock(pid=123, returncode=-signal.SIGTERM)
            process.poll.side_effect = [None, None, None, -signal.SIGTERM]
            with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                 mock.patch("bpy_runtime_acceptance.time.sleep"), \
                 mock.patch("bpy_runtime_acceptance.stop_open_capture") as stop:
                with self.assertRaisesRegex(AssertionError, "original probe failure"):
                    with capture_open_logs(output):
                        raise AssertionError("original probe failure")
            stop.assert_called_once_with(process)
            receipt = json.loads((output / "open-capture.json").read_text())
            self.assertTrue(receipt["reaped"])
            self.assertFalse(receipt["stoppedEarly"])

    def test_early_capture_exit_does_not_pass_as_complete(self):
        for during_probe in (False, True):
            with self.subTest(during_probe=during_probe), tempfile.TemporaryDirectory() as temporary:
                process = mock.Mock(pid=123, returncode=1)
                process.poll.side_effect = [None if during_probe else 1, None if during_probe else 1, 1, 1]
                with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                     mock.patch("bpy_runtime_acceptance.time.sleep"), \
                     mock.patch("bpy_runtime_acceptance.stop_open_capture"):
                    with self.assertRaisesRegex(AssertionError, "stream"):
                        with capture_open_logs(Path(temporary)):
                            self.assertTrue(during_probe)
                receipt = json.loads((Path(temporary) / "open-capture.json").read_text())
                self.assertTrue(receipt["stoppedEarly"])

    def test_cleanup_escalates_only_the_owned_process_group(self):
        process = mock.Mock(pid=123)
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired("owned log", 5), -signal.SIGKILL]
        with mock.patch("bpy_runtime_acceptance.subprocess.run") as signal_process:
            stop_open_capture(process)
        self.assertEqual([call.args[0] for call in signal_process.call_args_list], [
            ["/usr/bin/sudo", "-n", "/bin/kill", "-TERM", "--", "-123"],
            ["/usr/bin/sudo", "-n", "/bin/kill", "-KILL", "--", "-123"],
        ])
        self.assertEqual(process.wait.call_count, 2)

    def test_cancellation_during_cleanup_is_recorded_after_reaping(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = mock.Mock(pid=123, returncode=-signal.SIGTERM)
            process.poll.side_effect = [None, None, None, -signal.SIGTERM]
            original_handler = signal.getsignal(signal.SIGTERM)

            def stop(_process):
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)

            with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                 mock.patch("bpy_runtime_acceptance.time.sleep"), \
                 mock.patch("bpy_runtime_acceptance.stop_open_capture", side_effect=stop):
                with self.assertRaisesRegex(InterruptedError, "cleanup"):
                    with capture_open_logs(Path(temporary)):
                        pass
            self.assertEqual(signal.getsignal(signal.SIGTERM), original_handler)
            receipt = json.loads((Path(temporary) / "open-capture.json").read_text())
            self.assertEqual(receipt["cancelled"], [signal.SIGTERM])
            self.assertTrue(receipt["reaped"])

    def test_cleanup_failure_keeps_the_original_error_and_records_both_states(self):
        for body_fails in (False, True):
            with self.subTest(body_fails=body_fails), tempfile.TemporaryDirectory() as temporary:
                process = mock.Mock(pid=123, returncode=None)
                process.poll.return_value = None
                with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                     mock.patch("bpy_runtime_acceptance.time.sleep"), \
                     mock.patch("bpy_runtime_acceptance.stop_open_capture", side_effect=RuntimeError("capture stuck")):
                    with self.assertRaisesRegex(AssertionError, "original failure" if body_fails else "cleanup failed"):
                        with capture_open_logs(Path(temporary)):
                            if body_fails:
                                raise AssertionError("original failure")
                receipt = json.loads((Path(temporary) / "open-capture.json").read_text())
                self.assertFalse(receipt["reaped"])
                self.assertIn("capture stuck", receipt["cleanupErrors"][0])

    def test_receipt_write_failure_does_not_replace_the_probe_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = mock.Mock(pid=123, returncode=0)
            process.poll.side_effect = [None, None, None, 0]
            with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                 mock.patch("bpy_runtime_acceptance.time.sleep"), \
                 mock.patch("bpy_runtime_acceptance.stop_open_capture"), \
                 mock.patch("bpy_runtime_acceptance.Path.write_text", side_effect=OSError("disk failure")):
                with self.assertRaisesRegex(AssertionError, "original failure"):
                    with capture_open_logs(Path(temporary)):
                        raise AssertionError("original failure")

    def test_exit_race_and_signal_timeout_still_wait_and_escalate(self):
        for signal_timeout in (False, True):
            with self.subTest(signal_timeout=signal_timeout):
                process = mock.Mock(pid=123)
                process.poll.return_value = None
                process.wait.side_effect = ([subprocess.TimeoutExpired("owned log", 5), 0]
                                            if signal_timeout else [0])
                with mock.patch("bpy_runtime_acceptance.subprocess.run") as kill:
                    kill.side_effect = ([subprocess.TimeoutExpired("signal", 5), mock.Mock(returncode=1)]
                                        if signal_timeout else [mock.Mock(returncode=1)])
                    stop_open_capture(process)
                self.assertEqual(process.wait.call_count, 2 if signal_timeout else 1)
                self.assertTrue(all(call.kwargs["check"] is False for call in kill.call_args_list))

    def test_final_log_delivery_is_drained_before_capture_is_stopped(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = mock.Mock(pid=123, returncode=-signal.SIGTERM)
            process.poll.side_effect = [None, None, None, -signal.SIGTERM]
            events = []
            with mock.patch("bpy_runtime_acceptance.subprocess.Popen", return_value=process), \
                 mock.patch("bpy_runtime_acceptance.time.sleep", side_effect=lambda delay: events.append(delay)), \
                 mock.patch("bpy_runtime_acceptance.stop_open_capture", side_effect=lambda _: events.append("stop")):
                with capture_open_logs(Path(temporary)):
                    events.append("probe")
            self.assertEqual(events, [0.5, "probe", 2, "stop"])


class HostCrashProofTests(unittest.TestCase):
    source = "a" * 40

    def proof(self, mode):
        value = dict(schema=1, pid=123, sourceSHA=self.source, state="running", mode=mode,
                     jobID=str(uuid.uuid4()), supervisorPID=456)
        if mode == "before-authorization":
            value["authorizationID"] = str(uuid.uuid4())
        else:
            value["workerPID"] = 789
        return value

    def test_requires_actual_sigkill_at_both_declared_stages(self):
        for mode in ("before-authorization", "after-authorization"):
            proof = self.proof(mode)
            verify_crash(proof, mode, 123, self.source, -signal.SIGKILL)
            for status in (0, 1, 70, -signal.SIGTERM, -signal.SIGABRT):
                with self.subTest(mode=mode, status=status), self.assertRaisesRegex(AssertionError, "intentional SIGKILL"):
                    verify_crash(proof, mode, 123, self.source, status)

    def test_rejects_foreign_identity_and_unreached_stage(self):
        proof = self.proof("before-authorization")
        for key, value in (("pid", 124), ("sourceSHA", "b" * 40), ("schema", 2),
                           ("state", "failed"), ("mode", "after-authorization"), ("supervisorPID", 123)):
            modified = dict(proof, **{key: value})
            with self.subTest(key=key), self.assertRaises(AssertionError):
                verify_crash(modified, "before-authorization", 123, self.source, -signal.SIGKILL)

    def test_pre_authorization_requires_lease_without_a_worker(self):
        proof = self.proof("before-authorization")
        for key, value in (("authorizationID", "bad-id"), ("workerPID", 789)):
            modified = dict(proof, **{key: value})
            with self.subTest(key=key), self.assertRaises((AssertionError, ValueError)):
                verify_crash(modified, "before-authorization", 123, self.source, -signal.SIGKILL)

    def test_post_authorization_requires_distinct_worker_without_pending_lease(self):
        proof = self.proof("after-authorization")
        for key, value in (("workerPID", None), ("workerPID", 123), ("workerPID", 456),
                           ("authorizationID", str(uuid.uuid4()))):
            modified = copy.deepcopy(proof)
            modified[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(AssertionError):
                verify_crash(modified, "after-authorization", 123, self.source, -signal.SIGKILL)


class SupervisionTests(unittest.TestCase):
    source = "a" * 40

    def test_diagnostic_write_ignores_disk_errors_but_preserves_ci_cancellation(self):
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch("bpy_runtime_acceptance.Path.write_text", side_effect=OSError("disk failure")):
                diagnostic_error(Path(temporary), "sample", ValueError("capture failed"))
            with mock.patch("bpy_runtime_acceptance.Path.write_text", side_effect=InterruptedError("CI stop")):
                with self.assertRaisesRegex(InterruptedError, "CI stop"):
                    diagnostic_error(Path(temporary), "sample", ValueError("capture failed"))

    def executable(self, root, source):
        binary = root / "owned-app"
        binary.write_text("#!" + sys.executable + "\n" + source)
        binary.chmod(0o755)
        return binary

    def test_all_bpy_modes_decline_recording_on_the_owned_process(self):
        source = '''import json, os, signal, sys, uuid
from pathlib import Path
output = Path(os.environ["NGV_BPY_COMMAND_EVIDENCE"])
(output / "launch-arguments.json").write_text(json.dumps(sys.argv[1:]))
(output / "launch-diagnostic-environment.json").write_text(json.dumps({"sandboxLogFlagPresent": "NGV_BPY_CAPTURE_SANDBOX_LOGS" in os.environ}))
mode = os.environ.get("NGV_SELFTEST_BPY_HOST_CRASH")
if mode:
    proof = dict(schema=1, pid=os.getpid(), sourceSHA="''' + self.source + '''", mode=mode,
                 state="running", jobID=str(uuid.uuid4()), supervisorPID=os.getpid() + 1)
    if mode == "before-authorization":
        proof["authorizationID"] = str(uuid.uuid4())
    else:
        proof["workerPID"] = os.getpid() + 2
    Path(os.environ["NGV_SELFTEST_BPY_HOST_CRASH_EVIDENCE"]).write_text(json.dumps(proof))
    os.kill(os.getpid(), signal.SIGKILL)
'''
        for mode in ("runtime", "before-authorization", "after-authorization"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                binary = self.executable(root, source)
                with mock.patch.dict(driver.os.environ, NGV_BPY_CAPTURE_SANDBOX_LOGS='1'), \
                        mock.patch.object(driver, "prepare_worker_postmortem", return_value=None), \
                        mock.patch.object(driver, "collect_hangs"):
                    supervise(binary, root / "evidence", mode, self.source, 3)
                    self.assertEqual(driver.os.environ['NGV_BPY_CAPTURE_SANDBOX_LOGS'], '1')
                self.assertEqual(json.loads((root / "evidence/launch-arguments.json").read_text()),
                                 ["-hangDiagnosticMode", "disabled"])
                self.assertEqual(json.loads((root / "evidence/launch-diagnostic-environment.json").read_text()),
                                 {"sandboxLogFlagPresent": False})
                result = json.loads((root / "evidence/process-result.json").read_text())
                self.assertEqual(result["returncode"], 0 if mode == "runtime" else -signal.SIGKILL)
                self.assertFalse((root / "evidence/process-failure.json").exists())

    def test_runtime_nonzero_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch("bpy_runtime_acceptance.sample_owned"):
            root = Path(temporary)
            binary = self.executable(root, "raise SystemExit(7)\n")
            with mock.patch("bpy_runtime_acceptance.Path.home", return_value=root / "home"):
                with self.assertRaisesRegex(AssertionError, "status 7"):
                    supervise(binary, root / "evidence", "runtime", self.source, 3)
            failure = json.loads((root / "evidence/process-failure.json").read_text())
            self.assertIn("status 7", failure["error"])

    def test_deadline_records_failure_and_reaps_its_child(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch("bpy_runtime_acceptance.sample_owned"):
            root = Path(temporary)
            binary = self.executable(root, "import time\ntime.sleep(30)\n")
            with mock.patch("bpy_runtime_acceptance.Path.home", return_value=root / "home"):
                with self.assertRaisesRegex(AssertionError, "timed out"):
                    supervise(binary, root / "evidence", "runtime", self.source, 0.05)
            failure = json.loads((root / "evidence/process-failure.json").read_text())
            try:
                with self.assertRaises(ProcessLookupError):
                    os.kill(failure["pid"], 0)
            finally:
                try:
                    os.kill(failure["pid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_sampler_or_report_copy_failure_cannot_change_a_successful_app_result(self):
        for failure_kind in ("sample", "copy"):
            with self.subTest(failure_kind=failure_kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                home = root / "home"
                hangs = home / "Library/Logs/NexGenVideo"
                hangs.mkdir(parents=True)
                binary = self.executable(root, """import json, os, time
from pathlib import Path
path = Path(os.environ['NGV_TEST_HANG_DIRECTORY']) / 'owned-main-thread-hang.json'
temporary = path.with_suffix('.partial')
temporary.write_text(json.dumps(dict(processID=os.getpid())))
os.replace(temporary, path)
time.sleep(0.3)
""")
                sample_error = subprocess.TimeoutExpired("sample", 30) if failure_kind == "sample" else None
                with mock.patch.dict(os.environ, NGV_TEST_HANG_DIRECTORY=str(hangs)), \
                     mock.patch("bpy_runtime_acceptance.Path.home", return_value=home), \
                     mock.patch("bpy_runtime_acceptance.sample_owned", side_effect=sample_error) as sampler:
                    if failure_kind == "copy":
                        with mock.patch("bpy_runtime_acceptance.Path.write_bytes", side_effect=OSError("capture disk failure")):
                            supervise(binary, root / "evidence", "runtime", self.source, 3)
                    else:
                        supervise(binary, root / "evidence", "runtime", self.source, 3)
                        sampler.assert_called_once()
                result = json.loads((root / "evidence/process-result.json").read_text())
                self.assertEqual(result["returncode"], 0)
                self.assertTrue((root / "evidence/hang-1-error.json").is_file())
                error = json.loads((root / "evidence/hang-1-error.json").read_text())["error"]
                self.assertIn("timed out" if failure_kind == "sample" else "capture disk failure", error)
                self.assertFalse((root / "evidence/process-failure.json").exists())

    def test_foreign_pid_report_never_triggers_sampling(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hangs = root / "Library/Logs/NexGenVideo"
            hangs.mkdir(parents=True)
            (hangs / "foreign-main-thread-hang.json").write_text(json.dumps(dict(processID=456)))
            process = mock.Mock(pid=123)
            captured = set()
            with mock.patch("bpy_runtime_acceptance.Path.home", return_value=root), \
                 mock.patch("bpy_runtime_acceptance.sample_owned") as sampler:
                collect_hangs(process, root, time.time() - 1, captured)
            sampler.assert_not_called()
            self.assertFalse(captured)

    def test_a_report_read_in_progress_is_retried_without_consuming_a_sample_slot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hangs = root / "Library/Logs/NexGenVideo"
            hangs.mkdir(parents=True)
            path = hangs / "owned-main-thread-hang.json"
            path.write_text("{")
            captured = set()
            process = mock.Mock(pid=123)
            with mock.patch("bpy_runtime_acceptance.Path.home", return_value=root), \
                 mock.patch("bpy_runtime_acceptance.sample_owned") as sampler:
                collect_hangs(process, root, time.time() - 1, captured)
                self.assertFalse(captured)
                sampler.assert_not_called()
                path.write_text(json.dumps(dict(processID=123)))
                collect_hangs(process, root, time.time() - 1, captured)
                sampler.assert_called_once()
                self.assertEqual(captured, {path})

    def test_ci_interruption_during_sampling_is_not_swallowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hangs = root / "home/Library/Logs/NexGenVideo"
            hangs.mkdir(parents=True)
            binary = self.executable(root, """import json, os, time
from pathlib import Path
path = Path(os.environ['NGV_TEST_HANG_DIRECTORY']) / 'owned-main-thread-hang.json'
temporary = path.with_suffix('.partial')
temporary.write_text(json.dumps(dict(processID=os.getpid())))
os.replace(temporary, path)
time.sleep(30)
""")
            with mock.patch.dict(os.environ, NGV_TEST_HANG_DIRECTORY=str(hangs)), \
                 mock.patch("bpy_runtime_acceptance.Path.home", return_value=root / "home"), \
                 mock.patch("bpy_runtime_acceptance.sample_owned", side_effect=InterruptedError("CI stop")):
                with self.assertRaisesRegex(InterruptedError, "CI stop"):
                    supervise(binary, root / "evidence", "runtime", self.source, 3)
            failure = json.loads((root / "evidence/process-failure.json").read_text())
            self.assertEqual(failure["error"], "CI stop")
            with self.assertRaises(ProcessLookupError):
                os.kill(failure["pid"], 0)

    def test_metadata_write_failure_still_reaps_the_started_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = self.executable(root, "import time\ntime.sleep(30)\n")
            children = []
            original_popen = subprocess.Popen
            original_write = Path.write_text

            def spawn(*args, **kwargs):
                process = original_popen(*args, **kwargs)
                children.append(process)
                return process

            def write(path, *args, **kwargs):
                if path.name == "process.json":
                    raise OSError("metadata write failed")
                return original_write(path, *args, **kwargs)

            try:
                with mock.patch("bpy_runtime_acceptance.subprocess.Popen", side_effect=spawn), \
                     mock.patch("bpy_runtime_acceptance.Path.write_text", new=write), \
                     mock.patch("bpy_runtime_acceptance.sample_owned"):
                    with self.assertRaisesRegex(OSError, "metadata write failed"):
                        supervise(binary, root / "evidence", "runtime", self.source, 3)
                self.assertEqual(len(children), 1)
                self.assertIsNotNone(children[0].poll())
                self.assertTrue((root / "evidence/process-failure.json").is_file())
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)


class WorkerPostmortemTests(unittest.TestCase):
    source = "a" * 40
    started = 1793408400
    image_uuid = "22222222-2222-2222-2222-222222222222"

    def record(self, root, change=None, metrics=None, omit_metrics=()):
        values = {"probe.exitStatus": 134, "probe.terminationSignal": -1,
                  "probe.workerPID": 42, "probe.supervisorPID": 41}
        values.update(metrics or {})
        for key in omit_metrics:
            values.pop(key)
        raw = json.dumps(dict(ok=False, metrics=values)).encode()
        record = dict(schema="nexgenvideo/bpy-open-failure/1", hostPID=40, sourceSHA=self.source,
                      sessionID=str(uuid.uuid4()), response=base64.b64encode(raw).decode(),
                      responseSHA256=hashlib.sha256(raw).hexdigest())
        record.update(change or {})
        path = root / "open-failure-owned.json"
        path.write_text(json.dumps(record))
        return path

    def preparation(self, root):
        return dict(templates=[dict(role="supervisor", hostExecutable="/app/Supervisor",
                                   hostSHA256="b" * 64, hostUUID="11111111-1111-1111-1111-111111111111"),
                               dict(role="python", hostExecutable="/app/python3.13",
                                    hostSHA256="c" * 64, hostUUID=self.image_uuid)],
                    directories=[str(root)], prefixes=("Supervisor", "Python", "python"),
                    baseline={}, preparationErrors=[], baselineErrors=[])

    def report(self, **changes):
        body = dict(pid=42, parentPid=41, procLaunch="2026-10-31T01:00:00Z",
                    captureTime="2026-10-31T01:00:00.5Z", procPath="/Users/USER/redacted/Python",
                    usedImages=[dict(uuid=self.image_uuid)], exception=dict(type="EXC_CRASH"))
        body.update(changes)
        return (json.dumps(dict(bug_type="309")) + "\n" + json.dumps(body)).encode()

    def test_failure_record_binds_the_worker_and_both_possible_images(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contexts = driver.failed_worker_contexts(self.record(root), 40, self.source,
                self.preparation(root), self.started, self.started + 1)
            self.assertEqual({c["role"] for c in contexts}, {"python", "supervisor"})
            self.assertTrue(all(c["pid"] == 42 and c["parentPID"] == 41 for c in contexts))
            with self.subTest(termination="supervisor"):
                contexts = driver.failed_worker_contexts(
                    self.record(root, metrics={"probe.terminationSignal": 6}), 40, self.source,
                    self.preparation(root), self.started, self.started + 1)
                self.assertEqual(len(contexts), 1)
                self.assertEqual(contexts[0]["role"], "supervisor")
                self.assertEqual(contexts[0]["pid"], 41)
                self.assertEqual(contexts[0]["parentPID"], 40)
            for metrics, omitted in (({"probe.exitStatus": 0}, ()),
                                     ({}, ("probe.exitStatus",)),
                                     ({"probe.workerPID": -1}, ())):
                with self.subTest(metrics=metrics, omitted=omitted):
                    self.assertEqual(driver.failed_worker_contexts(
                        self.record(root, metrics=metrics, omit_metrics=omitted), 40, self.source,
                        self.preparation(root), self.started, self.started + 1), [])

    def test_failure_record_rejects_foreign_forged_and_reused_process_metadata(self):
        for change in ({"hostPID": 99}, {"sourceSHA": "f" * 40}, {"responseSHA256": "0" * 64},
                       {"schema": "unknown"}, {"response": "invalid base64"}):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self.assertRaises((AssertionError, ValueError)):
                    driver.failed_worker_contexts(self.record(root, change), 40, self.source,
                        self.preparation(root), self.started, self.started + 1)
        for metrics in ({"probe.workerPID": 41}, {"probe.supervisorPID": 40},
                        {"probe.workerPID": float("nan")}, {"probe.workerPID": True}):
            with self.subTest(metrics=metrics), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                with self.assertRaises(AssertionError):
                    driver.failed_worker_contexts(self.record(root, metrics=metrics), 40, self.source,
                        self.preparation(root), self.started, self.started + 1)

    def collect(self, root):
        with mock.patch.object(driver, "capture_worker_log", return_value={}), \
             mock.patch.object(driver.time, "time", return_value=self.started + 1), \
             mock.patch.object(driver.time, "monotonic", side_effect=range(10000)), \
             mock.patch.object(driver.time, "sleep"), \
             mock.patch.dict(os.environ, {"GITHUB_SHA": "d" * 40}):
            return driver.collect_worker_postmortem(root, 40, self.source, self.preparation(root), self.started)

    def test_python_report_alias_is_bound_to_the_original_worker_image(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.record(root)
            raw = self.report()
            (root / "Python-owned.ips").write_bytes(raw)
            receipt = self.collect(root)
            self.assertEqual(receipt["status"], "bound-report-captured")
            self.assertEqual(receipt["appSourceSHA"], self.source)
            self.assertEqual(receipt["harnessSHA"], "d" * 40)
            self.assertEqual((root / "worker-postmortem/worker-42.ips").read_bytes(), raw)
            self.assertEqual(receipt["reports"][0]["sha256"], hashlib.sha256(raw).hexdigest())

    def test_foreign_parent_stale_time_and_wrong_image_reports_are_not_copied(self):
        for changes in ({"pid": 99}, {"parentPid": 99}, {"procLaunch": "2026-10-30T01:00:00Z"},
                        {"usedImages": [dict(uuid="another-image")]}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self.record(root)
                (root / "Python-unowned.ips").write_bytes(self.report(**changes))
                receipt = self.collect(root)
                self.assertEqual(receipt["status"], "no-bound-report")
                self.assertEqual(receipt["missingPIDs"], [42])
                self.assertEqual(list((root / "worker-postmortem").glob("*.ips")), [])

    def test_stable_report_reader_rejects_changed_bytes_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "Python-owned.ips"
            report.write_bytes(self.report())
            info = report.stat()
            identity = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
            report.write_bytes(self.report(pid=12345))
            with self.assertRaises(ValueError):
                driver.read_stable_crash_report(str(report), identity)
            link = root / "Python-link.ips"
            link.symlink_to(report)
            with self.assertRaises(OSError):
                driver.read_stable_crash_report(str(link), identity)

    def test_postmortem_failure_does_not_replace_the_original_probe_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = mock.Mock(pid=40, returncode=1)
            process.poll.return_value = 1
            with mock.patch.object(driver.subprocess, "Popen", return_value=process), \
                 mock.patch.object(driver, "prepare_worker_postmortem", return_value={}), \
                 mock.patch.object(driver, "collect_hangs"), mock.patch.object(driver, "sample_owned"), \
                 mock.patch.object(driver, "collect_worker_postmortem", side_effect=ValueError("capture failed")):
                with self.assertRaisesRegex(AssertionError, "before its crash was armed"):
                    supervise(root / "app", root, "before-authorization", self.source, 3)
            self.assertIn("before its crash was armed", json.loads((root / "process-failure.json").read_text())["error"])
            self.assertIn("capture failed", (root / "worker-postmortem-error.json").read_text())

    def test_postmortem_cancellation_is_propagated_after_owned_app_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = mock.Mock(pid=40, returncode=1)
            process.poll.return_value = 1
            with mock.patch.object(driver.subprocess, "Popen", return_value=process), \
                 mock.patch.object(driver, "prepare_worker_postmortem", return_value={}), \
                 mock.patch.object(driver, "collect_hangs"), mock.patch.object(driver, "sample_owned"), \
                 mock.patch.object(driver, "collect_worker_postmortem", side_effect=InterruptedError("cancelled")):
                with self.assertRaisesRegex(InterruptedError, "cancelled"):
                    supervise(root / "app", root, "before-authorization", self.source, 3)
            process.wait.assert_called_once_with(timeout=5)

    def test_unified_log_output_is_bounded_and_its_owned_process_is_reaped(self):
        original_popen = subprocess.Popen
        children = []

        def spawn(command, **kwargs):
            self.assertEqual(command[command.index("--process") + 1], "42")
            child = original_popen([sys.executable, "-c", "import os; os.write(1, b'x' * (5 * 1024 * 1024))"], **kwargs)
            children.append(child)
            return child

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contexts = [dict(pid=42, hostExecutable="/app/python3.13")]
            with mock.patch.object(driver.subprocess, "Popen", side_effect=spawn):
                result = driver.capture_worker_log(root, 42, contexts, self.started, self.started + 1,
                                                   time.monotonic() + 10)
            self.assertEqual(result["bytes"], 4 * 1024 * 1024)
            self.assertEqual(result["discardedBytes"], 1024 * 1024)
            self.assertEqual((root / "process-42.log").stat().st_size, 4 * 1024 * 1024)
            self.assertTrue(all(c.poll() is not None for c in children))


class LiveWorkerSampleTests(unittest.TestCase):
    app = Path('/app/NexGenVideo.app/Contents/MacOS/NexGenVideo')
    service = '/app/NexGenVideo.app/Contents/XPCServices/Service.xpc'
    image = '28e32694-8c96-33f4-9ebc-ab10afa8977b'

    def fixture(self, output):
        supervisor = self.service + '/Contents/MacOS/NexGenVideoBpySupervisor'
        python = self.service + '/Contents/Resources/BpyRuntime/python/bin/python3.13'
        identities = {pid: dict(pid=pid, parentPID=parent, start=pid * 10, imageUUID=self.image, executable=path)
                      for pid, parent, path in [(10, 9, str(self.app)), (20, 10, supervisor), (30, 20, python)]}
        reader = mock.Mock()
        reader.identity.side_effect = lambda pid: copy.deepcopy(identities.get(pid))
        reader.children.side_effect = lambda pid: [20] if pid == 10 else [30]
        process = mock.Mock(pid=10)
        process.poll.return_value = None
        templates = [dict(role=role, hostExecutable=identities[pid]['executable'], hostUUID=self.image)
                     for role, pid in [('supervisor', 20), ('python', 30)]]
        with mock.patch.object(driver, 'host_binary_identity', return_value=dict(hostExecutable=str(self.app), hostUUID=self.image)):
            capture = driver.WorkerSamples(process, self.app, dict(templates=templates), output, 'a' * 40, reader)
        return capture, identities, reader

    def sample(self, command, **kwargs):
        self.assertEqual(command[:5], ['/usr/bin/sample', '30', '1', '-mayDie', '-file'])
        self.assertEqual(kwargs['timeout'], 5)
        self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
        self.assertEqual(kwargs['stderr'], subprocess.STDOUT)
        text = ('Process: Python [30]\nParent Process: Supervisor [20]\n\nBinary Images:\n'
                '  0x1000 - 0x2000 Python (3.13) <' + self.image + '> ' + self.service +
                '/Contents/Resources/BpyRuntime/python/bin/python3.13\n')
        Path(command[-1]).write_text(text)
        return subprocess.CompletedProcess(command, 0)

    def test_owned_worker_capture_waits_for_age_and_is_bounded_to_two_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            capture, _, reader = self.fixture(output)
            with mock.patch.object(driver.subprocess, 'run', side_effect=self.sample) as run:
                for age, expected in [(0, 0), (19, 0), (20, 1), (21, 1), (59, 1), (60, 2), (61, 2), (120, 2)]:
                    capture.poll(age)
                    self.assertEqual(run.call_count, expected, age)
                self.assertEqual(run.call_count, 2)
            self.assertEqual(set(reader.children.call_args_list[0].args), {10})
            self.assertTrue(all(call.args[0] in {10, 20} for call in reader.children.call_args_list))
            for index in (1, 2):
                value = json.loads((output / f'live-workers/{index}.json').read_text())
                self.assertEqual(value['status'], 'verified')
                self.assertEqual(value['worker']['start'], 300)
                self.assertEqual(value['appSourceSHA'], 'a' * 40)
                raw = (output / f'live-workers/{index}.sample.txt').read_bytes()
                self.assertEqual(value['sampleSHA256'], hashlib.sha256(raw).hexdigest())

    def test_foreign_parent_image_and_reused_birth_never_trigger_a_sample(self):
        mutations = [('parentPID', 99), ('imageUUID', str(uuid.uuid4())), ('executable', '/foreign/python')]
        for pid in (20, 30):
            for field, value in mutations:
                with self.subTest(pid=pid, field=field), tempfile.TemporaryDirectory() as directory:
                    capture, identities, _ = self.fixture(Path(directory))
                    identities[pid][field] = value
                    with mock.patch.object(driver.subprocess, 'run') as run:
                        capture.poll(0)
                        capture.poll(60)
                        run.assert_not_called()
        with tempfile.TemporaryDirectory() as directory:
            capture, identities, _ = self.fixture(Path(directory))
            other = identities[30]['executable'].replace('/Service.xpc/', '/OtherService.xpc/')
            identities[30]['executable'] = other
            capture.templates.append(dict(role='python', hostExecutable=other, hostUUID=self.image))
            with mock.patch.object(driver.subprocess, 'run') as run:
                capture.poll(0)
                capture.poll(60)
                run.assert_not_called()
        with tempfile.TemporaryDirectory() as directory:
            capture, identities, _ = self.fixture(Path(directory))
            with mock.patch.object(driver.subprocess, 'run') as run:
                capture.poll(0)
                identities[30]['start'] += 1
                capture.poll(20)
                run.assert_not_called()
                identities[10]['start'] += 1
                capture.poll(60)
                run.assert_not_called()

    def test_sample_timeout_malformed_ancestry_and_identity_change_remain_unverified(self):
        for mode in ['timeout', 'parent', 'image', 'reused']:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                capture, identities, _ = self.fixture(Path(directory))
                def sample(command, **kwargs):
                    if mode == 'timeout':
                        raise subprocess.TimeoutExpired(command, 5)
                    result = self.sample(command, **kwargs)
                    path = Path(command[-1])
                    if mode == 'parent':
                        path.write_text(path.read_text().replace('[20]', '[99]'))
                    elif mode == 'image':
                        path.write_text(path.read_text().replace(self.image, str(uuid.uuid4())))
                    else:
                        identities[30]['start'] += 1
                    return result
                with mock.patch.object(driver.subprocess, 'run', side_effect=sample):
                    capture.poll(0)
                    capture.poll(20)
                receipt = json.loads((Path(directory) / 'live-workers/1.json').read_text())
                self.assertEqual(receipt['status'], 'unverified')
                self.assertIn('error', receipt)
                self.assertNotIn('sampleSHA256', receipt)

    def test_capture_cancellation_propagates_even_when_receipt_storage_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            capture, _, _ = self.fixture(Path(directory))
            with mock.patch.object(driver.subprocess, 'run', side_effect=InterruptedError('CI stop')), \
                    mock.patch.object(Path, 'write_text', side_effect=OSError('disk failure')):
                capture.poll(0)
                with self.assertRaisesRegex(InterruptedError, 'CI stop'):
                    capture.poll(20)
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                process = mock.Mock(pid=10, returncode=0)
                process.poll.side_effect = [None, None] if interrupted else [None, None, 0, 0]
                worker = mock.Mock()
                worker.poll.side_effect = InterruptedError('CI stop') if interrupted else RuntimeError('capture failed')
                with mock.patch.object(driver.sys, 'platform', 'darwin'), \
                        mock.patch.object(driver, 'prepare_worker_postmortem', return_value=dict(templates=[])), \
                        mock.patch.object(driver, 'WorkerReader'), \
                        mock.patch.object(driver, 'WorkerSamples', return_value=worker), \
                        mock.patch.object(driver, 'collect_hangs'), mock.patch.object(driver, 'sample_owned'), \
                        mock.patch.object(driver, 'collect_worker_postmortem'), \
                        mock.patch.object(driver.subprocess, 'Popen', return_value=process):
                    if interrupted:
                        with self.assertRaisesRegex(InterruptedError, 'CI stop'):
                            supervise(self.app, output, 'runtime', 'a' * 40, 3)
                        process.kill.assert_called_once()
                    else:
                        supervise(self.app, output, 'runtime', 'a' * 40, 3)
                        self.assertEqual(json.loads((output / 'process-result.json').read_text())['returncode'], 0)
                        self.assertTrue((output / 'live-worker-capture-error.json').is_file())
                    self.assertEqual(worker.poll.call_count, 1)
                    process.wait.assert_called_once_with(timeout=5)


class LiveWorkerSandboxLogTests(unittest.TestCase):
    def fixture(self, output):
        support = LiveWorkerSampleTests('test_owned_worker_capture_waits_for_age_and_is_bounded_to_two_samples')
        with mock.patch.dict(driver.os.environ, NGV_BPY_CAPTURE_SANDBOX_LOGS='1'):
            capture, identities, reader = support.fixture(output)
        return support, capture, identities, reader

    def test_diagnostic_logs_survive_sample_timeout_and_keep_two_owned_time_windows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, capture, _, _ = self.fixture(root)
            clock = [0.0]
            def query(folder, pid, contexts, started, observed, deadline, **kwargs):
                self.assertEqual(pid, 30)
                self.assertEqual(contexts, [dict(pid=30, hostExecutable=capture.templates[1]['hostExecutable'])])
                self.assertTrue(kwargs['include_sandbox'])
                self.assertEqual(started, 1001)
                self.assertEqual(observed, 1000 + int(clock[0]))
                self.assertEqual(deadline, clock[0] + 5)
                (folder / 'process-30.log').write_bytes(b'[]\n')
                return dict(exitCode=0, bytes=3, discardedBytes=0)
            with mock.patch.object(driver.time, 'time', side_effect=lambda: 1000.25 + clock[0]), \
                    mock.patch.object(driver.time, 'monotonic', side_effect=lambda: clock[0]), \
                    mock.patch.object(driver.subprocess, 'run', side_effect=subprocess.TimeoutExpired('sample', 5)), \
                    mock.patch.object(driver, 'capture_worker_log', side_effect=query) as logs:
                for age, count in [(0, 0), (19, 0), (20, 1), (21, 1), (59, 1), (60, 2), (61, 2), (120, 2)]:
                    clock[0] = float(age)
                    capture.poll(age)
                    self.assertEqual(logs.call_count, count, age)
            for index in (1, 2):
                sample = json.loads((root / f'live-workers/{index}.json').read_text())
                log = json.loads((root / f'live-workers/{index}.sandbox.json').read_text())
                self.assertEqual(sample['status'], 'unverified')
                self.assertEqual(log['status'], 'captured')
                self.assertEqual(log['worker']['start'], 300)
                self.assertEqual(log['appSourceSHA'], 'a' * 40)
                self.assertEqual(log['sha256'], hashlib.sha256(b'[]\n').hexdigest())
        for flag in (None, '0'):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as directory, \
                    mock.patch.dict(driver.os.environ):
                driver.os.environ.pop('NGV_BPY_CAPTURE_SANDBOX_LOGS', None)
                if flag is not None:
                    driver.os.environ['NGV_BPY_CAPTURE_SANDBOX_LOGS'] = flag
                root = Path(directory)
                support = LiveWorkerSampleTests('test_owned_worker_capture_waits_for_age_and_is_bounded_to_two_samples')
                capture, _, _ = support.fixture(root)
                with mock.patch.object(driver.subprocess, 'run', side_effect=support.sample), \
                        mock.patch.object(driver, 'capture_worker_log') as logs:
                    for age in (0, 20, 60):
                        capture.poll(age)
                logs.assert_not_called()
                self.assertFalse(list(root.rglob('*.sandbox*')))

    def test_foreign_reused_and_changed_clock_scopes_never_become_captured(self):
        for mode in ('foreign-parent', 'reused-before', 'clock-jump', 'backwards', 'reused-after'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                _, capture, identities, _ = self.fixture(root)
                supervisor, worker = copy.deepcopy(identities[20]), copy.deepcopy(identities[30])
                if mode == 'foreign-parent':
                    identities[30]['parentPID'] = 99
                if mode == 'reused-before':
                    identities[30]['start'] += 1
                def query(folder, *args, **kwargs):
                    (folder / 'process-30.log').write_bytes(b'[]')
                    identities[30]['start'] += 1
                    return dict(exitCode=0)
                wall = 1200.25 if mode == 'clock-jump' else 999 if mode == 'backwards' else 1020.25
                with mock.patch.object(driver.time, 'time', return_value=wall), \
                        mock.patch.object(driver.time, 'monotonic', return_value=20), \
                        mock.patch.object(driver, 'capture_worker_log', side_effect=query) as logs:
                    capture.capture_log(root, 1, supervisor, worker, (1000.25, 0))
                self.assertEqual(logs.call_count, int(mode == 'reused-after'))
                receipt = json.loads((root / '1.sandbox.json').read_text())
                self.assertEqual(receipt['status'], 'unverified')
        for label, wall, started, expected in [('within-tolerance', 1020.03125, (1000.0, 0.0), 1),
                ('beyond-tolerance', 1020.0625, (1000.0, 0.0), 0),
                ('future-monotonic', 999.0, (1000.0, 21.0), 0)]:
            with self.subTest(clock=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                _, capture, identities, _ = self.fixture(root)
                def query(folder, *args, **kwargs):
                    (folder / 'process-30.log').write_bytes(b'[]')
                    return dict(exitCode=0)
                with mock.patch.object(driver.time, 'time', return_value=wall), \
                        mock.patch.object(driver.time, 'monotonic', return_value=20), \
                        mock.patch.object(driver, 'capture_worker_log', side_effect=query) as logs:
                    capture.capture_log(root, 1, identities[20], identities[30], started)
                self.assertEqual(logs.call_count, expected)
                self.assertEqual(json.loads((root / '1.sandbox.json').read_text())['status'],
                                 'captured' if expected else 'unverified')

    def test_log_predicate_includes_only_exact_owned_process_and_kernel_pid_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contexts = [dict(pid=30, hostExecutable='/app/python3.13')]
            with mock.patch.object(driver.subprocess, 'Popen', side_effect=RuntimeError('before spawn')) as spawn:
                with self.assertRaisesRegex(RuntimeError, 'before spawn'):
                    driver.capture_worker_log(root, 30, contexts, 1001, 1020, time.monotonic() + 5,
                                              include_sandbox=True)
            command = spawn.call_args.args[0]
            self.assertNotIn('--process', command)
            self.assertEqual(command[command.index('--start') + 1], '1970-01-01 00:16:41+0000')
            self.assertEqual(command[command.index('--end') + 1], '1970-01-01 00:17:00+0000')
            predicate = command[command.index('--predicate') + 1]
            self.assertIn('processID == 30 AND (processImagePath == "/app/python3.13")', predicate)
            self.assertIn('process == "kernel" OR process == "sandboxd"', predicate)
            marker = json.loads(predicate.split('eventMessage MATCHES ', 1)[1][:-1])
            self.assertIsNotNone(re.fullmatch(marker, 'Sandbox: python3.13(30) deny(1) file-write-create'))
            for text in ('Sandbox: python3.13(30) deny(1) mach-lookup com.apple.MTLCompilerService\n'
                         'Violation: deny(1) mach-lookup ...\nThread 0 ...',
                         'Sandbox: python3.13(30) deny(1) file-read-data /x\n'):
                self.assertIsNotNone(re.fullmatch(marker, text))
            for foreign in ('python3.13(300)', 'python3.13(31)', 'foreign(30)', 'evilpython3.13(30)'):
                for suffix in (' deny(1) file-read-data', ' deny(1) file-read-data\nViolation: deny\nThread 0 ...'):
                    self.assertIsNone(re.fullmatch(marker, 'Sandbox: ' + foreign + suffix))
            self.assertIsNone(re.fullmatch(marker, 'Another record\nSandbox: python3.13(30) deny(1) file-read-data'))
            with mock.patch.object(driver.subprocess, 'Popen', side_effect=RuntimeError('legacy before spawn')) as spawn:
                with self.assertRaisesRegex(RuntimeError, 'legacy before spawn'):
                    driver.capture_worker_log(root, 30, contexts, 1001, 1020, time.monotonic() + 5)
            self.assertEqual(spawn.call_args.args[0], ['/usr/bin/log', 'show', '--style', 'json', '--no-pager',
                '--info', '--debug', '--process', '30', '--start', '1970-01-01 00:16:40+0000',
                '--end', '1970-01-01 00:17:01+0000', '--predicate', 'processImagePath == "/app/python3.13"'])
            for pid, paths, start, end in [(1, contexts, 1001, 1020), (True, contexts, 1001, 1020),
                    (30, [dict(pid=30, hostExecutable='relative')], 1001, 1020),
                    (30, contexts + [dict(pid=30, hostExecutable='/other/python')], 1001, 1020),
                    (30, contexts, 1020, 1001), (30, contexts, float('nan'), 1020)]:
                with self.subTest(pid=pid, paths=paths, start=start), \
                        mock.patch.object(driver.subprocess, 'Popen') as spawn:
                    with self.assertRaises(AssertionError):
                        driver.capture_worker_log(root, pid, paths, start, end, time.monotonic() + 5,
                                                  include_sandbox=True)
                    spawn.assert_not_called()

    def test_log_failures_preserve_samples_and_bounded_queries_reap_their_children(self):
        for error in (OSError('log unavailable'), InterruptedError('CI cancelled')):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                support, capture, _, _ = self.fixture(root)
                with mock.patch.object(driver.time, 'time', return_value=1020.25), \
                        mock.patch.object(driver.time, 'monotonic', return_value=20), \
                        mock.patch.object(driver.subprocess, 'run', side_effect=support.sample), \
                        mock.patch.object(driver, 'capture_worker_log', side_effect=error):
                    if isinstance(error, InterruptedError):
                        with self.assertRaisesRegex(InterruptedError, 'CI cancelled'):
                            capture.capture(capture.reader.identity(20), capture.reader.identity(30), (1000.25, 0))
                    else:
                        capture.capture(capture.reader.identity(20), capture.reader.identity(30), (1000.25, 0))
                self.assertEqual(json.loads((root / 'live-workers/1.json').read_text())['status'], 'verified')
                self.assertEqual(json.loads((root / 'live-workers/1.sandbox.json').read_text())['status'], 'unverified')
        original_popen = subprocess.Popen
        for stalled in (False, True):
            with self.subTest(stalled=stalled), tempfile.TemporaryDirectory() as directory:
                children = []
                def spawn(command, **kwargs):
                    self.assertNotIn('--process', command)
                    self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
                    self.assertTrue(kwargs['start_new_session'])
                    script = 'import time; time.sleep(60)' if stalled else "import os; os.write(1, b'x' * (5 * 1024 * 1024))"
                    child = original_popen([sys.executable, '-c', script], **kwargs)
                    children.append(child)
                    return child
                try:
                    with mock.patch.object(driver.subprocess, 'Popen', side_effect=spawn):
                        if stalled:
                            with self.assertRaisesRegex(AssertionError, 'timed out'):
                                driver.capture_worker_log(Path(directory), 30, [dict(pid=30, hostExecutable='/app/python')],
                                    1001, 1020, time.monotonic() + 0.15, include_sandbox=True)
                        else:
                            result = driver.capture_worker_log(Path(directory), 30,
                                [dict(pid=30, hostExecutable='/app/python')], 1001, 1020,
                                time.monotonic() + 10, include_sandbox=True)
                            self.assertEqual(result['bytes'], 4 * 1024 * 1024)
                            self.assertEqual(result['discardedBytes'], 1024 * 1024)
                    self.assertTrue(children and all(child.poll() is not None for child in children))
                finally:
                    for child in children:
                        if child.poll() is None:
                            child.kill()
                        child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
