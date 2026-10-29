import Darwin
import Foundation

public struct BpyStorageOperation: Codable, Sendable, Equatable {
    public let id: UUID
    public let bootSessionID: UUID
    public let pid: Int32
    public let start: UInt64
    public let completed: Bool
    public let ownerPID: Int32
    public let ownerStart: UInt64

    public init(id: UUID, bootSessionID: UUID, pid: Int32, start: UInt64, completed: Bool,
                ownerPID: Int32, ownerStart: UInt64) {
        self.id = id; self.bootSessionID = bootSessionID; self.pid = pid; self.start = start
        self.completed = completed; self.ownerPID = ownerPID; self.ownerStart = ownerStart
    }
}

public enum BpyStorageJournal {
    public static func bootSessionID() throws -> UUID {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0, (1...128).contains(count) else {
            throw POSIXError(.EIO)
        }
        var bytes = [CChar](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &count, nil, 0) }
        guard result == 0, bytes.contains(0), let id = UUID(uuidString: String(cString: bytes)) else { throw POSIXError(.EIO) }
        return id
    }

    public static func lock(directoryFD: Int32) throws -> Int32 {
        let descriptor = openat(directoryFD, "operation.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == getuid(), value.st_nlink == 1, value.st_mode & 0o077 == 0 else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    public static func read(directoryFD: Int32) throws -> BpyStorageOperation? {
        let descriptor = openat(directoryFD, "operation.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(),
              value.st_nlink == 1, (0...4_096).contains(value.st_size) else { throw CocoaError(.fileReadCorruptFile) }
        let data = try handle.read(upToCount: 4_097) ?? Data()
        guard data.count == value.st_size else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(BpyStorageOperation.self, from: data)
    }

    public static func write(_ operation: BpyStorageOperation, directoryFD: Int32) throws {
        if unlinkat(directoryFD, "operation.partial", 0) != 0, errno != ENOENT { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let descriptor = openat(directoryFD, "operation.partial", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        let data = try JSONEncoder().encode(operation)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(descriptor) == 0, renameat(directoryFD, "operation.partial", directoryFD, "operation.json") == 0,
              fsync(directoryFD) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}
