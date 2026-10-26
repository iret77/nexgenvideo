import BpySupervisorPOSIX
import Darwin
import Foundation

public struct BpyProcessTermination: Sendable, Equatable {
    public let exitStatus: Int32
    public let signal: Int32?
    public var exitedNormally: Bool { signal == nil }
}

public final class BpyOwnedProcess: @unchecked Sendable {
    private let child: OpaquePointer
    private let allowsForcedTermination: Bool
    public let processIdentifier: Int32

    public init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
                input: FileHandle? = nil, output: FileHandle? = .standardOutput,
                errors: FileHandle? = .standardError, allowsForcedTermination: Bool = true) throws {
        func descriptor(_ handle: FileHandle?) throws -> Int32 {
            guard let handle, handle !== FileHandle.nullDevice else { return -1 }
            guard handle.fileDescriptor >= 0 else { throw POSIXError(.EBADF) }
            return handle.fileDescriptor
        }
        let inputFD = try descriptor(input), outputFD = try descriptor(output), errorFD = try descriptor(errors)
        let argvStrings = [executable.path] + arguments
        let envStrings = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        guard executable.isFileURL, directory.isFileURL,
              (argvStrings + envStrings + [directory.path]).allSatisfy({ !$0.utf8.contains(0) }),
              environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else {
            throw POSIXError(.EINVAL)
        }
        let argv = argvStrings.map { strdup($0) }
        let envp = envStrings.map { strdup($0) }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var argumentPointers = argv + [nil]
        var environmentPointers = envp + [nil]
        var created: OpaquePointer?
        let error = argumentPointers.withUnsafeMutableBufferPointer { arguments in
            environmentPointers.withUnsafeMutableBufferPointer { environment in
                executable.path.withCString { path in
                    directory.path.withCString { directory in
                        ngv_bpy_child_spawn(path, arguments.baseAddress!, environment.baseAddress!, directory,
                                            inputFD, outputFD, errorFD, &created)
                    }
                }
            }
        }
        guard error == 0, let created else { throw POSIXError(.init(rawValue: error) ?? .EIO) }
        child = created
        self.allowsForcedTermination = allowsForcedTermination
        processIdentifier = ngv_bpy_child_pid(created)
    }

    public var isRunning: Bool {
        get throws {
            var running: Int32 = 0
            let error = ngv_bpy_child_poll(child, &running)
            guard error == 0 else { throw POSIXError(.init(rawValue: error) ?? .EIO) }
            return running != 0
        }
    }

    public func signal(_ number: Int32) throws {
        let error = ngv_bpy_child_signal(child, number)
        guard error == 0 else { throw POSIXError(.init(rawValue: error) ?? .EIO) }
    }

    public func waitUntilExit(timeout: TimeInterval = 3) throws -> Int32 {
        try waitForTermination(timeout: timeout).exitStatus
    }

    public func waitForTermination(timeout: TimeInterval = 3) throws -> BpyProcessTermination {
        guard timeout.isFinite, timeout >= 0 else { throw POSIXError(.EINVAL) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            var reaped: Int32 = 0
            var status: Int32 = 0
            var signal: Int32 = 0
            let error = ngv_bpy_child_reap(child, &reaped, &status, &signal)
            guard error == 0 else { throw POSIXError(.init(rawValue: error) ?? .EIO) }
            if reaped != 0 { return .init(exitStatus: status, signal: signal == 0 ? nil : signal) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw POSIXError(.ETIMEDOUT) }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    @discardableResult
    public func terminateAndReap(grace: TimeInterval = 0.25) throws -> Int32 {
        guard grace.isFinite, grace >= 0 else { throw POSIXError(.EINVAL) }
        try signal(SIGTERM)
        do { return try waitUntilExit(timeout: grace) }
        catch let error as POSIXError where error.code == .ETIMEDOUT {
            guard allowsForcedTermination else { throw error }
            try signal(SIGSTOP)
            try signal(SIGKILL)
            return try waitUntilExit(timeout: 2)
        }
    }

    deinit {
        do { try terminateAndReap(grace: 3) }
        catch { try? FileHandle.standardError.write(contentsOf: Data("bpy owned-child cleanup failed: \((error as NSError).code)\n".utf8)) }
        if ngv_bpy_child_destroy(child) != 0 {
            try? FileHandle.standardError.write(contentsOf: Data("bpy owned-child handle retained: child not reaped\n".utf8))
        }
    }
}
