import BpyRuntimeProtocol
import Darwin
import Foundation

nonisolated final class BpyLaunchReplay: @unchecked Sendable {
    private let lock = NSLock()
    private let epoch: UUID
    private let transport: UUID
    private let execution: UUID
    private let service: BpyObservedProcess
    private let supervisor: BpyObservedProcess
    private var sequence: UInt64 = 0
    private var pending: BpyMonitorRequest?
    private var completed: BpyMonitorRequest?
    private var response: BpyMonitorResponse?

    init(epoch: UUID, transport: UUID, execution: UUID, service: BpyObservedProcess, supervisor: BpyObservedProcess) {
        self.epoch = epoch; self.transport = transport; self.execution = execution
        self.service = service; self.supervisor = supervisor
    }

    func begin(_ request: BpyMonitorRequest, peer: BpyObservedProcess) throws -> BpyMonitorResponse? {
        try lock.withLock {
            guard request.epoch == epoch, request.transport == transport, request.execution == execution,
                  request.supervisorPID == supervisor.pid, peer.pid == service.pid, peer.start == service.start,
                  peer.executable == service.executable else { throw POSIXError(.EPERM) }
            if request.sequence == sequence, completed == request, let response { return response }
            guard pending == nil else { throw POSIXError(.EBUSY) }
            guard sequence < UInt64.max, request.sequence == sequence + 1 else { throw POSIXError(.EPERM) }
            sequence = request.sequence; pending = request
            return nil
        }
    }

    func complete(_ response: BpyMonitorResponse, request: BpyMonitorRequest) throws {
        try lock.withLock {
            guard pending == request, response.epoch == epoch, response.transport == transport,
                  response.execution == execution, response.sequence == sequence else { throw POSIXError(.EPERM) }
            self.response = response; completed = request; pending = nil
        }
    }
}
