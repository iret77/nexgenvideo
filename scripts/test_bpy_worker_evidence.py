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
                       "memoryPolicyVersion": "system-pressure-v1",
                       "memoryPolicy": {"schema": "nexgenvideo/bpy-memory-policy-evidence/3", "policy": "system-pressure-v1",
                           "hostProcessIdentifier": 9999,
                           "nativeEvidenceFile": "native-memory-policy.json", "maximumRequestedBytesPerProbe": 256 * 1024 * 1024,
                           "touchedChunkBytes": 4 * 1024 * 1024, "diagnosticThresholdDeltaBytes": 128 * 1024 * 1024,
                           "diagnosticSafetyDeltaBytes": 256 * 1024 * 1024, "untouchedVirtualProtection": "PROT_NONE",
                           "syntheticEvidenceFile": "native-synthetic-pressure.json",
                           "untouchedVirtualBytes": 8 * 1024 * 1024 * 1024, "genuinePressureTransitionsProven": False}}
        self.probes = []
        controller, activity, parent = str(uuid4()), str(uuid4()), str(uuid4())
        digest_activity, stopped_permit = str(uuid4()), str(uuid4())
        def clock(at): return {"awake": at, "continuous": at, "uncertainty": 0}
        self.result["runtimeObservation"] = {
            "schema": "nexgenvideo/bpy-runtime-observation/1", "osVersion": "26.1.0", "osBuild": "25B1", "kernel": "Darwin test fixture",
            "architecture": "arm64", "imageVersionStatus": "absent", "activitiesEnded": True,
            "genuinePressureTransitionsProven": False, "maximumAwakeObservationGap": 3, "maximumSleepOffsetChange": 0,
            "evidenceClock": clock(104), "observerWatchdogExpiryCount": 1,
            "trace": {"overflow": False,
                "pressure": [{"controller": controller, "sample": {"source": "sysctl", "pressure": 1, "byteCount": 4, "clock": clock(100)}}],
                "lifecycle": [{"controller": controller, "event": event, "clock": clock(at)}
                    for event, at in (("dispatch-source-resumed", 99), ("sampling-ended", 103))],
                "swap": [{"clock": clock(100), "total": 0, "used": 0, "available": 0, "bytes": 32}],
                "activity": [{"id": activity, "parent": parent, "scope": "Validate and encode 3D media", "event": event, "clock": clock(at)}
                    for event, at in (("begin", 100), ("end", 101))]
                    + [{"id": digest_activity, "parent": parent, "scope": "Verify 3D runtime files", "event": event, "clock": clock(at)}
                       for event, at in (("begin", 100.1), ("end", 100.9))],
                "stops": [{"controller": controller, "permit": stopped_permit, "reason": "monitorUnresponsive",
                    "decision": clock(102.3), "hasHandler": True, "requestInvoked": clock(102.31)}],
                "processCleanup": {stopped_permit: {"controller": controller, "permit": stopped_permit, "started": 102.3,
                    "finished": 102.5, "complete": True, "grounds": [{"reason": "monitorUnresponsive", "clock": clock(102.3)}]}},
                "footprints": {role: {"role": role, "pid": 3000 + index, "start": 30000 + index,
                    "current": 100, "peak": 100, "clock": clock(101),
                    "status": "live" if role in ("host", "service") else "exited",
                    **({"exitObserved": clock(102)} if role not in ("host", "service") else {})}
                    for index, role in enumerate(("host", "service", "supervisor", "worker"))}}}
        self.result["memoryPolicy"]["stdoutBurst"] = {
            "mode": "diagnostic-stdout-burst",
            "response": {"status": "gone", "exitStatus": 0, "stage": 7, "outputComplete": True, "descendants": [],
                "ended": [{"pid": 4000, "start": 40000, "parent": 9999}, {"pid": 4100, "start": 41000, "parent": 4000}],
                "diagnosticStdout": {"burst": {"flags": 1, "bytes": 1_048_576, "started": clock(100.04), "finished": clock(100.4)},
                    "capturedBytes": 1_048_576, "capturedSHA256": hashlib.sha256(b"R" * 1_048_576).hexdigest(),
                    "childReadyWritten": clock(100), "childReadyReceived": clock(100.01),
                    "paused": clock(100.03), "resumed": clock(100.3)}},
            "receipt": {"firstRelease": 100.02, "cleanupComplete": True, "cleanupFinishedAt": 100.5,
                "authorizationSamples": [{"source": "sysctl", "pressure": 1, "clock": clock(100)}]}}
        role_job = str(uuid4())
        self.result["memoryPolicy"]["roleLock"] = {"control": "host-owned-mutex-hold",
            "hold": {"slot": "slot-A", "role": "data", "acquired": clock(100), "heldThrough": clock(105.1)},
            "workerRoleFinishedAt": clock(100.1), "launchedSlot": "slot-B",
            "source": "print('ROLE_LOCK_PROGRESS', flush=True)\nbpy.context.scene.render.resolution_x = 64\nbpy.context.scene.render.resolution_y = 64",
            "response": {"ok": True, "state": "awaitingConfirmation", "stdout": "ROLE_LOCK_PROGRESS", "jobID": role_job,
                "firstRelease": 101, "terminalCommit": 104},
            "receipt": {"identity": {"job": role_job, "timeout": 120}, "firstRelease": 101, "terminalCommit": 104,
                "cleanupComplete": True, "releases": [{"child": child, "clock": clock(at)} for child, at in (("worker", 101), ("verifier", 103))],
                "authorizationSamples": [{"source": "sysctl", "pressure": 1, "clock": clock(at)} for at in (100.9, 102.9)]},
            "holdingRevisionBefore": "revision-a", "holdingRevisionAfter": "revision-a",
            "launchingRevisionBefore": "revision-b", "launchingRevisionAfter": "revision-b"}
        self.result["memoryPolicy"]["mediaCancellation"] = {
            "schema": "nexgenvideo/bpy-native-media-cancellation/1",
            "encoder": {"synthetic": True, "criticalObservedAt": 100, "stopRequestedAt": 100.01,
                "cancelSettledAt": 100.1, "disposedAt": 100.2, "width": 64, "height": 64, "framesAppended": 1,
                "statusBefore": "writing", "statusAfter": "cancelled", "fileRetainedWhileWriting": True, "stop": "pressure",
                "owner": str(uuid4()), "writerOwnersBefore": 1, "writerOwnersAfter": 0,
                "chargedBefore": [{"id": str(uuid4()), "kind": kind, "bytes": 512 * 1024 * 1024} for kind in ("retained", "transfer")],
                "chargedAfter": 0},
            "queuedDecode": {"cancelledAt": 101, "completedAt": 101.01, "failure": "cancelled", "decoded": False,
                "queuedBefore": 1, "queuedAfter": 0, "capacityHeldBefore": 2 * (512 * 1024 * 1024 + 67_108_864 * 12),
                "capacityHeldAfter": 2 * (512 * 1024 * 1024 + 67_108_864 * 12)}}
        for index, mode in enumerate(("diagnostic-footprint", "diagnostic-footprint-after-exec", "diagnostic-python-footprint", "diagnostic-virtual-mapping")):
            supervisor = {"pid": 500 + index, "start": 5000 + index, "parent": 9999}
            observed = {"pid": 100 + index, "start": 1000 + index, "parent": supervisor["pid"], "footprint": 332 * 1024 * 1024}
            response = {"schema": "nexgenvideo/bpy-monitor-response/2", "execution": str(uuid4()), "status": "gone",
                        "outputComplete": True, "descendants": [], "stage": (2, 3, 2, 4)[index],
                        "diagnosticBaseline": dict(observed, footprint=200 * 1024 * 1024), "diagnosticObserved": observed,
                        "diagnosticThresholdBytes": 128 * 1024 * 1024, "diagnosticSafetyBytes": 456 * 1024 * 1024,
                        "diagnosticChunks": [i * 4 * 1024 * 1024 for i in range(1, 33)], "ended": [supervisor, observed]}
            receipt = {"policy": "system-pressure-v1", "firstRelease": 100, "cleanupComplete": True,
                       "identity": {"owner": str(uuid4()), "transport": str(uuid4())}, "cleanupFinishedAt": 100.5,
                       "samples": [{"source": "sysctl", "pressure": 1}],
                       "authorizationSamples": [{"source": "sysctl", "pressure": 1, "clock": {"awake": 99.9}}]}
            if index < 3:
                response["stopReason"] = receipt["stop"] = "diagnosticMemory"
                if index == 2:
                    response["diagnosticAllocationObjectBytes"] = 289
            else:
                response["exitStatus"] = 0
                response["diagnosticMapping"] = {"bytes": 8 * 1024 * 1024 * 1024, "protection": 0, "deallocated": True}
            self.probes.append({"mode": mode, "response": response, "receipt": receipt})
        self.reaped_recovery = []
        self.commit_cancellation = {"schema": "nexgenvideo/spatial-commit-cancellation/1", "sceneID": str(uuid4()),
            "priorRevision": str(uuid4()), "committedRevision": str(uuid4()), "cancelAfterCommitObserved": True,
            "cancelEnabledAtCommit": False, "taskCancelledAfterLateCancel": False, "canUndo": True, "error": "", "objects": 1,
            "committedSceneSHA256": "e" * 64, "readbackSceneSHA256": "e" * 64, "payloadVerified": True}
        self.commit_cancellation["currentRevision"] = self.commit_cancellation["committedRevision"]
        self.hash_cancellation = []
        for index, purpose in enumerate(("checkpoint", "file-digest")):
            stamp = {"transport": str(uuid4()), "revision": str(uuid4()), "sha256": "a" * 64, "uploadedJobs": "0"}
            self.hash_cancellation.append({"purpose": purpose, "operation": str(uuid4()), "sceneID": str(uuid4()),
                "sceneBytes": 256 * 1024 * 1024, "expectedBytes": 256 * 1024 * 1024, "hashedBytes": 65536,
                "device": 11, "expectedDevice": 11, "inode": 12 + index, "expectedInode": 12 + index, "sceneCount": 2,
                "sceneSHA256": "b" * 64, "controlSeconds": 1, "cancelledAt": 100, "endedAt": 100.01,
                "failure": "cancelled", "taskCancelled": False, "callerCancelled": True, "chunksAfterCancellation": 0, "checkpointBefore": stamp,
                "checkpointAfter": dict(stamp), "releasesBefore": 10, "releasesAfter": 10, "indexBefore": "c" * 64, "indexAfter": "c" * 64})
        revision = str(uuid4())
        self.editor_cancellation = [{"route": route, "operation": str(uuid4()),
            "purpose": "file-digest" if route == "user" else "checkpoint",
            "device": 11, "expectedDevice": 11, "inode": 13, "expectedInode": 13,
            "sceneID": self.hash_cancellation[1]["sceneID"], "revisionBefore": revision, "revisionAfter": revision,
            "frameBefore": 1, "frameAfter": 1, "sceneBytes": 256 * 1024 * 1024, "hashedBytes": 65536,
            "chunksAfterCancellation": 0, "callerCancelled": True, "callingTaskCancelled": False, "canCancel": False,
            "error": "" if route == "user" else "The 3D operation was cancelled.", "releasesBefore": 10, "releasesAfter": 10}
            for route in ("user", "externalToken")]
        for index, route in enumerate(("transportLoss", "ownerClose")):
            response = json.loads(json.dumps(self.probes[3]["response"]))
            response.update(execution=str(uuid4()), ended=[
                {"pid": 1500 + index, "start": 15000 + index, "parent": 9999},
                {"pid": 1600 + index, "start": 16000 + index, "parent": 1500 + index}])
            identity = {"id": str(uuid4()), "owner": str(uuid4()), "generation": str(uuid4()),
                        "transport": str(uuid4()), "kind": "boundary"}
            before = {"policy": "system-pressure-v1", "identity": identity, "firstRelease": 100, "cleanupComplete": False}
            after = dict(before, stop="closed" if route == "ownerClose" else "transportLost",
                         cleanupStarted=101, cleanupFinishedAt=101.1, cleanupComplete=True)
            successor = {"policy": "system-pressure-v1", "identity": {"id": str(uuid4()), "owner": str(uuid4()),
                "generation": str(uuid4()), "transport": str(uuid4()), "kind": "boundary"},
                "grantedAt": 107.1, "releases": [], "cleanupComplete": False}
            self.reaped_recovery.append({"route": route, "response": response, "before": before, "after": after,
                "checkedAt": {"awake": 107, "continuous": 107}, "reapedBeforeCleanup": True,
                "recoveredAfter": True, "cleanupFailed": False, "successor": successor})
        self.synthetic = {"warningContinuation": {"response": {"state": "awaitingConfirmation"},
            "receipt": {"terminalCommit": 102, "releases": [
                {"child": "worker", "clock": {"awake": 100}}, {"child": "verifier", "clock": {"awake": 101}}],
                "samples": [{"source": "selftest-sensor", "pressure": 2, "clock": {"awake": 100.9}}]}}, "pressure": []}
        for index, scenario in enumerate(("sustainedWarning", "criticalSensor", "criticalEvent", "stalledSensor")):
            supervisor = {"pid": 600 + index, "start": 6000 + index, "parent": 9999}
            baseline = {"pid": 200 + index, "start": 2000 + index, "parent": supervisor["pid"]}
            began = 101.1 if index == 0 else 102.25 if index > 2 else 100.05
            receipt = {"policy": "system-pressure-v1", "cleanupStarted": began, "cleanupFinishedAt": began + 0.3,
                "identity": {"owner": str(uuid4()), "transport": str(uuid4())},
                "cleanupComplete": True, "stop": "diagnosticMemory" if index == 0 else "monitorUnresponsive" if index > 2 else "pressure",
                "samples": [{"source": "selftest-event" if index == 2 else "selftest-sensor",
                    "pressure": 2 if index == 0 else 5 if index == 2 else 4, "clock": {"awake": 100.05}}]}
            response = {"execution": str(uuid4()), "status": "gone", "outputComplete": True, "descendants": [],
                "stage": 2, "diagnosticBaseline": baseline, "ended": [supervisor, baseline], "stopDeliveredAt": began + 0.01}
            self.synthetic["pressure"].append({"scenario": scenario, "injectedAt": {"awake": 100},
                "warningAt": {"awake": 100.05} if index == 0 else None,
                "execution": {"mode": "diagnostic-pressure-wait", "response": response, "receipt": receipt}})
        dual = {"event": {"awake": 100}, "executions": []}
        for index in range(2):
            item = json.loads(json.dumps(self.synthetic["pressure"][1]["execution"]))
            transport = str(uuid4())
            item["response"].update(execution=str(uuid4()), transport=transport, service={"pid": 700 + index})
            supervisor = {"pid": 800 + index, "start": 8000 + index, "parent": 9999}
            child = {"pid": 900 + index, "start": 9000 + index, "parent": supervisor["pid"]}
            item["response"].update(ended=[supervisor, child], diagnosticBaseline=child)
            item["receipt"].update(identity={"owner": str(uuid4()), "transport": transport}, firstRelease=99,
                samples=[{"source": "selftest-sensor", "pressure": 1, "clock": {"awake": 100.05 + i * 0.1}} for i in range(4)])
            dual["executions"].append(item)
        resumed = json.loads(json.dumps(self.probes[3]))
        resumed["response"].update(execution=str(uuid4()))
        resumed["response"]["ended"] = [{"pid": 810, "start": 8100, "parent": 9999}, {"pid": 910, "start": 9100, "parent": 810}]
        resumed["receipt"].update(grantedAt=101.1, firstRelease=101.11, stop=None,
            samples=[{"source": "selftest-sensor", "pressure": 1, "clock": {"awake": 100.45 + i * 0.1}} for i in range(7)])
        dual["resumption"] = resumed
        self.synthetic["dualCritical"] = dual
        retries = []
        stopped = self.probes[:3] + [item["execution"] for item in self.synthetic["pressure"]] + dual["executions"]
        for probe in stopped:
            job = str(uuid4())
            identity = dict(probe["receipt"]["identity"], job=job, timeout=120)
            retry = {"interruptedExecution": probe["response"]["execution"],
                "response": {"ok": True, "state": "awaitingConfirmation", "jobID": job, "firstRelease": 110, "terminalCommit": 112},
                "receipt": {"identity": identity, "firstRelease": 110, "terminalCommit": 112, "cleanupComplete": True,
                    "policy": "system-pressure-v1", "releases": [
                        {"child": "worker", "clock": {"awake": 110}}, {"child": "verifier", "clock": {"awake": 111}}],
                    "authorizationSamples": [{"source": "sysctl", "pressure": 1, "clock": {"awake": at}} for at in (109.9, 110.9)]}}
            retries.append(retry)
        self.synthetic["healthyRetries"] = retries
        source = "print('BOUND_SOURCE_RAN', flush=True)\nbpy.context.scene.render.resolution_x = 64\nbpy.context.scene.render.resolution_y = 64"
        self.bindings = []
        for index, target in enumerate(("source.py", "job.json")):
            job, execution, transport, owner = str(uuid4()), str(uuid4()), str(uuid4()), str(uuid4())
            gate = {"pid": 2000 + index, "start": 20000 + index, "parent": 9999}
            child = {"pid": 2100 + index, "start": 21000 + index, "parent": gate["pid"]}
            replacement = "raise RuntimeError('UNAPPROVED_SOURCE_EXECUTED')" if index == 0 else '{"memoryPolicy":"unapproved"}'
            permit = str(uuid4())
            receipt = {"identity": {"id": permit, "job": job, "transport": transport, "owner": owner}, "firstRelease": 100,
                "cleanupComplete": True, "cleanupFinishedAt": 102,
                "releases": [{"child": "worker", "clock": {"awake": 100}}]}
            response = {"ok": True, "jobID": job, "state": "failed", "outputs": [], "stdout": "invalid host bootstrap descriptor"}
            if index == 1:
                receipt.update(terminalCommit=102, releases=receipt["releases"] + [{"child": "verifier", "clock": {"awake": 101}}])
                response.update(state="awaitingConfirmation", stdout="BOUND_SOURCE_RAN")
            ended = {"execution": execution, "transport": transport, "ended": [dict(gate), dict(child)], "status": "detached",
                "outputComplete": True, "descendants": [], "exitStatus": 70 if index == 0 else 0}
            retry = json.loads(json.dumps(retries[0]))
            retry.update(interruptedExecution=execution)
            retry["response"]["jobID"] = str(uuid4())
            retry["receipt"]["identity"].update(job=retry["response"]["jobID"], transport=transport, owner=owner)
            gate_before = {"execution": execution, "permit": permit, "process": dict(gate), "clock": clock(98.5),
                "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(), "configurationSHA256": "a" * 64}
            gate_after = json.loads(json.dumps(gate_before))
            gate_after["clock"] = clock(99.1)
            self.bindings.append({"mutation": {"target": target, "source": source,
                "originalSHA256": hashlib.sha256(source.encode()).hexdigest() if index == 0 else "a" * 64,
                "replacementSHA256": hashlib.sha256(replacement.encode()).hexdigest(), "originalInode": 10, "replacementInode": 11,
                "mutatedAt": clock(99), "authorizedAt": clock(100.1), "gateBefore": gate_before, "gateAfter": gate_after,
                "response": response, "ended": ended, "receipt": receipt}, "retry": retry})
        missing = json.loads(json.dumps(self.synthetic["pressure"][3]))
        missing["scenario"] = "missingSensor"
        missing["execution"]["response"].update(execution=str(uuid4()), stopDeliveredAt=100.06,
            diagnosticBaseline={"pid": 1300, "start": 13000, "parent": 1200}, ended=[
                {"pid": 1200, "start": 12000, "parent": 9999}, {"pid": 1300, "start": 13000, "parent": 1200}])
        missing["execution"]["receipt"].update(stop="monitorUnavailable", cleanupStarted=100.05, cleanupFinishedAt=100.35,
            samples=[{"source": "selftest-sensor", "error": 2, "clock": {"awake": 100.05}}])
        self.unavailable = {"execution": missing, "failure": "sensorUnavailable", "retryJob": str(uuid4()),
            "releasesBeforeRetry": 4, "releasesAfterRetry": 4,
            "confirmedRevisionBefore": "unavailable-sensor-checkpoint", "confirmedRevisionAfter": "unavailable-sensor-checkpoint"}

    def write(self):
        production = self.result.setdefault("productionSpatial", {})
        for key, name, value in (("postCommitCancellation", "production-spatial-commit-cancel.json", self.commit_cancellation),
                                 ("hashCancellation", "production-spatial-hash-cancel.json", {
                                     "schema": "nexgenvideo/spatial-hash-cancellation/2", "hashes": self.hash_cancellation,
                                     "editor": self.editor_cancellation})):
            data = json.dumps(value).encode()
            (self.directory / name).write_bytes(data)
            production[key] = {"file": name, "sha256": hashlib.sha256(data).hexdigest()}
        recovery = json.dumps(self.reaped_recovery).encode()
        (self.directory / "native-reaped-recovery.json").write_bytes(recovery)
        self.result["reapedRecovery"] = {"file": "native-reaped-recovery.json", "sha256": hashlib.sha256(recovery).hexdigest()}
        bindings = json.dumps(self.bindings).encode()
        (self.directory / "native-source-binding.json").write_bytes(bindings)
        self.result["memoryPolicy"].update(sourceBindingEvidenceFile="native-source-binding.json",
            sourceBindingEvidenceSHA256=hashlib.sha256(bindings).hexdigest())
        unavailable = json.dumps(self.unavailable).encode()
        (self.directory / "native-unavailable-sensor.json").write_bytes(unavailable)
        self.result["unavailableSensor"] = {"file": "native-unavailable-sensor.json", "sha256": hashlib.sha256(unavailable).hexdigest()}
        synthetic = json.dumps(self.synthetic).encode()
        (self.directory / "native-synthetic-pressure.json").write_bytes(synthetic)
        self.result["memoryPolicy"]["syntheticEvidenceSHA256"] = hashlib.sha256(synthetic).hexdigest()
        native = json.dumps(self.probes).encode()
        (self.directory / "native-memory-policy.json").write_bytes(native)
        self.result["memoryPolicy"]["nativeEvidenceSHA256"] = hashlib.sha256(native).hexdigest()
        data = json.dumps(self.exits).encode()
        (self.directory / "native-untrusted-exits.json").write_bytes(data)
        self.result["untrustedExitEvidenceSHA256"] = hashlib.sha256(data).hexdigest()
        (self.directory / "result.json").write_text(json.dumps(self.result))

    def test_commit_cancellation_cannot_lose_the_revision_or_undo_or_claim_cancelled_task(self):
        for name, changed in (
                ("undo-lost", {"canUndo": False}), ("error-shown", {"error": "cancelled"}),
                ("cancel-still-enabled", {"cancelEnabledAtCommit": True}), ("task-cancelled", {"taskCancelledAfterLateCancel": True}),
                ("stale-current", {"currentRevision": str(uuid4())}), ("no-observed-commit", {"cancelAfterCommitObserved": False}),
                ("unreadable-payload", {"payloadVerified": False}), ("wrong-readback", {"readbackSceneSHA256": "f" * 64}),
                ("invalid-hash", {"committedSceneSHA256": "invalid", "readbackSceneSHA256": "invalid"}),
                ("wrong-objects", {"objects": 2}), ("boolean-objects", {"objects": True})):
            with self.subTest(case=name):
                original = dict(self.commit_cancellation)
                self.commit_cancellation.update(changed); self.write()
                with self.assertRaisesRegex(ValueError, "committed location survives late user cancellation with Undo"): validate(self.directory)
                self.commit_cancellation = original

    def test_hash_cancellation_requires_active_large_file_caller_identity_and_observed_latency(self):
        for name, changed in (
                ("small-file", {"sceneBytes": 65536, "expectedBytes": 65536}), ("no-read", {"hashedBytes": 0}),
                ("already-finished", {"hashedBytes": 256 * 1024 * 1024}), ("wrong-file", {"inode": 999}),
                ("task-cancelled", {"taskCancelled": True}), ("caller-live", {"callerCancelled": False}),
                ("not-cancelled", {"failure": "unexpected-success"}), ("too-slow", {"endedAt": 100.3}),
                ("full-hash-time", {"controlSeconds": 0.01}), ("only-one-scene", {"sceneCount": 1}),
                ("hash-continued-after-cancel", {"chunksAfterCancellation": 1})):
            with self.subTest(case=name):
                original = json.dumps(self.hash_cancellation)
                self.hash_cancellation[0].update(changed); self.write()
                with self.assertRaisesRegex(ValueError, "caller-only cancellation during actual large-file hash"): validate(self.directory)
                self.hash_cancellation = json.loads(original)

    def test_hash_cancellation_cannot_upload_or_publish_after_cancel(self):
        for name, changed in (("new-release", {"releasesAfter": 11}), ("canonical-change", {"indexAfter": "d" * 64}),
                              ("new-checkpoint", {"checkpointAfter": {**self.hash_cancellation[0]["checkpointAfter"], "revision": str(uuid4())}})):
            with self.subTest(case=name):
                original = json.dumps(self.hash_cancellation)
                self.hash_cancellation[0].update(changed); self.write()
                with self.assertRaisesRegex(ValueError, "hash cancellation starts no upload and publishes no canonical bytes"): validate(self.directory)
                self.hash_cancellation = json.loads(original)

    def test_commit_cancellation_requires_each_actual_uuid(self):
        for key in ("sceneID", "priorRevision", "committedRevision", "currentRevision"):
            with self.subTest(field=key):
                original = dict(self.commit_cancellation)
                self.write(); validate(self.directory)
                self.commit_cancellation[key] = "invalid"; self.write()
                with self.assertRaisesRegex(ValueError, "committed location identity"): validate(self.directory)
                self.commit_cancellation = original

    def test_spatial_cancellation_files_are_bound_to_their_exact_bytes(self):
        for key in ("postCommitCancellation", "hashCancellation"):
            with self.subTest(file=key):
                self.write(); validate(self.directory)
                self.result["productionSpatial"][key]["sha256"] = "0" * 64
                (self.directory / "result.json").write_text(json.dumps(self.result))
                with self.assertRaisesRegex(ValueError, "spatial cancellation evidence bytes"): validate(self.directory)

    def test_hash_cancellation_coverage_and_independent_sources_are_required(self):
        for mutation in ("one-case", "duplicate-purpose", "same-operation", "same-scene", "same-file"):
            with self.subTest(case=mutation):
                original = json.dumps(self.hash_cancellation)
                self.write(); validate(self.directory)
                first, second = self.hash_cancellation
                if mutation == "one-case": self.hash_cancellation.pop()
                elif mutation == "duplicate-purpose": second["purpose"] = first["purpose"]
                elif mutation == "same-operation": second["operation"] = first["operation"]
                elif mutation == "same-scene": second["sceneID"] = first["sceneID"]
                else:
                    second["inode"] = first["inode"]; second["expectedInode"] = first["expectedInode"]
                self.write()
                message = ("caller-only spatial hash cancellation coverage" if mutation in {"one-case", "duplicate-purpose"}
                    else "caller-only cancellation during actual large-file hash" if mutation == "same-file"
                    else "spatial cancellation independent operations and scenes")
                with self.assertRaisesRegex(ValueError, message): validate(self.directory)
                self.hash_cancellation = json.loads(original)

    def test_hash_cancellation_requires_positive_matching_file_identity_and_hash(self):
        for changed in ({"device": 999}, {"device": 0, "expectedDevice": 0},
                        {"inode": 0, "expectedInode": 0}, {"sceneSHA256": "invalid"},
                        {"expectedBytes": 1}):
            with self.subTest(change=changed):
                original = json.dumps(self.hash_cancellation)
                self.write(); validate(self.directory)
                self.hash_cancellation[0].update(changed); self.write()
                with self.assertRaisesRegex(ValueError, "caller-only cancellation during actual large-file hash"): validate(self.directory)
                self.hash_cancellation = json.loads(original)

    def test_equal_checkpoint_stamps_still_require_the_actual_structure(self):
        for changed in (None, {}, {"transport": None}, {"transport": "invalid"},
                        {"uploadedJobs": "-1"}, {"uploadedJobs": 0}, {"sha256": "invalid"},
                        {"revision": 1}, {"extra": "unexpected"}):
            with self.subTest(change=changed):
                original = json.dumps(self.hash_cancellation)
                self.write(); validate(self.directory)
                stamp = None if changed is None else ({} if not changed else {**self.hash_cancellation[0]["checkpointBefore"], **changed})
                self.hash_cancellation[0].update(checkpointBefore=stamp, checkpointAfter=stamp); self.write()
                with self.assertRaisesRegex(ValueError, "spatial cancellation checkpoint stamp structure"): validate(self.directory)
                self.hash_cancellation = json.loads(original)

    def test_location_editor_cancellation_preserves_state_and_distinguishes_foreign_cancellation(self):
        for index in range(2):
            mutations = [{"error": "unexpected" if index == 0 else ""}, {"revisionAfter": str(uuid4())},
                {"frameAfter": 2}, {"callingTaskCancelled": True}, {"callerCancelled": False}, {"canCancel": True},
                {"chunksAfterCancellation": 1}, {"releasesAfter": 11}, {"sceneBytes": 65536}, {"hashedBytes": 0},
                {"hashedBytes": 256 * 1024 * 1024}, {"frameAfter": True}]
            for change in mutations:
                with self.subTest(route=index, change=change):
                    original = json.dumps(self.editor_cancellation)
                    self.write(); validate(self.directory)
                    self.editor_cancellation[index].update(change); self.write()
                    with self.assertRaisesRegex(ValueError, "location editor cancellation preserves state and separates user intent"):
                        validate(self.directory)
                    self.editor_cancellation = json.loads(original)
        for mutation in ("one-route", "duplicate-route", "same-operation", "invalid-revision"):
            original = json.dumps(self.editor_cancellation)
            self.write(); validate(self.directory)
            if mutation == "one-route": self.editor_cancellation.pop()
            elif mutation == "duplicate-route": self.editor_cancellation[1]["route"] = "user"
            elif mutation == "same-operation": self.editor_cancellation[1]["operation"] = self.editor_cancellation[0]["operation"]
            else: self.editor_cancellation[0]["revisionBefore"] = "invalid"
            self.write()
            message = "location editor cancellation coverage" if mutation in {"one-route", "duplicate-route"} else "location editor cancellation identity"
            with self.assertRaisesRegex(ValueError, message): validate(self.directory)
            self.editor_cancellation = json.loads(original)

    def test_editor_cancellation_is_bound_to_the_actual_stage_and_large_scene(self):
        for index in range(2):
            for change in ({"purpose": "checkpoint" if index == 0 else "file-digest"},
                           {"inode": 999}, {"device": True}, {"sceneID": str(uuid4())},
                           {"device": 0, "expectedDevice": 0}, {"inode": 999, "expectedInode": 999},
                           {"sceneBytes": 256 * 1024 * 1024 + 1}):
                with self.subTest(route=index, change=change):
                    original = json.dumps(self.editor_cancellation)
                    self.write(); validate(self.directory)
                    self.editor_cancellation[index].update(change); self.write()
                    with self.assertRaisesRegex(ValueError, "location editor cancellation stage and source"):
                        validate(self.directory)
                    self.editor_cancellation = json.loads(original)

    def test_reaped_recovery_checks_both_registry_cleanup_routes_after_the_original_deadline(self):
        for name, target, change, message in (
                ("already-finished-before-stop", "before", {"cleanupComplete": True}, "original cleanup and registry"),
                ("not-cleaned", "after", {"cleanupComplete": False}, "original cleanup and registry"),
                ("late-cleanup", "after", {"cleanupFinishedAt": 106.01}, "original cleanup and registry"),
                ("too-early-observation", None, {"checkedAt": {"awake": 105, "continuous": 105}}, "original cleanup and registry"),
                ("global-poison", None, {"cleanupFailed": True}, "original cleanup and registry"),
                ("registry-not-recovered", None, {"recoveredAfter": False}, "original cleanup and registry"),
                ("not-reaped", None, {"reapedBeforeCleanup": False}, "original cleanup and registry"),
                ("successor-failed", "successor", {"failure": "cleanupFailed"}, "independent successor admission"),
                ("old-successor-grant", "successor", {"grantedAt": 106.9}, "independent successor admission")):
            with self.subTest(case=name):
                original = json.dumps(self.reaped_recovery)
                item = self.reaped_recovery[0]
                (item if target is None else item[target]).update(change)
                self.write()
                with self.assertRaisesRegex(ValueError, message): validate(self.directory)
                self.reaped_recovery = json.loads(original)

    def test_reaped_recovery_requires_both_routes_and_distinct_owned_processes(self):
        original = json.dumps(self.reaped_recovery)
        self.reaped_recovery = self.reaped_recovery[:1]; self.write()
        with self.assertRaisesRegex(ValueError, "reaped recovery coverage"): validate(self.directory)
        self.reaped_recovery = json.loads(original)
        self.reaped_recovery[1]["response"]["ended"] = self.reaped_recovery[0]["response"]["ended"]
        self.write()
        with self.assertRaisesRegex(ValueError, "reused reaped process identity"): validate(self.directory)

    def test_reaped_recovery_cannot_reuse_the_original_admission_or_owner(self):
        for field in ("id", "owner"):
            with self.subTest(field=field):
                original = json.dumps(self.reaped_recovery)
                item = self.reaped_recovery[0]
                item["successor"]["identity"][field] = item["before"]["identity"][field]
                self.write()
                with self.assertRaisesRegex(ValueError, "independent successor admission"): validate(self.directory)
                self.reaped_recovery = json.loads(original)

    def test_controls(self):
        self.write()
        self.assertEqual(validate(self.directory)["untrustedExits"], [71, 72])

    def test_exited_footprints_keep_their_last_actual_read_and_never_become_synthetic_zeroes(self):
        footprints = self.result["runtimeObservation"]["trace"]["footprints"]
        for name, change in (
                ("zero_after_exit", lambda: footprints["worker"].update(current=0)),
                ("missing_status", lambda: footprints["worker"].pop("status")),
                ("synthetic_evidence_timestamp", lambda: footprints["worker"].update(clock={"awake": 103, "continuous": 103})),
                ("host_gone", lambda: footprints["host"].update(status="exited", exitObserved={"awake": 102, "continuous": 102}))):
            with self.subTest(case=name):
                original = json.dumps(footprints)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, "current and peak observed owned footprint"): validate(self.directory)
                footprints.clear(); footprints.update(json.loads(original))

    def test_role_lock_must_not_block_other_role_or_other_slot_and_cannot_change_checkpoints(self):
        value = self.result["memoryPolicy"]["roleLock"]
        message = "other-role owner binding and actual worker release inside held interval"
        def late_verifier():
            end = value["hold"]["heldThrough"]["awake"]
            value["receipt"]["releases"][1]["clock"].update(awake=end + 0.01, continuous=end + 0.01)
            value["receipt"]["authorizationSamples"][1]["clock"].update(awake=end - 0.09, continuous=end - 0.09)
            value["receipt"]["terminalCommit"] = end + 0.02
            value["response"]["terminalCommit"] = end + 0.02
        def late_commit():
            value["receipt"]["terminalCommit"] = value["hold"]["heldThrough"]["awake"] + 0.01
            value["response"]["terminalCommit"] = value["receipt"]["terminalCommit"]
        def late_worker():
            end = value["hold"]["heldThrough"]["awake"]
            for index in range(2):
                at = end + 0.01 * (index + 1)
                value["receipt"]["releases"][index]["clock"].update(awake=at, continuous=at)
                value["receipt"]["authorizationSamples"][index]["clock"].update(awake=at - 0.1, continuous=at - 0.1)
            value["receipt"].update(firstRelease=end + 0.01, terminalCommit=end + 0.03)
            value["response"].update(firstRelease=end + 0.01, terminalCommit=end + 0.03)
        for name, change, error in (
                ("worker-role-after-hold", lambda: value.update(workerRoleFinishedAt={"awake": 106, "continuous": 106}), message),
                ("worker-release-after-hold", late_worker, message),
                ("verifier-after-hold", late_verifier, message), ("commit-after-hold", late_commit, message),
                ("hold-shorter-than-five", lambda: value["hold"].update(heldThrough={"awake": 104.9, "continuous": 104.9}), message),
                ("same-slot", lambda: value.update(launchedSlot="slot-A"), message),
                ("missing-worker-marker", lambda: value["response"].update(stdout=""), message),
                ("holding-checkpoint-changed", lambda: value.update(holdingRevisionAfter="rewritten"), message),
                ("launching-checkpoint-changed", lambda: value.update(launchingRevisionAfter="rewritten"), message),
                ("non-native-sensor", lambda: value["receipt"]["authorizationSamples"][0].update(source="selftest-sensor"), "role lock fresh native release")):
            with self.subTest(case=name):
                original = json.dumps(value)
                self.write(); validate(self.directory)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, error): validate(self.directory)
                value.clear(); value.update(json.loads(original))

    def test_stdout_burst_requires_blocking_fd_exact_payload_and_independent_report_pipe(self):
        value = self.result["memoryPolicy"]["stdoutBurst"]
        for name, change in (
                ("nonblocking-output", lambda: value["response"]["diagnosticStdout"]["burst"].update(flags=5)),
                ("truncated-output", lambda: value["response"]["diagnosticStdout"].update(capturedBytes=65_536)),
                ("wrong-bytes", lambda: value["response"]["diagnosticStdout"].update(capturedSHA256="0" * 64)),
                ("late-ready", lambda: value["response"]["diagnosticStdout"].update(childReadyReceived={"awake": 100.2, "continuous": 100.2})),
                ("insufficient-pause", lambda: value["response"]["diagnosticStdout"].update(resumed={"awake": 100.1, "continuous": 100.1})),
                ("failed-child", lambda: value["response"].update(exitStatus=70))):
            with self.subTest(case=name):
                original = json.dumps(value)
                self.write(); validate(self.directory)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, "blocking native stdout, prompt childReady and exact resumed drain"):
                    validate(self.directory)
                value.clear(); value.update(json.loads(original))

    def test_runtime_observation_accepts_newer_macos_and_rejects_missing_or_invalid_versions(self):
        observation = self.result["runtimeObservation"]
        for version in ("26.6.2", "27.0.1"):
            observation["osVersion"] = version
            self.write(); validate(self.directory)
        for version in ("25.7.2", "", None, "invalid.0.1", "27.0"):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "actual minimum-OS runtime environment"):
                observation["osVersion"] = version
                self.write(); validate(self.directory)

    def test_runtime_observation_requires_actual_floor_adapter_clocks_swap_and_complete_activity(self):
        observation = self.result["runtimeObservation"]
        environment = "actual minimum-OS runtime environment or activity completion"
        adapter = "actual UInt32 pressure adapter qualification"
        for name, change, error in (
                ("wrong-floor", lambda: observation.update(osVersion="25.7.2"), environment),
                ("unexpected-image-version", lambda: observation.update(imageVersion="unlabeled"), environment),
                ("wrong-adapter-size", lambda: observation["trace"]["pressure"][0]["sample"].update(byteCount=8), adapter),
                ("synthetic-adapter", lambda: observation["trace"]["pressure"][0]["sample"].update(source="selftest-sensor"), adapter),
                ("impossible-swap", lambda: observation["trace"]["swap"][0].update(used=1), "timestamped read-only swap observation"),
                ("missing-service", lambda: observation["trace"]["footprints"].pop("service"), "per-role footprint coverage"),
                ("unended-activity", lambda: observation["trace"]["activity"].pop(), "actual bounded runtime activity lifetime"),
                ("wrong-continuous-clock", lambda: observation["trace"]["activity"][0]["clock"].update(continuous=1), "invalid awake and continuous clocks"),
                ("wrong-gap", lambda: observation.update(maximumAwakeObservationGap=0), "independent observation gap or sleep clocks"),
                ("overflow", lambda: observation["trace"].update(overflow=True), "runtime observation coverage")):
            with self.subTest(case=name):
                original = json.dumps(observation)
                self.write(); validate(self.directory)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, error): validate(self.directory)
                observation.clear(); observation.update(json.loads(original))

    def test_runtime_digests_must_own_a_traced_consumer_activity(self):
        value = self.result["runtimeObservation"]
        unrelated_parent = str(uuid4())
        for name, change in (
                ("missing_digest", lambda: value["trace"].update(activity=value["trace"]["activity"][:2])),
                ("unrelated_consumer", lambda: [item.update(parent=unrelated_parent) for item in value["trace"]["activity"][:2]]),
                ("digest_after_consumer", lambda: [item["clock"].update(awake=102, continuous=102) for item in value["trace"]["activity"][2:]])):
            with self.subTest(case=name):
                original = json.dumps(value)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, "parented runtime file verification activity"): validate(self.directory)
                value.clear(); value.update(json.loads(original))

    def test_owned_stop_trace_binds_its_actual_request_original_cleanup_and_watchdog_count(self):
        value = self.result["runtimeObservation"]
        def stop(): return value["trace"]["stops"][0]
        def cleanup(): return next(iter(value["trace"]["processCleanup"].values()))
        cases = (
            ("missing_stops", lambda: value["trace"].update(stops=[]), "owned stop and process cleanup observation coverage"),
            ("missing_cleanup", lambda: value["trace"].update(processCleanup={}), "owned stop and process cleanup observation coverage"),
            ("unfinished_cleanup", lambda: cleanup().update(complete=False), "owned process cleanup identity or completion"),
            ("refreshed_cleanup", lambda: cleanup().update(started=102.4), "observed owned stop and cleanup lineage"),
            ("wrong_ground", lambda: cleanup()["grounds"][0].update(reason="cancelled"), "observed owned stop and cleanup lineage"),
            ("unrequested_handler", lambda: stop().pop("requestInvoked"), "observed owned stop request latency"),
            ("no_handler_but_request", lambda: stop().update(hasHandler=False), "observed owned stop request latency"),
            ("wrong_controller", lambda: cleanup().update(controller=str(uuid4())), "observed owned stop and cleanup lineage"),
            ("wrong_watchdog_count", lambda: value.update(observerWatchdogExpiryCount=0), "independent observer watchdog expiry count"),
        )
        for name, change, error in cases:
            with self.subTest(case=name):
                original = json.dumps(value)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, error): validate(self.directory)
                value.clear(); value.update(json.loads(original))

    def test_pressure_stop_request_cannot_be_delayed_past_a_quarter_second(self):
        value = self.result["runtimeObservation"]
        stop = value["trace"]["stops"][0]
        stop.update(reason="pressure", requestInvoked={"awake": 102.6, "continuous": 102.6})
        self.write()
        with self.assertRaisesRegex(ValueError, "observed owned stop request latency"): validate(self.directory)

    def test_media_stop_must_cancel_the_writer_and_keep_physical_storage_charged_until_settlement(self):
        value = self.result["memoryPolicy"]["mediaCancellation"]
        encoder, decode = "native host encoder stop or retained storage cleanup", "native queued decode cancellation"
        for name, change, error in (
                ("writer-completed", lambda: value["encoder"].update(statusAfter="completed"), encoder),
                ("late-stop", lambda: value["encoder"].update(stopRequestedAt=100.3), encoder),
                ("disposed-before-settlement", lambda: value["encoder"].update(disposedAt=100.05), encoder),
                ("retained-charge", lambda: value["encoder"].update(chargedAfter=1), encoder),
                ("decoded-after-cancel", lambda: value["queuedDecode"].update(decoded=True), decode),
                ("late-queued-cancel", lambda: value["queuedDecode"].update(completedAt=101.1), decode)):
            with self.subTest(case=name):
                original = json.dumps(value)
                self.write(); validate(self.directory)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, error): validate(self.directory)
                value.clear(); value.update(json.loads(original))

    def test_gated_mutations_require_exact_bytes_pre_release_order_and_healthy_recovery(self):
        identity = "gated mutation identity, order or exact bytes"
        source = "changed source ran or was not refused at the descriptor boundary"
        changes = (
            ("replacement_hash", identity, lambda: self.bindings[0]["mutation"].update(replacementSHA256="b" * 64)),
            ("late_mutation", identity, lambda: self.bindings[0]["mutation"]["mutatedAt"].update(awake=101, continuous=101)),
            ("bound_source_ran", source, lambda: self.bindings[0]["mutation"]["response"].update(stdout="invalid host bootstrap descriptor\nBOUND_SOURCE_RAN")),
            ("config_reopened", "worker reopened mutable configuration", lambda: self.bindings[1]["mutation"]["response"].update(state="failed")),
            ("different_gate", identity, lambda: self.bindings[0]["mutation"]["gateAfter"]["process"].update(start=1)),
            ("late_gate", identity, lambda: self.bindings[0]["mutation"]["gateAfter"]["clock"].update(awake=100.01, continuous=100.01)),
            ("replacement_source_ran", source, lambda: self.bindings[0]["mutation"]["response"].update(stdout="invalid host bootstrap descriptor\nUNAPPROVED_SOURCE_EXECUTED")),
            ("source_hash", identity, lambda: self.bindings[0]["mutation"].update(originalSHA256="b" * 64)),
            ("source_success", source, lambda: self.bindings[0]["mutation"]["response"].update(state="awaitingConfirmation")),
            ("source_exit_zero", source, lambda: self.bindings[0]["mutation"]["ended"].update(exitStatus=0)),
            ("config_hash", identity, lambda: self.bindings[1]["mutation"].update(originalSHA256="b" * 64)),
            ("different_retry", "gated mutation healthy recovery", lambda: self.bindings[1]["retry"].update(interruptedExecution=str(uuid4()))),
            ("stopped_retry", "gated mutation healthy recovery", lambda: self.bindings[1]["retry"]["receipt"].update(stop="pressure")),
            ("missing_config", "gated source and configuration mutation coverage", lambda: self.bindings.pop()),
        )
        for name, message, change in changes:
            with self.subTest(case=name):
                original = json.dumps(self.bindings)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, message): validate(self.directory)
                self.bindings = json.loads(original)

    def test_native_limit_claim_missing_marker_duplicate_job_and_wrong_source_fail(self):
        for name, change, message in (
                ("false_native_limit", lambda: self.exits[0]["response"].update(state="resourceLimited"), "untrusted exit became native evidence"),
                ("missing_marker", lambda: self.exits[0]["response"].update(stdout=""), "untrusted exit became native evidence"),
                ("duplicate_job", lambda: self.exits[1]["response"].update(jobID=self.exits[0]["response"]["jobID"]), "untrusted exit became native evidence"),
                ("wrong_source", lambda: self.exits[0].update(source="raise MemoryError()"), "actual untrusted exit source"),
                ("boolean_exit_code", lambda: self.exits[0].update(exitCode=True), "actual untrusted exit source"),
                ("legacy_policy", lambda: self.result.update(memoryPolicyVersion="legacy-fixed-as"), "independent memory policy controls")):
            with self.subTest(case=name):
                original_exits, original_result = json.dumps(self.exits), json.dumps(self.result)
                change()
                self.write()
                with self.assertRaisesRegex(ValueError, message):
                    validate(self.directory)
                self.exits, self.result = json.loads(original_exits), json.loads(original_result)

    def test_memory_stop_requires_kernel_delta_exec_stage_adapter_and_cleanup(self):
        native, stop = "native memory identity or live adapter", "controlled native footprint stop"
        mapping, objects = "untouched virtual mapping control", "Python small-object allocator coverage"
        for name, change, error in (
                ("insufficient-kernel-delta", lambda: self.probes[0]["response"]["diagnosticObserved"].update(footprint=11 * 1024 * 1024), stop),
                ("wrong-exec-stage", lambda: self.probes[1]["response"].update(stage=2), native),
                ("cleanup-incomplete", lambda: self.probes[0]["receipt"].update(cleanupComplete=False), stop),
                ("event-instead-of-sysctl", lambda: self.probes[0]["receipt"].update(authorizationSamples=[{"source": "dispatch-event", "pressure": 1, "clock": {"awake": 99.9}}]), native),
                ("virtual-mapping-stopped", lambda: self.probes[3]["response"].update(stopReason="diagnosticMemory"), mapping),
                ("one-allocation", lambda: self.probes[0]["response"].update(diagnosticChunks=[4 * 1024 * 1024]), stop),
                ("lowered-threshold", lambda: self.probes[0]["response"].update(diagnosticThresholdBytes=32 * 1024 * 1024), stop),
                ("large-python-objects", lambda: self.probes[2]["response"].update(diagnosticAllocationObjectBytes=1057), objects),
                ("missing-object-size", lambda: self.probes[2]["response"].update(diagnosticAllocationObjectBytes=None), objects),
                ("undersized-mapping", lambda: self.probes[3]["response"]["diagnosticMapping"].update(bytes=7 * 1024 * 1024 * 1024), mapping),
                ("touched-mapping", lambda: self.probes[3]["response"]["diagnosticMapping"].update(protection=3), mapping)):
            with self.subTest(case=name):
                original = json.dumps(self.probes)
                self.write(); validate(self.directory)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, error): validate(self.directory)
                self.probes = json.loads(original)

    def test_changed_retained_bytes_fail(self):
        self.write()
        (self.directory / "native-untrusted-exits.json").write_bytes(b"[]")
        with self.assertRaisesRegex(ValueError, "bytes"):
            validate(self.directory)

    def test_synthetic_pressure_requires_real_verifier_timing_and_cleanup(self):
        def delayed_watchdog():
            probe = self.synthetic["pressure"][3]
            injected = probe["injectedAt"]["awake"]
            probe["execution"]["receipt"].update(cleanupStarted=injected + 2.6, cleanupFinishedAt=injected + 2.7)
        changes = (
            ("warning-missing-verifier", lambda: self.synthetic["warningContinuation"]["receipt"]["releases"].pop(), "warning verifier continuation"),
            ("warning-before-worker", lambda: self.synthetic["warningContinuation"]["receipt"]["samples"][0]["clock"].update(awake=99), "warning was not observed before verifier release"),
            ("warning-stopped-child", lambda: self.synthetic["pressure"][0]["execution"]["receipt"].update(stop="pressure"), "sustained warning stopped admitted child"),
            ("critical-late-stop", lambda: self.synthetic["pressure"][1]["execution"]["response"].update(stopDeliveredAt=101), "critical pressure stop exceeded host bound"),
            ("late-cleanup", lambda: self.synthetic["pressure"][2]["execution"]["receipt"].update(cleanupFinishedAt=110), "synthetic pressure native cleanup"),
            ("late-watchdog", delayed_watchdog, "independent observer watchdog"),
            ("missing-reaped-children", lambda: self.synthetic["pressure"][3]["execution"]["response"].update(ended=[]), "owned supervisor and child receipts"),
            ("dual-late-stop", lambda: self.synthetic["dualCritical"]["executions"][1]["response"].update(stopDeliveredAt=101), "two-slot critical native bounds"),
            ("early-resumption", lambda: self.synthetic["dualCritical"]["resumption"]["receipt"].update(grantedAt=100.5), "two-slot recovery before cleanup and normal dwell"),
            ("missing-retry", lambda: self.synthetic["healthyRetries"].pop(), "healthy retry after every controlled stop"),
            ("retry-missing-verifier", lambda: self.synthetic["healthyRetries"][0]["receipt"]["releases"].pop(), "healthy retry identity or completion"),
            ("retry-before-cleanup", lambda: self.synthetic["healthyRetries"][1]["receipt"].update(firstRelease=1), "healthy retry identity or completion"),
            ("retry-wrong-owner", lambda: self.synthetic["healthyRetries"][2]["receipt"]["identity"].update(owner=str(uuid4())), "healthy retry identity or completion"),
        )
        for name, change, error in changes:
            with self.subTest(case=name):
                original = json.dumps(self.synthetic)
                self.write(); validate(self.directory)
                change(); self.write()
                with self.assertRaisesRegex(ValueError, error): validate(self.directory)
                self.synthetic = json.loads(original)

    def test_permanent_sensor_failure_cannot_be_a_stall_or_start_another_worker(self):
        changes = (
            ("unauthorized-retry", lambda: self.unavailable.update(releasesAfterRetry=5)),
            ("stall-instead-of-missing", lambda: self.unavailable.update(failure="sensorUnresponsive")),
            ("checkpoint-changed", lambda: self.unavailable.update(confirmedRevisionAfter="changed")),
            ("wrong-stop", lambda: self.unavailable["execution"]["execution"]["receipt"].update(stop="monitorUnresponsive")),
            ("missing-sensor-observation", lambda: self.unavailable["execution"]["execution"]["receipt"].update(samples=[])),
            ("no-reaped-children", lambda: self.unavailable["execution"]["execution"]["response"].update(ended=[])),
            ("missing-reaped-field", lambda: self.unavailable["execution"]["execution"]["response"].pop("ended")),
        )
        for name, change in changes:
            with self.subTest(case=name):
                original = json.dumps(self.unavailable)
                self.write(); validate(self.directory)
                change(); self.write()
                error = "owned supervisor and child receipts" if name in {"no-reaped-children", "missing-reaped-field"} else "permanent sensor failure or unauthorized reopen"
                with self.assertRaisesRegex(ValueError, error): validate(self.directory)
                self.unavailable = json.loads(original)


if __name__ == "__main__":
    unittest.main()
