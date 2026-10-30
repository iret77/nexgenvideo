import Darwin
import Foundation

public final class BpyManifestReadBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: UInt64
    private var used: UInt64 = 0

    public init(capacity: UInt64) { self.capacity = capacity }
    public var reservedBytes: UInt64 { lock.withLock { used } }

    fileprivate func withReservation<Value>(_ bytes: UInt64, operation: () throws -> Value) throws -> Value {
        try lock.withLock {
            guard used <= capacity, bytes <= capacity - used else { throw CocoaError(.fileReadTooLarge) }
            used += bytes
        }
        defer { lock.withLock { used -= bytes } }
        return try operation()
    }
}

public enum BpyRuntimeManifest {
    public static func decode<Value: Decodable>(_ type: Value.Type, name: String, in root: URL,
                                                maximum: UInt64, budget: BpyManifestReadBudget) throws -> Value {
        guard !name.isEmpty, name != ".", name != "..", name == URL(fileURLWithPath: name).lastPathComponent,
              !name.utf8.contains(0) else { throw CocoaError(.fileReadInvalidFileName) }
        let parent = try BpyStoragePaths.openDirectory(root)
        defer { Darwin.close(parent) }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = UInt64(before.st_size)
        guard bytes <= maximum, bytes <= UInt64(Int.max) else { throw CocoaError(.fileReadTooLarge) }
        return try budget.withReservation(bytes) {
            var data = Data(count: Int(bytes))
            try data.withUnsafeMutableBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = pread(descriptor, buffer.baseAddress!.advanced(by: offset), min(65_536, buffer.count - offset), off_t(offset))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    offset += count
                }
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, after.st_mode & S_IFMT == S_IFREG, after.st_uid == before.st_uid,
                  after.st_nlink == 1, before.st_size == after.st_size, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try JSONDecoder().decode(type, from: data)
        }
    }
}
