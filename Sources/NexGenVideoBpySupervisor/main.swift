import BpySupervisorPOSIX
import BpyRuntimeProtocol
import Darwin
import Foundation

@_silgen_name("fileport_makeport")
private func fileportMakePort(_ descriptor: Int32, _ port: UnsafeMutablePointer<mach_port_t>) -> Int32

private typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
private typealias SandboxFreeError = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
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
    let execution = configuration.mode != .boundary || configuration.boundary == .diagnosticFootprintAfterExec
        || configuration.boundary == .diagnosticPythonFootprint
        ? "(allow process-exec (literal \"\(python)\"))" : ""
    let profile = """
    (version 1)
    (deny default)
    (allow file-read* (subpath "/System/Library") (subpath "/usr/lib")
        (subpath "/usr/share/icu") (subpath "/usr/share/zoneinfo")
        (literal "/private/etc/passwd") (literal "/private/etc/localtime")
        (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))
    (allow file-read-metadata (literal "/") (literal "/System") (literal "/usr") (literal "/private"))
    (allow file-read* file-map-executable (subpath "\(runtime)") (literal "\(worker)"))
    (allow file-read* file-write* (literal "\(root)") (subpath "\(root)"))
    (allow file-read* \(reads))
    \(execution)
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

private func checkDenials(_ configuration: BpySupervisorConfiguration) throws {
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
}

private func ownExecutable() throws -> URL {
    var path = [CChar](repeating: 0, count: 4_096)
    guard ngv_bpy_self_path(&path, path.count) == 0 else { throw SupervisorError.invalidArguments }
    return URL(fileURLWithPath: String(cString: path))
}

private func launchChild(_ configuration: BpySupervisorConfiguration) throws -> Never {
    let root = try descriptorPath(BpyLaunchDescriptors.root, directory: true)
    _ = try descriptorPath(BpyLaunchDescriptors.configuration, directory: false)
    if configuration.injections.contains(.childIgnoreTerm) { _ = Darwin.signal(SIGTERM, SIG_IGN) }
    try awaitRelease(BpyLaunchDescriptors.childRelease, parent: getppid())
    do { try applyWorkerSandbox(root: root, configuration: configuration) }
    catch SupervisorError.sandboxUnavailable { try? report(.sandboxUnavailable); Darwin.exit(BpyLaunchStage.sandboxUnavailable.rawValue) }
    catch { try? report(.sandboxRejected); Darwin.exit(BpyLaunchStage.sandboxRejected.rawValue) }
    do { try checkDenials(configuration) }
    catch { try? report(.denialCheckFailed); Darwin.exit(BpyLaunchStage.denialCheckFailed.rawValue) }
    if configuration.mode == .boundary, let mode = configuration.boundary, mode.isHostDiagnostic {
        if mode == .diagnosticPythonFootprint { try execMemoryPython(configuration) }
        if mode == .diagnosticFootprintAfterExec {
            let executable = try ownExecutable().path
            let payload = try JSONEncoder().encode(configuration).base64EncodedString()
            let values = [executable, "host-memory-child", payload].map { strdup($0) }
            defer { values.forEach { free($0) } }
            guard values.allSatisfy({ $0 != nil }) else { throw SupervisorError.invalidArguments }
            var arguments = values + [nil]
            var environment: [UnsafeMutablePointer<CChar>?] = [nil]
            arguments.withUnsafeMutableBufferPointer { argv in
                environment.withUnsafeMutableBufferPointer { envp in
                    _ = execve(executable, argv.baseAddress!, envp.baseAddress!)
                }
            }
            try? report(.execFailed)
            Darwin.exit(BpyLaunchStage.execFailed.rawValue)
        }
        try runMemoryDiagnostic(mode)
    }
    ngv_bpy_close_parent_lifeline()
    Darwin.close(BpyLaunchDescriptors.root)
    Darwin.close(BpyLaunchDescriptors.diagnosticRelease)
    if configuration.mode == .boundary {
        guard let mode = configuration.boundary else { throw SupervisorError.invalidArguments }
        Darwin.close(BpyLaunchDescriptors.configuration)
        closeReport()
        try runBoundaryChild(root: URL(fileURLWithPath: root),
            outsidePath: URL(fileURLWithPath: configuration.boundaryPath ?? configuration.canaryWrite), mode: mode.rawValue)
    }
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
    if configuration.injections.contains(.failChildIdentityCapture) {
        try? report(.identityCaptureFailed)
        return BpyLaunchStage.identityCaptureFailed.rawValue
    }
    if configuration.injections.contains(.failAfterChildStart) { throw SupervisorError.processLaunch }
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

private func execMemoryPython(_ configuration: BpySupervisorConfiguration) throws -> Never {
    ngv_bpy_close_parent_lifeline()
    Darwin.close(BpyLaunchDescriptors.root); Darwin.close(BpyLaunchDescriptors.configuration)
    let script = """
    import gc, json, os, random, sys, time
    sys.path.insert(0, sys.argv[1] + '/site-packages')
    import bpy
    gc.collect()
    def report(stage, requested=None):
        value = {'schema':'nexgenvideo/bpy-launch-report/1', 'stage':stage, 'pid':os.getpid()}
        if requested is not None:
            value['requestedBytes'] = requested
            value['allocationObjectBytes'] = sys.getsizeof(chunks[-1][0])
        data = (json.dumps(value) + '\\n').encode()
        if os.write(200, data) != len(data):
            raise RuntimeError('diagnostic report failed')
    report(2)
    if os.read(205, 1) != b'\\x01':
        raise RuntimeError('diagnostic release missing')
    os.close(205)
    generator = random.Random(0x4e4756)
    chunks = []
    for index in range(1, 65):
        chunks.append([generator.randbytes(256) for _ in range(16384)])
        report(5, index * 4 * 1024 * 1024)
        time.sleep(0.05)
    report(6, 256 * 1024 * 1024)
    while True:
        time.sleep(0.05)
    """
    let values = [configuration.python, "-I", "-S", "-c", script, configuration.runtime].map { strdup($0) }
    let environment = configuration.environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) }
    defer { values.forEach { free($0) }; environment.forEach { free($0) } }
    guard values.allSatisfy({ $0 != nil }), environment.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
    var argv = values + [nil], envp = environment + [nil]
    argv.withUnsafeMutableBufferPointer { arguments in
        envp.withUnsafeMutableBufferPointer { environment in
            _ = execve(configuration.python, arguments.baseAddress!, environment.baseAddress!)
        }
    }
    try? report(.execFailed)
    Darwin.exit(BpyLaunchStage.execFailed.rawValue)
}

private func runMemoryDiagnostic(_ mode: BpyBoundaryMode) throws -> Never {
    guard mode.isHostDiagnostic else { throw SupervisorError.invalidArguments }
    try report(mode == .diagnosticFootprintAfterExec ? .diagnosticExecReady : .diagnosticReady)
    try awaitRelease(BpyLaunchDescriptors.diagnosticRelease, parent: getppid())
    ngv_bpy_close_parent_lifeline()
    Darwin.close(BpyLaunchDescriptors.root); Darwin.close(BpyLaunchDescriptors.configuration)
    if mode == .diagnosticStdoutBurst {
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, let started = BpyRuntimeClock.read() else { throw SupervisorError.invalidArguments }
        let data = Data(repeating: 0x52, count: 1_048_576)
        try writeAll(STDOUT_FILENO, data: data)
        guard let finished = BpyRuntimeClock.read() else { throw SupervisorError.invalidArguments }
        try report(.stdoutBurstComplete, stdoutBurst: .init(flags: flags, bytes: data.count, started: started, finished: finished))
        Darwin.exit(0)
    }
    if mode == .diagnosticPressureWait { while true { usleep(50_000) } }
    if mode == .diagnosticVirtualMapping {
        var limit = rlimit()
        guard getrlimit(RLIMIT_AS, &limit) == 0, limit.rlim_cur == RLIM_INFINITY else { throw SupervisorError.invalidArguments }
        let bytes = 8 * 1_024 * 1_024 * 1_024
        let address = mmap(nil, bytes, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard address != MAP_FAILED else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard munmap(address, bytes) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try report(.virtualMappingSucceeded, mapping: .init(bytes: UInt64(bytes), protection: PROT_NONE, deallocated: true))
        Darwin.exit(0)
    }
    var allocations: [UnsafeMutableRawPointer] = []
    let bytes = 4 * 1_024 * 1_024
    for index in 1...64 {
        guard let allocation = ngv_bpy_allocate_memory_probe(bytes) else { throw POSIXError(.init(rawValue: errno) ?? .ENOMEM) }
        allocations.append(allocation)
        try report(.diagnosticProgress, requestedBytes: UInt64(index * bytes))
        usleep(50_000)
    }
    try report(.diagnosticAllocationCap, requestedBytes: 256 * 1_024 * 1_024)
    while true { usleep(50_000); withExtendedLifetime(allocations) {} }
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

private func writeBoundaryResource(_ descriptor: Int32, byteCount: Int) throws {
    let chunk = Data(repeating: 0x5a, count: 64 * 1_024)
    for _ in 0..<(byteCount / chunk.count) {
        try writeAll(descriptor, data: chunk)
    }
    guard Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private func runBoundaryChild(root writeRoot: URL, outsidePath: URL, mode: String) throws -> Never {
    let reportURL = writeRoot.appendingPathComponent("child.json")
    if boundaryResourceModes.contains(mode) { _ = Darwin.signal(SIGTERM, SIG_IGN) }


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

    var forkErrno: Int32 = 0
    let forkProbeError = ngv_bpy_probe_fork(&forkErrno)
    guard forkProbeError == 0 else {
        throw POSIXError(.init(rawValue: forkProbeError) ?? .EIO)
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
    let acknowledgment = writeRoot.appendingPathComponent("service-observed")
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while !FileManager.default.fileExists(atPath: acknowledgment.path) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw SupervisorError.processLaunch }
        usleep(5_000)
    }
    Darwin.exit(0)
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
                  configuration.schema == "nexgenvideo/bpy-supervisor/2" else { throw SupervisorError.invalidArguments }
            _ = Darwin.signal(SIGPIPE, SIG_IGN)
            switch CommandLine.arguments[1] {
            case "host-supervise": Darwin.exit(try supervise(configuration, payload: CommandLine.arguments[2]))
            case "host-child": try launchChild(configuration)
            case "host-memory-child":
                guard configuration.mode == .boundary, configuration.boundary == .diagnosticFootprintAfterExec else {
                    throw SupervisorError.invalidArguments
                }
                try runMemoryDiagnostic(.diagnosticFootprintAfterExec)
            default: throw SupervisorError.invalidArguments
            }
        } catch {
            try? report(.invalidLaunch)
            Darwin.exit(BpyLaunchStage.invalidLaunch.rawValue)
        }
    }
}
