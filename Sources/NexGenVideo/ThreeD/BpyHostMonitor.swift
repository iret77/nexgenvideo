import BpyRuntimeProtocol
import Darwin
import Foundation

nonisolated enum BpyTransportDisposition: String, Sendable {
    case rotation, close, loss, releaseFailed

    var stop: BpyMemoryStop {
        switch self {
        case .rotation: .cancelled
        case .close: .closed
        case .loss, .releaseFailed: .transportLost
        }
    }
}

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

    private let peerPID: @Sendable () -> Int32
    private let inspector: Inspector
    private let layout: BpyRuntimeBundleLayout
    private let launcher: BpyHostLauncher
    private let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.monitor")
    private let recovery = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.monitor.recovery", qos: .userInitiated)

    private final class Peer: @unchecked Sendable {
        private weak var connection: NSXPCConnection?
        init(_ connection: NSXPCConnection) { self.connection = connection }
        var pid: Int32 { connection?.processIdentifier ?? -1 }
    }

    init(connection: NSXPCConnection, transport: UUID, layout: BpyRuntimeBundleLayout,
         memory: BpyMemoryCoordinator = .shared,
         observed: @escaping @Sendable (BpyObservedProcess?) -> Void = { _ in }) {
        let peer = Peer(connection)
        peerPID = { peer.pid }
        inspector = Inspector()
        self.layout = layout
        launcher = BpyHostLauncher(transport: transport, layout: layout, memory: memory, observed: observed)
    }

    init(peerPID: @escaping @Sendable () -> Int32, transport: UUID, layout: BpyRuntimeBundleLayout, inspector: Inspector) {
        self.peerPID = peerPID; self.inspector = inspector; self.layout = layout
        launcher = BpyHostLauncher(transport: transport, layout: layout, observed: { _ in })
    }

    func install(_ binding: BpyHostLauncher.Binding) throws { try launcher.install(binding) }

    func authorize(execution: UUID, pid: Int32, start: UInt64) throws -> Bool {
        try launcher.authorize(execution: execution, pid: pid, start: start)
    }

    func diagnosticGate(execution: UUID) throws -> BpyHeldGateEvidence { try launcher.diagnosticGate(execution: execution) }
    func diagnosticEnded(execution: UUID) throws -> BpyMonitorResponse { try launcher.diagnosticEnded(execution: execution) }
    func diagnosticReapedLaunch(execution: UUID) throws -> Bool { try launcher.diagnosticReapedLaunch(execution: execution) }
    func diagnosticRecovered() throws -> Bool { try launcher.diagnosticRecovered() }

    func inspectDiagnostic(_ request: BpyMonitorRequest) throws -> BpyMonitorResponse {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw POSIXError(.EPERM) }
        return try queue.sync {
            guard let peer = try inspector.process(peerPID()),
                  peer.executable == (try inspector.canonical(layout.service.appendingPathComponent("Contents/MacOS/NexGenVideoBpyService"))),
                  try inspector.matches(peer) else { throw POSIXError(.EPERM) }
            return try launcher.inspect(request, service: peer)
        }
    }

    private final class Reply: @unchecked Sendable {
        let body: (Data) -> Void
        init(_ body: @escaping (Data) -> Void) { self.body = body }
    }

    func inspect(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        guard data.count <= 65_536, let request = try? JSONDecoder().decode(BpyMonitorRequest.self, from: data) else {
            reply(Data())
            return
        }
        let callback = Reply(reply)
        queue.async { [self] in
            let response: BpyMonitorResponse
            do {
                guard let peer = try inspector.process(peerPID()),
                      peer.executable == (try inspector.canonical(layout.service.appendingPathComponent("Contents/MacOS/NexGenVideoBpyService"))),
                      try inspector.matches(peer) else { throw POSIXError(.EPERM) }
                response = try launcher.inspect(request, service: peer)
            } catch {
                response = .init(status: .refused, request: request, errorCode: Int32((error as NSError).code))
            }
            guard let encoded = try? JSONEncoder().encode(response), encoded.count <= 8 * 1_024 * 1_024 else {
                callback.body(Data())
                return
            }
            callback.body(encoded)
        }
    }

    func recover(disposition: BpyTransportDisposition, timeout: TimeInterval = 5,
                 completion: @escaping @Sendable (Bool) -> Void) {
        guard timeout.isFinite, timeout >= 0, timeout <= 5 else { completion(false); return }
        let deadline = BpyRuntimeClock.read().map { $0.awake + timeout }
        launcher.beginRecovery(reason: disposition.stop)
        recovery.async { [self] in
            let exited = BpyLaunchLifecycle.recover(until: deadline, clock: BpyRuntimeClock.read,
                cleanupDeadline: { launcher.recoveryDeadline }, cleanup: { launcher.cleanup() },
                recovered: { launcher.recovered }, pause: { Thread.sleep(forTimeInterval: $0) })
            if !exited { recordRecoveryFailure(deadline: deadline) }
            completion(exited)
        }
    }

    private func recordRecoveryFailure(deadline: TimeInterval?) {
        guard let path = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"], path.hasPrefix("/") else { return }
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return }
        var record = launcher.recoveryDiagnostic()
        record["deadline"] = deadline.map { String($0) } ?? "unavailable"
        record["capturedAt"] = BpyRuntimeClock.read().map { String($0.awake) } ?? "unavailable"
        do {
            let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try bytes.write(to: URL(fileURLWithPath: path).appendingPathComponent("recovery-failure-\(UUID().uuidString).json"), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("SELFTEST_BPY_RECOVERY_DIAGNOSTIC_FAIL\n".utf8))
        }
    }
}
