import BpyRuntimeProtocol
import Darwin
import Foundation

nonisolated final class BpyProcessObservation: @unchecked Sendable {
    struct Snapshot: Sendable {
        let supervisor: BpyObservedProcess?
        let descendants: [BpyObservedProcess]
        let worker: BpyObservedProcess?
        let vnodes: [BpyObservedVnode]
        let ended: [BpyObservedProcess]
    }

    private let lock = NSLock()
    private let supervisor: BpyObservedProcess
    private let workerExecutable: String
    private let inspector: BpyHostMonitor.Inspector
    private var child: BpyObservedProcess?

    init(supervisor: BpyObservedProcess, workerExecutable: String,
         inspector: BpyHostMonitor.Inspector = .init()) {
        self.supervisor = supervisor; self.workerExecutable = workerExecutable; self.inspector = inspector
    }

    func captureChild(_ value: BpyObservedProcess) throws {
        try lock.withLock {
            guard value.parent == supervisor.pid, value.start > 0,
                  value.executable == supervisor.executable || value.executable == workerExecutable,
                  child.map({ $0.pid == value.pid && $0.start == value.start }) ?? true,
                  try inspector.matches(value) else { throw POSIXError(.EPERM) }
            child = value
        }
    }

    func sample() throws -> Snapshot {
        try lock.withLock {
            guard let root = try inspector.process(supervisor.pid) else {
                if let child, try inspector.process(child.pid)?.start == child.start { throw POSIXError(.EBUSY) }
                return .init(supervisor: nil, descendants: [], worker: nil, vnodes: [], ended: [supervisor] + (child.map { [$0] } ?? []))
            }
            guard root.start == supervisor.start, root.parent == supervisor.parent,
                  root.executable == supervisor.executable else { throw POSIXError(.EPERM) }
            let descendants = try inspector.descendants(root)
            guard descendants.count <= 1 else { throw POSIXError(.EOVERFLOW) }
            var worker = descendants.first
            if let value = worker {
                guard value.parent == root.pid,
                      value.executable == supervisor.executable || value.executable == workerExecutable,
                      child.map({ $0.pid == value.pid && $0.start == value.start }) ?? true,
                      try inspector.matches(value) else { throw POSIXError(.EPERM) }
            } else if let child, let value = try inspector.process(child.pid), value.start == child.start {
                throw POSIXError(.EBUSY)
            }
            let vnodes = try worker.map { try inspector.vnodes($0) } ?? []
            if let value = worker, try !inspector.matches(value) { worker = nil }
            return .init(supervisor: root, descendants: worker.map { [$0] } ?? [], worker: worker, vnodes: vnodes, ended: [])
        }
    }
}
