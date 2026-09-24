import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BpyRuntimeWorkflowTests(unittest.TestCase):
    def test_acceptance_is_manual_and_uses_existing_runner_split(self):
        text = (ROOT / ".github/workflows/bpy-runtime-acceptance.yml").read_text()
        trigger = text.split("permissions:", 1)[0]
        self.assertIn("workflow_dispatch:", trigger)
        self.assertNotIn("pull_request:", trigger)
        self.assertNotIn("push:", trigger)
        self.assertIn("runs-on: xcode-27", text)
        self.assertIn("runs-on: macos-26", text)
        self.assertIn("scripts/stage_bpy_runtime.sh", text)
        self.assertIn("verify_bpy_runtime.py --distribution", text)
        self.assertIn("scripts/bundle.sh release --sign", text)
        self.assertIn("scripts/notarize.sh", text)
        self.assertIn("NGV_SELFTEST_BPY", text)
        self.assertIn(".failedOpenReleased == true", text)
        self.assertIn(".closeBeforeOpenReleased == true", text)
        self.assertIn(".changedDuplicateRejected == true", text)
        self.assertIn(".serviceRecoveryRevision == \"revision-e\"", text)
        self.assertIn(".parentDeathJobFailedClosed == true", text)
        self.assertIn(".rlimitASAllocationDenied == true", text)
        self.assertIn('.outOfMemoryState == "resourceLimited"', text)
        self.assertIn('.structuralLimitState == "resourceLimited"', text)
        self.assertIn('.storageLimitState == "resourceLimited"', text)
        self.assertIn('.aggregateByteLimitState == "resourceLimited"', text)
        self.assertIn('.resourceScanErrorState == "crashed"', text)
        self.assertIn(".supervisorSignalDenied == true", text)
        self.assertIn(".supervisorSignalRecovered == true", text)
        self.assertIn('.supervisorIdentityWriteFailureState == "failed"', text)
        self.assertIn('.supervisorIdentityCaptureFailureState == "failed"', text)
        self.assertIn('.trustedVerification.blenderBuildHash == "d13f752e3b9c"', text)
        self.assertIn(".trustedVerification.libraryVersions.openvdb.version", text)
        self.assertIn("NGV_SELFTEST_BPY_HOST_CRASH", text)
        self.assertIn("verify_bpy_source_closure.py", text)
        self.assertIn(".appDelegateShutdown == true", text)
        self.assertIn(".jobMetrics.worker_process_identifier != .jobMetrics.verifier_process_identifier", text)

    def test_release_fails_closed_on_distribution_review(self):
        release = (ROOT / ".github/workflows/release.yml").read_text()
        bundle = (ROOT / "scripts/bundle.sh").read_text()
        self.assertIn("verify_bpy_runtime.py --distribution", release)
        self.assertIn('if [ "$MODE" = "dist" ] || [ "$MODE" = "package" ]', bundle)
        self.assertIn('verify_bpy_runtime.py" --distribution', bundle)
        source_gate = release.index("verify_bpy_runtime.py --distribution")
        first_build = release.index("scripts/bundle.sh release")
        self.assertLess(source_gate, first_build)

    def test_public_ci_never_transfers_a_blocked_runtime(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("id: bpy_distribution", ci)
        self.assertIn("needs.source_gate.outputs.bpy_distribution_ready == 'true'", ci)
        for workflow in (
            "chat-hang-replay.yml",
            "private-example-analysis.yml",
            "recorded-hang-replay.yml",
        ):
            text = (ROOT / ".github/workflows" / workflow).read_text()
            self.assertIn("--without-bpy-runtime-for-ci-transfer", text)

    def test_worker_has_no_network_entitlement(self):
        for filename in (
            "NexGenVideoBpyService.entitlements",
            "PythonChild.entitlements",
        ):
            text = (ROOT / "Runtime/bpy" / filename).read_text()
            self.assertIn("com.apple.security.app-sandbox", text)
            self.assertNotIn("com.apple.security.network.client", text)
            self.assertNotIn("com.apple.security.files", text)

    def test_bundle_creates_two_distinct_xpc_containers(self):
        text = (ROOT / "scripts/bundle_bpy_runtime.sh").read_text()
        self.assertIn("for slot in 0 1", text)
        self.assertIn("bpy-service-$slot", text)

    def test_exact_wheel_entrypoint_and_inventory_are_locked(self):
        lock = (ROOT / "Runtime/bpy/runtime-lock.json").read_text()
        verifier = (ROOT / "scripts/verify_bpy_runtime.py").read_text()
        stage = (ROOT / "scripts/stage_bpy_runtime.sh").read_text()
        self.assertIn('\"entryPoint\": \"bpy/__init__.so\"', lock)
        self.assertNotIn('\"entryPoint\": \"bpy/__init__.py\"', lock)
        self.assertIn("len(native_libraries) != 43", verifier)
        self.assertIn("record_path", stage)

    def test_worker_results_are_host_owned(self):
        worker = (ROOT / "Runtime/bpy/worker.py").read_text()
        service = (ROOT / "Sources/NexGenVideoBpyService/main.swift").read_text()
        client = (ROOT / "Sources/NexGenVideo/ThreeD/BpyRuntimeClient.swift").read_text()
        self.assertNotIn('\"type\": \"result\"', worker)
        self.assertIn("os.closerange(3,", worker)
        self.assertIn("resource.setrlimit(resource.RLIMIT_NPROC, (0, 0))", worker)
        self.assertIn("except MemoryError:", worker)
        self.assertIn("raise SystemExit(71)", worker)
        self.assertIn('load_scene(bpy, config["scenePath"], False)', worker)
        self.assertIn('elif mode == "verify":', worker)
        self.assertIn("jobFingerprint", service)
        self.assertIn("resultExpired", service)
        self.assertIn("connection.interruptionHandler", service)
        self.assertIn("connection.invalidationHandler", service)
        self.assertIn("invalidateSessions", service)
        self.assertIn("activeProcessStartAbsoluteTime", client)
        self.assertIn("terminateLeasedProcess", client)
        self.assertIn("rotateFromConfirmedState", client)
        supervisor = (ROOT / "Sources/NexGenVideoBpySupervisor/main.swift").read_text()
        self.assertIn("(deny file-write*)", supervisor)
        self.assertIn("(deny signal)", supervisor)
        self.assertNotIn("(deny process-signal)", supervisor)
        self.assertIn("parentIsAlive", supervisor)
        self.assertIn("terminateAndReapOwnedChild", supervisor)
        self.assertIn("NGV_BPY_SUPERVISOR_FAIL_AFTER_CHILD_START", supervisor)
        self.assertIn("NGV_BPY_SUPERVISOR_FAIL_CHILD_IDENTITY_CAPTURE", supervisor)
        self.assertIn("NGV_BPY_SUPERVISOR_CHILD_IGNORE_TERM", supervisor)
        self.assertIn("waitForOwnedChildExit", supervisor)

    def test_source_candidate_workflow_is_manual_source_only_and_fail_closed(self):
        text = (ROOT / ".github/workflows/bpy-source-closure-candidate.yml").read_text()
        trigger = text.split("permissions:", 1)[0]
        self.assertIn("workflow_dispatch:", trigger)
        self.assertNotIn("pull_request:", trigger)
        self.assertNotIn("push:", trigger)
        self.assertIn("runs-on: ubuntu-24.04", text)
        self.assertIn("assemble_bpy_source_closure.py", text)
        self.assertIn("verify_bpy_source_closure.py", text)
        self.assertIn('classification: "candidate-only"', text)
        self.assertIn("publicDistributionAuthorized: false", text)
        self.assertNotIn("verify_bpy_runtime.py --distribution", text)
        self.assertNotIn("swift build", text)
        self.assertNotIn("stage_bpy_runtime", text)
        self.assertNotIn("secrets.", text)

    def test_registered_bundle_dispatch_selects_only_one_evidence_job(self):
        text = (ROOT / ".github/workflows/bundle.yml").read_text()
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("default: bundle", text)
        self.assertIn("bpy-source-closure-candidate", text)
        self.assertIn("bpy-binary-evidence-candidate", text)
        self.assertIn("if: inputs.evidence_mode == 'bundle'", text)
        self.assertIn("if: inputs.evidence_mode == 'bpy-source-closure-candidate'", text)
        self.assertIn("if: inputs.evidence_mode == 'bpy-binary-evidence-candidate'", text)
        self.assertIn("workflow_ref: ${{ github.ref }}", text)
        self.assertNotIn("pull_request:", text.split("permissions:", 1)[0])
        self.assertNotIn("push:", text.split("permissions:", 1)[0])

        for filename in (
            "bpy-source-closure-candidate.yml",
            "bpy-binary-evidence-candidate.yml",
        ):
            called = (ROOT / ".github/workflows" / filename).read_text()
            self.assertIn("workflow_call:", called)
            self.assertIn("CALLED_WORKFLOW_REF: ${{ job.workflow_ref }}", called)
            self.assertIn("CALLED_WORKFLOW_SHA: ${{ job.workflow_sha }}", called)
            self.assertIn('[ "$CALLED_WORKFLOW_SHA" = "$EXPECTED_SHA" ]', called)

    def test_binary_evidence_workflow_is_manual_non_distributable_and_build_free(self):
        text = (ROOT / ".github/workflows/bpy-binary-evidence-candidate.yml").read_text()
        collector = (ROOT / "scripts/collect_bpy_binary_evidence.py").read_text()
        verifier = (ROOT / "scripts/verify_bpy_binary_evidence.py").read_text()
        trigger = text.split("permissions:", 1)[0]
        self.assertIn("workflow_dispatch:", trigger)
        self.assertNotIn("pull_request:", trigger)
        self.assertNotIn("push:", trigger)
        self.assertIn("runs-on: macos-26", text)
        self.assertIn("collect_bpy_binary_evidence.py", text)
        self.assertIn("verify_bpy_binary_evidence.py", text)
        self.assertIn("publicDistributionAuthorized: false", text)
        self.assertNotIn("verify_bpy_runtime.py --distribution", text)
        self.assertNotIn("swift build", text)
        self.assertNotIn("bundle.sh", text)
        self.assertNotIn("secrets.", text)
        self.assertIn("bpy.app.build_hash", collector)
        self.assertIn("library.version", collector)
        self.assertIn("does not identify every native source archive", collector)
        self.assertIn('expected["buildHash"]', verifier)

    def test_ready_distribution_requires_repository_evidence(self):
        verifier = (ROOT / "scripts/verify_bpy_runtime.py").read_text()
        stage = (ROOT / "scripts/stage_bpy_runtime.sh").read_text()
        bundle_verifier = (ROOT / "scripts/verify_bpy_bundle.sh").read_text()
        self.assertIn("validate_distribution_closure", verifier)
        self.assertIn('lock.get("distributionClosure", {})', verifier)
        self.assertIn("distributionClosure.sourceArchives", stage)
        self.assertIn("distributionClosure.sourceArchives", bundle_verifier)


if __name__ == "__main__":
    unittest.main()
