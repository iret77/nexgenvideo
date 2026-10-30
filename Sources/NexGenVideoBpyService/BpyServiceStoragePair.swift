import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation
import os

final class BpyServiceStoragePair: @unchecked Sendable {
    let pair: BpyStoragePair
    let workerRoot: URL
    let dataRoot: URL
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var registry: [UUID: [UUID]] = [:]
    static var inUseIDs: [UUID] { registryLock.withLock { registry.values.flatMap { $0 } } }
    private let lock = NSLock()
    private var pins = 0
    private var closing = false
    private let registryID = UUID()

    final class Pin: @unchecked Sendable {
        private let owner: BpyServiceStoragePair
        private let lock = NSLock()
        private var released = false
        fileprivate init(owner: BpyServiceStoragePair) { self.owner = owner }
        func release() {
            let release = lock.withLock { if released { return false }; released = true; return true }
            if release { owner.lock.withLock { owner.pins -= 1 } }
        }
    }

    func pin() throws -> Pin {
        try lock.withLock {
            guard !closing else { throw POSIXError(.EBUSY) }
            pins += 1
            return Pin(owner: self)
        }
    }

    func beginClose() -> Bool {
        lock.withLock { closing = true; return pins == 0 }
    }
    private var descriptors: [Int32] = []
    private var scopes: [URL] = []
    private let log = Logger(subsystem: "de.h5ventures.nexgenvideo.bpy-service", category: "open-diagnostic")

    init(pair: BpyStoragePair, limits: BpyRuntimeLimits, transport: UUID, owner: UUID, serviceStart: UInt64) throws {
        guard serviceStart > 0, pair.isValid(limits: limits), let dataBytes = limits.dataStorageBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.pair = pair
        workerRoot = URL(fileURLWithPath: pair.worker.mountPath).appendingPathComponent(transport.uuidString)
        dataRoot = URL(fileURLWithPath: pair.data.mountPath).appendingPathComponent(transport.uuidString)
        do {
            for (lease, maximum, role) in [(pair.worker, limits.physicalStorageBytes, "worker"), (pair.data, dataBytes, "data")] {
                let before = Darwin.open(lease.mountPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
                let beforeError = before < 0 ? errno : 0
                let closeError = before >= 0 && Darwin.close(before) != 0 ? errno : 0
                log.notice("open.beforeScope session=\(transport.uuidString, privacy: .public) owner=\(owner.uuidString, privacy: .public) pid=\(getpid(), privacy: .public) start=\(serviceStart, privacy: .public) pair=\(pair.id.uuidString, privacy: .public) storage=\(lease.id.uuidString, privacy: .public) role=\(role, privacy: .public) errno=\(beforeError, privacy: .public) closeErrno=\(closeError, privacy: .public)")
                var stale = false
                let resolved = try URL(resolvingBookmarkData: lease.bookmark, options: [.withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
                scopes.append(resolved)
                let matches = resolved.path == lease.mountPath
                let volume = BpyStoragePaths.bookmarkVolumeMatch(lease.bookmark, mount: resolved)
                let digest = SHA256.hash(data: lease.bookmark).map { String(format: "%02x", $0) }.joined()
                log.notice("open.check session=\(transport.uuidString, privacy: .public) owner=\(owner.uuidString, privacy: .public) pid=\(getpid(), privacy: .public) start=\(serviceStart, privacy: .public) pair=\(pair.id.uuidString, privacy: .public) storage=\(lease.id.uuidString, privacy: .public) role=\(role, privacy: .public) sha256=\(digest, privacy: .public) stale=\(stale, privacy: .public) file=\(resolved.isFileURL, privacy: .public) pathMatches=\(matches, privacy: .public) volumeMatch=\(volume, privacy: .public)")
                // Transient bookmark freshness does not replace the leased mount identity.
                descriptors.append(try BpyStoragePaths.validateResolvedMount(lease, resolved: resolved, maximumBytes: maximum))
                log.notice("open.validated session=\(transport.uuidString, privacy: .public) owner=\(owner.uuidString, privacy: .public) pid=\(getpid(), privacy: .public) start=\(serviceStart, privacy: .public) pair=\(pair.id.uuidString, privacy: .public) storage=\(lease.id.uuidString, privacy: .public) role=\(role, privacy: .public) sha256=\(digest, privacy: .public) device=\(lease.device, privacy: .public) capacity=\(lease.capacityBytes, privacy: .public)")
            }
            Self.registryLock.withLock { Self.registry[registryID] = [pair.worker.id, pair.data.id] }
        } catch { release(); throw error }
    }

    func release() {
        let owned = lock.withLock { () -> ([Int32], [URL]) in
            guard pins == 0 else { return ([], []) }
            let value = (descriptors, scopes)
            descriptors.removeAll(); scopes.removeAll()
            return value
        }
        if !owned.0.isEmpty { _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: registryID) } }
        for descriptor in owned.0 { Darwin.close(descriptor) }
        for scope in owned.1 { scope.stopAccessingSecurityScopedResource() }
    }

    deinit { release() }
}
