import CryptoKit
import Darwin
import Foundation

public struct BpyRuntimeFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let bytes: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    fileprivate init(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(),
              value.st_nlink == 1, value.st_size >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        device = UInt64(UInt32(bitPattern: value.st_dev)); inode = value.st_ino; bytes = UInt64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

public final class BpyRuntimeFile: @unchecked Sendable {
    public final class Cleanup: @unchecked Sendable {
        public let id = UUID()
        private let lock = NSLock()
        private var completed = false
        private var callbacks: [@Sendable () -> Void] = []

        public func whenComplete(_ callback: @escaping @Sendable () -> Void) {
            let call = lock.withLock {
                if completed { return true }
                callbacks.append(callback)
                return false
            }
            if call { callback() }
        }

        fileprivate func finish() {
            let actions = lock.withLock {
                completed = true
                let actions = callbacks; callbacks.removeAll()
                return actions
            }
            for action in actions { action() }
        }
    }

    public struct CreationError: LocalizedError {
        public let underlying: any Error
        public let cleanup: Cleanup
        public var errorDescription: String? { underlying.localizedDescription }
    }

    private final class Removal: @unchecked Sendable {
        let descriptor: Int32
        let parent: Int32
        let name: String
        let cleanup = Cleanup()
        private var descriptorsUncertain = false

        init(descriptor: Int32, parent: Int32, name: String) {
            self.descriptor = descriptor; self.parent = parent; self.name = name
        }

        func attempt() -> Bool {
            guard !descriptorsUncertain else { return false }
            var owned = stat(), linked = stat()
            guard fstat(descriptor, &owned) == 0, owned.st_mode & S_IFMT == S_IFREG,
                  owned.st_uid == getuid() else { return false }
            if owned.st_nlink != 0 {
                guard owned.st_nlink == 1, fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                      linked.st_mode & S_IFMT == S_IFREG, linked.st_uid == owned.st_uid,
                      linked.st_dev == owned.st_dev, linked.st_ino == owned.st_ino,
                      unlinkat(parent, name, 0) == 0 else { return false }
            }
            let closed = Darwin.close(descriptor)
            let parentClosed = Darwin.close(parent)
            guard closed == 0, parentClosed == 0 else { descriptorsUncertain = true; return false }
            cleanup.finish()
            return true
        }
    }

    private final class Recovery: @unchecked Sendable {
        static let shared = Recovery()
        private let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.files.recovery", qos: .utility)
        private var pending: [UUID: Removal] = [:]
        private var timer: DispatchSourceTimer?

        func retain(_ removal: Removal) {
            queue.async { [self] in
                pending[removal.cleanup.id] = removal
                guard timer == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
                timer.setEventHandler { [weak self] in self?.retry() }
                self.timer = timer
                timer.resume()
            }
        }

        private func retry() {
            for (id, removal) in pending where removal.attempt() { pending.removeValue(forKey: id) }
            if pending.isEmpty { timer?.cancel(); timer = nil }
        }
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        let descriptor: Int32
        let parent: Int32
        let name: String
        let identity: BpyRuntimeFileIdentity
        let sha256: String
        let url: URL
        let disposed: @Sendable (Bool, BpyRuntimeFileIdentity) -> Void
        var owners = 0
        var readers = 0
        var closing = false
        var removesFile = true

        init(descriptor: Int32, parent: Int32, name: String, identity: BpyRuntimeFileIdentity,
             sha256: String, url: URL, disposed: @escaping @Sendable (Bool, BpyRuntimeFileIdentity) -> Void) {
            self.descriptor = descriptor; self.parent = parent; self.name = name; self.identity = identity
            self.sha256 = sha256; self.url = url; self.disposed = disposed
        }

        func retainOwner() throws {
            try lock.withLock {
                guard !closing else { throw CocoaError(.fileReadNoSuchFile) }
                owners += 1
            }
        }

        func releaseOwner() {
            lock.withLock { owners -= 1 }
            disposeIfUnused()
        }

        func disposeIfUnused() {
            let dispose = lock.withLock {
                guard owners == 0, readers == 0, !closing else { return false }
                closing = true
                return true
            }
            guard dispose else { return }
            DispatchQueue.global(qos: .utility).async { [self] in
                if !removesFile {
                    let closed = Darwin.close(descriptor), parentClosed = Darwin.close(parent)
                    disposed(closed == 0 && parentClosed == 0, identity)
                    return
                }
                let removal = Removal(descriptor: descriptor, parent: parent, name: name)
                removal.cleanup.whenComplete { [disposed, identity] in disposed(true, identity) }
                if !removal.attempt() {
                    disposed(false, identity)
                    Recovery.shared.retain(removal)
                }
            }
        }

        func read(offset: UInt64, maximum: Int) throws -> Data {
            try lock.withLock {
                guard !closing else { throw CocoaError(.fileReadNoSuchFile) }
                readers += 1
            }
            defer {
                lock.withLock { readers -= 1 }
                disposeIfUnused()
            }
            guard maximum >= 0, maximum <= 4 * 1_024 * 1_024, offset <= identity.bytes,
                  offset <= UInt64(Int64.max) else { throw CocoaError(.fileReadTooLarge) }
            var before = stat()
            guard fstat(descriptor, &before) == 0,
                  try BpyRuntimeFileIdentity(before) == identity else { throw CocoaError(.fileReadCorruptFile) }
            let count = min(maximum, Int(identity.bytes - offset))
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { bytes in
                var received = 0
                while received < count {
                    let actual = pread(descriptor, bytes.baseAddress!.advanced(by: received), count - received, off_t(offset) + off_t(received))
                    if actual < 0 && errno == EINTR { continue }
                    guard actual > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    received += actual
                }
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  try BpyRuntimeFileIdentity(after) == identity else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
    }

    private let lock = NSLock()
    private let storage: Storage
    private var released = false
    public var identity: BpyRuntimeFileIdentity { storage.identity }
    public var sha256: String { storage.sha256 }
    public var url: URL { storage.url }
    public var byteCount: UInt64 { storage.identity.bytes }

    private init(storage: Storage) throws {
        self.storage = storage
        try storage.retainOwner()
    }

    public func retained() throws -> BpyRuntimeFile {
        try lock.withLock {
            guard !released else { throw CocoaError(.fileReadNoSuchFile) }
            return try BpyRuntimeFile(storage: storage)
        }
    }

    public func release() {
        let release = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if release { storage.releaseOwner() }
    }

    public func read(offset: UInt64 = 0, maximum: Int) throws -> Data {
        let retained = try self.retained()
        defer { retained.release() }
        return try storage.read(offset: offset, maximum: maximum)
    }

    public func withDescriptor<Value>(_ operation: (Int32) throws -> Value) throws -> Value {
        let held = try retained()
        defer { held.release() }
        var value = stat()
        guard fstat(storage.descriptor, &value) == 0, try BpyRuntimeFileIdentity(value) == identity else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try operation(storage.descriptor)
    }

    public func verify(checking: () throws -> Void = {}) throws {
        let retained = try self.retained()
        defer { retained.release() }
        var digest = SHA256(), offset: UInt64 = 0
        while offset < byteCount {
            try checking()
            let chunk = try storage.read(offset: offset, maximum: min(65_536, Int(byteCount - offset)))
            digest.update(data: chunk); offset += UInt64(chunk.count)
            BpyRuntimeHashObservation.chunk(device: identity.device, inode: identity.inode, bytes: byteCount, hashedBytes: offset)
        }
        guard Self.hex(digest.finalize()) == sha256 else { throw CocoaError(.fileReadCorruptFile) }
        try checking()
    }

    public func verifiedData(maximum: UInt64, preallocate: Bool = true, checking: () throws -> Void = {}) throws -> Data {
        guard byteCount <= maximum, byteCount <= UInt64(Int.max) else { throw CocoaError(.fileReadTooLarge) }
        let retained = try self.retained()
        defer { retained.release() }
        var value = Data(), digest = SHA256(), offset: UInt64 = 0
        if preallocate { value.reserveCapacity(Int(byteCount)) }
        while offset < byteCount {
            try checking()
            let chunk = try storage.read(offset: offset, maximum: min(65_536, Int(byteCount - offset)))
            value.append(chunk); digest.update(data: chunk); offset += UInt64(chunk.count)
        }
        guard Self.hex(digest.finalize()) == sha256 else { throw CocoaError(.fileReadCorruptFile) }
        try checking()
        return value
    }

    public static func borrow(_ relativePath: String, in root: URL, maximum: UInt64,
                              expectedSHA256: String, checking: () throws -> Void = {}) throws -> BpyRuntimeFile {
        try checking()
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.utf8.contains(0) }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var descriptor: Int32 = -1
        do {
            for component in components.dropLast() {
                let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                Darwin.close(parent); parent = next
            }
            let name = components.last!
            descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { throw POSIXError(.EIO) }
            let identity = try BpyRuntimeFileIdentity(value)
            guard identity.bytes <= maximum else { throw CocoaError(.fileReadTooLarge) }
            let storage = Storage(descriptor: descriptor, parent: parent, name: name, identity: identity,
                sha256: expectedSHA256, url: root.appendingPathComponent(relativePath), disposed: { _, _ in })
            storage.removesFile = false
            let file = try BpyRuntimeFile(storage: storage)
            descriptor = -1; parent = -1
            try file.verify(checking: checking)
            return file
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if parent >= 0 { Darwin.close(parent) }
            throw error
        }
    }

    public static func export(data: Data, to destination: URL, checking: () throws -> Void = {}) throws {
        let file = try copy(data: data, to: destination, maximum: UInt64(data.count), checking: checking)
        file.storage.lock.withLock { file.storage.removesFile = false }
        file.release()
    }

    public static func digest(at url: URL, checking: () throws -> Void = {}) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var before = stat(), after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var digest = SHA256(), offset: Int64 = 0
        while offset < before.st_size {
            try checking()
            let count = Int(min(65_536, Int64(before.st_size) - offset))
            var chunk = Data(count: count)
            try chunk.withUnsafeMutableBytes { buffer in
                var received = 0
                while received < count {
                    let result = pread(descriptor, buffer.baseAddress!.advanced(by: received), count - received, off_t(offset) + off_t(received))
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    received += result
                }
            }
            digest.update(data: chunk); offset += Int64(count)
            BpyRuntimeHashObservation.chunk(device: UInt64(UInt32(bitPattern: before.st_dev)), inode: before.st_ino,
                bytes: UInt64(before.st_size), hashedBytes: UInt64(offset))
        }
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw CocoaError(.fileReadCorruptFile) }
        return hex(digest.finalize())
    }

    public static func adoptCompleted(at url: URL,
        disposed: @escaping @Sendable (Bool, BpyRuntimeFileIdentity) -> Void
    ) throws -> BpyRuntimeFile {
        let parent = try BpyStoragePaths.openDirectory(url.deletingLastPathComponent())
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { Darwin.close(parent); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        do {
            guard fchmod(descriptor, 0o400) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { throw POSIXError(.EIO) }
            let identity = try BpyRuntimeFileIdentity(value)
            var digest = SHA256(), offset: UInt64 = 0
            while offset < identity.bytes {
                let count = min(65_536, Int(min(identity.bytes - offset, UInt64(Int.max))))
                var chunk = Data(count: count)
                try chunk.withUnsafeMutableBytes { buffer in
                    var received = 0
                    while received < count {
                        let result = pread(descriptor, buffer.baseAddress!.advanced(by: received), count - received, off_t(offset) + off_t(received))
                        if result < 0 && errno == EINTR { continue }
                        guard result > 0 else { throw CocoaError(.fileReadCorruptFile) }
                        received += result
                    }
                }
                digest.update(data: chunk); offset += UInt64(count)
            }
            guard fstat(descriptor, &value) == 0, try BpyRuntimeFileIdentity(value) == identity else { throw CocoaError(.fileReadCorruptFile) }
            return try BpyRuntimeFile(storage: Storage(descriptor: descriptor, parent: parent, name: url.lastPathComponent,
                identity: identity, sha256: hex(digest.finalize()), url: url, disposed: disposed))
        } catch { Darwin.close(descriptor); Darwin.close(parent); throw error }
    }

    public static func discardOwned(at url: URL, completion: @escaping @Sendable () -> Void) throws {
        let parent = try BpyStoragePaths.openDirectory(url.deletingLastPathComponent())
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let absent = errno == ENOENT
            let closed = Darwin.close(parent)
            if absent && closed == 0 { completion(); return }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let removal = Removal(descriptor: descriptor, parent: parent, name: url.lastPathComponent)
        removal.cleanup.whenComplete(completion)
        if !removal.attempt() { Recovery.shared.retain(removal) }
    }

    public func export(to destination: URL, checking: () throws -> Void = {}) throws {
        let source = try retained()
        defer { source.release() }
        let copy = try Self.create(at: destination, byteCount: byteCount, expectedSHA256: sha256,
            disposed: { _, _ in }) { offset, count in
                try checking()
                return try source.read(offset: offset, maximum: count)
            }
        copy.storage.lock.withLock { copy.storage.removesFile = false }
        copy.release()
    }

    public static func copy(from source: URL, to destination: URL, maximum: UInt64,
                            expectedSHA256: String? = nil,
                            disposed: @escaping @Sendable (Bool, BpyRuntimeFileIdentity) -> Void = { _, _ in }) throws -> BpyRuntimeFile {
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw POSIXError(.EIO) }
        let identity = try BpyRuntimeFileIdentity(value)
        guard identity.bytes <= maximum else { throw CocoaError(.fileReadTooLarge) }
        return try create(at: destination, byteCount: identity.bytes, expectedSHA256: expectedSHA256, disposed: disposed) { offset, count in
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { bytes in
                var received = 0
                while received < count {
                    let actual = pread(descriptor, bytes.baseAddress!.advanced(by: received), count - received, off_t(offset) + off_t(received))
                    if actual < 0 && errno == EINTR { continue }
                    guard actual > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    received += actual
                }
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  try BpyRuntimeFileIdentity(after) == identity else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
    }

    public func copy(to destination: URL, maximum: UInt64,
                     checking: () throws -> Void = {},
                     disposed: @escaping @Sendable (Bool, BpyRuntimeFileIdentity) -> Void = { _, _ in }) throws -> BpyRuntimeFile {
        guard byteCount <= maximum else { throw CocoaError(.fileReadTooLarge) }
        let owner = try retained()
        defer { owner.release() }
        return try Self.create(at: destination, byteCount: byteCount, expectedSHA256: sha256,
            disposed: disposed) { offset, count in
                try checking()
                return try owner.read(offset: offset, maximum: count)
            }
    }

    public static func copy(data: Data, to destination: URL, maximum: UInt64,
                            checking: () throws -> Void = {},
                            disposed: @escaping @Sendable (Bool, BpyRuntimeFileIdentity) -> Void = { _, _ in }) throws -> BpyRuntimeFile {
        guard UInt64(data.count) <= maximum else { throw CocoaError(.fileReadTooLarge) }
        return try create(at: destination, byteCount: UInt64(data.count), expectedSHA256: nil, disposed: disposed) { offset, count in
            try checking()
            return data.subdata(in: Int(offset)..<(Int(offset) + count))
        }
    }

    public static func receive(at destination: URL, byteCount: UInt64, expectedSHA256: String,
                               disposed: @escaping @Sendable (Bool, BpyRuntimeFileIdentity) -> Void,
                               read: (UInt64, Int) throws -> Data) throws -> BpyRuntimeFile {
        try create(at: destination, byteCount: byteCount, expectedSHA256: expectedSHA256, disposed: disposed, read: read)
    }

    private static func create(at destination: URL, byteCount: UInt64, expectedSHA256: String?,
                               disposed: @escaping @Sendable (Bool, BpyRuntimeFileIdentity) -> Void,
                               read: (UInt64, Int) throws -> Data) throws -> BpyRuntimeFile {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = try BpyStoragePaths.openDirectory(directory)
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(0), !name.contains("/") else {
            Darwin.close(parent); throw CocoaError(.fileWriteInvalidFileName)
        }
        let temporary = UUID().uuidString + ".part"
        let writer = openat(parent, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard writer >= 0 else { Darwin.close(parent); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var published = false
        do {
            var digest = SHA256(), offset: UInt64 = 0
            while offset < byteCount {
                let count = min(65_536, Int(byteCount - offset))
                let chunk = try read(offset, count)
                guard chunk.count == count else { throw CocoaError(.fileReadCorruptFile) }
                try chunk.withUnsafeBytes { bytes in
                    var written = 0
                    while written < count {
                        let result = Darwin.write(writer, bytes.baseAddress!.advanced(by: written), count - written)
                        if result < 0 && errno == EINTR { continue }
                        guard result > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                        written += result
                    }
                }
                digest.update(data: chunk); offset += UInt64(chunk.count)
            }
            let hash = hex(digest.finalize())
            guard expectedSHA256 == nil || expectedSHA256 == hash else { throw CocoaError(.fileReadCorruptFile) }
            guard fchmod(writer, 0o400) == 0, fsync(writer) == 0, renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            published = true
            let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { Darwin.close(descriptor); throw POSIXError(.EIO) }
            let identity: BpyRuntimeFileIdentity
            do { identity = try BpyRuntimeFileIdentity(value) }
            catch { Darwin.close(descriptor); throw error }
            guard identity.bytes == byteCount else { Darwin.close(descriptor); throw CocoaError(.fileReadCorruptFile) }
            let file = try BpyRuntimeFile(storage: Storage(descriptor: descriptor, parent: parent, name: name,
                identity: identity, sha256: hash, url: destination, disposed: disposed))
            Darwin.close(writer)
            return file
        } catch {
            let removal = Removal(descriptor: writer, parent: parent, name: published ? name : temporary)
            if !removal.attempt() {
                Recovery.shared.retain(removal)
                throw CreationError(underlying: error, cleanup: removal.cleanup)
            }
            throw error
        }
    }

    private static func hex(_ value: SHA256.Digest) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }

    deinit { release() }
}
