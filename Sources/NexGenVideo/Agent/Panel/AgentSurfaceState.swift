import Foundation

struct AgentSurfaceState: Equatable {
    enum DockOwner: Equatable {
        case spendApproval
        case gateApproval
        case dialog
        case backendRecovery
        case composer
    }

    enum StatusOwner: Equatable {
        case spendRun
        case phaseRun
        case phaseFailure
        case actionRequired
        case hostFollowUp
        case stream
        case turnFailure
        case backendChecking
        case backendUnavailable
        case ready
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
        var hasTurnFailure = false
        var isCheckingBackend = false
        var needsBackendRecovery = false
    }

    let dockOwner: DockOwner
    let statusOwner: StatusOwner
    let statusHasTranscriptActivity: Bool

    static func resolve(_ input: Input) -> AgentSurfaceState {
        let dockOwner: DockOwner
        if input.hasSpendApproval {
            dockOwner = .spendApproval
        } else if input.hasGateApproval {
            dockOwner = .gateApproval
        } else if input.hasDialog {
            dockOwner = .dialog
        } else if input.needsBackendRecovery {
            dockOwner = .backendRecovery
        } else {
            dockOwner = .composer
        }

        let statusOwner: StatusOwner
        if input.hasSpendRun {
            statusOwner = .spendRun
        } else if input.phaseIsRunning {
            statusOwner = .phaseRun
        } else if input.phaseHasFailed {
            statusOwner = .phaseFailure
        } else if dockOwner == .spendApproval
                    || dockOwner == .gateApproval
                    || dockOwner == .dialog {
            statusOwner = .actionRequired
        } else if input.isStreaming {
            statusOwner = .stream
        } else if input.hasTurnFailure {
            statusOwner = .turnFailure
        } else if input.hasHostFollowUp {
            statusOwner = .hostFollowUp
        } else if input.isCheckingBackend {
            statusOwner = .backendChecking
        } else if input.needsBackendRecovery {
            statusOwner = .backendUnavailable
        } else {
            statusOwner = .ready
        }

        let statusHasTranscriptActivity = switch statusOwner {
        case .phaseRun: input.phaseHasTranscriptActivity
        case .stream: input.streamHasTranscriptActivity
        default: false
        }
        return AgentSurfaceState(
            dockOwner: dockOwner,
            statusOwner: statusOwner,
            statusHasTranscriptActivity: statusHasTranscriptActivity
        )
    }
}
