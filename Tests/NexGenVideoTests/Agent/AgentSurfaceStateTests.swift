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
    }

    @Test func decisionAndTranscriptNoticeSuppressRedundantStatus() {
        #expect(AgentSurfaceState.resolve(.init(
            hasDialog: true
        )).statusOwner == .none)
        #expect(AgentSurfaceState.resolve(.init(
            transcriptOwnsStatus: true
        )).statusOwner == .none)
    }

    @Test func transcriptActivitySuppressesDuplicateOperationStatus() {
        #expect(AgentSurfaceState.resolve(.init(
            phaseIsRunning: true,
            phaseHasTranscriptActivity: true
        )).statusOwner == .none)
        #expect(AgentSurfaceState.resolve(.init(
            isStreaming: true,
            streamHasTranscriptActivity: true
        )).statusOwner == .none)
    }

    @Test func oneStatusOwnerWinsByPrecedence() {
        #expect(AgentSurfaceState.resolve(.init(
            hasSpendRun: true,
            phaseIsRunning: true,
            phaseHasFailed: true,
            hasHostFollowUp: true,
            isStreaming: true
        )).statusOwner == .spendRun)
        #expect(AgentSurfaceState.resolve(.init(
            phaseHasFailed: true,
            hasHostFollowUp: true
        )).statusOwner == .phaseFailure)
    }
}
