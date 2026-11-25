import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest

import bpy_stage_evidence as stage_evidence

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
WORKFLOW = WORKFLOWS / "bpy-runtime-acceptance.yml"
SELFTEST = ROOT / "Sources/NexGenVideo/ThreeD/BpyRuntimeSelfTest.swift"
PRODUCTION = ROOT / "Sources/NexGenVideo/App/ProductionSpatialAcceptance.swift"
NATIVE = "Run real bpy acceptance without ambient Blender or Python"
PERSISTED = "Evaluate the physical storage proof persisted by the native run"
APP = "/runner/relocated/NexGenVideo.app"
FOREIGN = "/runner/denied/foreign-blender"
SOURCE = "a" * 40
HOST = 4242
SCOPE_GUARD = '''            and (if $scope == "" then (has("scope") | not) else .scope == $scope
              and (.productionSpatial | has("historyAdmission") or has("nativeStoryboardUI") or has("nativeBibleUI") | not) end)
'''
FULL_ONLY = '            and (if $scope != "" then true else true\n'
FULL_ONLY_END = '            end)\n'
ORIGINAL_FILTER_SHA256 = "247f0f63a0cfdb1447d83c865b1291858a7902139c18da3deda8d28f3f78ac31"
STORAGE_PREDICATE = '''([.physicalStorage[].mode] | sort) == ["fileport", "memory-entry", "scm-rights"]
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
UNCONDITIONAL_COMMANDS = (
    'python3 scripts/production_spatial_ui_evidence.py "$EVIDENCE" ${SCOPE:+--scope "$SCOPE"}',
    '"$RUNNER_TEMP/panorama-parser/bin/python" scripts/retained_spatial_evidence.py "$EVIDENCE"',
    'python3 scripts/spatial_evaluated_geometry_evidence.py "$EVIDENCE" --runtime-root '
    '"$APP/Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/Resources/BpyRuntime"',
    'python3 scripts/bpy_protocol_evidence.py "$EVIDENCE" --app "$APP"',
    'python3 scripts/bpy_worker_evidence.py "$EVIDENCE" ${SCOPE:+--scope "$SCOPE"}',
    'test -s "$EVIDENCE/perspective.png"',
    'for artifact in production-spatial-storyboard.png production-spatial-start.png \\',
    'test -s "$EVIDENCE/$artifact"',
    '''[ "$(sips -g pixelWidth "$EVIDENCE/perspective.png" | awk '/pixelWidth/{print $2}')" = 640 ]''',
    '''[ "$(sips -g pixelHeight "$EVIDENCE/perspective.png" | awk '/pixelHeight/{print $2}')" = 360 ]''',
    '''after="$(pgrep -f 'BpyRuntime/python' || true)"''',
    '''[ -z "$after" ] || { echo "orphan bpy workers: $after"; exit 1; }''',
    'grep -q "$MARKER" "$EVIDENCE/runtime.log"',
)


def step(name):
    return WORKFLOW.read_text().split(f"      - name: {name}\n", 1)[1].split("\n      - ", 1)[0]


def run_script(name):
    return textwrap.dedent(step(name).split("        run: |\n", 1)[1])


def native_filter():
    head = """jq -e --arg app "$APP" --arg foreign "$RUNNER_TEMP/denied/foreign-blender" --arg scope "$SCOPE" '\n"""
    return step(NATIVE).split(head, 1)[1].split("""          ' "$EVIDENCE/result.json"\n""", 1)[0]


def persisted_filter():
    return step(PERSISTED).split("jq -e '\n", 1)[1].split("""          ' "$RUNNER_TEMP/evidence/stages/physical-storage.json\"""", 1)[0]


def storage_cases():
    return [dict(mode=mode, capacityBytes=64 * 1024 * 1024, filledBytes=60 * 1024 * 1024, retainedBytes=4 * 1024 * 1024,
                 retentionDeniedErrno=0, storageErrno=28, fileSizeLimitBytes=8 * 1024 * 1024, pressureFileCount=8,
                 largestPressureFileBytes=8 * 1024 * 1024) for mode in ("fileport", "memory-entry", "scm-rights")]


def ui_rows(**flags):
    return [dict(scale=scale, viewport=[960, 640], screenshots=[f"s{index}.png" for index in range(10)],
                 interactions=[{}] * 21, **dict.fromkeys(flags["flags"], True)) for scale in (1, 1.25, 1.5)]


def production_spatial(scoped):
    value = dict.fromkeys(("nativeSceneAndCamera", "storyboardNativeDerivation", "completeShotState",
                           "fullShotClayAndDistinctEndpoints", "biblePreviewAndAssignment", "staleBibleRejected",
                           "changedBibleProofRejected", "savedProjectReopened"), True)
    value.update(promotion=dict.fromkeys(("nativeSpatialProofGraphAdmitted", "neutralSpatialRejectedAsAppearance",
                                          "neutralSpatialReferenceGeometryOnly"), True),
                 referencePurpose=dict.fromkeys(("nativeGeometryAccepted", "nativeAppearanceRejected",
                                                 "copiedAppearanceRejected", "copiedGeometryAccepted",
                                                 "duplicateViewAliasRejected"), True),
                 nativeClayUI=[dict(cancelDuringHash=True, closeDuringLoading=True)] * 3,
                 postCommitCancellation=dict(file="production-spatial-commit-cancel.json", sha256="1" * 64),
                 hashCancellation=dict(file="production-spatial-hash-cancel.json", sha256="2" * 64))
    if not scoped:
        value.update(historyAdmission={}, nativeStoryboardUI=ui_rows(flags=(
            "sourceFilePanel", "sourcePreviewAndAssignment", "changedTimeRevokesPreview", "sourcePreparedCancelUnchanged",
            "sourceStaleAssignmentUnchanged", "externalPreviewAndAssignment", "nativeImageInspection", "filePanelCancel",
            "preparedCancelUnchanged", "staleAssignmentUnchanged")),
            nativeBibleUI=ui_rows(flags=(
                "nativeSceneAndCameraSelection", "requiredPurpose", "realRenderedPreview", "nativeImageInspection",
                "exactPreviewAssigned", "preparedCancelUnchanged", "staleAssignmentUnchanged", "reloadAndAssign",
                "cancelDuringHash", "closeDuringLoading")))
    return value


def complete_result(scoped=True):
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
    result = {
        "schema": "nexgenvideo/bpy-runtime-acceptance/2", "python": "3.13.15", "bpy": "5.2.2",
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
        "productionSpatial": production_spatial(scoped),
        "storageRecovery": dict.fromkeys(recovery, True), "immutableCleanupFlagApplied": False,
        "immutableCleanupFlagDenied": True, "crashState": "crashed", "serviceRecoveryRevision": "revision-e",
        "supervisorIdentityWriteFailureState": "failed", "supervisorIdentityCaptureFailureState": "failed",
        "runtimeObservation": dict(schema="nexgenvideo/bpy-runtime-observation/1"),
        **states, **dict.fromkeys(flags, True),
    }
    if scoped:
        result["scope"] = "storage-isolation"
    return result


def jq(program, value, *arguments):
    executable = shutil.which("jq")
    assert executable, "jq is required by the workflow and its tests"
    return subprocess.run([executable, "-e", *arguments, program], input=json.dumps(value), text=True,
                          capture_output=True, timeout=10).returncode == 0


def native_accepts(result, scope="storage-isolation"):
    return jq(native_filter(), result, "--arg", "app", APP, "--arg", "foreign", FOREIGN, "--arg", "scope", scope)


def persisted_accepts(record):
    return jq(persisted_filter(), record)


def stage_record(stage, result):
    return dict(schema="nexgenvideo/bpy-stage-evidence/1", scope="storage-isolation", stage=stage, hostPID=HOST,
                sourceSHA=SOURCE, value={key: copy.deepcopy(result[key]) for key in stage_evidence.STAGES[stage]})


def write_stages(directory, result, complete=True):
    stages = directory / "stages"
    stages.mkdir(parents=True, exist_ok=True)
    (directory / "process.json").write_text(json.dumps(dict(pid=HOST, sourceSHA=SOURCE, mode="runtime")))
    if complete:
        (directory / "result.json").write_text(json.dumps(result))
        (directory / "process-result.json").write_text(json.dumps(dict(pid=HOST, returncode=0, sourceSHA=SOURCE)))
    for stage in stage_evidence.STAGES if complete else ("physical-storage",):
        (stages / (stage + ".json")).write_text(json.dumps(stage_record(stage, result)))
    for index, item in enumerate(result["physicalStorage"]):
        raw = json.dumps(item).encode()
        (stages / f"physical-storage-{item['mode']}-proof.json").write_bytes(raw)
        (stages / f"physical-storage-{item['mode']}-response.json").write_text(json.dumps(dict(
            ok=True, state="awaitingConfirmation", jobID=f"00000000-0000-0000-0000-00000000000{index}",
            outputs=[dict(name="storage-proof.json", byteCount=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
                          mediaType="application/json")])))


def unconditional_lines(script):
    lines, depth, outside = script.splitlines(), 0, []
    for line in lines:
        stripped = line.strip()
        if re.match(r"if \[ -[zn] \"\$SCOPE\" \]; then$", stripped):
            depth += 1
            continue
        if stripped == "fi" and depth:
            depth -= 1
            continue
        if not depth:
            outside.append(stripped)
    return outside


def guarded_blocks(text, condition):
    blocks = []
    for match in re.finditer(r"^( *)" + re.escape(condition) + r" \{\n", text, re.M):
        end = text.index("\n" + match[1] + "}\n", match.end() - 1)
        blocks.append(text[match.end():end])
    return blocks


class StorageIsolationWorkflowTests(unittest.TestCase):
    def test_full_and_scoped_results_pass_their_own_predicates_only(self):
        self.assertTrue(native_accepts(complete_result(scoped=True)))
        self.assertTrue(native_accepts(complete_result(scoped=False), scope=""))
        self.assertFalse(native_accepts(complete_result(scoped=True), scope=""))
        self.assertFalse(native_accepts(complete_result(scoped=False)))
        full = complete_result(scoped=False)
        for key in ("nativeStoryboardUI", "nativeBibleUI"):
            with self.subTest(full_run_without=key):
                changed = copy.deepcopy(full)
                changed["productionSpatial"][key][0]["staleAssignmentUnchanged"] = False
                self.assertFalse(native_accepts(changed, scope=""))
        for key, value in (("historyAdmission", {}), ("nativeStoryboardUI", []), ("nativeBibleUI", [])):
            with self.subTest(scoped_with=key):
                changed = complete_result()
                changed["productionSpatial"][key] = value
                self.assertFalse(native_accepts(changed))
        self.assertFalse(native_accepts({**complete_result(), "scope": "scene-history"}))
        self.assertFalse(native_accepts({key: value for key, value in complete_result().items() if key != "scope"}))

    def test_every_original_predicate_is_unchanged(self):
        source = native_filter()
        self.assertEqual((source.count(SCOPE_GUARD), source.count(FULL_ONLY), source.count(FULL_ONLY_END)), (1, 2, 2))
        self.assertTrue(source.startswith('            .schema == "nexgenvideo/bpy-runtime-acceptance/2"\n' + SCOPE_GUARD))
        original = source.replace(SCOPE_GUARD, "").replace(FULL_ONLY, "").replace(FULL_ONLY_END, "")
        self.assertEqual(hashlib.sha256(original.encode()).hexdigest(), ORIGINAL_FILTER_SHA256)
        full_only = [block.split(FULL_ONLY_END, 1)[0] for block in source.split(FULL_ONLY)[1:]]
        self.assertTrue(all(re.findall(r"\.productionSpatial\.(native(?:Storyboard|Bible)UI)\b", line)
                            for block in full_only for line in block.splitlines() if line.startswith("            and ")))
        self.assertEqual(sum(line.startswith("            and ") for block in full_only for line in block.splitlines()), 4)
        self.assertEqual(source.count("            and " + STORAGE_PREDICATE + "\n"), 1)
        self.assertEqual(persisted_filter().count("            | " + STORAGE_PREDICATE + ")\n"), 1)

    def test_scope_is_passed_only_by_the_diagnostic_ci_callers(self):
        workflow = WORKFLOW.read_text()
        self.assertIn("      selftest_scope:\n        type: string\n        default: ''\n", workflow)
        script = run_script(NATIVE)
        self.assertIn("          SCOPE: ${{ inputs.selftest_scope }}\n", step(NATIVE))
        self.assertIn("""case "$SCOPE" in
  '') MARKER=SELFTEST_BPY_OK ;;
  storage-isolation) MARKER=SELFTEST_BPY_STORAGE_ISOLATION_OK ;;
  *) echo "unknown bpy self-test scope: $SCOPE" >&2; exit 1 ;;
esac""", script)
        self.assertIn('  ${SCOPE:+"NGV_SELFTEST_BPY_SCOPE=$SCOPE"} \\\n', script)
        self.assertIn("inputs.selftest_scope == 'storage-isolation'", step(PERSISTED).split("\n", 1)[0])
        callers = {}
        for path in WORKFLOWS.glob("*.yml"):
            for job in re.split(r"\n  (?=[\w-]+:\n)", path.read_text()):
                if "uses: ./.github/workflows/bpy-runtime-acceptance.yml" in job:
                    callers[(path.name, job.split(":", 1)[0].strip())] = re.findall(r"selftest_scope: (.+)", job)
        self.assertEqual(callers.pop(("ci-batch.yml", "bpy-runtime-followup")), ["storage-isolation"])
        self.assertEqual(callers.pop(("ci.yml", "bpy-runtime")), ["storage-isolation"])
        self.assertEqual({name for name, _ in callers}, {"release.yml", "diagnostic-acceptance.yml"})
        self.assertTrue(all(scopes == [] for scopes in callers.values()), callers)

    def test_every_kept_runtime_and_media_check_runs_in_every_scope(self):
        outside = unconditional_lines(run_script(NATIVE))
        for command in UNCONDITIONAL_COMMANDS:
            with self.subTest(command=command):
                self.assertEqual(outside.count(command), 1)
        self.assertIn("production-spatial-end.png production-spatial-shot.mov \\", outside)
        self.assertIn("production-spatial-shot-proof.json production-spatial-bible.png; do", outside)
        script = run_script(NATIVE)
        scoped = script.split('if [ -n "$SCOPE" ]; then\n', 1)[1].split("\nfi\n", 1)[0]
        self.assertEqual(scoped.strip(), 'python3 scripts/bpy_stage_evidence.py "$EVIDENCE" --scope "$SCOPE" --source-sha "$EXPECTED_SOURCE"')
        full = script.split('if [ -z "$SCOPE" ]; then\n', 1)[1].split("\nfi\n", 1)[0]
        self.assertIn(".productionSpatial | (.nativeStoryboardUI + .nativeBibleUI)[]", full)

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
                full = {**complete_result(scoped=False), "physicalStorage": changed["physicalStorage"]}
                self.assertFalse(native_accepts(full, scope=""))
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
                         "spatialAuthoring", "productionSpatial", "slotReusedAfterClose", "threeRealDocuments"} <= checked)
        for key in sorted(checked):
            with self.subTest(key=key):
                self.assertFalse(native_accepts({name: value for name, value in result.items() if name != key}))
        for key in ("promotion", "referencePurpose", "staleBibleRejected", "changedBibleProofRejected",
                    "savedProjectReopened", "nativeClayUI"):
            with self.subTest(production=key):
                changed = copy.deepcopy(result)
                del changed["productionSpatial"][key]
                self.assertFalse(native_accepts(changed))

    def test_persisted_storage_step_binds_launch_source_and_raw_attempts(self):
        script = run_script(PERSISTED)
        self.assertIn('--source-sha "$EXPECTED_SOURCE" --physical-storage-only', script)
        self.assertIn("EXPECTED_SOURCE: ${{ inputs.expected_source_sha || github.sha }}", step(PERSISTED))

        def outcome(mutate=None):
            with tempfile.TemporaryDirectory() as temporary:
                evidence = Path(temporary) / "evidence"
                write_stages(evidence, complete_result(), complete=False)
                if mutate:
                    mutate(evidence)
                return subprocess.run(["bash", "-c", script], cwd=ROOT, capture_output=True, text=True, timeout=30,
                                      env={**os.environ, "RUNNER_TEMP": temporary, "EXPECTED_SOURCE": SOURCE}).returncode

        def edit(path, change):
            def apply(evidence):
                target = evidence / path
                value = json.loads(target.read_text())
                change(value)
                target.write_text(json.dumps(value))
            return apply

        self.assertEqual(outcome(), 0)
        cases = {
            "launched host": edit("process.json", lambda value: value.update(pid=HOST + 1)),
            "launched source": edit("process.json", lambda value: value.update(sourceSHA="b" * 40)),
            "stage host": edit("stages/physical-storage.json", lambda value: value.update(hostPID=HOST + 1)),
            "stage source": edit("stages/physical-storage.json", lambda value: value.update(sourceSHA="b" * 40)),
            "memory-entry weakened": edit("stages/physical-storage.json", lambda value: value["value"]["physicalStorage"][1].update(retentionDeniedErrno=1)),
            "raw proof": edit("stages/physical-storage-scm-rights-proof.json", lambda value: value.update(filledBytes=1)),
            "raw response state": edit("stages/physical-storage-fileport-response.json", lambda value: value.update(state="failed")),
            "raw response digest": edit("stages/physical-storage-memory-entry-response.json",
                                        lambda value: value["outputs"][0].update(sha256="0" * 64)),
            "reused job": edit("stages/physical-storage-scm-rights-response.json",
                               lambda value: value.update(jobID="00000000-0000-0000-0000-000000000000")),
            "missing raw proof": lambda evidence: (evidence / "stages/physical-storage-fileport-proof.json").unlink(),
            "missing launch": lambda evidence: (evidence / "process.json").unlink(),
        }
        for label, mutate in cases.items():
            with self.subTest(label):
                self.assertNotEqual(outcome(mutate), 0)

    def test_unchanged_boundary_deletion_and_host_crash_steps(self):
        workflow = WORKFLOW.read_text()
        for name, digest in UNCHANGED_STEPS.items():
            with self.subTest(step=name):
                self.assertEqual(hashlib.sha256(step(name).encode()).hexdigest(), digest)
        names = re.findall(r"^      - name: (.+)$", workflow, re.M)
        order = ["Prove deterministic deletion during native directory accounting",
                 "Prove pre-lease and post-exec host-crash cleanup", NATIVE, PERSISTED,
                 "Prove both sandbox boundary slots using an explicitly derived fixture"]
        self.assertEqual([name for name in names if name in order], order)


class ProductionSpatialUIScopeTests(unittest.TestCase):
    def test_scope_drops_only_the_bible_screen_case_and_must_match_the_result(self):
        import production_spatial_ui_evidence as ui
        self.assertEqual(ui.SCOPED_CASES, {"storage-isolation": tuple(case for case in ui.CASES if case != "nativeBibleUI")})
        for recorded, arguments in (("storage-isolation", []), (None, ["--scope", "storage-isolation"]),
                                    ("scene-history", ["--scope", "storage-isolation"])):
            with self.subTest(recorded=recorded, arguments=arguments), tempfile.TemporaryDirectory() as temporary:
                result = {"productionSpatial": {}}
                if recorded:
                    result["scope"] = recorded
                (Path(temporary) / "result.json").write_text(json.dumps(result))
                completed = subprocess.run(["python3", str(ROOT / "scripts/production_spatial_ui_evidence.py"), temporary,
                                            *arguments], capture_output=True, text=True, timeout=30)
                self.assertIn("another acceptance scope", completed.stderr)
                self.assertNotEqual(completed.returncode, 0)


class StageEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.result = complete_result()
        self.write()

    def write(self):
        write_stages(self.directory, self.result)

    def check(self):
        return stage_evidence.validate(self.directory, "storage-isolation", SOURCE)

    def test_complete_stages_bind_to_the_final_result(self):
        self.assertEqual(self.check()["stages"], list(stage_evidence.STAGES))
        self.assertEqual(len(stage_evidence.validate_physical_storage(self.directory, "storage-isolation", SOURCE)), 3)

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
                ("extra section", lambda record: record["value"].__setitem__("unexpected", {})),
                ("host", lambda record: record.__setitem__("hostPID", HOST + 1)),
                ("source", lambda record: record.__setitem__("sourceSHA", "b" * 40)),
                ("scope", lambda record: record.__setitem__("scope", "scene-history")),
                ("schema", lambda record: record.__setitem__("schema", "other"))):
            for stage in ("physical-storage", "two-slot-lifecycle", "production-spatial", "storage-recovery"):
                with self.subTest(label=label, stage=stage):
                    self.write()
                    record = json.loads((stages / (stage + ".json")).read_text())
                    mutate(record)
                    (stages / (stage + ".json")).write_text(json.dumps(record))
                    with self.assertRaises(ValueError):
                        self.check()
        for name, change in (("result.json", {"scope": "scene-history"}), ("result.json", {"unexpected": {}}),
                             ("process-result.json", {"pid": HOST + 1})):
            with self.subTest(file=name, change=change):
                self.write()
                path = self.directory / name
                path.write_text(json.dumps({**json.loads(path.read_text()), **change}))
                with self.assertRaises(ValueError):
                    self.check()
        self.write()
        (stages / "unexpected.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "persisted stage files"):
            self.check()

    def test_raw_storage_attempts_match_the_accepted_cases(self):
        stages = self.directory / "stages"
        for mode in ("fileport", "memory-entry", "scm-rights"):
            for kind, change in (("proof", {"retentionDeniedErrno": 1}), ("response", {"state": "failed"}),
                                 ("response", {"outputs": []})):
                with self.subTest(mode=mode, kind=kind, change=change):
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
    def run_body(self):
        return SELFTEST.read_text().split(
            "    private static func run(output: URL, scope: String? = nil) async throws -> [String: Any] {\n", 1)[1] \
            .split("\n    private static func verifyPhysicalStorage(", 1)[0]

    def test_scope_dispatch_and_marker_are_explicit(self):
        text = SELFTEST.read_text()
        self.assertIn('                case "storage-isolation":\n'
                      '                    pendingResult = try await run(output: output, scope: "storage-isolation")\n', text)
        self.assertIn('            case "storage-isolation": "SELFTEST_BPY_STORAGE_ISOLATION_OK\\n"\n', text)

    def test_scope_changes_no_self_test_stage(self):
        scoped = [line.strip() for line in self.run_body().splitlines() if re.search(r'(?<![-"\w])scope(?![-"\w])', line)]
        self.assertEqual(scoped, [
            "guard let scope else { return }",
            '"schema": "nexgenvideo/bpy-stage-evidence/1", "scope": scope, "stage": stage, "hostPID": getpid(),',
            "let physicalStorage = try verifyPhysicalStorage(serviceName: originalSlot, attempts: scope == nil ? nil : stages)",
            "let productionSpatial = try await ProductionSpatialAcceptance.run(output: output, storageIsolation: scope != nil)",
            'if let scope { acceptance["scope"] = scope }',
        ])
        body = self.run_body()
        kept = ["BpyRuntimeHost.shared.session(for: projectC) == nil", "sessionA.nativeProtocolProbe(",
                "native-cross-document-denial.json", "BpyMemoryRuntimeAcceptance.run(", "parentDeathWorker",
                "verifyPhysicalStorage(", "SpatialSceneRuntimeAcceptance.run(", "containerScopeSource",
                "nativeStorageOwnershipSnapshot()", "BpyMemoryRuntimeAcceptance.unavailableSensor(",
                "BpyReapedRecoveryAcceptance.run(", "ProductionSpatialAcceptance.run(", "BpyStorageRecoveryAcceptance.run(",
                "waitUntilRunning(sessionB"]
        positions = [body.index(marker) for marker in kept]
        self.assertEqual(positions, sorted(positions))

    def test_production_spatial_skips_only_the_three_ui_only_leaves(self):
        text = PRODUCTION.read_text()
        blocks = guarded_blocks(text, "if !storageIsolation")
        calls = sorted(call for block in blocks for call in re.findall(r"(Production\w+Acceptance\.\w+)\(", block))
        self.assertEqual(calls, ["ProductionSpatialHistoryAcceptance.run", "ProductionVisualSourcesAcceptance.bible",
                                 "ProductionVisualSourcesAcceptance.storyboard"])
        self.assertEqual(len(blocks), 4)
        self.assertEqual(blocks[-1].split(), ['evidence["nativeStoryboardUI"]', "=", "nativeStoryboardUI",
                                              'evidence["nativeBibleUI"]', "=", "nativeBibleUI",
                                              'evidence["historyAdmission"]', "=", "historyAdmission"])
        self.assertEqual(text.count("storageIsolation"), 5)
        unguarded = text
        for block in blocks:
            unguarded = unguarded.replace(block, "")
        for kept in ("ProductionSceneUIAcceptance.run(", "ProductionSpatialCommitCancellationAcceptance.run(",
                     "ProductionSpatialHashCancellationAcceptance.run(", "ProductionSpatialClayAcceptance.storyboard(",
                     "ProductionSpatialPoseAcceptance.run(", "ProductionRetainedSpatialAcceptance.blockout(context: context, shotID: shot.id, imported: false",
                     "ProductionSpatialClayAcceptance.run(", "ProductionRetainedSpatialAcceptance.blockout(context: context, shotID: shot.id, imported: true",
                     "ProductionRetainedSpatialAcceptance.panorama(", "PipelineSpatialDerivationWriter.prepareBibleView(",
                     "staleRejected", "changedProofRejected", "ProductionSpatialPromotionAcceptance.verify(",
                     "ProductionSpatialReferencePurposeAcceptance.verify(", "VideoProject.load(from: context.packageURL)",
                     "PipelineProductionAssetEvidence.requireBible(reopenedBible", "requireSpatialInputs(draft"):
            with self.subTest(kept=kept):
                self.assertIn(kept, unguarded)

    def test_persisted_stages_match_the_verifier_and_cover_every_result_section(self):
        body = self.run_body()
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
