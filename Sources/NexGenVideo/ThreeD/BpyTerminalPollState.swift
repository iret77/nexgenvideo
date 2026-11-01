import BpyRuntimeProtocol
import Foundation

nonisolated struct BpyTerminalPollState {
    private(set) var finalRead = false
    private var started: TimeInterval?

    mutating func begin(at now: TimeInterval, deadline: TimeInterval) throws {
        guard now.isFinite, deadline.isFinite, started == nil, !finalRead else { throw BpyRuntimeError.timedOut }
        started = now
        if now >= deadline { finalRead = true }
    }

    mutating func end(at now: TimeInterval, deadline: TimeInterval, terminal: Bool) throws {
        guard let started, now.isFinite, now >= started, deadline.isFinite else { throw BpyRuntimeError.timedOut }
        self.started = nil
        if now >= deadline { finalRead = true }
        if finalRead && !terminal { throw BpyRuntimeError.timedOut }
    }

    static func timelyCommit(first: TimeInterval, timeout: TimeInterval, commit: TimeInterval) -> Bool {
        first.isFinite && timeout.isFinite && commit.isFinite && first >= 0 && timeout > 0
            && commit >= first && commit <= first + timeout + 15
    }

    static func settle(_ response: BpyServiceResponse, receipt: BpyMemoryCoordinator.PermitReceipt,
                       timeout: TimeInterval) throws -> BpyServiceResponse {
        var response = response
        if let failure = receipt.failure { throw failure }
        if receipt.firstRelease == nil, let stop = receipt.stop {
            switch stop {
            case .pressure: throw BpyAdmissionFailure.pressure
            case .monitorUnavailable: throw BpyAdmissionFailure.sensorUnavailable
            case .monitorUnresponsive: throw BpyAdmissionFailure.sensorUnresponsive
            case .launchFailed where !receipt.cleanupComplete: throw BpyAdmissionFailure.launchFailed
            case .transportLost: throw BpyAdmissionFailure.transportLost
            case .deadline: throw BpyAdmissionFailure.timedOut
            case .closed: throw BpyAdmissionFailure.closed
            case .cancelled: throw BpyAdmissionFailure.cancelled
            case .cleanupFailed: throw BpyAdmissionFailure.cleanupFailed
            default: break
            }
        }
        if [.awaitingConfirmation, .confirmed].contains(response.state) {
            guard receipt.stop == nil, let first = receipt.firstRelease, let commit = receipt.terminalCommit,
                  response.firstRelease == first, response.runningDeadline == first + timeout,
                  response.terminalCommit == commit, BpyTerminalPollState.timelyCommit(first: first, timeout: timeout, commit: commit) else {
                throw BpyRuntimeError.invalidOutput("The 3D result has no timely host completion receipt.")
            }
        } else if let reason = receipt.stop {
            response.outputs = []
            switch reason {
            case .deadline:
                response.state = .timedOut; response.message = "The 3D job exceeded its execution deadline."
            case .pressure:
                response.state = .resourceLimited; response.message = "macOS reported critical memory pressure. Retry the 3D job when memory is available."
            case .disk:
                response.state = .resourceLimited; response.message = "The 3D job exceeded its temporary storage limit. Reduce its output before retrying."
            case .fileCount:
                response.state = .resourceLimited; response.message = "The 3D job created too many temporary files. Reduce its output before retrying."
            case .processCount:
                response.state = .resourceLimited; response.message = "The 3D job started an unauthorized process. Remove the process launch before retrying."
            case .closed, .cancelled:
                response.state = .cancelled; response.message = "The 3D job was cancelled."
            case .executionFailed:
                if ![.crashed, .failed, .rejected].contains(response.state) {
                    response.state = .failed; response.message = "The 3D job failed. Check its diagnostics before retrying."
                }
            case .launchFailed, .ownershipViolation, .orphanedWorker, .observationFailed, .transportLost, .monitorUnavailable, .monitorUnresponsive, .serviceStall:
                response.state = .failed; response.message = BpyExecutionInterruption(reason: reason).localizedDescription
            default:
                response.state = .failed; response.message = "The 3D runtime could not be monitored safely. Retry after cleanup finishes."
            }
        }
        return response
    }
}
