import BpyRuntimeProtocol
import Darwin
import Foundation

private struct BpyMonitorRefusal: LocalizedError, CustomNSError {
    let code: Int32
    static var errorDomain: String { NSPOSIXErrorDomain }
    var errorCode: Int { Int(code) }
    var errorDescription: String? { POSIXError(.init(rawValue: code) ?? .EIO).localizedDescription }
}

final class BpyServiceMonitor: @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let transport: UUID

    init(connection: NSXPCConnection, transport: UUID) {
        self.connection = connection; self.transport = transport
    }

    func start(spec: BpyHostLaunchSpec, execution: UUID, serviceStart: UInt64, maximumOutputBytes: Int,
               deadline: TimeInterval,
               cancelled: () -> Bool) throws -> BpyRemoteProcess {
        let request = BpyMonitorRequest(transport: transport, execution: execution, operation: .launch, launch: spec)
        guard deadline.isFinite else { throw POSIXError(.EINVAL) }
        while true {
            guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw POSIXError(.ETIMEDOUT) }
            guard !cancelled() else { throw POSIXError(.ECANCELED) }
            let response: BpyMonitorResponse
            do { response = try inspect(request) }
            catch let error as POSIXError where error.code == .ETIMEDOUT {
                guard !cancelled() else { throw POSIXError(.ECANCELED) }
                continue
            }
            if response.status == .deferred {
                guard let hostDeadline = response.runningDeadline ?? response.admissionDeadline, hostDeadline.isFinite,
                      try BpyRuntimeClock.awakeSeconds() < min(deadline, hostDeadline) else { throw POSIXError(.ETIMEDOUT) }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if response.status == .refused { throw POSIXError(.init(rawValue: response.errorCode) ?? .EIO) }
            guard response.status == .launched || response.status == .observed || response.status == .gone,
                  let epoch = response.epoch, let service = response.service,
                  service.pid == getpid(), service.start == serviceStart,
                  let supervisor = response.supervisor ?? response.ended.first,
                  supervisor.parent == connection?.processIdentifier,
                  supervisor.start > 0, response.admissionDeadline?.isFinite == true else {
                throw POSIXError(.EPERM)
            }
            return BpyRemoteProcess(monitor: self, transport: transport, execution: execution,
                epoch: epoch, service: service, supervisor: supervisor, initial: response, maximumOutputBytes: maximumOutputBytes)
        }
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var value: Data?
        let ready = DispatchSemaphore(value: 0)

        func store(_ data: Data?) {
            lock.lock(); defer { lock.unlock() }
            guard !completed else { return }
            completed = true; value = data; ready.signal()
        }

        func load() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
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
        guard response.schema == "nexgenvideo/bpy-monitor-response/2",
              response.transport == request.transport, response.execution == request.execution,
              response.sequence == request.sequence else { throw POSIXError(.EIO) }
        return response
    }
}

final class BpyRemoteProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let monitor: BpyServiceMonitor
    private let transport: UUID
    let execution: UUID
    private let epoch: UUID
    private var sequence: UInt64 = 0
    private var outputOffset: UInt64
    private var response: BpyMonitorResponse
    private var output = Data()
    private var pending: BpyMonitorRequest?
    private let maximumOutputBytes: Int
    let service: BpyObservedProcess
    let supervisor: BpyObservedProcess

    var processIdentifier: Int32 { supervisor.pid }
    var isRunning: Bool { get throws { try sample().status != .gone } }
    var firstRelease: TimeInterval? { lock.withLock { response.firstRelease } }
    var runningDeadline: TimeInterval? { lock.withLock { response.runningDeadline } }
    var admissionDeadline: TimeInterval? { lock.withLock { response.admissionDeadline } }
    var cleanupDeadline: TimeInterval? { lock.withLock { response.cleanupDeadline } }
    var stopReason: String? { lock.withLock { response.stopReason } }
    var launchStage: BpyLaunchStage? { lock.withLock { response.stage } }
    var logByteCount: Int { lock.withLock { output.count } }
    var log: String { lock.withLock { String(decoding: output, as: UTF8.self) } }

    fileprivate init(monitor: BpyServiceMonitor, transport: UUID, execution: UUID, epoch: UUID,
                     service: BpyObservedProcess, supervisor: BpyObservedProcess, initial: BpyMonitorResponse,
                     maximumOutputBytes: Int) {
        self.monitor = monitor; self.transport = transport; self.execution = execution; self.epoch = epoch
        self.service = service; self.supervisor = supervisor; response = initial
        outputOffset = initial.nextOutputOffset
        output = initial.stdout ?? Data()
        self.maximumOutputBytes = maximumOutputBytes
    }

    func sample() throws -> BpyMonitorResponse { try inspect(.sample) }
    @discardableResult
    func detach() throws -> BpyMonitorResponse { try inspect(.detach) }
    @discardableResult
    func beginCollection() throws -> BpyMonitorResponse { try inspect(.collecting) }
    @discardableResult
    func commit() throws -> BpyMonitorResponse { try inspect(.commit) }

    func signal(_ number: Int32) throws {
        guard number == SIGTERM else { throw POSIXError(.EPERM) }
        try stop(.cancelled)
    }

    func stop(_ cause: BpyServiceStopCause) throws { _ = try inspect(.terminate, stopCause: cause) }

    func waitUntilExit(timeout: TimeInterval = 3) throws -> Int32 {
        try waitForTermination(timeout: timeout).exitStatus
    }

    func waitForTermination(timeout: TimeInterval = 3) throws -> BpyProcessTermination {
        guard timeout.isFinite, timeout >= 0 else { throw POSIXError(.EINVAL) }
        let deadline = try BpyRuntimeClock.awakeSeconds() + timeout
        while true {
            let current = try sample()
            if current.status == .gone, current.outputComplete, let status = current.exitStatus {
                return .init(exitStatus: status, signal: current.terminationSignal)
            }
            guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw POSIXError(.ETIMEDOUT) }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    @discardableResult
    func terminateAndReap(grace: TimeInterval = 0.25, cause: BpyServiceStopCause = .cancelled) throws -> Int32 {
        try stop(cause)
        guard let deadline = cleanupDeadline else { throw POSIXError(.EIO) }
        return try waitUntilExit(timeout: max(0, deadline - BpyRuntimeClock.awakeSeconds()))
    }

    private func inspect(_ operation: BpyMonitorRequest.Operation, stopCause: BpyServiceStopCause? = nil) throws -> BpyMonitorResponse {
        lock.lock(); defer { lock.unlock() }
        if let previous = pending {
            let recovered = try monitor.inspect(previous)
            do {
                try accept(recovered, request: previous)
                pending = nil
                if previous.operation == operation && previous.stopCause == stopCause { return recovered }
            } catch let refusal as BpyMonitorRefusal {
                if previous.operation == operation && previous.stopCause == stopCause { throw refusal }
            }
        }
        guard sequence < UInt64.max else { throw POSIXError(.EOVERFLOW) }
        let next = sequence + 1
        let request = BpyMonitorRequest(transport: transport, execution: execution, operation: operation,
            epoch: epoch, sequence: next, supervisorPID: supervisor.pid, outputOffset: outputOffset, stopCause: stopCause)
        pending = request
        let received = try monitor.inspect(request)
        try accept(received, request: request)
        pending = nil
        return received
    }

    private func accept(_ received: BpyMonitorResponse, request: BpyMonitorRequest) throws {
        guard received.epoch == epoch, let peer = received.service,
              peer.pid == service.pid, peer.start == service.start else { throw POSIXError(.EPERM) }
        if received.status == .refused {
            sequence = request.sequence
            pending = nil
            throw BpyMonitorRefusal(code: received.errorCode)
        }
        if received.status == .observed || received.status == .released {
            guard let observed = received.supervisor, observed.pid == supervisor.pid,
                  observed.start == supervisor.start, observed.parent == supervisor.parent else { throw POSIXError(.EPERM) }
        } else if [.gone, .detached, .committed].contains(received.status) {
            guard received.supervisor == nil, received.worker == nil, received.descendants.isEmpty,
                  received.ended.contains(where: { $0.pid == supervisor.pid && $0.start == supervisor.start }) else {
                throw POSIXError(.EPERM)
            }
        } else { throw POSIXError(.EIO) }
        if let data = received.stdout {
            let next = outputOffset.addingReportingOverflow(UInt64(data.count))
            guard !next.overflow, received.nextOutputOffset == next.partialValue,
                  data.count <= 65_536, output.count <= maximumOutputBytes,
                  data.count <= maximumOutputBytes - output.count else { throw POSIXError(.EIO) }
            output.append(data)
        }
        response = received; outputOffset = received.nextOutputOffset; sequence = request.sequence
    }
}
