import AppKit
import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

private let bpyHostResultRetentionSeconds: TimeInterval = 15 * 60
private let bpyOpenDiagnostics = CategoryLog("bpy-open")

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
    var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
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
    private var storageVolume: BpyRuntimeVolume?
    private var spatialDerivations: [UUID: String] = [:]
    private let closeLock = NSLock()
    private var cleanupComplete = false
    private var cleanupMessage: String?
    private var storagePreparation: BpyStoragePreparation?
    private var claimedStoragePreparation: BpyStoragePreparation?
    private var jobInputDigests: [UUID: [String: String]] = [:]
    private let spatialSequences = SpatialClaySequenceReceipts()
    private var cleanupRequiresRestart = false
    private var storageServiceReleased = false

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
        return !cleanupComplete
    }

    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && !closing
    }

    var cleanupFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return cleanupMessage
    }

    var canQuitWithReservedStorage: Bool {
        lock.withLock {
            Self.permitsReservedStorageQuit(closed: closed, closing: closing, cleanupComplete: cleanupComplete,
                                            requiresRestart: cleanupRequiresRestart, serviceReleased: storageServiceReleased)
        }
    }

    static func permitsReservedStorageQuit(closed: Bool, closing: Bool, cleanupComplete: Bool,
                                          requiresRestart: Bool, serviceReleased: Bool) -> Bool {
        closed && !closing && !cleanupComplete && requiresRestart && serviceReleased
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
        try Self.requireDiagnosticPaths(diagnosticDeniedPaths)
        for path in diagnosticDeniedPaths {
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw BpyRuntimeError.invalidInput("A diagnostic positive-control file is unreadable.") }
            defer { Darwin.close(descriptor) }
            var status = stat(), byte: UInt8 = 0
            guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
                  Darwin.read(descriptor, &byte, 1) == 1 else {
                throw BpyRuntimeError.invalidInput("A diagnostic positive control requires an actual readable regular file.")
            }
        }
        _ = try ensureOpen()
        purgeExpiredHostResults()
        guard Set(inputs.map(\.filename)).count == inputs.count else {
            throw BpyRuntimeError.invalidInput("Input filenames must be unique.")
        }
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
            jobInputDigests[id] = Dictionary(uniqueKeysWithValues: prepared.map { ($0.input.filename, $0.sha256) })
            lock.unlock()
        }
        lock.lock()
        let needsUpload = !submittedJobIDs.contains(id)
        lock.unlock()
        if needsUpload {
            do {
                for value in prepared {
                    try upload(value, jobID: id)
                }
            } catch {
                let cancellation = BpyJobReference(sessionID: transportID, jobID: id)
                _ = try? call { service, reply in
                    service.cancelJob(try Self.encode(cancellation), withReply: reply)
                }
                throw error
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

    func authenticateSpatialReceipt(_ revision: SpatialSceneRevision) throws {
        let receipt = revision.manifest.receipt
        guard try SpatialSceneStore.encode(revision.manifest) == revision.manifestData,
              try SpatialSceneStore.encode(revision.snapshot) == revision.snapshotData,
              Self.sha256(revision.sceneData) == revision.manifest.sceneSHA256,
              Self.sha256(revision.snapshotData) == revision.manifest.snapshotSHA256,
              receipt.sceneSHA256 == revision.manifest.sceneSHA256,
              receipt.snapshotSHA256 == revision.manifest.snapshotSHA256,
              Self.sha256(try SpatialSceneStore.encode(revision.manifest.resources)) == revision.manifest.resourceClosureSHA256,
              Set(revision.resources.keys) == Set(revision.manifest.resources.map(\.id)),
              revision.resources.count == revision.manifest.resources.count,
              revision.manifest.resources.allSatisfy({ item in
                  guard let data = revision.resources[item.id] else { return false }
                  return data.count == item.byteCount && Self.sha256(data) == item.sha256
              }) else {
            throw BpyRuntimeError.invalidOutput("The location revision differs from its verified bytes.")
        }
        try SpatialSceneStore.validate(revision.snapshot)
        struct Verification: Decodable {
            let schema: String
            let jobID: UUID
            let fingerprint: String
            let blenderBuildHash: String
            let spatial: BpySpatialSnapshot?
        }
        lock.lock()
        let inputDigests = jobInputDigests[receipt.jobID]
        let result = cachedResults[receipt.jobID]
        let fingerprint = jobFingerprints[receipt.jobID]
        let transport = submittedTransportIDs[receipt.jobID]
        let currentTransport = sessionID
        let unavailable = closed || closing || transportInvalidated
        lock.unlock()
        let expectedInputs = Dictionary(uniqueKeysWithValues: revision.manifest.resources.map {
            ("resource-" + $0.id.uuidString + ".glb", $0.sha256)
        })
        guard !unavailable, transport == currentTransport, fingerprint == receipt.jobFingerprint,
              inputDigests == expectedInputs,
              receipt.resourceClosureSHA256 == revision.manifest.resourceClosureSHA256,
              let result, result.response.ok, result.response.state == .awaitingConfirmation,
              result.response.jobID == receipt.jobID,
              result.response.jobFingerprint == receipt.jobFingerprint else {
            throw BpyRuntimeError.invalidOutput("The location has no authenticated host runtime result.")
        }
        func output(_ name: String) throws -> Data {
            guard let url = result.stagedOutputs[name],
                  let descriptor = result.response.outputs.first(where: { $0.name == name }) else {
                throw BpyRuntimeError.invalidOutput("The location's verified runtime output is missing.")
            }
            let data = try SpatialSceneStore.read(url.lastPathComponent, in: url.deletingLastPathComponent())
            guard descriptor.byteCount == data.count, descriptor.sha256 == Self.sha256(data) else {
                throw BpyRuntimeError.invalidOutput("The location's verified runtime output changed.")
            }
            return data
        }
        let verification = try JSONDecoder().decode(Verification.self, from: output("verification.json"))
        let runtime = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BpyRuntime")
        guard verification.schema == "nexgenvideo/bpy-verification/1",
              verification.jobID == receipt.jobID, verification.fingerprint == receipt.jobFingerprint,
              verification.blenderBuildHash == receipt.blenderBuildHash, let snapshot = verification.spatial,
              Self.sha256(try output("scene.blend")) == receipt.sceneSHA256,
              Self.sha256(try SpatialSceneStore.encode(snapshot)) == receipt.snapshotSHA256,
              Self.sha256(try Data(contentsOf: runtime.appendingPathComponent("runtime-lock.json"))) == receipt.runtimeLockSHA256,
              Self.sha256(try Data(contentsOf: runtime.appendingPathComponent("worker.py"))) == receipt.workerSHA256 else {
            throw BpyRuntimeError.invalidOutput("The location receipt differs from its actual host runtime execution.")
        }
    }

    static func evaluatedGeometryFingerprint(revision: UUID?, source: String, timeoutSeconds: Int) -> String {
        fingerprint(expectedRevision: revision?.uuidString, source: source, requestedTimeoutSeconds: nil,
            effectiveTimeoutSeconds: timeoutSeconds, inputs: [], diagnosticDeniedPaths: [],
            diagnosticAutoexecPositiveControl: false, diagnosticSupervisorIdentityWriteFailure: false,
            diagnosticSupervisorIdentityCaptureFailure: false)
    }

    func authenticateEvaluatedGeometry(jobID: UUID, source: String, revision: SpatialSceneRevision,
                                       result: BpyRuntimeJobResult) throws -> (bounds: Data, verification: Data, fingerprint: String) {
        struct Verification: Decodable { let jobID: UUID; let fingerprint: String; let blenderBuildHash: String }
        let expected = Self.fingerprint(expectedRevision: revision.manifest.revision.uuidString, source: source,
            requestedTimeoutSeconds: nil, effectiveTimeoutSeconds: limits.timeoutSeconds, inputs: [], diagnosticDeniedPaths: [],
            diagnosticAutoexecPositiveControl: false, diagnosticSupervisorIdentityWriteFailure: false,
            diagnosticSupervisorIdentityCaptureFailure: false)
        lock.lock()
        let cached = cachedResults[jobID]
        let current = !closed && !closing && !transportInvalidated && submittedTransportIDs[jobID] == sessionID
            && jobFingerprints[jobID] == expected
        lock.unlock()
        guard current, let cached, cached.response.ok, cached.response.state == .awaitingConfirmation,
              cached.response.jobFingerprint == expected, result.response.jobFingerprint == expected,
              cached.stagedOutputs == result.stagedOutputs else { throw BpyRuntimeError.invalidOutput("The evaluated bounds have no current native runtime execution.") }
        func output(_ name: String) throws -> Data {
            guard let url = cached.stagedOutputs[name], let descriptor = cached.response.outputs.first(where: { $0.name == name }) else { throw SpatialSceneError.changed }
            let data = try SpatialSceneStore.read(url.lastPathComponent, in: url.deletingLastPathComponent())
            guard data.count == descriptor.byteCount, Self.sha256(data) == descriptor.sha256 else { throw SpatialSceneError.changed }
            return data
        }
        let verification = try output("verification.json")
        let value = try JSONDecoder().decode(Verification.self, from: verification)
        guard value.jobID == jobID, value.fingerprint == expected, !value.blenderBuildHash.isEmpty else { throw SpatialSceneError.changed }
        return (try output("evaluated-bounds.v1.json"), verification, expected)
    }

    func retainSpatialDerivation(_ candidate: SpatialClayCandidate, source: SpatialSceneRevision) throws {
        try verifySpatialDerivation(candidate, source: source)
        lock.lock()
        defer { lock.unlock() }
        spatialDerivations = spatialDerivations.filter { cachedResults[$0.key] != nil }
        spatialDerivations[candidate.proof.jobID] = Self.sha256(candidate.proofData)
    }

    func authenticateSpatialDerivation(_ candidate: SpatialClayCandidate, source: SpatialSceneRevision) throws {
        lock.lock()
        let issued = spatialDerivations[candidate.proof.jobID]
        lock.unlock()
        guard issued == Self.sha256(candidate.proofData) else {
            throw BpyRuntimeError.invalidOutput("The Clay output has no host-issued derivation receipt.")
        }
        try verifySpatialDerivation(candidate, source: source)
    }

    func beginSpatialSequence(binding: Data) throws -> UUID {
        try requireSequenceSession()
        return try spatialSequences.begin(binding: binding)
    }

    func appendSpatialSequence(_ identifier: UUID, candidate: SpatialClayCandidate,
                               source: SpatialSceneRevision) throws {
        try authenticateSpatialDerivation(candidate, source: source)
        try spatialSequences.append(identifier, proof: candidate.proofData)
    }

    func retainSpatialSequence(_ candidate: SpatialClaySequenceCandidate,
                               source: SpatialSceneRevision) async throws {
        try requireSequenceSession()
        try SpatialClayRenderer.validateSequence(proofData: candidate.proofData, files: candidate.files, against: source)
        try await SpatialClayRenderer.verifySequenceMovie(candidate, isCancelled: { !candidate.isAvailable })
        try SpatialClayRenderer.validateSequence(proofData: candidate.proofData, files: candidate.files, against: source)
        try requireSequenceSession()
        try spatialSequences.seal(candidate)
    }

    func authenticateSpatialSequence(_ candidate: SpatialClaySequenceCandidate, source: SpatialSceneRevision) throws {
        try requireSequenceSession()
        try spatialSequences.authenticate(candidate)
        try SpatialClayRenderer.validateSequence(proofData: candidate.proofData, files: candidate.files, against: source)
        try requireSequenceSession()
        try spatialSequences.authenticate(candidate)
    }

    func releaseSpatialSequence(_ identifier: UUID) { spatialSequences.release(identifier) }

    private func requireSequenceSession() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !closing, !transportInvalidated else {
            throw BpyRuntimeError.unavailable("The 3D sequence session is closed.")
        }
    }

    private func verifySpatialDerivation(_ candidate: SpatialClayCandidate, source: SpatialSceneRevision) throws {
        struct Verification: Decodable {
            let jobID: UUID
            let fingerprint: String
            let blenderBuildHash: String
            let spatial: BpySpatialSnapshot?
        }
        try SpatialClayRenderer.validate(candidate, against: source)
        let proof = candidate.proof
        lock.lock()
        let result = cachedResults[proof.jobID]
        let transportMatches = submittedTransportIDs[proof.jobID] == sessionID
        let fingerprint = jobFingerprints[proof.jobID]
        let unavailable = closed || closing || transportInvalidated
        lock.unlock()
        guard !unavailable, transportMatches, fingerprint == proof.jobFingerprint,
              let result, result.response.ok, result.response.jobFingerprint == fingerprint,
              result.response.state == .awaitingConfirmation else {
            throw BpyRuntimeError.invalidOutput("The Clay output has no authenticated runtime execution.")
        }
        let root = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/BpyRuntime")
        let script = try Data(contentsOf: root.appendingPathComponent("scene_operations.py"))
        let settings = try SpatialClayRenderer.renderSettings(proof.request, state: proof.state)
        let literal = try JSONEncoder().encode(String(decoding: settings, as: UTF8.self))
        let sourceCode = "import json\nngv_command = json.loads(\(String(decoding: literal, as: UTF8.self)))\n"
            + String(decoding: script, as: UTF8.self)
        let expectedFingerprint = Self.fingerprint(
            expectedRevision: source.manifest.revision.uuidString, source: sourceCode,
            requestedTimeoutSeconds: nil, effectiveTimeoutSeconds: limits.timeoutSeconds,
            inputs: [], diagnosticDeniedPaths: [], diagnosticAutoexecPositiveControl: false,
            diagnosticSupervisorIdentityWriteFailure: false, diagnosticSupervisorIdentityCaptureFailure: false
        )
        guard expectedFingerprint == proof.jobFingerprint,
              Self.sha256(settings) == proof.settingsSHA256,
              Self.sha256(script) == proof.rendererScriptSHA256,
              Self.sha256(try Data(contentsOf: root.appendingPathComponent("worker.py"))) == proof.workerSHA256,
              Self.sha256(try Data(contentsOf: root.appendingPathComponent("runtime-lock.json"))) == proof.runtimeLockSHA256,
              Self.sha256(try Data(contentsOf: root.appendingPathComponent("site-packages/bpy/__init__.so"), options: .mappedIfSafe)) == proof.rendererBinarySHA256 else {
            throw BpyRuntimeError.invalidOutput("The Clay receipt differs from its actual render command or runtime.")
        }
        func output(_ name: String) throws -> Data {
            guard let url = result.stagedOutputs[name],
                  let descriptor = result.response.outputs.first(where: { $0.name == name }) else {
                throw BpyRuntimeError.invalidOutput("The actual Clay runtime output is missing.")
            }
            let data = try SpatialSceneStore.read(url.lastPathComponent, in: url.deletingLastPathComponent())
            guard data.count == descriptor.byteCount, Self.sha256(data) == descriptor.sha256 else {
                throw BpyRuntimeError.invalidOutput("The actual Clay runtime output changed.")
            }
            return data
        }
        let verification = try JSONDecoder().decode(Verification.self, from: output("verification.json"))
        guard verification.jobID == proof.jobID, verification.fingerprint == proof.jobFingerprint,
              verification.blenderBuildHash == proof.blenderBuildHash, let snapshot = verification.spatial,
              Self.sha256(try SpatialSceneStore.encode(snapshot)) == proof.verifiedRenderSnapshotSHA256,
              try JSONDecoder().decode([SpatialClayFramePose].self, from: output("clay-frames.json")) == proof.framePoses else {
            throw BpyRuntimeError.invalidOutput("The Clay receipt differs from independent runtime verification.")
        }
        for descriptor in proof.outputs where descriptor.mediaKind == "image/png" {
            guard try output(descriptor.filename) == candidate.files[descriptor.filename] else {
                throw BpyRuntimeError.invalidOutput("The Clay image differs from its actual render output.")
            }
        }
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
        jobInputDigests.removeAll()
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

    func loadProjectCheckpoint(scene: Data?, revision: String?, sha256: String?) throws {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        if let scene, let revision, let sha256 {
            guard !revision.isEmpty, Self.sha256(scene) == sha256,
                  scene.count <= limits.inputBytes else {
                throw BpyRuntimeError.invalidInput("The saved location checkpoint changed.")
            }
        } else if scene != nil || revision != nil || sha256 != nil {
            throw BpyRuntimeError.invalidInput("The saved location checkpoint is incomplete.")
        }
        lock.lock()
        guard !closed, !closing, candidateJobIDs.isEmpty else {
            lock.unlock()
            throw BpyRuntimeError.rejected("Finish the current location edit before opening another location.")
        }
        let staged = Array(cachedResults.keys)
        confirmedSceneData = scene
        confirmedRevision = revision
        jobFingerprints.removeAll()
        jobInputDigests.removeAll()
        submittedJobIDs.removeAll()
        submittedTransportIDs.removeAll()
        cachedResults.removeAll()
        cachedResultOrder.removeAll()
        cachedResultDates.removeAll()
        lock.unlock()
        rotateTransport()
        _ = try ensureOpen()
        removeStagedResults(staged)
    }

    fileprivate func beginClose() {
        lock.lock()
        if !cleanupComplete { closing = true }
        lock.unlock()
        spatialSequences.close()
    }

    @discardableResult
    func close() -> Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        lock.lock()
        guard !cleanupComplete else {
            lock.unlock()
            return true
        }
        closing = true
        lock.unlock()
        spatialSequences.close()
        openLock.lock()
        lock.lock()
        let identifier = sessionID
        let activeConnection = connection
        lock.unlock()
        if activeConnection != nil {
            let request = BpySessionReference(sessionID: identifier)
            _ = try? call(timeout: 10, allowClosing: true) { service, reply in
                service.closeSession(try Self.encode(request), withReply: reply)
            }
        }
        activeConnection?.invalidate()
        lock.lock()
        let volume = storageVolume
        let preparation = claimedStoragePreparation
        closed = true
        connection = nil
        lock.unlock()
        openLock.unlock()
        var failure: String?
        var serviceReleased = false
        var restartRequired = false
        do {
            let serviceProof = try? queryStorageOwnership()
            let workerStopped = lock.withLock {
                if let lease = activeProcessLease {
                    return processStartAbsoluteTime(lease.processIdentifier) != lease.startAbsoluteTime
                }
                return submittedJobIDs.isEmpty
            }
            if let volume {
                serviceReleased = volume.serviceReleasedForRecovery(serviceProof, workerStopped: workerStopped)
                try volume.release(serviceStopped: false, serviceProof: serviceProof)
            } else if let preparation {
                serviceReleased = serviceProof?.inUseStorageIDs.contains(preparation.id) == false
                    && ((serviceProof?.servicePID == preparation.servicePID && serviceProof?.serviceStart == preparation.serviceStart)
                        || (workerStopped && processStartAbsoluteTime(preparation.servicePID) != preparation.serviceStart))
                try BpyRuntimeVolume.releasePrepared(preparation, serviceName: serviceName,
                                                     serviceStopped: false, serviceProof: serviceProof)
            }
            do {
                try FileManager.default.removeItem(at: stagingRoot)
            } catch let error as CocoaError where error.code == .fileNoSuchFile { }
        } catch {
            failure = error.localizedDescription
            restartRequired = (error as? BpyStorageRecoveryError) == .restartRequired
            NSLog("3D runtime cleanup failed; slot retained: %@", error.localizedDescription)
        }
        lock.lock()
        cleanupComplete = failure == nil
        cleanupMessage = failure
        cleanupRequiresRestart = restartRequired
        storageServiceReleased = serviceReleased
        if cleanupComplete { storageVolume = nil }
        closing = false
        lock.unlock()
        return failure == nil
    }

    private func queryStorageOwnership() throws -> BpyStoragePreparation {
        let query = NSXPCConnection(serviceName: serviceName)
        query.remoteObjectInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        query.resume()
        defer { query.invalidate() }
        let box = BpyReplyBox()
        let completed = DispatchSemaphore(value: 0)
        guard let service = query.remoteObjectProxyWithErrorHandler({ error in
            if box.store(error: error) { completed.signal() }
        }) as? BpyRuntimeServiceProtocol else { throw BpyRuntimeError.timedOut }
        let id = UUID()
        let request = BpyOpenSessionRequest(sessionID: id, documentID: documentID, confirmedRevision: nil, limits: limits)
        service.openSession(try Self.encode(request)) { data in
            if box.store(response: data) { completed.signal() }
        }
        guard completed.wait(timeout: .now() + 10) == .success,
              let data = box.load().0 else { throw BpyRuntimeError.timedOut }
        let response = try Self.decode(data)
        guard response.ok, let proof = response.storagePreparation, proof.id == id,
              proof.servicePID == query.processIdentifier,
              processStartAbsoluteTime(proof.servicePID) == proof.serviceStart else {
            throw BpyRuntimeError.invalidOutput("The 3D storage owner could not be verified.")
        }
        return proof
    }

    private func ensureOpen(restoreProbe: BpyNativeRestoreProbe? = nil) throws -> BpyServiceResponse {
        openLock.lock()
        do {
            let response = try ensureOpenLocked(restoreProbe: restoreProbe)
            openLock.unlock()
            return response
        } catch {
            openLock.unlock()
            close()
            throw error
        }
    }

    private func ensureOpenLocked(restoreProbe: BpyNativeRestoreProbe?) throws -> BpyServiceResponse {
        lock.lock()
        if closed || closing {
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
        let firstSession = currentSessionID()
        do {
            return try openCurrentTransport(restoreProbe: restoreProbe)
        } catch {
            lock.lock()
            let unfinishedStorage = storagePreparation != nil && storageVolume == nil
            lock.unlock()
            let firstError = error as NSError
            bpyOpenDiagnostics.notice("open.first.fail session=\(firstSession.uuidString) unfinishedStorage=\(unfinishedStorage) domain=\(firstError.domain) code=\(firstError.code)")
            guard !unfinishedStorage else { throw error }
            markTransportInvalid(currentSessionID())
            rotateTransport()
            let retrySession = currentSessionID()
            do {
                return try openCurrentTransport(restoreProbe: restoreProbe)
            } catch {
                let retryError = error as NSError
                bpyOpenDiagnostics.notice("open.retry.fail session=\(retrySession.uuidString) firstSession=\(firstSession.uuidString) domain=\(retryError.domain) code=\(retryError.code)")
                throw error
            }
        }
    }

    private func openCurrentTransport(restoreProbe: BpyNativeRestoreProbe?) throws -> BpyServiceResponse {
        lock.lock()
        guard !closed, !closing else {
            lock.unlock()
            throw BpyRuntimeError.unavailable("The 3D document session is closed.")
        }
        let identifier = sessionID
        let revision = confirmedRevision
        let checkpoint = confirmedSceneData
        lock.unlock()
        lock.lock()
        let existingStorage = storageVolume?.lease
        lock.unlock()
        var request = BpyOpenSessionRequest(
            sessionID: identifier, documentID: documentID, confirmedRevision: revision,
            limits: limits, diagnosticOpenFailure: diagnosticOpenFailure, storage: existingStorage
        )
        var requestBytes = try Self.encode(request)
        var response = try call(timeout: 180, observing: { bytes in
            restoreProbe?.open = .init(method: "openSession", request: requestBytes.base64EncodedString(),
                                       response: bytes.base64EncodedString())
        }) { service, reply in
            service.openSession(requestBytes, withReply: reply)
        }
        if let preparation = response.storagePreparation {
            let transport = try currentConnection()
            guard transport.1 == identifier, existingStorage == nil, preparation.id == identifier,
                  preparation.servicePID == transport.0.processIdentifier,
                  processStartAbsoluteTime(preparation.servicePID) == preparation.serviceStart else {
                throw BpyRuntimeError.invalidOutput("The 3D service changed its storage lease.")
            }
            bpyOpenDiagnostics.notice("open.preparation session=\(identifier.uuidString) servicePID=\(preparation.servicePID) serviceStart=\(preparation.serviceStart)")
            lock.lock()
            storagePreparation = preparation
            lock.unlock()
            let volume = try BpyRuntimeVolume.create(preparation: preparation, serviceName: serviceName,
                                                     maximumBytes: limits.physicalStorageBytes) { [self] in
                lock.lock()
                claimedStoragePreparation = preparation
                lock.unlock()
            }
            lock.lock()
            storageVolume = volume
            guard !closed, !closing, sessionID == identifier else {
                lock.unlock()
                throw BpyRuntimeError.unavailable("The 3D session closed while preparing storage.")
            }
            lock.unlock()
            request = BpyOpenSessionRequest(
                sessionID: identifier, documentID: documentID, confirmedRevision: revision,
                limits: limits, diagnosticOpenFailure: diagnosticOpenFailure, storage: volume.lease
            )
            requestBytes = try Self.encode(request)
            response = try call(timeout: 180, observing: { bytes in
                restoreProbe?.open = .init(method: "openSession", request: requestBytes.base64EncodedString(),
                                           response: bytes.base64EncodedString())
            }) { service, reply in
                service.openSession(requestBytes, withReply: reply)
            }
        }
        guard response.ok, let runtime = response.runtime,
              runtime.pythonVersion == "3.13.15", runtime.bpyVersion == "5.2.2" else {
            throw BpyRuntimeError.unavailable(
                response.message ?? "The bundled 3D runtime has the wrong identity."
            )
        }
        lock.lock()
        let volume = storageVolume
        lock.unlock()
        let transport = try currentConnection()
        guard transport.1 == identifier, runtime.serviceProcessIdentifier == transport.0.processIdentifier else {
            throw BpyRuntimeError.invalidOutput("The 3D service returned another process identity.")
        }
        try volume?.bindService(transport.0.processIdentifier)
        if let revision, let checkpoint {
            try restoreCheckpoint(checkpoint, revision: revision, sessionID: identifier, probe: restoreProbe)
        } else if revision != nil || checkpoint != nil {
            throw BpyRuntimeError.unavailable("The confirmed 3D checkpoint is incomplete.")
        }
        lock.lock()
        guard sessionID == identifier, !closed, !closing else {
            lock.unlock()
            throw BpyRuntimeError.unavailable("The 3D transport changed while it opened.")
        }
        opened = true
        transportInvalidated = false
        lastReadyResponse = response
        lock.unlock()
        return response
    }

    private func restoreCheckpoint(_ data: Data, revision: String, sessionID: UUID,
                                   probe: BpyNativeRestoreProbe?) throws {
        probe?.checkpoint = data
        probe?.exchanges.removeAll()
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
            let requestBytes = try Self.encode(request)
            func observe(_ method: String, _ responseBytes: Data) {
                probe?.exchanges.append(.init(method: method, request: requestBytes.base64EncodedString(),
                    response: responseBytes.base64EncodedString(), chunkSHA256: Self.sha256(chunk), chunkBytes: chunk.count))
            }
            let response = try call(observing: { observe("restoreCheckpoint", $0) }) { service, reply in
                service.restoreCheckpoint(requestBytes, chunk: chunk, withReply: reply)
            }
            guard response.ok else {
                throw BpyRuntimeError.unavailable(
                    response.message ?? "The confirmed 3D checkpoint could not be restored."
                )
            }
            if final {
                if probe != nil {
                    let replay = try call(observing: { observe("restoreCheckpointReplay", $0) }) { service, reply in
                        service.restoreCheckpoint(requestBytes, chunk: chunk, withReply: reply)
                    }
                    guard replay.ok, replay.confirmedRevision == revision else {
                        throw BpyRuntimeError.invalidOutput("The actual final restore chunk could not be replayed.")
                    }
                }
                break
            }
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
        let directoryPathResult = resolvedDirectory.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.fcntl(directoryFD, F_GETPATH, base)
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
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard fileFD >= 0 else {
            throw BpyRuntimeError.invalidInput("Approved input is unavailable.")
        }
        let handle = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        var resolvedFile = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let expectedFile = input.approvedDirectory.appendingPathComponent(input.filename).path
        let filePathResult = resolvedFile.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.fcntl(fileFD, F_GETPATH, base)
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
        let digest = try BpyApprovedInputDigest.read(handle, expectedBytes: UInt64(before.st_size))
        var after = stat()
        guard fstat(fileFD, &after) == 0,
              (after.st_mode & S_IFMT) == S_IFREG, after.st_nlink == 1,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw BpyRuntimeError.invalidInput("Approved input changed while it was hashed.")
        }
        try handle.seek(toOffset: 0)
        return PreparedBpyInput(
            input: input,
            handle: handle,
            before: before,
            totalBytes: UInt64(before.st_size),
            sha256: digest
        )
    }

    static func requireDiagnosticPaths(_ paths: [String]) throws {
        guard paths.count <= 8, Set(paths).count == paths.count,
              paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) && $0.utf8.count <= 4_096 }) else {
            throw BpyRuntimeError.invalidInput("Diagnostic denial paths must be distinct, bounded absolute file paths.")
        }
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
        guard BpyOutputContract.acceptsOutputs(descriptors, fileLimit: limits.files, byteLimit: limits.outputBytes) else {
            throw BpyRuntimeError.invalidOutput("The worker returned invalid or over-budget output descriptors.")
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
            valid = BpyBlendFileFormat.accepts(prefix)
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
        guard !closed, !closing, sessionID == identifier else {
            lock.unlock()
            value.invalidate()
            return
        }
        connection = value
        lock.unlock()
        value.resume()
    }

    private func rotateTransport() {
        lock.lock()
        guard !closed, !closing else {
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

    func nativeProtocolProbe(confirmedJobID: UUID) throws -> Data {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else {
            throw BpyRuntimeError.unavailable("The native protocol probe requires explicit acceptance.")
        }
        let identifier = currentSessionID()
        let checkpoint = protocolProbeCheckpoint()
        guard let revision = checkpoint.0, let scene = checkpoint.1 else { throw BpyRuntimeError.invalidOutput("The protocol probe requires an actual confirmed scene.") }
        guard limits.inputBytes >= 8 else {
            throw BpyRuntimeError.invalidInput("The protocol probe requires at least eight input bytes.")
        }
        var responses: [String: String] = [:]
        var completion: [BpyNativeProtocolExchange] = []
        var exchangeOrder: [String] = []
        var requests: [String: String] = [:]
        var chunks: [String: String] = [:]
        func send(_ label: String, request: Data, connection foreign: NSXPCConnection? = nil,
                  _ invoke: (BpyRuntimeServiceProtocol, Data, @escaping (Data) -> Void) -> Void) throws -> BpyServiceResponse {
            requests[label] = request.base64EncodedString()
            let response: BpyServiceResponse
            var responseBytes: Data?
            if let foreign {
                let box = BpyReplyBox(), done = DispatchSemaphore(value: 0)
                guard let proxy = foreign.remoteObjectProxyWithErrorHandler({ error in
                    if box.store(error: error) { done.signal() }
                }) as? BpyRuntimeServiceProtocol else { throw BpyRuntimeError.unavailable("The foreign probe connection is unavailable.") }
                invoke(proxy, request) { data in if box.store(response: data) { done.signal() } }
                guard done.wait(timeout: .now() + 30) == .success else { throw BpyRuntimeError.timedOut }
                let result = box.load()
                if let error = result.2 { throw error }
                guard let bytes = result.0 else { throw BpyRuntimeError.invalidOutput("The foreign probe returned no bytes.") }
                responseBytes = bytes
                response = try Self.decode(bytes)
            } else {
                response = try call(observing: { responseBytes = $0 }) { service, reply in invoke(service, request, reply) }
            }
            guard let responseBytes else { throw BpyRuntimeError.invalidOutput("The protocol exchange has no response bytes.") }
            responses[label] = responseBytes.base64EncodedString()
            exchangeOrder.append(label)
            return response
        }
        let foreign = NSXPCConnection(serviceName: serviceName)
        defer { foreign.invalidate() }
        foreign.remoteObjectInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        foreign.resume()
        let reference = try Self.encode(BpyJobReference(sessionID: identifier, jobID: confirmedJobID))
        let open = try Self.encode(BpyOpenSessionRequest(sessionID: identifier, documentID: documentID, limits: limits))
        let stolen = try send("foreign-open", request: open, connection: foreign) { $0.openSession($1, withReply: $2) }
        let foreignStatus = try send("foreign-status", request: reference, connection: foreign) { $0.jobStatus($1, withReply: $2) }
        let foreignClose = try send("foreign-close", request: Self.encode(BpySessionReference(sessionID: identifier)), connection: foreign) { $0.closeSession($1, withReply: $2) }
        foreign.invalidate()
        guard !stolen.ok, !foreignStatus.ok, !foreignClose.ok else { throw BpyRuntimeError.invalidOutput("A second XPC connection acquired another connection's session.") }
        let owner = try send("owner-after-foreign-close", request: reference) { $0.jobStatus($1, withReply: $2) }
        guard owner.ok, owner.state == .confirmed else { throw BpyRuntimeError.invalidOutput("The foreign connection closed the legitimate owner's scene.") }
        let staleConnection = NSXPCConnection(serviceName: serviceName)
        let replacementConnection = NSXPCConnection(serviceName: serviceName)
        for connection in [staleConnection, replacementConnection] {
            connection.remoteObjectInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
            connection.resume()
        }
        defer { staleConnection.invalidate(); replacementConnection.invalidate() }
        let reservationID = UUID()
        let reservationOpen = try Self.encode(BpyOpenSessionRequest(sessionID: reservationID, documentID: documentID, limits: limits))
        guard try send("reservation-first-owner", request: reservationOpen, connection: staleConnection,
                       { $0.openSession($1, withReply: $2) }).ok else {
            throw BpyRuntimeError.invalidOutput("The reservation probe could not prepare its session.")
        }
        lock.lock()
        let currentStorage = storageVolume?.lease
        lock.unlock()
        guard let currentStorage else { throw BpyRuntimeError.invalidOutput("The protocol probe has no actual storage lease.") }
        let brokenStorage = BpyStorageLease(id: currentStorage.id, mountPath: currentStorage.mountPath,
            device: currentStorage.device, capacityBytes: currentStorage.capacityBytes, bookmark: Data([1, 2, 3]))
        let failedOpen = try Self.encode(BpyOpenSessionRequest(sessionID: reservationID, documentID: documentID,
            limits: limits, storage: brokenStorage))
        let reservationClose = try Self.encode(BpySessionReference(sessionID: reservationID))
        guard try !send("reservation-failed-bookmark", request: failedOpen, connection: staleConnection,
                        { $0.openSession($1, withReply: $2) }).ok,
              try send("reservation-new-owner", request: reservationOpen, connection: replacementConnection,
                       { $0.openSession($1, withReply: $2) }).ok,
              try !send("reservation-stale-close", request: reservationClose, connection: staleConnection,
                        { $0.closeSession($1, withReply: $2) }).ok,
              try !send("reservation-stale-reopen", request: reservationOpen, connection: staleConnection,
                        { $0.openSession($1, withReply: $2) }).ok,
              try send("reservation-survived-stale-close", request: reservationOpen, connection: replacementConnection,
                       { $0.openSession($1, withReply: $2) }).ok,
              try send("reservation-cleanup", request: reservationClose, connection: replacementConnection,
                       { $0.closeSession($1, withReply: $2) }).ok else {
            throw BpyRuntimeError.invalidOutput("A stale connection invalidated a replacement reservation owner.")
        }
        let confirm = BpyConfirmJobRequest(sessionID: identifier, jobID: confirmedJobID, revision: revision, sceneSHA256: Self.sha256(scene))
        guard try send("confirm-replay", request: Self.encode(confirm), { $0.confirmJob($1, withReply: $2) }).ok else {
            throw BpyRuntimeError.invalidOutput("An exact consumed confirmation could not be replayed.")
        }
        let stagedID = UUID(), reservedID = UUID(), otherID = UUID()
        let bytes = Data("{}".utf8), hash = Self.sha256(Data("{}".utf8))
        func stage(_ label: String, id: UUID, size: UInt64, sha: String, final: Bool, data: Data,
                   name: String = "probe.json", offset: UInt64 = 0) throws -> BpyServiceResponse {
            let value = BpyStageInputRequest(sessionID: identifier, jobID: id, name: name, offset: offset,
                totalBytes: size, sha256: sha, finalChunk: final)
            chunks[label] = data.base64EncodedString()
            return try send(label, request: Self.encode(value)) { $0.stageInput($1, chunk: data, withReply: $2) }
        }
        func cancel(_ label: String, _ id: UUID) throws -> BpyServiceResponse {
            try send(label, request: Self.encode(BpyJobReference(sessionID: identifier, jobID: id))) { $0.cancelJob($1, withReply: $2) }
        }
        var cleanedUp = false
        defer {
            if !cleanedUp {
                _ = try? cancel("cleanup-staged", stagedID)
                _ = try? cancel("cleanup-reserved", reservedID)
                _ = try? cancel("cleanup-other", otherID)
            }
        }
        guard try !stage("invalid-final-hash", id: stagedID, size: 2, sha: String(repeating: "0", count: 64), final: true, data: bytes).ok,
              try stage("valid-final-after-failure", id: stagedID, size: 2, sha: hash, final: true, data: bytes).ok else {
            throw BpyRuntimeError.invalidOutput("A failed final chunk wedged or bypassed its actual upload slot.")
        }
        let reservation = limits.inputBytes - 2
        guard try stage("reserve-global-input-budget", id: reservedID, size: reservation, sha: hash, final: false, data: Data([0])).ok,
              try !stage("cross-job-budget-refused", id: otherID, size: 2, sha: hash, final: true, data: bytes).ok else {
            throw BpyRuntimeError.invalidOutput("Unsubmitted job IDs bypassed the session input reservation.")
        }
        _ = try cancel("cancel-reservation", reservedID)
        guard try stage("budget-released-after-cancel", id: otherID, size: 2, sha: hash, final: true, data: bytes).ok else {
            throw BpyRuntimeError.invalidOutput("Cancelling unsubmitted staging did not release its reservation.")
        }
        _ = try cancel("cancel-unrelated-unknown-job", UUID())
        guard try stage("literal-part-name", id: stagedID, size: 2, sha: hash, final: true, data: bytes, name: "foo.part").ok,
              try stage("partial-input", id: stagedID, size: 2, sha: hash, final: false, data: Data("{".utf8), name: "foo").ok else {
            throw BpyRuntimeError.invalidOutput("The actual literal .part input or partial sibling could not be staged.")
        }
        let partialSource = "assert all((input_dir / n).read_text() == '{}' for n in ['foo.part', 'probe.json'])"
        let partialFingerprint = BpyJobFingerprintV5.compute(expectedRevision: revision, source: partialSource,
            requestedTimeout: nil, effectiveTimeout: limits.timeoutSeconds,
            inputs: ["foo.part", "probe.json"].map { .init(name: $0, byteCount: 2, sha256: hash) },
            deniedPaths: [], autoexecControl: false, identityWriteFailure: false, identityCaptureFailure: false)
        let partialRun = BpyRunJobRequest(sessionID: identifier, jobID: stagedID, expectedRevision: revision,
            source: partialSource, inputNames: ["foo.part", "probe.json"], fingerprint: partialFingerprint)
        guard try !send("submit-with-partial-input", request: Self.encode(partialRun), { $0.runJob($1, withReply: $2) }).ok,
              try stage("completed-partial-input", id: stagedID, size: 2, sha: hash, final: true,
                        data: Data("}".utf8), name: "foo", offset: 1).ok else {
            throw BpyRuntimeError.invalidOutput("A partial input reached execution or could not be completed after refusal.")
        }
        let inputNames = ["foo", "foo.part", "probe.json"]
        let source = "assert set(p.name for p in input_dir.iterdir()) == {'foo', 'foo.part', 'probe.json'}; assert all((input_dir / n).read_text() == '{}' for n in ['foo', 'foo.part', 'probe.json'])"
        let fingerprint = BpyJobFingerprintV5.compute(expectedRevision: revision, source: source, requestedTimeout: nil,
            effectiveTimeout: limits.timeoutSeconds, inputs: inputNames.map { .init(name: $0, byteCount: 2, sha256: hash) },
            deniedPaths: [], autoexecControl: false, identityWriteFailure: false, identityCaptureFailure: false)
        let run = BpyRunJobRequest(sessionID: identifier, jobID: stagedID, expectedRevision: revision, source: source,
            inputNames: inputNames, fingerprint: fingerprint)
        let accepted = try send("service-submit", request: Self.encode(run)) { $0.runJob($1, withReply: $2) }
        let joined = try send("service-submit-replay", request: Self.encode(run)) { $0.runJob($1, withReply: $2) }
        guard accepted.ok, joined.ok, joined.joinedExistingJob, joined.jobFingerprint == fingerprint else {
            throw BpyRuntimeError.invalidOutput("The actual service did not idempotently join its consumed Job ID.")
        }
        let status = try Self.encode(BpyJobReference(sessionID: identifier, jobID: stagedID))
        let deadline = Date().addingTimeInterval(Double(limits.timeoutSeconds) + 15)
        var complete: BpyServiceResponse?
        while Date() < deadline {
            let polled = try send("service-completed", request: status) { $0.jobStatus($1, withReply: $2) }
            guard let polledBytes = responses["service-completed"] else {
                throw BpyRuntimeError.invalidOutput("The completion poll has no response bytes.")
            }
            completion.append(.init(method: "jobStatus", request: status.base64EncodedString(), response: polledBytes))
            let value = try authorizeProcessIfNeeded(polled, jobID: stagedID, observing: { request, response in
                completion.append(.init(method: "authorizeProcess", request: request.base64EncodedString(),
                                        response: response.base64EncodedString()))
            })
            if value.state == .awaitingConfirmation { complete = value; break }
            guard value.ok, value.state == .accepted || value.state == .running else {
                throw BpyRuntimeError.invalidOutput(value.message ?? "The staged service job failed.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let complete else { throw BpyRuntimeError.timedOut }
        guard complete.jobID == stagedID, complete.jobFingerprint == fingerprint else {
            throw BpyRuntimeError.invalidOutput("The completed protocol job has another identity.")
        }
        guard try cancel("cleanup-staged", stagedID).ok else {
            throw BpyRuntimeError.invalidOutput("The protocol probe could not reject its actual candidate.")
        }
        _ = try cancel("cleanup-reserved", reservedID)
        _ = try cancel("cleanup-other", otherID)
        cleanedUp = true
        return try JSONEncoder().encode(BpyNativeProtocolProbeEvidence(
            schema: "nexgenvideo/bpy-native-protocol-evidence/2", requests: requests, chunks: chunks,
            responses: responses, exchangeOrder: exchangeOrder, completion: completion, restoreOpen: nil, restore: nil))
    }

    func nativeProtocolRestoreProbe(addingTo evidence: Data) throws -> (ready: BpyServiceResponse, evidence: Data, checkpoint: Data) {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else {
            throw BpyRuntimeError.unavailable("The native restore probe requires explicit acceptance.")
        }
        var document = try JSONDecoder().decode(BpyNativeProtocolProbeEvidence.self, from: evidence)
        guard document.schema == "nexgenvideo/bpy-native-protocol-evidence/2", document.restore == nil else {
            throw BpyRuntimeError.invalidOutput("The protocol evidence already contains a restore.")
        }
        let probe = BpyNativeRestoreProbe()
        let ready = try ensureOpen(restoreProbe: probe)
        guard let checkpoint = probe.checkpoint, let open = probe.open, !probe.exchanges.isEmpty else {
            throw BpyRuntimeError.invalidOutput("No actual checkpoint upload occurred.")
        }
        document.restoreOpen = open
        document.restore = probe.exchanges
        return (ready, try JSONEncoder().encode(document), checkpoint)
    }

    private func protocolProbeCheckpoint() -> (String?, Data?) {
        lock.lock()
        defer { lock.unlock() }
        return (confirmedRevision, confirmedSceneData)
    }

    private func currentConnection(allowClosing: Bool = false) throws -> (NSXPCConnection, UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, (!closing || allowClosing), let connection else {
            throw BpyRuntimeError.unavailable("The 3D XPC service is unavailable.")
        }
        return (connection, sessionID)
    }

    private func call(
        timeout: TimeInterval = 30,
        allowClosing: Bool = false,
        observing: ((Data) -> Void)? = nil,
        _ invoke: (BpyRuntimeServiceProtocol, @escaping (Data) -> Void) throws -> Void
    ) throws -> BpyServiceResponse {
        let box = BpyReplyBox()
        let semaphore = DispatchSemaphore(value: 0)
        let (activeConnection, transportID) = try currentConnection(allowClosing: allowClosing)
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
        observing?(data)
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
        jobID: UUID,
        observing: ((Data, Data) -> Void)? = nil
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
        let requestBytes = try Self.encode(request)
        let authorized = try call(observing: { observing?(requestBytes, $0) }) { service, reply in
            service.authorizeProcess(requestBytes, withReply: reply)
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
        BpyJobFingerprintV5.compute(expectedRevision: expectedRevision, source: source,
            requestedTimeout: requestedTimeoutSeconds, effectiveTimeout: effectiveTimeoutSeconds,
            inputs: inputs.map { .init(name: $0.input.filename, byteCount: $0.totalBytes, sha256: $0.sha256) },
            deniedPaths: diagnosticDeniedPaths, autoexecControl: diagnosticAutoexecPositiveControl,
            identityWriteFailure: diagnosticSupervisorIdentityWriteFailure,
            identityCaptureFailure: diagnosticSupervisorIdentityCaptureFailure)
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

struct BpyNativeProtocolProbeEvidence: Codable, Sendable {
    let schema: String
    let requests: [String: String]
    let chunks: [String: String]
    let responses: [String: String]
    let exchangeOrder: [String]
    let completion: [BpyNativeProtocolExchange]
    var restoreOpen: BpyNativeProtocolExchange?
    var restore: [BpyNativeProtocolExchange]?
}

struct BpyNativeProtocolExchange: Codable, Sendable {
    let method: String
    let request: String
    let response: String
    var chunkSHA256: String? = nil
    var chunkBytes: Int? = nil
}

private final class BpyNativeRestoreProbe {
    var open: BpyNativeProtocolExchange?
    var checkpoint: Data?
    var exchanges: [BpyNativeProtocolExchange] = []
}

struct BpyRuntimePresentation: Sendable {
    fileprivate let id: UUID
}

struct BpyRuntimeOperation: Sendable {
    fileprivate let id: UUID
    let session: BpyRuntimeSession
}

@MainActor
final class BpyRuntimeHost {
    static let shared = BpyRuntimeHost()

    private struct Entry {
        weak var document: VideoProject?
        let documentID: String
        var session: BpyRuntimeSession?
        var presentationIDs: Set<UUID> = []
        var operationIDs: Set<UUID> = []
    }

    private struct CleanupAttempt {
        let id = UUID()
        let task: Task<Bool, Never>
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var retiring: [ObjectIdentifier: BpyRuntimeSession] = [:]
    private var cleanupTasks: [ObjectIdentifier: CleanupAttempt] = [:]
    private var shuttingDown = false
    private let closedDocuments = NSHashTable<VideoProject>(options: [.weakMemory, .objectPointerPersonality])

    private init() {}

    var cleanupFailure: String? {
        retiring.values.compactMap(\.cleanupFailure).sorted().first
    }

    var canQuitWithReservedStorage: Bool {
        !retiring.isEmpty && retiring.values.allSatisfy(\.canQuitWithReservedStorage)
            && entries.values.compactMap(\.session).allSatisfy { !$0.occupiesHostSlot }
    }

    func confirmQuitWithReservedStorage() -> Bool {
        guard canQuitWithReservedStorage else { return false }
        shuttingDown = true
        return true
    }

    var hasReservedSlots: Bool {
        (entries.values.compactMap(\.session) + Array(retiring.values)).contains(where: \.occupiesHostSlot)
    }

    @discardableResult
    func register(document: VideoProject, documentID: String) -> BpyRuntimePresentation? {
        removeExpiredDocuments()
        let key = ObjectIdentifier(document)
        guard !shuttingDown, !closedDocuments.contains(document) else { return nil }
        if entries[key] == nil {
            entries[key] = Entry(document: document, documentID: documentID, session: nil)
        }
        guard entries[key]?.documentID == documentID else { return nil }
        let id = UUID()
        entries[key]?.presentationIDs.insert(id)
        return BpyRuntimePresentation(id: id)
    }

    func acquireOperation(document: VideoProject, documentID: String) throws -> BpyRuntimeOperation {
        removeExpiredDocuments()
        let key = ObjectIdentifier(document)
        guard !shuttingDown, !closedDocuments.contains(document) else {
            throw BpyRuntimeError.unavailable("The location document is closing.")
        }
        if entries[key] == nil {
            entries[key] = Entry(document: document, documentID: documentID, session: nil)
        }
        guard entries[key]?.documentID == documentID else {
            throw BpyRuntimeError.unavailable("The production project changed. Reopen its location editor.")
        }
        guard let session = self.session(for: document) else {
            if entries[key]?.presentationIDs.isEmpty == true, entries[key]?.operationIDs.isEmpty == true {
                entries.removeValue(forKey: key)
            }
            throw BpyRuntimeError.unavailable(cleanupFailure
                ?? "The location runtime is busy. Close an unused location editor, then retry.")
        }
        let id = UUID()
        entries[key]?.operationIDs.insert(id)
        return BpyRuntimeOperation(id: id, session: session)
    }

    func isOperationActive(_ operation: BpyRuntimeOperation) -> Bool {
        removeExpiredDocuments()
        return !shuttingDown && operation.session.isAvailable && entries.values.contains {
            $0.session === operation.session && $0.operationIDs.contains(operation.id)
        }
    }

    func releaseOperation(_ operation: BpyRuntimeOperation) {
        guard let key = entries.first(where: { $0.value.operationIDs.contains(operation.id) })?.key else { return }
        entries[key]?.operationIDs.remove(operation.id)
        retireIfUnused(key)
    }

    func releasePresentation(_ presentation: BpyRuntimePresentation) {
        guard let key = entries.first(where: { $0.value.presentationIDs.contains(presentation.id) })?.key else { return }
        entries[key]?.presentationIDs.remove(presentation.id)
        retireIfUnused(key)
    }

    private func retireIfUnused(_ key: ObjectIdentifier) {
        guard let entry = entries[key], entry.presentationIDs.isEmpty, entry.operationIDs.isEmpty else { return }
        entries.removeValue(forKey: key)
        if let session = entry.session { retire(session) }
    }

    func session(
        for document: VideoProject,
        diagnosticOpenFailure: Bool = false
    ) -> BpyRuntimeSession? {
        removeExpiredDocuments()
        let key = ObjectIdentifier(document)
        guard !shuttingDown, var entry = entries[key] else { return nil }
        if let session = entry.session, session.isAvailable { return session }
        guard entry.operationIDs.isEmpty else { return nil }
        if let session = entry.session, session.occupiesHostSlot {
            retire(session)
        }
        entry.session = nil
        entries[key] = entry
        let sessions = entries.values.compactMap(\.session) + Array(retiring.values)
        let used = Set(sessions.filter(\.occupiesHostSlot).map(\.serviceName))
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
        closedDocuments.add(document)
        guard let session = entries.removeValue(forKey: ObjectIdentifier(document))?.session else { return }
        retire(session)
    }

    func shutdown() async -> Bool {
        shuttingDown = true
        let sessions = entries.values.compactMap(\.session)
        for key in Array(entries.keys) {
            entries[key]?.session = nil
            entries[key]?.operationIDs.removeAll()
        }
        for session in sessions { retire(session, presentFailure: false) }
        let success = await retryCleanup()
        if !success { shuttingDown = false }
        return success
    }

    func retryCleanup() async -> Bool {
        let previous = cleanupTasks
        for (key, attempt) in previous {
            let success = await attempt.task.value
            finishCleanup(key: key, attempt: attempt.id, success: success, presentFailure: false)
        }
        for session in Array(retiring.values) { retire(session, presentFailure: false) }
        let attempts = cleanupTasks
        for (key, attempt) in attempts {
            let success = await attempt.task.value
            finishCleanup(key: key, attempt: attempt.id, success: success, presentFailure: false)
        }
        retiring = retiring.filter { $0.value.occupiesHostSlot }
        return retiring.isEmpty
    }

    private func removeExpiredDocuments() {
        for key in Array(entries.keys) where entries[key]?.document == nil {
            if let session = entries.removeValue(forKey: key)?.session { retire(session) }
        }
        retiring = retiring.filter { $0.value.occupiesHostSlot }
    }

    private func retire(_ session: BpyRuntimeSession, presentFailure: Bool = true) {
        let key = ObjectIdentifier(session)
        guard session.occupiesHostSlot else {
            retiring.removeValue(forKey: key)
            return
        }
        retiring[key] = session
        guard cleanupTasks[key] == nil else { return }
        session.beginClose()
        let attempt = CleanupAttempt(task: Task.detached(priority: .userInitiated) { session.close() })
        cleanupTasks[key] = attempt
        Task { [weak self] in
            let success = await attempt.task.value
            guard let self else { return }
            self.finishCleanup(key: key, attempt: attempt.id, success: success, presentFailure: presentFailure)
        }
    }

    private func finishCleanup(key: ObjectIdentifier, attempt: UUID, success: Bool, presentFailure: Bool) {
        guard cleanupTasks[key]?.id == attempt else { return }
        cleanupTasks.removeValue(forKey: key)
        if success {
            retiring.removeValue(forKey: key)
        } else if presentFailure && !shuttingDown {
            NSApplication.shared.presentError(NSError(
                domain: "NexGenVideo.BpyRuntime", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "3D runtime cleanup failed.",
                    NSLocalizedFailureReasonErrorKey: retiring[key]?.cleanupFailure ?? "The runtime storage is still in use.",
                    NSLocalizedRecoverySuggestionErrorKey: "The runtime slot stays reserved. Follow the recovery instruction above; project files remain unchanged."
                ]
            ))
        }
    }
}
