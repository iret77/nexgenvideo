import BpyRuntimeProtocol
import Darwin
import Foundation

nonisolated final class BpyHostStaging: @unchecked Sendable {
    private struct RecoveryFailure: LocalizedError {
        let namespace: URL
        let entry: URL
        let reason: String
        var errorDescription: String? {
            "3D storage recovery stopped at \(entry.path): \(reason). Quit NexGenVideo, move \(namespace.path) aside, then reopen the project."
        }
    }

    private struct Record: Codable {
        let schema: String
        let id: UUID
        let uid: UInt32
        let pid: Int32
        let start: UInt64
        let boot: UUID
        let device: UInt64
        let inode: UInt64
    }

    static let shared = BpyHostStaging()
    private let lock = NSLock()
    private let id = UUID()
    private let base: URL
    private var prepared = false
    private var rootIdentity: (device: UInt64, inode: UInt64)?

    init(base: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NexGenVideo/BpyHostStaging")) { self.base = base }

    private var root: URL { base.appendingPathComponent(id.uuidString) }

    func location(_ name: String) -> URL { root.appendingPathComponent(name) }

    func prepare() throws {
        try lock.withLock {
            if prepared {
                let descriptor = try BpyStoragePaths.openDirectory(root)
                defer { Darwin.close(descriptor) }
                try requireDirectory(descriptor)
                let identity = try BpyStoragePaths.identity(descriptor)
                guard identity.device == rootIdentity?.device, identity.inode == rootIdentity?.inode else { throw CocoaError(.fileReadCorruptFile) }
                return
            }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let descriptor = try BpyStoragePaths.openDirectory(base)
            defer { Darwin.close(descriptor) }
            try requireDirectory(descriptor)
            let coordination = try BpyStorageJournal.lock(directoryFD: descriptor)
            defer { Darwin.close(coordination) }
            let boot = try BpyStorageJournal.bootSessionID()
            do { try recover(base: descriptor, boot: boot) }
            catch let failure as RecoveryFailure { throw failure }
            catch {
                throw BpyRuntimeError.unavailable("Temporary 3D storage could not be recovered. Its remaining files were retained. Export runtime diagnostics before retrying.")
            }
            guard let process = try BpyKernelInspection.identity(getpid()) else { throw POSIXError(.ESRCH) }
            let pending = "pending-" + id.uuidString
            guard mkdirat(descriptor, pending, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let child = openat(descriptor, pending, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(child) }
            let identity = try BpyStoragePaths.identity(child)
            let record = Record(schema: "nexgenvideo/bpy-host-staging/1", id: id, uid: getuid(), pid: getpid(),
                start: process.start, boot: boot, device: identity.device, inode: identity.inode)
            let output = openat(child, "owner.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            do {
                let data = try JSONEncoder().encode(record)
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                        offset += count
                    }
                }
                guard fsync(output) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            } catch { Darwin.close(output); throw error }
            guard Darwin.close(output) == 0, fsync(child) == 0,
                  renameatx_np(descriptor, pending, descriptor, id.uuidString, UInt32(RENAME_EXCL)) == 0,
                  fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            rootIdentity = identity
            prepared = true
        }
    }

    func directory(_ name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        try prepare()
        let descriptor = try BpyStoragePaths.openDirectory(root)
        defer { Darwin.close(descriptor) }
        guard mkdirat(descriptor, name, 0o700) == 0 || errno == EEXIST else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(child) }
        try requireDirectory(child)
        return location(name)
    }

    func removeEmpty(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let descriptor: Int32
        do { descriptor = try BpyStoragePaths.openDirectory(root) }
        catch let error as POSIXError where error.code == .ENOENT { return }
        defer { Darwin.close(descriptor) }
        var value = stat()
        guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try removeDirectory(name, parent: descriptor, device: UInt64(UInt32(bitPattern: value.st_dev)), deletingFiles: false)
    }

    private func recover(base descriptor: Int32, boot: UUID) throws {
        for name in try names(descriptor) where name != "operation.lock" {
            let pending = name.hasPrefix("pending-") && UUID(uuidString: String(name.dropFirst(8))) != nil
            guard pending || UUID(uuidString: name) != nil else { continue }
            do { try recoverNamespace(name, pending: pending, descriptor: descriptor, boot: boot) }
            catch let failure as RecoveryFailure { throw failure }
            catch {
                let namespace = base.appendingPathComponent(name)
                throw RecoveryFailure(namespace: namespace, entry: namespace, reason: error.localizedDescription)
            }
        }
    }

    private func recoverNamespace(_ name: String, pending: Bool, descriptor: Int32, boot: UUID) throws {
        let namespace = base.appendingPathComponent(name)
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw RecoveryFailure(namespace: namespace, entry: namespace, reason: "Not an accessible owned directory") }
        defer { Darwin.close(child) }
        try requireDirectory(child)
        if pending {
            guard try names(child).allSatisfy({ $0 == "owner.json" }) else {
                throw RecoveryFailure(namespace: namespace, entry: namespace, reason: "Incomplete namespace contains unrecognized files")
            }
            let device = try BpyStoragePaths.identity(descriptor).device
            try removeDirectory(name, parent: descriptor, device: device, deletingFiles: true, namespace: namespace)
            return
        }
        let record: Record
        do { record = try readRecord(child) }
        catch { throw RecoveryFailure(namespace: namespace, entry: namespace.appendingPathComponent("owner.json"), reason: "Missing or invalid ownership record") }
        let identity = try BpyStoragePaths.identity(child)
        guard record.schema == "nexgenvideo/bpy-host-staging/1", record.id == UUID(uuidString: name), record.uid == getuid(),
              record.pid > 1, record.start > 0, record.device == identity.device, record.inode == identity.inode else {
            throw RecoveryFailure(namespace: namespace, entry: namespace.appendingPathComponent("owner.json"), reason: "Ownership or directory identity mismatch")
        }
        if record.boot == boot, try BpyKernelInspection.identity(record.pid)?.start == record.start { return }
        try removeDirectory(name, parent: descriptor, device: identity.device, deletingFiles: true, namespace: namespace)
    }

    private func readRecord(_ descriptor: Int32) throws -> Record {
        let file = openat(descriptor, "owner.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        defer { Darwin.close(file) }
        var value = stat()
        guard fstat(file, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(),
              value.st_nlink == 1, (1...4_096).contains(value.st_size) else { throw CocoaError(.fileReadCorruptFile) }
        let data = try FileHandle(fileDescriptor: file, closeOnDealloc: false).read(upToCount: 4_097) ?? Data()
        guard data.count == value.st_size else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    private func requireDirectory(_ descriptor: Int32) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFDIR,
              value.st_mode & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
    }

    private func names(_ descriptor: Int32) throws -> [String] {
        var result: [String] = []
        try forEachName(descriptor) { result.append($0) }
        return result
    }

    private func forEachName(_ descriptor: Int32, _ body: (String) throws -> Void) throws {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { closedir(directory) }
        rewinddir(directory)
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                return
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if name != ".", name != ".." { try body(name) }
        }
    }

    private func removeDirectory(_ name: String, parent: Int32, device: UInt64, deletingFiles: Bool,
                                 depth: Int = 0, namespace: URL? = nil) throws {
        guard depth < 64 else { throw CocoaError(.fileReadCorruptFile) }
        let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        defer { Darwin.close(child) }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(child, F_GETPATH, &path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let location = URL(fileURLWithPath: String(cString: path))
        func failure(_ entry: String, _ reason: String) -> any Error {
            guard deletingFiles else { return CocoaError(.fileWriteNoPermission) }
            return RecoveryFailure(namespace: namespace ?? location, entry: location.appendingPathComponent(entry), reason: reason)
        }
        try requireDirectory(child)
        guard try BpyStoragePaths.identity(child).device == device else { throw CocoaError(.fileReadCorruptFile) }
        let preserveRecord = depth == 0 && deletingFiles
        for _ in 0..<4 {
            let entries = try names(child).filter { !preserveRecord || $0 != "owner.json" }
            if entries.isEmpty { break }
            for entry in entries {
                var value = stat()
                guard fstatat(child, entry, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(entry, "Entry could not be inspected") }
                guard value.st_uid == getuid() else { throw failure(entry, "Entry belongs to another user") }
                guard UInt64(UInt32(bitPattern: value.st_dev)) == device else { throw failure(entry, "Entry is on another filesystem") }
                if value.st_mode & S_IFMT == S_IFDIR {
                    try removeDirectory(entry, parent: child, device: device, deletingFiles: deletingFiles, depth: depth + 1, namespace: namespace ?? location)
                } else {
                    guard value.st_mode & S_IFMT != S_IFLNK else { throw failure(entry, "Symbolic links are not followed") }
                    guard deletingFiles, value.st_mode & S_IFMT == S_IFREG else { throw failure(entry, "Entry is not a removable regular file") }
                    guard value.st_nlink == 1 else { throw failure(entry, "File has multiple hard links") }
                    guard unlinkat(child, entry, 0) == 0 else { throw failure(entry, "File could not be removed") }
                }
            }
        }
        guard try names(child).allSatisfy({ preserveRecord && $0 == "owner.json" }) else { throw POSIXError(.ENOTEMPTY) }
        if preserveRecord {
            guard unlinkat(child, "owner.json", 0) == 0 || errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
