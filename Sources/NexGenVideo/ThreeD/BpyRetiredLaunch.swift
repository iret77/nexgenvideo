import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

nonisolated final class BpyRetiredLaunch: @unchecked Sendable {
    private let lock = NSLock()
    private let specification: String
    let permit: UUID
    private let service: BpyObservedProcess
    private let supervisor: BpyObservedProcess
    private let authorized: Bool
    private let replay: BpyLaunchReplay
    private var snapshot: BpyMonitorResponse

    init(spec: BpyHostLaunchSpec, service: BpyObservedProcess, supervisor: BpyObservedProcess,
         authorized: Bool, replay: BpyLaunchReplay, response: BpyMonitorResponse) throws {
        guard response.status == .detached, response.outputComplete, response.stdout?.isEmpty != false,
              response.supervisor == nil, response.worker == nil, response.descendants.isEmpty else { throw POSIXError(.EBUSY) }
        specification = try Self.digest(spec)
        permit = spec.permit; self.service = service; self.supervisor = supervisor
        self.authorized = authorized; self.replay = replay; snapshot = response
    }

    func authorize(pid: Int32, start: UInt64) throws -> Bool {
        guard pid == supervisor.pid, start == supervisor.start else { throw POSIXError(.EPERM) }
        return authorized
    }

    var diagnosticSnapshot: BpyMonitorResponse { lock.withLock { snapshot } }

    func launch(_ request: BpyMonitorRequest, spec: BpyHostLaunchSpec, peer: BpyObservedProcess) throws -> BpyMonitorResponse {
        let original = lock.withLock { snapshot }
        guard request.operation == .launch, request.epoch == nil, request.sequence == 0,
              request.transport == original.transport, request.execution == original.execution,
              try Self.digest(spec) == specification, peer.pid == service.pid, peer.start == service.start,
              peer.executable == service.executable else { throw POSIXError(.EPERM) }
        return response(request, receipt: nil, status: .gone)
    }

    func inspect(_ request: BpyMonitorRequest, peer: BpyObservedProcess, memory: BpyMemoryCoordinator) throws -> BpyMonitorResponse {
        if let saved = try replay.begin(request, peer: peer) { return saved }
        let result: BpyMonitorResponse
        do {
            guard request.outputOffset == lock.withLock({ snapshot.nextOutputOffset }) else { throw POSIXError(.EINVAL) }
            let status: BpyMonitorResponse.Status
            switch request.operation {
            case .sample, .release: status = .gone
            case .detach: status = .detached
            case .collecting:
                try memory.beginCollection(permit)
                status = .gone
            case .commit:
                if lock.withLock({ snapshot.terminalCommit == nil }) { _ = try memory.commit(permit) }
                status = .committed
            case .terminate:
                memory.cancel(permit, reason: Self.reason(request.stopCause ?? .cancelled))
                status = .gone
            default: throw POSIXError(.EPERM)
            }
            result = response(request, receipt: try? memory.receipt(permit), status: status)
            lock.withLock { snapshot = result }
        } catch {
            result = .init(status: .refused, request: request, epoch: lock.withLock { snapshot.epoch },
                service: service, errorCode: Int32((error as NSError).code))
        }
        try replay.complete(result, request: request)
        return result
    }

    private func response(_ request: BpyMonitorRequest, receipt: BpyMemoryCoordinator.PermitReceipt?,
                          status: BpyMonitorResponse.Status) -> BpyMonitorResponse {
        let value = lock.withLock { snapshot }
        return .init(status: status, request: request, epoch: value.epoch, service: service,
            ended: value.ended, errorCode: value.errorCode, exitStatus: value.exitStatus, terminationSignal: value.terminationSignal,
            stage: value.stage, firstRelease: receipt?.firstRelease ?? value.firstRelease,
            terminalCommit: receipt?.terminalCommit ?? value.terminalCommit, stopReason: receipt?.stop?.rawValue ?? value.stopReason,
            nextOutputOffset: value.nextOutputOffset, outputComplete: true,
            admissionDeadline: value.admissionDeadline, runningDeadline: value.runningDeadline,
            cleanupDeadline: receipt?.cleanupStarted.map { $0 + BpyMemoryState.cleanupBudget } ?? value.cleanupDeadline,
            stopDeliveredAt: value.stopDeliveredAt, diagnosticBaseline: value.diagnosticBaseline,
            diagnosticObserved: value.diagnosticObserved, diagnosticThresholdBytes: value.diagnosticThresholdBytes,
            diagnosticSafetyBytes: value.diagnosticSafetyBytes, diagnosticChunks: value.diagnosticChunks,
            diagnosticMapping: value.diagnosticMapping, diagnosticAllocationObjectBytes: value.diagnosticAllocationObjectBytes,
            diagnosticStdout: value.diagnosticStdout)
    }

    static func digest(_ value: BpyHostLaunchSpec) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try SHA256.hash(data: encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    private static func reason(_ cause: BpyServiceStopCause) -> BpyMemoryStop {
        switch cause {
        case .cancelled: .cancelled
        case .disk: .disk
        case .fileCount: .fileCount
        case .processCount: .processCount
        case .failure: .executionFailed
        }
    }
}
