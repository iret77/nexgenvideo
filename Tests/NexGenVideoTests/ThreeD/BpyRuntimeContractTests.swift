import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Managed bpy runtime contract")
struct BpyRuntimeContractTests {
    @Test func workerSlotsHaveIndependentSandboxIdentities() {
        #expect(bpyRuntimeServiceNames.count == 2)
        #expect(Set(bpyRuntimeServiceNames).count == 2)
    }

    @Test func defaultLimitsAreBounded() {
        let limits = BpyRuntimeLimits()
        #expect(limits.isValid)
        #expect(limits.timeoutSeconds == 120)
        #expect(limits.outputBytes <= 512 * 1_024 * 1_024)
    }

    @Test func invalidLimitsFailClosed() {
        var limits = BpyRuntimeLimits()
        limits.timeoutSeconds = 0
        #expect(!limits.isValid)
        limits = BpyRuntimeLimits()
        limits.memoryBytes = 64 * 1_024 * 1_024
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
    }

    @Test func requestsRoundTripWithoutPaths() throws {
        let request = BpyRunJobRequest(
            sessionID: UUID(),
            jobID: UUID(),
            expectedRevision: "r1",
            source: "import bpy",
            inputNames: ["approved.blend"],
            timeoutSeconds: 10
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BpyRunJobRequest.self, from: data)
        #expect(decoded == request)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("projectURL"))
    }
}
