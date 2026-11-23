import BpySupervisorPOSIX
import BpyRuntimeProtocol
import Darwin
import Foundation

private typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
private typealias SandboxFreeError = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
private typealias SandboxIssueFile = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var terminationRequested: sig_atomic_t = 0
nonisolated(unsafe) private var reportOpen = false
private func requestTermination(_ signal: Int32) { terminationRequested = 1 }

private enum SupervisorError: Error {
    case invalidArguments, invalidParent, processLaunch, sandboxUnavailable, sandboxRejected, denialCheckFailed
}

private func parentIsAlive(_ pid: Int32) -> Bool {
    pid > 1 && ngv_bpy_parent_alive(pid) == 1
}

private func descriptorPath(_ descriptor: Int32, directory: Bool) throws -> String {
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_uid == getuid(),
          status.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
          directory || (status.st_nlink == 1 && status.st_size >= 0 && status.st_size <= 4 * 1_024 * 1_024) else {
        throw SupervisorError.invalidArguments
    }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw SupervisorError.invalidArguments }
    let value = String(cString: path)
    guard value.hasPrefix("/"), !value.utf8.contains(0) else { throw SupervisorError.invalidArguments }
    return value
}

private func escapedSandboxLiteral(_ value: String) throws -> String {
    guard value.hasPrefix("/"), !value.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
        throw SupervisorError.invalidArguments
    }
    return value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

private func sandboxSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return symbol }
    for path in ["/usr/lib/system/libsystem_sandbox.dylib", "/usr/lib/libsandbox.dylib"] {
        if let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, name) { return symbol }
    }
    return nil
}

private func applyWorkerSandbox(root: String, configuration: BpySupervisorConfiguration) throws {
    guard let symbol = sandboxSymbol("sandbox_init") else { throw SupervisorError.sandboxUnavailable }
    let root = try escapedSandboxLiteral(root)
    let runtime = try escapedSandboxLiteral(configuration.runtime)
    let python = try escapedSandboxLiteral(configuration.python)
    let worker = try escapedSandboxLiteral(configuration.worker)
    let reads = try configuration.readPaths.map { "(literal \"\(try escapedSandboxLiteral($0))\")" }.joined(separator: "\n")
    let profile = """
    (version 1)
    (deny default)
    (allow file-read* (subpath "/System/Library") (subpath "/usr/lib")
        (subpath "/usr/share/icu") (subpath "/usr/share/zoneinfo")
        (literal "/private/etc/passwd") (literal "/private/etc/localtime")
        (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))
    (allow file-read* file-test-existence file-map-executable
        (subpath "/System/Cryptexes/OS") (subpath "/System/Volumes/Preboot/Cryptexes/OS"))
    (allow file-read* file-test-existence
        (literal "/") (literal "/System") (literal "/System/Cryptexes")
        (literal "/System/Volumes") (literal "/System/Volumes/Preboot")
        (literal "/System/Volumes/Preboot/Cryptexes"))
    (allow file-read-metadata (literal "/") (literal "/System") (literal "/usr") (literal "/private"))
    (allow file-read* file-map-executable (subpath "\(runtime)") (literal "\(worker)"))
    (allow file-issue-extension
        (require-all (extension-class "com.apple.app-sandbox.read") (subpath "\(runtime)")))
    (allow file-read* file-write* (literal "\(root)") (subpath "\(root)"))
    (allow file-read* \(reads))
    (allow process-exec (literal "\(python)"))
    (allow sysctl-read)
    (allow process-info* (target self))
    (allow mach-lookup (global-name "com.apple.logd") (global-name "com.apple.system.logger")
        (xpc-service-name "com.apple.MTLCompilerService"))
    (allow iokit-open (iokit-connection "IOAccelerator")
        (iokit-user-client-class "IOAccelerationUserClient")
        (iokit-user-client-class "IOSurfaceRootUserClient") (iokit-user-client-class "IOSurfaceSendRight"))
    """
    var error: UnsafeMutablePointer<CChar>?
    let status = profile.withCString { unsafeBitCast(symbol, to: SandboxInit.self)($0, 0, &error) }
    if let error, let free = sandboxSymbol("sandbox_free_error") {
        unsafeBitCast(free, to: SandboxFreeError.self)(error)
    }
    guard status == 0 else { throw SupervisorError.sandboxRejected }
}

private func awaitRelease(_ descriptor: Int32, parent: Int32) throws {
    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
    while terminationRequested == 0 && parentIsAlive(parent) {
        let result = Darwin.poll(&pollDescriptor, 1, 5)
        if result < 0 && errno == EINTR { continue }
        guard result >= 0 else { throw SupervisorError.invalidParent }
        if result > 0 {
            var byte: UInt8 = 0
            guard Darwin.read(descriptor, &byte, 1) == 1, byte == 1 else { throw SupervisorError.invalidParent }
            Darwin.close(descriptor)
            return
        }
    }
    throw SupervisorError.invalidParent
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
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            offset += written
        }
    }
}

private func report(_ stage: BpyLaunchStage, pid: Int32 = getpid(), requestedBytes: UInt64? = nil,
                    mapping: BpyMappingDiagnostic? = nil, stdoutBurst: BpyStdoutBurst? = nil) throws {
    guard reportOpen else { throw SupervisorError.invalidArguments }
    var data = try JSONEncoder().encode(BpyLaunchReport(stage: stage, pid: pid, requestedBytes: requestedBytes,
        mapping: mapping, clock: BpyRuntimeClock.read(), stdoutBurst: stdoutBurst))
    data.append(0x0a)
    try writeAll(BpyLaunchDescriptors.report, data: data)
}

private func closeReport() {
    reportOpen = false
    Darwin.close(BpyLaunchDescriptors.report)
}

private func checkRuntimeExtensions(root: String, configuration: BpySupervisorConfiguration) throws {
    guard let symbol = sandboxSymbol("sandbox_extension_issue_file") else { throw SupervisorError.sandboxUnavailable }
    let issue = unsafeBitCast(symbol, to: SandboxIssueFile.self)
    let read = "com.apple.app-sandbox.read"
    let write = "com.apple.app-sandbox.read-write"
    func check(_ path: String, extensionClass: String, allowed: Bool) throws {
        errno = 0
        let token = extensionClass.withCString { name in path.withCString { issue(name, $0, 0) } }
        let error = errno
        defer { free(token) }
        guard allowed ? token != nil : token == nil && [EPERM, EACCES].contains(error) else {
            throw SupervisorError.denialCheckFailed
        }
    }
    for path in Set([configuration.runtime, URL(fileURLWithPath: configuration.python).deletingLastPathComponent().path]) {
        try check(path, extensionClass: read, allowed: true)
        try check(path, extensionClass: write, allowed: false)
    }
    let outside = [root, URL(fileURLWithPath: configuration.runtime).deletingLastPathComponent().path,
        configuration.canaryRead, configuration.canaryWrite] + configuration.readPaths.filter {
            $0 != configuration.runtime && !$0.hasPrefix(configuration.runtime + "/")
        }
    for path in Set(outside) {
        try check(path, extensionClass: read, allowed: false)
        try check(path, extensionClass: write, allowed: false)
    }
}

private func checkDenials(root: String, configuration: BpySupervisorConfiguration) throws {
    errno = 0
    let read = Darwin.open(configuration.canaryRead, O_RDONLY)
    let readError = errno
    if read >= 0 { Darwin.close(read) }
    errno = 0
    let write = Darwin.open(configuration.canaryWrite, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    let writeError = errno
    if write >= 0 { Darwin.close(write) }
    guard read < 0, write < 0, [EPERM, EACCES].contains(readError), [EPERM, EACCES].contains(writeError) else {
        throw SupervisorError.denialCheckFailed
    }
    try checkRuntimeExtensions(root: root, configuration: configuration)
}

private func ownExecutable() throws -> URL {
    var path = [CChar](repeating: 0, count: 4_096)
    guard ngv_bpy_self_path(&path, path.count) == 0 else { throw SupervisorError.invalidArguments }
    return URL(fileURLWithPath: String(cString: path))
}

private func launchChild(_ configuration: BpySupervisorConfiguration) throws -> Never {
    let root = try descriptorPath(BpyLaunchDescriptors.root, directory: true)
    _ = try descriptorPath(BpyLaunchDescriptors.configuration, directory: false)
    try awaitRelease(BpyLaunchDescriptors.childRelease, parent: getppid())
    do { try applyWorkerSandbox(root: root, configuration: configuration) }
    catch SupervisorError.sandboxUnavailable { try? report(.sandboxUnavailable); Darwin.exit(BpyLaunchStage.sandboxUnavailable.rawValue) }
    catch { try? report(.sandboxRejected); Darwin.exit(BpyLaunchStage.sandboxRejected.rawValue) }
    do { try checkDenials(root: root, configuration: configuration) }
    catch { try? report(.denialCheckFailed); Darwin.exit(BpyLaunchStage.denialCheckFailed.rawValue) }
    ngv_bpy_close_parent_lifeline()
    Darwin.close(BpyLaunchDescriptors.root)
    Darwin.close(BpyLaunchDescriptors.diagnosticRelease)
    _ = fcntl(BpyLaunchDescriptors.report, F_SETFD, FD_CLOEXEC)
    guard fcntl(BpyLaunchDescriptors.configuration, F_SETFD, 0) == 0 else { throw SupervisorError.invalidArguments }
    if configuration.mode == .job {
        guard fcntl(BpyLaunchDescriptors.source, F_SETFD, 0) == 0 else { throw SupervisorError.invalidArguments }
    }
    let arguments = [configuration.python, "-I", "-S", configuration.worker, configuration.mode.rawValue,
        String(BpyLaunchDescriptors.configuration)]
    let environment = configuration.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    let argv = arguments.map { strdup($0) }, envp = environment.map { strdup($0) }
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw SupervisorError.invalidArguments }
    var pointers = argv + [nil], environmentPointers = envp + [nil]
    pointers.withUnsafeMutableBufferPointer { values in
        environmentPointers.withUnsafeMutableBufferPointer { environment in
            _ = execve(configuration.python, values.baseAddress!, environment.baseAddress!)
        }
    }
    try? report(.execFailed)
    Darwin.exit(BpyLaunchStage.execFailed.rawValue)
}

private func supervise(_ configuration: BpySupervisorConfiguration, payload: String) throws -> Int32 {
    guard configuration.hostPID > 1, configuration.hostStart > 0, parentIsAlive(configuration.hostPID) else {
        throw SupervisorError.invalidParent
    }
    _ = Darwin.signal(SIGTERM, requestTermination)
    _ = Darwin.signal(SIGINT, requestTermination)
    try report(.supervisorReady)
    try awaitRelease(BpyLaunchDescriptors.release, parent: configuration.hostPID)
    let root = try descriptorPath(BpyLaunchDescriptors.root, directory: true)
    var descriptors = [BpyLaunchDescriptors.root: BpyLaunchDescriptors.root,
        BpyLaunchDescriptors.configuration: BpyLaunchDescriptors.configuration,
        BpyLaunchDescriptors.childRelease: BpyLaunchDescriptors.childRelease,
        BpyLaunchDescriptors.report: BpyLaunchDescriptors.report,
        BpyLaunchDescriptors.diagnosticRelease: BpyLaunchDescriptors.diagnosticRelease]
    if configuration.mode == .job { descriptors[BpyLaunchDescriptors.source] = BpyLaunchDescriptors.source }
    let process = try BpyOwnedProcess(executable: ownExecutable(), arguments: ["host-child", payload],
        environment: configuration.environment, directory: URL(fileURLWithPath: root),
        allowsForcedTermination: true, directoryDescriptor: BpyLaunchDescriptors.root,
        inheritedDescriptors: descriptors)
    var reaped = false
    defer { if !reaped { reapBeforeExiting(process) } }
    Darwin.close(BpyLaunchDescriptors.root)
    Darwin.close(BpyLaunchDescriptors.configuration)
    if configuration.mode == .job { Darwin.close(BpyLaunchDescriptors.source) }
    Darwin.close(BpyLaunchDescriptors.childRelease)
    Darwin.close(BpyLaunchDescriptors.diagnosticRelease)
    try report(.childReady, pid: process.processIdentifier)
    closeReport()
    while try process.isRunning {
        if terminationRequested != 0 || !parentIsAlive(configuration.hostPID) {
            try process.terminateAndReap()
            reaped = true
            return terminationRequested == 0 ? 70 : 0
        }
        usleep(5_000)
    }
    let status = try process.waitUntilExit()
    reaped = true
    return status
}

private func reapBeforeExiting(_ process: BpyOwnedProcess) {
    while true {
        do { try process.terminateAndReap(); return }
        catch {
            try? FileHandle.standardError.write(contentsOf: Data("bpy child cleanup pending: \(error)\n".utf8))
            usleep(250_000)
        }
    }
}


@main
private enum BpySupervisorMain {
    static func main() {
        do {
            var reportStatus = stat()
            reportOpen = fstat(BpyLaunchDescriptors.report, &reportStatus) == 0 && reportStatus.st_mode & S_IFMT == S_IFIFO
            guard CommandLine.arguments.count == 3, CommandLine.arguments[2].utf8.count <= 131_072,
                  let data = Data(base64Encoded: CommandLine.arguments[2]),
                  let configuration = try? JSONDecoder().decode(BpySupervisorConfiguration.self, from: data),
                  configuration.schema == "nexgenvideo/bpy-supervisor/2",
                  [.probe, .job, .verify].contains(configuration.mode),
                  configuration.injections.isEmpty, configuration.boundary == nil else { throw SupervisorError.invalidArguments }
            _ = Darwin.signal(SIGPIPE, SIG_IGN)
            switch CommandLine.arguments[1] {
            case "host-supervise": Darwin.exit(try supervise(configuration, payload: CommandLine.arguments[2]))
            case "host-child": try launchChild(configuration)
            default: throw SupervisorError.invalidArguments
            }
        } catch {
            try? report(.invalidLaunch)
            Darwin.exit(BpyLaunchStage.invalidLaunch.rawValue)
        }
    }
}
