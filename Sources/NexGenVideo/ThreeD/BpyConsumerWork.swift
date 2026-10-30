import BpyRuntimeProtocol
import Foundation

nonisolated final class BpyConsumerWork: @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let id: UUID
        let coordinator: BpyMemoryCoordinator
        let cancellation: BpyOperationCancellation
        let lock = NSLock()
        var owners = 1
        var registration: BpyOperationCancellation.Registration?

        init(id: UUID, coordinator: BpyMemoryCoordinator, cancellation: BpyOperationCancellation) {
            self.id = id; self.coordinator = coordinator; self.cancellation = cancellation
            registration = cancellation.observe { [weak coordinator] in coordinator?.cancelConsumer(id) }
        }

        func retain() throws {
            try lock.withLock {
                guard owners > 0 else { throw BpyAdmissionFailure.closed }
                owners += 1
            }
        }

        func release() {
            let ended = lock.withLock { owners -= 1; return owners == 0 }
            if ended { registration = nil; coordinator.endConsumer(id) }
        }
    }

    private let storage: Storage
    private let lock = NSLock()
    private var released = false
    var id: UUID { storage.id }

    init(id: UUID, coordinator: BpyMemoryCoordinator, cancellation: BpyOperationCancellation) {
        storage = Storage(id: id, coordinator: coordinator, cancellation: cancellation)
    }

    private init(storage: Storage) throws { try storage.retain(); self.storage = storage }

    func retained() throws -> BpyConsumerWork {
        try lock.withLock {
            guard !released else { throw BpyAdmissionFailure.closed }
            return try BpyConsumerWork(storage: storage)
        }
    }

    func check() throws {
        guard lock.withLock({ !released }) else { throw BpyAdmissionFailure.closed }
        try storage.coordinator.checkConsumer(id)
        try storage.cancellation.check()
    }

    var isStopped: Bool { (try? check()) == nil }
    func digest(at url: URL, checking: () throws -> Void = {}) throws -> String {
        func require() throws {
            if Task.isCancelled { storage.cancellation.cancel(); throw BpyAdmissionFailure.cancelled }
            try checking(); try check()
        }
        try require()
        let activity = BpyObservedActivity(options: .userInitiated, reason: "Verify 3D runtime files", parent: id)
        defer { activity.end() }
        let context = BpyRuntimeHashObservation.Context(id: storage.cancellation.id,
            callerOwned: BpyRuntimeHashObservation.context?.callerOwned ?? true, purpose: "file-digest",
            isCancelled: { self.storage.cancellation.isCancelled })
        return try BpyRuntimeHashObservation.$context.withValue(context) { try BpyRuntimeFile.digest(at: url, checking: require) }
    }
    func rethrowAfterCleanup(_ error: any Error) throws -> Never {
        do { try check() }
        catch let stop as BpyExecutionInterruption {
            if stop.reason != .cancelled { throw stop }
        } catch let failure as BpyAdmissionFailure {
            if failure != .cancelled { throw failure }
        }
        throw error
    }
    func failCleanup(since began: TimeInterval?) { storage.coordinator.failConsumerCleanup(id, since: began) }
    func release() {
        let end = lock.withLock { if released { return false }; released = true; return true }
        if end { storage.release() }
    }
    deinit { release() }
}
