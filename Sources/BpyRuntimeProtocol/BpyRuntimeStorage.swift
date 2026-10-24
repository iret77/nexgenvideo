import Darwin
import Foundation

public struct BpyStorageLease: Codable, Sendable, Equatable {
    public let id: UUID
    public let mountPath: String
    public let device: UInt64
    public let capacityBytes: UInt64
    public let bookmark: Data

    public init(id: UUID, mountPath: String, device: UInt64, capacityBytes: UInt64, bookmark: Data) {
        self.id = id
        self.mountPath = mountPath
        self.device = device
        self.capacityBytes = capacityBytes
        self.bookmark = bookmark
    }
}

public struct BpyStoragePreparation: Codable, Sendable, Equatable {
    public let id: UUID
    public let servicePID: Int32
    public let serviceStart: UInt64
    public let inUseStorageIDs: [UUID]

    public init(id: UUID, servicePID: Int32, serviceStart: UInt64, inUseStorageIDs: [UUID]) {
        self.id = id
        self.servicePID = servicePID
        self.serviceStart = serviceStart
        self.inUseStorageIDs = inUseStorageIDs
    }
}

public enum BpyStoragePaths {
    public static func bookmarkVolumeMatch(_ data: Data, mount: URL) -> String {
        guard let recorded = URL.resourceValues(forKeys: [.volumeUUIDStringKey], fromBookmarkData: data)?
            .volumeUUIDString else { return "absent" }
        guard let recordedID = UUID(uuidString: recorded) else { return "invalid" }
        guard let live = try? URL(fileURLWithPath: mount.path)
            .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              let liveID = UUID(uuidString: live) else { return "unavailable" }
        return recordedID == liveID ? "equal" : "different"
    }

    public static func mount(home: URL, serviceName: String) -> URL {
        home.appendingPathComponent("Library/Caches/NexGenVideo/BpyVolumes")
            .appendingPathComponent(serviceName).appendingPathComponent("mount")
    }

    public static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        for component in url.path.split(separator: "/") {
            guard component != ".", component != ".." else { throw CocoaError(.fileReadInvalidFileName) }
        }
        // A directory scope grants its subtree, not read access to its ancestors.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    public static func validateResolvedMount(_ lease: BpyStorageLease, resolved: URL, maximumBytes: UInt64) throws -> Int32 {
        guard resolved.isFileURL, resolved.path == lease.mountPath,
              bookmarkVolumeMatch(lease.bookmark, mount: resolved) == "equal" else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try validateMount(lease, maximumBytes: maximumBytes)
    }

    public static func identity(_ descriptor: Int32) throws -> (device: UInt64, inode: UInt64) {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadNoPermission)
        }
        return (UInt64(UInt32(bitPattern: value.st_dev)), value.st_ino)
    }

    public static func validateMount(_ lease: BpyStorageLease, maximumBytes: UInt64) throws -> Int32 {
        let descriptor = try openDirectory(URL(fileURLWithPath: lease.mountPath))
        do {
            let identity = try identity(descriptor)
            var filesystem = statfs()
            guard fstatfs(descriptor, &filesystem) == 0 else { throw POSIXError(.EIO) }
            let capacity = filesystem.f_blocks.multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
            let type = withUnsafeBytes(of: filesystem.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let mount = withUnsafeBytes(of: filesystem.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            guard !capacity.overflow, capacity.partialValue > 0,
                  capacity.partialValue == lease.capacityBytes, capacity.partialValue <= maximumBytes,
                  identity.device == lease.device, type == "apfs", mount == lease.mountPath else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
