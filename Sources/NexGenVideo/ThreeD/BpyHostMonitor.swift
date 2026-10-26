import BpyRuntimeProtocol
import Darwin
import Foundation

nonisolated final class BpyHostMonitor: NSObject, BpyHostMonitorProtocol, @unchecked Sendable {
    struct Inspector: Sendable {
        var canonical: @Sendable (URL) throws -> String = BpyRuntimePath.canonical
        var process: @Sendable (Int32) throws -> BpyObservedProcess? = BpyKernelInspection.process
        var descendants: @Sendable (BpyObservedProcess) throws -> [BpyObservedProcess] = BpyKernelInspection.descendants
        var matches: @Sendable (BpyObservedProcess) throws -> Bool = BpyKernelInspection.matches
        var vnodes: @Sendable (BpyObservedProcess) throws -> [BpyObservedVnode] = {
            try BpyKernelInspection.descriptors($0, fileports: false)
                + BpyKernelInspection.descriptors($0, fileports: true) + BpyKernelInspection.mappings($0)
        }
    }
    private struct Lease {
        let execution: UUID
        let epoch: UUID
        let service: BpyObservedProcess
        let supervisor: BpyObservedProcess
        var sequence: UInt64
        var worker: BpyObservedProcess?
    }

    private let peerPID: @Sendable () -> Int32
    private let inspector: Inspector
    private let observed: @Sendable (BpyObservedProcess?) -> Void
    private let transport: UUID
    private let layout: BpyRuntimeBundleLayout
    private let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.monitor")
    private var lease: Lease?
    private var executions = Set<UUID>()
    private var detached: [UUID: BpyMonitorResponse] = [:]
    private var recovering = false

    private final class Peer: @unchecked Sendable {
        private weak var connection: NSXPCConnection?
        init(_ connection: NSXPCConnection) { self.connection = connection }
        var pid: Int32 { connection?.processIdentifier ?? -1 }
    }

    init(connection: NSXPCConnection, transport: UUID, layout: BpyRuntimeBundleLayout,
         observed: @escaping @Sendable (BpyObservedProcess?) -> Void = { _ in }) {
        let peer = Peer(connection)
        peerPID = { peer.pid }
        inspector = Inspector()
        self.observed = observed
        self.transport = transport; self.layout = layout
    }

    init(peerPID: @escaping @Sendable () -> Int32, transport: UUID, layout: BpyRuntimeBundleLayout, inspector: Inspector) {
        self.peerPID = peerPID; self.inspector = inspector; self.transport = transport; self.layout = layout
        observed = { _ in }
    }

    private final class Reply: @unchecked Sendable {
        let body: (Data) -> Void
        init(_ body: @escaping (Data) -> Void) { self.body = body }
    }

    func inspect(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        guard data.count <= 4_096, let request = try? JSONDecoder().decode(BpyMonitorRequest.self, from: data) else {
            reply(Data())
            return
        }
        let callback = Reply(reply)
        queue.async { [self] in
            let response: BpyMonitorResponse
            do { response = try inspect(request) }
            catch { response = .init(status: .refused, request: request, errorCode: Int32((error as NSError).code)) }
            guard let encoded = try? JSONEncoder().encode(response), encoded.count <= 8 * 1_024 * 1_024 else {
                callback.body(Data())
                return
            }
            callback.body(encoded)
        }
    }

    func recover(timeout: TimeInterval = 5, completion: @escaping @Sendable (Bool) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        queue.async { [self] in
            recovering = true
            guard timeout.isFinite, timeout >= 0 else { completion(false); return }
            let processes = lease.map { [$0.supervisor] + ($0.worker.map { [$0] } ?? []) } ?? []
            do {
                while true {
                    if try processes.allSatisfy({ try !inspector.matches($0) }) {
                        observed(nil)
                        completion(true)
                        return
                    }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { completion(false); return }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            } catch { completion(false) }
        }
    }

    private func service() throws -> BpyObservedProcess {
        guard let process = try inspector.process(peerPID()),
              process.executable == (try inspector.canonical(layout.service.appendingPathComponent("Contents/MacOS/NexGenVideoBpyService"))) else {
            throw POSIXError(.EPERM)
        }
        return process
    }

    private func inspect(_ request: BpyMonitorRequest) throws -> BpyMonitorResponse {
        guard !recovering, request.transport == transport, request.supervisorPID > 1 else { throw POSIXError(.EPERM) }
        let peer = try service()
        if request.operation == .detach, let previous = detached[request.execution] {
            guard request.epoch == previous.epoch, request.sequence >= previous.sequence,
                  previous.service?.pid == peer.pid, previous.service?.start == peer.start,
                  previous.ended.first?.pid == request.supervisorPID else { throw POSIXError(.EPERM) }
            let response = BpyMonitorResponse(status: .detached, request: request, epoch: previous.epoch,
                service: peer, ended: previous.ended)
            detached[request.execution] = response
            return response
        }
        if request.operation == .attach {
            if let previous = lease {
                guard try !inspector.matches(previous.supervisor) else { throw POSIXError(.EBUSY) }
                if let worker = previous.worker, try inspector.matches(worker) { throw POSIXError(.EBUSY) }
                lease = nil
                observed(nil)
            }
            guard lease == nil, request.epoch == nil, request.sequence == 0,
                  executions.count < 65_536, !executions.contains(request.execution),
                  let supervisor = try inspector.process(request.supervisorPID),
                  supervisor.parent == peer.pid, supervisor.executable == (try inspector.canonical(layout.supervisor)),
                  try inspector.matches(peer), try inspector.matches(supervisor) else {
                throw POSIXError(.EPERM)
            }
            let epoch = UUID()
            lease = .init(execution: request.execution, epoch: epoch, service: peer, supervisor: supervisor, sequence: 0)
            executions.insert(request.execution)
            observed(supervisor)
            return .init(status: .attached, request: request, epoch: epoch, service: peer, supervisor: supervisor)
        }
        guard var current = lease, request.execution == current.execution, request.epoch == current.epoch,
              request.supervisorPID == current.supervisor.pid, current.sequence < UInt64.max,
              request.sequence == current.sequence + 1, peer.pid == current.service.pid,
              peer.start == current.service.start else { throw POSIXError(.EPERM) }
        current.sequence = request.sequence
        lease = current
        guard let supervisor = try inspector.process(current.supervisor.pid),
              supervisor.start == current.supervisor.start else {
            if let worker = current.worker, try inspector.matches(worker) { throw POSIXError(.EBUSY) }
            let response = BpyMonitorResponse(status: request.operation == .detach ? .detached : .gone,
                request: request, epoch: current.epoch, service: peer,
                ended: [current.supervisor] + (current.worker.map { [$0] } ?? []))
            if request.operation == .detach {
                detached[request.execution] = response
                lease = nil
                observed(nil)
            }
            return response
        }
        guard request.operation == .sample, supervisor.parent == peer.pid,
              supervisor.executable == (try inspector.canonical(layout.supervisor)) else { throw POSIXError(.EPERM) }
        let descendants = try inspector.descendants(supervisor)
        let direct = descendants.filter { $0.parent == supervisor.pid }
        var worker: BpyObservedProcess?
        if let previous = current.worker {
            worker = descendants.first { $0.pid == previous.pid && $0.start == previous.start }
            if worker == nil, try inspector.matches(previous) { throw POSIXError(.EPERM) }
            if worker == nil && !descendants.isEmpty { throw POSIXError(.EPERM) }
        } else {
            guard direct.count <= 1 else { throw POSIXError(.EOVERFLOW) }
            worker = direct.first
        }
        var vnodes: [BpyObservedVnode] = []
        if let observedWorker = worker {
            guard observedWorker.parent == supervisor.pid else { throw POSIXError(.EPERM) }
            if observedWorker.executable != supervisor.executable {
                guard observedWorker.executable == (try inspector.canonical(layout.runtime.appendingPathComponent("python/bin/python3.13"))) else {
                    throw POSIXError(.EPERM)
                }
            }
            current.worker = observedWorker
            lease = current
            do { vnodes = try inspector.vnodes(observedWorker) }
            catch { if try inspector.matches(observedWorker) { throw error } }
            if try !inspector.matches(observedWorker) { worker = nil; vnodes = [] }
        }
        guard try inspector.matches(peer) else { throw POSIXError(.EPERM) }
        if try !inspector.matches(supervisor) {
            if let previous = current.worker, try inspector.matches(previous) { throw POSIXError(.EBUSY) }
            return .init(status: .gone, request: request, epoch: current.epoch, service: peer,
                         ended: [current.supervisor] + (current.worker.map { [$0] } ?? []))
        }
        lease = current
        let liveDescendants = try descendants.filter { try inspector.matches($0) }
        return .init(status: .observed, request: request, epoch: current.epoch, service: peer,
                     supervisor: supervisor, descendants: liveDescendants, worker: worker, vnodes: vnodes)
    }
}
