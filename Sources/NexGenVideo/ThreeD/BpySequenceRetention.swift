import BpyRuntimeProtocol
import Darwin
import Foundation

nonisolated final class BpySequenceDiskLedger: @unchecked Sendable {
    struct Entry: Sendable {
        let owner: UUID
        let device: UInt64
        var occupied: UInt64
        var planned: UInt64
    }

    static let shared = BpySequenceDiskLedger()
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func reserve(owner: UUID, root: URL, occupied: UInt64 = 0, planned: UInt64) throws -> UUID {
        let descriptor = try BpyStoragePaths.openDirectory(root)
        defer { Darwin.close(descriptor) }
        let device = try BpyStoragePaths.identity(descriptor).device
        let id = UUID()
        try lock.withLock {
            try requireSpace(descriptor: descriptor, device: device, planned: planned)
            entries[id] = .init(owner: owner, device: device, occupied: occupied, planned: planned)
        }
        return id
    }

    func update(_ id: UUID, root: URL, occupied: UInt64, planned: UInt64) throws {
        let descriptor = try BpyStoragePaths.openDirectory(root)
        defer { Darwin.close(descriptor) }
        let device = try BpyStoragePaths.identity(descriptor).device
        try lock.withLock {
            guard var entry = entries[id], entry.device == device else { throw SpatialSceneError.changed }
            entry.occupied = occupied; entry.planned = 0; entries[id] = entry
            try requireSpace(descriptor: descriptor, device: device, planned: planned)
            entry.planned = planned; entries[id] = entry
        }
    }

    private func requireSpace(descriptor: Int32, device: UInt64, planned: UInt64) throws {
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { throw POSIXError(.EIO) }
        let available = filesystem.f_bavail.multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
        let reserved = entries.values.filter { $0.device == device }.reduce(UInt64(0)) { $0 + $1.planned }
        guard !available.overflow, reserved <= available.partialValue, planned <= available.partialValue - reserved else {
            throw SpatialSceneError.invalid("The Clay sequence needs \(planned) more bytes of temporary storage; \(available.partialValue > reserved ? available.partialValue - reserved : 0) bytes are available.")
        }
    }

    func release(_ id: UUID) { _ = lock.withLock { entries.removeValue(forKey: id) } }
    var snapshot: [Entry] { lock.withLock { Array(entries.values) } }
}

nonisolated final class BpySequenceRetention: @unchecked Sendable {
    fileprivate final class Directory: @unchecked Sendable {
        let root: URL
        private let lock = NSLock()
        private var tokens = Set<UUID>()
        private var closing = false
        init(root: URL) { self.root = root }
        func insert(_ id: UUID) { lock.withLock { _ = tokens.insert(id) } }
        func disposed(_ id: UUID) {
            let remove = lock.withLock { tokens.remove(id); return closing && tokens.isEmpty }
            if remove { _ = rmdir(root.path) }
        }
        func close() {
            let remove = lock.withLock { closing = true; return tokens.isEmpty }
            if remove { _ = rmdir(root.path) }
        }
    }

    private let lock = NSLock()
    private let directory: Directory
    private let owner = UUID()
    let workOwner: UUID
    private let ledger = BpySequenceDiskLedger.shared
    private var files: [URL: BpyRuntimeFile] = [:]
    private var released = false

    init(root: URL, workOwner: UUID = UUID()) { directory = Directory(root: root); self.workOwner = workOwner }

    final class Encoding: @unchecked Sendable {
        let url: URL
        let workOwner: UUID
        private let directory: Directory
        private let reservation: UUID
        private let frameBytes: UInt64
        private let ledger = BpySequenceDiskLedger.shared
        private var transferred = false
        private let stateLock = NSLock()
        private var writers = 0
        private var abandonRequested = false

        fileprivate init(directory: Directory, owner: UUID, workOwner: UUID, frameBytes: UInt64) throws {
            self.directory = directory; self.frameBytes = frameBytes; self.workOwner = workOwner
            reservation = try ledger.reserve(owner: owner, root: directory.root, planned: frameBytes)
            directory.insert(reservation)
            url = directory.root.appendingPathComponent("encoding-" + reservation.uuidString + ".mov")
        }

        func checkSize(planningFrame: Bool = true) throws {
            var value = stat()
            let result = lstat(url.path, &value)
            let bytes: UInt64
            if result == 0 {
                guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(), value.st_nlink == 1, value.st_size >= 0 else {
                    throw SpatialSceneError.changed
                }
                bytes = UInt64(value.st_size)
            } else if errno == ENOENT { bytes = 0 }
            else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try ledger.update(reservation, root: directory.root, occupied: bytes, planned: planningFrame ? frameBytes : 0)
        }

        func finish() throws -> BpyRuntimeFile {
            guard stateLock.withLock({ writers == 0 && !abandonRequested && !transferred }) else { throw SpatialSceneError.changed }
            try checkSize(planningFrame: false)
            let ledger = ledger, directory = directory, reservation = reservation
            let file = try BpyRuntimeFile.adoptCompleted(at: url) { removed, _ in
                if removed { ledger.release(reservation); directory.disposed(reservation) }
            }
            stateLock.withLock { transferred = true }
            return file
        }

        func abandon() {
            let remove = stateLock.withLock {
                guard !transferred else { return false }
                abandonRequested = true
                guard writers == 0 else { return false }
                transferred = true
                return true
            }
            guard remove else { return }
            let ledger = ledger, directory = directory, reservation = reservation
            BpyStagingCleanup.shared.discard(url) { ledger.release(reservation); directory.disposed(reservation) }
        }

        func retainForIO() throws -> BpyMediaFilePin {
            try stateLock.withLock {
                guard !transferred, !abandonRequested else { throw SpatialSceneError.changed }
                writers += 1
            }
            return BpyMediaFilePin { [self] in
                let dispose = stateLock.withLock { writers -= 1; return writers == 0 && abandonRequested }
                if dispose { abandon() }
            }
        }
        deinit { abandon() }
    }

    func encoding(width: Int, height: Int) throws -> Encoding {
        try lock.withLock {
            guard !released, width > 0, height > 0 else { throw SpatialSceneError.changed }
            return try Encoding(directory: directory, owner: owner, workOwner: workOwner, frameBytes: UInt64(width) * UInt64(height) * 4)
        }
    }

    func copy(_ source: BpyRuntimeFile, to destination: URL) throws {
        try create(bytes: source.byteCount) { disposed in
            try source.copy(to: destination, maximum: source.byteCount, disposed: disposed)
        }
    }

    func copy(_ data: Data, to destination: URL) throws {
        try create(bytes: UInt64(data.count)) { disposed in
            try BpyRuntimeFile.copy(data: data, to: destination, maximum: UInt64(data.count), disposed: disposed)
        }
    }

    func adopt(_ file: BpyRuntimeFile) throws {
        try lock.withLock {
            guard !released else { throw SpatialSceneError.changed }
            guard files[file.url] == nil else { throw SpatialSceneError.changed }
            files[file.url] = try file.retained()
        }
    }

    private func create(bytes: UInt64, operation: (@escaping @Sendable (Bool, BpyRuntimeFileIdentity) -> Void) throws -> BpyRuntimeFile) throws {
        try lock.withLock {
            guard !released else { throw SpatialSceneError.changed }
            let ledger = ledger, directory = directory
            let reservation = try ledger.reserve(owner: owner, root: directory.root, planned: bytes)
            directory.insert(reservation)
            var created: BpyRuntimeFile?
            do {
                let file = try operation { removed, _ in
                    if removed { ledger.release(reservation); directory.disposed(reservation) }
                }
                created = file
                try ledger.update(reservation, root: directory.root, occupied: file.byteCount, planned: 0)
                files[file.url] = file
            } catch {
                if let created { created.release() }
                else if let failure = error as? BpyRuntimeFile.CreationError {
                    failure.cleanup.whenComplete { ledger.release(reservation); directory.disposed(reservation) }
                } else { ledger.release(reservation); directory.disposed(reservation) }
                throw error
            }
        }
    }

    func borrow() throws -> [BpyRuntimeFile] {
        try lock.withLock {
            guard !released else { throw SpatialSceneError.changed }
            return try files.values.map { try $0.retained() }
        }
    }

    func file(at url: URL) throws -> BpyRuntimeFile {
        try lock.withLock {
            guard !released, let file = files[url] else { throw SpatialSceneError.changed }
            return try file.retained()
        }
    }

    func release() {
        let owned = lock.withLock {
            released = true
            let owned = Array(files.values); files.removeAll()
            return owned
        }
        directory.close()
        for file in owned { file.release() }
    }
    deinit { release() }
}
