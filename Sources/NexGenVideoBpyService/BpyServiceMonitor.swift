import BpyRuntimeProtocol
import Darwin
import Foundation

final class BpyServiceMonitor: @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let transport: UUID

    init(connection: NSXPCConnection, transport: UUID) {
        self.connection = connection; self.transport = transport
    }

    func attach(process: BpyOwnedProcess, serviceStart: UInt64) throws -> BpyServiceObservation {
        let request = BpyMonitorRequest(transport: transport, execution: UUID(), operation: .attach,
                                        supervisorPID: process.processIdentifier)
        let response = try inspect(request)
        guard response.status == .attached, let epoch = response.epoch,
              let service = response.service, service.pid == getpid(), service.start == serviceStart,
              let supervisor = response.supervisor, supervisor.pid == process.processIdentifier,
              supervisor.parent == getpid(), supervisor.start > 0 else { throw POSIXError(.EPERM) }
        return BpyServiceObservation(monitor: self, transport: transport, execution: request.execution,
                                     epoch: epoch, service: service, supervisor: supervisor)
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var value: Data?
        let ready = DispatchSemaphore(value: 0)

        func store(_ data: Data?) {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return }
            completed = true; value = data; ready.signal()
        }

        func load() -> Data? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    fileprivate func inspect(_ request: BpyMonitorRequest) throws -> BpyMonitorResponse {
        guard let connection else { throw POSIXError(.ENOTCONN) }
        let box = Reply()
        guard let host = connection.remoteObjectProxyWithErrorHandler({ _ in box.store(nil) }) as? BpyHostMonitorProtocol else {
            throw POSIXError(.ENOTCONN)
        }
        host.inspect(try JSONEncoder().encode(request)) { box.store($0) }
        guard box.ready.wait(timeout: .now() + 2) == .success else { throw POSIXError(.ETIMEDOUT) }
        guard let data = box.load(), data.count <= 8 * 1_024 * 1_024 else { throw POSIXError(.EIO) }
        let response = try JSONDecoder().decode(BpyMonitorResponse.self, from: data)
        guard response.transport == request.transport, response.execution == request.execution,
              response.sequence == request.sequence, response.status != .refused else { throw POSIXError(.EIO) }
        return response
    }
}

final class BpyServiceObservation {
    private let monitor: BpyServiceMonitor
    private let transport: UUID
    private let execution: UUID
    private let epoch: UUID
    private var sequence: UInt64 = 0
    let service: BpyObservedProcess
    let supervisor: BpyObservedProcess

    fileprivate init(monitor: BpyServiceMonitor, transport: UUID, execution: UUID, epoch: UUID,
                     service: BpyObservedProcess, supervisor: BpyObservedProcess) {
        self.monitor = monitor; self.transport = transport; self.execution = execution; self.epoch = epoch
        self.service = service; self.supervisor = supervisor
    }

    func sample() throws -> BpyMonitorResponse { try inspect(.sample) }
    @discardableResult
    func detach() throws -> BpyMonitorResponse { try inspect(.detach) }

    private func inspect(_ operation: BpyMonitorRequest.Operation) throws -> BpyMonitorResponse {
        guard sequence < UInt64.max else { throw POSIXError(.EOVERFLOW) }
        sequence += 1
        let response = try monitor.inspect(.init(transport: transport, execution: execution,
            operation: operation, epoch: epoch, sequence: sequence, supervisorPID: supervisor.pid))
        guard response.epoch == epoch, let peer = response.service,
              peer.pid == service.pid, peer.start == service.start else { throw POSIXError(.EPERM) }
        guard (operation == .sample && [.observed, .gone].contains(response.status))
                || (operation == .detach && response.status == .detached) else { throw POSIXError(.EIO) }
        if response.status == .observed {
            guard let observed = response.supervisor, observed.pid == supervisor.pid,
                  observed.start == supervisor.start, observed.parent == service.pid else { throw POSIXError(.EPERM) }
        } else {
            guard response.ended.contains(where: { $0.pid == supervisor.pid && $0.start == supervisor.start }),
                  response.supervisor == nil, response.worker == nil, response.descendants.isEmpty,
                  response.vnodes.isEmpty else { throw POSIXError(.EIO) }
        }
        return response
    }
}
