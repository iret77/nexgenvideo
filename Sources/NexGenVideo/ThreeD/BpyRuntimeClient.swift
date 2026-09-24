import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

private let bpyHostResultRetentionSeconds: TimeInterval = 15 * 60

@_silgen_name("proc_pid_rusage")
private func procPIDRusage(
    _ processIdentifier: pid_t,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer
) -> Int32

@_silgen_name("proc_pidpath")
private func procPIDPath(
    _ processIdentifier: pid_t,
    _ buffer: UnsafeMutableRawPointer,
    _ bufferSize: UInt32
) -> Int32

private struct BpyProcessLease {
    let transportID: UUID
    let processIdentifier: pid_t
    let startAbsoluteTime: UInt64
    let executable: String
}

private func processStartAbsoluteTime(_ processIdentifier: pid_t) -> UInt64? {
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
    defer { buffer.deallocate() }
    buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
    guard procPIDRusage(processIdentifier, 4, buffer) == 0 else { return nil }
    return buffer.load(fromByteOffset: 80, as: UInt64.self)
}

private func processExecutable(_ processIdentifier: pid_t) -> String? {
    var bytes = [UInt8](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
    let count = bytes.withUnsafeMutableBytes {
        guard let base = $0.baseAddress else { return Int32(0) }
        return procPIDPath(processIdentifier, base, UInt32($0.count))
    }
    guard count > 0 else { return nil }
    return bytes.withUnsafeBytes {
        String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
    }
}

private func terminateLeasedProcess(_ lease: BpyProcessLease) -> Bool {
    guard lease.processIdentifier > 1,
          processStartAbsoluteTime(lease.processIdentifier) == lease.startAbsoluteTime,
          processExecutable(lease.processIdentifier) == lease.executable else {
        return true
    }
    guard Darwin.kill(lease.processIdentifier, SIGTERM) == 0 || errno == ESRCH else {
        return false
    }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        guard processStartAbsoluteTime(lease.processIdentifier) == lease.startAbsoluteTime,
              processExecutable(lease.processIdentifier) == lease.executable else {
            return true
        }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return false
}

enum BpyRuntimeError: LocalizedError {
    case unavailable(String)
    case invalidInput(String)
    case rejected(String)
    case timedOut
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidInput(let message),
             .rejected(let message), .invalidOutput(let message):
            message
        case .timedOut:
            "The 3D runtime did not respond in time."
        }
    }
}

struct BpyApprovedInputCopy: Sendable, Equatable {
    let approvedDirectory: URL
    let filename: String

    init(approvedDirectory: URL, filename: String) throws {
        guard approvedDirectory.isFileURL,
              filename.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression
              ) != nil else {
            throw BpyRuntimeError.invalidInput("Invalid approved input name.")
        }
        self.approvedDirectory = approvedDirectory.standardizedFileURL
        self.filename = filename
    }
}

struct BpyRuntimeJobResult: Sendable {
    let response: BpyServiceResponse
    let stagedOutputs: [String: URL]
}

private final class BpyReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: Data?
    private var chunk: Data?
    private var error: Error?
    private var completed = false

    func store(response: Data, chunk: Data? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        self.response = response
        self.chunk = chunk
        return true
    }

    func store(error: Error) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        self.error = error
        return true
    }

    func load() -> (Data?, Data?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (response, chunk, error)
    }
}

private final class PreparedBpyInput {
    let input: BpyApprovedInputCopy
    let handle: FileHandle
    let before: stat
    let totalBytes: UInt64
    let sha256: String

    init(
        input: BpyApprovedInputCopy,
        handle: FileHandle,
        before: stat,
        totalBytes: UInt64,
        sha256: String
    ) {
        self.input = input
        self.handle = handle
        self.before = before
        self.totalBytes = totalBytes
        self.sha256 = sha256
    }
}

final class BpyRuntimeSession: @unchecked Sendable {
    private(set) var sessionID: UUID
    let documentID: String
    let limits: BpyRuntimeLimits
    let serviceName: String

    private let stagingRoot: URL
    private let diagnosticOpenFailure: Bool
    private let lock = NSLock()
    private let openLock = NSLock()
    private let submissionLock = NSLock()
    private var connection: NSXPCConnection?
    private var opened = false
    private var transportInvalidated = false
    private var transportRecoveryBlocked = false
    private var closing = false
    private var closed = false
    private var validatedCandidates: [UUID: (sha256: String, url: URL)] = [:]
    private var candidateJobIDs = Set<UUID>()
    private var jobFingerprints: [UUID: String] = [:]
    private var submittedJobIDs = Set<UUID>()
    private var submittedTransportIDs: [UUID: UUID] = [:]
    private var cachedResults: [UUID: BpyRuntimeJobResult] = [:]
    private var cachedResultOrder: [UUID] = []
    private var cachedResultDates: [UUID: Date] = [:]
    private var lastReadyResponse: BpyServiceResponse?
    private var confirmedSceneData: Data?
    private var activeProcessLease: BpyProcessLease?
    private(set) var confirmedRevision: String?

    init(
        documentID: String,
        limits: BpyRuntimeLimits = .init(),
        serviceName: String = bpyRuntimeServiceNames[0],
        diagnosticOpenFailure: Bool = false
    ) {
        let identifier = UUID()
        sessionID = UUID()
        self.documentID = documentID
        self.confirmedRevision = nil
        self.limits = limits
        self.serviceName = serviceName
        self.diagnosticOpenFailure = diagnosticOpenFailure
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NexGenVideo/BpyHost/\(identifier.uuidString)", isDirectory: true)
        installConnection()
    }

    deinit {
        close()
    }

    var occupiesHostSlot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && !closing
    }

    func ready() throws -> BpyServiceResponse {
        try ensureOpen()
    }

    func runJob(
        id: UUID,
        expectedRevision: String?,
        source: String,
        inputs: [BpyApprovedInputCopy] = [],
        timeoutSeconds: Int? = nil,
        diagnosticDeniedPaths: [String] = [],
        diagnosticAutoexecPositiveControl: Bool = false,
        diagnosticDeferExecutionAuthorization: Bool = false,
        diagnosticSupervisorIdentityWriteFailure: Bool = false,
        diagnosticSupervisorIdentityCaptureFailure: Bool = false
    ) throws -> BpyRuntimeJobResult {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        _ = try ensureOpen()
        purgeExpiredHostResults()
        let prepared = try inputs.map(prepare)
        let timeout = min(timeoutSeconds ?? limits.timeoutSeconds, limits.timeoutSeconds)
        let transportID = currentSessionID()
        let fingerprint = Self.fingerprint(
            expectedRevision: expectedRevision,
            source: source,
            requestedTimeoutSeconds: timeoutSeconds,
            effectiveTimeoutSeconds: timeout,
            inputs: prepared,
            diagnosticDeniedPaths: diagnosticDeniedPaths,
            diagnosticAutoexecPositiveControl: diagnosticAutoexecPositiveControl,
            diagnosticSupervisorIdentityWriteFailure: diagnosticSupervisorIdentityWriteFailure,
            diagnosticSupervisorIdentityCaptureFailure: diagnosticSupervisorIdentityCaptureFailure
        )
        lock.lock()
        let knownFingerprint = jobFingerprints[id]
        let cached = cachedResults[id]
        lock.unlock()
        if let knownFingerprint {
            guard knownFingerprint == fingerprint else {
                throw BpyRuntimeError.rejected("A Job ID cannot be reused with different source, inputs, revision, or options.")
            }
            if let cached {
                var response = cached.response
                response.joinedExistingJob = true
                return .init(response: response, stagedOutputs: cached.stagedOutputs)
            }
            lock.lock()
            let submittedTransportID = submittedTransportIDs[id]
            lock.unlock()
            guard submittedTransportID == nil || submittedTransportID == transportID else {
                throw BpyRuntimeError.rejected(
                    "The prior execution outcome is unavailable after 3D transport recovery; the Job ID will not run again."
                )
            }
        } else {
            lock.lock()
            guard jobFingerprints.count < 1_024 else {
                lock.unlock()
                throw BpyRuntimeError.rejected(
                    "The document 3D session reached its Job ID limit; rotate only from confirmed state."
                )
            }
            jobFingerprints[id] = fingerprint
            lock.unlock()
        }
        lock.lock()
        let needsUpload = !submittedJobIDs.contains(id)
        lock.unlock()
        if needsUpload {
            for value in prepared {
                try upload(value, jobID: id)
            }
            lock.lock()
            submittedJobIDs.insert(id)
            submittedTransportIDs[id] = transportID
            lock.unlock()
        }
        let request = BpyRunJobRequest(
            sessionID: transportID,
            jobID: id,
            expectedRevision: expectedRevision,
            source: source,
            inputNames: inputs.map(\.filename),
            timeoutSeconds: timeoutSeconds,
            fingerprint: fingerprint,
            diagnosticDeniedPaths: diagnosticDeniedPaths,
            diagnosticAutoexecPositiveControl: diagnosticAutoexecPositiveControl,
            diagnosticSupervisorIdentityWriteFailure: diagnosticSupervisorIdentityWriteFailure,
            diagnosticSupervisorIdentityCaptureFailure: diagnosticSupervisorIdentityCaptureFailure
        )
        let response = try call { service, reply in
            service.runJob(try Self.encode(request), withReply: reply)
        }
        guard response.ok else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D job was rejected.")
        }
        guard response.jobID == id, response.jobFingerprint == fingerprint else {
            throw BpyRuntimeError.invalidOutput("The 3D service returned the wrong job identity.")
        }
        if response.resultExpired {
            throw BpyRuntimeError.rejected("The retained result for this Job ID has expired; it will not run again.")
        }
        let result = try finish(
            jobID: id,
            fingerprint: fingerprint,
            response: response,
            timeoutSeconds: timeout,
            diagnosticDeferExecutionAuthorization: diagnosticDeferExecutionAuthorization
        )
        cache(result, for: id)
        return result
    }

    private func finish(
        jobID: UUID,
        fingerprint: String,
        response initialResponse: BpyServiceResponse,
        timeoutSeconds: Int,
        diagnosticDeferExecutionAuthorization: Bool
    ) throws -> BpyRuntimeJobResult {
        var response = initialResponse
        if diagnosticDeferExecutionAuthorization,
           response.activeProcessAuthorizationID != nil {
            while true { Thread.sleep(forTimeInterval: 0.05) }
        }
        response = try authorizeProcessIfNeeded(response, jobID: jobID)
        let joinedExistingJob = response.joinedExistingJob
        let deadline = Date().addingTimeInterval(
            TimeInterval(timeoutSeconds + 15)
        )
        while response.state == .accepted || response.state == .running {
            guard Date() < deadline else { throw BpyRuntimeError.timedOut }
            Thread.sleep(forTimeInterval: 0.05)
            response = try status(jobID: jobID)
            guard response.ok, response.jobID == jobID,
                  response.jobFingerprint == fingerprint else {
                throw BpyRuntimeError.rejected(response.message ?? "The 3D job disappeared.")
            }
            if diagnosticDeferExecutionAuthorization,
               response.activeProcessAuthorizationID != nil {
                while true { Thread.sleep(forTimeInterval: 0.05) }
            }
            response = try authorizeProcessIfNeeded(response, jobID: jobID)
        }
        response.joinedExistingJob = joinedExistingJob
        if response.state == .awaitingConfirmation {
            lock.lock()
            candidateJobIDs.insert(jobID)
            lock.unlock()
        }
        if response.runtime != nil {
            lock.lock()
            lastReadyResponse = response
            lock.unlock()
        }
        var outputs: [String: URL] = [:]
        if response.state == .awaitingConfirmation || response.state == .confirmed {
            guard !response.resultExpired else {
                throw BpyRuntimeError.rejected("The retained 3D result expired before download.")
            }
            outputs = try downloadOutputs(response.outputs, jobID: jobID)
            if response.state == .awaitingConfirmation,
               let scene = response.outputs.first(where: { $0.name == "scene.blend" }),
               let url = outputs["scene.blend"] {
                lock.lock()
                validatedCandidates[jobID] = (scene.sha256, url)
                lock.unlock()
            }
        }
        return .init(response: response, stagedOutputs: outputs)
    }

    func status(jobID: UUID) throws -> BpyServiceResponse {
        let request = BpyJobReference(sessionID: currentSessionID(), jobID: jobID)
        let response = try call { service, reply in
            service.jobStatus(try Self.encode(request), withReply: reply)
        }
        if response.ok {
            lock.lock()
            let fingerprint = jobFingerprints[jobID]
            lock.unlock()
            guard response.jobID == jobID,
                  response.jobFingerprint == fingerprint else {
                throw BpyRuntimeError.invalidOutput("The 3D status returned the wrong job identity.")
            }
        }
        return response
    }

    func confirm(jobID: UUID, revision: String) throws -> BpyServiceResponse {
        purgeExpiredHostResults()
        lock.lock()
        let candidate = validatedCandidates[jobID]
        lock.unlock()
        guard let candidate else {
            throw BpyRuntimeError.invalidOutput("Validate the staged 3D candidate before confirmation.")
        }
        let data = try Data(contentsOf: candidate.url)
        guard Self.sha256(data) == candidate.sha256,
              data.starts(with: Data("BLENDER".utf8)) else {
            throw BpyRuntimeError.invalidOutput("The staged 3D candidate changed before confirmation.")
        }
        let request = BpyConfirmJobRequest(
            sessionID: currentSessionID(),
            jobID: jobID,
            revision: revision,
            sceneSHA256: candidate.sha256
        )
        let response = try call(timeout: 180) { service, reply in
            service.confirmJob(try Self.encode(request), withReply: reply)
        }
        lock.lock()
        let fingerprint = jobFingerprints[jobID]
        lock.unlock()
        guard response.ok, response.jobID == jobID,
              response.jobFingerprint == fingerprint,
              response.state == .confirmed else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D candidate was not confirmed.")
        }
        lock.lock()
        confirmedRevision = revision
        confirmedSceneData = data
        validatedCandidates.removeValue(forKey: jobID)
        candidateJobIDs.remove(jobID)
        lastReadyResponse?.confirmedRevision = revision
        if let cached = cachedResults[jobID] {
            var confirmedResponse = cached.response
            confirmedResponse.state = .confirmed
            confirmedResponse.confirmedRevision = revision
            cachedResults[jobID] = .init(
                response: confirmedResponse,
                stagedOutputs: cached.stagedOutputs
            )
        }
        lock.unlock()
        return response
    }

    func cancel(jobID: UUID) throws -> BpyServiceResponse {
        let request = BpyJobReference(sessionID: currentSessionID(), jobID: jobID)
        let response = try call { service, reply in
            service.cancelJob(try Self.encode(request), withReply: reply)
        }
        lock.lock()
        let fingerprint = jobFingerprints[jobID]
        lock.unlock()
        guard response.ok, response.jobID == jobID,
              response.jobFingerprint == fingerprint else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D job could not be cancelled.")
        }
        lock.lock()
        validatedCandidates.removeValue(forKey: jobID)
        candidateJobIDs.remove(jobID)
        lock.unlock()
        return response
    }

    func rotateFromConfirmedState() throws -> BpyServiceResponse {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        _ = try ensureOpen()
        lock.lock()
        guard confirmedRevision != nil, confirmedSceneData != nil else {
            lock.unlock()
            throw BpyRuntimeError.rejected(
                "Confirm a 3D scene before rotating the document session."
            )
        }
        guard candidateJobIDs.isEmpty else {
            lock.unlock()
            throw BpyRuntimeError.rejected(
                "Confirm or reject the current 3D candidate before rotating the session."
            )
        }
        let staged = Array(cachedResults.keys)
        lock.unlock()
        rotateTransport()
        let response = try ensureOpen()
        lock.lock()
        jobFingerprints.removeAll()
        submittedJobIDs.removeAll()
        submittedTransportIDs.removeAll()
        cachedResults.removeAll()
        cachedResultOrder.removeAll()
        cachedResultDates.removeAll()
        activeProcessLease = nil
        lock.unlock()
        removeStagedResults(staged)
        return response
    }

    func close() {
        lock.lock()
        guard !closed, !closing else {
            lock.unlock()
            return
        }
        closing = true
        let identifier = sessionID
        let activeConnection = connection
        lock.unlock()
        if activeConnection != nil {
            let request = BpySessionReference(sessionID: identifier)
            _ = try? call(timeout: 10) { service, reply in
                service.closeSession(try Self.encode(request), withReply: reply)
            }
        }
        lock.lock()
        closed = true
        closing = false
        connection = nil
        lock.unlock()
        activeConnection?.invalidate()
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    private func ensureOpen() throws -> BpyServiceResponse {
        openLock.lock()
        defer { openLock.unlock() }
        lock.lock()
        if closed {
            lock.unlock()
            throw BpyRuntimeError.unavailable("The 3D document session is closed.")
        }
        if transportRecoveryBlocked {
            lock.unlock()
            throw BpyRuntimeError.unavailable(
                "The previous 3D worker could not be observed exiting; recovery is blocked."
            )
        }
        if opened, !transportInvalidated {
            let response = lastReadyResponse
            lock.unlock()
            return response ?? .init(ok: true, confirmedRevision: confirmedRevision)
        }
        let shouldRotate = transportInvalidated
        lock.unlock()
        if shouldRotate { rotateTransport() }
        do {
            return try openCurrentTransport()
        } catch {
            markTransportInvalid(currentSessionID())
            rotateTransport()
            do {
                return try openCurrentTransport()
            } catch {
                close()
                throw error
            }
        }
    }

    private func openCurrentTransport() throws -> BpyServiceResponse {
        lock.lock()
        let identifier = sessionID
        let revision = confirmedRevision
        let checkpoint = confirmedSceneData
        lock.unlock()
        let request = BpyOpenSessionRequest(
            sessionID: identifier,
            documentID: documentID,
            confirmedRevision: revision,
            limits: limits,
            diagnosticOpenFailure: diagnosticOpenFailure
        )
        let response = try call(timeout: 180) { service, reply in
            service.openSession(try Self.encode(request), withReply: reply)
        }
        guard response.ok, let runtime = response.runtime,
              runtime.pythonVersion == "3.13.15", runtime.bpyVersion == "5.2.2" else {
            throw BpyRuntimeError.unavailable(
                response.message ?? "The bundled 3D runtime has the wrong identity."
            )
        }
        if let revision, let checkpoint {
            try restoreCheckpoint(checkpoint, revision: revision, sessionID: identifier)
        } else if revision != nil || checkpoint != nil {
            throw BpyRuntimeError.unavailable("The confirmed 3D checkpoint is incomplete.")
        }
        lock.lock()
        guard sessionID == identifier, !closed else {
            lock.unlock()
            throw BpyRuntimeError.unavailable("The 3D transport changed while it opened.")
        }
        opened = true
        transportInvalidated = false
        lastReadyResponse = response
        lock.unlock()
        return response
    }

    private func restoreCheckpoint(_ data: Data, revision: String, sessionID: UUID) throws {
        let digest = Self.sha256(data)
        var offset: UInt64 = 0
        while offset < UInt64(data.count) || data.isEmpty {
            let end = min(data.count, Int(offset) + 4 * 1_024 * 1_024)
            let chunk = data.subdata(in: Int(offset)..<end)
            let final = end == data.count
            let request = BpyRestoreCheckpointRequest(
                sessionID: sessionID,
                revision: revision,
                offset: offset,
                totalBytes: UInt64(data.count),
                sha256: digest,
                finalChunk: final
            )
            let response = try call { service, reply in
                service.restoreCheckpoint(try Self.encode(request), chunk: chunk, withReply: reply)
            }
            guard response.ok else {
                throw BpyRuntimeError.unavailable(
                    response.message ?? "The confirmed 3D checkpoint could not be restored."
                )
            }
            if final { break }
            offset = UInt64(end)
        }
    }

    private func prepare(_ input: BpyApprovedInputCopy) throws -> PreparedBpyInput {
        let directoryFD = Darwin.open(
            input.approvedDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            throw BpyRuntimeError.invalidInput("Approved input directory is unavailable.")
        }
        defer { Darwin.close(directoryFD) }
        var resolvedDirectory = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let directoryPathResult = resolvedDirectory.withUnsafeMutableBufferPointer {
            fcntl(directoryFD, F_GETPATH, $0.baseAddress)
        }
        guard directoryPathResult == 0,
              String(cString: resolvedDirectory) == input.approvedDirectory.path else {
            throw BpyRuntimeError.invalidInput("Approved input directory crosses a symbolic link.")
        }
        var directoryStat = stat()
        guard fstat(directoryFD, &directoryStat) == 0,
              (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw BpyRuntimeError.invalidInput("Approved input root is not a directory.")
        }
        let fileFD = Darwin.openat(
            directoryFD,
            input.filename,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileFD >= 0 else {
            throw BpyRuntimeError.invalidInput("Approved input is unavailable.")
        }
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        var resolvedFile = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let expectedFile = input.approvedDirectory.appendingPathComponent(input.filename).path
        let filePathResult = resolvedFile.withUnsafeMutableBufferPointer {
            fcntl(fileFD, F_GETPATH, $0.baseAddress)
        }
        guard filePathResult == 0,
              String(cString: resolvedFile) == expectedFile else {
            throw BpyRuntimeError.invalidInput("Approved input crosses a symbolic link.")
        }
        var before = stat()
        guard fstat(fileFD, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              UInt64(before.st_size) <= limits.inputBytes else {
            throw BpyRuntimeError.invalidInput("Approved input must be a bounded single-link file.")
        }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        try handle.seek(toOffset: 0)
        return PreparedBpyInput(
            input: input,
            handle: handle,
            before: before,
            totalBytes: UInt64(before.st_size),
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func upload(_ prepared: PreparedBpyInput, jobID: UUID) throws {
        let total = prepared.totalBytes
        var offset: UInt64 = 0
        if total == 0 {
            try stageChunk(
                jobID: jobID,
                name: prepared.input.filename,
                offset: 0,
                total: 0,
                sha256: prepared.sha256,
                final: true,
                data: Data()
            )
        } else {
            while let data = try prepared.handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
                let final = offset + UInt64(data.count) == total
                try stageChunk(
                    jobID: jobID,
                    name: prepared.input.filename,
                    offset: offset,
                    total: total,
                    sha256: prepared.sha256,
                    final: final,
                    data: data
                )
                offset += UInt64(data.count)
            }
        }
        var after = stat()
        guard offset == total,
              fstat(prepared.handle.fileDescriptor, &after) == 0,
              (after.st_mode & S_IFMT) == S_IFREG,
              after.st_nlink == 1,
              prepared.before.st_dev == after.st_dev,
              prepared.before.st_ino == after.st_ino,
              prepared.before.st_size == after.st_size,
              prepared.before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              prepared.before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              prepared.before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              prepared.before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw BpyRuntimeError.invalidInput("Approved input changed while it was copied.")
        }
    }

    private func stageChunk(
        jobID: UUID,
        name: String,
        offset: UInt64,
        total: UInt64,
        sha256: String,
        final: Bool,
        data: Data
    ) throws {
        let request = BpyStageInputRequest(
            sessionID: currentSessionID(),
            jobID: jobID,
            name: name,
            offset: offset,
            totalBytes: total,
            sha256: sha256,
            finalChunk: final
        )
        let response = try call { service, reply in
            service.stageInput(try Self.encode(request), chunk: data, withReply: reply)
        }
        guard response.ok else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D input was rejected.")
        }
    }

    private func downloadOutputs(
        _ descriptors: [BpyOutputDescriptor],
        jobID: UUID
    ) throws -> [String: URL] {
        lock.lock()
        let expectedFingerprint = jobFingerprints[jobID]
        lock.unlock()
        guard let expectedFingerprint else {
            throw BpyRuntimeError.invalidOutput("The 3D output has no retained job identity.")
        }
        let root = stagingRoot.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var result: [String: URL] = [:]
        for descriptor in descriptors {
            guard descriptor.name.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
                options: .regularExpression
            ) != nil else {
                throw BpyRuntimeError.invalidOutput("The worker returned an invalid output name.")
            }
            let partial = root.appendingPathComponent(descriptor.name + ".part")
            let destination = root.appendingPathComponent(descriptor.name)
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            guard FileManager.default.createFile(
                atPath: partial.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw BpyRuntimeError.invalidOutput("The host output staging file could not be created.")
            }
            let handle = try FileHandle(forWritingTo: partial)
            var digest = SHA256()
            var offset: UInt64 = 0
            do {
                while offset < descriptor.byteCount {
                    let count = min(4 * 1_024 * 1_024, Int(descriptor.byteCount - offset))
                    let request = BpyReadOutputRequest(
                        sessionID: currentSessionID(),
                        jobID: jobID,
                        name: descriptor.name,
                        offset: offset,
                        maximumBytes: count
                    )
                    let chunk = try callChunk(
                        jobID: jobID,
                        fingerprint: expectedFingerprint
                    ) { service, reply in
                        service.readOutput(try Self.encode(request), withReply: reply)
                    }
                    guard !chunk.isEmpty, chunk.count <= count else {
                        throw BpyRuntimeError.invalidOutput("The worker returned a truncated output.")
                    }
                    try handle.write(contentsOf: chunk)
                    digest.update(data: chunk)
                    offset += UInt64(chunk.count)
                }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
            let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard offset == descriptor.byteCount, checksum == descriptor.sha256 else {
                try? FileManager.default.removeItem(at: partial)
                throw BpyRuntimeError.invalidOutput("The worker output checksum does not match.")
            }
            try validateMagic(partial, mediaType: descriptor.mediaType)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            result[descriptor.name] = destination
        }
        return result
    }

    private func validateMagic(_ url: URL, mediaType: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 24) ?? Data()
        let valid: Bool
        switch mediaType {
        case "application/x-blender":
            valid = prefix.starts(with: Data("BLENDER".utf8))
        case "image/png":
            valid = prefix.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        case "application/json":
            valid = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) != nil
        default:
            valid = false
        }
        guard valid else {
            throw BpyRuntimeError.invalidOutput("The worker output type is invalid.")
        }
    }

    private func cache(_ result: BpyRuntimeJobResult, for id: UUID) {
        var evicted: [UUID] = []
        lock.lock()
        cachedResults[id] = result
        cachedResultDates[id] = Date()
        cachedResultOrder.removeAll(where: { $0 == id })
        cachedResultOrder.append(id)
        while cachedResultOrder.count > 16 {
            let removed = cachedResultOrder.removeFirst()
            cachedResults.removeValue(forKey: removed)
            cachedResultDates.removeValue(forKey: removed)
            validatedCandidates.removeValue(forKey: removed)
            evicted.append(removed)
        }
        lock.unlock()
        removeStagedResults(evicted)
    }

    private func purgeExpiredHostResults() {
        let cutoff = Date().addingTimeInterval(-bpyHostResultRetentionSeconds)
        lock.lock()
        let expired = cachedResultDates.compactMap { id, date in date < cutoff ? id : nil }
        expired.forEach {
            cachedResults.removeValue(forKey: $0)
            cachedResultDates.removeValue(forKey: $0)
            validatedCandidates.removeValue(forKey: $0)
            candidateJobIDs.remove($0)
        }
        cachedResultOrder.removeAll(where: { expired.contains($0) })
        lock.unlock()
        removeStagedResults(expired)
    }

    private func removeStagedResults(_ ids: [UUID]) {
        ids.forEach {
            try? FileManager.default.removeItem(
                at: stagingRoot.appendingPathComponent($0.uuidString, isDirectory: true)
            )
        }
    }

    private func installConnection() {
        let identifier = currentSessionID()
        let value = NSXPCConnection(serviceName: serviceName)
        value.remoteObjectInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        value.interruptionHandler = { [weak self] in self?.markTransportInvalid(identifier) }
        value.invalidationHandler = { [weak self] in self?.markTransportInvalid(identifier) }
        lock.lock()
        connection = value
        lock.unlock()
        value.resume()
    }

    private func rotateTransport() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        let previous = connection
        connection = nil
        sessionID = UUID()
        opened = false
        transportInvalidated = false
        lastReadyResponse = nil
        lock.unlock()
        previous?.invalidate()
        installConnection()
    }

    private func markTransportInvalid(_ identifier: UUID) {
        lock.lock()
        guard sessionID == identifier else {
            lock.unlock()
            return
        }
        transportInvalidated = true
        opened = false
        validatedCandidates.removeAll()
        candidateJobIDs.removeAll()
        let lease = activeProcessLease?.transportID == identifier ? activeProcessLease : nil
        if lease != nil { activeProcessLease = nil }
        let unconfirmed = cachedResults.compactMap { key, value in
            value.response.state == .awaitingConfirmation ? key : nil
        }
        unconfirmed.forEach {
            cachedResults.removeValue(forKey: $0)
            cachedResultDates.removeValue(forKey: $0)
        }
        cachedResultOrder.removeAll(where: { unconfirmed.contains($0) })
        lock.unlock()
        if let lease, !terminateLeasedProcess(lease) {
            lock.lock()
            if sessionID == identifier { transportRecoveryBlocked = true }
            lock.unlock()
        }
        removeStagedResults(unconfirmed)
    }

    private func currentSessionID() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    private func currentConnection() throws -> (NSXPCConnection, UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let connection else {
            throw BpyRuntimeError.unavailable("The 3D XPC service is unavailable.")
        }
        return (connection, sessionID)
    }

    private func call(
        timeout: TimeInterval = 30,
        _ invoke: (BpyRuntimeServiceProtocol, @escaping (Data) -> Void) throws -> Void
    ) throws -> BpyServiceResponse {
        let box = BpyReplyBox()
        let semaphore = DispatchSemaphore(value: 0)
        let (activeConnection, transportID) = try currentConnection()
        guard let service = activeConnection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.markTransportInvalid(transportID)
            if box.store(error: error) { semaphore.signal() }
        }) as? BpyRuntimeServiceProtocol else {
            markTransportInvalid(transportID)
            throw BpyRuntimeError.unavailable("The 3D XPC service is unavailable.")
        }
        try invoke(service) { data in
            if box.store(response: data) { semaphore.signal() }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            markTransportInvalid(transportID)
            throw BpyRuntimeError.timedOut
        }
        let value = box.load()
        if let error = value.2 { throw error }
        guard let data = value.0 else {
            throw BpyRuntimeError.unavailable("Empty 3D service reply.")
        }
        let response = try Self.decode(data)
        recordProcessLease(response, transportID: transportID)
        return response
    }

    private func callChunk(
        timeout: TimeInterval = 30,
        jobID: UUID,
        fingerprint: String?,
        _ invoke: (BpyRuntimeServiceProtocol, @escaping (Data, Data) -> Void) throws -> Void
    ) throws -> Data {
        let box = BpyReplyBox()
        let semaphore = DispatchSemaphore(value: 0)
        let (activeConnection, transportID) = try currentConnection()
        guard let service = activeConnection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.markTransportInvalid(transportID)
            if box.store(error: error) { semaphore.signal() }
        }) as? BpyRuntimeServiceProtocol else {
            markTransportInvalid(transportID)
            throw BpyRuntimeError.unavailable("The 3D XPC service is unavailable.")
        }
        try invoke(service) { response, chunk in
            if box.store(response: response, chunk: chunk) { semaphore.signal() }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            markTransportInvalid(transportID)
            throw BpyRuntimeError.timedOut
        }
        let value = box.load()
        if let error = value.2 { throw error }
        guard let responseData = value.0, let chunk = value.1 else {
            throw BpyRuntimeError.unavailable("Empty 3D service reply.")
        }
        let response = try Self.decode(responseData)
        recordProcessLease(response, transportID: transportID)
        guard response.ok else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D output was rejected.")
        }
        guard response.jobID == jobID, response.jobFingerprint == fingerprint else {
            throw BpyRuntimeError.invalidOutput("The 3D output returned the wrong job identity.")
        }
        return chunk
    }

    private func recordProcessLease(_ response: BpyServiceResponse, transportID: UUID) {
        let expectedExecutable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/NexGenVideoBpySupervisor")
            .resolvingSymlinksInPath().path
        lock.lock()
        defer { lock.unlock() }
        guard sessionID == transportID else { return }
        if let processIdentifier = response.activeProcessIdentifier,
           let startAbsoluteTime = response.activeProcessStartAbsoluteTime,
           let executable = response.activeProcessExecutable,
           processIdentifier > 1,
           URL(fileURLWithPath: executable).resolvingSymlinksInPath().path == expectedExecutable,
           processStartAbsoluteTime(processIdentifier) == startAbsoluteTime,
           processExecutable(processIdentifier) == expectedExecutable {
            activeProcessLease = .init(
                transportID: transportID,
                processIdentifier: processIdentifier,
                startAbsoluteTime: startAbsoluteTime,
                executable: expectedExecutable
            )
        } else if response.state?.isTerminal == true || response.state == .awaitingConfirmation {
            activeProcessLease = nil
        }
    }

    private func authorizeProcessIfNeeded(
        _ response: BpyServiceResponse,
        jobID: UUID
    ) throws -> BpyServiceResponse {
        guard let authorizationID = response.activeProcessAuthorizationID else { return response }
        guard response.jobID == jobID,
              let processIdentifier = response.activeProcessIdentifier,
              let startAbsoluteTime = response.activeProcessStartAbsoluteTime,
              let executable = response.activeProcessExecutable else {
            throw BpyRuntimeError.invalidOutput("The 3D service returned an incomplete process authorization.")
        }
        let transportID = currentSessionID()
        lock.lock()
        let lease = activeProcessLease
        lock.unlock()
        guard lease?.transportID == transportID,
              lease?.processIdentifier == processIdentifier,
              lease?.startAbsoluteTime == startAbsoluteTime,
              lease?.executable == executable,
              processStartAbsoluteTime(processIdentifier) == startAbsoluteTime,
              processExecutable(processIdentifier) == executable else {
            throw BpyRuntimeError.invalidOutput("The 3D process could not be bound to the host lease.")
        }
        let request = BpyAuthorizeProcessRequest(
            sessionID: transportID,
            jobID: jobID,
            authorizationID: authorizationID,
            processIdentifier: processIdentifier,
            processStartAbsoluteTime: startAbsoluteTime,
            processExecutable: executable
        )
        let authorized = try call { service, reply in
            service.authorizeProcess(try Self.encode(request), withReply: reply)
        }
        guard authorized.ok,
              authorized.jobID == jobID,
              authorized.activeProcessAuthorizationID == nil else {
            throw BpyRuntimeError.rejected(
                authorized.message ?? "The 3D process authorization was rejected."
            )
        }
        return authorized
    }

    private static func fingerprint(
        expectedRevision: String?,
        source: String,
        requestedTimeoutSeconds: Int?,
        effectiveTimeoutSeconds: Int,
        inputs: [PreparedBpyInput],
        diagnosticDeniedPaths: [String],
        diagnosticAutoexecPositiveControl: Bool,
        diagnosticSupervisorIdentityWriteFailure: Bool,
        diagnosticSupervisorIdentityCaptureFailure: Bool
    ) -> String {
        var digest = SHA256()
        func add(_ value: String?) {
            let data = Data((value ?? "<nil>").utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: data)
        }
        add("nexgenvideo/bpy-job/4")
        add(expectedRevision)
        add(requestedTimeoutSeconds.map(String.init))
        add(String(effectiveTimeoutSeconds))
        add(source)
        inputs.forEach {
            add($0.input.filename)
            add(String($0.totalBytes))
            add($0.sha256)
        }
        diagnosticDeniedPaths.forEach { add($0) }
        add(diagnosticAutoexecPositiveControl ? "1" : "0")
        add(diagnosticSupervisorIdentityWriteFailure ? "1" : "0")
        add(diagnosticSupervisorIdentityCaptureFailure ? "1" : "0")
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func decode(_ data: Data) throws -> BpyServiceResponse {
        try JSONDecoder().decode(BpyServiceResponse.self, from: data)
    }
}

@MainActor
final class BpyRuntimeHost {
    static let shared = BpyRuntimeHost()

    private struct Entry {
        weak var document: VideoProject?
        let documentID: String
        var session: BpyRuntimeSession?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    private init() {}

    func register(document: VideoProject, documentID: String) {
        let key = ObjectIdentifier(document)
        guard entries[key] == nil else { return }
        entries[key] = Entry(document: document, documentID: documentID, session: nil)
        entries = entries.filter { $0.value.document != nil }
    }

    func session(
        for document: VideoProject,
        diagnosticOpenFailure: Bool = false
    ) -> BpyRuntimeSession? {
        let key = ObjectIdentifier(document)
        guard var entry = entries[key] else { return nil }
        if let session = entry.session, session.occupiesHostSlot { return session }
        entry.session = nil
        let used = Set(entries.values.compactMap { entry -> String? in
            guard let session = entry.session, session.occupiesHostSlot else { return nil }
            return session.serviceName
        })
        guard let serviceName = bpyRuntimeServiceNames.first(where: { !used.contains($0) }) else {
            return nil
        }
        let session = BpyRuntimeSession(
            documentID: entry.documentID,
            serviceName: serviceName,
            diagnosticOpenFailure: diagnosticOpenFailure
        )
        entry.session = session
        entries[key] = entry
        return session
    }

    func unregister(document: VideoProject) {
        entries.removeValue(forKey: ObjectIdentifier(document))?.session?.close()
    }

    func shutdown() {
        let sessions = entries.values.compactMap(\.session)
        entries.removeAll()
        sessions.forEach { $0.close() }
    }
}
