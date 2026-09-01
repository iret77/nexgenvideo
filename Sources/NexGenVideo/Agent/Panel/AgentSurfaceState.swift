import Foundation

struct AgentSurfaceState: Equatable {
    enum DockOwner: Equatable {
        case spendApproval
        case gateApproval
        case dialog
        case composer
    }

    enum StatusOwner: Equatable {
        case spendRun
        case phaseRun
        case phaseFailure
        case hostFollowUp
        case stream
        case ready
        case none
    }

    struct Input: Equatable {
        var hasSpendApproval = false
        var hasGateApproval = false
        var hasDialog = false
        var hasSpendRun = false
        var phaseIsRunning = false
        var phaseHasTranscriptActivity = false
        var phaseHasFailed = false
        var hasHostFollowUp = false
        var isStreaming = false
        var streamHasTranscriptActivity = false
        var transcriptOwnsStatus = false
    }

    let dockOwner: DockOwner
    let statusOwner: StatusOwner

    static func resolve(_ input: Input) -> AgentSurfaceState {
        let dockOwner: DockOwner
        if input.hasSpendApproval {
            dockOwner = .spendApproval
        } else if input.hasGateApproval {
            dockOwner = .gateApproval
        } else if input.hasDialog {
            dockOwner = .dialog
        } else {
            dockOwner = .composer
        }

        let statusOwner: StatusOwner
        if input.hasSpendRun {
            statusOwner = .spendRun
        } else if input.phaseIsRunning {
            statusOwner = input.phaseHasTranscriptActivity ? .none : .phaseRun
        } else if input.phaseHasFailed {
            statusOwner = .phaseFailure
        } else if input.hasHostFollowUp {
            statusOwner = .hostFollowUp
        } else if input.isStreaming {
            statusOwner = input.streamHasTranscriptActivity ? .none : .stream
        } else if dockOwner == .composer, !input.transcriptOwnsStatus {
            statusOwner = .ready
        } else {
            statusOwner = .none
        }

        return AgentSurfaceState(dockOwner: dockOwner, statusOwner: statusOwner)
    }
}
