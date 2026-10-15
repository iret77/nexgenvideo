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

    @Test func decisionsReflectWhetherTheUserCanActuallyAct() {
        #expect(AgentSurfaceState.resolve(.init(hasGateApproval: true, isStreaming: true)).statusOwner == .actionRequired)
        #expect(AgentSurfaceState.resolve(.init(hasSpendApproval: true, phaseIsRunning: true, isStreaming: true)).statusOwner == .actionRequired)
        #expect(AgentSurfaceState.resolve(.init(hasGateApproval: true, gateApprovalBlocked: true,
            phaseIsRunning: true, isStreaming: true)).statusOwner == .phaseRun)
        #expect(AgentSurfaceState.resolve(.init(hasGateApproval: true, gateApprovalIsWriting: true)).statusOwner == .decisionWorking)
        #expect(AgentSurfaceState.resolve(.init(hasSpendApproval: true, spendApprovalIsRunning: true)).statusOwner == .decisionWorking)
        #expect(AgentSurfaceState.resolve(.init(hasSpendApproval: true, hasSpendRun: true)).statusOwner == .spendRun)
        #expect(AgentSurfaceState.resolve(.init(hasBatchRun: true)).statusOwner == .batchRun)
        #expect(AgentSurfaceState.resolve(.init(hasSpendRun: true, hasBatchRun: true)).statusOwner == .spendRun)
        #expect(AgentSurfaceState.resolve(.init(phaseHasFailed: true)).statusOwner == .phaseFailure)
        #expect(AgentSurfaceState.resolve(.init(isStreaming: true)).statusOwner == .stream)
        #expect(AgentSurfaceState.resolve(.init()).statusOwner == .ready)
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
        )).statusOwner == .actionRequired)
        #expect(AgentSurfaceState.resolve(.init(
            hasDialog: true,
            phaseHasFailed: true,
            hasHostFollowUp: true,
            isStreaming: true,
            hasTurnFailure: true,
            isCheckingBackend: true,
            needsBackendRecovery: true
        )).statusOwner == .actionRequired)
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

    @Test("a repair pause owns the dock and status until a decision card takes precedence")
    func repairPauseIsOneHostState() {
        let paused = AgentSurfaceState.resolve(.init(hasRepairPause: true))
        #expect(paused.dockOwner == .repairRecovery)
        #expect(paused.statusOwner == .repairPaused)
        let pausedWithOutdated = AgentSurfaceState.resolve(.init(hasRepairPause: true, hasOutdatedApproval: true))
        #expect(pausedWithOutdated.statusOwner == .repairPaused)
        let decision = AgentSurfaceState.resolve(.init(hasGateApproval: true, hasRepairPause: true))
        #expect(decision.dockOwner == .gateApproval)
        #expect(decision.statusOwner == .actionRequired)
    }

    @Test("an outdated approval is reported when no work or decision is active")
    func outdatedApprovalWhenIdle() {
        #expect(AgentSurfaceState.resolve(.init(hasOutdatedApproval: true)).statusOwner == .approvalOutdated)
        #expect(AgentSurfaceState.resolve(.init(hasOutdatedApproval: true)).dockOwner == .composer)
        #expect(AgentSurfaceState.resolve(.init(isStreaming: true, hasOutdatedApproval: true)).statusOwner == .stream)
        #expect(AgentSurfaceState.resolve(.init(hasBatchRun: true, hasOutdatedApproval: true)).statusOwner == .batchRun)
    }
}
