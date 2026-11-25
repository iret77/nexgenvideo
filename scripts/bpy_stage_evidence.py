"""Bind the per-stage evidence of a scoped bpy acceptance run to its final result."""
import argparse
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


def validate(directory, scope, source_sha):
    directory = Path(directory)
    require(scope in SCOPES, "unknown acceptance scope")
    result = read(directory / "result.json")
    host = read(directory / "process-result.json")["pid"]
    require(result.get("schema") == "nexgenvideo/bpy-runtime-acceptance/2" and result.get("scope") == scope,
            "result scope")
    require(set(result) == TERMINAL | set().union(*STAGES.values()), "result sections differ from the scoped stages")
    stages = directory / "stages"
    attempts = {f"physical-storage-{mode}-{kind}.json" for mode in STORAGE_MODES for kind in ("response", "proof")}
    require({path.name for path in stages.iterdir()} == {name + ".json" for name in STAGES} | attempts,
            "persisted stage files")
    for stage, keys in STAGES.items():
        record = read(stages / (stage + ".json"))
        require(record.get("schema") == "nexgenvideo/bpy-stage-evidence/1" and record.get("scope") == scope
                and record.get("stage") == stage, "stage identity: " + stage)
        require(type(record.get("hostPID")) is int and record["hostPID"] == host, "stage host: " + stage)
        require(record.get("sourceSHA") == source_sha, "stage source: " + stage)
        value = record.get("value")
        require(isinstance(value, dict) and set(value) == keys, "stage sections: " + stage)
        for key in keys:
            require(value[key] == result[key], "stage differs from the final result: " + stage + "." + key)
    proofs = {item.get("mode"): item for item in result["physicalStorage"]}
    require(len(result["physicalStorage"]) == len(STORAGE_MODES) and set(proofs) == set(STORAGE_MODES),
            "physical storage cases")
    for mode in STORAGE_MODES:
        require(read(stages / f"physical-storage-{mode}-proof.json") == proofs[mode], "raw storage proof: " + mode)
        response = read(stages / f"physical-storage-{mode}-response.json")
        require(response.get("ok") is True and response.get("state") == "awaitingConfirmation",
                "raw storage response: " + mode)
    return dict(schema="nexgenvideo/bpy-stage-evidence-validation/1", scope=scope, stages=list(STAGES))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--scope", choices=SCOPES, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.directory, args.scope, args.source_sha), sort_keys=True))
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, f"stage evidence rejected: {error}\n")
