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

@_silgen_name("proc_pid_rusage")
private func procPIDRusage(
    _ processIdentifier: pid_t,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer
) -> Int32

private let resultRetentionSeconds: TimeInterval = 15 * 60

private extension NSLock {
    func access<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func encoded(_ response: BpyServiceResponse) -> Data {
    (try? JSONEncoder().encode(response)) ?? Data()
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

private struct ProcessUsage {
    let physicalFootprint: UInt64
    let startAbsoluteTime: UInt64
}

private func processUsage(_ processIdentifier: pid_t) -> ProcessUsage? {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
    defer { buffer.deallocate() }
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
    guard procPIDRusage(processIdentifier, 4, buffer) == 0 else { return nil }
    return ProcessUsage(
        physicalFootprint: buffer.load(fromByteOffset: 72, as: UInt64.self),
        startAbsoluteTime: buffer.load(fromByteOffset: 80, as: UInt64.self)
    )
}

private func processTree(root: pid_t) -> [pid_t] {
    var visited = Set<pid_t>()
    var pending = [root]
    while let parent = pending.popLast() {
        var children = [pid_t](repeating: 0, count: 256)
        let byteCount = children.withUnsafeMutableBytes {
            procListChildPIDs(parent, $0.baseAddress, Int32($0.count))
        }
        guard byteCount > 0 else { continue }
        let count = Int(byteCount) / MemoryLayout<pid_t>.size
        for child in children.prefix(count)
            where child > 1 && visited.insert(child).inserted {
            pending.append(child)
        }
    }
    return Array(visited)
}

private func stopProcess(_ process: Process) {
    guard process.processIdentifier > 1, process.isRunning else { return }
    process.terminate()
}

private struct DirectoryUsage {
    let bytes: UInt64
    let files: Int
    let limitReason: String?
}

private func directoryUsage(
    _ roots: [URL],
    byteLimit: UInt64,
    fileLimit: Int
) throws -> DirectoryUsage {
    var bytes: UInt64 = 0
    var files = 0
    for root in roots {
        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rootBytes = rootStatus.st_blocks > 0 ? UInt64(rootStatus.st_blocks) * 512 : 0
        guard rootBytes <= byteLimit - min(bytes, byteLimit) else {
            return .init(bytes: byteLimit &+ 1, files: files, limitReason: "disk")
        }
        bytes += rootBytes
        var enumerationError: Error?
        guard let values = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let url = values.nextObject() as? URL {
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            files += 1
            if files > fileLimit {
                return .init(bytes: bytes, files: files, limitReason: "file-count")
            }
            let allocated = status.st_blocks > 0 ? UInt64(status.st_blocks) * 512 : 0
            let logical = (status.st_mode & S_IFMT) == S_IFREG && status.st_size > 0
                ? UInt64(status.st_size)
                : 0
            let size = max(allocated, logical)
            guard size <= byteLimit - min(bytes, byteLimit) else {
                return .init(bytes: byteLimit &+ 1, files: files, limitReason: "disk")
            }
            bytes += size
        }
        if let enumerationError { throw enumerationError }
        if bytes > byteLimit {
            return .init(bytes: bytes, files: files, limitReason: "disk")
        }
    }
    return .init(bytes: bytes, files: files, limitReason: nil)
}

private func fingerprint(
    request: BpyRunJobRequest,
    timeoutSeconds: Int,
    inputs: [String: (UInt64, String)]
) -> String {
    var digest = SHA256()
    func add(_ value: String?) {
        let data = Data((value ?? "<nil>").utf8)
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
        digest.update(data: data)
    }
    add("nexgenvideo/bpy-job/4")
    add(request.expectedRevision)
    add(request.timeoutSeconds.map(String.init))
    add(String(timeoutSeconds))
    add(request.source)
    request.inputNames.forEach {
        add($0)
        add(String(inputs[$0]?.0 ?? UInt64.max))
        add(inputs[$0]?.1)
    }
    request.diagnosticDeniedPaths.forEach { add($0) }
    add(request.diagnosticAutoexecPositiveControl ? "1" : "0")
    add(request.diagnosticSupervisorIdentityWriteFailure ? "1" : "0")
    add(request.diagnosticSupervisorIdentityCaptureFailure ? "1" : "0")
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private final class ResponseCallback: @unchecked Sendable {
    let body: (Data) -> Void

    init(_ body: @escaping (Data) -> Void) {
        self.body = body
    }
}

private final class BoundedLog: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ value: Data) {
        lock.access {
            let remaining = max(0, limit - data.count)
            data.append(value.prefix(remaining))
        }
    }

    var text: String {
        lock.access { String(decoding: data, as: UTF8.self) }
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
    let fingerprint: String
    let diagnosticDeniedPaths: [String]
    let diagnosticAutoexecPositiveControl: Bool
    var state: BpyRuntimeJobState = .accepted
    var message: String?
    var progress: [BpyRuntimeProgress] = []
    var outputs: [BpyOutputDescriptor] = []
    var outputData: [String: Data] = [:]
    var stdout: String?
    var metrics: [String: Double] = [:]
    var terminalAt: Date?
    var resultExpired = false
    let diagnosticSupervisorIdentityWriteFailure: Bool
    let diagnosticSupervisorIdentityCaptureFailure: Bool

    init(request: BpyRunJobRequest, timeoutSeconds: Int) {
        id = request.jobID
        source = request.source
        expectedRevision = request.expectedRevision
        inputNames = request.inputNames
        self.timeoutSeconds = timeoutSeconds
        fingerprint = request.fingerprint
        diagnosticDeniedPaths = request.diagnosticDeniedPaths
        diagnosticAutoexecPositiveControl = request.diagnosticAutoexecPositiveControl
        diagnosticSupervisorIdentityWriteFailure = request.diagnosticSupervisorIdentityWriteFailure
        diagnosticSupervisorIdentityCaptureFailure = request.diagnosticSupervisorIdentityCaptureFailure
    }

    func expireResult() {
        outputs.removeAll()
        outputData.removeAll()
        progress.removeAll()
        stdout = nil
        metrics.removeAll()
        resultExpired = true
    }
}

private struct ProbeManifest: Decodable {
    let schema: String
    let pythonVersion: String
    let bpyVersion: String
    let bpyModule: String
    let executable: String
    let processIdentifier: Int32
    let startupSeconds: Double
}

private struct VerificationScene: Codable {
    let name: String
    let width: Int
    let height: Int
    let percentage: Int
    let pixels: Int
    let engine: String
    let cyclesDevice: String?
}

private struct DenialResult: Codable {
    let denied: Bool
    let errno: Int?
}

private struct RuntimeLibraryVersion: Codable {
    let supported: Bool
    let version: [Int]
    let versionString: String
}

private struct VerificationManifest: Codable {
    let schema: String
    let jobID: String
    let fingerprint: String
    let pythonVersion: String
    let bpyVersion: String
    let executable: String
    let bpyModule: String
    let processIdentifier: Int32
    let verificationSeconds: Double
    let objects: Int
    let vertices: Int
    let polygons: Int
    let scenes: [VerificationScene]
    let objectNames: [String]
    let modifiers: [String: [String]]
    let autorunTextPresent: Bool
    let autorunMarkerAbsent: Bool
    let deniedPaths: [String: DenialResult]
    let networkDenied: DenialResult
    let secretEnvironmentAbsent: Bool
    let blenderUserConfig: String?
    let sessionRoot: String
    let blenderBuildHash: String
    let blenderBuildBranch: String
    let blenderBuildType: String
    let blenderBuildSystem: String
    let libraryVersions: [String: RuntimeLibraryVersion]
}

private struct AutoexecManifest: Decodable {
    let schema: String
    let jobID: String
    let processIdentifier: Int32
    let autorunMarkerPresent: Bool
}

private struct SupervisorWorkerIdentity: Decodable {
    let processIdentifier: Int32
    let startAbsoluteTime: UInt64
}

private struct ManagedProcessResult {
    let workerProcessIdentifier: Int32
    let exitStatus: Int32
    let duration: Double
    let peakMemoryBytes: UInt64
    let peakDiskBytes: UInt64
    let peakFileCount: Int
    let peakDescendantCount: Int
    let limitReason: String?
    let log: String
}

private final class ServiceSession: @unchecked Sendable {
    let request: BpyOpenSessionRequest
    private let root: URL
    private let runtimeRoot: URL
    private let capacity: DispatchSemaphore
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var uploads: [String: UploadRecord] = [:]
    private var checkpointUpload: UploadRecord?
    private var completedInputs: [UUID: [String: (UInt64, String)]] = [:]
    private var jobs: [UUID: JobRecord] = [:]
    private var confirmedRevision: String?
    private var confirmedSceneData: Data?
    private var activeProcess: Process?
    private var activeProcessStartAbsoluteTime: UInt64?
    private var activeProcessExecutable: String?
    private var activeProcessJobID: UUID?
    private var activeProcessAuthorizationID: UUID?
    private var activeProcessAuthorizationURL: URL?
    private var activeProcessAuthorizationToken: String?
    private var activeProcessAuthorized = false
    private var activeWorkerProcessIdentifier: Int32?
    private var runtimeIdentity: BpyRuntimeIdentity?
    private var coldStartSeconds: Double?
    private var servicePeakMemoryBytes: UInt64 = 0
    private var closed = false

    init(
        request: BpyOpenSessionRequest,
        root: URL,
        runtimeRoot: URL,
        capacity: DispatchSemaphore
    ) {
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
                guard lock.access({ !closed }) else { throw CocoaError(.fileNoSuchFile) }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                guard !request.diagnosticOpenFailure else { throw CocoaError(.executableLoad) }
                let started = ProcessInfo.processInfo.systemUptime
                let manifest = try probeRuntime()
                coldStartSeconds = ProcessInfo.processInfo.systemUptime - started
                guard manifest.schema == "nexgenvideo/bpy-probe/1",
                      manifest.pythonVersion == "3.13.15",
                      manifest.bpyVersion == "5.2.2",
                      URL(fileURLWithPath: manifest.executable).resolvingSymlinksInPath()
                        == pythonURL.resolvingSymlinksInPath(),
                      URL(fileURLWithPath: manifest.bpyModule).resolvingSymlinksInPath()
                        == bpyEntryPointURL.resolvingSymlinksInPath() else {
                    throw CocoaError(.executableLoad)
                }
                let installed = lock.access { () -> Bool in
                    guard !closed else { return false }
                    runtimeIdentity = .init(
                        pythonVersion: manifest.pythonVersion,
                        bpyVersion: manifest.bpyVersion,
                        executable: manifest.executable,
                        processIdentifier: manifest.processIdentifier,
                        serviceProcessIdentifier: getpid()
                    )
                    return true
                }
                guard installed else { throw CocoaError(.fileNoSuchFile) }
                callback.body(encoded(readyResponse()))
            } catch {
                stopActiveProcess()
                callback.body(failure("worker did not become ready: \(error.localizedDescription)"))
            }
        }
    }

    func matches(_ candidate: BpyOpenSessionRequest) -> Bool {
        request == candidate
    }

    func restore(_ request: BpyRestoreCheckpointRequest, chunk: Data) throws {
        guard let expectedRevision = confirmedRevision,
              request.revision == expectedRevision,
              isSafeName(request.revision),
              isSHA256(request.sha256),
              request.totalBytes <= self.request.limits.outputBytes,
              chunk.count <= 4 * 1_024 * 1_024,
              request.offset <= request.totalBytes,
              UInt64(chunk.count) <= request.totalBytes - request.offset,
              request.finalChunk == (
                  request.offset + UInt64(chunk.count) == request.totalBytes
              ) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try lock.access {
            guard !closed, confirmedSceneData == nil else {
                throw CocoaError(.fileWriteFileExists)
            }
            let upload: UploadRecord
            if let existing = checkpointUpload {
                upload = existing
                guard upload.totalBytes == request.totalBytes,
                      upload.expectedSHA256 == request.sha256 else {
                    throw CocoaError(.fileWriteFileExists)
                }
            } else {
                guard request.offset == 0 else { throw CocoaError(.fileWriteUnknown) }
                let url = root.appendingPathComponent("host-checkpoint.part")
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                upload = UploadRecord(
                    url: url,
                    totalBytes: request.totalBytes,
                    expectedSHA256: request.sha256,
                    handle: FileHandle(forWritingTo: url)
                )
                checkpointUpload = upload
            }
            try append(chunk, offset: request.offset, finalChunk: request.finalChunk, to: upload)
            if request.finalChunk {
                let data = try Data(contentsOf: upload.url)
                guard UInt64(data.count) == upload.totalBytes,
                      sha256(data) == upload.expectedSHA256,
                      data.starts(with: Data("BLENDER".utf8)) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                confirmedSceneData = data
                checkpointUpload = nil
                try? FileManager.default.removeItem(at: upload.url)
            }
        }
    }

    func stage(_ request: BpyStageInputRequest, chunk: Data) throws {
        guard isSafeName(request.name), isSHA256(request.sha256),
              request.totalBytes <= self.request.limits.inputBytes,
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
                      uploadingTotal <= self.request.limits.inputBytes - completedTotal,
                      request.totalBytes <= self.request.limits.inputBytes
                        - completedTotal - uploadingTotal else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                let directory = inputDirectory(request.jobID)
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
            try append(chunk, offset: request.offset, finalChunk: request.finalChunk, to: upload)
            if request.finalChunk {
                let finalURL = upload.url.deletingPathExtension()
                try FileManager.default.moveItem(at: upload.url, to: finalURL)
                uploads.removeValue(forKey: key)
                completedInputs[request.jobID, default: [:]][request.name] = (
                    request.totalBytes, request.sha256
                )
            }
        }
    }

    private func append(
        _ chunk: Data,
        offset: UInt64,
        finalChunk: Bool,
        to upload: UploadRecord
    ) throws {
        if offset < upload.receivedBytes {
            guard offset + UInt64(chunk.count) <= upload.receivedBytes else {
                throw CocoaError(.fileWriteUnknown)
            }
            var existing = Data(count: chunk.count)
            let count = existing.withUnsafeMutableBytes {
                pread(upload.handle.fileDescriptor, $0.baseAddress, chunk.count, off_t(offset))
            }
            guard count == chunk.count, existing == chunk else {
                throw CocoaError(.fileWriteFileExists)
            }
            return
        }
        guard offset == upload.receivedBytes,
              upload.receivedBytes + UInt64(chunk.count) <= upload.totalBytes else {
            throw CocoaError(.fileWriteUnknown)
        }
        try upload.handle.write(contentsOf: chunk)
        upload.receivedBytes += UInt64(chunk.count)
        if finalChunk {
            try upload.handle.synchronize()
            try upload.handle.close()
            guard upload.receivedBytes == upload.totalBytes,
                  try sha256(upload.url) == upload.expectedSHA256 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    func submit(_ request: BpyRunJobRequest) -> BpyServiceResponse {
        let decision: (JobRecord?, BpyServiceResponse) = lock.access {
            purgeExpiredResults()
            if closed {
                return (nil, .init(ok: false, message: "session is closed"))
            }
            guard isSHA256(request.fingerprint) else {
                return (nil, .init(ok: false, message: "invalid job fingerprint"))
            }
            if let existing = jobs[request.jobID] {
                guard existing.fingerprint == request.fingerprint else {
                    return (nil, .init(ok: false, message: "job ID payload mismatch"))
                }
                var response = response(for: existing)
                response.joinedExistingJob = true
                return (nil, response)
            }
            guard jobs.count < 1_024 else {
                return (nil, .init(ok: false, message: "session job limit reached; rotate the document session"))
            }
            guard !jobs.values.contains(where: {
                [.accepted, .running, .awaitingConfirmation].contains($0.state)
            }) else {
                return (nil, .init(ok: false, message: "session already has an active job"))
            }
            guard request.expectedRevision == confirmedRevision,
                  confirmedRevision == nil || confirmedSceneData != nil else {
                return (nil, .init(ok: false, message: "confirmed checkpoint is unavailable"))
            }
            let names = Set(request.inputNames)
            let inputs = completedInputs[request.jobID, default: [:]]
            guard names.count == request.inputNames.count, names.count <= 64,
                  request.inputNames.allSatisfy(isSafeName),
                  names == Set(inputs.keys) else {
                return (nil, .init(ok: false, message: "staged inputs do not match the request"))
            }
            guard request.source.utf8.count <= 4 * 1_024 * 1_024,
                  request.diagnosticDeniedPaths.count <= 8,
                  request.diagnosticDeniedPaths.allSatisfy({ $0.utf8.count <= 4_096 }) else {
                return (nil, .init(ok: false, message: "job payload exceeds the runtime limit"))
            }
            let timeout = min(
                request.timeoutSeconds ?? self.request.limits.timeoutSeconds,
                self.request.limits.timeoutSeconds
            )
            guard timeout > 0,
                  fingerprint(request: request, timeoutSeconds: timeout, inputs: inputs)
                    == request.fingerprint else {
                return (nil, .init(ok: false, message: "job fingerprint mismatch"))
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
            purgeExpiredResults()
            guard let job = jobs[jobID] else {
                return .init(ok: false, message: "unknown job")
            }
            return response(for: job)
        }
    }

    func authorize(_ request: BpyAuthorizeProcessRequest) throws -> BpyServiceResponse {
        try lock.access {
            guard !closed,
                  let job = jobs[request.jobID],
                  job.state == .running,
                  activeProcessJobID == request.jobID,
                  activeProcessAuthorizationID == request.authorizationID,
                  activeProcess?.processIdentifier == request.processIdentifier,
                  activeProcess?.isRunning == true,
                  activeProcessStartAbsoluteTime == request.processStartAbsoluteTime,
                  processUsage(request.processIdentifier)?.startAbsoluteTime
                    == request.processStartAbsoluteTime,
                  activeProcessExecutable == request.processExecutable,
                  let authorizationURL = activeProcessAuthorizationURL,
                  let authorizationToken = activeProcessAuthorizationToken else {
                throw CocoaError(.fileWriteNoPermission)
            }
            if !activeProcessAuthorized {
                try Data(authorizationToken.utf8).write(to: authorizationURL, options: .atomic)
                activeProcessAuthorized = true
            }
            return response(for: job)
        }
    }

    func output(_ request: BpyReadOutputRequest) throws -> (BpyServiceResponse, Data) {
        guard isSafeName(request.name), request.maximumBytes > 0,
              request.maximumBytes <= 4 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try lock.access {
            purgeExpiredResults()
            guard let job = jobs[request.jobID], !job.resultExpired,
                  [.awaitingConfirmation, .confirmed].contains(job.state),
                  let output = job.outputs.first(where: { $0.name == request.name }),
                  let data = job.outputData[request.name] else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            guard request.offset <= output.byteCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let end = min(output.byteCount, request.offset + UInt64(request.maximumBytes))
            return (
                response(for: job),
                data.subdata(in: Int(request.offset)..<Int(end))
            )
        }
    }

    func confirm(_ request: BpyConfirmJobRequest) throws -> BpyServiceResponse {
        guard isSafeName(request.revision), isSHA256(request.sceneSHA256) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return try lock.access {
            purgeExpiredResults()
            guard let job = jobs[request.jobID], job.state == .awaitingConfirmation,
                  !job.resultExpired else {
                throw CocoaError(.fileWriteNoPermission)
            }
            guard request.revision != confirmedRevision,
                  let confirmedData = job.outputData["scene.blend"],
                  sha256(confirmedData) == request.sceneSHA256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            confirmedRevision = request.revision
            confirmedSceneData = confirmedData
            job.state = .confirmed
            job.terminalAt = Date()
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
                job.terminalAt = Date()
                completedInputs.removeValue(forKey: jobID)
                return true
            case .awaitingConfirmation:
                job.state = .rejected
                job.message = "candidate rejected"
                job.terminalAt = Date()
                job.expireResult()
                completedInputs.removeValue(forKey: jobID)
                return true
            default:
                return false
            }
        }
        if shouldStop { stopActiveProcess() }
        try? FileManager.default.removeItem(at: jobDirectory(jobID))
        return status(jobID)
    }

    func close() {
        lock.access { closed = true }
        stopActiveProcess()
        lock.access {
            for upload in uploads.values { try? upload.handle.close() }
            try? checkpointUpload?.handle.close()
            uploads.removeAll()
            checkpointUpload = nil
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func execute(_ job: JobRecord) {
        capacity.wait()
        defer { capacity.signal() }
        let began = ProcessInfo.processInfo.systemUptime
        let deadline = began + Double(job.timeoutSeconds)
        guard lock.access({ job.state == .accepted && !closed }) else { return }
        lock.access {
            job.state = .running
            job.progress = [.init(sequence: 1, stage: "worker", fraction: 0.05)]
        }
        do {
            let directory = jobDirectory(job.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sourceURL = directory.appendingPathComponent("source.py")
            guard let source = lock.access({ job.source }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try Data(source.utf8).write(to: sourceURL, options: .atomic)
            let confirmedURL = try writeConfirmedCheckpoint(for: job)
            let writableRoot = jobWorkerDirectory(job.id)
            var jobConfiguration = baseConfiguration(
                processRoot: writableRoot,
                cpuSeconds: job.timeoutSeconds
            ).merging([
                "jobID": job.id.uuidString,
                "sessionRoot": root.path,
                "sourcePath": sourceURL.path,
                "inputDirectory": inputDirectory(job.id).path,
                "outputDirectory": outputDirectory(job.id).path,
            ]) { _, new in new }
            if let confirmedURL { jobConfiguration["confirmedScene"] = confirmedURL.path }
            let jobConfig = try writeConfiguration(
                jobConfiguration,
                at: directory.appendingPathComponent("job.json")
            )
            let worker = try runManagedProcess(
                mode: "job",
                configuration: jobConfig,
                processRoot: writableRoot,
                deadline: deadline,
                job: job,
                injectSupervisorIdentityWriteFailure: job.diagnosticSupervisorIdentityWriteFailure,
                injectSupervisorIdentityCaptureFailure: job.diagnosticSupervisorIdentityCaptureFailure
            )
            try requireSuccessful(worker, job: job)
            try enforceStoredResources(job)
            try verifyStagedInputs(job.id)
            lock.access {
                guard job.state == .running else { return }
                job.progress.append(.init(sequence: 2, stage: "verification", fraction: 0.75))
            }
            let verification = try verify(job: job, deadline: deadline)
            try enforceStoredResources(job)
            let collected = try collectOutputs(job.id)
            try enforceServiceMemory(job)
            let verificationData = try JSONEncoder().encode(verification.manifest)
            var descriptors = collected.descriptors
            var outputData = collected.data
            descriptors.append(.init(
                name: "verification.json",
                byteCount: UInt64(verificationData.count),
                sha256: sha256(verificationData),
                mediaType: "application/json"
            ))
            outputData["verification.json"] = verificationData
            let wallSeconds = ProcessInfo.processInfo.systemUptime - began
            lock.access {
                guard job.state == .running else { return }
                job.outputs = descriptors
                job.outputData = outputData
                job.stdout = String(worker.log.prefix(request.limits.stdoutBytes))
                job.metrics = [
                    "job_wall_seconds": wallSeconds,
                    "worker_wall_seconds": worker.duration,
                    "verification_seconds": verification.manifest.verificationSeconds,
                    "worker_peak_memory_bytes": Double(worker.peakMemoryBytes),
                    "verifier_peak_memory_bytes": Double(verification.process.peakMemoryBytes),
                    "service_peak_memory_bytes": Double(servicePeakMemoryBytes),
                    "disk_peak_bytes": Double(max(worker.peakDiskBytes, verification.process.peakDiskBytes)),
                    "file_peak_count": Double(max(worker.peakFileCount, verification.process.peakFileCount)),
                    "descendant_peak_count": Double(
                        max(worker.peakDescendantCount, verification.process.peakDescendantCount)
                    ),
                    "worker_process_identifier": Double(worker.workerProcessIdentifier),
                    "verifier_process_identifier": Double(verification.process.workerProcessIdentifier),
                    "objects": Double(verification.manifest.objects),
                    "vertices": Double(verification.manifest.vertices),
                    "polygons": Double(verification.manifest.polygons),
                    "rlimit_as_bytes": Double(request.limits.memoryBytes),
                ]
                if verification.autoexecPositive {
                    job.metrics["autoexec_positive_control"] = 1
                }
                job.progress.append(.init(sequence: 3, stage: "complete", fraction: 1))
                job.source = nil
                job.state = .awaitingConfirmation
                job.terminalAt = Date()
                enforceResultRetentionBudget(retaining: job.id)
            }
            try? FileManager.default.removeItem(at: directory)
        } catch {
            lock.access {
                if job.state == .running {
                    let code = (error as? CocoaError)?.code
                    if code == .fileReadTooLarge || code == .fileWriteOutOfSpace {
                        job.state = .resourceLimited
                        job.message = "job exceeded a stored-resource limit"
                    } else {
                        job.state = .crashed
                        job.message = "worker failed: \(error.localizedDescription)"
                    }
                    job.source = nil
                    job.terminalAt = Date()
                }
            }
            stopActiveProcess()
            try? FileManager.default.removeItem(at: jobDirectory(job.id))
        }
    }

    private func requireSuccessful(_ result: ManagedProcessResult, job: JobRecord) throws {
        if let reason = result.limitReason {
            lock.access {
                guard job.state == .running else { return }
                job.state = reason == "deadline" ? .timedOut : .resourceLimited
                job.message = reason == "deadline"
                    ? "job exceeded \(job.timeoutSeconds) seconds"
                    : "job exceeded the \(reason) limit"
                job.stdout = String(result.log.prefix(request.limits.stdoutBytes))
                job.source = nil
                job.terminalAt = Date()
            }
            throw CocoaError(.executableLoad)
        }
        guard lock.access({ job.state == .running }) else {
            throw CocoaError(.userCancelled)
        }
        guard result.exitStatus == 0 else {
            lock.access {
                if result.exitStatus == 71 {
                    job.state = .resourceLimited
                    job.message = "worker exhausted its address-space limit"
                } else {
                    job.state = result.exitStatus == 70 ? .failed : .crashed
                    job.message = result.exitStatus == 70
                        ? "worker rejected the job"
                        : "worker exited with status \(result.exitStatus)"
                }
                job.stdout = String(result.log.prefix(request.limits.stdoutBytes))
                job.source = nil
                job.terminalAt = Date()
            }
            throw CocoaError(.executableLoad)
        }
    }

    private func enforceStoredResources(_ job: JobRecord) throws {
        let usage = try directoryUsage(
            workerWritableRoots(job.id),
            byteLimit: request.limits.diskBytes,
            fileLimit: request.limits.files
        )
        guard let reason = usage.limitReason else { return }
        lock.access {
            guard job.state == .running else { return }
            job.state = .resourceLimited
            job.message = reason == "disk"
                ? "job exceeded the disk limit"
                : "job exceeded the file-count limit"
            job.terminalAt = Date()
        }
        throw CocoaError(.fileWriteOutOfSpace)
    }

    private func enforceServiceMemory(_ job: JobRecord) throws {
        let footprint = processUsage(getpid())?.physicalFootprint ?? 0
        lock.access { servicePeakMemoryBytes = max(servicePeakMemoryBytes, footprint) }
        guard footprint <= request.limits.memoryBytes else {
            lock.access {
                guard job.state == .running else { return }
                job.state = .resourceLimited
                job.message = "job exceeded the service-memory limit"
                job.terminalAt = Date()
            }
            throw CocoaError(.fileReadTooLarge)
        }
    }

    private func verify(
        job: JobRecord,
        deadline: Double
    ) throws -> (manifest: VerificationManifest, process: ManagedProcessResult, autoexecPositive: Bool) {
        let verificationRoot = verificationDirectory(job.id)
        try? FileManager.default.removeItem(at: verificationRoot)
        try FileManager.default.createDirectory(at: verificationRoot, withIntermediateDirectories: true)
        let manifestURL = verificationRoot.appendingPathComponent("manifest.json")
        let config = try writeConfiguration(
            baseConfiguration(processRoot: verificationRoot, cpuSeconds: job.timeoutSeconds)
                .merging([
                    "jobID": job.id.uuidString,
                    "fingerprint": job.fingerprint,
                    "scenePath": outputDirectory(job.id).appendingPathComponent("scene.blend").path,
                    "manifest": manifestURL.path,
                    "sessionRoot": root.path,
                    "diagnosticDeniedPaths": job.diagnosticDeniedPaths,
                    "limits": [
                        "objects": request.limits.objects,
                        "vertices": request.limits.vertices,
                        "polygons": request.limits.polygons,
                        "renderWidth": request.limits.renderWidth,
                        "renderHeight": request.limits.renderHeight,
                        "renderPixels": request.limits.renderPixels,
                    ],
                ]) { _, new in new },
            at: verificationRoot.appendingPathComponent("verify.json")
        )
        let result = try runManagedProcess(
            mode: "verify",
            configuration: config,
            processRoot: verificationRoot,
            deadline: deadline,
            job: job
        )
        if let reason = result.limitReason {
            lock.access {
                guard job.state == .running else { return }
                job.state = reason == "deadline" ? .timedOut : .resourceLimited
                job.message = "verification exceeded the \(reason) limit"
                job.terminalAt = Date()
            }
            throw CocoaError(.fileReadCorruptFile)
        }
        if result.exitStatus == 70 {
            lock.access {
                guard job.state == .running else { return }
                job.state = .resourceLimited
                job.message = "verified scene exceeded a structural limit"
                job.terminalAt = Date()
            }
            throw CocoaError(.fileReadTooLarge)
        }
        guard result.exitStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(VerificationManifest.self, from: data)
        guard manifest.schema == "nexgenvideo/bpy-verification/1",
              manifest.jobID == job.id.uuidString,
              manifest.fingerprint == job.fingerprint,
              manifest.processIdentifier == result.workerProcessIdentifier,
              manifest.pythonVersion == "3.13.15",
              manifest.bpyVersion == "5.2.2",
              manifest.blenderBuildHash == "d13f752e3b9c",
              manifest.libraryVersions["alembic"]?.version == [1, 8, 3],
              manifest.libraryVersions["ocio"]?.version == [2, 5, 0],
              manifest.libraryVersions["oiio"]?.version == [3, 1, 13],
              manifest.libraryVersions["opensubdiv"]?.version == [3, 7, 0],
              manifest.libraryVersions["openvdb"]?.version == [13, 0, 0],
              manifest.libraryVersions["usd"]?.version == [0, 26, 3],
              URL(fileURLWithPath: manifest.executable).resolvingSymlinksInPath()
                == pythonURL.resolvingSymlinksInPath(),
              URL(fileURLWithPath: manifest.bpyModule).resolvingSymlinksInPath()
                == bpyEntryPointURL.resolvingSymlinksInPath(),
              manifest.autorunMarkerAbsent else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var positive = false
        if job.diagnosticAutoexecPositiveControl {
            positive = try runAutoexecPositiveControl(job: job, deadline: deadline)
        }
        return (manifest, result, positive)
    }

    private func runAutoexecPositiveControl(job: JobRecord, deadline: Double) throws -> Bool {
        let controlRoot = autoexecDirectory(job.id)
        try FileManager.default.createDirectory(at: controlRoot, withIntermediateDirectories: true)
        let manifestURL = controlRoot.appendingPathComponent("manifest.json")
        let config = try writeConfiguration(
            baseConfiguration(processRoot: controlRoot, cpuSeconds: job.timeoutSeconds)
                .merging([
                    "jobID": job.id.uuidString,
                    "scenePath": outputDirectory(job.id).appendingPathComponent("scene.blend").path,
                    "manifest": manifestURL.path,
                ]) { _, new in new },
            at: controlRoot.appendingPathComponent("autoexec.json")
        )
        let result = try runManagedProcess(
            mode: "autoexec-positive",
            configuration: config,
            processRoot: controlRoot,
            deadline: deadline,
            job: job
        )
        guard result.limitReason == nil, result.exitStatus == 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let manifest = try JSONDecoder().decode(
            AutoexecManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schema == "nexgenvideo/bpy-autoexec-positive/1",
              manifest.jobID == job.id.uuidString,
              manifest.processIdentifier == result.workerProcessIdentifier,
              manifest.autorunMarkerPresent else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return true
    }

    private func probeRuntime() throws -> ProbeManifest {
        let probeRoot = root.appendingPathComponent("probe-worker", isDirectory: true)
        try? FileManager.default.removeItem(at: probeRoot)
        try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        let manifestURL = probeRoot.appendingPathComponent("manifest.json")
        let config = try writeConfiguration(
            baseConfiguration(processRoot: probeRoot, cpuSeconds: 120)
                .merging(["manifest": manifestURL.path]) { _, new in new },
            at: probeRoot.appendingPathComponent("probe.json")
        )
        let result = try runManagedProcess(
            mode: "probe",
            configuration: config,
            processRoot: probeRoot,
            deadline: ProcessInfo.processInfo.systemUptime + 120,
            job: nil
        )
        guard result.limitReason == nil, result.exitStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
        let manifest = try JSONDecoder().decode(
            ProbeManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.processIdentifier == result.workerProcessIdentifier else {
            throw CocoaError(.executableLoad)
        }
        try? FileManager.default.removeItem(at: probeRoot)
        return manifest
    }

    private func runManagedProcess(
        mode: String,
        configuration: URL,
        processRoot: URL,
        deadline: Double,
        job: JobRecord?,
        injectSupervisorIdentityWriteFailure: Bool = false,
        injectSupervisorIdentityCaptureFailure: Bool = false
    ) throws -> ManagedProcessResult {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path),
              FileManager.default.isExecutableFile(atPath: supervisorURL.path),
              FileManager.default.fileExists(atPath: workerURL.path),
              FileManager.default.fileExists(atPath: sitePackagesURL.path) else {
            throw CocoaError(.executableNotLoadable)
        }
        for name in ["tmp", "home", "blender-config", "blender-scripts", "blender-data"] {
            try FileManager.default.createDirectory(
                at: processRoot.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let output = Pipe()
        let errors = Pipe()
        let log = BoundedLog(limit: request.limits.stdoutBytes)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { log.append(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { log.append(data) }
        }
        let controlRoot = root.appendingPathComponent(
            "process-control/\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: controlRoot, withIntermediateDirectories: true)
        let authorizationURL = controlRoot.appendingPathComponent("authorized")
        let identityURL = controlRoot.appendingPathComponent("worker.json")
        let authorizationID = UUID()
        let authorizationToken = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
        guard let serviceUsage = processUsage(getpid()) else {
            throw CocoaError(.executableLoad)
        }
        if job == nil {
            try Data(authorizationToken.utf8).write(to: authorizationURL, options: .atomic)
        }
        let process = Process()
        process.executableURL = supervisorURL
        process.arguments = [
            "supervise",
            String(getpid()),
            String(serviceUsage.startAbsoluteTime),
            authorizationURL.path,
            authorizationToken,
            identityURL.path,
            processRoot.path,
            pythonURL.path,
            workerURL.path,
            mode,
            configuration.path,
        ]
        process.currentDirectoryURL = processRoot
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        var environment = [
            "HOME": processRoot.appendingPathComponent("home").path,
            "TMPDIR": processRoot.appendingPathComponent("tmp").path,
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "BLENDER_USER_CONFIG": processRoot.appendingPathComponent("blender-config").path,
            "BLENDER_USER_SCRIPTS": processRoot.appendingPathComponent("blender-scripts").path,
            "BLENDER_USER_DATAFILES": processRoot.appendingPathComponent("blender-data").path,
        ]
        if injectSupervisorIdentityWriteFailure {
            environment["NGV_BPY_SUPERVISOR_FAIL_AFTER_CHILD_START"] = "1"
        }
        if injectSupervisorIdentityCaptureFailure {
            environment["NGV_BPY_SUPERVISOR_FAIL_CHILD_IDENTITY_CAPTURE"] = "1"
            environment["NGV_BPY_SUPERVISOR_CHILD_IGNORE_TERM"] = "1"
        }
        process.environment = environment
        let began = ProcessInfo.processInfo.systemUptime
        try process.run()
        let supervisorProcessIdentifier = process.processIdentifier
        lock.access { activeProcess = process }
        defer {
            if process.isRunning {
                stopProcess(process)
                process.waitUntilExit()
            }
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            lock.access {
                if activeProcess === process {
                    activeProcess = nil
                    activeProcessStartAbsoluteTime = nil
                    activeProcessExecutable = nil
                    activeProcessJobID = nil
                    activeProcessAuthorizationID = nil
                    activeProcessAuthorizationURL = nil
                    activeProcessAuthorizationToken = nil
                    activeProcessAuthorized = false
                    activeWorkerProcessIdentifier = nil
                }
            }
            try? FileManager.default.removeItem(at: controlRoot)
        }
        var initialUsage: ProcessUsage?
        for _ in 0..<20 where initialUsage == nil && process.isRunning {
            initialUsage = processUsage(supervisorProcessIdentifier)
            if initialUsage == nil { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard let initialUsage else {
            stopProcess(process)
            process.waitUntilExit()
            throw CocoaError(.executableLoad)
        }
        lock.access {
            guard activeProcess === process else { return }
            activeProcessStartAbsoluteTime = initialUsage.startAbsoluteTime
            activeProcessExecutable = supervisorURL.resolvingSymlinksInPath().path
            activeProcessJobID = job?.id
            activeProcessAuthorizationID = job == nil ? nil : authorizationID
            activeProcessAuthorizationURL = job == nil ? nil : authorizationURL
            activeProcessAuthorizationToken = job == nil ? nil : authorizationToken
            activeProcessAuthorized = job == nil
        }
        var peakMemory = initialUsage.physicalFootprint
        var peakDisk: UInt64 = 0
        var peakFiles = 0
        var peakDescendants = 0
        var limitReason: String?
        var workerIdentity: SupervisorWorkerIdentity?
        while process.isRunning {
            let now = ProcessInfo.processInfo.systemUptime
            let descendants = processTree(root: supervisorProcessIdentifier)
            let unexpectedDescendants = max(0, descendants.count - 1)
            peakDescendants = max(peakDescendants, unexpectedDescendants)
            let processFootprint = ([supervisorProcessIdentifier] + descendants)
                .compactMap { processUsage($0)?.physicalFootprint }
                .reduce(UInt64(0), +)
            peakMemory = max(peakMemory, processFootprint)
            if workerIdentity == nil,
               let data = try? Data(contentsOf: identityURL),
               let decoded = try? JSONDecoder().decode(SupervisorWorkerIdentity.self, from: data),
               processUsage(decoded.processIdentifier)?.startAbsoluteTime == decoded.startAbsoluteTime {
                workerIdentity = decoded
                lock.access {
                    if activeProcess === process {
                        activeWorkerProcessIdentifier = decoded.processIdentifier
                    }
                }
            }
            let serviceFootprint = processUsage(getpid())?.physicalFootprint ?? 0
            lock.access {
                servicePeakMemoryBytes = max(servicePeakMemoryBytes, serviceFootprint)
            }
            let resourceRoots = job.map { workerWritableRoots($0.id) } ?? [processRoot]
            let disk = try directoryUsage(
                resourceRoots,
                byteLimit: request.limits.diskBytes,
                fileLimit: request.limits.files
            )
            peakDisk = max(peakDisk, disk.bytes)
            peakFiles = max(peakFiles, disk.files)
            if lock.access({ closed || activeProcess !== process }) {
                stopProcess(process)
            } else if let job, lock.access({ job.state != .running }) {
                stopProcess(process)
            } else if now >= deadline {
                limitReason = "deadline"
                stopProcess(process)
            } else if peakMemory > request.limits.memoryBytes {
                limitReason = "memory"
                stopProcess(process)
            } else if serviceFootprint > request.limits.memoryBytes {
                limitReason = "service-memory"
                stopProcess(process)
            } else if let resourceReason = disk.limitReason {
                limitReason = resourceReason
                stopProcess(process)
            } else if unexpectedDescendants > 0 {
                limitReason = "process-count"
                stopProcess(process)
            }
            if process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let remainingOutput = output.fileHandleForReading.readDataToEndOfFile()
        let remainingErrors = errors.fileHandleForReading.readDataToEndOfFile()
        log.append(remainingOutput)
        log.append(remainingErrors)
        if workerIdentity == nil,
           let data = try? Data(contentsOf: identityURL) {
            workerIdentity = try? JSONDecoder().decode(SupervisorWorkerIdentity.self, from: data)
        }
        return ManagedProcessResult(
            workerProcessIdentifier: workerIdentity?.processIdentifier ?? -1,
            exitStatus: process.terminationStatus,
            duration: ProcessInfo.processInfo.systemUptime - began,
            peakMemoryBytes: peakMemory,
            peakDiskBytes: peakDisk,
            peakFileCount: peakFiles,
            peakDescendantCount: peakDescendants,
            limitReason: limitReason,
            log: log.text
        )
    }

    private func stopActiveProcess() {
        guard let process = lock.access({ activeProcess }) else { return }
        stopProcess(process)
        while lock.access({ activeProcess === process }) {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func baseConfiguration(processRoot: URL, cpuSeconds: Int) -> [String: Any] {
        [
            "sitePackages": sitePackagesURL.path,
            "memoryBytes": request.limits.memoryBytes,
            "outputBytes": request.limits.outputBytes,
            "cpuSeconds": max(2, cpuSeconds + 1),
        ]
    }

    private func writeConfiguration(_ value: [String: Any], at url: URL) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }

    private func writeConfirmedCheckpoint(for job: JobRecord) throws -> URL? {
        guard let data = lock.access({ confirmedSceneData }) else { return nil }
        let directory = jobDirectory(job.id).appendingPathComponent("bootstrap", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("confirmed.blend")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func verifyStagedInputs(_ jobID: UUID) throws {
        let values = lock.access { completedInputs[jobID, default: [:]] }
        for (name, expected) in values {
            let url = inputDirectory(jobID).appendingPathComponent(name)
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1,
                  UInt64(status.st_size) == expected.0,
                  try sha256(url) == expected.1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private func collectOutputs(
        _ jobID: UUID
    ) throws -> (descriptors: [BpyOutputDescriptor], data: [String: Data]) {
        let directory = outputDirectory(jobID)
        let values = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard values.count <= min(256, request.limits.files) else {
            throw CocoaError(.fileReadTooLarge)
        }
        var total: UInt64 = 0
        var result: [BpyOutputDescriptor] = []
        var outputData: [String: Data] = [:]
        for url in values.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard isSafeName(url.lastPathComponent),
                  url.lastPathComponent != "verification.json" else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1,
                  status.st_size >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            total += UInt64(status.st_size)
            guard total <= request.limits.outputBytes,
                  let mediaType = mediaType(url.pathExtension) else {
                throw CocoaError(.fileReadTooLarge)
            }
            let data = try Data(contentsOf: url)
            guard Int64(data.count) == Int64(status.st_size) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try validateMagic(data, mediaType: mediaType)
            if mediaType == "image/png" { try validatePNGDimensions(data) }
            let digest = sha256(data)
            result.append(.init(
                name: url.lastPathComponent,
                byteCount: UInt64(data.count),
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

    private func validateMagic(_ data: Data, mediaType: String) throws {
        let valid: Bool
        switch mediaType {
        case "application/x-blender":
            valid = data.starts(with: Data("BLENDER".utf8))
        case "image/png":
            valid = data.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        case "application/json":
            valid = (try? JSONSerialization.jsonObject(with: data)) != nil
        default:
            valid = false
        }
        guard valid else { throw CocoaError(.fileReadCorruptFile) }
    }

    private func validatePNGDimensions(_ data: Data) throws {
        guard data.count >= 24 else { throw CocoaError(.fileReadCorruptFile) }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard width > 0, height > 0,
              width <= request.limits.renderWidth,
              height <= request.limits.renderHeight,
              UInt64(width) * UInt64(height) <= UInt64(request.limits.renderPixels) else {
            throw CocoaError(.fileReadTooLarge)
        }
    }

    private func purgeExpiredResults() {
        let cutoff = Date().addingTimeInterval(-resultRetentionSeconds)
        for job in jobs.values where job.terminalAt.map({ $0 < cutoff }) == true {
            if job.state == .awaitingConfirmation {
                job.state = .rejected
                job.message = "candidate result expired"
            }
            job.expireResult()
            completedInputs.removeValue(forKey: job.id)
        }
    }

    private func enforceResultRetentionBudget(retaining retainedID: UUID) {
        let budget = min(
            request.limits.diskBytes,
            min(request.limits.memoryBytes / 2, request.limits.outputBytes * 4)
        )
        var retainedBytes = jobs.values.reduce(UInt64(0)) { partial, job in
            partial + job.outputs.reduce(UInt64(0)) { $0 + $1.byteCount }
        }
        let candidates = jobs.values
            .filter { $0.id != retainedID && !$0.resultExpired && $0.terminalAt != nil }
            .sorted { ($0.terminalAt ?? .distantFuture) < ($1.terminalAt ?? .distantFuture) }
        for candidate in candidates where retainedBytes > budget {
            let bytes = candidate.outputs.reduce(UInt64(0)) { $0 + $1.byteCount }
            if candidate.state == .awaitingConfirmation {
                candidate.state = .rejected
                candidate.message = "candidate result expired under the session retention budget"
            }
            candidate.expireResult()
            completedInputs.removeValue(forKey: candidate.id)
            retainedBytes = retainedBytes > bytes ? retainedBytes - bytes : 0
        }
    }

    private func response(for job: JobRecord) -> BpyServiceResponse {
        let ownsActiveProcess = activeProcessJobID == job.id
        return .init(
            ok: true,
            jobID: job.id,
            state: job.state,
            message: job.message,
            runtime: runtimeIdentity,
            progress: job.progress,
            outputs: job.outputs,
            confirmedRevision: confirmedRevision,
            stdout: job.stdout,
            metrics: job.metrics,
            jobFingerprint: job.fingerprint,
            resultExpired: job.resultExpired,
            activeProcessIdentifier: ownsActiveProcess ? activeProcess?.processIdentifier : nil,
            activeProcessStartAbsoluteTime: ownsActiveProcess ? activeProcessStartAbsoluteTime : nil,
            activeProcessExecutable: ownsActiveProcess ? activeProcessExecutable : nil,
            activeProcessAuthorizationID: ownsActiveProcess && !activeProcessAuthorized
                ? activeProcessAuthorizationID
                : nil,
            activeWorkerProcessIdentifier: ownsActiveProcess ? activeWorkerProcessIdentifier : nil
        )
    }

    private func readyResponse() -> BpyServiceResponse {
        lock.access {
            .init(
                ok: true,
                runtime: runtimeIdentity,
                confirmedRevision: confirmedRevision,
                metrics: [
                    "cold_start_seconds": coldStartSeconds ?? 0,
                    "service_peak_memory_bytes": Double(servicePeakMemoryBytes),
                ]
            )
        }
    }

    private var pythonURL: URL {
        runtimeRoot.appendingPathComponent("python/bin/python3")
    }

    private var workerURL: URL {
        runtimeRoot.appendingPathComponent("worker.py")
    }

    private var supervisorURL: URL {
        runtimeRoot.deletingLastPathComponent()
            .appendingPathComponent("NexGenVideoBpySupervisor")
    }

    private var sitePackagesURL: URL {
        runtimeRoot.appendingPathComponent("site-packages")
    }

    private var bpyEntryPointURL: URL {
        sitePackagesURL.appendingPathComponent("bpy/__init__.so")
    }

    private func jobDirectory(_ jobID: UUID) -> URL {
        root.appendingPathComponent("jobs/\(jobID.uuidString)", isDirectory: true)
    }

    private func inputDirectory(_ jobID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("inputs", isDirectory: true)
    }

    private func outputDirectory(_ jobID: UUID) -> URL {
        jobWorkerDirectory(jobID).appendingPathComponent("outputs", isDirectory: true)
    }

    private func jobWorkerDirectory(_ jobID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("worker", isDirectory: true)
    }

    private func verificationDirectory(_ jobID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("verification", isDirectory: true)
    }

    private func autoexecDirectory(_ jobID: UUID) -> URL {
        jobDirectory(jobID).appendingPathComponent("autoexec-positive", isDirectory: true)
    }

    private func workerWritableRoots(_ jobID: UUID) -> [URL] {
        [jobWorkerDirectory(jobID), verificationDirectory(jobID), autoexecDirectory(jobID)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
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
            let request = try JSONDecoder().decode(BpyOpenSessionRequest.self, from: data)
            guard request.limits.isValid, !request.documentID.isEmpty,
                  request.documentID.count <= 256,
                  request.confirmedRevision.map(isSafeName) ?? true else {
                reply(failure("invalid session contract"))
                return
            }
            var retired: ServiceSession?
            let session: ServiceSession = try lock.access {
                if let existing = sessions[request.sessionID] {
                    guard existing.matches(request) else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                    return existing
                }
                if let existing = sessions.values.first {
                    guard sessions.count == 1,
                          existing.request.documentID == request.documentID else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    retired = existing
                    sessions.removeAll()
                }
                let session = ServiceSession(
                    request: request,
                    root: sessionsRoot.appendingPathComponent(
                        request.sessionID.uuidString,
                        isDirectory: true
                    ),
                    runtimeRoot: runtimeRoot,
                    capacity: capacity
                )
                sessions[request.sessionID] = session
                return session
            }
            retired?.close()
            session.open { [weak self, weak session] response in
                if (try? JSONDecoder().decode(BpyServiceResponse.self, from: response).ok) != true,
                   let self, let session {
                    let removed = self.lock.access { () -> ServiceSession? in
                        guard self.sessions[request.sessionID] === session else { return nil }
                        return self.sessions.removeValue(forKey: request.sessionID)
                    }
                    removed?.close()
                }
                reply(response)
            }
        } catch {
            reply(failure("invalid open request"))
        }
    }

    func restoreCheckpoint(_ data: Data, chunk: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyRestoreCheckpointRequest.self, from: data)
            guard let session = session(request.sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try session.restore(request, chunk: chunk)
            reply(encoded(.init(ok: true, confirmedRevision: request.revision)))
        } catch {
            reply(failure("checkpoint rejected: \(error.localizedDescription)"))
        }
    }

    func stageInput(_ data: Data, chunk: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyStageInputRequest.self, from: data)
            guard let session = session(request.sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try session.stage(request, chunk: chunk)
            reply(encoded(.init(ok: true)))
        } catch {
            reply(failure("input rejected: \(error.localizedDescription)"))
        }
    }

    func runJob(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyRunJobRequest.self, from: data)
            guard let session = session(request.sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(session.submit(request)))
        } catch {
            reply(failure("invalid job request"))
        }
    }

    func jobStatus(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyJobReference.self, from: data)
            guard let session = session(request.sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(session.status(request.jobID)))
        } catch {
            reply(failure("invalid status request"))
        }
    }

    func authorizeProcess(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyAuthorizeProcessRequest.self, from: data)
            guard let session = session(request.sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(try session.authorize(request)))
        } catch {
            reply(failure("process authorization rejected"))
        }
    }

    func readOutput(_ data: Data, withReply reply: @escaping (Data, Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyReadOutputRequest.self, from: data)
            guard let session = session(request.sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let result = try session.output(request)
            reply(encoded(result.0), result.1)
        } catch {
            reply(failure("output rejected: \(error.localizedDescription)"), Data())
        }
    }

    func confirmJob(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyConfirmJobRequest.self, from: data)
            guard let session = session(request.sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(try session.confirm(request)))
        } catch {
            reply(failure("confirmation rejected: \(error.localizedDescription)"))
        }
    }

    func cancelJob(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpyJobReference.self, from: data)
            guard let session = session(request.sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reply(encoded(session.cancel(request.jobID)))
        } catch {
            reply(failure("invalid cancel request"))
        }
    }

    func closeSession(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try JSONDecoder().decode(BpySessionReference.self, from: data)
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

    func invalidateSessions(_ identifiers: Set<UUID>) {
        let closing = lock.access { () -> [ServiceSession] in
            identifiers.compactMap { sessions.removeValue(forKey: $0) }
        }
        closing.forEach { $0.close() }
    }
}

private final class BpyRuntimeConnection: NSObject, BpyRuntimeServiceProtocol, @unchecked Sendable {
    private let service: BpyRuntimeService
    private let lock = NSLock()
    private var sessionIDs = Set<UUID>()
    private var invalidated = false

    init(service: BpyRuntimeService) {
        self.service = service
    }

    private func owns<T: Decodable>(
        _ type: T.Type,
        request: Data,
        sessionID: (T) -> UUID
    ) -> Bool {
        guard let value = try? JSONDecoder().decode(type, from: request) else { return false }
        return lock.access { !invalidated && sessionIDs.contains(sessionID(value)) }
    }

    func openSession(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let value = try? JSONDecoder().decode(BpyOpenSessionRequest.self, from: request),
              lock.access({ () -> Bool in
                  guard !invalidated else { return false }
                  sessionIDs.insert(value.sessionID)
                  return true
              }) else {
            reply(failure("XPC connection is unavailable"))
            return
        }
        service.openSession(request, withReply: reply)
        if lock.access({ invalidated }) {
            service.invalidateSessions([value.sessionID])
        }
    }

    func restoreCheckpoint(_ request: Data, chunk: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyRestoreCheckpointRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.restoreCheckpoint(request, chunk: chunk, withReply: reply)
    }

    func stageInput(_ request: Data, chunk: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyStageInputRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.stageInput(request, chunk: chunk, withReply: reply)
    }

    func runJob(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyRunJobRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.runJob(request, withReply: reply)
    }

    func jobStatus(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyJobReference.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.jobStatus(request, withReply: reply)
    }

    func authorizeProcess(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyAuthorizeProcessRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.authorizeProcess(request, withReply: reply)
    }

    func readOutput(_ request: Data, withReply reply: @escaping (Data, Data) -> Void) {
        guard owns(BpyReadOutputRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"), Data())
            return
        }
        service.readOutput(request, withReply: reply)
    }

    func confirmJob(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyConfirmJobRequest.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.confirmJob(request, withReply: reply)
    }

    func cancelJob(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard owns(BpyJobReference.self, request: request, sessionID: { $0.sessionID }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.cancelJob(request, withReply: reply)
    }

    func closeSession(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard let value = try? JSONDecoder().decode(BpySessionReference.self, from: request),
              lock.access({ !invalidated && sessionIDs.remove(value.sessionID) != nil }) else {
            reply(failure("XPC session is unavailable"))
            return
        }
        service.closeSession(request, withReply: reply)
    }

    func shutdown(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let identifiers = lock.access { () -> Set<UUID> in
            let value = sessionIDs
            sessionIDs.removeAll()
            return value
        }
        service.invalidateSessions(identifiers)
        reply(encoded(.init(ok: true)))
    }

    func invalidate() {
        let identifiers = lock.access { () -> Set<UUID> in
            invalidated = true
            let value = sessionIDs
            sessionIDs.removeAll()
            return value
        }
        service.invalidateSessions(identifiers)
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = BpyRuntimeService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let exported = BpyRuntimeConnection(service: service)
        connection.exportedInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        connection.exportedObject = exported
        connection.interruptionHandler = { [weak exported] in exported?.invalidate() }
        connection.invalidationHandler = { [weak exported] in exported?.invalidate() }
        connection.resume()
        return true
    }
}

let listener = NSXPCListener.service()
let listenerDelegate = ListenerDelegate()
listener.delegate = listenerDelegate
listener.resume()
