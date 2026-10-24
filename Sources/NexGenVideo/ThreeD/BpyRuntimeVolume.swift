import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

private let storageBookmarkDiagnostics = CategoryLog("bpy-open")

@_silgen_name("proc_pid_rusage")
private func volumeProcessUsage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

enum BpyStorageRecoveryError: LocalizedError, Equatable {
    case pending, restartRequired, unverifiable

    var errorDescription: String? {
        switch self {
        case .pending:
            "A 3D storage operation is still running. Wait for it to finish, then retry cleanup."
        case .restartRequired:
            "A 3D storage operation stopped without a completion record. Save your projects and restart your Mac; the next launch will recover its reserved storage."
        case .unverifiable:
            "The 3D storage record cannot be verified. Its files were retained. Export diagnostics before changing the runtime storage."
        }
    }
}

final class BpyRuntimeVolume: @unchecked Sendable {
    private struct Record: Codable {
        let schema: String
        let id: UUID
        let serviceName: String
        let ownerPID: Int32
        let ownerStart: UInt64
        let bootSessionID: UUID
        var servicePID: Int32
        var serviceStart: UInt64
        let directoryDevice: UInt64
        let directoryInode: UInt64
        let directoryVolumeUUID: UUID
        let maximumBytes: UInt64
        var imageDevice: UInt64?
        var imageInode: UInt64?
        var lease: BpyStorageLease?
    }

    private static let coordination = NSLock()
    let lease: BpyStorageLease
    private let directory: URL
    private var record: Record
    private var released = false

    private init(lease: BpyStorageLease, directory: URL, record: Record) {
        self.lease = lease
        self.directory = directory
        self.record = record
    }

    static func create(preparation: BpyStoragePreparation, serviceName: String,
                       maximumBytes: UInt64, onClaim: @Sendable () -> Void = {}) throws -> BpyRuntimeVolume {
        coordination.lock()
        defer { coordination.unlock() }
        guard bpyRuntimeServiceNames.contains(serviceName), maximumBytes >= 64 * 1_024 * 1_024,
              maximumBytes <= 8 * 1_024 * 1_024 * 1_024,
              let ownerStart = start(getpid()), start(preparation.servicePID) == preparation.serviceStart else {
            throw BpyRuntimeError.unavailable("The 3D storage owner could not be verified.")
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NexGenVideo/BpyVolumes")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let baseFD = try BpyStoragePaths.openDirectory(base)
        defer { Darwin.close(baseFD) }
        _ = try BpyStoragePaths.identity(baseFD)
        let directory = base.appendingPathComponent(serviceName)
        var existing = stat()
        if fstatat(baseFD, serviceName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            try recover(directory: directory, current: preparation)
        } else if errno != ENOENT { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let pendingName = "pending-" + UUID().uuidString
        guard mkdirat(baseFD, pendingName, 0o700) == 0 else {
            throw BpyRuntimeError.unavailable("The 3D storage lease could not be prepared.")
        }
        let pendingDirectory = base.appendingPathComponent(pendingName)
        let directoryFD = try BpyStoragePaths.openDirectory(pendingDirectory)
        defer { Darwin.close(directoryFD) }
        let identity = try BpyStoragePaths.identity(directoryFD)
        var record = Record(schema: "nexgenvideo/bpy-storage/1", id: preparation.id,
                            serviceName: serviceName, ownerPID: getpid(), ownerStart: ownerStart,
                            bootSessionID: try BpyStorageJournal.bootSessionID(),
                            servicePID: preparation.servicePID, serviceStart: preparation.serviceStart,
                            directoryDevice: identity.device, directoryInode: identity.inode,
                            directoryVolumeUUID: try persistentVolumeID(pendingDirectory), maximumBytes: maximumBytes)
        guard mkdirat(directoryFD, "mount", 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try write(record, directory: pendingDirectory)
        guard renameatx_np(baseFD, pendingName, baseFD, serviceName, UInt32(RENAME_EXCL)) == 0 else {
            throw BpyRuntimeError.unavailable("Another host already owns this 3D runtime slot.")
        }
        onClaim()
        do {
            let mount = expectedMount(serviceName: serviceName)
            let image = directory.appendingPathComponent("runtime.sparseimage")
            _ = try command(["create", "-type", "SPARSE", "-fs", "APFS", "-sectors", "\(maximumBytes / 512)",
                             "-volname", "NexGenVideo Runtime", image.path], in: directory)
            let imageIdentity = try imageIdentity(in: directoryFD, maximumBytes: maximumBytes)
            record.imageDevice = imageIdentity.device
            record.imageInode = imageIdentity.inode
            try write(record, directory: directory)
            _ = try command(["attach", image.path, "-mountpoint", mount.path,
                             "-nobrowse", "-noautoopen", "-owners", "on", "-plist"], in: directory)
            let mountedFD = try BpyStoragePaths.openDirectory(mount)
            defer { Darwin.close(mountedFD) }
            let mountedIdentity = try BpyStoragePaths.identity(mountedFD)
            var filesystem = statfs()
            guard fstatfs(mountedFD, &filesystem) == 0 else { throw POSIXError(.EIO) }
            let capacity = filesystem.f_blocks.multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
            guard !capacity.overflow else { throw CocoaError(.fileReadTooLarge) }
            let bookmark: Data
            do {
                bookmark = try verifiedBookmark(for: mount, observed: { data, resolved, stale, attempt in
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    let volume = BpyStoragePaths.bookmarkVolumeMatch(data, mount: mount)
                    storageBookmarkDiagnostics.notice("bookmark.resolve id=\(preparation.id.uuidString) attempt=\(attempt) stale=\(stale) file=\(resolved.isFileURL) pathMatches=\(resolved.path == mount.path) sha256=\(digest) volumeMatch=\(volume)")
                })
            } catch {
                let failure = error as NSError
                storageBookmarkDiagnostics.notice("bookmark.fail id=\(preparation.id.uuidString) domain=\(failure.domain) code=\(failure.code)")
                throw error
            }
            let lease = BpyStorageLease(id: preparation.id, mountPath: mount.path,
                                        device: mountedIdentity.device, capacityBytes: capacity.partialValue,
                                        bookmark: bookmark)
            let checked = try BpyStoragePaths.validateMount(lease, maximumBytes: maximumBytes)
            Darwin.close(checked)
            record.lease = lease
            try write(record, directory: directory)
            guard try attachedDevice(image: image, mount: mount, directory: directory) != nil else {
                throw BpyRuntimeError.unavailable("The 3D mount is not attached to its exact owned image.")
            }
            return BpyRuntimeVolume(lease: lease, directory: directory, record: record)
        } catch {
            try? dispose(record: record, directory: directory)
            throw error
        }
    }

    static func verifiedBookmark(
        for url: URL,
        make: (URL) throws -> Data = {
            try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        resolve: (Data) throws -> (url: URL, stale: Bool) = {
            var stale = false
            let url = try URL(resolvingBookmarkData: $0,
                              options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale)
        },
        observed: (Data, URL, Bool, Int) -> Void = { _, _, _, _ in }
    ) throws -> Data {
        let original = try make(url)
        let first = try resolve(original)
        observed(original, first.url, first.stale, 1)
        guard first.url.isFileURL, first.url.path == url.path else {
            throw BpyRuntimeError.unavailable("3D storage resolves to another location. Export diagnostics before retrying.")
        }
        guard first.stale else { return original }
        let refreshed = try make(first.url)
        let second = try resolve(refreshed)
        observed(refreshed, second.url, second.stale, 2)
        guard !second.stale, second.url.isFileURL, second.url.path == url.path else {
            throw BpyRuntimeError.unavailable("3D storage could not be verified. Export diagnostics before retrying.")
        }
        return refreshed
    }

    func bindService(_ processIdentifier: Int32) throws {
        Self.coordination.lock()
        defer { Self.coordination.unlock() }
        guard !released, let started = Self.start(processIdentifier) else {
            throw BpyRuntimeError.unavailable("The 3D storage service owner is unavailable.")
        }
        record.servicePID = processIdentifier
        record.serviceStart = started
        try Self.write(record, directory: directory)
    }

    func release(serviceStopped: Bool, serviceProof: BpyStoragePreparation? = nil) throws {
        Self.coordination.lock()
        defer { Self.coordination.unlock() }
        guard !released else { return }
        guard serviceStopped || Self.start(record.servicePID) != record.serviceStart
            || (serviceProof?.servicePID == record.servicePID && serviceProof?.serviceStart == record.serviceStart
                && serviceProof?.inUseStorageIDs.contains(record.id) == false) else {
            throw BpyRuntimeError.unavailable("The 3D service still owns its runtime storage.")
        }
        try Self.dispose(record: record, directory: directory)
        released = true
    }

    func serviceReleasedForRecovery(_ proof: BpyStoragePreparation?, workerStopped: Bool) -> Bool {
        Self.coordination.lock()
        defer { Self.coordination.unlock() }
        guard let proof, !proof.inUseStorageIDs.contains(record.id) else { return false }
        return (proof.servicePID == record.servicePID && proof.serviceStart == record.serviceStart)
            || (workerStopped && Self.start(record.servicePID) != record.serviceStart)
    }

    static func releasePrepared(_ preparation: BpyStoragePreparation, serviceName: String,
                                serviceStopped: Bool, serviceProof: BpyStoragePreparation? = nil) throws {
        coordination.lock()
        defer { coordination.unlock() }
        guard bpyRuntimeServiceNames.contains(serviceName) else {
            throw BpyRuntimeError.unavailable("The 3D storage slot is unknown.")
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NexGenVideo/BpyVolumes/" + serviceName)
        var status = stat()
        if lstat(directory.path, &status) != 0 {
            guard errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return
        }
        let descriptor = try BpyStoragePaths.openDirectory(directory)
        defer { Darwin.close(descriptor) }
        let record = try readRecord(directoryFD: descriptor)
        guard record.id == preparation.id, record.ownerPID == getpid(),
              record.bootSessionID == (try BpyStorageJournal.bootSessionID()) else { return }
        guard record.schema == "nexgenvideo/bpy-storage/1", record.serviceName == serviceName,
              start(record.ownerPID) == record.ownerStart,
              record.servicePID == preparation.servicePID, record.serviceStart == preparation.serviceStart,
              (64 * 1_024 * 1_024...8 * 1_024 * 1_024 * 1_024).contains(record.maximumBytes),
              serviceStopped || start(record.servicePID) != record.serviceStart
                || (serviceProof?.servicePID == record.servicePID && serviceProof?.serviceStart == record.serviceStart
                    && serviceProof?.inUseStorageIDs.contains(record.id) == false) else {
            throw BpyRuntimeError.unavailable("An unfinished 3D storage lease needs recovery before this slot can be reused.")
        }
        try dispose(record: record, directory: directory)
    }

    private static func recover(directory: URL, current: BpyStoragePreparation) throws {
        let descriptor = try BpyStoragePaths.openDirectory(directory)
        defer { Darwin.close(descriptor) }
        let identity = try BpyStoragePaths.identity(descriptor)
        let record = try readRecord(directoryFD: descriptor)
        let previousBoot = record.bootSessionID != (try BpyStorageJournal.bootSessionID())
        guard record.schema == "nexgenvideo/bpy-storage/1", record.serviceName == directory.lastPathComponent,
              (previousBoot || record.directoryDevice == identity.device), record.directoryInode == identity.inode,
              record.directoryVolumeUUID == (try persistentVolumeID(directory)),
              (64 * 1_024 * 1_024...8 * 1_024 * 1_024 * 1_024).contains(record.maximumBytes),
              previousBoot || start(record.ownerPID) != record.ownerStart,
              (previousBoot || start(record.servicePID) != record.serviceStart
                || (record.servicePID == current.servicePID && record.serviceStart == current.serviceStart
                    && !current.inUseStorageIDs.contains(record.id))) else {
            throw BpyRuntimeError.unavailable("A live or unverified 3D storage lease prevents another runtime allocation.")
        }
        try dispose(record: record, directory: directory)
    }

    private static func dispose(record: Record, directory: URL) throws {
        let descriptor = try BpyStoragePaths.openDirectory(directory)
        defer { Darwin.close(descriptor) }
        let identity = try BpyStoragePaths.identity(descriptor)
        let previousBoot = record.bootSessionID != (try BpyStorageJournal.bootSessionID())
        guard (previousBoot || identity.device == record.directoryDevice), identity.inode == record.directoryInode,
              record.directoryVolumeUUID == (try persistentVolumeID(directory)) else {
            throw BpyRuntimeError.unavailable("The 3D storage directory changed; it was left untouched.")
        }
        try requireOperationStopped(directoryFD: descriptor)
        var imageStatus = stat()
        if fstatat(descriptor, "runtime.sparseimage", &imageStatus, AT_SYMLINK_NOFOLLOW) == 0 {
            let imageIdentity = try imageIdentity(in: descriptor, maximumBytes: record.maximumBytes)
            guard (record.imageDevice == nil && record.imageInode == nil)
                || ((previousBoot || imageIdentity.device == record.imageDevice) && imageIdentity.inode == record.imageInode) else {
                throw BpyRuntimeError.unavailable("The 3D storage image changed; it was left untouched.")
            }
        } else if errno != ENOENT || record.imageInode != nil {
            throw BpyRuntimeError.unavailable("The 3D storage image disappeared before cleanup.")
        }
        let mount = expectedMount(serviceName: record.serviceName)
        let image = directory.appendingPathComponent("runtime.sparseimage")
        if let device = try attachedDevice(image: image, mount: mount, directory: directory) {
            if let lease = record.lease {
                let checked = try BpyStoragePaths.validateMount(lease, maximumBytes: record.maximumBytes)
                Darwin.close(checked)
            }
            _ = try command(["detach", device], in: directory)
            guard try attachedDevice(image: image, mount: mount, directory: directory) == nil else {
                throw BpyRuntimeError.unavailable("The 3D volume remains attached.")
            }
        }
        let mountFD = try BpyStoragePaths.openDirectory(mount)
        defer { Darwin.close(mountFD) }
        var filesystem = statfs()
        guard fstatfs(mountFD, &filesystem) == 0 else { throw POSIXError(.EIO) }
        let actualMount = withUnsafeBytes(of: filesystem.f_mntonname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        guard actualMount != mount.path else {
            throw BpyRuntimeError.unavailable("A different volume occupies the 3D mount point.")
        }
        for name in ["runtime.sparseimage", "lease.json", "command.out", "command.err", "operation.json", "operation.partial", "operation.lock"] {
            var info = stat()
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                      unlinkat(descriptor, name, 0) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            } else if errno != ENOENT { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        guard unlinkat(descriptor, "mount", AT_REMOVEDIR) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard rmdir(directory.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private static func readRecord(directoryFD: Int32) throws -> Record {
        do {
            return try JSONDecoder().decode(Record.self, from: readRegular("lease.json", directoryFD: directoryFD, maximum: 16_384))
        } catch {
            NSLog("3D storage lease verification failed: %@", error.localizedDescription)
            throw BpyStorageRecoveryError.unverifiable
        }
    }

    private static func persistentVolumeID(_ directory: URL) throws -> UUID {
        guard let text = try directory.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              let identifier = UUID(uuidString: text) else { throw BpyStorageRecoveryError.unverifiable }
        return identifier
    }

    private static func expectedMount(serviceName: String) -> URL {
        BpyStoragePaths.mount(home: FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath(),
                              serviceName: serviceName)
    }

    private static func write(_ record: Record, directory: URL) throws {
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("lease.json"), options: .atomic)
    }

    private static func imageIdentity(in descriptor: Int32, maximumBytes: UInt64) throws -> (device: UInt64, inode: UInt64) {
        var value = stat()
        guard fstatat(descriptor, "runtime.sparseimage", &value, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(), value.st_nlink == 1,
              value.st_size > 0, UInt64(value.st_size) <= maximumBytes + 64 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (UInt64(UInt32(bitPattern: value.st_dev)), value.st_ino)
    }

    private static func readRegular(_ name: String, directoryFD: Int32, maximum: Int) throws -> Data {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_uid == getuid(), value.st_size >= 0, value.st_size <= maximum else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count == value.st_size else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    private static func attachedDevice(image: URL, mount: URL, directory: URL) throws -> String? {
        let data = try command(["info", "-plist"], in: directory)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        let matches = images.filter { ($0["image-path"] as? String) == image.path }
        guard matches.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
        guard let match = matches.first else { return nil }
        guard let entities = match["system-entities"] as? [[String: Any]],
              entities.compactMap({ $0["mount-point"] as? String }).allSatisfy({ $0 == mount.path }),
              let device = entities.first?["dev-entry"] as? String,
              device.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil else {
            throw BpyRuntimeError.unavailable("The 3D disk image has an unexpected device or mount mapping.")
        }
        return device
    }

    private static func command(_ arguments: [String], in directory: URL) throws -> Data {
        let descriptor = try BpyStoragePaths.openDirectory(directory)
        defer { Darwin.close(descriptor) }
        let operationID = UUID()
        let bootID = try BpyStorageJournal.bootSessionID()
        guard let ownerStart = start(getpid()) else { throw BpyRuntimeError.unavailable("The 3D storage host is unavailable.") }
        let intent = BpyStorageOperation(id: operationID, bootSessionID: bootID, pid: 0, start: 0,
                                         completed: false, ownerPID: getpid(), ownerStart: ownerStart)
        do {
            let journalLock = try storageLock(directoryFD: descriptor)
            defer { Darwin.close(journalLock) }
            try requireOperationStoppedLocked(directoryFD: descriptor)
            try BpyStorageJournal.write(intent, directoryFD: descriptor)
        }
        var launched = false
        defer { if !launched { try? completeUnstartedIntent(intent, directoryFD: descriptor) } }
        func output(_ name: String) throws -> FileHandle {
            let fd = openat(descriptor, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        let standardOutput = try output("command.out")
        let standardError = try output("command.err")
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NexGenVideoBpyStorage")
        process.environment = [:]
        let identity = try BpyStoragePaths.identity(descriptor)
        process.arguments = [directory.path, String(getpid()), String(ownerStart),
                             String(identity.device), String(identity.inode), operationID.uuidString, bootID.uuidString] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = standardError
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do { try process.run(); launched = true }
        catch {
            try completeUnstartedIntent(intent, directoryFD: descriptor)
            throw error
        }
        if completed.wait(timeout: .now() + 30) != .success {
            recordCommandFailure(arguments.first ?? "unknown", status: nil, reason: nil, operationID: operationID, directoryFD: descriptor)
            throw BpyRuntimeError.unavailable("The 3D storage operation is still pending; its lease remains reserved until completion.")
        }
        guard process.terminationStatus == 0 else {
            recordCommandFailure(arguments.first ?? "unknown", status: process.terminationStatus, reason: process.terminationReason, operationID: operationID, directoryFD: descriptor)
            try completeUnstartedIntent(intent, directoryFD: descriptor)
            try requireOperationStopped(directoryFD: descriptor)
            throw BpyRuntimeError.unavailable("The 3D runtime storage operation failed (\(process.terminationStatus)).")
        }
        try standardOutput.close()
        try standardError.close()
        return try readRegular("command.out", directoryFD: descriptor, maximum: 1_048_576)
    }

    private static func recordCommandFailure(_ command: String, status: Int32?, reason: Process.TerminationReason?, operationID: UUID, directoryFD: Int32) {
        var record: [String: Any] = ["schema": 1, "command": command, "operationID": operationID.uuidString,
            "pid": getpid(), "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? ""]
        record["status"] = status
        record["terminationReason"] = reason.map { $0 == .exit ? "exit" : "signal" }
        record["completed"] = status != nil
        for name in ["command.out", "command.err"] {
            do {
                let (data, truncated) = try readCommandDiagnostic(name, directoryFD: directoryFD)
                record[name] = data.base64EncodedString()
                record[name + ".truncated"] = truncated
                if name == "command.err" {
                    Log.app.error("3D storage \(command) failed: \(String(decoding: data.prefix(16_384), as: UTF8.self))", telemetry: "bpy-storage-command-failed")
                }
            } catch { record[name + ".captureError"] = error.localizedDescription }
        }
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let path = ProcessInfo.processInfo.environment["NGV_BPY_COMMAND_EVIDENCE"] else { return }
        do {
            let url = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("storage-\(operationID.uuidString).json")
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: url, options: .atomic)
        } catch { Log.app.error("3D storage diagnostics could not be saved: \(error.localizedDescription)", telemetry: "bpy-storage-diagnostics-write-failed") }
    }

    private static func readCommandDiagnostic(_ name: String, directoryFD: Int32) throws -> (Data, Bool) {
        let descriptor = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_nlink == 1, value.st_uid == getuid() else { throw CocoaError(.fileReadNoPermission) }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        return (Data(data.prefix(1_048_576)), data.count > 1_048_576)
    }

    private static func storageLock(directoryFD: Int32) throws -> Int32 {
        do { return try BpyStorageJournal.lock(directoryFD: directoryFD) }
        catch let error as POSIXError where error.code == .EWOULDBLOCK { throw BpyStorageRecoveryError.pending }
    }

    private static func completeUnstartedIntent(_ intent: BpyStorageOperation, directoryFD: Int32) throws {
        let journalLock = try storageLock(directoryFD: directoryFD)
        defer { Darwin.close(journalLock) }
        guard try BpyStorageJournal.read(directoryFD: directoryFD) == intent else { return }
        try BpyStorageJournal.write(.init(id: intent.id, bootSessionID: intent.bootSessionID, pid: 0, start: 0,
            completed: true, ownerPID: intent.ownerPID, ownerStart: intent.ownerStart), directoryFD: directoryFD)
    }

    private static func requireOperationStopped(directoryFD: Int32) throws {
        let journalLock = try storageLock(directoryFD: directoryFD)
        defer { Darwin.close(journalLock) }
        try requireOperationStoppedLocked(directoryFD: directoryFD)
    }

    private static func requireOperationStoppedLocked(directoryFD: Int32) throws {
        let operation: BpyStorageOperation?
        do { operation = try BpyStorageJournal.read(directoryFD: directoryFD) }
        catch { throw BpyStorageRecoveryError.unverifiable }
        guard let operation else { return }
        try requireStopped(operation, currentBoot: BpyStorageJournal.bootSessionID(), processStart: start)
    }

    static func requireStopped(_ operation: BpyStorageOperation, currentBoot: UUID,
                               processStart: (Int32) -> UInt64?) throws {
        guard operation.ownerPID > 1, operation.ownerStart > 0 else { throw BpyStorageRecoveryError.unverifiable }
        if operation.bootSessionID != currentBoot { return }
        if operation.pid == 0, operation.start == 0 {
            guard operation.completed || processStart(operation.ownerPID) != operation.ownerStart else {
                throw BpyStorageRecoveryError.pending
            }
            return
        }
        guard operation.pid > 1, operation.start > 0 else { throw BpyStorageRecoveryError.unverifiable }
        guard processStart(operation.pid) != operation.start else { throw BpyStorageRecoveryError.pending }
        guard operation.completed else { throw BpyStorageRecoveryError.restartRequired }
    }

    private static func start(_ pid: Int32) -> UInt64? {
        guard pid > 1 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
        guard volumeProcessUsage(pid, 4, buffer) == 0 else { return nil }
        return buffer.load(fromByteOffset: 80, as: UInt64.self)
    }
}
