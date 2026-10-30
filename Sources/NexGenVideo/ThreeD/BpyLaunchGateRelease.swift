import Foundation

nonisolated enum BpyLaunchGateRelease {
    static func write(lock: NSLock, stopped: () -> Bool, writing: () throws -> Void, released: () -> Void) throws {
        try lock.withLock {
            guard !stopped() else { throw BpyAdmissionFailure.closed }
            try writing()
            released()
        }
    }

    static func authorize(memory: BpyMemoryCoordinator, permit: UUID, lock: NSLock, stopped: () -> Bool,
                          writing: () throws -> Void, released: () -> Void) throws -> Bool {
        do {
            try memory.authorizePrepared(permit) {
                try write(lock: lock, stopped: stopped, writing: writing, released: released)
            }
        } catch {
            if lock.withLock({ stopped() }) { return false }
            if let receipt = try? memory.receipt(permit), receipt.stop != nil { return false }
            if error is BpyLaunchDeferral { return false }
            throw error
        }
        return true
    }
}
