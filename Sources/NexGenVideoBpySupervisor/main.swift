import Darwin
import Foundation

@_silgen_name("proc_pid_rusage")
private func procPIDRusage(
    _ processIdentifier: pid_t,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer
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
            default:
                throw SupervisorError.invalidArguments
            }
        } catch {
            FileHandle.standardError.write(Data("bpy supervisor failed: \(error)\n".utf8))
            Darwin.exit(70)
        }
    }
}
