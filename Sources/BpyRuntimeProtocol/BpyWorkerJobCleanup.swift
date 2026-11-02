import Darwin
import Foundation

public enum BpyWorkerJobCleanup {
    public static func removeJob(_ id: UUID, in root: URL, device: UInt64) throws {
        try withJobs(in: root, device: device) { jobs in
            try id.uuidString.withCString { try remove($0, parent: jobs, device: device) }
        }
    }

    public static func removeAllJobs(in root: URL, device: UInt64) throws {
        try withJobs(in: root, device: device) { jobs in
            var names: [[CChar]] = []
            try forEachName(jobs) { name in
                guard let value = String(validatingCString: name), UUID(uuidString: value) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                names.append(Array(UnsafeBufferPointer(start: name, count: strlen(name) + 1)))
            }
            for name in names {
                try name.withUnsafeBufferPointer { try remove($0.baseAddress!, parent: jobs, device: device) }
            }
        }
    }

    private static func withJobs(in root: URL, device: UInt64, body: (Int32) throws -> Void) throws {
        let parent: Int32
        do { parent = try BpyStoragePaths.openDirectory(root) }
        catch let error as POSIXError where error.code == .ENOENT {
            let mount = try BpyStoragePaths.openDirectory(root.deletingLastPathComponent())
            defer { Darwin.close(mount) }
            try requireDirectory(mount, device: device)
            return
        }
        defer { Darwin.close(parent) }
        try requireDirectory(parent, device: device)
        let jobs = openat(parent, "jobs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard jobs >= 0 else {
            if errno == ENOENT { return }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(jobs) }
        try requireDirectory(jobs, device: device)
        try body(jobs)
    }

    private static func requireOwner(_ value: stat, device: UInt64) throws {
        guard value.st_uid == getuid(), UInt64(UInt32(bitPattern: value.st_dev)) == device else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private static func requireDirectory(_ descriptor: Int32, device: UInt64) throws {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try requireOwner(value, device: device)
        guard value.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadCorruptFile) }
    }

    private static func requireIdentity(_ name: UnsafePointer<CChar>, parent: Int32, expected: stat) throws {
        var linked = stat()
        guard fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              linked.st_dev == expected.st_dev, linked.st_ino == expected.st_ino,
              linked.st_uid == expected.st_uid, linked.st_mode & S_IFMT == expected.st_mode & S_IFMT else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private struct Level {
        let name: [CChar]
        let ancestor: stat
        let opened: stat
        var pending: [[CChar]]
    }

    private static func remove(_ name: UnsafePointer<CChar>, parent: Int32, device: UInt64) throws {
        var current = fcntl(parent, F_DUPFD_CLOEXEC, 0)
        guard current >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(current) }
        var levels: [Level] = []
        var pending: [CChar]? = Array(UnsafeBufferPointer(start: name, count: strlen(name) + 1))
        while true {
            if let name = pending {
                pending = nil
                guard levels.count < 512 else { throw CocoaError(.fileReadTooLarge) }
                try name.withUnsafeBufferPointer { bytes in
                    let entry = bytes.baseAddress!
                    var before = stat()
                    guard fstatat(current, entry, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                        if errno == ENOENT { return }
                        throw POSIXError(.init(rawValue: errno) ?? .EIO)
                    }
                    try requireOwner(before, device: device)
                    guard before.st_mode & S_IFMT == S_IFDIR else {
                        guard unlinkat(current, entry, 0) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                        return
                    }
                    var ancestor = stat()
                    guard fstat(current, &ancestor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    var child = openat(current, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if child < 0, errno == EACCES || errno == EPERM {
                        try requireIdentity(entry, parent: current, expected: before)
                        // The job's processes have stopped before permission repair.
                        guard fchmodat(current, entry, 0o700, AT_SYMLINK_NOFOLLOW) == 0 else {
                            throw POSIXError(.init(rawValue: errno) ?? .EIO)
                        }
                        child = openat(current, entry, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard child >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    var opened = stat()
                    var names: [[CChar]] = []
                    do {
                        try requireDirectory(child, device: device)
                        guard fstat(child, &opened) == 0, opened.st_ino == before.st_ino, opened.st_dev == before.st_dev else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        if opened.st_mode & 0o700 != 0o700 {
                            guard fchmod(child, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                        }
                        try forEachName(child) { names.append(Array(UnsafeBufferPointer(start: $0, count: strlen($0) + 1))) }
                    } catch {
                        Darwin.close(child)
                        throw error
                    }
                    Darwin.close(current)
                    current = child
                    levels.append(.init(name: name, ancestor: ancestor, opened: opened, pending: names))
                }
                continue
            }
            guard let index = levels.indices.last else { return }
            if let entry = levels[index].pending.popLast() {
                pending = entry
                continue
            }
            let level = levels[index]
            let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            do {
                try requireDirectory(parent, device: device)
                var returned = stat()
                guard fstat(parent, &returned) == 0, returned.st_dev == level.ancestor.st_dev,
                      returned.st_ino == level.ancestor.st_ino, returned.st_uid == level.ancestor.st_uid,
                      returned.st_mode & S_IFMT == level.ancestor.st_mode & S_IFMT else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try level.name.withUnsafeBufferPointer { try requireIdentity($0.baseAddress!, parent: parent, expected: level.opened) }
            } catch {
                Darwin.close(parent)
                throw error
            }
            Darwin.close(current)
            current = parent
            try level.name.withUnsafeBufferPointer {
                guard unlinkat(current, $0.baseAddress!, AT_REMOVEDIR) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            }
            levels.removeLast()
        }
    }

    private static func forEachName(_ descriptor: Int32, body: (UnsafePointer<CChar>) throws -> Void) throws {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard let directory = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                return
            }
            try withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                let name = bytes.bindMemory(to: CChar.self).baseAddress!
                if name[0] == 46, name[1] == 0 || (name[1] == 46 && name[2] == 0) { return }
                try body(name)
            }
        }
    }
}
