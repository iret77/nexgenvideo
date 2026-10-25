import Foundation
import NexGenEngine

enum WorkbenchActivityState: Equatable {
    case idle, working, needsAttention, failed

    static func agent(_ input: AgentSurfaceState.Input, batchPaused: Bool, batchError: Bool) -> Self {
        let surface = AgentSurfaceState.resolve(input)
        if hasUsableDecision(input) { return .needsAttention }
        switch surface.statusOwner {
        case .decisionWorking, .phaseRun, .stream, .backendChecking:
            return .working
        case .spendRun, .batchRun:
            return batchPaused ? .needsAttention : .working
        case .phaseFailure, .turnFailure:
            return .failed
        case .actionRequired, .repairPaused, .backendUnavailable, .approvalOutdated:
            return .needsAttention
        case .ready, .hostFollowUp:
            if batchPaused { return .needsAttention }
            return batchError ? .failed : .idle
        }
    }

    static func hasUsableDecision(_ input: AgentSurfaceState.Input) -> Bool {
        switch AgentSurfaceState.resolve(input).dockOwner {
        case .dialog: true
        case .spendApproval: !input.spendApprovalIsRunning
        case .gateApproval: !input.gateApprovalBlocked && !input.gateApprovalIsWriting
        default: false
        }
    }

    static func attentionDetail(_ input: AgentSurfaceState.Input, batchPaused: Bool, decisionLocation: String) -> String? {
        if hasUsableDecision(input) { return decisionLocation }
        if batchPaused { return String(localized: "Generation needs attention. Review Generation batches below.") }
        return nil
    }

    static func export(_ status: ExportJobStatus?) -> Self {
        switch status {
        case .pending, .preparing, .exporting, .cancelling: .working
        case .failed: .failed
        case .interrupted: .needsAttention
        case .completed, .cancelled, nil: .idle
        }
    }

    @MainActor
    static func agent(editor: EditorViewModel) -> Self {
        let batch = editor.generationBatchCoordinator
        let notices = batch.activityNotices(projectID: editor.projectId)
        return agent(.current(editor: editor), batchPaused: notices.contains { $0.needsAttention },
            batchError: batch.activityError != nil || notices.contains { $0.failed })
    }
}

extension AgentSurfaceState.Input {
    @MainActor
    static func current(editor: EditorViewModel, hasTranscriptActivity: Bool = false) -> Self {
        let service = editor.agentService
        let batch = editor.generationBatchCoordinator
        let root = editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        let snapshot = editor.activityPhaseSnapshot
        let phaseRunning = root.flatMap { editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: $0) } != nil
        let gateBlocked = service.pendingGateApproval.flatMap(\.dataRoot).map {
            editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: $0) != nil
        } ?? false
        let authenticationError: Bool
        if case .authenticationRequired? = service.streamError { authenticationError = true }
        else { authenticationError = false }
        return .init(
            hasSpendApproval: service.pendingSpendApproval != nil || batch.pending != nil,
            hasGateApproval: service.pendingGateApproval != nil,
            gateApprovalBlocked: gateBlocked,
            gateApprovalIsWriting: service.gateApprovalIsWriting,
            spendApprovalIsRunning: service.spendApprovalIsRunning || batch.approving || batch.isRecovering,
            hasDialog: service.pendingDialog != nil,
            hasSpendRun: service.currentSpendRun != nil,
            hasBatchRun: batch.activeBatchID != nil,
            phaseIsRunning: phaseRunning || snapshot?.isRunning == true,
            phaseHasTranscriptActivity: hasTranscriptActivity,
            phaseHasFailed: {
                if case .failed? = snapshot?.status { return true }
                return false
            }(),
            hasHostFollowUp: service.hasPendingHostFollowUp,
            isStreaming: service.isStreaming,
            streamHasTranscriptActivity: hasTranscriptActivity,
            hasTurnFailure: service.streamError != nil && !authenticationError,
            isCheckingBackend: service.isCheckingBackend,
            needsBackendRecovery: !service.isCheckingBackend && (!service.canStream || authenticationError),
            hasRepairPause: service.currentPipelineRepairFailure != nil,
            hasOutdatedApproval: editor.projectState?.phases.contains { $0.approved && !$0.approvalCurrent } == true
        )
    }
}

extension EditorViewModel {
    var activityPhaseSnapshot: PipelinePhaseExecutionSnapshot? {
        let root = workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }
        return pipelinePhaseExecution.snapshot.flatMap { snapshot in
            snapshot.projectRootPath == root?.standardizedFileURL.resolvingSymlinksInPath().path ? snapshot : nil
        }
    }
}
