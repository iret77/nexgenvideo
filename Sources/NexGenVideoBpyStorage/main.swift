import BpyRuntimeProtocol
import Darwin
import Foundation

@_silgen_name("proc_pid_rusage")
private func procPIDRusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

private enum StorageCommandError: Error { case invalidArguments, invalidParent }

private func processStartAbsoluteTime(_ pid: Int32) -> UInt64? {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
    defer { buffer.deallocate() }
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
    guard procPIDRusage(pid, 4, buffer) == 0 else { return nil }
    return buffer.load(fromByteOffset: 80, as: UInt64.self)
}

private func parentIsAlive(_ pid: Int32, startAbsoluteTime: UInt64) -> Bool {
    getppid() == pid && processStartAbsoluteTime(pid) == startAbsoluteTime
}

private func runStorageCommand(arguments: [String]) throws -> Int32 {
    guard arguments.count >= 8, let owner = Int32(arguments[1]), let ownerStart = UInt64(arguments[2]),
          let device = UInt64(arguments[3]), let inode = UInt64(arguments[4]),
          let operationID = UUID(uuidString: arguments[5]), let bootID = UUID(uuidString: arguments[6]),
          ["create", "attach", "detach", "info"].contains(arguments[7]),
          let started = processStartAbsoluteTime(getpid()) else {
        throw StorageCommandError.invalidArguments
    }
    let directory = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let descriptor = try BpyStoragePaths.openDirectory(directory)
    let actual = try BpyStoragePaths.identity(descriptor)
    var identity = stat()
    guard fstat(descriptor, &identity) == 0, actual.device == device, actual.inode == inode,
          identity.st_uid == getuid(), identity.st_mode & 0o077 == 0 else {
        Darwin.close(descriptor)
        throw StorageCommandError.invalidArguments
    }
    defer { Darwin.close(descriptor) }
    let journalLock = try BpyStorageJournal.lock(directoryFD: descriptor)
    defer { Darwin.close(journalLock) }
    guard bootID == (try BpyStorageJournal.bootSessionID()),
          let intent = try BpyStorageJournal.read(directoryFD: descriptor), intent.id == operationID,
          intent.bootSessionID == bootID, intent.ownerPID == owner, intent.ownerStart == ownerStart,
          intent.pid == 0, intent.start == 0, !intent.completed,
          parentIsAlive(owner, startAbsoluteTime: ownerStart) else { throw StorageCommandError.invalidParent }
    func journal(completed: Bool) throws {
        try BpyStorageJournal.write(.init(id: operationID, bootSessionID: bootID, pid: getpid(), start: started,
            completed: completed, ownerPID: owner, ownerStart: ownerStart), directoryFD: descriptor)
    }
    try journal(completed: false)
    if ProcessInfo.processInfo.environment["NGV_BPY_STORAGE_CRASH_AFTER_JOURNAL"] == "1",
       Array(arguments.dropFirst(7)) == ["info", "-plist"] {
        kill(getpid(), SIGKILL)
        Darwin.exit(71)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = Array(arguments.dropFirst(7))
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do { try process.run() }
    catch { try journal(completed: true); throw error }
    process.waitUntilExit()
    guard process.terminationReason == .exit else {
        throw StorageCommandError.invalidArguments
    }
    try journal(completed: true)
    return process.terminationStatus
}

do {
    Darwin.exit(try runStorageCommand(arguments: Array(CommandLine.arguments.dropFirst())))
} catch {
    FileHandle.standardError.write(Data("3D storage command failed: \(error)\n".utf8))
    Darwin.exit(70)
}
