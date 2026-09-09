import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class FileDigestReadinessCache: @unchecked Sendable {
    private struct Stamp: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modified: Int64
        let modifiedNanos: Int64
        let changed: Int64
        let changedNanos: Int64
    }
    private struct Entry {
        let stamp: Stamp
        let digest: String
        let access: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var access: UInt64 = 0
    private let capacity: Int

    public init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    func digest(of url: URL, read: (FileHandle) throws -> String) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let stamp = try Self.stamp(handle)
        let key = url.standardizedFileURL.path
        if let cached = lock.withLock({ () -> String? in
            guard let entry = entries[key], entry.stamp == stamp else { return nil }
            access &+= 1
            entries[key] = Entry(stamp: stamp, digest: entry.digest, access: access)
            return entry.digest
        }) { return cached }
        let digest = try read(handle)
        guard try Self.stamp(handle) == stamp else { throw CocoaError(.fileReadUnknown) }
        lock.withLock {
            access &+= 1
            entries[key] = Entry(stamp: stamp, digest: digest, access: access)
            if entries.count > capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
        return digest
    }

    private static func stamp(_ handle: FileHandle) throws -> Stamp {
        var value = stat()
        guard fstat(handle.fileDescriptor, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
        #if canImport(Darwin)
        let modified = value.st_mtimespec
        let changed = value.st_ctimespec
        #else
        let modified = value.st_mtim
        let changed = value.st_ctim
        #endif
        return Stamp(device: Int64(value.st_dev), inode: UInt64(value.st_ino), size: Int64(value.st_size),
            modified: Int64(modified.tv_sec), modifiedNanos: Int64(modified.tv_nsec),
            changed: Int64(changed.tv_sec), changedNanos: Int64(changed.tv_nsec))
    }
}
