import BpyRuntimeProtocol
import Foundation

nonisolated struct BpyMediaReadScope: Sendable {
    private final class Storage: @unchecked Sendable {
        let owner: UUID
        let cancellation: BpyOperationCancellation
        let memory: BpyMemoryCoordinator
        let ownsOwner: Bool
        let ownsCancellation: Bool
        let lifetime: BpyOperationCancellation?
        let parent: Storage?

        init(owner: UUID, cancellation: BpyOperationCancellation, memory: BpyMemoryCoordinator,
             ownsOwner: Bool, ownsCancellation: Bool, lifetime: BpyOperationCancellation?, parent: Storage? = nil) {
            self.owner = owner; self.cancellation = cancellation; self.memory = memory
            self.ownsOwner = ownsOwner; self.ownsCancellation = ownsCancellation
            self.lifetime = lifetime; self.parent = parent
            if let lifetime { cancellation.follow(lifetime) }
            if let parent, ownsCancellation || !parent.ownsCancellation { cancellation.follow(parent.cancellation) }
        }
        deinit {
            if ownsCancellation { cancellation.cancel() }
            if ownsOwner { memory.close(owner: owner); memory.retire(owner: owner) }
        }
    }

    private final class Roots: @unchecked Sendable {
        struct Entry: Sendable {
            let owner: UUID
            let lifetime: BpyOperationCancellation
        }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        func register(_ root: String, generation: UUID) {
            let previous = lock.withLock { () -> Entry? in
                if entries[root]?.owner == generation { return nil }
                let previous = entries[root]
                entries[root] = .init(owner: generation, lifetime: .init())
                return previous
            }
            if let previous { close(previous) }
        }
        func close(_ root: String, generation: UUID?) {
            let entry = lock.withLock { () -> Entry? in
                guard let entry = entries[root], generation == nil || entry.owner == generation else { return nil }
                return entry
            }
            if let entry { close(entry) }
        }
        private func close(_ entry: Entry) {
            entry.lifetime.cancel()
            BpyMemoryCoordinator.shared.close(owner: entry.owner)
            BpyMemoryCoordinator.shared.retire(owner: entry.owner)
        }
        func entry(_ root: String) -> Entry? { lock.withLock { entries[root] } }
    }

    private static let roots = Roots()
    @TaskLocal private static var current: BpyMediaReadScope?
    private let storage: Storage
    private let allowedRoots: Set<String>
    private let additionalCheck: @Sendable () throws -> Void
    var owner: UUID { storage.owner }
    var cancellation: BpyOperationCancellation { storage.cancellation }

    private init(root: URL, cancellation: BpyOperationCancellation? = nil, memory: BpyMemoryCoordinator? = nil,
                 fallbackOwner: UUID? = nil) {
        let key = root.standardizedFileURL.path
        let parent = Self.current.flatMap { $0.allowedRoots.contains(key) ? $0 : nil }
        let entry = Self.roots.entry(key)
        storage = .init(owner: parent?.owner ?? entry?.owner ?? fallbackOwner ?? UUID(), cancellation: cancellation ?? .init(),
            memory: memory ?? parent?.storage.memory ?? .shared, ownsOwner: parent == nil && entry == nil && fallbackOwner == nil,
            ownsCancellation: cancellation == nil, lifetime: parent?.storage.lifetime ?? entry?.lifetime, parent: parent?.storage)
        allowedRoots = parent?.allowedRoots ?? [key]
        if let parent {
            additionalCheck = parent.additionalCheck
        } else {
            additionalCheck = { @Sendable in }
        }
    }

    private init(storage: Storage, allowedRoots: Set<String>, checking: @escaping @Sendable () throws -> Void) {
        self.storage = storage; self.allowedRoots = allowedRoots; additionalCheck = checking
    }

    static func register(root: URL, generation: UUID) { roots.register(root.standardizedFileURL.path, generation: generation) }
    static func close(root: URL, generation: UUID? = nil) { roots.close(root.standardizedFileURL.path, generation: generation) }

    static func withScope<Value>(dataRoot: URL, cancellation: BpyOperationCancellation? = nil,
                                 operation: (BpyMediaReadScope) throws -> Value) throws -> Value {
        let root = dataRoot.standardizedFileURL
        if let current, current.allowedRoots.contains(root.path), cancellation == nil || current.cancellation === cancellation {
            try current.check(); return try operation(current)
        }
        let scope = BpyMediaReadScope(root: root, cancellation: cancellation)
        return try $current.withValue(scope) { try scope.check(); return try operation(scope) }
    }

    static func withTransaction<Value>(source: URL, staging: URL, operation: () throws -> Value) throws -> Value {
        try withScope(dataRoot: source) { scope in
            let alias = BpyMediaReadScope(storage: scope.storage, allowedRoots: scope.allowedRoots.union([staging.standardizedFileURL.path]), checking: scope.additionalCheck)
            return try $current.withValue(alias, operation: operation)
        }
    }

    func check() throws {
        do { try additionalCheck() }
        catch { cancellation.cancel(); throw error }
        if Task.isCancelled { cancellation.cancel(); throw BpyAdmissionFailure.cancelled }
        try cancellation.check()
    }

    static func operation(dataRoot: URL, owner: UUID, cancellation: BpyOperationCancellation,
                          memory: BpyMemoryCoordinator) -> BpyMediaReadScope {
        .init(root: dataRoot.standardizedFileURL, cancellation: cancellation, memory: memory, fallbackOwner: owner)
    }

    func checking(_ check: @escaping @Sendable () throws -> Void) -> BpyMediaReadScope {
        let previous = additionalCheck
        return .init(storage: storage, allowedRoots: allowedRoots, checking: { try previous(); try check() })
    }

    func withConsumer<Value>(_ operation: (BpyConsumerWork) throws -> Value) throws -> Value {
        try check()
        let work = try storage.memory.beginConsumer(owner: owner, cancellation: cancellation, checking: check)
        defer { work.release() }
        try check()
        let token = cancellation
        let context = BpyRuntimeHashObservation.Context(id: token.id, callerOwned: !storage.ownsCancellation,
            purpose: "project-read", isCancelled: { token.isCancelled })
        let value = try BpyRuntimeHashObservation.$context.withValue(context) { try operation(work) }
        try check(); try work.check()
        return value
    }

    func digest(at url: URL) throws -> String { try withConsumer { try $0.digest(at: url, checking: check) } }

    func verifiedData(at url: URL, expectedSHA256: String, maximum: UInt64) throws -> Data {
        try withConsumer { work in
            func checking() throws { try check(); try work.check() }
            let file = try BpyRuntimeFile.borrow(url.lastPathComponent, in: url.deletingLastPathComponent(),
                maximum: maximum, expectedSHA256: expectedSHA256, checking: checking)
            defer { file.release() }
            return try file.verifiedData(maximum: maximum, preallocate: false, checking: checking)
        }
    }
}
