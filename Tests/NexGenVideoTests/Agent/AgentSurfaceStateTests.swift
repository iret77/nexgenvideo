import Testing
@testable import NexGenVideo

@Suite("Agent surface state")
struct AgentSurfaceStateTests {
    @Test func dockHasExactlyOneOwner() {
        #expect(AgentSurfaceState.resolve(.init()).dockOwner == .composer)
        #expect(AgentSurfaceState.resolve(.init()).statusOwner == .ready)
        #expect(AgentSurfaceState.resolve(.init(hasDialog: true)).dockOwner == .dialog)
        #expect(AgentSurfaceState.resolve(.init(
            hasGateApproval: true,
            hasDialog: true
        )).dockOwner == .gateApproval)
        #expect(AgentSurfaceState.resolve(.init(
            hasSpendApproval: true,
            hasGateApproval: true,
            hasDialog: true
        )).dockOwner == .spendApproval)
        #expect(AgentSurfaceState.resolve(.init(
            needsBackendRecovery: true
        )).dockOwner == .backendRecovery)
    }

    @Test func decisionsRetainOneCompactStatusOwner() {
        #expect(AgentSurfaceState.resolve(.init(
            hasDialog: true
        )).statusOwner == .actionRequired)
        #expect(AgentSurfaceState.resolve(.init(
            hasGateApproval: true,
            hasTurnFailure: true
        )).statusOwner == .actionRequired)
    }

    @Test func transcriptActivityKeepsTheLandmarkWithoutADuplicateSpinner() {
        let phase = AgentSurfaceState.resolve(.init(
            phaseIsRunning: true,
            phaseHasTranscriptActivity: true
        ))
        #expect(phase.statusOwner == .phaseRun)
        #expect(phase.statusHasTranscriptActivity)

        let stream = AgentSurfaceState.resolve(.init(
            isStreaming: true,
            streamHasTranscriptActivity: true
        ))
        #expect(stream.statusOwner == .stream)
        #expect(stream.statusHasTranscriptActivity)
    }

    @Test func everyCoexistingStateUsesOneDeterministicPrecedenceChain() {
        #expect(AgentSurfaceState.resolve(.init(
            hasSpendRun: true,
            phaseIsRunning: true,
            phaseHasFailed: true,
            hasHostFollowUp: true,
            isStreaming: true,
            hasTurnFailure: true,
            isCheckingBackend: true,
            needsBackendRecovery: true
        )).statusOwner == .spendRun)
        #expect(AgentSurfaceState.resolve(.init(
            hasDialog: true,
            phaseIsRunning: true,
            phaseHasFailed: true,
            hasHostFollowUp: true,
            isStreaming: true,
            hasTurnFailure: true,
            isCheckingBackend: true,
            needsBackendRecovery: true
        )).statusOwner == .phaseRun)
        #expect(AgentSurfaceState.resolve(.init(
            hasDialog: true,
            phaseHasFailed: true,
            hasHostFollowUp: true,
            isStreaming: true,
            hasTurnFailure: true,
            isCheckingBackend: true,
            needsBackendRecovery: true
        )).statusOwner == .phaseFailure)
        #expect(AgentSurfaceState.resolve(.init(
            hasDialog: true,
            hasHostFollowUp: true,
            isStreaming: true,
            hasTurnFailure: true,
            isCheckingBackend: true,
            needsBackendRecovery: true
        )).statusOwner == .actionRequired)
        #expect(AgentSurfaceState.resolve(.init(
            hasHostFollowUp: true,
            isStreaming: true,
            hasTurnFailure: true,
            isCheckingBackend: true,
            needsBackendRecovery: true
        )).statusOwner == .stream)
        #expect(AgentSurfaceState.resolve(.init(
            hasHostFollowUp: true,
            hasTurnFailure: true,
            isCheckingBackend: true,
            needsBackendRecovery: true
        )).statusOwner == .turnFailure)
        #expect(AgentSurfaceState.resolve(.init(
            hasHostFollowUp: true,
            isCheckingBackend: true,
            needsBackendRecovery: true
        )).statusOwner == .hostFollowUp)
        #expect(AgentSurfaceState.resolve(.init(
            isCheckingBackend: true,
            needsBackendRecovery: true
        )).statusOwner == .backendChecking)
        #expect(AgentSurfaceState.resolve(.init(
            needsBackendRecovery: true
        )).statusOwner == .backendUnavailable)
    }
}
