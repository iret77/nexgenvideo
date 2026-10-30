import BpyRuntimeProtocol
import Foundation

nonisolated enum BpyMediaDecode {
    final class Pool: @unchecked Sendable {
        private struct Entry {
            let id: UUID
            let bytes: UInt64
            let slot: String?
            let slotCapacity: UInt64
            let wake: DispatchSemaphore
        }
        private let lock = NSLock()
        private let capacity: UInt64
        private var used: UInt64 = 0
        private var slots: [String: UInt64] = [:]
        private var queue: [Entry] = []
        private var active: [UUID: Entry] = [:]

        init(capacity: UInt64) { self.capacity = capacity }

        func diagnosticBlock() throws -> UUID {
            guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw BpyAdmissionFailure.closed }
            return try reserve(capacity, cancellation: .init(), timeout: 30, checking: {})
        }

        func diagnosticState() throws -> (used: UInt64, queued: Int) {
            guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw BpyAdmissionFailure.closed }
            return lock.withLock { (used, queue.count) }
        }

        func reserve(_ bytes: UInt64, slot: String? = nil, slotCapacity: UInt64? = nil,
                     cancellation: BpyOperationCancellation, timeout: TimeInterval,
                     checking: () throws -> Void) throws -> UUID {
            guard bytes <= capacity, bytes <= (slotCapacity ?? capacity), timeout.isFinite, timeout > 0 else {
                throw BpyRuntimeError.invalidInput("The media validation exceeds its memory contract.")
            }
            let deadline = try BpyRuntimeClock.awakeSeconds() + timeout
            let entry = Entry(id: UUID(), bytes: bytes, slot: slot, slotCapacity: slotCapacity ?? capacity,
                wake: DispatchSemaphore(value: 0))
            let registration = cancellation.observe { entry.wake.signal() }
            defer { withExtendedLifetime(registration) {} }
            try lock.withLock {
                guard queue.count + active.count < 16_384 else { throw BpyRuntimeError.rejected("Too many media validations are pending.") }
                queue.append(entry)
            }
            var granted = false
            defer {
                if !granted {
                    let signals = lock.withLock { queue.removeAll { $0.id == entry.id }; return queue.map(\.wake) }
                    for signal in signals { signal.signal() }
                }
            }
            while true {
                try cancellation.check()
                try checking()
                guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw BpyRuntimeError.timedOut }
                granted = lock.withLock {
                    let slotUsed = entry.slot.flatMap { slots[$0] } ?? 0
                    guard queue.first?.id == entry.id, used <= capacity, entry.bytes <= capacity - used,
                          slotUsed <= entry.slotCapacity, entry.bytes <= entry.slotCapacity - slotUsed else { return false }
                    queue.removeFirst()
                    used += entry.bytes
                    if let slot = entry.slot { slots[slot] = slotUsed + entry.bytes }
                    active[entry.id] = entry
                    return true
                }
                if granted {
                    do { try cancellation.check(); try checking() }
                    catch { release(entry.id); throw error }
                    return entry.id
                }
                _ = entry.wake.wait(timeout: .now() + .milliseconds(50))
            }
        }

        func release(_ id: UUID) {
            let signals = lock.withLock { () -> [DispatchSemaphore] in
                guard let entry = active.removeValue(forKey: id) else { return [] }
                used -= entry.bytes
                if let slot = entry.slot {
                    let remaining = (slots[slot] ?? 0) - entry.bytes
                    if remaining == 0 { slots.removeValue(forKey: slot) } else { slots[slot] = remaining }
                }
                return queue.map(\.wake)
            }
            for signal in signals { signal.signal() }
        }
    }

    private static let pool = Pool(capacity: UInt64(bpyRuntimeServiceNames.count)
        * (BpyRuntimeLimits.maximumOutputBytes + UInt64(BpyRuntimeLimits.maximumRenderPixels) * 12))

    static func diagnosticBlock() throws -> UUID { try pool.diagnosticBlock() }
    static func diagnosticState() throws -> (used: UInt64, queued: Int) { try pool.diagnosticState() }
    static func diagnosticRelease(_ id: UUID) {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { return }
        pool.release(id)
    }

    static func withPixels<Value>(width: Int, height: Int, encodedBytes: UInt64,
        owner: UUID, slot: String? = nil, slotCapacity: UInt64? = nil,
        cancellation: BpyOperationCancellation, timeout: TimeInterval = 120,
        checking: () throws -> Void = {}, operation: () throws -> Value
    ) throws -> Value {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              UInt64(width) * UInt64(height) <= UInt64(BpyRuntimeLimits.maximumRenderPixels),
              encodedBytes <= BpyRuntimeLimits.maximumOutputBytes else { throw SpatialSceneError.changed }
        let bytes = encodedBytes + UInt64(width) * UInt64(height) * 12
        func check() throws {
            try cancellation.check()
            if Task.isCancelled { throw CancellationError() }
            try checking()
        }
        let reservation = try pool.reserve(bytes, slot: slot, slotCapacity: slotCapacity,
            cancellation: cancellation, timeout: timeout, checking: check)
        defer { pool.release(reservation) }
        let work = try BpyMemoryCoordinator.shared.beginConsumer(owner: owner, cancellation: cancellation, checking: check)
        defer { work.release() }
        try check()
        let value = try autoreleasepool { try operation() }
        try check()
        try work.check()
        return value
    }
}
