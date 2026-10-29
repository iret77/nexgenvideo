import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Managed bpy runtime contract")
struct BpyRuntimeContractTests {
    @Test func crashedStorageRequiresBootChangeDespitePIDReuse() throws {
        let boot = UUID()
        let operation = BpyStorageOperation(id: UUID(), bootSessionID: boot, pid: 22, start: 200,
                                           completed: false, ownerPID: 11, ownerStart: 100)
        #expect(throws: BpyStorageRecoveryError.restartRequired) {
            try BpyRuntimeVolume.requireStopped(operation, currentBoot: boot, processStart: { _ in nil })
        }
        #expect(throws: BpyStorageRecoveryError.pending) {
            try BpyRuntimeVolume.requireStopped(operation, currentBoot: boot, processStart: { $0 == 22 ? 200 : nil })
        }
        try BpyRuntimeVolume.requireStopped(operation, currentBoot: UUID(), processStart: { $0 == 22 ? 200 : 100 })
    }

    @Test func unstartedStorageIntentRequiresOwnerExitOrExplicitAbandonment() throws {
        let boot = UUID()
        let intent = BpyStorageOperation(id: UUID(), bootSessionID: boot, pid: 0, start: 0,
                                        completed: false, ownerPID: 11, ownerStart: 100)
        #expect(throws: BpyStorageRecoveryError.pending) {
            try BpyRuntimeVolume.requireStopped(intent, currentBoot: boot, processStart: { _ in 100 })
        }
        try BpyRuntimeVolume.requireStopped(intent, currentBoot: boot, processStart: { _ in nil })
        try BpyRuntimeVolume.requireStopped(intent, currentBoot: boot, processStart: { _ in 101 })
        let abandoned = BpyStorageOperation(id: intent.id, bootSessionID: boot, pid: 0, start: 0,
                                           completed: true, ownerPID: 11, ownerStart: 100)
        try BpyRuntimeVolume.requireStopped(abandoned, currentBoot: boot, processStart: { _ in 100 })
    }

    @Test func reservedStorageQuitNeedsEndedOwnershipAndProvenRestartRecovery() {
        #expect(BpyRuntimeSession.permitsReservedStorageQuit(closed: true, closing: false,
            cleanupComplete: false, requiresRestart: true, serviceReleased: true))
        #expect(!BpyRuntimeSession.permitsReservedStorageQuit(closed: true, closing: false,
            cleanupComplete: true, requiresRestart: true, serviceReleased: true))
        #expect(!BpyRuntimeSession.permitsReservedStorageQuit(closed: true, closing: false,
            cleanupComplete: false, requiresRestart: true, serviceReleased: false))
        #expect(!BpyRuntimeSession.permitsReservedStorageQuit(closed: true, closing: false,
            cleanupComplete: false, requiresRestart: false, serviceReleased: true))
        #expect(!BpyRuntimeSession.permitsReservedStorageQuit(closed: false, closing: true,
            cleanupComplete: false, requiresRestart: true, serviceReleased: true))
    }

    @Test func workerSlotsHaveIndependentSandboxIdentities() {
        #expect(bpyRuntimeServiceNames.count == 2)
        #expect(Set(bpyRuntimeServiceNames).count == 2)
    }

    @Test func defaultLimitsAreBounded() {
        let limits = BpyRuntimeLimits()
        #expect(limits.isValid)
        #expect(limits.timeoutSeconds == 120)
        #expect(limits.outputBytes <= 512 * 1_024 * 1_024)
        #expect(limits.diskBytes >= limits.outputBytes)
        #expect(limits.renderPixels <= limits.renderWidth * limits.renderHeight)
    }

    @Test func invalidLimitsFailClosed() {
        var limits = BpyRuntimeLimits()
        limits.timeoutSeconds = 0
        #expect(!limits.isValid)
        limits = BpyRuntimeLimits()
        limits.memoryBytes = 64 * 1_024 * 1_024
        #expect(!limits.isValid)
        limits = BpyRuntimeLimits()
        limits.diskBytes = limits.outputBytes - 1
        #expect(!limits.isValid)
    }

    @Test func inputCopyOnlyAcceptsSingleSafeName() throws {
        let root = URL(fileURLWithPath: "/tmp/approved", isDirectory: true)
        _ = try BpyApprovedInputCopy(approvedDirectory: root, filename: "scene.blend")
        #expect(throws: BpyRuntimeError.self) {
            _ = try BpyApprovedInputCopy(approvedDirectory: root, filename: "../scene.blend")
        }
        #expect(throws: BpyRuntimeError.self) {
            _ = try BpyApprovedInputCopy(approvedDirectory: root, filename: "folder/scene.blend")
        }
    }

    @Test func terminalStateSeparatesCandidateFromConfirmation() {
        #expect(!BpyRuntimeJobState.awaitingConfirmation.isTerminal)
        #expect(BpyRuntimeJobState.confirmed.isTerminal)
        #expect(BpyRuntimeJobState.crashed.isTerminal)
        #expect(BpyRuntimeJobState.timedOut.isTerminal)
        #expect(BpyRuntimeJobState.resourceLimited.isTerminal)
    }

    @Test func requestsRoundTripWithoutPaths() throws {
        let request = BpyRunJobRequest(
            sessionID: UUID(),
            jobID: UUID(),
            expectedRevision: "r1",
            source: "import bpy",
            inputNames: ["approved.blend"],
            timeoutSeconds: 10,
            fingerprint: String(repeating: "a", count: 64),
            diagnosticDeniedPaths: ["/denied/fixture"],
            diagnosticAutoexecPositiveControl: true
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BpyRunJobRequest.self, from: data)
        #expect(decoded == request)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("projectURL"))
    }

    @Test func serviceResponseRoundTripsTrustedProcessLease() throws {
        let jobID = UUID()
        let response = BpyServiceResponse(
            ok: true,
            jobID: jobID,
            state: .running,
            jobFingerprint: String(repeating: "b", count: 64),
            activeProcessIdentifier: 321,
            activeProcessStartAbsoluteTime: 654,
            activeProcessExecutable: "/Applications/NexGenVideo.app/Contents/Frameworks/Python.framework/Versions/3.13/bin/python3"
        )
        let decoded = try JSONDecoder().decode(
            BpyServiceResponse.self,
            from: JSONEncoder().encode(response)
        )
        #expect(decoded == response)
        #expect(decoded.jobID == jobID)
    }
}
