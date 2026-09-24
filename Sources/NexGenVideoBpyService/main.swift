import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

@_silgen_name("proc_listchildpids")
private func procListChildPIDs(
    _ processIdentifier: pid_t,
    _ buffer: UnsafeMutableRawPointer?,
    _ bufferSize: Int32
) -> Int32

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

private extension NSLock {
    func access<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func encoded(_ response: BpyServiceResponse) -> Data {
    (try? encoder.encode(response)) ?? Data()
}

private func failure(_ message: String) -> Data {
    encoded(.init(ok: false, message: message))
}

private func isSafeName(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128
        && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
}

private func isSHA256(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
}

private func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func processTree(root: pid_t) -> [pid_t] {
    var visited = Set<pid_t>()
    var pending = [root]
    while let parent = pending.popLast() {
        var children = [pid_t](repeating: 0, count: 256)
        let bytes = children.withUnsafeMutableBytes {
            procListChildPIDs(parent, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { continue }
        for child in children.prefix(Int(bytes))
            where child > 1 && visited.insert(child).inserted {
            pending.append(child)
        }
    }
    return Array(visited)
}

private final class ResponseCallback: @unchecked Sendable {
    let body: (Data) -> Void

    init(_ body: @escaping (Data) -> Void) {
        self.body = body
    }
}

private final class UploadRecord {
    let url: URL
    let totalBytes: UInt64
    let expectedSHA256: String
    let handle: FileHandle
    var receivedBytes: UInt64 = 0

    init(url: URL, totalBytes: UInt64, expectedSHA256: String, handle: FileHandle) {
        self.url = url
        self.totalBytes = totalBytes
        self.expectedSHA256 = expectedSHA256
        self.handle = handle
    }
}

private final class JobRecord: @unchecked Sendable {
    let id: UUID
    var source: String?
    let expectedRevision: String?
    let inputNames: [String]
    let timeoutSeconds: Int
    var state: BpyRuntimeJobState = .accepted
    var message: String?
    var progress: [BpyRuntimeProgress] = []
    var outputs: [BpyOutputDescriptor] = []
    var outputData: [String: Data] = [:]
    var stdout: String?
    var metrics: [String: Double] = [:]

    init(request: BpyRunJobRequest, timeoutSeconds: Int) {
        id = request.jobID
        source = request.source
        expectedRevision = request.expectedRevision
        inputNames = request.inputNames
        self.timeoutSeconds = timeoutSeconds
    }
}

private struct WorkerEvent: Decodable {
    let type: String
    let jobID: String?
    let pythonVersion: String?
    let bpyVersion: String?
    let executable: String?
    let pid: Int32?
    let startupSeconds: Double?
    let sequence: Int?
    let stage: String?
    let fraction: Double?
    let ok: Bool?
    let message: String?
    let stdout: String?
    let metrics: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case type, stage, fraction, ok, message, stdout, metrics, pid, sequence
        case jobID = "job_id"
        case pythonVersion = "python_version"
        case bpyVersion = "bpy_version"
        case executable
        case startupSeconds = "startup_seconds"
    }
}

private struct WorkerJobCommand: Encodable {
    let type = "job"
    let jobID: String
    let source: String
    let inputDirectory: String
    let outputDirectory: String

    enum CodingKeys: String, CodingKey {
        case type, source
        case jobID = "job_id"
        case inputDirectory = "input_dir"
        case outputDirectory = "output_dir"
    }
}

private final class ServiceSession: @unchecked Sendable {
    let request: BpyOpenSessionRequest
    private let root: URL
    private let runtimeRoot: URL
    private let capacity: DispatchSemaphore
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var uploads: [String: UploadRecord] = [:]
    private var completedInputs: [UUID: [String: (UInt64, String)]] = [:]
    private var jobs: [UUID: JobRecord] = [:]
    private var confirmedRevision: String?
    private var confirmedSceneData: Data?
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var stderrBytes = Data()
    private var runtimeIdentity: BpyRuntimeIdentity?
    private var coldStartSeconds: Double?
    private var closed = false

    init(request: BpyOpenSessionRequest, root: URL, runtimeRoot: URL, capacity: DispatchSemaphore) {
        self.request = request
        self.root = root
        self.runtimeRoot = runtimeRoot
        self.capacity = capacity
        confirmedRevision = request.confirmedRevision
        queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.\(request.sessionID.uuidString)")
    }

    func open(reply: @escaping (Data) -> Void) {
        let callback = ResponseCallback(reply)
        queue.async { [self] in
            do {
                guard lock.access({ !closed }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try startWorker()
                callback.body(encoded(readyResponse()))
            } catch {
                stopWorker()
                callback.body(failure(
                    "worker did not become ready: \(error.localizedDescription)\(stderrDiagnostic())"
                ))
            }
        }
    }

    func matches(_ candidate: BpyOpenSessionRequest) -> Bool {
        request == candidate
    }

    func stage(_ request: BpyStageInputRequest, chunk: Data) throws {
        guard isSafeName(request.name), isSHA256(request.sha256) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard request.totalBytes <= self.request.limits.inputBytes,
              chunk.count <= 4 * 1_024 * 1_024,
              request.offset <= request.totalBytes,
              UInt64(chunk.count) <= request.totalBytes - request.offset,
              request.finalChunk == (
                  request.offset + UInt64(chunk.count) == request.totalBytes
              ) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try lock.access {
            guard !closed else { throw CocoaError(.fileWriteNoPermission) }
            if let completed = completedInputs[request.jobID]?[request.name] {
                guard completed.0 == request.totalBytes, completed.1 == request.sha256 else {
                    throw CocoaError(.fileWriteFileExists)
                }
                return
            }
            guard jobs[request.jobID] == nil,
                  !jobs.values.contains(where: {
                      [.accepted, .running, .awaitingConfirmation].contains($0.state)
                  }) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            let key = "\(request.jobID.uuidString)/\(request.name)"
            let upload: UploadRecord
            if let existing = uploads[key] {
                upload = existing
                guard upload.totalBytes == request.totalBytes,
                      upload.expectedSHA256 == request.sha256 else {
                    throw CocoaError(.fileWriteFileExists)
                }
            } else {
                guard request.offset == 0 else { throw CocoaError(.fileWriteUnknown) }
                let prefix = request.jobID.uuidString + "/"
                let completedTotal = completedInputs[request.jobID, default: [:]].values
                    .reduce(UInt64(0)) { $0 + $1.0 }
                let uploadingTotal = uploads
                    .filter { $0.key.hasPrefix(prefix) }
                    .values.reduce(UInt64(0)) { $0 + $1.totalBytes }
                let uploadingCount = uploads.keys.filter { $0.hasPrefix(prefix) }.count
                guard completedInputs[request.jobID, default: [:]].count + uploadingCount < 64,
                      completedTotal <= self.request.limits.inputBytes,
                      uploadingTotal <= self.request.limits.inputBytes - completedTotal,
                      request.totalBytes <= self.request.limits.inputBytes - completedTotal - uploadingTotal else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                let directory = jobDirectory(request.jobID).appendingPathComponent("inputs", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(request.name + ".part")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                upload = UploadRecord(
                    url: url,
                    totalBytes: request.totalBytes,
                    expectedSHA256: request.sha256,
                    handle: FileHandle(forWritingTo: url)
                )
                uploads[key] = upload
            }
            if request.offset < upload.receivedBytes {
                guard request.offset + UInt64(chunk.count) <= upload.receivedBytes else {
                    throw CocoaError(.fileWriteUnknown)
                }
                var existing = Data(count: chunk.count)
                let count = existing.withUnsafeMutableBytes {
                    pread(upload.handle.fileDescriptor, $0.baseAddress, chunk.count, off_t(request.offset))
                }
                guard count == chunk.count, existing == chunk else {
                    throw CocoaError(.fileWriteFileExists)
                }
                return
            }
            guard request.offset == upload.receivedBytes,
                  upload.receivedBytes + UInt64(chunk.count) <= upload.totalBytes else {
                throw CocoaError(.fileWriteUnknown)
            }
            try upload.handle.write(contentsOf: chunk)
            upload.receivedBytes += UInt64(chunk.count)
            if request.finalChunk {
                try upload.handle.synchronize()
                try upload.handle.close()
                guard upload.receivedBytes == upload.totalBytes,
                      try sha256(upload.url) == upload.expectedSHA256 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let finalURL = upload.url.deletingPathExtension()
                try FileManager.default.moveItem(at: upload.url, to: finalURL)
                uploads.removeValue(forKey: key)
                completedInputs[request.jobID, default: [:]][request.name] = (
                    request.totalBytes, request.sha256
                )
            }
        }
    }

    func submit(_ request: BpyRunJobRequest) -> BpyServiceResponse {
        let decision: (JobRecord?, BpyServiceResponse) = lock.access {
            if closed {
                return (nil, .init(ok: false, message: "session is closed"))
            }
            if let existing = jobs[request.jobID] {
                var response = response(for: existing)
                response.joinedExistingJob = true
                return (nil, response)
            }
            guard jobs.count < 1_024 else {
                return (nil, .init(ok: false, message: "session job limit reached"))
            }
            if jobs.values.contains(where: {
                [.accepted, .running, .awaitingConfirmation].contains($0.state)
            }) {
                return (nil, .init(ok: false, message: "session already has an active job"))
            }
            guard request.expectedRevision == confirmedRevision else {
                return (nil, .init(ok: false, message: "confirmed revision mismatch"))
            }
            let names = Set(request.inputNames)
            guard names.count == request.inputNames.count, names.count <= 64,
                  request.inputNames.allSatisfy(isSafeName),
                  names == Set(completedInputs[request.jobID, default: [:]].keys) else {
                return (nil, .init(ok: false, message: "staged inputs do not match the request"))
            }
            guard request.source.utf8.count <= 4 * 1_024 * 1_024 else {
                return (nil, .init(ok: false, message: "job source exceeds the runtime limit"))
            }
            for previous in jobs.values where previous.state.isTerminal {
                previous.outputs.removeAll()
                previous.outputData.removeAll()
                previous.progress.removeAll()
                previous.stdout = nil
                previous.metrics.removeAll()
                completedInputs.removeValue(forKey: previous.id)
            }
            let timeout = min(request.timeoutSeconds ?? self.request.limits.timeoutSeconds,
                              self.request.limits.timeoutSeconds)
            guard timeout > 0 else {
                return (nil, .init(ok: false, message: "invalid timeout"))
            }
            let job = JobRecord(request: request, timeoutSeconds: timeout)
            jobs[request.jobID] = job
            return (job, response(for: job))
        }
        if let job = decision.0 {
            queue.async { [self] in execute(job) }
        }
        return decision.1
    }

    func status(_ jobID: UUID) -> BpyServiceResponse {
        lock.access {
            guard let job = jobs[jobID] else {
                return .init(ok: false, message: "unknown job")
            }
            return response(for: job)
        }
    }

    func output(_ request: BpyReadOutputRequest) throws -> Data {
        guard isSafeName(request.name), request.maximumBytes > 0,
              request.maximumBytes <= 4 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try lock.access {
            guard let job = jobs[request.jobID],
                  [.awaitingConfirmation, .confirmed].contains(job.state),
                  let output = job.outputs.first(where: { $0.name == request.name }),
                  let data = job.outputData[request.name] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            guard request.offset <= output.byteCount else { throw CocoaError(.fileReadCorruptFile) }
            let end = min(
                output.byteCount,
                request.offset + UInt64(request.maximumBytes)
            )
            return data.subdata(in: Int(request.offset)..<Int(end))
        }
    }

    func confirm(_ request: BpyConfirmJobRequest) throws -> BpyServiceResponse {
        guard isSafeName(request.revision), isSHA256(request.sceneSHA256) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return try lock.access {
            guard let job = jobs[request.jobID], job.state == .awaitingConfirmation else {
                throw CocoaError(.fileWriteNoPermission)
            }
            guard request.revision != confirmedRevision else {
                throw CocoaError(.fileWriteFileExists)
            }
            guard let confirmedData = job.outputData["scene.blend"] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            guard sha256(confirmedData) == request.sceneSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            confirmedRevision = request.revision
            confirmedSceneData = confirmedData
            job.state = .confirmed
            return response(for: job)
        }
    }

    func cancel(_ jobID: UUID) -> BpyServiceResponse {
        let shouldStop = lock.access { () -> Bool in
            guard let job = jobs[jobID] else { return false }
            switch job.state {
            case .accepted, .running:
                job.state = .cancelled
                job.message = "job cancelled"
                job.source = nil
                completedInputs.removeValue(forKey: jobID)
                return true
            case .awaitingConfirmation:
                job.state = .rejected
                job.message = "candidate rejected"
                job.outputs.removeAll()
                job.outputData.removeAll()
                completedInputs.removeValue(forKey: jobID)
                return true
            default:
                return false
            }
        }
        if shouldStop { stopWorker() }
        try? FileManager.default.removeItem(at: jobDirectory(jobID))
        return status(jobID)
    }

    func close() {
        lock.access { closed = true }
        stopWorker()
        lock.access {
            for upload in uploads.values { try? upload.handle.close() }
            uploads.removeAll()
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func execute(_ job: JobRecord) {
        capacity.wait()
        defer { capacity.signal() }
        guard lock.access({ job.state == .accepted && !closed }) else { return }
        lock.access { job.state = .running }
        let timeout = DispatchWorkItem { [weak self, weak job] in
            guard let self, let job else { return }
            let shouldStop = self.lock.access { () -> Bool in
                guard job.state == .running else { return false }
                job.state = .timedOut
                job.message = "job exceeded \(job.timeoutSeconds) seconds"
                job.source = nil
                return true
            }
            if shouldStop { self.stopWorker() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(job.timeoutSeconds), execute: timeout
        )
        defer { timeout.cancel() }
        do {
            try startWorker()
            guard lock.access({ job.state == .running && !closed }) else {
                stopWorker()
                return
            }
            guard let source = lock.access({ job.source }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let command = WorkerJobCommand(
                jobID: job.id.uuidString,
                source: source,
                inputDirectory: inputDirectory(job.id).path,
                outputDirectory: outputDirectory(job.id).path
            )
            try writeLine(command)
            while let event = try readEvent() {
                guard event.jobID == nil || event.jobID == job.id.uuidString else { continue }
                if event.type == "progress", let sequence = event.sequence,
                   let stage = event.stage, let fraction = event.fraction {
                    guard fraction.isFinite, (0...1).contains(fraction),
                          sequence == lock.access({ job.progress.count + 1 }),
                          sequence <= 1_024 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    lock.access {
                        job.progress.append(.init(sequence: sequence, stage: stage, fraction: fraction))
                    }
                    continue
                }
                if event.type == "result" {
                    if event.ok == true {
                        let collected = try collectOutputs(job.id)
                        lock.access {
                            guard job.state == .running else { return }
                            job.outputs = collected.descriptors
                            job.outputData = collected.data
                            job.stdout = limited(event.stdout)
                            job.metrics = event.metrics ?? [:]
                            job.source = nil
                            job.state = .awaitingConfirmation
                        }
                    } else {
                        lock.access {
                            guard job.state == .running else { return }
                            job.message = event.message ?? "worker rejected the job"
                            job.stdout = limited(event.stdout)
                            job.metrics = event.metrics ?? [:]
                            job.source = nil
                            job.state = .failed
                        }
                        stopWorker()
                    }
                    try? FileManager.default.removeItem(at: jobDirectory(job.id))
                    return
                }
                if event.type == "fatal" { throw CocoaError(.executableLoad) }
            }
            throw CocoaError(.executableLoad)
        } catch {
            lock.access {
                if job.state == .running {
                    job.state = .crashed
                    job.message = "worker crashed: \(error.localizedDescription)"
                    job.source = nil
                    job.stdout = String(
                        decoding: stderrBytes.prefix(request.limits.stdoutBytes),
                        as: UTF8.self
                    )
                }
            }
            stopWorker()
            try? FileManager.default.removeItem(at: jobDirectory(job.id))
        }
    }

    private func startWorker() throws {
        if lock.access({ process?.isRunning == true && runtimeIdentity != nil }) { return }
        stopWorker()
        let python = runtimeRoot.appendingPathComponent("python/bin/python3")
        let worker = runtimeRoot.appendingPathComponent("worker.py")
        let sitePackages = runtimeRoot.appendingPathComponent("site-packages")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: worker.path),
              FileManager.default.fileExists(atPath: sitePackages.path) else {
            throw CocoaError(.executableNotLoadable)
        }
        for name in ["tmp", "home", "blender-config", "blender-scripts", "blender-data"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let confirmedData = lock.access { confirmedSceneData }
        let bootstrap = root.appendingPathComponent("bootstrap", isDirectory: true)
        try? FileManager.default.removeItem(at: bootstrap)
        try FileManager.default.createDirectory(at: bootstrap, withIntermediateDirectories: true)
        let confirmedScene = bootstrap.appendingPathComponent("confirmed.blend")
        if let confirmedData {
            try confirmedData.write(to: confirmedScene, options: .atomic)
        }
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = python
        process.arguments = [
            "-I", "-S", worker.path, sitePackages.path, root.path,
            confirmedData == nil ? "-" : confirmedScene.path,
            String(request.limits.memoryBytes), String(request.limits.objects),
            String(request.limits.vertices), String(request.limits.polygons),
            String(request.limits.stdoutBytes), String(request.limits.outputBytes),
        ]
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = [
            "HOME": root.appendingPathComponent("home").path,
            "TMPDIR": root.appendingPathComponent("tmp").path,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "BLENDER_USER_CONFIG": root.appendingPathComponent("blender-config").path,
            "BLENDER_USER_SCRIPTS": root.appendingPathComponent("blender-scripts").path,
            "BLENDER_USER_DATAFILES": root.appendingPathComponent("blender-data").path,
        ]
        lock.access { stderrBytes = Data() }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.access {
                let remaining = max(0, self.request.limits.stdoutBytes - self.stderrBytes.count)
                self.stderrBytes.append(data.prefix(remaining))
            }
        }
        try process.run()
        let processIdentifier = process.processIdentifier
        let readinessTimeout = DispatchWorkItem {
            _ = Darwin.kill(-processIdentifier, SIGKILL)
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + .seconds(120),
            execute: readinessTimeout
        )
        defer { readinessTimeout.cancel() }
        lock.access {
            self.process = process
            stdin = input.fileHandleForWriting
            stdout = output.fileHandleForReading
            stderr = errors.fileHandleForReading
        }
        guard let event = try readEvent(), event.type == "ready",
              let pythonVersion = event.pythonVersion,
              let bpyVersion = event.bpyVersion,
              let executable = event.executable,
              let pid = event.pid,
              pid == processIdentifier,
              URL(fileURLWithPath: executable).resolvingSymlinksInPath()
                == python.resolvingSymlinksInPath() else {
            throw CocoaError(.executableLoad)
        }
        let installed = lock.access { () -> Bool in
            guard !closed, self.process === process else { return false }
            runtimeIdentity = .init(
                pythonVersion: pythonVersion,
                bpyVersion: bpyVersion,
                executable: executable,
                sandboxed: true,
                processIdentifier: pid
            )
            coldStartSeconds = event.startupSeconds
            return true
        }
        guard installed else { throw CocoaError(.fileNoSuchFile) }
    }

    private func stopWorker() {
        let current = lock.access { () -> (Process?, FileHandle?, FileHandle?, FileHandle?) in
            let value = (process, stdin, stdout, stderr)
            process = nil
            stdin = nil
            stdout = nil
            stderr = nil
            runtimeIdentity = nil
            return value
        }
        current.3?.readabilityHandler = nil
        try? current.1?.close()
        try? current.2?.close()
        guard let process = current.0 else { return }
        let pid = process.processIdentifier
        if pid > 1 {
            _ = Darwin.kill(-pid, SIGSTOP)
            _ = Darwin.kill(pid, SIGSTOP)
            let descendants = processTree(root: pid)
            descendants.forEach { _ = Darwin.kill($0, SIGSTOP) }
            descendants.reversed().forEach { _ = Darwin.kill($0, SIGTERM) }
            _ = Darwin.kill(-pid, SIGTERM)
            _ = Darwin.kill(pid, SIGTERM)
            descendants.forEach { _ = Darwin.kill($0, SIGCONT) }
            _ = Darwin.kill(-pid, SIGCONT)
            _ = Darwin.kill(pid, SIGCONT)
            descendants.reversed().forEach { _ = Darwin.kill($0, SIGKILL) }
            _ = Darwin.kill(-pid, SIGKILL)
            _ = Darwin.kill(pid, SIGKILL)
            process.waitUntilExit()
        }
    }

    private func writeLine<T: Encodable>(_ value: T) throws {
        guard let stdin = lock.access({ stdin }) else { throw CocoaError(.executableLoad) }
        var data = try encoder.encode(value)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func readEvent() throws -> WorkerEvent? {
        guard let stdout = lock.access({ stdout }) else { throw CocoaError(.executableLoad) }
        let protocolLimit = min(
            32 * 1_024 * 1_024,
            request.limits.stdoutBytes * 8 + 65_536
        )
        while true {
            var line = Data()
            var reachedEnd = false
            while true {
                guard let byte = try stdout.read(upToCount: 1), !byte.isEmpty else {
                    reachedEnd = true
                    break
                }
                if byte[0] == 0x0A { break }
                line.append(byte)
                if line.count > protocolLimit {
                    throw CocoaError(.fileReadTooLarge)
                }
            }
            if !line.isEmpty, let event = try? decoder.decode(WorkerEvent.self, from: line) {
                return event
            }
            if !line.isEmpty {
                lock.access {
                    let remaining = max(0, request.limits.stdoutBytes - stderrBytes.count)
                    stderrBytes.append(contentsOf: line.prefix(remaining))
                }
            }
            if reachedEnd { return nil }
        }
    }

    private func collectOutputs(
        _ jobID: UUID
    ) throws -> (descriptors: [BpyOutputDescriptor], data: [String: Data]) {
        let directory = outputDirectory(jobID)
        let values = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.count <= 256 else { throw CocoaError(.fileReadTooLarge) }
        var total: UInt64 = 0
        var result: [BpyOutputDescriptor] = []
        var outputData: [String: Data] = [:]
        for url in values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard isSafeName(url.lastPathComponent) else { throw CocoaError(.fileReadInvalidFileName) }
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1 else { throw CocoaError(.fileReadCorruptFile) }
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize else { throw CocoaError(.fileReadCorruptFile) }
            total += UInt64(size)
            guard total <= request.limits.outputBytes else { throw CocoaError(.fileReadTooLarge) }
            guard let mediaType = mediaType(url.pathExtension) else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let data = try Data(contentsOf: url)
            guard data.count == size else { throw CocoaError(.fileReadCorruptFile) }
            let digest = sha256(data)
            result.append(.init(
                name: url.lastPathComponent,
                byteCount: UInt64(size),
                sha256: digest,
                mediaType: mediaType
            ))
            outputData[url.lastPathComponent] = data
        }
        guard result.contains(where: { $0.name == "scene.blend" }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (result, outputData)
    }

    private func response(for job: JobRecord) -> BpyServiceResponse {
        .init(
            ok: true,
            state: job.state,
            message: job.message,
            runtime: runtimeIdentity,
            progress: job.progress,
            outputs: job.outputs,
            confirmedRevision: confirmedRevision,
            stdout: job.stdout,
            metrics: job.metrics
        )
    }

    private func readyResponse() -> BpyServiceResponse {
        lock.access {
            .init(
                ok: true,
                runtime: runtimeIdentity,
                confirmedRevision: confirmedRevision,
                metrics: ["cold_start_seconds": coldStartSeconds ?? 0]
            )
        }
    }

    private func limited(_ value: String?) -> String? {
        guard let value else { return nil }
        return String(value.prefix(request.limits.stdoutBytes))
    }

    private func stderrDiagnostic() -> String {
        lock.access {
            guard !stderrBytes.isEmpty else { return "" }
            return "\n" + String(
                decoding: stderrBytes.prefix(request.limits.stdoutBytes),
                as: UTF8.self
            )
        }
    }

    private func jobDirectory(_ jobID: UUID) -> URL {
        root.appendingPathComponent("jobs/\(jobID.uuidString)", isDirectory: true)
    }

    private func inputDirectory(_ jobID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("inputs", isDirectory: true)
    }

    private func outputDirectory(_ jobID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("outputs", isDirectory: true)
    }

    private func mediaType(_ extensionName: String) -> String? {
        switch extensionName.lowercased() {
        case "blend": "application/x-blender"
        case "png": "image/png"
        case "json": "application/json"
        default: nil
        }
    }
}

private final class BpyRuntimeService: NSObject, BpyRuntimeServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let capacity = DispatchSemaphore(value: 1)
    private var sessions: [UUID: ServiceSession] = [:]
    private let sessionsRoot: URL
    private let runtimeRoot: URL

    override init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexGenVideoBpyService", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        sessionsRoot = root
        runtimeRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("BpyRuntime", isDirectory: true)
        super.init()
    }

    func openSession(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try decoder.decode(BpyOpenSessionRequest.self, from: data)
            guard request.limits.isValid, !request.documentID.isEmpty,
                  request.documentID.count <= 256,
                  request.confirmedRevision == nil else {
                reply(failure("invalid session contract"))
                return
            }
            let session: ServiceSession = try lock.access {
                if let existing = sessions[request.sessionID] {
                    guard existing.matches(request) else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                    return existing
                }
                guard sessions.isEmpty else { throw CocoaError(.fileWriteNoPermission) }
                let session = ServiceSession(
                    request: request,
                    root: sessionsRoot.appendingPathComponent(request.sessionID.uuidString, isDirectory: true),
                    runtimeRoot: runtimeRoot,
                    capacity: capacity
                )
                sessions[request.sessionID] = session
                return session
            }
            session.open(reply: reply)
        } catch {
            reply(failure("invalid open request"))
        }
    }

    func stageInput(_ data: Data, chunk: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try decoder.decode(BpyStageInputRequest.self, from: data)
            guard let session = session(request.sessionID) else { throw CocoaError(.fileNoSuchFile) }
            try session.stage(request, chunk: chunk)
            reply(encoded(.init(ok: true)))
        } catch {
            reply(failure("input rejected: \(error.localizedDescription)"))
        }
    }

    func runJob(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try decoder.decode(BpyRunJobRequest.self, from: data)
            guard let session = session(request.sessionID) else { throw CocoaError(.fileNoSuchFile) }
            reply(encoded(session.submit(request)))
        } catch {
            reply(failure("invalid job request"))
        }
    }

    func jobStatus(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try decoder.decode(BpyJobReference.self, from: data)
            guard let session = session(request.sessionID) else { throw CocoaError(.fileNoSuchFile) }
            reply(encoded(session.status(request.jobID)))
        } catch {
            reply(failure("invalid status request"))
        }
    }

    func readOutput(_ data: Data, withReply reply: @escaping (Data, Data) -> Void) {
        do {
            let request = try decoder.decode(BpyReadOutputRequest.self, from: data)
            guard let session = session(request.sessionID) else { throw CocoaError(.fileNoSuchFile) }
            reply(encoded(.init(ok: true)), try session.output(request))
        } catch {
            reply(failure("output rejected: \(error.localizedDescription)"), Data())
        }
    }

    func confirmJob(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try decoder.decode(BpyConfirmJobRequest.self, from: data)
            guard let session = session(request.sessionID) else { throw CocoaError(.fileNoSuchFile) }
            reply(encoded(try session.confirm(request)))
        } catch {
            reply(failure("confirmation rejected: \(error.localizedDescription)"))
        }
    }

    func cancelJob(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try decoder.decode(BpyJobReference.self, from: data)
            guard let session = session(request.sessionID) else { throw CocoaError(.fileNoSuchFile) }
            reply(encoded(session.cancel(request.jobID)))
        } catch {
            reply(failure("invalid cancel request"))
        }
    }

    func closeSession(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try decoder.decode(BpySessionReference.self, from: data)
            let session = lock.access { sessions.removeValue(forKey: request.sessionID) }
            session?.close()
            reply(encoded(.init(ok: true)))
        } catch {
            reply(failure("invalid close request"))
        }
    }

    func shutdown(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        let closing = lock.access { () -> [ServiceSession] in
            let values = Array(sessions.values)
            sessions.removeAll()
            return values
        }
        closing.forEach { $0.close() }
        reply(encoded(.init(ok: true)))
    }

    private func session(_ id: UUID) -> ServiceSession? {
        lock.access { sessions[id] }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = BpyRuntimeService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let listener = NSXPCListener.service()
let listenerDelegate = ListenerDelegate()
listener.delegate = listenerDelegate
listener.resume()
