import Foundation
import Darwin

final class ClaudeCodeProcess: @unchecked Sendable {

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let lifecycleLock = NSLock()
    private var exitObserved = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var readerTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var stderrBytes = Data()
    private var writerTask: Task<Void, Never>?
    private var stdinClosing = false
    private var abortWrites = false

    init() {
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
    }

    /// Launch the process and return a stream of stdout lines. Throws if it can't be started.
    func start(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil
    ) throws -> AsyncThrowingStream<String, Error> {
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let environment { process.environment = environment }

        try Self.makeNonblocking(stdoutHandle)
        try Self.makeNonblocking(stderrPipe.fileHandleForReading)
        stderrReadLock.withLock { stderrReadable = true }
        try Self.makeNonblocking(stdinHandle)
        guard fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        process.terminationHandler = { [weak self] _ in self?.observeExit() }
        try process.runCoordinated()
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        let errors = Task.detached { [self] in
            while !Task.isCancelled {
                if drainAvailableStderr() { return }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
        lifecycleLock.withLock { stderrTask = errors }

        return AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                var pending = Data()
                do {
                    try await Self.readChunks(stdoutHandle) { bytes in
                        pending.append(bytes)
                        while let newline = pending.firstIndex(of: 10) {
                            var bytes = pending[..<newline]
                            if bytes.last == 13 { bytes = bytes.dropLast() }
                            let line = String(decoding: bytes, as: UTF8.self)
                            HangDiagnosticRecorder.shared.record(.runtimeReceive, values: [Double(line.utf8.count)])
                            continuation.yield(line)
                            pending.removeSubrange(...newline)
                        }
                    }
                    if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                    _ = drainAvailableStderr()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            lifecycleLock.withLock { readerTask = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Write one stream-json line (a newline is appended) to the process stdin.
    @discardableResult
    func send(line: String) -> Bool {
        guard let data = (line + "\n").data(using: .utf8) else { return false }
        return lifecycleLock.withLock {
            guard !stdinClosing, !abortWrites, process.isRunning else { return false }
            let previous = writerTask
            writerTask = Task.detached { [self] in
                await previous?.value
                do { try await writeAll(data) }
                catch {
                    let shouldTerminate = lifecycleLock.withLock {
                        guard !abortWrites else { return false }
                        abortWrites = true
                        return true
                    }
                    if shouldTerminate { terminate() }
                }
            }
            return true
        }
    }

    /// Close stdin (signals end-of-input to the child).
    func closeStdin() {
        lifecycleLock.withLock {
            guard !stdinClosing else { return }
            stdinClosing = true
            let previous = writerTask
            writerTask = Task.detached { [self] in
                await previous?.value
                closeInput()
            }
        }
    }

    /// Read whatever the child wrote to stderr so far (diagnostics on failure).
    func drainStderr() -> String {
        _ = drainAvailableStderr()
        return lifecycleLock.withLock { String(decoding: stderrBytes, as: UTF8.self) }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func shutdownAndWait() async {
        let task = lifecycleLock.withLock {
            if let shutdownTask { return shutdownTask }
            let task = Task.detached { [self] in await performShutdownAndWait() }
            shutdownTask = task
            return task
        }
        await task.value
    }

    private func performShutdownAndWait() async {
        let writer = lifecycleLock.withLock {
            abortWrites = true
            stdinClosing = true
            return writerTask
        }
        terminate()
        await writer?.value
        closeInput()
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.process.isRunning else { return }
            Darwin.kill(self.process.processIdentifier, SIGKILL)
        }
        await withCheckedContinuation { continuation in
            let finished = lifecycleLock.withLock {
                if exitObserved { return true }
                exitWaiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
        }
        watchdog.cancel()
        await watchdog.value
        let reader = lifecycleLock.withLock { readerTask }
        let errors = lifecycleLock.withLock { stderrTask }
        reader?.cancel()
        errors?.cancel()
        await reader?.value
        await errors?.value
        _ = drainAvailableStderr()
        try? stdoutHandle.close()
        stderrReadLock.withLock {
            stderrReadable = false
            try? stderrPipe.fileHandleForReading.close()
        }
    }

    private func drainAvailableStderr() -> Bool {
        stderrReadLock.withLock {
            guard stderrReadable else { return true }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            // Bound a drain if a surviving descendant keeps writing.
            for _ in 0..<64 {
                let count = Darwin.read(stderrPipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if count > 0 {
                    lifecycleLock.withLock {
                        stderrBytes.append(contentsOf: buffer.prefix(count))
                        if stderrBytes.count > 65_536 { stderrBytes = stderrBytes.suffix(65_536) }
                    }
                    continue
                }
                if count == 0 { return true }
                let code = errno
                if code == EINTR { continue }
                return code != EAGAIN && code != EWOULDBLOCK
            }
            return false
        }
    }

    private static func makeNonblocking(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeAll(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard !lifecycleLock.withLock({ abortWrites }) else { throw CancellationError() }
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(stdinHandle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count; continue }
            let code = errno
            if count < 0 && code == EINTR { continue }
            guard count < 0, code == EAGAIN || code == EWOULDBLOCK else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func readChunks(_ handle: FileHandle, receive: (Data) -> Void) async throws {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 { receive(Data(buffer.prefix(count))); continue }
            if count == 0 { return }
            let code = errno
            if code == EINTR { continue }
            guard code == EAGAIN || code == EWOULDBLOCK else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func observeExit() {
        let waiters = lifecycleLock.withLock {
            exitObserved = true
            let values = exitWaiters
            exitWaiters.removeAll()
            return values
        }
        for waiter in waiters { waiter.resume() }
    }

    private let stderrReadLock = NSLock()
    private var stderrReadable = false
    private var shutdownTask: Task<Void, Never>?
    private var stdinClosed = false

    private func closeInput() {
        lifecycleLock.withLock {
            guard !stdinClosed else { return }
            stdinClosed = true
            try? stdinHandle.close()
        }
    }

    var isRunning: Bool { process.isRunning }
    var exitStatus: Int32? { lifecycleLock.withLock { exitObserved ? process.terminationStatus : nil } }
}
