import argparse
import errno
import hashlib
import json
import math
from pathlib import Path
import re
from uuid import UUID


def validate(directory):
    directory = Path(directory)
    result = json.loads((directory / "result.json").read_bytes())
    if result.get("schema") != "nexgenvideo/bpy-runtime-acceptance/2" \
            or result.get("untrustedExitEvidenceFile") != "native-untrusted-exits.json":
        raise ValueError("worker evidence identity")
    data = (directory / "native-untrusted-exits.json").read_bytes()
    if hashlib.sha256(data).hexdigest() != result.get("untrustedExitEvidenceSHA256"):
        raise ValueError("worker evidence bytes")
    evidence = json.loads(data)
    if not isinstance(evidence, list) or len(evidence) != 2:
        raise ValueError("worker exit coverage")
    identifiers = set()
    for item, code in zip(evidence, (71, 72)):
        expected_source = f"import os\nos.write(1, b'UNTRUSTED_EXIT_REACHED\\n')\nos._exit({code})"
        if type(item.get("exitCode")) is not int or item["exitCode"] != code \
                or item.get("source") != expected_source:
            raise ValueError("actual untrusted exit source")
        response = item["response"]
        identifier = UUID(response["jobID"])
        if identifier in identifiers or response.get("ok") is not True \
                or response.get("state") != "failed" \
                or response.get("message") != f"worker reported exit {code} without an observed resource limit" \
                or "UNTRUSTED_EXIT_REACHED\n" not in response.get("stdout", "") \
                or not re.fullmatch(r"[a-f0-9]{64}", response.get("jobFingerprint", "")) \
                or response.get("outputs") != []:
            raise ValueError("untrusted exit became native evidence")
        identifiers.add(identifier)
    memory = result.get("memoryPolicy", {})
    if result.get("memoryPolicyVersion") != "system-pressure-v1" \
            or memory.get("schema") != "nexgenvideo/bpy-memory-policy-evidence/3" \
            or memory.get("policy") != "system-pressure-v1" \
            or memory.get("nativeEvidenceFile") != "native-memory-policy.json" \
            or memory.get("maximumRequestedBytesPerProbe") != 256 * 1024 * 1024 \
            or memory.get("touchedChunkBytes") != 4 * 1024 * 1024 \
            or memory.get("diagnosticThresholdDeltaBytes") != 128 * 1024 * 1024 \
            or memory.get("diagnosticSafetyDeltaBytes") != 256 * 1024 * 1024 \
            or memory.get("untouchedVirtualBytes") != 8 * 1024 * 1024 * 1024 \
            or memory.get("untouchedVirtualProtection") != "PROT_NONE" \
            or memory.get("genuinePressureTransitionsProven") is not False \
            or memory.get("syntheticEvidenceFile") != "native-synthetic-pressure.json":
        raise ValueError("independent memory policy controls")
    host_pid = memory.get("hostProcessIdentifier")
    if type(host_pid) is not int or host_pid <= 1:
        raise ValueError("memory evidence host identity")
    validate_runtime_observation(result.get("runtimeObservation", {}))
    validate_source_binding(directory, memory, host_pid)
    validate_media_cancellation(memory)
    validate_stdout_burst(memory, host_pid)
    validate_role_lock(memory)
    native = (directory / "native-memory-policy.json").read_bytes()
    if hashlib.sha256(native).hexdigest() != memory.get("nativeEvidenceSHA256"):
        raise ValueError("memory evidence bytes")
    probes = json.loads(native)
    modes = ["diagnostic-footprint", "diagnostic-footprint-after-exec", "diagnostic-python-footprint", "diagnostic-virtual-mapping"]
    if not isinstance(probes, list) or [value.get("mode") for value in probes] != modes:
        raise ValueError("native memory probe coverage")
    executions, processes, stopped = set(), set(), {}
    for probe, stage in zip(probes, (2, 3, 2, 4)):
        response, receipt = probe["response"], probe["receipt"]
        owned_child(response, host_pid, processes)
        execution = UUID(response["execution"])
        first = receipt.get("firstRelease")
        if execution in executions or receipt.get("policy") != "system-pressure-v1" \
                or response.get("schema") != "nexgenvideo/bpy-monitor-response/2" \
                or response.get("status") != "gone" or response.get("outputComplete") is not True \
                or response.get("supervisor") is not None or response.get("worker") is not None \
                or response.get("descendants") != [] or response.get("stage") != stage \
                or type(first) not in (int, float) or first < 0 \
                or not any(sample.get("source") == "sysctl" and type(sample.get("pressure")) is int
                           and sample["pressure"] == 1 and sample.get("error") is None
                           and number(sample["clock"]["awake"]) <= first
                           and first - number(sample["clock"]["awake"]) <= 0.25 for sample in receipt.get("authorizationSamples", [])):
            raise ValueError("native memory identity or live adapter")
        executions.add(execution)
        if stage == 4:
            mapping = response.get("diagnosticMapping", {})
            if response.get("exitStatus") != 0 or response.get("stopReason") is not None or receipt.get("stop") is not None \
                    or type(mapping.get("bytes")) is not int or mapping["bytes"] != 8 * 1024 * 1024 * 1024 \
                    or type(mapping.get("protection")) is not int or mapping["protection"] != 0 \
                    or mapping.get("deallocated") is not True:
                raise ValueError("untouched virtual mapping control")
        else:
            if probe["mode"] == "diagnostic-python-footprint" and (
                    type(response.get("diagnosticAllocationObjectBytes")) is not int
                    or not 256 < response["diagnosticAllocationObjectBytes"] <= 512):
                raise ValueError("Python small-object allocator coverage")
            baseline, observed = response["diagnosticBaseline"], response["diagnosticObserved"]
            for key in ("pid", "start", "footprint"):
                if type(baseline.get(key)) is not int or type(observed.get(key)) is not int:
                    raise ValueError("footprint numeric evidence")
            if baseline["pid"] <= 1 or baseline["start"] <= 0 \
                    or baseline["pid"] != observed["pid"] or baseline["start"] != observed["start"] \
                    or baseline["footprint"] > (1 << 64) - 1 - 256 * 1024 * 1024 \
                    or response.get("diagnosticThresholdBytes") != 128 * 1024 * 1024 \
                    or response.get("diagnosticSafetyBytes") != baseline["footprint"] + 256 * 1024 * 1024 \
                    or not 128 * 1024 * 1024 <= observed["footprint"] - baseline["footprint"] < 256 * 1024 * 1024 \
                    or type(response.get("diagnosticChunks")) is not list \
                    or not 1 < len(response["diagnosticChunks"]) < 64 \
                    or response["diagnosticChunks"] != [i * 4 * 1024 * 1024 for i in range(1, len(response["diagnosticChunks"]) + 1)] \
                    or response.get("stopReason") != "diagnosticMemory" or receipt.get("stop") != "diagnosticMemory" \
                    or receipt.get("cleanupComplete") is not True \
                    or not any(ended.get("pid") == observed["pid"] and ended.get("start") == observed["start"]
                               for ended in response.get("ended", [])):
                raise ValueError("controlled native footprint stop")
        if receipt.get("stop") is not None:
            stopped[execution] = receipt
    synthetic_bytes = (directory / "native-synthetic-pressure.json").read_bytes()
    if hashlib.sha256(synthetic_bytes).hexdigest() != memory.get("syntheticEvidenceSHA256"):
        raise ValueError("synthetic pressure evidence bytes")
    synthetic = json.loads(synthetic_bytes)
    continuation = synthetic["warningContinuation"]
    receipt = continuation["receipt"]
    releases = receipt.get("releases", [])
    if continuation["response"].get("state") != "awaitingConfirmation" \
            or receipt.get("stop") is not None or receipt.get("terminalCommit") is None \
            or [value.get("child") for value in releases] != ["worker", "verifier"]:
        raise ValueError("warning verifier continuation")
    verifier = number(releases[-1]["clock"]["awake"])
    worker = number(releases[0]["clock"]["awake"])
    if not any(sample.get("source") == "selftest-sensor" and sample.get("pressure") == 2
               and worker <= number(sample["clock"]["awake"]) <= verifier
               and verifier - number(sample["clock"]["awake"]) <= 0.25 for sample in receipt.get("samples", [])):
        raise ValueError("warning was not observed before verifier release")
    scenarios = ["sustainedWarning", "criticalSensor", "criticalEvent", "stalledSensor"]
    if [item.get("scenario") for item in synthetic.get("pressure", [])] != scenarios:
        raise ValueError("synthetic pressure coverage")
    for item in synthetic["pressure"]:
        probe = item["execution"]
        response, receipt = probe["response"], probe["receipt"]
        owned_child(response, host_pid, processes)
        execution = UUID(response["execution"])
        baseline = response["diagnosticBaseline"]
        began, ended = number(receipt["cleanupStarted"]), number(receipt["cleanupFinishedAt"])
        injected = number(item["injectedAt"]["awake"])
        if execution in executions or probe.get("mode") != "diagnostic-pressure-wait" \
                or response.get("status") != "gone" or response.get("outputComplete") is not True \
                or response.get("supervisor") is not None or response.get("worker") is not None \
                or response.get("descendants") != [] or response.get("stage") != 2 \
                or receipt.get("cleanupComplete") is not True or receipt.get("policy") != "system-pressure-v1" \
                or not injected <= began <= ended <= began + 5 \
                or not any(value.get("pid") == baseline["pid"] and value.get("start") == baseline["start"]
                           for value in response.get("ended", [])):
            raise ValueError("synthetic pressure native cleanup")
        executions.add(execution)
        scenario = item["scenario"]
        if scenario == "sustainedWarning":
            warning = number(item["warningAt"]["awake"])
            if receipt.get("stop") != "diagnosticMemory" or began - warning < 1 \
                    or not any(value.get("source") == "selftest-sensor" and value.get("pressure") == 2
                               and number(value["clock"]["awake"]) == warning for value in receipt.get("samples", [])):
                raise ValueError("sustained warning stopped admitted child")
        elif scenario in ("criticalSensor", "criticalEvent"):
            source = "selftest-event" if scenario == "criticalEvent" else "selftest-sensor"
            observed = next((number(value["clock"]["awake"]) for value in receipt.get("samples", [])
                             if value.get("source") == source and type(value.get("pressure")) is int
                             and value["pressure"] & 4), None)
            delivered = number(response["stopDeliveredAt"])
            if observed is None or receipt.get("stop") != "pressure" \
                    or not observed <= began <= delivered <= observed + 0.25:
                raise ValueError("critical pressure stop exceeded host bound")
        elif receipt.get("stop") != "monitorUnresponsive" or began - injected > 2.5:
            raise ValueError("independent observer watchdog")
        stopped[execution] = receipt
    unavailable_meta = result["unavailableSensor"]
    if unavailable_meta.get("file") != "native-unavailable-sensor.json":
        raise ValueError("permanent sensor evidence identity")
    unavailable_bytes = (directory / "native-unavailable-sensor.json").read_bytes()
    if hashlib.sha256(unavailable_bytes).hexdigest() != unavailable_meta.get("sha256"):
        raise ValueError("permanent sensor evidence bytes")
    unavailable = json.loads(unavailable_bytes)
    item = unavailable["execution"]
    probe = item["execution"]
    response, receipt = probe["response"], probe["receipt"]
    owned_child(response, host_pid, processes)
    execution = UUID(response["execution"])
    UUID(unavailable["retryJob"])
    began, ended = number(receipt["cleanupStarted"]), number(receipt["cleanupFinishedAt"])
    observed = next((number(sample["clock"]["awake"]) for sample in receipt.get("samples", [])
                     if sample.get("source") == "selftest-sensor" and sample.get("error") == errno.ENOENT
                     and sample.get("pressure") is None), None)
    before, after = unavailable.get("releasesBeforeRetry"), unavailable.get("releasesAfterRetry")
    if execution in executions or item.get("scenario") != "missingSensor" or observed is None \
            or probe.get("mode") != "diagnostic-pressure-wait" or response.get("status") != "gone" \
            or response.get("outputComplete") is not True or response.get("descendants") != [] \
            or response.get("supervisor") is not None or response.get("worker") is not None \
            or receipt.get("stop") != "monitorUnavailable" or receipt.get("cleanupComplete") is not True \
            or not observed <= began <= ended <= began + 5 \
            or unavailable.get("failure") != "sensorUnavailable" or type(before) is not int \
            or type(after) is not int or before < 4 or before != after \
            or unavailable.get("confirmedRevisionBefore") != "unavailable-sensor-checkpoint" \
            or unavailable.get("confirmedRevisionAfter") != "unavailable-sensor-checkpoint":
        raise ValueError("permanent sensor failure or unauthorized reopen")
    executions.add(execution)
    dual = synthetic["dualCritical"]
    event = number(dual["event"]["awake"])
    if len(dual.get("executions", [])) != 2:
        raise ValueError("two-slot critical coverage")
    owners, transports, services, cleanups, normal = set(), set(), set(), [], {}
    children = set()
    for probe in dual["executions"]:
        response, receipt = probe["response"], probe["receipt"]
        child = owned_child(response, host_pid, processes)
        identity = (child["pid"], child["start"])
        execution = UUID(response["execution"])
        owner, transport = UUID(receipt["identity"]["owner"]), UUID(receipt["identity"]["transport"])
        service = response["service"]["pid"]
        baseline = response["diagnosticBaseline"]
        began, ended = number(receipt["cleanupStarted"]), number(receipt["cleanupFinishedAt"])
        delivered = number(response["stopDeliveredAt"])
        if execution in executions or owner in owners or transport in transports or service in services or identity in children \
                or str(transport).lower() != response["transport"].lower() or type(service) is not int or service <= 1 \
                or probe.get("mode") != "diagnostic-pressure-wait" or response.get("status") != "gone" \
                or response.get("outputComplete") is not True or response.get("stage") != 2 \
                or response.get("supervisor") is not None or response.get("worker") is not None or response.get("descendants") != [] \
                or receipt.get("stop") != "pressure" or receipt.get("cleanupComplete") is not True \
                or not number(receipt["firstRelease"]) <= event <= began <= delivered <= event + 0.25 \
                or not began <= ended <= began + 5 \
                or not any(value.get("pid") == baseline["pid"] and value.get("start") == baseline["start"]
                           for value in response.get("ended", [])):
            raise ValueError("two-slot critical native bounds")
        executions.add(execution); owners.add(owner); transports.add(transport); services.add(service); cleanups.append(ended)
        stopped[execution] = receipt
        children.add(identity)
        for sample in receipt.get("samples", []):
            if sample.get("source") == "selftest-sensor" and number(sample["clock"]["awake"]) > event:
                normal[number(sample["clock"]["awake"])] = sample
    resumed = dual["resumption"]
    response, receipt = resumed["response"], resumed["receipt"]
    owned_child(response, host_pid, processes)
    grant, release = number(receipt["grantedAt"]), number(receipt["firstRelease"])
    for sample in receipt.get("samples", []):
        if sample.get("source") == "selftest-sensor" and event < number(sample["clock"]["awake"]) <= grant:
            normal[number(sample["clock"]["awake"])] = sample
    times = sorted(time for time in normal if time <= grant)
    mapping = response.get("diagnosticMapping", {})
    if UUID(response["execution"]) in executions or resumed.get("mode") != "diagnostic-virtual-mapping" \
            or response.get("status") != "gone" or response.get("exitStatus") != 0 or response.get("outputComplete") is not True \
            or receipt.get("stop") is not None or max(cleanups) > grant or grant > release \
            or not times or grant - times[0] < 1 or grant - times[-1] > 0.25 \
            or any(normal[time].get("pressure") != 1 or normal[time].get("error") is not None for time in times) \
            or any(right - left > 0.25 for left, right in zip(times, times[1:])) \
            or mapping.get("bytes") != 8 * 1024 * 1024 * 1024 or mapping.get("protection") != 0 or mapping.get("deallocated") is not True:
        raise ValueError("two-slot recovery before cleanup and normal dwell")
    retries = synthetic["healthyRetries"]
    if len(retries) != len(stopped) or {UUID(item["interruptedExecution"]) for item in retries} != set(stopped):
        raise ValueError("healthy retry after every controlled stop")
    jobs = set()
    for item in retries:
        prior = stopped[UUID(item["interruptedExecution"])]
        response, receipt = item["response"], item["receipt"]
        job = UUID(response["jobID"])
        identity = receipt["identity"]
        first, commit = number(receipt["firstRelease"]), number(receipt["terminalCommit"])
        releases, samples = receipt.get("releases", []), receipt.get("authorizationSamples", [])
        if job in jobs or identity.get("job") != response["jobID"] \
                or identity.get("owner") != prior["identity"]["owner"] or identity.get("transport") != prior["identity"]["transport"] \
                or response.get("state") != "awaitingConfirmation" or response.get("ok") is not True \
                or receipt.get("stop") is not None or receipt.get("cleanupComplete") is not True \
                or receipt.get("policy") != "system-pressure-v1" or number(prior["cleanupFinishedAt"]) > first \
                or response.get("firstRelease") != first or response.get("terminalCommit") != commit \
                or not first <= commit <= first + number(identity["timeout"]) + 15 \
                or [release.get("child") for release in releases] != ["worker", "verifier"] or len(samples) != 2:
            raise ValueError("healthy retry identity or completion")
        for release, sample in zip(releases, samples):
            at = number(release["clock"]["awake"])
            observed = number(sample["clock"]["awake"])
            if not first <= at <= commit or not observed <= at <= observed + 0.25 \
                    or sample.get("source") != "sysctl" or sample.get("pressure") not in (1, 2) or sample.get("error") is not None:
                raise ValueError("healthy retry live release authorization")
        jobs.add(job)
    validate_reaped_recovery(directory, result, host_pid, processes, executions)
    validate_spatial_cancellation(directory, result)
    return {"schema": "nexgenvideo/bpy-worker-evidence-validation/5", "untrustedExits": [71, 72],
            "memoryPolicy": "system-pressure-v1", "genuinePressureTransitionsProven": False}


def validate_spatial_cancellation(directory, result):
    production = result.get("productionSpatial", {})
    values = []
    for key, name in (("postCommitCancellation", "production-spatial-commit-cancel.json"),
                      ("hashCancellation", "production-spatial-hash-cancel.json")):
        meta = production.get(key, {})
        if meta.get("file") != name: raise ValueError("spatial cancellation evidence identity")
        data = (directory / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != meta.get("sha256"): raise ValueError("spatial cancellation evidence bytes")
        values.append(json.loads(data))
    commit, hash_evidence = values
    try:
        for key in ("sceneID", "priorRevision", "committedRevision", "currentRevision"): UUID(commit[key])
    except (KeyError, ValueError, TypeError, AttributeError) as error:
        raise ValueError("committed location identity") from error
    if commit.get("schema") != "nexgenvideo/spatial-commit-cancellation/1" \
            or commit["priorRevision"] == commit["committedRevision"] or commit["currentRevision"] != commit["committedRevision"] \
            or commit.get("cancelAfterCommitObserved") is not True or commit.get("cancelEnabledAtCommit") is not False \
            or commit.get("taskCancelledAfterLateCancel") is not False or commit.get("canUndo") is not True \
            or commit.get("error") != "" or type(commit.get("objects")) is not int or commit["objects"] != 1 \
            or not re.fullmatch(r"[a-f0-9]{64}", commit.get("committedSceneSHA256", "")) \
            or commit.get("readbackSceneSHA256") != commit["committedSceneSHA256"] or commit.get("payloadVerified") is not True:
        raise ValueError("committed location survives late user cancellation with Undo")
    if not isinstance(hash_evidence, dict) or hash_evidence.get("schema") != "nexgenvideo/spatial-hash-cancellation/2":
        raise ValueError("spatial hash cancellation evidence schema")
    cases = hash_evidence.get("hashes")
    if not isinstance(cases, list) or len(cases) != 2 or {item.get("purpose") for item in cases} != {"checkpoint", "file-digest"}:
        raise ValueError("caller-only spatial hash cancellation coverage")
    operations, scenes, files = set(), set(), set()
    for item in cases:
        operation, scene = UUID(item["operation"]), UUID(item["sceneID"])
        if operation in operations or scene in scenes: raise ValueError("spatial cancellation independent operations and scenes")
        operations.add(operation); scenes.add(scene)
        for key in ("sceneBytes", "hashedBytes", "expectedBytes", "device", "inode", "expectedDevice", "expectedInode", "sceneCount"):
            if type(item.get(key)) is not int: raise ValueError("spatial hash byte and file identity types")
        control, began, ended = number(item["controlSeconds"]), number(item["cancelledAt"]), number(item["endedAt"])
        identity = (item["device"], item["inode"])
        if item["sceneCount"] < 2 or item["sceneBytes"] < 256 * 1024 * 1024 \
                or item["expectedBytes"] != item["sceneBytes"] or not 0 < item["hashedBytes"] < item["sceneBytes"] \
                or item["device"] != item["expectedDevice"] or item["inode"] != item["expectedInode"] or identity in files \
                or item["device"] <= 0 or item["inode"] <= 0 or not re.fullmatch(r"[a-f0-9]{64}", item.get("sceneSHA256", "")) \
                or control <= 0 or not 0 <= ended - began <= 0.25 or ended - began >= control / 2 \
                or type(item.get("chunksAfterCancellation")) is not int or item["chunksAfterCancellation"] != 0 \
                or item.get("failure") != "cancelled" or item.get("taskCancelled") is not False or item.get("callerCancelled") is not True:
            raise ValueError("caller-only cancellation during actual large-file hash")
        files.add(identity)
        for stamp in (item.get("checkpointBefore"), item.get("checkpointAfter")):
            try:
                valid = isinstance(stamp, dict) and set(stamp) == {"transport", "revision", "sha256", "uploadedJobs"} \
                    and isinstance(stamp["transport"], str) and UUID(stamp["transport"]).int != 0 \
                    and isinstance(stamp["revision"], str) and isinstance(stamp["uploadedJobs"], str) \
                    and re.fullmatch(r"[0-9]+", stamp["uploadedJobs"]) \
                    and isinstance(stamp["sha256"], str) and (stamp["sha256"] == "" or re.fullmatch(r"[a-f0-9]{64}", stamp["sha256"]))
            except (ValueError, TypeError, AttributeError): valid = False
            if not valid: raise ValueError("spatial cancellation checkpoint stamp structure")
        if item.get("checkpointBefore") != item.get("checkpointAfter") or type(item.get("releasesBefore")) is not int \
                or item["releasesBefore"] != item.get("releasesAfter") or not re.fullmatch(r"[a-f0-9]{64}", item.get("indexBefore", "")) \
                or item["indexBefore"] != item.get("indexAfter"):
            raise ValueError("hash cancellation starts no upload and publishes no canonical bytes")
    editor = hash_evidence.get("editor")
    if not isinstance(editor, list) or len(editor) != 2 or {item.get("route") for item in editor} != {"user", "externalToken"}:
        raise ValueError("location editor cancellation coverage")
    editor_operations = set()
    for item in editor:
        try:
            operation = UUID(item["operation"])
            for key in ("sceneID", "revisionBefore", "revisionAfter"): UUID(item[key])
            if operation in editor_operations: raise ValueError("duplicate operation")
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            raise ValueError("location editor cancellation identity") from error
        editor_operations.add(operation)
        integers = ("frameBefore", "frameAfter", "sceneBytes", "hashedBytes", "chunksAfterCancellation", "releasesBefore", "releasesAfter")
        if (not all(type(item.get(key)) is int for key in integers)
            or item["revisionBefore"] != item["revisionAfter"] or item["frameBefore"] != item["frameAfter"]
            or item["sceneBytes"] < 256 * 1024 * 1024 or not 0 < item["hashedBytes"] < item["sceneBytes"]
            or item["chunksAfterCancellation"] != 0 or item["callerCancelled"] is not True
            or item["callingTaskCancelled"] is not False or item["canCancel"] is not False
            or item["releasesBefore"] != item["releasesAfter"] or not isinstance(item.get("error"), str)
            or (item["error"] != "" if item["route"] == "user" else item["error"] == "")):
            raise ValueError("location editor cancellation preserves state and separates user intent")
        source = next((value for value in cases if value["sceneID"] == item["sceneID"]), None)
        identities = ("device", "inode", "expectedDevice", "expectedInode")
        if (not all(type(item.get(key)) is int and item[key] > 0 for key in identities)
            or item.get("purpose") != ("file-digest" if item["route"] == "user" else "checkpoint")
            or item["device"] != item["expectedDevice"] or item["inode"] != item["expectedInode"]
            or source is None or item["sceneBytes"] != source["sceneBytes"]
            or item["device"] != source["device"] or item["inode"] != source["inode"]):
            raise ValueError("location editor cancellation stage and source")


def validate_reaped_recovery(directory, result, host_pid, processes, executions):
    meta = result.get("reapedRecovery", {})
    if meta.get("file") != "native-reaped-recovery.json":
        raise ValueError("reaped recovery evidence identity")
    data = (directory / meta["file"]).read_bytes()
    if hashlib.sha256(data).hexdigest() != meta.get("sha256"):
        raise ValueError("reaped recovery evidence bytes")
    cases = json.loads(data)
    if not isinstance(cases, list) or len(cases) != 2 or {item.get("route") for item in cases} != {"transportLoss", "ownerClose"}:
        raise ValueError("reaped recovery coverage")
    for item in cases:
        response, before, after, successor = [item[key] for key in ("response", "before", "after", "successor")]
        owned_child(response, host_pid, processes)
        execution = UUID(response["execution"])
        if execution in executions: raise ValueError("reaped recovery execution identity")
        executions.add(execution)
        for receipt in (before, after, successor):
            for key in ("id", "owner", "generation", "transport"): UUID(receipt["identity"][key])
        clock(item["checkedAt"])
        began, finished, checked = number(after["cleanupStarted"]), number(after["cleanupFinishedAt"]), number(item["checkedAt"]["awake"])
        expected = "closed" if item["route"] == "ownerClose" else "transportLost"
        if response.get("schema") != "nexgenvideo/bpy-monitor-response/2" or response.get("status") != "gone" \
                or response.get("outputComplete") is not True or response.get("supervisor") is not None \
                or response.get("worker") is not None or response.get("descendants") != [] \
                or response.get("stage") != 4 or type(response.get("exitStatus")) is not int \
                or response.get("exitStatus") != 0 or response.get("stopReason") is not None \
                or before.get("policy") != "system-pressure-v1" or after.get("policy") != "system-pressure-v1" \
                or before["identity"] != after["identity"] or before["identity"].get("kind") != "boundary" \
                or before.get("cleanupComplete") is not False or before.get("stop") is not None \
                or before.get("cleanupStarted") is not None or before.get("cleanupFinishedAt") is not None \
                or before.get("failure") is not None or after.get("failure") is not None \
                or after.get("stop") != expected or after.get("cleanupComplete") is not True \
                or item.get("reapedBeforeCleanup") is not True or item.get("recoveredAfter") is not True \
                or item.get("cleanupFailed") is not False \
                or not number(before["firstRelease"]) <= began <= finished <= began + 5 or checked < began + 6:
            raise ValueError("reaped recovery original cleanup and registry state")
        if successor.get("policy") != "system-pressure-v1" or successor.get("failure") is not None \
                or successor.get("stop") is not None or successor.get("firstRelease") is not None \
                or successor.get("cleanupComplete") is not False \
                or successor.get("releases") != [] or successor["identity"].get("kind") != "boundary" \
                or successor["identity"]["id"] == before["identity"]["id"] \
                or successor["identity"]["owner"] == before["identity"]["owner"] \
                or number(successor["grantedAt"]) < checked:
            raise ValueError("reaped recovery independent successor admission")


def validate_role_lock(memory):
    value = memory.get("roleLock", {})
    if value.get("control") != "host-owned-mutex-hold":
        raise ValueError("native role lock isolation coverage")
    hold, response, receipt = value["hold"], value["response"], value["receipt"]
    for item in (hold["acquired"], hold["heldThrough"], value["workerRoleFinishedAt"]): clock(item)
    began, ended, worker, first, commit = [number(item) for item in
        (hold["acquired"]["awake"], hold["heldThrough"]["awake"], value["workerRoleFinishedAt"]["awake"],
         receipt["firstRelease"], receipt["terminalCommit"])]
    expected_source = "print('ROLE_LOCK_PROGRESS', flush=True)\nbpy.context.scene.render.resolution_x = 64\nbpy.context.scene.render.resolution_y = 64"
    if hold.get("role") != "data" or not hold.get("slot") or not value.get("launchedSlot") or hold["slot"] == value["launchedSlot"] \
            or value.get("source") != expected_source or response.get("ok") is not True or response.get("state") != "awaitingConfirmation" \
            or "ROLE_LOCK_PROGRESS" not in response.get("stdout", "") or response.get("firstRelease") != first \
            or response.get("terminalCommit") != commit or response.get("jobID") != receipt["identity"].get("job") \
            or receipt.get("cleanupComplete") is not True or receipt.get("stop") is not None \
            or [item.get("child") for item in receipt.get("releases", [])] != ["worker", "verifier"] \
            or ended - began < 5 or not began <= worker <= first < ended \
            or not first <= number(receipt["releases"][0]["clock"]["awake"]) \
                <= number(receipt["releases"][1]["clock"]["awake"]) <= commit < ended \
            or not first <= commit <= first + number(receipt["identity"]["timeout"]) + 15 \
            or not value.get("holdingRevisionBefore") or not value.get("launchingRevisionBefore") \
            or value["holdingRevisionBefore"] != value.get("holdingRevisionAfter") \
            or value["launchingRevisionBefore"] != value.get("launchingRevisionAfter"):
        raise ValueError("other-role owner binding and actual worker release inside held interval")
    UUID(response["jobID"])
    samples, releases = receipt.get("authorizationSamples", []), receipt["releases"]
    if len(samples) != 2: raise ValueError("role lock worker and verifier authorization")
    for sample, release in zip(samples, releases):
        if sample.get("source") != "sysctl" or sample.get("pressure") not in (1, 2) or sample.get("error") is not None \
                or not number(sample["clock"]["awake"]) <= number(release["clock"]["awake"]) <= number(sample["clock"]["awake"]) + 0.25:
            raise ValueError("role lock fresh native release")


def validate_stdout_burst(memory, host_pid):
    value = memory.get("stdoutBurst", {})
    if value.get("mode") != "diagnostic-stdout-burst":
        raise ValueError("native stdout backpressure coverage")
    response, receipt = value["response"], value["receipt"]
    owned_child(response, host_pid, set())
    capture = response["diagnosticStdout"]
    burst = capture["burst"]
    for key in ("paused", "resumed", "childReadyWritten", "childReadyReceived"): clock(capture[key])
    clock(burst["started"]); clock(burst["finished"])
    written, received, paused, resumed, started, finished = [number(value["awake"]) for value in
        (capture["childReadyWritten"], capture["childReadyReceived"], capture["paused"], capture["resumed"], burst["started"], burst["finished"])]
    first = number(receipt["firstRelease"])
    if response.get("status") != "gone" or response.get("exitStatus") != 0 or response.get("stage") != 7 \
            or response.get("outputComplete") is not True or response.get("supervisor") is not None \
            or response.get("worker") is not None or response.get("descendants") != [] \
            or response.get("stopReason") is not None or receipt.get("stop") is not None or receipt.get("cleanupComplete") is not True \
            or type(burst.get("flags")) is not int or burst["flags"] < 0 or burst["flags"] & 0x4 \
            or burst.get("bytes") != 1_048_576 or capture.get("capturedBytes") != 1_048_576 \
            or capture.get("capturedSHA256") != hashlib.sha256(b"R" * 1_048_576).hexdigest() \
            or not written <= received <= first <= paused <= started <= resumed <= finished \
            or received - written > 0.1 or resumed - paused < 0.25 \
            or number(receipt["cleanupFinishedAt"]) < finished:
        raise ValueError("blocking native stdout, prompt childReady and exact resumed drain")
    samples = receipt.get("authorizationSamples", [])
    if len(samples) != 1 or samples[0].get("source") != "sysctl" or samples[0].get("error") is not None \
            or samples[0].get("pressure") not in (1, 2) or not number(samples[0]["clock"]["awake"]) <= first <= number(samples[0]["clock"]["awake"]) + 0.25:
        raise ValueError("stdout native release authorization")


def validate_runtime_observation(value):
    if value.get("schema") != "nexgenvideo/bpy-runtime-observation/1" or value.get("architecture") != "arm64" \
            or not re.fullmatch(r"26\.\d+\.\d+", value.get("osVersion", "")) \
            or not value.get("osBuild") or not value.get("kernel") \
            or value.get("imageVersionStatus") not in ("present", "absent") \
            or (value["imageVersionStatus"] == "present") != bool(value.get("imageVersion")) \
            or value.get("activitiesEnded") is not True or value.get("genuinePressureTransitionsProven") is not False:
        raise ValueError("actual minimum-OS runtime environment or activity completion")
    trace = value["trace"]
    if trace.get("overflow") is not False or not trace.get("pressure") or not trace.get("lifecycle") \
            or not trace.get("swap") or not trace.get("activity") or not trace.get("footprints"):
        raise ValueError("runtime observation coverage")
    if not any(item["sample"].get("source") == "sysctl" and item["sample"].get("pressure") in (1, 2, 4)
               and item["sample"].get("error") is None and item["sample"].get("byteCount") == 4 for item in trace["pressure"]):
        raise ValueError("actual UInt32 pressure adapter qualification")
    for item in trace["swap"]:
        clock(item["clock"])
        if item.get("error") is not None or item.get("bytes") != 32 \
                or any(type(item.get(key)) is not int or not 0 <= item[key] < 1 << 64 for key in ("total", "used", "available")) \
                or item["used"] > item["total"] or item["available"] > item["total"]:
            raise ValueError("timestamped read-only swap observation")
    footprints = list(trace["footprints"].values())
    clock(value["evidenceClock"])
    if {item.get("role") for item in footprints} != {"host", "service", "supervisor", "worker"}:
        raise ValueError("per-role footprint coverage")
    for item in footprints:
        clock(item["clock"])
        if item.get("error") is not None or type(item.get("current")) is not int or type(item.get("peak")) is not int \
                or not 0 < item["current"] <= item["peak"] < 1 << 64 or item["peak"] <= 0 \
                or type(item.get("pid")) is not int or item["pid"] <= 1 or type(item.get("start")) is not int or item["start"] <= 0:
            raise ValueError("current and peak observed owned footprint")
        if item.get("status") not in ("live", "exited") or (item["role"] == "host" and item["status"] != "live"):
            raise ValueError("current and peak observed owned footprint")
        if item["status"] == "live" and item.get("exitObserved") is not None:
            raise ValueError("current and peak observed owned footprint")
        if item["status"] == "exited":
            clock(item["exitObserved"])
            if not number(item["clock"]["awake"]) < number(item["exitObserved"]["awake"]) <= number(value["evidenceClock"]["awake"]):
                raise ValueError("current and peak observed owned footprint")
    activities = {}
    for item in trace["activity"]:
        activities.setdefault(UUID(item["id"]), []).append(item)
        UUID(item["parent"])
        clock(item["clock"])
    for events in activities.values():
        if len(events) != 2 or events[0].get("event") != "begin" or events[1].get("event") != "end" \
                or events[0].get("scope") != events[1].get("scope") or events[0].get("parent") != events[1].get("parent") \
                or number(events[1]["clock"]["awake"]) < number(events[0]["clock"]["awake"]):
            raise ValueError("actual bounded runtime activity lifetime")
        if number(events[1]["clock"]["awake"]) > number(value["evidenceClock"]["awake"]):
            raise ValueError("actual bounded runtime activity lifetime")
    digest_activities = [events for events in activities.values() if events[0].get("scope") == "Verify 3D runtime files"]
    if not digest_activities:
        raise ValueError("parented runtime file verification activity")
    for events in digest_activities + [events for events in activities.values() if events[0].get("scope") == "Verify a 3D movie"]:
        if not any(parent[0].get("scope") == "Validate and encode 3D media"
                   and parent[0]["parent"] == events[0]["parent"]
                   and parent[0]["clock"]["awake"] <= events[0]["clock"]["awake"] <= parent[1]["clock"]["awake"]
                   for parent in activities.values()):
            raise ValueError("parented runtime file verification activity")
    validate_stop_observation(value)
    maximum, sleep = 0, 0
    controllers = {UUID(item["controller"]) for item in trace["pressure"]}
    for controller in controllers:
        observations = sorted((item["sample"]["clock"] for item in trace["pressure"] if UUID(item["controller"]) == controller
            and item["sample"].get("source") in ("sysctl", "selftest-sensor") and item["sample"].get("error") is None
            and item["sample"].get("pressure") is not None), key=lambda item: number(item["awake"]))
        lifecycle = sorted((item for item in trace["lifecycle"] if UUID(item["controller"]) == controller),
            key=lambda item: number(item["clock"]["awake"]))
        began = None
        for event in lifecycle:
            clock(event["clock"])
            if event["event"] == "dispatch-source-resumed":
                if began is not None: raise ValueError("overlapping observation lifetimes")
                began = event["clock"]
            elif event["event"] == "sampling-ended" and began is not None:
                end = event["clock"]
                points = [began] + [item for item in observations if began["awake"] <= item["awake"] <= end["awake"]] + [end]
                for left, right in zip(points, points[1:]):
                    clock(left); clock(right)
                    maximum = max(maximum, right["awake"] - left["awake"])
                    sleep = max(sleep, abs((right["continuous"] - right["awake"]) - (left["continuous"] - left["awake"])))
                began = None
            else: raise ValueError("invalid observation lifetime")
        if began is not None or not lifecycle: raise ValueError("unended observation lifetime")
    if abs(number(value["maximumAwakeObservationGap"]) - maximum) > 1e-9 \
            or abs(number(value["maximumSleepOffsetChange"]) - sleep) > 1e-9:
        raise ValueError("independent observation gap or sleep clocks")


def validate_stop_observation(value):
    trace = value["trace"]
    stops, cleanups = trace.get("stops"), trace.get("processCleanup")
    if not isinstance(stops, list) or not stops or not isinstance(cleanups, dict) or not cleanups:
        raise ValueError("owned stop and process cleanup observation coverage")
    reasons = {"diagnosticMemory", "pressure", "monitorUnavailable", "monitorUnresponsive", "deadline", "serviceStall",
               "cancelled", "closed", "cleanupFailed", "diagnosticSafety", "executionFailed", "launchFailed", "transportLost",
               "ownershipViolation", "orphanedWorker", "observationFailed", "disk", "file-count", "process-count"}
    by_permit, seen = {}, set()
    for key, item in cleanups.items():
        permit = UUID(item["permit"])
        if UUID(key) != permit or permit in by_permit or item.get("complete") is not True or not isinstance(item.get("grounds"), list):
            raise ValueError("owned process cleanup identity or completion")
        UUID(item["controller"])
        finished = number(item["finished"])
        if not 0 <= finished <= number(value["evidenceClock"]["awake"]):
            raise ValueError("owned process cleanup identity or completion")
        if item.get("started") is not None and not number(item["started"]) <= finished <= number(item["started"]) + 5:
            raise ValueError("original owned process cleanup deadline")
        for ground in item["grounds"]:
            clock(ground["clock"])
            if ground.get("reason") not in reasons or ground["clock"]["awake"] > finished or ground["reason"] == "cleanupFailed":
                raise ValueError("observed owned stop grounds")
        by_permit[permit] = item
    for item in stops:
        permit, controller = UUID(item["permit"]), UUID(item["controller"])
        clock(item["decision"])
        if permit in seen or item.get("reason") not in reasons or type(item.get("hasHandler")) is not bool:
            raise ValueError("observed owned stop decision")
        seen.add(permit)
        if item["hasHandler"]:
            if not isinstance(item.get("requestInvoked"), dict):
                raise ValueError("observed owned stop request latency")
            clock(item["requestInvoked"])
            latency = number(item["requestInvoked"]["awake"]) - number(item["decision"]["awake"])
            if latency < 0 or item["requestInvoked"]["awake"] > value["evidenceClock"]["awake"] \
                    or (item["reason"] == "pressure" and latency > 0.25):
                raise ValueError("observed owned stop request latency")
        elif item.get("requestInvoked") is not None:
            raise ValueError("observed owned stop request latency")
        cleanup = by_permit.get(permit)
        if cleanup is None or UUID(cleanup["controller"]) != controller or cleanup.get("started") is None \
                or number(cleanup["started"]) != number(item["decision"]["awake"]) \
                or not any(ground["reason"] == item["reason"] and ground["clock"] == item["decision"] for ground in cleanup["grounds"]):
            raise ValueError("observed owned stop and cleanup lineage")
        if item.get("requestInvoked") is not None and item["requestInvoked"]["awake"] > cleanup["finished"]:
            raise ValueError("observed owned stop and cleanup lineage")
    watchdogs = sum(item["reason"] == "monitorUnresponsive" for item in stops)
    if type(value.get("observerWatchdogExpiryCount")) is not int or value["observerWatchdogExpiryCount"] != watchdogs or watchdogs < 1:
        raise ValueError("independent observer watchdog expiry count")


def clock(value):
    if number(value["continuous"]) < number(value["awake"]) or number(value.get("uncertainty", 0)) < 0:
        raise ValueError("invalid awake and continuous clocks")


def validate_media_cancellation(memory):
    value = memory.get("mediaCancellation", {})
    if value.get("schema") != "nexgenvideo/bpy-native-media-cancellation/1":
        raise ValueError("native media cancellation coverage")
    encoder, decode = value["encoder"], value["queuedDecode"]
    observed, requested, settled, disposed = [number(encoder[key]) for key in
        ("criticalObservedAt", "stopRequestedAt", "cancelSettledAt", "disposedAt")]
    charges = encoder.get("chargedBefore", [])
    UUID(encoder["owner"])
    if encoder.get("synthetic") is not True or encoder.get("stop") != "pressure" \
            or encoder.get("width") != 64 or encoder.get("height") != 64 or encoder.get("framesAppended") != 1 \
            or encoder.get("statusBefore") != "writing" or encoder.get("statusAfter") != "cancelled" \
            or encoder.get("fileRetainedWhileWriting") is not True \
            or encoder.get("writerOwnersBefore") != 1 or encoder.get("writerOwnersAfter") != 0 \
            or len(charges) != 2 or {item.get("kind") for item in charges} != {"retained", "transfer"} \
            or len({UUID(item["id"]) for item in charges}) != 2 \
            or any(type(item.get("bytes")) is not int or item["bytes"] != 512 * 1024 * 1024 for item in charges) \
            or encoder.get("chargedAfter") != 0 or not observed <= requested <= observed + 0.25 \
            or not requested <= settled <= disposed <= requested + 5:
        raise ValueError("native host encoder stop or retained storage cleanup")
    cancelled, completed = number(decode["cancelledAt"]), number(decode["completedAt"])
    expected_capacity = 2 * (512 * 1024 * 1024 + 67_108_864 * 12)
    if decode.get("failure") != "cancelled" or decode.get("decoded") is not False \
            or decode.get("queuedBefore") != 1 or decode.get("queuedAfter") != 0 \
            or decode.get("capacityHeldBefore") != expected_capacity or decode.get("capacityHeldAfter") != expected_capacity \
            or not cancelled <= completed <= cancelled + 0.05:
        raise ValueError("native queued decode cancellation")


def validate_source_binding(directory, memory, host_pid):
    if memory.get("sourceBindingEvidenceFile") != "native-source-binding.json":
        raise ValueError("gated mutation evidence missing")
    data = (directory / "native-source-binding.json").read_bytes()
    if hashlib.sha256(data).hexdigest() != memory.get("sourceBindingEvidenceSHA256"):
        raise ValueError("gated mutation evidence bytes")
    cases = json.loads(data)
    if not isinstance(cases, list) or [item["mutation"].get("target") for item in cases] != ["source.py", "job.json"]:
        raise ValueError("gated source and configuration mutation coverage")
    source = "print('BOUND_SOURCE_RAN', flush=True)\nbpy.context.scene.render.resolution_x = 64\nbpy.context.scene.render.resolution_y = 64"
    processes, jobs = set(), set()
    for case in cases:
        item, retry = case["mutation"], case["retry"]
        response, ended, receipt = item["response"], item["ended"], item["receipt"]
        before, after = item["gateBefore"], item["gateAfter"]
        gate = before["process"]
        for value in (before["clock"], after["clock"], item["mutatedAt"], item["authorizedAt"]): clock(value)
        replacement = "raise RuntimeError('UNAPPROVED_SOURCE_EXECUTED')" if item["target"] == "source.py" else '{"memoryPolicy":"unapproved"}'
        child = owned_child(ended, host_pid, processes)
        job = UUID(response["jobID"])
        mutated, authorized, released = number(item["mutatedAt"]["awake"]), number(item["authorizedAt"]["awake"]), number(receipt["firstRelease"])
        if job in jobs or item.get("source") != source or response.get("ok") is not True \
                or receipt["identity"].get("job") != response["jobID"] or receipt["identity"].get("transport") != ended.get("transport") \
                or any(UUID(proof["execution"]) != UUID(ended["execution"]) or proof["permit"] != receipt["identity"]["id"] for proof in (before, after)) \
                or after["process"] != gate or before.get("sourceSHA256") != after.get("sourceSHA256") \
                or before.get("configurationSHA256") != after.get("configurationSHA256") \
                or before.get("sourceSHA256") != hashlib.sha256(source.encode()).hexdigest() \
                or not re.fullmatch(r"[a-f0-9]{64}", before.get("configurationSHA256", "")) \
                or not number(before["clock"]["awake"]) <= mutated <= number(after["clock"]["awake"]) <= released \
                or authorized < number(after["clock"]["awake"]) \
                or item.get("originalSHA256") != before["sourceSHA256" if item["target"] == "source.py" else "configurationSHA256"] \
                or receipt.get("cleanupComplete") is not True or ended.get("status") != "detached" \
                or ended.get("outputComplete") is not True or ended.get("supervisor") is not None or ended.get("worker") is not None \
                or ended.get("descendants") != [] or gate.get("parent") != host_pid \
                or not any(value.get("pid") == gate.get("pid") and value.get("start") == gate.get("start") for value in ended["ended"]) \
                or child.get("parent") != gate.get("pid") or not mutated <= released or not mutated <= authorized \
                or type(item.get("originalInode")) is not int or type(item.get("replacementInode")) is not int \
                or item["originalInode"] <= 0 or item["replacementInode"] <= 0 or item["originalInode"] == item["replacementInode"] \
                or not re.fullmatch(r"[a-f0-9]{64}", item.get("originalSHA256", "")) \
                or item["originalSHA256"] == item.get("replacementSHA256") \
                or item.get("replacementSHA256") != hashlib.sha256(replacement.encode()).hexdigest():
            raise ValueError("gated mutation identity, order or exact bytes")
        releases = [value.get("child") for value in receipt.get("releases", [])]
        if item["target"] == "source.py":
            if item["originalSHA256"] != hashlib.sha256(source.encode()).hexdigest() \
                    or response.get("state") != "failed" or ended.get("exitStatus") != 70 or response.get("outputs") != [] \
                    or releases != ["worker"] or "invalid host bootstrap descriptor" not in response.get("stdout", "") \
                    or "BOUND_SOURCE_RAN" in response.get("stdout", "") or "UNAPPROVED_SOURCE_EXECUTED" in response.get("stdout", ""):
                raise ValueError("changed source ran or was not refused at the descriptor boundary")
        elif response.get("state") != "awaitingConfirmation" or ended.get("exitStatus") != 0 \
                or releases != ["worker", "verifier"] or receipt.get("terminalCommit") is None \
                or "BOUND_SOURCE_RAN" not in response.get("stdout", ""):
            raise ValueError("worker reopened mutable configuration")
        positive, positive_receipt = retry["response"], retry["receipt"]
        positive_job = UUID(positive["jobID"])
        first, commit = number(positive_receipt["firstRelease"]), number(positive_receipt["terminalCommit"])
        if UUID(retry["interruptedExecution"]) != UUID(ended["execution"]) or positive_job in jobs or positive_job == job \
                or positive.get("ok") is not True or positive.get("state") != "awaitingConfirmation" \
                or positive_receipt["identity"].get("job") != positive["jobID"] \
                or any(positive_receipt["identity"].get(key) != receipt["identity"].get(key) for key in ("owner", "transport")) \
                or positive_receipt.get("stop") is not None or positive_receipt.get("cleanupComplete") is not True \
                or first < number(receipt["cleanupFinishedAt"]) or not first <= commit <= first + number(positive_receipt["identity"]["timeout"]) + 15 \
                or positive.get("firstRelease") != first or positive.get("terminalCommit") != commit \
                or [value.get("child") for value in positive_receipt.get("releases", [])] != ["worker", "verifier"]:
            raise ValueError("gated mutation healthy recovery")
        jobs.update((job, positive_job))


def number(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError("invalid awake timestamp")
    return value


def owned_child(response, host_pid, processes):
    ended = response.get("ended", [])
    if len(ended) != 2 or any(type(item.get("pid")) is not int or not 1 < item["pid"] < 1 << 31
                             or type(item.get("start")) is not int or not 0 < item["start"] < 1 << 64 for item in ended):
        raise ValueError("owned supervisor and child receipts")
    supervisors = [item for item in ended if item.get("parent") == host_pid]
    if len(supervisors) != 1:
        raise ValueError("owned supervisor parent")
    children = [item for item in ended if item.get("parent") == supervisors[0]["pid"]]
    if len(children) != 1:
        raise ValueError("owned child parent")
    for item in ended:
        identity = (item["pid"], item["start"])
        if identity in processes:
            raise ValueError("reused reaped process identity")
        processes.add(identity)
    return children[0]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.directory), sort_keys=True))
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"worker evidence rejected: {error}\n")
