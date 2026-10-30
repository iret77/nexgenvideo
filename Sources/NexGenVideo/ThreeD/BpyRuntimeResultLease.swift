import BpyRuntimeProtocol
import Foundation

nonisolated final class BpyRuntimeResultLease: @unchecked Sendable {
    final class Registration: @unchecked Sendable {
        private let remove: @Sendable () -> Void
        init(remove: @escaping @Sendable () -> Void) { self.remove = remove }
        deinit { remove() }
    }

    private final class Storage: @unchecked Sendable {
        enum State { case live, transferred, derivation(Data), released }
        let lock = NSLock()
        let id: UUID
        let transport: UUID
        let job: UUID
        let slot: String
        let owner: UUID
        let limits: BpyRuntimeLimits
        let sourceRevision: String?
        let sourceSHA256: String?
        let fingerprint: String
        let response: BpyServiceResponse
        let onRelease: @Sendable (Bool) -> Void
        var state: State = .live
        var references = 1
        var detached = false
        var execution: BpyMemoryCoordinator.PermitReceipt?
        var files: [String: BpyRuntimeFile]
        var observers: [UUID: @Sendable () -> Void] = [:]

        init(id: UUID, transport: UUID, job: UUID, slot: String, owner: UUID, limits: BpyRuntimeLimits,
             sourceRevision: String?, sourceSHA256: String?, fingerprint: String,
             response: BpyServiceResponse, files: [String: BpyRuntimeFile], onRelease: @escaping @Sendable (Bool) -> Void) {
            self.id = id; self.transport = transport; self.job = job; self.slot = slot; self.owner = owner; self.limits = limits
            self.sourceRevision = sourceRevision; self.sourceSHA256 = sourceSHA256; self.fingerprint = fingerprint
            var receipt = response; receipt.stdout = nil; self.response = receipt
            self.files = files; self.onRelease = onRelease
        }

        var active: Bool { if case .released = state { false } else { true } }

        func retain() throws {
            try lock.withLock {
                guard active else { throw SpatialSceneError.changed }
                references += 1
            }
        }

        func end(force: Bool, reference: Bool) {
            let disposal = lock.withLock { () -> ([BpyRuntimeFile], [@Sendable () -> Void], Bool)? in
                if reference { references -= 1 }
                guard active, force || references == 0 else { return nil }
                state = .released
                let owned = Array(files.values); files.removeAll()
                let actions = force ? Array(observers.values) : []
                observers.removeAll()
                return (owned, actions, detached)
            }
            guard let disposal else { return }
            for file in disposal.0 { file.release() }
            for action in disposal.1 { action() }
            onRelease(disposal.2)
        }
    }

    private let storage: Storage
    private let lock = NSLock()
    private var released = false
    var id: UUID { storage.id }
    var transport: UUID { storage.transport }
    var job: UUID { storage.job }
    var sourceRevision: String? { storage.sourceRevision }
    var sourceSHA256: String? { storage.sourceSHA256 }
    var slot: String { storage.slot }
    var owner: UUID { storage.owner }
    var limits: BpyRuntimeLimits { storage.limits }
    var fingerprint: String { storage.fingerprint }
    var response: BpyServiceResponse { storage.response }
    var execution: BpyMemoryCoordinator.PermitReceipt? { storage.lock.withLock { storage.execution } }

    init(id: UUID = UUID(), transport: UUID, job: UUID, slot: String, owner: UUID, limits: BpyRuntimeLimits,
         sourceRevision: String?, sourceSHA256: String?, fingerprint: String, response: BpyServiceResponse,
         files: [String: BpyRuntimeFile], onRelease: @escaping @Sendable (Bool) -> Void) {
        storage = Storage(id: id, transport: transport, job: job, slot: slot, owner: owner, limits: limits,
            sourceRevision: sourceRevision, sourceSHA256: sourceSHA256, fingerprint: fingerprint,
            response: response, files: files, onRelease: onRelease)
    }

    private init(storage: Storage) throws { try storage.retain(); self.storage = storage }

    func joinedForReplay() throws -> BpyRuntimeResultLease { try BpyRuntimeResultLease(storage: storage) }

    var isAvailable: Bool { lock.withLock { !released && storage.lock.withLock { storage.active } } }
    var isDetached: Bool { storage.lock.withLock { storage.detached } }
    var urls: [String: URL] { storage.lock.withLock { storage.files.mapValues(\.url) } }

    private func access<Value>(_ body: (Storage) throws -> Value) throws -> Value {
        try lock.withLock {
            guard !released else { throw SpatialSceneError.changed }
            return try storage.lock.withLock {
                guard storage.active else { throw SpatialSceneError.changed }
                return try body(storage)
            }
        }
    }

    func file(_ name: String) throws -> BpyRuntimeFile {
        try access {
            guard let file = $0.files[name] else { throw SpatialSceneError.changed }
            return try file.retained()
        }
    }

    func data(_ name: String, maximum: UInt64, checking: () throws -> Void = {}) throws -> Data {
        let file = try file(name); defer { file.release() }
        return try file.verifiedData(maximum: maximum, checking: {
            guard self.isAvailable else { throw SpatialSceneError.changed }
            if Task.isCancelled { throw CancellationError() }
            try checking()
        })
    }

    func installGenerated(_ name: String, file: BpyRuntimeFile) throws {
        try access {
            guard $0.files[name] == nil else { throw SpatialSceneError.changed }
            $0.files[name] = try file.retained()
        }
    }

    func withConsumer<Value>(cancellation: BpyOperationCancellation,
                              _ operation: (BpyConsumerWork, BpyOperationCancellation) throws -> Value) throws -> Value {
        let invalidation = observeInvalidation { cancellation.cancel() }
        defer { withExtendedLifetime(invalidation) {} }
        func check() throws {
            if Task.isCancelled { cancellation.cancel() }
            try cancellation.check()
            guard isAvailable else { throw SpatialSceneError.changed }
        }
        let work = try BpyMemoryCoordinator.shared.beginConsumer(owner: owner, cancellation: cancellation, checking: check)
        defer { work.release() }
        try check(); try work.check()
        let value = try operation(work, cancellation)
        try check(); try work.check()
        return value
    }

    func withDecode<Value>(width: Int, height: Int, cancellation: BpyOperationCancellation,
                           checking: () throws -> Void = {},
                           _ operation: () throws -> Value) throws -> Value {
        guard isAvailable, width > 0, height > 0, width <= limits.renderWidth, height <= limits.renderHeight,
              UInt64(width) * UInt64(height) <= UInt64(limits.renderPixels) else { throw SpatialSceneError.changed }
        return try BpyMediaDecode.withPixels(width: width, height: height, encodedBytes: limits.outputBytes,
            owner: owner, slot: slot, slotCapacity: limits.outputBytes + UInt64(limits.renderPixels) * 12,
            cancellation: cancellation, timeout: Double(limits.timeoutSeconds),
            checking: {
                guard self.isAvailable else { throw SpatialSceneError.changed }
                try checking()
            }) {
                let reservation = try BpyRetentionLedger.shared.reserve(slot: slot, owner: owner, kind: .decode,
                    bytes: limits.outputBytes + UInt64(width) * UInt64(height) * 12)
                defer { BpyRetentionLedger.shared.release(reservation) }
                return try operation()
            }
    }

    func transferExecution() throws {
        try access {
            if case .live = $0.state { $0.state = .transferred; $0.detached = true }
        }
    }

    func recordExecution(_ receipt: BpyMemoryCoordinator.PermitReceipt) throws {
        try access {
            guard $0.execution == nil, receipt.identity.job == $0.job, receipt.identity.transport == $0.transport,
                  receipt.identity.owner == $0.owner else { throw SpatialSceneError.changed }
            $0.execution = receipt
        }
    }

    func detach(proof: Data) throws {
        try access {
            if case .live = $0.state { throw SpatialSceneError.changed }
            if case .derivation(let existing) = $0.state {
                guard existing == proof else { throw SpatialSceneError.changed }
            } else { $0.state = .derivation(proof) }
        }
    }

    func authenticate(proof: Data) throws {
        try access {
            guard case .derivation(let original) = $0.state, original == proof else { throw SpatialSceneError.changed }
        }
    }

    func observeInvalidation(_ action: @escaping @Sendable () -> Void) -> Registration {
        let id = UUID()
        let immediate = storage.lock.withLock {
            guard storage.active else { return true }
            storage.observers[id] = action
            return false
        }
        if immediate { action() }
        let storage = storage
        return Registration { [weak storage] in _ = storage?.lock.withLock { storage?.observers.removeValue(forKey: id) } }
    }

    func invalidate() { storage.end(force: true, reference: false) }

    func release() {
        let release = lock.withLock { if released { return false }; released = true; return true }
        if release { storage.end(force: false, reference: true) }
    }
    deinit { release() }
}
