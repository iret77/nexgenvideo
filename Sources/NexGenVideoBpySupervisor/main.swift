import Darwin
import Foundation

@_silgen_name("proc_pid_rusage")
private func procPIDRusage(
    _ processIdentifier: pid_t,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer
) -> Int32

@_silgen_name("fileport_makeport")
private func fileportMakePort(
    _ descriptor: Int32,
    _ port: UnsafeMutablePointer<mach_port_t>
) -> Int32

private typealias SandboxInit = @convention(c) (
    UnsafePointer<CChar>,
    UInt64,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

private typealias SandboxFreeError = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

private struct WorkerIdentity: Codable {
    let processIdentifier: Int32
    let startAbsoluteTime: UInt64
}

private struct BoundaryChildReport: Codable {
    let schema: String
    let mode: String
    let processIdentifier: Int32
    let parentProcessIdentifier: Int32
    let allowedWriteSucceeded: Bool
    let outsideWriteDeniedErrno: Int32
    let forkDeniedErrno: Int32
    let networkDeniedErrno: Int32
    let signalDeniedErrnos: [Int32]
    let resourceBytes: UInt64
    let retentionDeniedErrno: Int32
}

private let boundaryResourceBytes = 1_024 * 1_024
private let boundaryInternalResourceBytes = 128 * 1_024
private let boundaryResourceModes: Set<String> = [
    "open-unlinked-hold",
    "readonly-unlinked-hold",
    "mapped-unlinked-hold",
    "external-readonly-hold",
    "internal-linked-writable-hold",
    "fileport-unlinked-hold",
]

private struct BoundaryIdentity: Codable {
    let supervisorProcessIdentifier: Int32
    let supervisorParentProcessIdentifier: Int32
    let supervisorStartAbsoluteTime: UInt64
    let childProcessIdentifier: Int32
    let childStartAbsoluteTime: UInt64
}

nonisolated(unsafe) private var terminationRequested: sig_atomic_t = 0

private func requestTermination(_ signal: Int32) {
    terminationRequested = 1
}

private enum SupervisorError: Error {
    case invalidArguments
    case invalidParent
    case injectedIdentityWriteFailure
    case processLaunch
    case sandboxUnavailable
    case sandboxRejected(String)
}

private func processStartAbsoluteTime(_ processIdentifier: pid_t) -> UInt64? {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
    defer { buffer.deallocate() }
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
    guard procPIDRusage(processIdentifier, 4, buffer) == 0 else { return nil }
    return buffer.load(fromByteOffset: 80, as: UInt64.self)
}

private func parentIsAlive(_ processIdentifier: pid_t, startAbsoluteTime: UInt64) -> Bool {
    getppid() == processIdentifier
        && processStartAbsoluteTime(processIdentifier) == startAbsoluteTime
}

private func isAuthorized(at url: URL, token: String) -> Bool {
    var status = stat()
    guard lstat(url.path, &status) == 0,
          (status.st_mode & S_IFMT) == S_IFREG,
          status.st_nlink == 1,
          status.st_size == off_t(token.utf8.count),
          let data = try? Data(contentsOf: url),
          data == Data(token.utf8) else {
        return false
    }
    return true
}

private func sandboxSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
        return symbol
    }
    for path in [
        "/usr/lib/system/libsystem_sandbox.dylib",
        "/usr/lib/libsandbox.dylib",
    ] {
        if let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, name) {
            return symbol
        }
    }
    return nil
}

private func escapedSandboxLiteral(_ value: String) throws -> String {
    guard !value.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
        throw SupervisorError.invalidArguments
    }
    return value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func applyWorkerSandbox(writeRoot: URL) throws {
    guard let initSymbol = sandboxSymbol("sandbox_init") else {
        throw SupervisorError.sandboxUnavailable
    }
    let sandboxInit = unsafeBitCast(initSymbol, to: SandboxInit.self)
    let root = try escapedSandboxLiteral(writeRoot.resolvingSymlinksInPath().path)
    let profile = """
    (version 1)
    (allow default)
    (deny network*)
    (deny process-fork)
    (deny signal)
    (deny file-write*)
    (allow file-write* (literal "\(root)"))
    (allow file-write* (subpath "\(root)"))
    """
    var errorBuffer: UnsafeMutablePointer<CChar>?
    let result = profile.withCString { sandboxInit($0, 0, &errorBuffer) }
    guard result == 0 else {
        let message = errorBuffer.map { String(cString: $0) } ?? "unknown Seatbelt error"
        if let freeSymbol = sandboxSymbol("sandbox_free_error") {
            unsafeBitCast(freeSymbol, to: SandboxFreeError.self)(errorBuffer)
        }
        throw SupervisorError.sandboxRejected(message)
    }
}

private func execPython(arguments: [String]) throws -> Never {
    guard arguments.count == 5 else { throw SupervisorError.invalidArguments }
    let writeRoot = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
    let python = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let worker = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    let configuration = URL(fileURLWithPath: arguments[4]).standardizedFileURL
    guard writeRoot.path.hasPrefix("/"),
          FileManager.default.fileExists(atPath: writeRoot.path),
          FileManager.default.isExecutableFile(atPath: python.path),
          FileManager.default.fileExists(atPath: worker.path),
          FileManager.default.fileExists(atPath: configuration.path) else {
        throw SupervisorError.invalidArguments
    }
    if ProcessInfo.processInfo.environment["NGV_BPY_SUPERVISOR_CHILD_IGNORE_TERM"] == "1" {
        _ = Darwin.signal(SIGTERM, SIG_IGN)
        try Data().write(
            to: writeRoot.appendingPathComponent(".ngv-supervisor-child-term-ignored"),
            options: .atomic
        )
    }
    try applyWorkerSandbox(writeRoot: writeRoot)
    let values = [python.path, "-I", "-S", worker.path, arguments[3], configuration.path]
    let allocated = values.map { strdup($0) }
    defer { allocated.forEach { free($0) } }
    var pointers = allocated + [nil]
    pointers.withUnsafeMutableBufferPointer { buffer in
        _ = Darwin.execv(python.path, buffer.baseAddress!)
    }
    throw POSIXError(.init(rawValue: errno) ?? .EIO)
}

private func writeAll(_ descriptor: Int32, data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(
                descriptor,
                bytes.baseAddress!.advanced(by: offset),
                bytes.count - offset
            )
            guard written > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            offset += written
        }
    }
}

private func writeBoundaryResource(_ descriptor: Int32, byteCount: Int) throws {
    let chunk = Data(repeating: 0x5a, count: 64 * 1_024)
    for _ in 0..<(byteCount / chunk.count) {
        try writeAll(descriptor, data: chunk)
    }
    guard Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private func boundaryChild(arguments: [String]) throws -> Never {
    guard arguments.count == 4,
          arguments[3] == "denials" || boundaryResourceModes.contains(arguments[3]) else {
        throw SupervisorError.invalidArguments
    }
    let writeRoot = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
    let outsidePath = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let reportURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    let mode = arguments[3]
    guard reportURL.deletingLastPathComponent() == writeRoot,
          outsidePath.deletingLastPathComponent() != writeRoot else {
        throw SupervisorError.invalidArguments
    }
    if boundaryResourceModes.contains(mode) {
        _ = Darwin.signal(SIGTERM, SIG_IGN)
    }
    try applyWorkerSandbox(writeRoot: writeRoot)
    usleep(100_000)

    if boundaryResourceModes.contains(mode) {
        let path = mode == "external-readonly-hold"
            ? outsidePath.path
            : writeRoot.appendingPathComponent("retained-resource.bin").path
        var retainedDescriptor: Int32 = -1
        var retentionDeniedErrno: Int32 = 0
        var resourceBytes = boundaryResourceBytes
        if mode == "open-unlinked-hold" {
            retainedDescriptor = Darwin.open(
                path,
                O_CREAT | O_TRUNC | O_RDWR,
                S_IRUSR | S_IWUSR
            )
            guard retainedDescriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            guard Darwin.unlink(path) == 0 else {
                Darwin.close(retainedDescriptor)
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try writeBoundaryResource(retainedDescriptor, byteCount: resourceBytes)
        } else if mode == "readonly-unlinked-hold" || mode == "mapped-unlinked-hold" {
            let writer = Darwin.open(
                path,
                O_CREAT | O_TRUNC | O_RDWR,
                S_IRUSR | S_IWUSR
            )
            guard writer >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            do {
                try writeBoundaryResource(writer, byteCount: resourceBytes)
                Darwin.close(writer)
            } catch {
                Darwin.close(writer)
                throw error
            }
            retainedDescriptor = Darwin.open(path, O_RDONLY)
            guard retainedDescriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if mode == "mapped-unlinked-hold" {
                let mapping = Darwin.mmap(
                    nil,
                    boundaryResourceBytes,
                    PROT_READ,
                    MAP_PRIVATE,
                    retainedDescriptor,
                    0
                )
                guard let mapping,
                      mapping != UnsafeMutableRawPointer(bitPattern: -1) else {
                    Darwin.close(retainedDescriptor)
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                guard mapping.load(as: UInt8.self) == 0x5a else {
                    Darwin.close(retainedDescriptor)
                    throw CocoaError(.fileReadCorruptFile)
                }
                Darwin.close(retainedDescriptor)
                retainedDescriptor = -1
            }
            guard Darwin.unlink(path) == 0 else {
                if retainedDescriptor >= 0 { Darwin.close(retainedDescriptor) }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } else if mode == "external-readonly-hold" {
            retainedDescriptor = Darwin.open(path, O_RDONLY)
            guard retainedDescriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            var status = stat()
            guard Darwin.fstat(retainedDescriptor, &status) == 0,
                  status.st_size >= Int64(boundaryResourceBytes) else {
                Darwin.close(retainedDescriptor)
                throw CocoaError(.fileReadCorruptFile)
            }
        } else if mode == "internal-linked-writable-hold" {
            resourceBytes = boundaryInternalResourceBytes
            retainedDescriptor = Darwin.open(
                path,
                O_CREAT | O_TRUNC | O_RDWR,
                S_IRUSR | S_IWUSR
            )
            guard retainedDescriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try writeBoundaryResource(retainedDescriptor, byteCount: resourceBytes)
        } else {
            retainedDescriptor = Darwin.open(
                path,
                O_CREAT | O_TRUNC | O_RDWR,
                S_IRUSR | S_IWUSR
            )
            guard retainedDescriptor >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try writeBoundaryResource(retainedDescriptor, byteCount: resourceBytes)
            guard Darwin.unlink(path) == 0 else {
                Darwin.close(retainedDescriptor)
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            var port = mach_port_t(MACH_PORT_NULL)
            errno = 0
            if fileportMakePort(retainedDescriptor, &port) != 0 {
                retentionDeniedErrno = errno
            }
            Darwin.close(retainedDescriptor)
            retainedDescriptor = -1
        }
        let report = BoundaryChildReport(
            schema: "nexgenvideo/bpy-boundary-child/2",
            mode: mode,
            processIdentifier: getpid(),
            parentProcessIdentifier: getppid(),
            allowedWriteSucceeded: true,
            outsideWriteDeniedErrno: 0,
            forkDeniedErrno: 0,
            networkDeniedErrno: 0,
            signalDeniedErrnos: [],
            resourceBytes: UInt64(resourceBytes),
            retentionDeniedErrno: retentionDeniedErrno
        )
        try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
        while true { pause() }
    }

    let allowedWriteSucceeded = (try? Data("allowed".utf8).write(
        to: writeRoot.appendingPathComponent("allowed-write"),
        options: .atomic
    )) != nil
    errno = 0
    let outsideDescriptor = Darwin.open(
        outsidePath.path,
        O_CREAT | O_TRUNC | O_WRONLY,
        S_IRUSR | S_IWUSR
    )
    let outsideErrno: Int32
    if outsideDescriptor >= 0 {
        outsideErrno = 0
        Darwin.close(outsideDescriptor)
    } else {
        outsideErrno = errno
    }

    errno = 0
    let forked = Darwin.fork()
    let forkErrno: Int32
    if forked == 0 {
        Darwin._exit(0)
    } else if forked > 0 {
        var status: Int32 = 0
        _ = Darwin.waitpid(forked, &status, 0)
        forkErrno = 0
    } else {
        forkErrno = errno
    }

    errno = 0
    let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    let networkErrno: Int32
    if socketDescriptor >= 0 {
        networkErrno = 0
        Darwin.close(socketDescriptor)
    } else {
        networkErrno = errno
    }

    var signalErrnos: [Int32] = []
    for value in [Int32(0), SIGSTOP, SIGKILL] {
        errno = 0
        signalErrnos.append(Darwin.kill(getppid(), value) == 0 ? 0 : errno)
    }
    let report = BoundaryChildReport(
        schema: "nexgenvideo/bpy-boundary-child/2",
        mode: mode,
        processIdentifier: getpid(),
        parentProcessIdentifier: getppid(),
        allowedWriteSucceeded: allowedWriteSucceeded,
        outsideWriteDeniedErrno: outsideErrno,
        forkDeniedErrno: forkErrno,
        networkDeniedErrno: networkErrno,
        signalDeniedErrnos: signalErrnos,
        resourceBytes: 0,
        retentionDeniedErrno: 0
    )
    try JSONEncoder().encode(report).write(to: reportURL, options: .atomic)
    let denied = [EPERM, EACCES]
    guard allowedWriteSucceeded,
          denied.contains(outsideErrno),
          [EPERM, EAGAIN].contains(forkErrno),
          denied.contains(networkErrno),
          signalErrnos.count == 3,
          signalErrnos.allSatisfy({ denied.contains($0) }) else {
        Darwin.exit(70)
    }
    Darwin.exit(0)
}

private func waitForOwnedChildExit(_ process: Process, timeoutNanoseconds: UInt64) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
    while process.isRunning {
        if DispatchTime.now().uptimeNanoseconds >= deadline { return false }
        usleep(5_000)
    }
    return true
}

private func terminateOwnedChildThroughProcess(_ process: Process, processIdentifier: pid_t) {
    process.terminate()
    if waitForOwnedChildExit(process, timeoutNanoseconds: 250_000_000) { return }
    guard process.isRunning else { return }
    _ = Darwin.kill(processIdentifier, SIGSTOP)
    if process.isRunning {
        _ = Darwin.kill(processIdentifier, SIGKILL)
    }
    _ = waitForOwnedChildExit(process, timeoutNanoseconds: 2_000_000_000)
}

private func terminateAndReapOwnedChild(_ process: Process, startAbsoluteTime: UInt64?) {
    guard process.isRunning else { return }
    let processIdentifier = process.processIdentifier
    if let startAbsoluteTime {
        guard let currentStart = processStartAbsoluteTime(processIdentifier) else {
            terminateOwnedChildThroughProcess(process, processIdentifier: processIdentifier)
            return
        }
        guard currentStart == startAbsoluteTime else {
            _ = waitForOwnedChildExit(process, timeoutNanoseconds: 10_000_000)
            return
        }
        let stopped = Darwin.kill(processIdentifier, SIGSTOP) == 0
        let stoppedStart = stopped ? processStartAbsoluteTime(processIdentifier) : nil
        if stoppedStart == startAbsoluteTime
            || (stopped && stoppedStart == nil && process.isRunning) {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    } else {
        terminateOwnedChildThroughProcess(process, processIdentifier: processIdentifier)
        return
    }
    _ = waitForOwnedChildExit(process, timeoutNanoseconds: 2_000_000_000)
}

private func supervise(arguments: [String]) throws -> Int32 {
    guard arguments.count == 10,
          let servicePID = Int32(arguments[0]),
          let serviceStart = UInt64(arguments[1]),
          servicePID > 1,
          parentIsAlive(servicePID, startAbsoluteTime: serviceStart) else {
        throw SupervisorError.invalidParent
    }
    let authorizationURL = URL(fileURLWithPath: arguments[2])
    let authorizationToken = arguments[3]
    let identityURL = URL(fileURLWithPath: arguments[4])
    let writeRoot = URL(fileURLWithPath: arguments[5], isDirectory: true)
    let pythonArguments = Array(arguments[5...9])
    guard authorizationToken.count == 64,
          authorizationToken.allSatisfy({ $0.isHexDigit }) else {
        throw SupervisorError.invalidArguments
    }
    _ = Darwin.signal(SIGTERM, requestTermination)
    _ = Darwin.signal(SIGINT, requestTermination)
    while !isAuthorized(at: authorizationURL, token: authorizationToken) {
        if terminationRequested != 0 { return 0 }
        guard parentIsAlive(servicePID, startAbsoluteTime: serviceStart) else {
            throw SupervisorError.invalidParent
        }
        usleep(5_000)
    }
    guard parentIsAlive(servicePID, startAbsoluteTime: serviceStart) else {
        throw SupervisorError.invalidParent
    }
    if terminationRequested != 0 { return 0 }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["launch"] + pythonArguments
    process.currentDirectoryURL = writeRoot
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    let childPID = process.processIdentifier
    var childReaped = false
    var childStart: UInt64?
    defer {
        if !childReaped {
            terminateAndReapOwnedChild(process, startAbsoluteTime: childStart)
        }
    }
    let failChildIdentityCapture = ProcessInfo.processInfo.environment[
        "NGV_BPY_SUPERVISOR_FAIL_CHILD_IDENTITY_CAPTURE"
    ] == "1"
    if failChildIdentityCapture {
        let readyURL = writeRoot.appendingPathComponent(".ngv-supervisor-child-term-ignored")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: readyURL.path) && process.isRunning {
            usleep(5_000)
        }
        guard FileManager.default.fileExists(atPath: readyURL.path) else {
            throw SupervisorError.processLaunch
        }
    }
    for _ in 0..<20 where childStart == nil && process.isRunning {
        if !failChildIdentityCapture {
            childStart = processStartAbsoluteTime(childPID)
        }
        if childStart == nil { usleep(5_000) }
    }
    guard let confirmedChildStart = childStart else { throw SupervisorError.processLaunch }
    childStart = confirmedChildStart
    if ProcessInfo.processInfo.environment["NGV_BPY_SUPERVISOR_FAIL_AFTER_CHILD_START"] == "1" {
        throw SupervisorError.injectedIdentityWriteFailure
    }
    let identity = try JSONEncoder().encode(
        WorkerIdentity(processIdentifier: childPID, startAbsoluteTime: confirmedChildStart)
    )
    try identity.write(to: identityURL, options: .atomic)

    while process.isRunning {
        if terminationRequested != 0
            || !parentIsAlive(servicePID, startAbsoluteTime: serviceStart) {
            return terminationRequested != 0 ? 0 : 70
        }
        usleep(10_000)
    }
    process.waitUntilExit()
    childReaped = true
    return process.terminationStatus
}

private func superviseBoundary(arguments: [String]) throws -> Int32 {
    guard arguments.count == 7,
          let servicePID = Int32(arguments[0]),
          let serviceStart = UInt64(arguments[1]),
          servicePID > 1,
          parentIsAlive(servicePID, startAbsoluteTime: serviceStart),
          arguments[6] == "denials" || boundaryResourceModes.contains(arguments[6]) else {
        throw SupervisorError.invalidParent
    }
    let identityURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
    let writeRoot = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
    let outsidePath = URL(fileURLWithPath: arguments[4]).standardizedFileURL
    let reportURL = URL(fileURLWithPath: arguments[5]).standardizedFileURL
    let mode = arguments[6]
    _ = Darwin.signal(SIGTERM, requestTermination)
    _ = Darwin.signal(SIGINT, requestTermination)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = [
        "boundary-child",
        writeRoot.path,
        outsidePath.path,
        reportURL.path,
        mode,
    ]
    process.currentDirectoryURL = writeRoot
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    var childReaped = false
    var childStart: UInt64?
    defer {
        if !childReaped {
            terminateAndReapOwnedChild(process, startAbsoluteTime: childStart)
        }
    }
    for _ in 0..<40 where childStart == nil && process.isRunning {
        childStart = processStartAbsoluteTime(process.processIdentifier)
        if childStart == nil { usleep(5_000) }
    }
    guard let childStart else { throw SupervisorError.processLaunch }
    guard let supervisorStart = processStartAbsoluteTime(getpid()) else {
        throw SupervisorError.processLaunch
    }
    try JSONEncoder().encode(BoundaryIdentity(
        supervisorProcessIdentifier: getpid(),
        supervisorParentProcessIdentifier: getppid(),
        supervisorStartAbsoluteTime: supervisorStart,
        childProcessIdentifier: process.processIdentifier,
        childStartAbsoluteTime: childStart
    )).write(to: identityURL, options: .atomic)

    while process.isRunning {
        if terminationRequested != 0
            || !parentIsAlive(servicePID, startAbsoluteTime: serviceStart) {
            return terminationRequested != 0 ? 0 : 70
        }
        usleep(10_000)
    }
    process.waitUntilExit()
    childReaped = true
    return process.terminationStatus
}

@main
private enum BpySupervisorMain {
    static func main() {
        do {
            guard CommandLine.arguments.count >= 2 else { throw SupervisorError.invalidArguments }
            let arguments = Array(CommandLine.arguments.dropFirst(2))
            switch CommandLine.arguments[1] {
            case "supervise":
                Darwin.exit(try supervise(arguments: arguments))
            case "launch":
                try execPython(arguments: arguments)
            case "boundary-supervise":
                Darwin.exit(try superviseBoundary(arguments: arguments))
            case "boundary-child":
                try boundaryChild(arguments: arguments)
            default:
                throw SupervisorError.invalidArguments
            }
        } catch {
            FileHandle.standardError.write(Data("bpy supervisor failed: \(error)\n".utf8))
            Darwin.exit(70)
        }
    }
}
