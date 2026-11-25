import copy
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import bpy_stage_evidence as stage_evidence

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/bpy-runtime-acceptance.yml"
SELFTEST = ROOT / "Sources/NexGenVideo/ThreeD/BpyRuntimeSelfTest.swift"
APP = "/runner/relocated/NexGenVideo.app"
FOREIGN = "/runner/denied/foreign-blender"
SOURCE = "a" * 40
HOST = 4242
SCOPE_LINES = '            and .scope == "storage-isolation"\n            and (has("productionSpatial") | not)\n'
KEPT_PREDICATES_SHA256 = "80ba0269fc2f551cf7e9b58d691d9486008574ce085cf66155b6085515d830f6"
STORAGE_PREDICATE = '''            ([.physicalStorage[].mode] | sort) == ["fileport", "memory-entry", "scm-rights"]
            and all(.physicalStorage[];
              .capacityBytes > 0 and .capacityBytes <= 67108864
              and .filledBytes > 0 and .filledBytes <= .capacityBytes
              and .retainedBytes == 4194304 and .storageErrno == 28
              and (.retentionDeniedErrno == 0 or
                   (.mode != "memory-entry" and (.retentionDeniedErrno == 1 or .retentionDeniedErrno == 13))))'''
STORAGE_GUARD = '''            guard result.response.state == .awaitingConfirmation,
                  let url = result.stagedOutputs["storage-proof.json"],
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  value["mode"] as? String == mode,
                  let capacity = value["capacityBytes"] as? UInt64, capacity > 0, capacity <= 64 * 1_024 * 1_024,
                  let filled = value["filledBytes"] as? UInt64, filled > 0, filled <= capacity,
                  value["fileSizeLimitBytes"] as? UInt64 == 8 * 1_024 * 1_024,
                  let pressureFiles = value["pressureFileCount"] as? Int, pressureFiles >= 2,
                  let largestFile = value["largestPressureFileBytes"] as? UInt64,
                  largestFile > 0, largestFile <= 8 * 1_024 * 1_024,
                  value["retainedBytes"] as? UInt64 == 4 * 1_024 * 1_024,
                  value["storageErrno"] as? Int == Int(ENOSPC),
                  let denied = value["retentionDeniedErrno"] as? Int,
                  (denied == 0 || (mode != "memory-entry" && [Int(EPERM), Int(EACCES)].contains(denied))) else {
                throw BpyRuntimeError.invalidOutput("The bounded volume did not prove ENOSPC for \\(mode).")
            }'''
UNCHANGED_STEPS = {
    "Prove deterministic deletion during native directory accounting":
        "b9b4d2faf64e27c72e1a3d4b93439980005ac0c3bbe5f9c5a6ff8ab00b29eb8a",
    "Prove pre-lease and post-exec host-crash cleanup":
        "255880e6a8113658bc08aaa940541a11b1d40e37fd6489c937303929941e97b7",
    "Prove both sandbox boundary slots using an explicitly derived fixture":
        "fdae3cdd439f605b858e751742f4361d8b3e40af68dc9937074a20c17fe825c3",
}


def step(name):
    return WORKFLOW.read_text().split(f"      - name: {name}\n", 1)[1].split("\n      - ", 1)[0]


def native_filter():
    text = step("Run real bpy acceptance without ambient Blender or Python")
    head = """jq -e --arg app "$APP" --arg foreign "$RUNNER_TEMP/denied/foreign-blender" '\n"""
    return text.split(head, 1)[1].split("""          ' "$EVIDENCE/result.json"\n""", 1)[0]


def persisted_filter():
    text = step("Evaluate the physical storage proof persisted by the native run")
    return text.split("jq -e '\n", 1)[1].split("""          ' "$RUNNER_TEMP/evidence/stages/physical-storage.json\"""", 1)[0]


def storage_cases():
    return [dict(mode=mode, capacityBytes=64 * 1024 * 1024, filledBytes=60 * 1024 * 1024, retainedBytes=4 * 1024 * 1024,
                 retentionDeniedErrno=0, storageErrno=28, fileSizeLimitBytes=8 * 1024 * 1024, pressureFileCount=8,
                 largestPressureFileBytes=8 * 1024 * 1024) for mode in ("fileport", "memory-entry", "scm-rights")]


def complete_result():
    states = dict(structuralLimitState="resourceLimited", renderOnlyGeometryState="resourceLimited",
                  secondarySceneGeometryState="resourceLimited", prefixedUserGeometryState="resourceLimited",
                  zeroEffectiveResolutionState="resourceLimited", noEnabledViewLayerState="resourceLimited",
                  storageLimitState="resourceLimited", aggregateByteLimitState="resourceLimited",
                  unlinkedStorageLimitState="resourceLimited", renameChurnStorageLimitState="resourceLimited",
                  healthyResourceChurnState="awaitingConfirmation", resourceScanErrorState="crashed")
    flags = ("duplicateJoined", "changedDuplicateRejected", "failedOpenReleased", "closeBeforeOpenReleased",
             "transportTimeoutRecovered", "containerSiblingWriteDenied", "supervisorSignalDenied", "supervisorSignalRecovered",
             "supervisorIdentityWriteFailureRecovered", "supervisorIdentityCaptureFailureRecovered",
             "resourceSupervisorRecovered", "serviceDeathBeforeReleaseRecovered", "parentDeathJobFailedClosed",
             "parentDeathExecObserved", "parentDeathWorkerExitObserved", "execveOrphanReaped", "threeRealDocuments",
             "thirdDocumentInitiallyDenied", "slotReusedAfterClose", "appTerminationJobStarted", "appDelegateShutdown",
             "operationPresentationLifetime", "overlappingPresentations", "operationDocumentClose", "operationLastRelease",
             "operationShutdown", "closedSessionStorageOwnershipReleased")
    spatial = ("glbImport", "quaternionKeyframes", "viewedFrameEdit", "cameraDimensions", "stableRestFrame",
               "resourceReceipt", "preCancelledCallerReceiptRejected", "preCancelledCallerDerivationRejected",
               "preCancelledCallerSequenceRejected", "resolvedStatePixels", "fractionalTimebaseMovie",
               "derivationAuthentication", "completeShotSequence", "partialLastFrame", "sequenceTamperingRejected",
               "sequenceDiscardRevokes", "sequenceExtraChunkRejected", "evaluatedDeformationBounds")
    recovery = ("bootIdentityRead", "normalHelperCompletion", "staleHelperRejected", "journalLockEnforced",
                "crashedHelperRetained", "ancestorSymlinkRejected", "leafSymlinkRejected", "regularFileRejected",
                "searchOnlyAncestorOpened")
    libraries = dict(alembic=[1, 8, 3], ocio=[2, 5, 0], oiio=[3, 1, 13], opensubdiv=[3, 7, 0], openvdb=[13, 0, 0], usd=[0, 26, 3])
    return {
        "schema": "nexgenvideo/bpy-runtime-acceptance/2", "scope": "storage-isolation", "python": "3.13.15", "bpy": "5.2.2",
        "probeA": 501, "probeB": 502, "serviceA": 601, "serviceB": 602, "coldStartSeconds": 1.5,
        "serviceColdStartSeconds": 1.25, "warmJobSeconds": 0.5, "hostJobSeconds": 4.5, "hostPeakMemoryBytes": 1 << 28,
        "jobMetrics": dict(job_wall_seconds=4, worker_wall_seconds=3, verification_seconds=1, worker_peak_memory_bytes=10,
                           verifier_peak_memory_bytes=10, service_peak_memory_bytes=10, disk_peak_bytes=10,
                           file_peak_count=3, descendant_peak_count=0, worker_process_identifier=11,
                           verifier_process_identifier=12, autoexec_positive_control=1, vertices=200, polygons=100),
        "trustedVerification": dict(secretEnvironmentAbsent=True, autorunTextPresent=True, autorunMarkerAbsent=True,
            blenderBuildHash="d13f752e3b9c", libraryVersions={key: dict(version=value) for key, value in libraries.items()},
            modifiers=dict(NGV_Room=["BEVEL"]), executable=APP + "/Contents/python", bpyModule=APP + "/bpy/__init__.so",
            blenderUserConfig="/elsewhere", networkDenied=dict(denied=True, errno=1),
            deniedPaths={"/secret": dict(denied=True, errno=1), "/canonical": dict(denied=True, errno=13)},
            scenes=[dict(engine="CYCLES", cyclesDevice="GPU")]),
        "deniedPositiveControls": [dict(path=f"/denied/{index}", bytes=5) for index in range(4)],
        "nativeProtocolEvidenceSHA256": "c" * 64, "nativeProtocolEvidenceFile": "native-protocol-evidence.json",
        "forgedResultState": "timedOut", "cancelState": "cancelled", "droppedReplyEvidenceSHA256": "d" * 64,
        "memoryPolicyVersion": "system-pressure-v1", "memoryPolicy": dict(schema="nexgenvideo/bpy-memory-policy-evidence/3"),
        "unavailableSensor": dict(file="native-unavailable-sensor.json", sha256="e" * 64),
        "reapedRecovery": dict(file="native-reaped-recovery.json", sha256="f" * 64),
        "untrustedExitEvidenceFile": "native-untrusted-exits.json", "untrustedExitEvidenceSHA256": "b" * 64,
        "physicalStorage": storage_cases(), "spatialAuthoring": dict.fromkeys(spatial, True),
        "storageRecovery": dict.fromkeys(recovery, True), "immutableCleanupFlagApplied": False,
        "immutableCleanupFlagDenied": True, "crashState": "crashed", "serviceRecoveryRevision": "revision-e",
        "supervisorIdentityWriteFailureState": "failed", "supervisorIdentityCaptureFailureState": "failed",
        "runtimeObservation": dict(schema="nexgenvideo/bpy-runtime-observation/1"),
        **states, **dict.fromkeys(flags, True),
    }


def jq(program, value, *arguments):
    executable = shutil.which("jq")
    assert executable, "jq is required by the workflow and its tests"
    return subprocess.run([executable, "-e", *arguments, program], input=json.dumps(value), text=True,
                          capture_output=True, timeout=10).returncode == 0


def native_accepts(result):
    return jq(native_filter(), result, "--arg", "app", APP, "--arg", "foreign", FOREIGN)


def persisted_accepts(record):
    return jq(persisted_filter(), record)


def stage_record(stage, result):
    return dict(schema="nexgenvideo/bpy-stage-evidence/1", scope="storage-isolation", stage=stage, hostPID=HOST,
                sourceSHA=SOURCE, value={key: copy.deepcopy(result[key]) for key in stage_evidence.STAGES[stage]})


def swift_run_body():
    text = SELFTEST.read_text()
    return text.split("    private static func run(output: URL, scope: String? = nil) async throws -> [String: Any] {\n", 1)[1] \
        .split("\n    private static func verifyPhysicalStorage(", 1)[0]


class StorageIsolationWorkflowTests(unittest.TestCase):
    def test_complete_storage_isolation_result_passes_every_kept_predicate(self):
        self.assertTrue(native_accepts(complete_result()))

    def test_kept_predicates_are_the_unchanged_original_minus_only_production_spatial(self):
        source = native_filter()
        self.assertEqual(source.count(SCOPE_LINES), 1)
        self.assertTrue(source.startswith('            .schema == "nexgenvideo/bpy-runtime-acceptance/2"\n' + SCOPE_LINES))
        kept = source.replace(SCOPE_LINES, "")
        self.assertEqual(hashlib.sha256(kept.encode()).hexdigest(), KEPT_PREDICATES_SHA256)
        self.assertNotIn("productionSpatial.", source)
        core = STORAGE_PREDICATE.lstrip()
        self.assertEqual(kept.count("            and " + core + "\n"), 1)
        self.assertEqual(persisted_filter().count("            | " + core + ")\n"), 1)

    def test_scope_is_explicit_in_launch_marker_and_result(self):
        text = step("Run real bpy acceptance without ambient Blender or Python")
        self.assertEqual(text.count("NGV_SELFTEST_BPY_SCOPE=storage-isolation \\\n"), 1)
        self.assertIn('grep -q SELFTEST_BPY_STORAGE_ISOLATION_OK "$EVIDENCE/runtime.log"', text)
        self.assertNotIn("grep -q SELFTEST_BPY_OK", text)
        self.assertIn('python3 scripts/bpy_worker_evidence.py "$EVIDENCE" --scope storage-isolation\n', text)
        self.assertIn('python3 scripts/bpy_stage_evidence.py "$EVIDENCE" --scope storage-isolation --source-sha "$EXPECTED_SOURCE"\n', text)
        for kept in ("scripts/spatial_evaluated_geometry_evidence.py", "scripts/bpy_protocol_evidence.py"):
            self.assertIn(kept, text)
        for dropped in ("production_spatial_ui_evidence.py", "retained_spatial_evidence.py", "production-spatial"):
            self.assertNotIn(dropped, text)
        result = complete_result()
        for change in ({"scope": None}, {"scope": "scene-history"}, {"productionSpatial": {}}):
            with self.subTest(change=change):
                changed = {**result, **change}
                if change.get("scope", "") is None:
                    changed.pop("scope")
                self.assertFalse(native_accepts(changed))

    def test_missing_or_weakened_storage_case_turns_red_in_both_evaluations(self):
        result = complete_result()
        record = stage_record("physical-storage", result)
        self.assertTrue(persisted_accepts(record))
        mutations = [("missing " + mode, lambda cases, mode=mode: [item for item in cases if item["mode"] != mode])
                     for mode in ("fileport", "memory-entry", "scm-rights")]
        mutations += [
            ("memory-entry EPERM", lambda cases: [dict(item, retentionDeniedErrno=1) if item["mode"] == "memory-entry" else item for item in cases]),
            ("memory-entry EACCES", lambda cases: [dict(item, retentionDeniedErrno=13) if item["mode"] == "memory-entry" else item for item in cases]),
            ("fileport foreign errno", lambda cases: [dict(item, retentionDeniedErrno=2) if item["mode"] == "fileport" else item for item in cases]),
            ("duplicate case", lambda cases: cases[:2] + [dict(cases[1])]),
            ("oversized volume", lambda cases: [dict(item, capacityBytes=67108865) for item in cases]),
            ("overfilled volume", lambda cases: [dict(item, filledBytes=item["capacityBytes"] + 1) for item in cases]),
            ("smaller retention", lambda cases: [dict(item, retainedBytes=4194303) for item in cases]),
            ("no ENOSPC", lambda cases: [dict(item, storageErrno=0) for item in cases]),
        ]
        for label, mutate in mutations:
            with self.subTest(label):
                changed = {**result, "physicalStorage": mutate(copy.deepcopy(result["physicalStorage"]))}
                self.assertFalse(native_accepts(changed))
                self.assertFalse(persisted_accepts({**record, "value": {"physicalStorage": changed["physicalStorage"]}}))
        allowed = {**result, "physicalStorage": [dict(item, retentionDeniedErrno=13) if item["mode"] != "memory-entry"
                                                 else item for item in result["physicalStorage"]]}
        self.assertTrue(native_accepts(allowed))
        for change in ({"stage": "spatial-authoring"}, {"scope": "scene-history"}, {"schema": "other"}):
            with self.subTest(record=change):
                self.assertFalse(persisted_accepts({**record, **change}))

    def test_every_checked_kept_section_is_required(self):
        result = complete_result()
        checked = set(re.findall(r"(?<![\w\]])\.([A-Za-z]\w*)", native_filter())) & set(result)
        self.assertTrue({"physicalStorage", "storageRecovery", "reapedRecovery", "memoryPolicy", "trustedVerification",
                         "spatialAuthoring", "slotReusedAfterClose", "threeRealDocuments"} <= checked)
        for key in sorted(checked - {"scope"}):
            with self.subTest(key=key):
                self.assertFalse(native_accepts({name: value for name, value in result.items() if name != key}))

    def test_unchanged_boundary_deletion_and_host_crash_steps(self):
        workflow = WORKFLOW.read_text()
        for name, digest in UNCHANGED_STEPS.items():
            with self.subTest(step=name):
                self.assertEqual(hashlib.sha256(step(name).encode()).hexdigest(), digest)
        names = re.findall(r"^      - name: (.+)$", workflow, re.M)
        order = ["Prove deterministic deletion during native directory accounting",
                 "Prove pre-lease and post-exec host-crash cleanup",
                 "Run real bpy acceptance without ambient Blender or Python",
                 "Evaluate the physical storage proof persisted by the native run",
                 "Prove both sandbox boundary slots using an explicitly derived fixture"]
        self.assertEqual([name for name in names if name in order], order)
        self.assertEqual(step("Evaluate the physical storage proof persisted by the native run").split("\n", 1)[0],
                         step("Prove both sandbox boundary slots using an explicitly derived fixture").split("\n", 1)[0])


class StageEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.result = complete_result()
        self.write()

    def write(self):
        stages = self.directory / "stages"
        stages.mkdir(exist_ok=True)
        (self.directory / "result.json").write_text(json.dumps(self.result))
        (self.directory / "process-result.json").write_text(json.dumps(dict(pid=HOST, returncode=0)))
        for stage in stage_evidence.STAGES:
            (stages / (stage + ".json")).write_text(json.dumps(stage_record(stage, self.result)))
        for item in self.result["physicalStorage"]:
            (stages / f"physical-storage-{item['mode']}-proof.json").write_text(json.dumps(item))
            (stages / f"physical-storage-{item['mode']}-response.json").write_text(
                json.dumps(dict(ok=True, state="awaitingConfirmation", jobID="00000000-0000-0000-0000-000000000001")))

    def check(self):
        return stage_evidence.validate(self.directory, "storage-isolation", SOURCE)

    def test_complete_stages_bind_to_the_final_result(self):
        self.assertEqual(self.check()["stages"], list(stage_evidence.STAGES))

    def test_missing_kept_section_or_stage_turns_red(self):
        for key in sorted(set().union(*stage_evidence.STAGES.values())):
            with self.subTest(section=key):
                (self.directory / "result.json").write_text(json.dumps({k: v for k, v in self.result.items() if k != key}))
                with self.assertRaises((ValueError, KeyError)):
                    self.check()
        self.write()
        for stage in stage_evidence.STAGES:
            with self.subTest(stage=stage):
                path = self.directory / "stages" / (stage + ".json")
                original = path.read_bytes()
                path.unlink()
                with self.assertRaisesRegex(ValueError, "stage"):
                    self.check()
                path.write_bytes(original)

    def test_stage_bytes_identity_and_scope_are_bound(self):
        stages = self.directory / "stages"
        for label, mutate in (
                ("value", lambda record: record["value"].__setitem__(next(iter(record["value"])), "changed")),
                ("extra section", lambda record: record["value"].__setitem__("productionSpatial", {})),
                ("host", lambda record: record.__setitem__("hostPID", HOST + 1)),
                ("source", lambda record: record.__setitem__("sourceSHA", "b" * 40)),
                ("scope", lambda record: record.__setitem__("scope", "scene-history")),
                ("schema", lambda record: record.__setitem__("schema", "other"))):
            for stage in ("physical-storage", "two-slot-lifecycle", "storage-recovery"):
                with self.subTest(label=label, stage=stage):
                    self.write()
                    record = json.loads((stages / (stage + ".json")).read_text())
                    mutate(record)
                    (stages / (stage + ".json")).write_text(json.dumps(record))
                    with self.assertRaises(ValueError):
                        self.check()
        for change in ({"scope": "scene-history"}, {"productionSpatial": {}}):
            with self.subTest(result=change):
                self.result = {**complete_result(), **change}
                self.write()
                with self.assertRaises(ValueError):
                    self.check()
        self.result = complete_result()
        self.write()
        (stages / "unexpected.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "persisted stage files"):
            self.check()

    def test_raw_storage_attempts_match_the_accepted_cases(self):
        stages = self.directory / "stages"
        for mode in ("fileport", "memory-entry", "scm-rights"):
            for kind, change in (("proof", {"retentionDeniedErrno": 1}), ("response", {"state": "failed"})):
                with self.subTest(mode=mode, kind=kind):
                    self.write()
                    path = stages / f"physical-storage-{mode}-{kind}.json"
                    path.write_text(json.dumps({**json.loads(path.read_text()), **change}))
                    with self.assertRaisesRegex(ValueError, "raw storage"):
                        self.check()
                    self.write()
                    path.unlink()
                    with self.assertRaises(ValueError):
                        self.check()


class StorageIsolationSelfTestSourceTests(unittest.TestCase):
    def test_scope_dispatch_and_marker_are_explicit(self):
        text = SELFTEST.read_text()
        self.assertIn('                case "storage-isolation":\n'
                      '                    pendingResult = try await run(output: output, scope: "storage-isolation")\n', text)
        self.assertIn('            case "storage-isolation": "SELFTEST_BPY_STORAGE_ISOLATION_OK\\n"\n', text)

    def test_scope_skips_only_the_production_spatial_ui_stage(self):
        body = swift_run_body()
        scoped = [line.strip() for line in body.splitlines() if re.search(r'(?<![-"\w])scope(?![-"\w])', line)]
        self.assertEqual(scoped, [
            "guard let scope else { return }",
            '"schema": "nexgenvideo/bpy-stage-evidence/1", "scope": scope, "stage": stage, "hostPID": getpid(),',
            "let physicalStorage = try verifyPhysicalStorage(serviceName: originalSlot, attempts: scope == nil ? nil : stages)",
            "if scope == nil {",
            'if let scope { acceptance["scope"] = scope }',
        ])
        self.assertIn("        if scope == nil {\n"
                      "            productionSpatial = try await ProductionSpatialAcceptance.run(output: output)\n"
                      "        }\n", body)
        for dropped in ("ProductionVisualSourcesDriver", "ProductionSceneUIAcceptance", "ProductionSpatialHistoryAcceptance",
                        "ProductionVisualSourcesAcceptance", "ProductionSpatialClayAcceptance"):
            self.assertNotIn(dropped, body)
        kept = ["BpyRuntimeHost.shared.session(for: projectC) == nil", "sessionA.nativeProtocolProbe(",
                "native-cross-document-denial.json", "BpyMemoryRuntimeAcceptance.run(", "parentDeathWorker",
                "verifyPhysicalStorage(", "SpatialSceneRuntimeAcceptance.run(", "containerScopeSource",
                "nativeStorageOwnershipSnapshot()", "BpyMemoryRuntimeAcceptance.unavailableSensor(",
                "BpyReapedRecoveryAcceptance.run(", "BpyStorageRecoveryAcceptance.run(", "waitUntilRunning(sessionB"]
        positions = [body.index(marker) for marker in kept]
        self.assertEqual(positions, sorted(positions))

    def test_persisted_stages_match_the_verifier_and_cover_every_result_section(self):
        body = swift_run_body()
        persisted = [(match[1], set(re.findall(r'"([A-Za-z0-9]+)":', match[2])))
                     for match in re.finditer(r'try persist\("([a-z-]+)", \[(.*?)\]\)\n', body, re.S)]
        self.assertEqual([name for name, _ in persisted], list(stage_evidence.STAGES))
        self.assertEqual(dict(persisted), stage_evidence.STAGES)
        final = body.split("        var acceptance: [String: Any] = [\n", 1)[1].split("\n        ]\n", 1)[0]
        keys = set(re.findall(r'^\s*"([A-Za-z0-9]+)":', final, re.M))
        terminal = {"scope", "operationShutdown", "appDelegateShutdown", "hostPeakMemoryBytes", "runtimeObservation"}
        self.assertEqual(keys | terminal, stage_evidence.TERMINAL | set().union(*stage_evidence.STAGES.values()))
        storage = body.index('try persist("physical-storage"')
        self.assertLess(body.index("let physicalStorage = try verifyPhysicalStorage("), storage)
        self.assertLess(storage, body.index("SpatialSceneRuntimeAcceptance.run("))

    def test_physical_storage_proof_method_is_unchanged(self):
        text = SELFTEST.read_text()
        verify = text.split("    private static func verifyPhysicalStorage(serviceName: String, attempts: URL? = nil)", 1)[1] \
            .split("\n    private static func waitUntilReleased(", 1)[0]
        self.assertEqual(verify.count(STORAGE_GUARD), 1)
        self.assertIn('for mode in ["fileport", "memory-entry", "scm-rights"] {', verify)
        self.assertIn("limits: .init(inputBytes: 16 * 1_024 * 1_024, outputBytes: 8 * 1_024 * 1_024,\n"
                      "                          diskBytes: 64 * 1_024 * 1_024), serviceName: serviceName", verify)
        self.assertLess(verify.index("if let attempts {"), verify.index(STORAGE_GUARD))


if __name__ == "__main__":
    unittest.main()
