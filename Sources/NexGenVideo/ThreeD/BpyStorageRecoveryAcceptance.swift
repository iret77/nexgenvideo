import BpyRuntimeProtocol
import Darwin
import Foundation

@_silgen_name("proc_pid_rusage")
private func recoveryProcessUsage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

nonisolated enum BpyStorageRecoveryAcceptance {
    static func run(output: URL) async throws -> [String: Bool] {
        try await Task.detached {
            let root = output.appendingPathComponent("storage-recovery")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let descriptor = try BpyStoragePaths.openDirectory(root)
            defer { Darwin.close(descriptor) }
            let lookup = try verifyDirectoryLookup(root: root)
            let boot = try BpyStorageJournal.bootSessionID()
            guard boot == (try BpyStorageJournal.bootSessionID()), let ownerStart = start(getpid()) else {
                throw SpatialSceneError.invalid("Native storage boot/process identity is unavailable.")
            }
            let identity = try BpyStoragePaths.identity(descriptor)
            func intent() -> BpyStorageOperation {
                .init(id: UUID(), bootSessionID: boot, pid: 0, start: 0, completed: false,
                      ownerPID: getpid(), ownerStart: ownerStart)
            }
            func write(_ value: BpyStorageOperation) throws {
                let lock = try BpyStorageJournal.lock(directoryFD: descriptor)
                defer { Darwin.close(lock) }
                try BpyStorageJournal.write(value, directoryFD: descriptor)
            }
            func invoke(_ value: BpyStorageOperation, crash: Bool, name: String) throws -> Int32 {
                let process = Process()
                process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NexGenVideoBpyStorage")
                process.arguments = [root.path, String(getpid()), String(ownerStart), String(identity.device), String(identity.inode),
                                     value.id.uuidString, boot.uuidString, "info", "-plist"]
                process.environment = crash ? ["NGV_BPY_STORAGE_CRASH_AFTER_JOURNAL": "1"] : [:]
                process.standardInput = FileHandle.nullDevice
                let log = root.appendingPathComponent(name + ".log")
                guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw SpatialSceneError.changed }
                let handle = try FileHandle(forWritingTo: log)
                defer { try? handle.close() }
                process.standardOutput = handle
                process.standardError = handle
                let completed = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in completed.signal() }
                try process.run()
                guard completed.wait(timeout: .now() + 30) == .success else {
                    throw SpatialSceneError.invalid("The native storage helper did not complete; its journal remains for recovery.")
                }
                return process.terminationStatus
            }
            let normal = intent()
            try write(normal)
            guard try invoke(normal, crash: false, name: "normal") == 0,
                  let finished = try BpyStorageJournal.read(directoryFD: descriptor), finished.id == normal.id,
                  finished.completed, finished.pid > 1 else { throw SpatialSceneError.invalid("The real storage helper did not record completion.") }
            guard let information = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("normal.log")),
                    format: nil) as? [String: Any], information["images"] is [[String: Any]] else {
                throw SpatialSceneError.invalid("The storage helper did not return actual hdiutil image information.")
            }
            try BpyRuntimeVolume.requireStopped(finished, currentBoot: boot, processStart: start)
            let replacement = intent()
            try write(replacement)
            guard try invoke(normal, crash: false, name: "late-helper") != 0,
                  try BpyStorageJournal.read(directoryFD: descriptor) == replacement else {
                throw SpatialSceneError.invalid("A stale storage helper overwrote a newer operation intent.")
            }
            do {
                let lock = try BpyStorageJournal.lock(directoryFD: descriptor)
                defer { Darwin.close(lock) }
                guard try invoke(replacement, crash: false, name: "locked-helper") != 0,
                      try BpyStorageJournal.read(directoryFD: descriptor) == replacement else {
                    throw SpatialSceneError.invalid("A storage helper bypassed the journal lock.")
                }
            }
            guard try invoke(replacement, crash: true, name: "crashed-helper") != 0,
                  let crashed = try BpyStorageJournal.read(directoryFD: descriptor), crashed.id == replacement.id,
                  !crashed.completed, crashed.pid > 1, start(crashed.pid) != crashed.start else {
                throw SpatialSceneError.invalid("The native storage crash fixture did not retain its actual incomplete journal.")
            }
            var retained = false
            do { try BpyRuntimeVolume.requireStopped(crashed, currentBoot: boot, processStart: start) }
            catch BpyStorageRecoveryError.restartRequired { retained = true }
            guard retained, try BpyStorageJournal.read(directoryFD: descriptor) == crashed else {
                throw SpatialSceneError.invalid("A crashed same-boot operation was released without completion.")
            }
            return lookup.merging(["bootIdentityRead": true, "normalHelperCompletion": true,
                    "staleHelperRejected": true, "journalLockEnforced": true, "crashedHelperRetained": true]) { _, new in new }
        }.value
    }

    private static func verifyDirectoryLookup(root: URL) throws -> [String: Bool] {
        let target = root.appendingPathComponent("directory-target")
        let child = target.appendingPathComponent("child")
        let alias = root.appendingPathComponent("directory-alias")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        for candidate in [alias, alias.appendingPathComponent("child")] {
            var rejected = false
            do {
                let opened = try BpyStoragePaths.openDirectory(candidate)
                Darwin.close(opened)
            } catch let error as POSIXError where error.code == .ELOOP { rejected = true }
            guard rejected else { throw SpatialSceneError.invalid("The kernel followed a storage directory symlink.") }
        }
        let file = root.appendingPathComponent("regular-file")
        try Data([1]).write(to: file)
        var rejectedFile = false
        do {
            let opened = try BpyStoragePaths.openDirectory(file)
            Darwin.close(opened)
        } catch let error as POSIXError where error.code == .ENOTDIR { rejectedFile = true }
        guard rejectedFile else { throw SpatialSceneError.invalid("A regular file opened as a storage directory.") }
        guard chmod(target.path, 0o100) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = chmod(target.path, 0o700) }
        let opened = try BpyStoragePaths.openDirectory(child)
        defer { Darwin.close(opened) }
        let identity = try BpyStoragePaths.identity(opened)
        var actual = stat()
        guard stat(child.path, &actual) == 0, identity.inode == actual.st_ino,
              identity.device == UInt64(UInt32(bitPattern: actual.st_dev)) else {
            throw SpatialSceneError.invalid("A search-only ancestor changed storage directory identity.")
        }
        return ["ancestorSymlinkRejected": true, "leafSymlinkRejected": true,
                "regularFileRejected": true, "searchOnlyAncestorOpened": true]
    }

    private static func start(_ pid: Int32) -> UInt64? {
        guard pid > 1 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
        guard recoveryProcessUsage(pid, 4, buffer) == 0 else { return nil }
        return buffer.load(fromByteOffset: 80, as: UInt64.self)
    }
}
