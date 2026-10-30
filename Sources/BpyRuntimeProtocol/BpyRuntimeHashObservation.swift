import Foundation

public enum BpyRuntimeHashObservation {
    public struct Context: Sendable {
        public let id: UUID
        public let callerOwned: Bool
        public let purpose: String
        public let isCancelled: @Sendable () -> Bool
        public init(id: UUID, callerOwned: Bool, purpose: String, isCancelled: @escaping @Sendable () -> Bool) {
            self.id = id; self.callerOwned = callerOwned; self.purpose = purpose; self.isCancelled = isCancelled
        }
    }
    public struct Progress: Sendable {
        public let device: UInt64
        public let inode: UInt64
        public let bytes: UInt64
        public let hashedBytes: UInt64
    }
    public final class Registration: @unchecked Sendable {
        private let id: UUID
        fileprivate init(_ id: UUID) { self.id = id }
        deinit { BpyRuntimeHashObservation.state.lock.withLock { _ = BpyRuntimeHashObservation.state.observers.removeValue(forKey: id) } }
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var observers: [UUID: @Sendable (Progress, Context) -> Void] = [:]
    }
    @TaskLocal public static var context: Context?
    private static let state = State()
    private static let enabled = ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false

    public static func observe(_ observer: @escaping @Sendable (Progress, Context) -> Void) throws -> Registration {
        guard enabled else { throw CocoaError(.fileReadNoPermission) }
        let id = UUID()
        state.lock.withLock { state.observers[id] = observer }
        return Registration(id)
    }

    static func chunk(device: UInt64, inode: UInt64, bytes: UInt64, hashedBytes: UInt64) {
        guard enabled, let context else { return }
        let observers = state.lock.withLock { Array(state.observers.values) }
        let progress = Progress(device: device, inode: inode, bytes: bytes, hashedBytes: hashedBytes)
        for observer in observers { observer(progress, context) }
    }
}
