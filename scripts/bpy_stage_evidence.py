"""Bind the per-stage evidence of a scoped bpy acceptance run to its final result."""
import argparse
import hashlib
import json
from pathlib import Path

STAGES = {
    "two-slot-lifecycle": {"python", "bpy", "probeA", "probeB", "serviceA", "serviceB", "coldStartSeconds",
                           "serviceColdStartSeconds", "closeBeforeOpenReleased", "failedOpenReleased",
                           "threeRealDocuments", "thirdDocumentInitiallyDenied", "operationPresentationLifetime",
                           "overlappingPresentations"},
    "trusted-verification": {"warmJobSeconds", "hostJobSeconds", "jobMetrics", "trustedVerification",
                             "deniedPositiveControls"},
    "job-isolation": {"duplicateJoined", "changedDuplicateRejected", "forgedResultState", "cancelState",
                      "transportTimeoutRecovered", "droppedReplyEvidenceSHA256"},
    "memory-policy": {"memoryPolicyVersion", "memoryPolicy"},
    "service-recovery": {"untrustedExitEvidenceFile", "untrustedExitEvidenceSHA256", "crashState",
                         "supervisorIdentityWriteFailureState", "supervisorIdentityWriteFailureRecovered",
                         "supervisorIdentityCaptureFailureState", "supervisorIdentityCaptureFailureRecovered",
                         "serviceRecoveryRevision", "serviceDeathBeforeReleaseRecovered", "parentDeathJobFailedClosed",
                         "parentDeathExecObserved", "parentDeathWorkerExitObserved", "execveOrphanReaped"},
    "slot-release": {"operationDocumentClose", "operationLastRelease"},
    "physical-storage": {"physicalStorage"},
    "spatial-authoring": {"spatialAuthoring"},
    "resource-limits": {"containerSiblingWriteDenied", "supervisorSignalDenied", "supervisorSignalRecovered",
                        "structuralLimitState", "renderOnlyGeometryState", "secondarySceneGeometryState",
                        "prefixedUserGeometryState", "zeroEffectiveResolutionState", "noEnabledViewLayerState",
                        "storageLimitState", "aggregateByteLimitState", "unlinkedStorageLimitState",
                        "renameChurnStorageLimitState", "healthyResourceChurnState", "resourceScanErrorState",
                        "resourceSupervisorRecovered", "immutableCleanupFlagApplied", "immutableCleanupFlagDenied",
                        "closedSessionStorageOwnershipReleased"},
    "slot-reuse": {"slotReusedAfterClose"},
    "unavailable-sensor": {"unavailableSensor"},
    "reaped-recovery": {"reapedRecovery"},
    "production-spatial": {"productionSpatial"},
    "storage-recovery": {"storageRecovery"},
}
TERMINAL = {"schema", "scope", "nativeProtocolEvidenceSHA256", "nativeProtocolEvidenceFile", "appTerminationJobStarted",
            "operationShutdown", "appDelegateShutdown", "hostPeakMemoryBytes", "runtimeObservation"}
STORAGE_MODES = ("fileport", "memory-entry", "scm-rights")
SCOPES = ("storage-isolation",)


def require(value, message):
    if not value:
        raise ValueError(message)


def read(path):
    require(path.is_file() and not path.is_symlink(), "missing regular stage evidence: " + path.name)
    return json.loads(path.read_bytes())


def launch(directory, source_sha):
    process = read(Path(directory) / "process.json")
    require(type(process.get("pid")) is int and process["pid"] > 1 and process.get("mode") == "runtime"
            and process.get("sourceSHA") == source_sha, "launched host identity")
    return process["pid"]


def stage(directory, name, scope, host, source_sha):
    record = read(Path(directory) / "stages" / (name + ".json"))
    require(record.get("schema") == "nexgenvideo/bpy-stage-evidence/1" and record.get("scope") == scope
            and record.get("stage") == name, "stage identity: " + name)
    require(type(record.get("hostPID")) is int and record["hostPID"] == host, "stage host: " + name)
    require(record.get("sourceSHA") == source_sha, "stage source: " + name)
    value = record.get("value")
    require(isinstance(value, dict) and set(value) == STAGES[name], "stage sections: " + name)
    return value


def validate_physical_storage(directory, scope, source_sha):
    directory = Path(directory)
    require(scope in SCOPES, "unknown acceptance scope")
    cases = stage(directory, "physical-storage", scope, launch(directory, source_sha), source_sha)["physicalStorage"]
    proofs = {item.get("mode"): item for item in cases}
    require(len(cases) == len(STORAGE_MODES) and set(proofs) == set(STORAGE_MODES), "physical storage cases")
    jobs = set()
    for mode in STORAGE_MODES:
        raw = directory / "stages" / f"physical-storage-{mode}-proof.json"
        require(read(raw) == proofs[mode], "raw storage proof: " + mode)
        response = read(directory / "stages" / f"physical-storage-{mode}-response.json")
        outputs = [item for item in response.get("outputs", []) if item.get("name") == "storage-proof.json"]
        require(response.get("ok") is True and response.get("state") == "awaitingConfirmation"
                and isinstance(response.get("jobID"), str) and response["jobID"] not in jobs and len(outputs) == 1
                and outputs[0].get("sha256") == hashlib.sha256(raw.read_bytes()).hexdigest()
                and outputs[0].get("byteCount") == raw.stat().st_size, "raw storage response: " + mode)
        jobs.add(response["jobID"])
    return cases


def validate(directory, scope, source_sha):
    directory = Path(directory)
    require(scope in SCOPES, "unknown acceptance scope")
    result = read(directory / "result.json")
    host = launch(directory, source_sha)
    require(read(directory / "process-result.json").get("pid") == host, "completed host identity")
    require(result.get("schema") == "nexgenvideo/bpy-runtime-acceptance/2" and result.get("scope") == scope,
            "result scope")
    require(set(result) == TERMINAL | set().union(*STAGES.values()), "result sections differ from the scoped stages")
    stages = directory / "stages"
    attempts = {f"physical-storage-{mode}-{kind}.json" for mode in STORAGE_MODES for kind in ("response", "proof")}
    require({path.name for path in stages.iterdir()} == {name + ".json" for name in STAGES} | attempts,
            "persisted stage files")
    for name, keys in STAGES.items():
        value = stage(directory, name, scope, host, source_sha)
        for key in keys:
            require(value[key] == result[key], "stage differs from the final result: " + name + "." + key)
    validate_physical_storage(directory, scope, source_sha)
    return dict(schema="nexgenvideo/bpy-stage-evidence-validation/1", scope=scope, stages=list(STAGES))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--scope", choices=SCOPES, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--physical-storage-only", action="store_true")
    args = parser.parse_args()
    try:
        if args.physical_storage_only:
            cases = validate_physical_storage(args.directory, args.scope, args.source_sha)
            print(json.dumps(dict(schema="nexgenvideo/bpy-physical-storage-binding/1", scope=args.scope,
                                  modes=sorted(item["mode"] for item in cases)), sort_keys=True))
        else:
            print(json.dumps(validate(args.directory, args.scope, args.source_sha), sort_keys=True))
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"stage evidence rejected: {error}\n")
