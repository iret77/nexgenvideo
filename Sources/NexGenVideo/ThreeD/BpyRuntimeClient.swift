import AppKit
import BpyRuntimeProtocol
import CryptoKit
import Darwin
import Foundation

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

private struct BpyProcessLease: Sendable {
    let transportID: UUID
    let processIdentifier: pid_t
    let startAbsoluteTime: UInt64
    let executable: String
}

private final class BpyTransportRecovery: @unchecked Sendable {
    private let completed = DispatchGroup()
    private let lock = NSLock()
    private var exited = false

    init() { completed.enter() }

    func finish(exited: Bool) {
        lock.lock()
        self.exited = exited
        lock.unlock()
        completed.leave()
    }

    func wait() -> Bool {
        guard completed.wait(timeout: .now() + 6) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return exited
    }
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
        let path = String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        return try? BpyRuntimePath.canonical(URL(fileURLWithPath: path))
    }
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
    let lease: BpyRuntimeResultLease?

    init(response: BpyServiceResponse, stagedOutputs: [String: URL], lease: BpyRuntimeResultLease? = nil) {
        self.response = response; self.stagedOutputs = stagedOutputs; self.lease = lease
    }

    func release() { lease?.release() }
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
    private var hostMonitor: BpyHostMonitor?
    private var opened = false
    private var transportInvalidated = false
    private var transportRecovery: BpyTransportRecovery?
    private var closing = false
    private var closed = false
    private var validatedCandidates: [UUID: (sha256: String, url: URL)] = [:]
    private var candidateJobIDs = Set<UUID>()
    private var jobFingerprints: [UUID: String] = [:]
    private var jobOrigins: [UUID: (revision: String?, sha256: String?)] = [:]
    private var submittedJobIDs = Set<UUID>()
    private var submittedTransportIDs: [UUID: UUID] = [:]
    private var cachedResults: [UUID: BpyRuntimeJobResult] = [:]
    private var cachedLogs: [UUID: String] = [:]
    private var logOrder: [UUID] = []
    private var lastReadyResponse: BpyServiceResponse?
    private var confirmedSceneFile: BpyRuntimeFile?
    private var outputReservations: [UUID: UUID] = [:]
    private struct TransferRecord {
        let reservation: UUID
        let transport: UUID
        let pairIDs: [UUID]
        let request: BpyReleaseResourcesRequest
        var releaseRequested = false
        var releaseDeadline: TimeInterval?
    }
    private var transfers: [UUID: TransferRecord] = [:]
    private let transferCleanupLock = NSLock()
    private var transferDeadlines: [UUID: TimeInterval] = [:]
    private var openAdmission: BpyAdmissionIdentity?
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
    private let memoryOwner = UUID()
    private let memoryGeneration = UUID()
    private var storageDataVolume: BpyRuntimeVolume?
    private var jobAdmissions: [UUID: BpyAdmissionIdentity] = [:]
    private var operationTokens: [UUID: BpyOperationCancellation] = [:]
    private var uploadedJobIDs: Set<UUID> = []
    private var stagingJobIDs: Set<UUID> = []
    private var hostDisposalDeadline: TimeInterval?
    private let memoryCoordinator: BpyMemoryCoordinator

    private final class OpenBudget {
        var admissionDeadline: TimeInterval?
        var rpcDeadline: TimeInterval?
    }

    init(
        documentID: String,
        limits: BpyRuntimeLimits = .init(),
        serviceName: String = bpyRuntimeServiceNames[0],
        diagnosticOpenFailure: Bool = false,
        memoryCoordinator: BpyMemoryCoordinator = .shared
    ) {
        precondition(memoryCoordinator === BpyMemoryCoordinator.shared
            || ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false)
        self.memoryCoordinator = memoryCoordinator
        let identifier = UUID()
        sessionID = UUID()
        self.documentID = documentID
        self.confirmedRevision = nil
        self.limits = limits
        self.serviceName = serviceName
        self.diagnosticOpenFailure = diagnosticOpenFailure
        stagingRoot = BpyHostStaging.shared.location("session-" + identifier.uuidString)
        installConnection()
    }

    deinit {
        close()
        // A close-racing caller can still register until the session is destroyed.
        memoryCoordinator.retire(owner: memoryOwner)
    }

    var bundledRuntimeRoot: URL {
        get throws { try BpyRuntimeBundleLayout(app: Bundle.main.bundleURL, serviceName: serviceName).runtime }
    }

    func consumerWork(cancellation: BpyOperationCancellation) throws -> BpyConsumerWork {
        try requireOperation(cancellation)
        return try memoryCoordinator.beginConsumer(owner: memoryOwner, cancellation: cancellation, checking: {
            if Task.isCancelled { cancellation.cancel() }
            try self.requireOperation(cancellation)
        })
    }

    func mediaReadScope(cancellation: BpyOperationCancellation) throws -> BpyMediaReadScope {
        try requireOperation(cancellation)
        return BpyMediaReadScope.operation(dataRoot: ProjectWorkingCopy.home(documentID).appendingPathComponent("pipeline"),
            owner: memoryOwner, cancellation: cancellation, memory: memoryCoordinator).checking { [weak self] in
                guard let self else { throw BpyAdmissionFailure.closed }
                try requireOperation(cancellation)
            }
    }

    func digestRuntimeFile(at url: URL, cancellation: BpyOperationCancellation) throws -> String {
        try mediaReadScope(cancellation: cancellation).digest(at: url)
    }

    func sequenceRetention(root: URL) -> BpySequenceRetention {
        .init(root: root, workOwner: memoryOwner)
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

    func nativeMediaContext() throws -> (owner: UUID, slot: String, limits: BpyRuntimeLimits, memory: BpyMemoryCoordinator) {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw BpyAdmissionFailure.closed }
        return (memoryOwner, serviceName, limits, memoryCoordinator)
    }

    func nativeRecoveryMonitor() throws -> BpyHostMonitor {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
              let monitor = lock.withLock({ hostMonitor }) else { throw BpyAdmissionFailure.closed }
        return monitor
    }

    func nativeCheckpointStamp() throws -> [String: String] {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw BpyAdmissionFailure.closed }
        return lock.withLock { ["transport": sessionID.uuidString, "revision": confirmedRevision ?? "",
            "sha256": confirmedSceneFile?.sha256 ?? "", "uploadedJobs": String(uploadedJobIDs.count)] }
    }

    func nativeRefreshWorkerRole() throws -> BpyClockReading {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
              let worker = lock.withLock({ storageVolume }) else { throw BpyAdmissionFailure.closed }
        return try worker.nativeRefreshWorkerRole()
    }

    func nativeSourceBindingDiagnostic(target: String, expectedRevision: String) throws -> BpySourceBindingEvidence {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
              ["source.py", "job.json"].contains(target) else { throw SpatialSceneError.changed }
        let source = "print('BOUND_SOURCE_RAN', flush=True)\nbpy.context.scene.render.resolution_x = 64\nbpy.context.scene.render.resolution_y = 64"
        let replacement = target == "source.py" ? Data("raise RuntimeError('UNAPPROVED_SOURCE_EXECUTED')".utf8) : Data("{\"memoryPolicy\":\"unapproved\"}".utf8)
        let job = UUID(), token = BpyOperationCancellation(), box = BpyDiagnosticJobResult()
        defer { token.cancel(); box.abandon(); _ = try? cancel(jobID: job) }
        _ = try ensureOpen(cancellation: token)
        let transport = currentSessionID()
        let statusRequest = try Self.encode(BpyJobReference(sessionID: transport, jobID: job))
        let deadline = try BpyRuntimeClock.awakeSeconds() + Double(limits.timeoutSeconds)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            box.complete(Result { try runJob(id: job, expectedRevision: expectedRevision, source: source,
                diagnosticDeferExecutionAuthorization: true, cancellation: token) })
        }
        var pending: BpyServiceResponse?
        while pending == nil {
            if let early = box.take() { let result = try early.get(); result.release(); throw SpatialSceneError.changed }
            guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw BpyRuntimeError.timedOut }
            let value = try call { service, reply in service.jobStatus(statusRequest, withReply: reply) }
            guard value.jobID == nil || value.jobID == job else { throw SpatialSceneError.changed }
            if value.activeProcessAuthorizationID != nil { pending = value }
            else { Thread.sleep(forTimeInterval: 0.02) }
        }
        guard let pending, let execution = pending.activeProcessAuthorizationID,
              let monitor = lock.withLock({ hostMonitor }), let data = lock.withLock({ storageDataVolume }),
              let admission = lock.withLock({ jobAdmissions[job] }), let dataBytes = limits.dataStorageBytes else {
            throw SpatialSceneError.changed
        }
        let gate = try monitor.diagnosticGate(execution: execution)
        guard gate.process.pid == pending.activeProcessIdentifier, gate.process.start == pending.activeProcessStartAbsoluteTime,
              gate.process.executable == pending.activeProcessExecutable, gate.permit == admission.id else { throw SpatialSceneError.changed }
        let mount = try BpyStoragePaths.validateMount(data.lease, maximumBytes: dataBytes)
        defer { Darwin.close(mount) }
        let relative = transport.uuidString + "/jobs/" + job.uuidString
        let directory = openat(mount, relative, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(directory) }
        let original = openat(directory, target, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard original >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(original) }
        var before = stat()
        guard fstat(original, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_uid == getuid(), before.st_size > 0, before.st_size <= 1_024 * 1_024,
              UInt64(UInt32(bitPattern: before.st_dev)) == data.lease.device else { throw SpatialSceneError.changed }
        var originalBytes = Data(count: Int(before.st_size))
        try originalBytes.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = pread(original, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        let originalSHA256 = Self.sha256(originalBytes)
        guard target != "source.py" || originalBytes == Data(source.utf8) else { throw SpatialSceneError.changed }
        let name = "mutation-" + UUID().uuidString
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var installed = false
        defer { Darwin.close(descriptor); if !installed { _ = unlinkat(directory, name, 0) } }
        try replacement.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
        var after = stat()
        guard fsync(descriptor) == 0, fstat(descriptor, &after) == 0,
              renameat(directory, name, directory, target) == 0, fsync(directory) == 0 else { throw POSIXError(.EIO) }
        installed = true
        guard let mutated = BpyRuntimeClock.read() else { throw BpyAdmissionFailure.sensorUnavailable }
        let gateAfter = try monitor.diagnosticGate(execution: execution)
        var authorized = pending
        while authorized.activeProcessAuthorizationID == execution {
            if let early = box.take() { let result = try early.get(); result.release(); throw SpatialSceneError.changed }
            if let stop = try memoryCoordinator.receipt(admission.id).stop { throw BpyExecutionInterruption(reason: stop) }
            guard try BpyRuntimeClock.awakeSeconds() < admission.admissionDeadline else { throw BpyRuntimeError.timedOut }
            authorized = try authorizeProcessIfNeeded(authorized, jobID: job)
            if authorized.activeProcessAuthorizationID == execution { Thread.sleep(forTimeInterval: 0.005) }
        }
        guard let authorizedAt = BpyRuntimeClock.read() else { throw BpyAdmissionFailure.sensorUnavailable }
        var completionDeadline = admission.admissionDeadline + 2 * admission.timeout + 15 + 30
        while true {
            if let completed = box.take() {
                let result = try completed.get()
                defer { result.release() }
                guard let receipt = result.lease?.execution, receipt.identity.transport == transport,
                      receipt.identity.job == job, confirmedRevision == expectedRevision else { throw SpatialSceneError.changed }
                let ended = try monitor.diagnosticEnded(execution: execution)
                return .init(target: target, source: source, originalSHA256: originalSHA256, replacementSHA256: Self.sha256(replacement),
                    originalInode: UInt64(before.st_ino), replacementInode: UInt64(after.st_ino),
                    mutatedAt: mutated, authorizedAt: authorizedAt, gateBefore: gate, gateAfter: gateAfter,
                    response: result.response, ended: ended, receipt: receipt)
            }
            if let receipt = try? memoryCoordinator.receipt(admission.id) {
                if let cleanup = receipt.cleanupStarted { completionDeadline = cleanup + BpyMemoryState.cleanupBudget + 30 }
                else if let first = receipt.firstRelease { completionDeadline = first + 2 * admission.timeout + 15 + 30 }
            }
            if let transfer = lock.withLock({ transferDeadlines[job] }) { completionDeadline = transfer }
            guard try BpyRuntimeClock.awakeSeconds() <= completionDeadline else { throw BpyRuntimeError.timedOut }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func nativeMemoryDiagnostic(_ mode: BpyBoundaryMode,
        observe: ((BpyMonitorResponse, BpyMemoryCoordinator.PermitReceipt) throws -> Void)? = nil
    ) throws -> BpyMemoryDiagnosticEvidence {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
              mode.isHostDiagnostic else { throw BpyRuntimeError.invalidInput("Invalid native host probe.") }
        submissionLock.lock(); defer { submissionLock.unlock() }
        let cancellation = BpyOperationCancellation()
        _ = try ensureOpen(cancellation: cancellation)
        let context = lock.withLock { (sessionID, hostMonitor, storageVolume, storageDataVolume) }
        guard let monitor = context.1, let worker = context.2, let data = context.3 else { throw SpatialSceneError.changed }
        let admission = try admit(kind: .boundary, job: nil, timeout: mode == .diagnosticPythonFootprint ? 120 : 30, cancellation: cancellation)
        try installAdmission(admission)
        defer { memoryCoordinator.finish(admission.id); memoryCoordinator.forget(admission.id) }
        let workerPath = context.0.uuidString + "/boundary/" + mode.rawValue
        let configPath = context.0.uuidString + "/memory-" + mode.rawValue + ".json"
        let root = URL(fileURLWithPath: worker.lease.mountPath).appendingPathComponent(workerPath)
        let config = URL(fileURLWithPath: data.lease.mountPath).appendingPathComponent(configPath)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: config, options: .atomic)
        let spec = BpyHostLaunchSpec(permit: admission.id, job: nil, mode: .boundary,
            workerLease: worker.lease.id, dataLease: data.lease.id, workerRoot: workerPath,
            configuration: configPath, configurationSHA256: Self.sha256(Data("{}".utf8)), readFiles: [], boundary: mode)
        let execution = UUID()
        let launch = BpyMonitorRequest(transport: context.0, execution: execution, operation: .launch, launch: spec)
        var response = try monitor.inspectDiagnostic(launch)
        while response.status == .deferred {
            guard try BpyRuntimeClock.awakeSeconds() < admission.admissionDeadline else { throw BpyRuntimeError.timedOut }
            Thread.sleep(forTimeInterval: 0.05)
            response = try monitor.inspectDiagnostic(launch)
        }
        guard let epoch = response.epoch, let supervisor = response.supervisor,
              [.launched, .observed].contains(response.status) else { throw SpatialSceneError.changed }
        var sequence: UInt64 = 0
        var reaped = false
        defer {
            if !reaped {
                memoryCoordinator.cancel(admission.id)
                monitor.recover(disposition: .loss) { _ in }
            }
        }
        while response.status != .gone || !response.outputComplete {
            let receipt = try memoryCoordinator.receipt(admission.id)
            let now = try BpyRuntimeClock.awakeSeconds()
            let deadline = receipt.cleanupStarted.map { $0 + 5 }
                ?? receipt.firstRelease.map { $0 + admission.timeout } ?? admission.admissionDeadline
            guard now <= deadline else { throw BpyRuntimeError.timedOut }
            sequence += 1
            response = try monitor.inspectDiagnostic(.init(transport: context.0, execution: execution, operation: .sample,
                epoch: epoch, sequence: sequence, supervisorPID: supervisor.pid, outputOffset: response.nextOutputOffset))
            guard response.status == .observed || response.status == .gone else { throw SpatialSceneError.changed }
            try observe?(response, memoryCoordinator.receipt(admission.id))
            Thread.sleep(forTimeInterval: 0.05)
        }
        reaped = true
        memoryCoordinator.finish(admission.id)
        let receipt = try memoryCoordinator.receipt(admission.id)
        let evidence = BpyMemoryDiagnosticEvidence(mode: mode, response: response, receipt: receipt)
        sequence += 1
        let detached = try monitor.inspectDiagnostic(.init(transport: context.0, execution: execution, operation: .detach,
            epoch: epoch, sequence: sequence, supervisorPID: supervisor.pid, outputOffset: response.nextOutputOffset))
        guard detached.status == .detached, detached.outputComplete else { throw SpatialSceneError.changed }
        try FileManager.default.removeItem(at: root)
        try FileManager.default.removeItem(at: config)
        return evidence
    }

    func nativePressureDiagnostic(_ scenario: BpyPressureDiagnosticScenario) throws -> BpyPressureDiagnosticEvidence {
        let memory = memoryCoordinator
        try memory.beginSelftest(owner: memoryOwner)
        defer { memory.endSelftest(owner: memoryOwner) }
        var injectedAt: BpyClockReading?
        var warningAt: BpyClockReading?
        let evidence = try nativeMemoryDiagnostic(.diagnosticPressureWait) { response, receipt in
            guard response.diagnosticBaseline != nil else { return }
            let now = try BpyRuntimeClock.awakeSeconds()
            if injectedAt == nil {
                injectedAt = BpyRuntimeClock.read()
                switch scenario {
                case .criticalEvent: injectedAt = try memory.selftestCriticalEvent(owner: self.memoryOwner)
                case .criticalSensor: try memory.selftestSensor(owner: self.memoryOwner, mode: .critical)
                case .missingSensor: try memory.selftestSensor(owner: self.memoryOwner, mode: .missing)
                case .stalledSensor: try memory.selftestSensor(owner: self.memoryOwner, mode: .stalled)
                case .sustainedWarning: try memory.selftestSensor(owner: self.memoryOwner, mode: .warning)
                }
            }
            if scenario == .sustainedWarning,
               let warning = receipt.samples.first(where: { $0.source == "selftest-sensor" && $0.pressure == 2 }) {
                if warningAt == nil { warningAt = warning.clock }
                guard receipt.stop == nil || receipt.stop == .diagnosticMemory else { throw SpatialSceneError.changed }
                if now - warning.clock.awake >= 1 { memory.cancel(receipt.identity.id, reason: .diagnosticMemory) }
            }
        }
        guard let injectedAt else { throw SpatialSceneError.changed }
        return .init(scenario: scenario, injectedAt: injectedAt, warningAt: warningAt, execution: evidence)
    }

    func nativeWarningContinuation(expectedRevision: String) throws -> BpyWarningContinuationEvidence {
        let memory = memoryCoordinator
        try memory.beginSelftest(owner: memoryOwner, warningOnWorker: true)
        defer { memory.endSelftest(owner: memoryOwner) }
        let id = UUID()
        let result = try runJob(id: id, expectedRevision: expectedRevision,
            source: "import time\ntime.sleep(1)\nbpy.data.objects.new('WARNING_CONTINUATION', None)")
        defer { result.release(); _ = try? cancel(jobID: id) }
        guard let receipt = result.lease?.execution else { throw SpatialSceneError.changed }
        return .init(response: result.response, receipt: receipt)
    }

    func nativeCriticalBoth(with other: BpyRuntimeSession) throws -> BpyDualPressureEvidence {
        guard serviceName != other.serviceName, memoryCoordinator === other.memoryCoordinator else { throw SpatialSceneError.changed }
        _ = try ready(); _ = try other.ready()
        let memory = memoryCoordinator
        try memory.beginSelftest(owners: [memoryOwner, other.memoryOwner])
        defer { memory.endSelftest(owner: memoryOwner) }
        final class Evidence: @unchecked Sendable {
            let lock = NSLock()
            var ready = Set<Int>()
            var firing = false
            var event: BpyClockReading?
            var results: [Int: Result<BpyMemoryDiagnosticEvidence, any Error>] = [:]
        }
        let evidence = Evidence(), group = DispatchGroup()
        for (index, session) in [self, other].enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let result = Result {
                    try session.nativeMemoryDiagnostic(.diagnosticPressureWait) { response, _ in
                        guard response.diagnosticBaseline != nil else { return }
                        let fire = evidence.lock.withLock {
                            evidence.ready.insert(index)
                            guard evidence.ready.count == 2, !evidence.firing else { return false }
                            evidence.firing = true
                            return true
                        }
                        if fire {
                            let event = try memory.selftestCriticalEvent(owner: self.memoryOwner)
                            evidence.lock.withLock { evidence.event = event }
                        }
                    }
                }
                evidence.lock.withLock { evidence.results[index] = result }
            }
        }
        let deadline = try BpyRuntimeClock.awakeSeconds() + 45
        while group.wait(timeout: .now() + .milliseconds(50)) != .success {
            guard try BpyRuntimeClock.awakeSeconds() < deadline else {
                memory.close(owner: memoryOwner); memory.close(owner: other.memoryOwner)
                throw BpyRuntimeError.timedOut
            }
        }
        let stopped: (BpyClockReading, [BpyMemoryDiagnosticEvidence]) = try evidence.lock.withLock {
            guard let event = evidence.event, let first = evidence.results[0], let second = evidence.results[1] else { throw SpatialSceneError.changed }
            return (event, [try first.get(), try second.get()])
        }
        let resumed = try nativeMemoryDiagnostic(.diagnosticVirtualMapping)
        return .init(event: stopped.0, executions: stopped.1, resumption: resumed)
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
        diagnosticSupervisorIdentityCaptureFailure: Bool = false,
        diagnosticReceiptBarrier: (@Sendable (BpyAdmissionIdentity) throws -> Void)? = nil,
        cancellation: BpyOperationCancellation = .init()
    ) throws -> BpyRuntimeJobResult {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        try requireOperation(cancellation)
        if diagnosticReceiptBarrier != nil {
            guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else {
                throw BpyRuntimeError.invalidInput("The receipt barrier requires native runtime acceptance.")
            }
        }
        let ownsExecution = lock.withLock { cachedResults[id] == nil && !submittedJobIDs.contains(id) }
        lock.withLock { operationTokens[id] = cancellation }
        let cancellationRegistration = cancellation.observe { [weak self] in
            if ownsExecution { self?.requestCancellation(jobID: id) }
        }
        defer { withExtendedLifetime(cancellationRegistration) {} }
        var returned = false
        var pendingLease: BpyRuntimeResultLease?
        var ownedAdmission: BpyAdmissionIdentity?
        defer {
            if !returned && ownsExecution {
                pendingLease?.release()
                abandon(jobID: id)
                if let ownedAdmission {
                    memoryCoordinator.cancel(ownedAdmission.id)
                    memoryCoordinator.forget(ownedAdmission.id)
                }
                requestTransferRelease(jobID: id)
                if let reservation = lock.withLock({ outputReservations.removeValue(forKey: id) }) {
                    BpyRetentionLedger.shared.settle(reservation)
                }
            }
            _ = lock.withLock { operationTokens.removeValue(forKey: id) }
        }
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
        _ = try ensureOpen(cancellation: cancellation)
        try drainTransfers()
        if lock.withLock({ transportInvalidated }) { _ = try ensureOpen(cancellation: cancellation) }
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
        let cached = cachedResults[id]
        let knownFingerprint = jobFingerprints[id] ?? cached?.response.jobFingerprint
        let cachedLog = cachedLogs[id]
        lock.unlock()
        if let knownFingerprint {
            guard knownFingerprint == fingerprint else {
                throw BpyRuntimeError.rejected("A Job ID cannot be reused with different source, inputs, revision, or options.")
            }
            if let cached {
                var response = cached.response
                response.stdout = cachedLog
                response.joinedExistingJob = true
                returned = true
                let joined = try cached.lease?.joinedForReplay()
                return .init(response: response, stagedOutputs: cached.stagedOutputs, lease: joined)
            }
            lock.lock()
            let submittedTransportID = submittedTransportIDs[id]
            lock.unlock()
            guard submittedTransportID == nil else {
                throw BpyRuntimeError.rejected(
                    "The prior result for this Job ID is no longer retained; it will not run again. Start a new job."
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
            jobOrigins[id] = (expectedRevision, expectedRevision == confirmedRevision ? confirmedSceneFile?.sha256 : nil)
            jobInputDigests[id] = Dictionary(uniqueKeysWithValues: prepared.map { ($0.input.filename, $0.sha256) })
            lock.unlock()
        }
        lock.lock()
        let needsUpload = !uploadedJobIDs.contains(id)
        lock.unlock()
        if needsUpload {
            lock.withLock { _ = stagingJobIDs.insert(id) }
            do {
                for value in prepared {
                    try upload(value, jobID: id, cancellation: cancellation)
                }
            } catch {
                let cancellation = BpyJobReference(sessionID: transportID, jobID: id)
                _ = try? call { service, reply in
                    service.cancelJob(try Self.encode(cancellation), withReply: reply)
                }
                throw error
            }
            lock.lock()
            uploadedJobIDs.insert(id)
            lock.unlock()
        }
        try requireOperation(cancellation)
        if lock.withLock({ outputReservations[id] == nil }) {
            try BpyRetentionLedger.shared.configure(slot: serviceName, limits: limits)
            let reservation = try BpyRetentionLedger.shared.reserve(slot: serviceName, owner: memoryOwner,
                kind: .retained, bytes: limits.outputBytes)
            lock.withLock { outputReservations[id] = reservation }
        }
        let admission: BpyAdmissionIdentity
        if let existing = lock.withLock({ jobAdmissions[id] }) { admission = existing }
        else {
            admission = try admit(kind: .job, job: id, timeout: Double(timeout),
                diagnosticAutoexec: diagnosticAutoexecPositiveControl, cancellation: cancellation)
            ownedAdmission = admission
            try installAdmission(admission, source: source, diagnosticDeniedPaths: diagnosticDeniedPaths)
            lock.withLock { jobAdmissions[id] = admission }
        }
        ownedAdmission = admission
        try requireOperation(cancellation)
        lock.withLock {
            submittedJobIDs.insert(id)
            submittedTransportIDs[id] = transportID
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
            diagnosticSupervisorIdentityCaptureFailure: diagnosticSupervisorIdentityCaptureFailure,
            admission: admission.id, admissionDeadline: admission.admissionDeadline
        )
        let diagnosticDirectory = Self.jobDiagnosticDirectory
        var initialServerReply: Data?
        var initialServerReplyBytes = 0
        let response = try call(observing: diagnosticDirectory == nil ? nil : { data in
            initialServerReplyBytes = data.count
            if data.count <= Self.jobDiagnosticReplyBytes { initialServerReply = data }
        }) { service, reply in
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
            diagnosticDeferExecutionAuthorization: diagnosticDeferExecutionAuthorization,
            diagnosticReceiptBarrier: diagnosticReceiptBarrier,
            cancellation: cancellation, admission: admission,
            diagnosticDirectory: diagnosticDirectory, initialServerReply: initialServerReply,
            initialServerReplyBytes: initialServerReplyBytes
        )
        pendingLease = result.lease
        try requireOperation(cancellation)
        try cache(result, for: id, cancellation: cancellation)
        if ![.awaitingConfirmation, .confirmed].contains(result.response.state) {
            if let reservation = lock.withLock({ outputReservations[id] }) { BpyRetentionLedger.shared.settle(reservation) }
        }
        returned = true
        return result
    }

    private func finish(
        jobID: UUID, fingerprint: String, response initialResponse: BpyServiceResponse,
        timeoutSeconds: Int, diagnosticDeferExecutionAuthorization: Bool,
        diagnosticReceiptBarrier: (@Sendable (BpyAdmissionIdentity) throws -> Void)?,
        cancellation: BpyOperationCancellation, admission: BpyAdmissionIdentity,
        diagnosticDirectory: URL? = nil, initialServerReply: Data? = nil, initialServerReplyBytes: Int = 0
    ) throws -> BpyRuntimeJobResult {
        let memory = memoryCoordinator
        var diagnosticResponse: BpyServiceResponse?
        var diagnosticReceipt: BpyMemoryCoordinator.PermitReceipt?
        var diagnosticError: Error?
        var lastServerReply = initialServerReply
        var lastServerMethod = "runJob"
        var lastServerReplyBytes = initialServerReplyBytes
        var files: [String: BpyRuntimeFile] = [:]
        var returned = false
        defer {
            if let diagnosticDirectory {
                Self.recordJobDiagnostic(directory: diagnosticDirectory, jobID: jobID,
                    response: diagnosticResponse, initial: initialResponse,
                    serverReply: lastServerReply, serverMethod: lastServerMethod,
                    serverReplyBytes: lastServerReplyBytes,
                    permit: diagnosticReceipt ?? (try? memory.receipt(admission.id)),
                    error: diagnosticError, returned: returned, stagedOutputNames: files.keys.sorted())
            }
        }
        do {
            let response = try waitForTerminal(jobID: jobID, fingerprint: fingerprint,
                response: initialResponse, admission: admission, cancellation: cancellation,
                diagnosticDeferExecutionAuthorization: diagnosticDeferExecutionAuthorization,
                diagnosticReceiptBarrier: diagnosticReceiptBarrier,
                observing: diagnosticDirectory == nil ? nil : { method, _, data in
                    lastServerMethod = method
                    lastServerReplyBytes = data.count
                    lastServerReply = data.count <= Self.jobDiagnosticReplyBytes ? data : nil
                })
            diagnosticResponse = response
            guard !response.resultExpired else {
                throw BpyRuntimeError.rejected("The retained result for this Job ID has expired; it will not run again.")
            }
            memory.finish(admission.id)
            let receipt = try memory.receipt(admission.id)
            diagnosticReceipt = receipt
            lock.withLock { jobAdmissions.removeValue(forKey: jobID) }
            memory.forget(admission.id)
            let succeeded = [.awaitingConfirmation, .confirmed].contains(response.state)
            if succeeded {
                if let failure = receipt.failure { throw failure }
                if let stop = receipt.stop { throw BpyExecutionInterruption(reason: stop) }
                guard receipt.cleanupComplete else {
                    throw BpyRuntimeError.invalidOutput("The 3D result has no completed process cleanup receipt.")
                }
            }
            if response.runtime != nil {
                lock.withLock { var ready = response; ready.stdout = nil; lastReadyResponse = ready }
            }
            defer { if !returned { for file in files.values { file.release() } } }
            if succeeded {
                let work = try consumerWork(cancellation: cancellation)
                defer { work.release() }
                files = try downloadOutputs(response.outputs, jobID: jobID, cancellation: cancellation,
                    timeout: admission.timeout, work: work)
                try work.check()
            }
            let origin = lock.withLock { jobOrigins[jobID] }
            let leaseID = UUID()
            let lease = BpyRuntimeResultLease(id: leaseID, transport: admission.transport, job: jobID, slot: serviceName,
                owner: memoryOwner, limits: limits, sourceRevision: origin?.revision,
                sourceSHA256: origin?.sha256, fingerprint: fingerprint,
                response: response, files: files) { [weak self] detached in
                    self?.releasedResult(jobID: jobID, leaseID: leaseID, wasDetached: detached)
                }
            try lease.recordExecution(receipt)
            if response.state == .awaitingConfirmation, let scene = files["scene.blend"] {
                lock.withLock {
                    candidateJobIDs.insert(jobID)
                    validatedCandidates[jobID] = (scene.sha256, scene.url)
                }
            }
            returned = true
            return .init(response: response, stagedOutputs: lease.urls, lease: lease)
        } catch {
            diagnosticError = error
            throw error
        }
    }

    private func waitForTerminal(jobID: UUID, fingerprint: String, response initial: BpyServiceResponse,
                                 admission: BpyAdmissionIdentity, cancellation: BpyOperationCancellation,
                                 diagnosticDeferExecutionAuthorization: Bool = false, authorizeInitial: Bool = true,
                                 diagnosticReceiptBarrier: (@Sendable (BpyAdmissionIdentity) throws -> Void)? = nil,
                                 observing: ((String, Data, Data) -> Void)? = nil) throws -> BpyServiceResponse {
        var response = initial
        var polling = BpyTerminalPollState()
        var canAuthorize = authorizeInitial
        var receiptBarrier = diagnosticReceiptBarrier
        let memory = memoryCoordinator
        func deadline(_ receipt: BpyMemoryCoordinator.PermitReceipt) -> TimeInterval {
            receipt.cleanupStarted.map { $0 + 5 }
                ?? receipt.firstRelease.map { $0 + admission.timeout + 15 } ?? admission.admissionDeadline
        }
        while response.state == .accepted || response.state == .running {
            try requireOperation(cancellation)
            if canAuthorize, !diagnosticDeferExecutionAuthorization {
                response = try authorizeProcessIfNeeded(response, jobID: jobID, observing: { request, response in
                    observing?("authorizeProcess", request, response)
                })
                if ![.accepted, .running].contains(response.state) { break }
            }
            if let barrier = receiptBarrier, response.activeWorkerProcessIdentifier != nil,
               response.activeProcessAuthorizationID == nil {
                receiptBarrier = nil
                try barrier(admission)
            }
            let before = try memory.receipt(admission.id)
            let now = try BpyRuntimeClock.awakeSeconds()
            if now < deadline(before) { Thread.sleep(forTimeInterval: 0.05) }
            let started = try BpyRuntimeClock.awakeSeconds()
            let starting = try memory.receipt(admission.id)
            try polling.begin(at: started, deadline: deadline(starting))
            response = try status(jobID: jobID, observing: { request, response in
                observing?("jobStatus", request, response)
            })
            try requireOperation(cancellation)
            let ended = try BpyRuntimeClock.awakeSeconds()
            let after = try memory.receipt(admission.id)
            canAuthorize = true
            try polling.end(at: ended, deadline: deadline(after), terminal: ![.accepted, .running].contains(response.state))
            guard response.ok, response.jobID == jobID, response.jobFingerprint == fingerprint else {
                throw BpyRuntimeError.rejected(response.message ?? "The 3D job disappeared.")
            }
        }
        let receipt = try memory.receipt(admission.id)
        if let failure = receipt.failure { throw failure }
        if receipt.firstRelease == nil, let stop = receipt.stop {
            switch stop {
            case .pressure: throw BpyAdmissionFailure.pressure
            case .monitorUnavailable: throw BpyAdmissionFailure.sensorUnavailable
            case .monitorUnresponsive: throw BpyAdmissionFailure.sensorUnresponsive
            case .launchFailed: throw BpyAdmissionFailure.launchFailed
            case .transportLost: throw BpyAdmissionFailure.transportLost
            case .deadline: throw BpyAdmissionFailure.timedOut
            case .closed: throw BpyAdmissionFailure.closed
            case .cancelled: throw BpyAdmissionFailure.cancelled
            case .cleanupFailed: throw BpyAdmissionFailure.cleanupFailed
            default: break
            }
        }
        if [.awaitingConfirmation, .confirmed].contains(response.state) {
            guard receipt.stop == nil, let first = receipt.firstRelease, let commit = receipt.terminalCommit,
                  response.firstRelease == first, response.runningDeadline == first + admission.timeout,
                  response.terminalCommit == commit, BpyTerminalPollState.timelyCommit(first: first, timeout: admission.timeout, commit: commit) else {
                throw BpyRuntimeError.invalidOutput("The 3D result has no timely host completion receipt.")
            }
        } else if let reason = receipt.stop {
            response.outputs = []
            switch reason {
            case .deadline:
                response.state = .timedOut; response.message = "The 3D job exceeded its execution deadline."
            case .pressure:
                response.state = .resourceLimited; response.message = "macOS reported critical memory pressure. Retry the 3D job when memory is available."
            case .disk:
                response.state = .resourceLimited; response.message = "The 3D job exceeded its temporary storage limit. Reduce its output before retrying."
            case .fileCount:
                response.state = .resourceLimited; response.message = "The 3D job created too many temporary files. Reduce its output before retrying."
            case .processCount:
                response.state = .resourceLimited; response.message = "The 3D job started an unauthorized process. Remove the process launch before retrying."
            case .closed, .cancelled:
                response.state = .cancelled; response.message = "The 3D job was cancelled."
            case .executionFailed:
                if ![.crashed, .failed, .rejected].contains(response.state) {
                    response.state = .failed; response.message = "The 3D job failed. Check its diagnostics before retrying."
                }
            case .launchFailed, .ownershipViolation, .orphanedWorker, .observationFailed, .transportLost, .monitorUnavailable, .monitorUnresponsive, .serviceStall:
                response.state = .failed; response.message = BpyExecutionInterruption(reason: reason).localizedDescription
            default:
                response.state = .failed; response.message = "The 3D runtime could not be monitored safely. Retry after cleanup finishes."
            }
        }
        response.joinedExistingJob = initial.joinedExistingJob
        return response
    }

    func status(jobID: UUID, observing: ((Data, Data) -> Void)? = nil) throws -> BpyServiceResponse {
        let request = try Self.encode(BpyJobReference(sessionID: currentSessionID(), jobID: jobID))
        let response = try call(observing: { observing?(request, $0) }) { service, reply in
            service.jobStatus(request, withReply: reply)
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
        lock.lock()
        let candidate = validatedCandidates[jobID]
        lock.unlock()
        guard let candidate else {
            throw BpyRuntimeError.invalidOutput("Validate the staged 3D candidate before confirmation.")
        }
        guard let lease = try lock.withLock({ try cachedResults[jobID]?.lease?.joinedForReplay() }) else { throw SpatialSceneError.changed }
        defer { lease.release() }
        let file = try lease.file("scene.blend")
        defer { file.release() }
        guard file.sha256 == candidate.sha256, file.byteCount <= limits.inputBytes,
              BpyBlendFileFormat.accepts(try file.read(maximum: 64)) else {
            throw BpyRuntimeError.invalidOutput("The staged 3D candidate changed before confirmation.")
        }
        let replacementCheckpoint = try file.retained()
        var installedCheckpoint = false
        defer { if !installedCheckpoint { replacementCheckpoint.release() } }
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
        let previousCheckpoint = confirmedSceneFile
        confirmedRevision = revision
        confirmedSceneFile = replacementCheckpoint
        installedCheckpoint = true
        validatedCandidates.removeValue(forKey: jobID)
        candidateJobIDs.remove(jobID)
        lastReadyResponse?.confirmedRevision = revision
        if let cached = cachedResults[jobID] {
            var confirmedResponse = cached.response
            confirmedResponse.state = .confirmed
            confirmedResponse.confirmedRevision = revision
            cachedResults[jobID] = .init(
                response: confirmedResponse,
                stagedOutputs: cached.stagedOutputs, lease: cached.lease
            )
        }
        lock.unlock()
        previousCheckpoint?.release()
        return response
    }

    func authenticateSpatialReceipt(_ revision: SpatialSceneRevision, cancellation: BpyOperationCancellation) throws {
        let work = try consumerWork(cancellation: cancellation)
        defer { work.release() }
        let receipt = revision.manifest.receipt
        guard try SpatialSceneStore.encode(revision.manifest) == revision.manifestData,
              try SpatialSceneStore.encode(revision.snapshot) == revision.snapshotData,
              try revision.scenePayload.verify(checking: { try cancellation.check(); try work.check() }) == revision.manifest.sceneSHA256,
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
        guard let lease = try result.lease?.joinedForReplay() else { throw SpatialSceneError.changed }
        defer { lease.release() }
        func output(_ name: String) throws -> Data {
            guard let descriptor = result.response.outputs.first(where: { $0.name == name }) else {
                throw BpyRuntimeError.invalidOutput("The location's verified runtime output is missing.")
            }
            let data = try lease.data(name, maximum: limits.outputBytes, checking: { try work.check() })
            guard descriptor.byteCount == data.count, descriptor.sha256 == Self.sha256(data) else {
                throw BpyRuntimeError.invalidOutput("The location's verified runtime output changed.")
            }
            return data
        }
        let scene = try lease.file("scene.blend")
        defer { scene.release() }
        try scene.verify(checking: { try work.check() })
        let verification = try JSONDecoder().decode(Verification.self, from: output("verification.json"))
        let runtime = try bundledRuntimeRoot
        guard verification.schema == "nexgenvideo/bpy-verification/1",
              verification.jobID == receipt.jobID, verification.fingerprint == receipt.jobFingerprint,
              verification.blenderBuildHash == receipt.blenderBuildHash, let snapshot = verification.spatial,
              scene.sha256 == receipt.sceneSHA256,
              Self.sha256(try SpatialSceneStore.encode(snapshot)) == receipt.snapshotSHA256,
              try work.digest(at: runtime.appendingPathComponent("runtime-lock.json")) == receipt.runtimeLockSHA256,
              try work.digest(at: runtime.appendingPathComponent("worker.py")) == receipt.workerSHA256 else {
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
                                       result: BpyRuntimeJobResult,
                                       cancellation: BpyOperationCancellation) throws -> (bounds: Data, verification: Data, fingerprint: String) {
        let work = try consumerWork(cancellation: cancellation)
        defer { work.release() }
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
              cached.stagedOutputs == result.stagedOutputs, let lease = result.lease,
              lease.id == cached.lease?.id, lease.isAvailable else { throw BpyRuntimeError.invalidOutput("The evaluated bounds have no current native runtime execution.") }
        func output(_ name: String) throws -> Data {
            guard let descriptor = cached.response.outputs.first(where: { $0.name == name }) else { throw SpatialSceneError.changed }
            let data = try lease.data(name, maximum: limits.outputBytes, checking: { try work.check() })
            guard data.count == descriptor.byteCount, Self.sha256(data) == descriptor.sha256 else { throw SpatialSceneError.changed }
            return data
        }
        let verification = try output("verification.json")
        let value = try JSONDecoder().decode(Verification.self, from: verification)
        guard value.jobID == jobID, value.fingerprint == expected, !value.blenderBuildHash.isEmpty else { throw SpatialSceneError.changed }
        let bounds = try output("evaluated-bounds.v1.json")
        try work.check(); try requireOperation(cancellation)
        return (bounds, verification, expected)
    }

    func transferResult(_ result: BpyRuntimeJobResult, source: SpatialSceneRevision,
                        cancellation: BpyOperationCancellation) throws {
        guard let lease = result.lease, lease.isAvailable,
              lease.sourceRevision == source.manifest.revision.uuidString,
              lease.sourceSHA256 == source.manifest.sceneSHA256 else { throw SpatialSceneError.changed }
        try requireOperation(cancellation)
        if lease.isDetached { return }
        let live = lock.withLock { !closed && !closing && !transportInvalidated && sessionID == lease.transport
            && cachedResults[lease.job]?.lease?.id == lease.id }
        guard live else { throw SpatialSceneError.changed }
        let request = BpyReleaseResourcesRequest(sessionID: lease.transport, jobID: lease.job,
            disposition: .transferredResult, fingerprint: lease.fingerprint, outputs: lease.response.outputs)
        guard let deadline = lock.withLock({ transferDeadlines[lease.job] }) else { throw SpatialSceneError.changed }
        let work = try consumerWork(cancellation: cancellation)
        defer { work.release() }
        while true {
            try requireOperation(cancellation)
            try work.check()
            let now = try BpyRuntimeClock.awakeSeconds()
            guard now < deadline else { throw BpyRuntimeError.timedOut }
            let response = try call(timeout: min(30, deadline - now)) { service, reply in
                service.releaseResources(try Self.encode(request), withReply: reply)
            }
            try requireOperation(cancellation)
            try work.check()
            guard try BpyRuntimeClock.awakeSeconds() <= deadline else { throw BpyRuntimeError.timedOut }
            if response.ok { break }
            guard response.message == "result release pending" else { throw SpatialSceneError.changed }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if let reservation = lock.withLock({ transfers[lease.job]?.reservation }) {
            acknowledgeTransfer(jobID: lease.job, reservation: reservation)
        }
        try lease.transferExecution()
        lock.withLock { validatedCandidates.removeValue(forKey: lease.job); candidateJobIDs.remove(lease.job) }
        _ = try cancel(jobID: lease.job)
    }

    func retainSpatialDerivation(_ candidate: SpatialClayCandidate, source: SpatialSceneRevision,
                                 cancellation: BpyOperationCancellation) throws {
        try verifySpatialDerivation(candidate, source: source, cancellation: cancellation)
        try candidate.lease.detach(proof: candidate.proofData)
        try lock.withLock {
            guard !closed, !closing else { throw SpatialSceneError.changed }
            spatialDerivations[candidate.proof.jobID] = Self.sha256(candidate.proofData)
        }
    }

    func authenticateSpatialDerivation(_ candidate: SpatialClayCandidate, source: SpatialSceneRevision,
                                       cancellation: BpyOperationCancellation) throws {
        lock.lock()
        let issued = spatialDerivations[candidate.proof.jobID]
        lock.unlock()
        guard issued == Self.sha256(candidate.proofData) else {
            throw BpyRuntimeError.invalidOutput("The Clay output has no host-issued derivation receipt.")
        }
        try candidate.lease.authenticate(proof: candidate.proofData)
        try verifySpatialDerivation(candidate, source: source, cancellation: cancellation)
    }

    func beginSpatialSequence(binding: Data) throws -> UUID {
        try requireSequenceSession()
        return try spatialSequences.begin(binding: binding)
    }

    func appendSpatialSequence(_ identifier: UUID, candidate: SpatialClayCandidate,
                               source: SpatialSceneRevision, cancellation: BpyOperationCancellation) throws {
        try authenticateSpatialDerivation(candidate, source: source, cancellation: cancellation)
        try spatialSequences.append(identifier, proof: candidate.proofData)
    }

    func retainSpatialSequence(_ candidate: SpatialClaySequenceCandidate,
                               source: SpatialSceneRevision, cancellation: BpyOperationCancellation) async throws {
        let borrowed = try candidate.borrowFiles()
        defer { for file in borrowed { file.release() } }
        try requireSequenceSession()
        let scope = try mediaReadScope(cancellation: cancellation).checking {
            guard candidate.isAvailable else { throw SpatialSceneError.changed }
        }
        try SpatialClayRenderer.validateSequence(proofData: candidate.proofData, files: candidate.files, against: source, scope: scope)
        try await SpatialClayRenderer.verifySequenceMovie(candidate, cancellation: cancellation, isCancelled: { !candidate.isAvailable })
        try SpatialClayRenderer.validateSequence(proofData: candidate.proofData, files: candidate.files, against: source, scope: scope)
        try requireSequenceSession()
        try spatialSequences.seal(candidate)
    }

    func authenticateSpatialSequence(_ candidate: SpatialClaySequenceCandidate, source: SpatialSceneRevision,
                                    cancellation: BpyOperationCancellation) throws {
        let borrowed = try candidate.borrowFiles()
        defer { for file in borrowed { file.release() } }
        try requireSequenceSession()
        try spatialSequences.authenticate(candidate)
        let scope = try mediaReadScope(cancellation: cancellation).checking {
            guard candidate.isAvailable else { throw SpatialSceneError.changed }
        }
        try SpatialClayRenderer.validateSequence(proofData: candidate.proofData, files: candidate.files, against: source, scope: scope)
        try requireSequenceSession()
        try spatialSequences.authenticate(candidate)
    }

    func releaseSpatialSequence(_ identifier: UUID) { spatialSequences.release(identifier) }

    private func requireSequenceSession() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !closing else {
            throw BpyRuntimeError.unavailable("The 3D sequence session is closed.")
        }
    }

    private func verifySpatialDerivation(_ candidate: SpatialClayCandidate, source: SpatialSceneRevision,
                                        cancellation: BpyOperationCancellation) throws {
        let work = try consumerWork(cancellation: cancellation)
        defer { work.release() }
        struct Verification: Decodable {
            let jobID: UUID
            let fingerprint: String
            let blenderBuildHash: String
            let spatial: BpySpatialSnapshot?
        }
        try SpatialClayRenderer.validate(candidate, against: source, cancellation: cancellation)
        let proof = candidate.proof
        let lease = candidate.lease
        let unavailable = lock.withLock { closed || closing }
        guard !unavailable, lease.isAvailable, lease.isDetached,
              lease.job == proof.jobID, lease.fingerprint == proof.jobFingerprint,
              lease.sourceRevision == source.manifest.revision.uuidString,
              lease.sourceSHA256 == source.manifest.sceneSHA256 else {
            throw BpyRuntimeError.invalidOutput("The Clay output has no authenticated runtime execution.")
        }
        let root = try bundledRuntimeRoot
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
              try work.digest(at: root.appendingPathComponent("site-packages/bpy/__init__.so")) == proof.rendererBinarySHA256 else {
            throw BpyRuntimeError.invalidOutput("The Clay receipt differs from its actual render command or runtime.")
        }
        func output(_ name: String) throws -> Data {
            guard let descriptor = lease.response.outputs.first(where: { $0.name == name }) else { throw SpatialSceneError.changed }
            let data = try lease.data(name, maximum: limits.outputBytes, checking: { try cancellation.check(); try work.check() })
            guard data.count == descriptor.byteCount, Self.sha256(data) == descriptor.sha256 else { throw SpatialSceneError.changed }
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
            guard let file = candidate.files[descriptor.filename],
                  let original = lease.response.outputs.first(where: { $0.name == descriptor.filename }),
                  file.sha256 == descriptor.sha256, file.byteCount == descriptor.byteCount,
                  original.sha256 == file.sha256, original.byteCount == file.byteCount else { throw SpatialSceneError.changed }
            try file.verify(checking: { try cancellation.check(); try work.check() })
        }
    }

    func cancel(jobID: UUID) throws -> BpyServiceResponse {
        let local = lock.withLock { (jobAdmissions[jobID], operationTokens[jobID], submittedJobIDs.contains(jobID)) }
        local.1?.cancel()
        if let admission = local.0 { memoryCoordinator.cancel(admission.id) }
        if !local.2 { return .init(ok: true, jobID: jobID, state: .cancelled) }
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
        let result = cachedResults[jobID]?.lease
        lock.unlock()
        if result?.isDetached != true { result?.invalidate() }
        return response
    }

    func rotateFromConfirmedState() throws -> BpyServiceResponse {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        _ = try ensureOpen()
        lock.lock()
        guard confirmedRevision != nil, confirmedSceneFile != nil else {
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
        let staged = cachedResults.compactMap { $0.value.lease?.isDetached == true ? nil : $0.key }
        lock.unlock()
        removeStagedResults(staged)
        try rotateTransport()
        let response = try ensureOpen()
        lock.lock()
        jobFingerprints.removeAll()
        jobOrigins.removeAll()
        jobInputDigests.removeAll()
        submittedJobIDs.removeAll()
        submittedTransportIDs.removeAll()
        activeProcessLease = nil
        lock.unlock()
        removeStagedResults(staged)
        return response
    }

    func loadProjectCheckpoint(scene: Data?, revision: String?, sha256: String?,
                               cancellation: BpyOperationCancellation = .init()) throws {
        try loadProjectCheckpoint(payload: scene.map(SpatialScenePayload.init(data:)), revision: revision,
            sha256: sha256, cancellation: cancellation)
    }

    func loadProjectCheckpoint(sceneRevision: SpatialSceneRevision?, cancellation: BpyOperationCancellation) throws {
        try loadProjectCheckpoint(payload: sceneRevision?.scenePayload,
            revision: sceneRevision?.manifest.revision.uuidString, sha256: sceneRevision?.manifest.sceneSHA256,
            cancellation: cancellation)
    }

    private func loadProjectCheckpoint(payload: SpatialScenePayload?, revision: String?, sha256: String?,
                                       cancellation: BpyOperationCancellation) throws {
        submissionLock.lock()
        defer { submissionLock.unlock() }
        try requireOperation(cancellation)
        let operationID = UUID()
        lock.withLock { operationTokens[operationID] = cancellation }
        defer { _ = lock.withLock { operationTokens.removeValue(forKey: operationID) } }
        if let payload, let revision, let sha256 {
            guard !revision.isEmpty, payload.byteCount <= limits.inputBytes else {
                throw BpyRuntimeError.invalidInput("The saved location checkpoint changed.")
            }
            let work = try consumerWork(cancellation: cancellation)
            defer { work.release() }
            func checking() throws { try requireOperation(cancellation); try work.check() }
            let context = BpyRuntimeHashObservation.Context(id: cancellation.id, callerOwned: true,
                purpose: "checkpoint", isCancelled: { cancellation.isCancelled })
            try BpyRuntimeHashObservation.$context.withValue(context) {
                let verified = try payload.verifiedHeader(checking: checking)
                guard verified.sha256 == sha256, BpyBlendFileFormat.accepts(verified.header) else {
                    throw BpyRuntimeError.invalidInput("The saved location checkpoint changed.")
                }
            }
        } else if payload != nil || revision != nil || sha256 != nil {
            throw BpyRuntimeError.invalidInput("The saved location checkpoint is incomplete.")
        }
        lock.lock()
        guard !closed, !closing, candidateJobIDs.isEmpty else {
            lock.unlock()
            throw BpyRuntimeError.rejected("Finish the current location edit before opening another location.")
        }
        lock.unlock()
        _ = try BpyHostStaging.shared.directory(stagingRoot.lastPathComponent)
        let checkpoint = try payload.map { try makeCheckpoint($0, cancellation: cancellation) }
        lock.lock()
        guard !closed, !closing, !cancellation.isCancelled else {
            lock.unlock(); checkpoint?.release()
            try requireOperation(cancellation)
            throw BpyAdmissionFailure.closed
        }
        let staged = cachedResults.compactMap { $0.value.lease?.isDetached == true ? nil : $0.key }
        let previousCheckpoint = confirmedSceneFile
        confirmedSceneFile = checkpoint
        confirmedRevision = revision
        jobFingerprints.removeAll()
        jobOrigins.removeAll()
        jobInputDigests.removeAll()
        submittedJobIDs.removeAll()
        submittedTransportIDs.removeAll()
        lock.unlock()
        previousCheckpoint?.release()
        removeStagedResults(staged)
        try rotateTransport()
        _ = try ensureOpen(cancellation: cancellation)
        removeStagedResults(staged)
    }

    fileprivate func beginClose() {
        lock.lock()
        if !cleanupComplete { closing = true }
        let tokens = Array(operationTokens.values)
        let results = cachedResults.values.compactMap(\.lease)
        let checkpoint = confirmedSceneFile
        confirmedSceneFile = nil
        if hostDisposalDeadline == nil { hostDisposalDeadline = BpyRuntimeClock.read().map { $0.awake + 5 } }
        lock.unlock()
        memoryCoordinator.close(owner: memoryOwner)
        for result in results { result.invalidate() }
        checkpoint?.release()
        for token in tokens { token.cancel() }
        spatialSequences.close()
    }

    @discardableResult
    func close() -> Bool {
        beginClose()
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
        markTransportInvalid(identifier, disposition: .close)
        lock.lock()
        let volumes = [(BpyStorageRole.worker, storageVolume), (BpyStorageRole.data, storageDataVolume)]
        let preparation = claimedStoragePreparation
        closed = true
        connection = nil
        lock.unlock()
        openLock.unlock()
        var failures: [String] = []
        var serviceReleased = true
        var restartRequired = false
        let serviceProof = try? queryStorageOwnership()
        let recovery = lock.withLock { transportRecovery }
        let workerStopped = recovery?.wait() ?? lock.withLock {
            activeProcessLease == nil && submittedJobIDs.isEmpty
        }
        for (role, volume) in volumes {
            do {
                if let volume {
                    serviceReleased = volume.serviceReleasedForRecovery(serviceProof, workerStopped: workerStopped) && serviceReleased
                    try volume.release(serviceStopped: false, serviceProof: serviceProof)
                } else if let preparation {
                    let released = serviceProof?.inUseStorageIDs.contains(preparation.id) == false
                        && ((serviceProof?.servicePID == preparation.servicePID && serviceProof?.serviceStart == preparation.serviceStart)
                            || (workerStopped && processStartAbsoluteTime(preparation.servicePID) != preparation.serviceStart))
                    serviceReleased = released && serviceReleased
                    try BpyRuntimeVolume.releasePrepared(preparation, serviceName: serviceName,
                        serviceStopped: false, serviceProof: serviceProof, role: role)
                }
            } catch {
                failures.append(error.localizedDescription)
                restartRequired = restartRequired || (error as? BpyStorageRecoveryError) == .restartRequired
            }
        }
        if failures.isEmpty {
            let retired = lock.withLock { transfers.map { ($0.key, $0.value.reservation) } }
            for (job, reservation) in retired { acknowledgeTransfer(jobID: job, reservation: reservation) }
        }
        if failures.isEmpty, !BpyRetentionLedger.shared.waitForDisposal(owner: memoryOwner,
            deadline: lock.withLock({ hostDisposalDeadline })) {
            failures.append("Retained 3D files are still being released.")
        }
        if failures.isEmpty {
            do { try BpyHostStaging.shared.removeEmpty(stagingRoot.lastPathComponent) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { failures.append(error.localizedDescription) }
        }
        let failure = failures.isEmpty ? nil : failures.joined(separator: " ")
        lock.lock()
        cleanupComplete = failure == nil
        cleanupMessage = failure
        cleanupRequiresRestart = restartRequired
        storageServiceReleased = serviceReleased
        if cleanupComplete { storageVolume = nil; storageDataVolume = nil }
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

    private func requireOperation(_ cancellation: BpyOperationCancellation) throws {
        guard lock.withLock({ !closed && !closing }) else { throw BpyAdmissionFailure.closed }
        try cancellation.check()
    }

    private func requireExecutionActive(_ admission: UUID, cancellation: BpyOperationCancellation) throws {
        try requireOperation(cancellation)
        let receipt = try memoryCoordinator.receipt(admission)
        if let failure = receipt.failure { throw failure }
        if let stop = receipt.stop {
            switch stop {
            case .closed: throw BpyAdmissionFailure.closed
            case .cancelled: throw BpyAdmissionFailure.cancelled
            case .deadline:
                if receipt.firstRelease == nil { throw BpyAdmissionFailure.timedOut }
                throw BpyRuntimeError.timedOut
            case .cleanupFailed: throw BpyAdmissionFailure.cleanupFailed
            case .pressure where receipt.firstRelease == nil: throw BpyAdmissionFailure.pressure
            case .monitorUnavailable, .monitorUnresponsive:
                if receipt.firstRelease == nil {
                    throw stop == .monitorUnavailable ? BpyAdmissionFailure.sensorUnavailable : BpyAdmissionFailure.sensorUnresponsive
                }
                throw BpyExecutionInterruption(reason: stop)
            default: throw BpyExecutionInterruption(reason: stop)
            }
        }
    }

    private func admit(kind: BpyAdmissionIdentity.Kind, job: UUID?, timeout: TimeInterval,
                       admissionDeadline: TimeInterval? = nil, diagnosticAutoexec: Bool = false,
                       cancellation: BpyOperationCancellation) throws -> BpyAdmissionIdentity {
        try requireOperation(cancellation)
        let memory = memoryCoordinator
        try memory.register(owner: memoryOwner, generation: memoryGeneration)
        return try memory.admit(owner: memoryOwner, generation: memoryGeneration,
            transport: currentSessionID(), job: job, kind: kind, timeout: timeout,
            admissionDeadline: admissionDeadline, diagnosticAutoexec: diagnosticAutoexec, cancellation: cancellation)
    }

    private func installAdmission(_ identity: BpyAdmissionIdentity, source: String? = nil,
                                  diagnosticDeniedPaths: [String] = [], fingerprint: String? = nil) throws {
        let context = lock.withLock { (hostMonitor, storageVolume, storageDataVolume, sessionID, closed || closing || transportInvalidated) }
        guard !context.4, identity.transport == context.3, let monitor = context.0,
              let worker = context.1, let data = context.2, let pairID = worker.lease.pairID else {
            throw BpyAdmissionFailure.closed
        }
        let pair = BpyStoragePair(id: pairID, worker: worker.lease, data: data.lease)
        try monitor.install(.init(slot: serviceName, identity: identity, pair: pair, limits: limits,
            workerVolume: worker, dataVolume: data, sourceSHA256: source.map { Self.sha256(Data($0.utf8)) },
            fingerprint: fingerprint ?? lock.withLock { identity.job.flatMap { jobFingerprints[$0] } }, diagnosticDeniedPaths: diagnosticDeniedPaths))
    }

    private func abandon(jobID: UUID) {
        requestCancellation(jobID: jobID)
        _ = lock.withLock { jobAdmissions.removeValue(forKey: jobID) }
    }

    private func requestCancellation(jobID: UUID) {
        let context = lock.withLock { (jobAdmissions[jobID], submittedJobIDs.contains(jobID), stagingJobIDs.contains(jobID), sessionID) }
        if let identity = context.0 {
            memoryCoordinator.cancel(identity.id)
        }
        guard context.1 || context.2 else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, self.currentSessionID() == context.3 else { return }
            if context.1 {
                let request = BpyJobReference(sessionID: context.3, jobID: jobID)
                _ = try? self.call(timeout: 2, allowClosing: true) { service, reply in
                    service.cancelJob(try Self.encode(request), withReply: reply)
                }
            } else {
                let request = BpyReleaseResourcesRequest(sessionID: context.3, jobID: jobID,
                    disposition: .stagedInputs, fingerprint: nil, outputs: [])
                _ = try? self.call(timeout: 2, allowClosing: true) { service, reply in
                    service.releaseResources(try Self.encode(request), withReply: reply)
                }
            }
        }
    }

    private func ensureOpen(restoreProbe: BpyNativeRestoreProbe? = nil,
                            cancellation: BpyOperationCancellation = .init()) throws -> BpyServiceResponse {
        try requireOperation(cancellation)
        _ = try BpyHostStaging.shared.directory(stagingRoot.lastPathComponent)
        openLock.lock()
        do {
            try requireOperation(cancellation)
            let response = try ensureOpenLocked(restoreProbe: restoreProbe, cancellation: cancellation, budget: OpenBudget())
            openLock.unlock()
            return response
        } catch {
            openLock.unlock()
            if error is BpyAdmissionFailure || error is BpyLaunchDeferral || error is BpyExecutionInterruption { throw error }
            close()
            throw error
        }
    }

    private func ensureOpenLocked(restoreProbe: BpyNativeRestoreProbe?, cancellation: BpyOperationCancellation,
                                  budget: OpenBudget) throws -> BpyServiceResponse {
        lock.lock()
        if closed || closing {
            lock.unlock()
            throw BpyAdmissionFailure.closed
        }
        if opened, !transportInvalidated {
            let response = lastReadyResponse
            lock.unlock()
            return response ?? .init(ok: true, confirmedRevision: confirmedRevision)
        }
        let shouldRotate = transportInvalidated
        lock.unlock()
        if shouldRotate { try rotateTransport() }
        let firstSession = currentSessionID()
        do {
            return try openCurrentTransport(restoreProbe: restoreProbe, cancellation: cancellation, budget: budget)
        } catch {
            if error is BpyAdmissionFailure || error is BpyLaunchDeferral || error is BpyExecutionInterruption { throw error }
            if let runtimeError = error as? BpyRuntimeError, case .timedOut = runtimeError { throw error }
            lock.lock()
            let unfinishedStorage = (storagePreparation != nil && storageVolume == nil)
                || ((storageVolume == nil) != (storageDataVolume == nil))
            lock.unlock()
            let firstError = error as NSError
            bpyOpenDiagnostics.notice("open.first.fail session=\(firstSession.uuidString) unfinishedStorage=\(unfinishedStorage) domain=\(firstError.domain) code=\(firstError.code)")
            guard !unfinishedStorage, lock.withLock({ transportInvalidated }) else { throw error }
            try rotateTransport()
            let retrySession = currentSessionID()
            do {
                return try openCurrentTransport(restoreProbe: restoreProbe, cancellation: cancellation, budget: budget)
            } catch {
                let retryError = error as NSError
                bpyOpenDiagnostics.notice("open.retry.fail session=\(retrySession.uuidString) firstSession=\(firstSession.uuidString) domain=\(retryError.domain) code=\(retryError.code)")
                throw error
            }
        }
    }

    private func openCurrentTransport(restoreProbe: BpyNativeRestoreProbe?,
                                      cancellation: BpyOperationCancellation, budget: OpenBudget) throws -> BpyServiceResponse {
        try requireOperation(cancellation)
        let context = try lock.withLock { (sessionID, confirmedRevision, try confirmedSceneFile?.retained(), storageVolume, storageDataVolume) }
        let identifier = context.0, revision = context.1, checkpoint = context.2
        defer { checkpoint?.release() }
        var worker = context.3, data = context.4
        if worker == nil && data == nil {
            let request = BpyOpenSessionRequest(sessionID: identifier, documentID: documentID,
                confirmedRevision: revision, limits: limits, diagnosticOpenFailure: diagnosticOpenFailure)
            let response = try call(timeout: 180) { service, reply in
                service.openSession(try Self.encode(request), withReply: reply)
            }
            let transport = try currentConnection()
            guard response.ok, let preparation = response.storagePreparation,
                  transport.1 == identifier, preparation.id == identifier,
                  preparation.servicePID == transport.0.processIdentifier,
                  processStartAbsoluteTime(preparation.servicePID) == preparation.serviceStart,
                  let dataBytes = limits.dataStorageBytes else {
                throw BpyRuntimeError.invalidOutput("The 3D service changed its storage preparation.")
            }
            bpyOpenDiagnostics.notice("open.preparation session=\(identifier.uuidString) servicePID=\(preparation.servicePID) serviceStart=\(preparation.serviceStart)")
            lock.withLock { storagePreparation = preparation }
            let createdWorker = try BpyRuntimeVolume.create(preparation: preparation, serviceName: serviceName,
                maximumBytes: limits.physicalStorageBytes, role: .worker) { [self] in
                lock.withLock { claimedStoragePreparation = preparation }
            }
            lock.withLock { storageVolume = createdWorker }
            try requireOperation(cancellation)
            let createdData = try BpyRuntimeVolume.create(preparation: preparation, serviceName: serviceName,
                maximumBytes: dataBytes, role: .data)
            lock.withLock { storageDataVolume = createdData }
            worker = createdWorker; data = createdData
        }
        guard let worker, let data, let pairID = worker.lease.pairID else {
            throw BpyRuntimeError.unavailable("The 3D storage pair is incomplete. Retry cleanup before opening the scene.")
        }
        let pair = BpyStoragePair(id: pairID, worker: worker.lease, data: data.lease)
        guard pair.isValid(limits: limits), currentSessionID() == identifier else {
            throw BpyRuntimeError.invalidOutput("The 3D storage pair changed.")
        }
        try BpyRetentionLedger.shared.configure(slot: serviceName, limits: limits)
        let admission = try admit(kind: .probe, job: nil, timeout: Double(limits.timeoutSeconds),
            admissionDeadline: budget.admissionDeadline, cancellation: cancellation)
        if budget.admissionDeadline == nil { budget.admissionDeadline = admission.admissionDeadline }
        defer {
            memoryCoordinator.finish(admission.id)
            memoryCoordinator.forget(admission.id)
        }
        try installAdmission(admission)
        try requireOperation(cancellation)
        if budget.rpcDeadline == nil { budget.rpcDeadline = try BpyRuntimeClock.awakeSeconds() + 180 }
        let remaining = try (budget.rpcDeadline ?? 0) - BpyRuntimeClock.awakeSeconds()
        guard remaining > 0 else { throw BpyAdmissionFailure.timedOut }
        let request = BpyOpenSessionRequest(sessionID: identifier, documentID: documentID,
            confirmedRevision: revision, limits: limits, diagnosticOpenFailure: diagnosticOpenFailure,
            storagePair: pair, admission: admission.id, admissionDeadline: admission.admissionDeadline)
        let requestBytes = try Self.encode(request)
        var openResponseBytes: Data?
        let response = try call(timeout: remaining, observing: { bytes in
            openResponseBytes = bytes
            restoreProbe?.open = .init(method: "openSession", request: requestBytes.base64EncodedString(),
                response: bytes.base64EncodedString())
        }) { service, reply in service.openSession(requestBytes, withReply: reply) }
        if !response.ok, let openResponseBytes {
            Self.recordOpenFailure(openResponseBytes, sessionID: identifier)
        }
        try requireExecutionActive(admission.id, cancellation: cancellation)
        guard response.ok, let runtime = response.runtime,
              runtime.pythonVersion == "3.13.15", runtime.bpyVersion == "5.2.2" else {
            throw BpyRuntimeError.unavailable(response.message ?? "The bundled 3D runtime has the wrong identity.")
        }
        let transport = try currentConnection()
        guard transport.1 == identifier, runtime.serviceProcessIdentifier == transport.0.processIdentifier else {
            throw BpyRuntimeError.invalidOutput("The 3D service returned another process identity.")
        }
        try worker.bindService(transport.0.processIdentifier)
        try data.bindService(transport.0.processIdentifier)
        if let revision, let checkpoint {
            try restoreCheckpoint(checkpoint, revision: revision, sessionID: identifier, probe: restoreProbe,
                admission: admission.id, cancellation: cancellation)
        } else if revision != nil || checkpoint != nil {
            throw BpyRuntimeError.unavailable("The confirmed 3D checkpoint is incomplete.")
        }
        try requireExecutionActive(admission.id, cancellation: cancellation)
        try lock.withLock {
            guard sessionID == identifier, !closed, !closing else { throw BpyAdmissionFailure.closed }
            opened = true; transportInvalidated = false; lastReadyResponse = response
            openAdmission = admission
        }
        return response
    }

    private static func recordOpenFailure(_ response: Data, sessionID: UUID) {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let path = ProcessInfo.processInfo.environment["NGV_BPY_COMMAND_EVIDENCE"] else { return }
        var record: [String: Any] = [
            "schema": "nexgenvideo/bpy-open-failure/1", "sessionID": sessionID.uuidString,
            "hostPID": getpid(),
            "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
            "responseSHA256": SHA256.hash(data: response).map { String(format: "%02x", $0) }.joined(),
            "response": response.base64EncodedString(),
        ]
        do {
            record["hostInspectionFailures"] = try BpyRuntimeObservation.shared.inspectionFailureSnapshot()
            let url = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("open-failure-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                .write(to: url, options: .withoutOverwriting)
        } catch {
            Log.app.error("3D startup diagnostics could not be saved: \(error.localizedDescription)",
                telemetry: "bpy-open-diagnostics-write-failed")
        }
    }

    private static var jobDiagnosticReplyBytes: Int { 8 * 1_024 * 1_024 }

    private static var jobDiagnosticDirectory: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["NGV_SELFTEST_BPY"]?.isEmpty == false,
              let path = environment["NGV_BPY_COMMAND_EVIDENCE"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func recordJobDiagnostic(directory: URL, jobID: UUID,
        response: BpyServiceResponse?, initial: BpyServiceResponse,
        serverReply: Data?, serverMethod: String, serverReplyBytes: Int,
        permit: BpyMemoryCoordinator.PermitReceipt?, error: Error?, returned: Bool, stagedOutputNames: [String]) {
        do {
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            var record: [String: Any] = [
                "schema": "nexgenvideo/bpy-job-diagnostic/1", "hostPID": getpid(),
                "sourceSHA": Bundle.main.object(forInfoDictionaryKey: "NGVSourceCommit") as? String ?? "",
                "jobID": jobID.uuidString, "finishReturned": returned,
                "initialResponse": try JSONSerialization.jsonObject(with: encoder.encode(initial)),
                "serverMethod": serverMethod, "serverReplyBytes": serverReplyBytes,
                "serverReplyRetained": serverReply != nil, "stagedOutputNames": stagedOutputNames,
                "serverReplyScope": "last-successfully-decoded",
                "responseStatus": response == nil ? "unavailable" : "captured",
                "permitReceiptStatus": permit == nil ? "unavailable" : "captured",
                "partialDiagnosticOnly": true, "nonFiniteFloatEncoding": "strings",
                "hostInspectionFailures": try BpyRuntimeObservation.shared.inspectionFailureSnapshot(),
            ]
            if let response { record["response"] = try JSONSerialization.jsonObject(with: encoder.encode(response)) }
            if let permit { record["permitReceipt"] = try JSONSerialization.jsonObject(with: encoder.encode(permit)) }
            if let error {
                record["error"] = String(describing: error)
                record["localizedError"] = error.localizedDescription
            }
            if let serverReply {
                record["serverReply"] = serverReply.base64EncodedString()
                record["serverReplySHA256"] = SHA256.hash(data: serverReply).map { String(format: "%02x", $0) }.joined()
            }
            let url = directory.appendingPathComponent("job-response-\(jobID.uuidString)-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                .write(to: url, options: .withoutOverwriting)
        } catch {
            Log.app.error("3D job diagnostics could not be saved: \(error.localizedDescription)",
                telemetry: "bpy-job-diagnostics-write-failed")
        }
    }

    private func restoreCheckpoint(_ file: BpyRuntimeFile, revision: String, sessionID: UUID,
                                   probe: BpyNativeRestoreProbe?, admission: UUID, cancellation: BpyOperationCancellation) throws {
        if probe != nil { probe?.checkpoint = try file.verifiedData(maximum: limits.inputBytes) }
        probe?.exchanges.removeAll()
        let digest = file.sha256
        var offset: UInt64 = 0
        while offset < file.byteCount || file.byteCount == 0 {
            try requireExecutionActive(admission, cancellation: cancellation)
            let end = min(file.byteCount, offset + 4 * 1_024 * 1_024)
            let chunk = try file.read(offset: offset, maximum: Int(end - offset))
            let final = end == file.byteCount
            let request = BpyRestoreCheckpointRequest(
                sessionID: sessionID,
                revision: revision,
                offset: offset,
                totalBytes: file.byteCount,
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

    private func upload(_ prepared: PreparedBpyInput, jobID: UUID, cancellation: BpyOperationCancellation) throws {
        try requireOperation(cancellation)
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
                try requireOperation(cancellation)
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
                try requireOperation(cancellation)
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

    private func downloadOutputs(_ descriptors: [BpyOutputDescriptor], jobID: UUID,
                                 cancellation: BpyOperationCancellation, timeout: TimeInterval,
                                 work: BpyConsumerWork) throws -> [String: BpyRuntimeFile] {
        let context = lock.withLock { (jobFingerprints[jobID], outputReservations[jobID], transferDeadlines[jobID]) }
        guard let fingerprint = context.0, let reservation = context.1,
              BpyOutputContract.acceptsOutputs(descriptors, fileLimit: limits.files, byteLimit: limits.outputBytes) else {
            throw BpyRuntimeError.invalidOutput("The 3D output has no valid retained reservation.")
        }
        let deadline = try context.2 ?? (BpyRuntimeClock.awakeSeconds() + timeout)
        lock.withLock { transferDeadlines[jobID] = deadline }
        let ledger = BpyRetentionLedger.shared
        let overlap = try ledger.reserve(slot: serviceName, owner: memoryOwner, kind: .transfer, bytes: limits.outputBytes)
        lock.withLock {
            transfers[jobID] = .init(reservation: overlap, transport: sessionID,
                pairIDs: [storageVolume?.lease.id, storageDataVolume?.lease.id].compactMap { $0 },
                request: .init(sessionID: sessionID, jobID: jobID, disposition: .abandonedResult,
                    fingerprint: fingerprint, outputs: descriptors))
        }
        defer { ledger.settle(reservation) }
        let root = stagingRoot.appendingPathComponent(jobID.uuidString)
        var files: [String: BpyRuntimeFile] = [:]
        var returned = false
        defer { if !returned { for file in files.values { file.release() } } }
        for descriptor in descriptors {
            try requireOperation(cancellation)
            try work.check()
            let file = try ledger.creatingFile(reservation, bytes: descriptor.byteCount) {
                try BpyRuntimeFile.receive(at: root.appendingPathComponent(descriptor.name),
                byteCount: descriptor.byteCount, expectedSHA256: descriptor.sha256,
                disposed: { removed, identity in
                    if removed { ledger.disposed(reservation, identity: identity, bytes: identity.bytes) }
                }) { offset, count in
                    try self.requireOperation(cancellation)
                    try work.check()
                    let now = try BpyRuntimeClock.awakeSeconds()
                    guard now < deadline else { throw BpyRuntimeError.timedOut }
                    let request = BpyReadOutputRequest(sessionID: self.currentSessionID(), jobID: jobID,
                        name: descriptor.name, offset: offset, maximumBytes: count)
                    let chunk = try self.callChunk(timeout: min(30, deadline - now), jobID: jobID, fingerprint: fingerprint) { service, reply in
                            service.readOutput(try Self.encode(request), withReply: reply)
                        }
                    try self.requireOperation(cancellation)
                    try work.check()
                    guard try BpyRuntimeClock.awakeSeconds() <= deadline, chunk.count == count else {
                        throw BpyRuntimeError.timedOut
                    }
                    return chunk
                }
            }
            files[descriptor.name] = file
            try ledger.bind(reservation, file: file)
            try validateMagic(file, mediaType: descriptor.mediaType, checking: {
                try self.requireOperation(cancellation)
                try work.check()
                guard try BpyRuntimeClock.awakeSeconds() <= deadline else { throw BpyRuntimeError.timedOut }
            })
        }
        returned = true
        return files
    }

    private func validateMagic(_ file: BpyRuntimeFile, mediaType: String, checking: @escaping () throws -> Void) throws {
        try checking()
        let prefix = try file.read(maximum: 24)
        let valid: Bool
        switch mediaType {
        case "application/x-blender":
            valid = BpyBlendFileFormat.accepts(prefix)
        case "image/png":
            valid = prefix.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        case "application/json":
            try BpyJSONValidation.validate(file, checking: checking)
            valid = true
        default:
            valid = false
        }
        guard valid else {
            throw BpyRuntimeError.invalidOutput("The worker output type is invalid.")
        }
    }

    private func cache(_ result: BpyRuntimeJobResult, for id: UUID, cancellation: BpyOperationCancellation) throws {
        try lock.withLock {
            guard !closed, !closing, !transportInvalidated, result.lease?.transport == sessionID else { throw BpyAdmissionFailure.closed }
            try cancellation.check()
            if let log = result.response.stdout {
                cachedLogs[id] = log; logOrder.removeAll { $0 == id }; logOrder.append(id)
                while logOrder.count > 16 { cachedLogs.removeValue(forKey: logOrder.removeFirst()) }
            }
            var receipt = result.response
            receipt.stdout = nil
            cachedResults[id] = .init(response: receipt, stagedOutputs: result.stagedOutputs, lease: result.lease)
        }
    }

    private func releasedResult(jobID: UUID, leaseID: UUID, wasDetached: Bool) {
        let released = lock.withLock { () -> (BpyRuntimeJobResult?, UUID?, Bool)? in
            guard cachedResults[jobID]?.lease?.id == leaseID else { return nil }
            validatedCandidates.removeValue(forKey: jobID); candidateJobIDs.remove(jobID)
            spatialDerivations.removeValue(forKey: jobID)
            transferDeadlines.removeValue(forKey: jobID)
            cachedLogs.removeValue(forKey: jobID); logOrder.removeAll { $0 == jobID }
            return (cachedResults.removeValue(forKey: jobID), outputReservations.removeValue(forKey: jobID), transfers[jobID] != nil)
        }
        guard let context = released else { return }
        if let reservation = context.1 { BpyRetentionLedger.shared.settle(reservation) }
        requestTransferRelease(jobID: jobID)
        if let result = context.0, !context.2, !wasDetached {
            let request = BpyReleaseResourcesRequest(sessionID: currentSessionID(), jobID: jobID,
                disposition: .abandonedResult, fingerprint: result.response.jobFingerprint, outputs: result.response.outputs)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = try? self?.call(timeout: 2) { service, reply in service.releaseResources(try Self.encode(request), withReply: reply) }
            }
        }
    }

    private func requestTransferRelease(jobID: UUID) {
        let needsRelease = lock.withLock { () -> Bool in
            guard var record = transfers[jobID] else { return false }
            record.releaseRequested = true
            if record.releaseDeadline == nil { record.releaseDeadline = BpyRuntimeClock.read().map { $0.awake + 5 } }
            transfers[jobID] = record
            return true
        }
        if needsRelease {
            DispatchQueue.global(qos: .utility).async { [self] in _ = releaseTransfer(jobID: jobID) }
        }
    }

    @discardableResult
    private func releaseTransfer(jobID: UUID) -> Bool {
        transferCleanupLock.lock(); defer { transferCleanupLock.unlock() }
        while true {
            guard let record = lock.withLock({ transfers[jobID] }) else { return true }
            guard record.releaseRequested, let deadline = record.releaseDeadline,
                  let now = BpyRuntimeClock.read()?.awake else { return false }
            let current = lock.withLock { sessionID == record.transport && !transportInvalidated && !closed }
            if current {
                guard now < deadline else { return recoverTransfer(jobID: jobID, record: record) }
                do {
                    let response = try call(timeout: min(2, deadline - now), allowClosing: true) { service, reply in
                        service.releaseResources(try Self.encode(record.request), withReply: reply)
                    }
                    if response.ok { acknowledgeTransfer(jobID: jobID, reservation: record.reservation); return true }
                    guard response.message == "result release pending" else { return recoverTransfer(jobID: jobID, record: record) }
                } catch { return recoverTransfer(jobID: jobID, record: record) }
            } else {
                guard record.pairIDs.count == 2, let proof = try? queryStorageOwnership(),
                      record.pairIDs.allSatisfy({ !proof.inUseStorageIDs.contains($0) }) else { return false }
                acknowledgeTransfer(jobID: jobID, reservation: record.reservation)
                return true
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func recoverTransfer(jobID: UUID, record: TransferRecord) -> Bool {
        markTransportInvalid(record.transport, disposition: .releaseFailed)
        guard lock.withLock({ transportRecovery })?.wait() == true,
              record.pairIDs.count == 2, let proof = try? queryStorageOwnership(),
              record.pairIDs.allSatisfy({ !proof.inUseStorageIDs.contains($0) }) else { return false }
        acknowledgeTransfer(jobID: jobID, reservation: record.reservation)
        return true
    }

    private func acknowledgeTransfer(jobID: UUID, reservation: UUID) {
        let removed = lock.withLock { () -> Bool in
            guard transfers[jobID]?.reservation == reservation else { return false }
            transfers.removeValue(forKey: jobID)
            return true
        }
        if removed { BpyRetentionLedger.shared.release(reservation) }
    }

    private func drainTransfers() throws {
        let pending = lock.withLock { transfers.filter { $0.value.releaseRequested }.map(\.key) }
        for job in pending where !releaseTransfer(jobID: job) {
            throw BpyRuntimeError.unavailable("The prior 3D result is still being released. Retry after cleanup finishes.")
        }
    }

    func releaseResult(jobID: UUID) {
        let lease = lock.withLock { cachedResults[jobID]?.lease }
        lease?.release()
    }

    private func removeStagedResults(_ ids: [UUID]) {
        let leases = lock.withLock { ids.compactMap { cachedResults[$0]?.lease } }
        for lease in leases { lease.invalidate() }
    }

    private func installConnection() {
        let identifier = currentSessionID()
        let value = NSXPCConnection(serviceName: serviceName)
        value.remoteObjectInterface = NSXPCInterface(with: BpyRuntimeServiceProtocol.self)
        var monitor: BpyHostMonitor?
        if let layout = try? BpyRuntimeBundleLayout(app: Bundle.main.bundleURL, serviceName: serviceName) {
            value.exportedInterface = NSXPCInterface(with: BpyHostMonitorProtocol.self)
            monitor = BpyHostMonitor(connection: value, transport: identifier, layout: layout,
                memory: memoryCoordinator) { [weak self] process in
                self?.recordMonitoredProcess(process, transportID: identifier)
            }
            value.exportedObject = monitor
        }
        value.interruptionHandler = { [weak self] in self?.markTransportInvalid(identifier) }
        value.invalidationHandler = { [weak self] in self?.markTransportInvalid(identifier) }
        lock.lock()
        guard !closed, !closing, sessionID == identifier else {
            lock.unlock()
            value.invalidate()
            return
        }
        connection = value
        hostMonitor = monitor
        lock.unlock()
        value.resume()
    }

    private func rotateTransport() throws {
        let invalid = lock.withLock { transportInvalidated }
        if !invalid { try drainTransfers() }
        let identifier = currentSessionID()
        markTransportInvalid(identifier, disposition: .rotation)
        lock.lock()
        let recovery = transportRecovery
        lock.unlock()
        guard recovery?.wait() == true else {
            throw BpyRuntimeError.unavailable("The previous 3D worker could not be observed exiting; recovery is blocked.")
        }
        try drainTransfers()
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
        transportRecovery = nil
        activeProcessLease = nil
        lastReadyResponse = nil
        uploadedJobIDs.removeAll(); stagingJobIDs.removeAll()
        lock.unlock()
        previous?.invalidate()
        installConnection()
    }

    private func markTransportInvalid(_ identifier: UUID, disposition: BpyTransportDisposition = .loss) {
        lock.lock()
        guard sessionID == identifier, !transportInvalidated else {
            lock.unlock()
            return
        }
        let recovery = BpyTransportRecovery()
        transportRecovery = recovery
        let invalidConnection = connection
        let monitor = hostMonitor
        transportInvalidated = true
        opened = false
        validatedCandidates.removeAll()
        candidateJobIDs.removeAll()
        let unconfirmed = cachedResults.compactMap { key, value in
            value.response.state == .awaitingConfirmation ? key : nil
        }
        let invalidLeases = unconfirmed.compactMap { cachedResults[$0]?.lease }.filter { !$0.isDetached }
        lock.unlock()
        invalidConnection?.invalidate()
        if let monitor {
            monitor.recover(disposition: disposition) { recovery.finish(exited: $0) }
        } else { recovery.finish(exited: false) }
        for lease in invalidLeases { lease.invalidate() }
    }

    private func currentSessionID() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    func nativeDroppedStatusReplyProbe(jobID: UUID) throws -> Data {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else {
            throw BpyRuntimeError.unavailable("The transport probe requires explicit verification.")
        }
        let (connection, transport) = try currentConnection()
        guard let service = try BpyKernelInspection.process(connection.processIdentifier) else {
            throw BpyRuntimeError.invalidOutput("The transport probe requires a live service.")
        }
        let captured = BpyReplyBox()
        let request = BpyJobReference(sessionID: transport, jobID: jobID)
        do {
            _ = try call(timeout: 2) { proxy, _ in
                proxy.jobStatus(try Self.encode(request)) { data in _ = captured.store(response: data) }
            }
            throw BpyRuntimeError.invalidOutput("The dropped reply did not exercise the timeout.")
        } catch BpyRuntimeError.timedOut { }
        guard let bytes = captured.load().0 else {
            throw BpyRuntimeError.invalidOutput("The live service did not answer the controlled request.")
        }
        let response = try Self.decode(bytes)
        guard response.ok, response.jobID == jobID, response.state == .running,
              response.activeProcessIdentifier != nil, response.activeProcessStartAbsoluteTime != nil,
              response.activeProcessExecutable != nil, response.activeWorkerProcessIdentifier != nil,
              response.runtime?.serviceProcessIdentifier == service.pid,
              response.activeProcessAuthorizationID == nil else {
            throw BpyRuntimeError.invalidOutput("The timeout probe did not observe an authorized live worker.")
        }
        return try JSONSerialization.data(withJSONObject: ["schema": "nexgenvideo/bpy-dropped-reply/1",
            "servicePID": service.pid, "serviceStart": service.start, "serviceExecutable": service.executable,
            "jobID": jobID.uuidString, "transport": transport.uuidString,
            "response": bytes.base64EncodedString()] as [String: Any], options: [.sortedKeys])
    }

    func nativeProtocolProbe(confirmedJobID: UUID) throws -> Data {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else {
            throw BpyRuntimeError.unavailable("The native protocol probe requires explicit acceptance.")
        }
        let identifier = currentSessionID()
        let checkpoint = try protocolProbeCheckpoint()
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
            requests[label] = try ((label.hasPrefix("storage-") || label == "reservation-failed-bookmark") ? Self.storageEvidenceRequest(request) : request).base64EncodedString()
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
        let storageContext = lock.withLock { (storageVolume?.lease, storageDataVolume?.lease, openAdmission) }
        guard let workerLease = storageContext.0, let dataLease = storageContext.1,
              let pairID = workerLease.pairID, let originalAdmission = storageContext.2 else { throw SpatialSceneError.changed }
        let pair = BpyStoragePair(id: pairID, worker: workerLease, data: dataLease)
        let storageReference = try Self.storageEvidenceRequest(Self.encode(BpyOpenSessionRequest(
            sessionID: identifier, documentID: documentID, limits: limits, storagePair: pair, admission: originalAdmission.id, admissionDeadline: originalAdmission.admissionDeadline)))
        func changedWorker(device: UInt64? = nil, capacity: UInt64? = nil, path: String? = nil, bookmark: Data? = nil) -> BpyStorageLease {
            .init(id: workerLease.id, mountPath: path ?? workerLease.mountPath, device: device ?? workerLease.device,
                capacityBytes: capacity ?? workerLease.capacityBytes, bookmark: bookmark ?? workerLease.bookmark,
                role: workerLease.role, pairID: workerLease.pairID)
        }
        let wrongDevice = workerLease.device ^ ((workerLease.device ^ (1 << 31)) == dataLease.device ? (1 << 30) : (1 << 31))
        for (label, storage) in [
            ("storage-wrong-device", changedWorker(device: wrongDevice)),
            ("storage-wrong-capacity", changedWorker(capacity: workerLease.capacityBytes - 1)),
            ("storage-wrong-path", changedWorker(path: workerLease.mountPath + "/other"))
        ] {
            let target = UUID(), cancellation = BpyOperationCancellation()
            let permit = try memoryCoordinator.admit(owner: memoryOwner, generation: memoryGeneration,
                transport: target, job: nil, kind: .probe, timeout: Double(limits.timeoutSeconds), cancellation: cancellation)
            defer { memoryCoordinator.finish(permit.id); memoryCoordinator.forget(permit.id) }
            let forgedPair = BpyStoragePair(id: pair.id, worker: storage, data: dataLease)
            let probe = BpyOpenSessionRequest(sessionID: target, documentID: documentID, limits: limits,
                storagePair: forgedPair, admission: permit.id, admissionDeadline: permit.admissionDeadline)
            guard try !send(label, request: Self.encode(probe), { $0.openSession($1, withReply: $2) }).ok else {
                throw BpyRuntimeError.invalidOutput("The service accepted a forged storage pair: " + label)
            }
        }
        let brokenPair = BpyStoragePair(id: pair.id, worker: changedWorker(bookmark: Data([1, 2, 3])), data: dataLease)
        let failedOpen = try Self.encode(BpyOpenSessionRequest(sessionID: reservationID, documentID: documentID,
            limits: limits, storagePair: brokenPair, admission: originalAdmission.id, admissionDeadline: originalAdmission.admissionDeadline))
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
        let verifiedSource = "assert set(p.name for p in input_dir.iterdir()) == {'foo', 'foo.part', 'probe.json'}; assert all((input_dir / n).read_text() == '{}' for n in ['foo', 'foo.part', 'probe.json'])"
        let inputNames = ["foo", "foo.part", "probe.json"]
        let source = verifiedSource
        let fingerprint = BpyJobFingerprintV5.compute(expectedRevision: revision, source: source, requestedTimeout: nil,
            effectiveTimeout: limits.timeoutSeconds, inputs: inputNames.map { .init(name: $0, byteCount: 2, sha256: hash) },
            deniedPaths: [], autoexecControl: false, identityWriteFailure: false, identityCaptureFailure: false)
        let cancellation = BpyOperationCancellation()
        let admission = try admit(kind: .job, job: stagedID, timeout: Double(limits.timeoutSeconds), cancellation: cancellation)
        try installAdmission(admission, source: verifiedSource, fingerprint: fingerprint)
        defer {
            memoryCoordinator.cancel(admission.id)
            memoryCoordinator.finish(admission.id)
            memoryCoordinator.forget(admission.id)
        }
        let partialRun = BpyRunJobRequest(sessionID: identifier, jobID: stagedID, expectedRevision: revision,
            source: partialSource, inputNames: ["foo.part", "probe.json"], fingerprint: partialFingerprint, admission: admission.id, admissionDeadline: admission.admissionDeadline)
        guard try !send("submit-with-partial-input", request: Self.encode(partialRun), { $0.runJob($1, withReply: $2) }).ok,
              try stage("completed-partial-input", id: stagedID, size: 2, sha: hash, final: true,
                        data: Data("}".utf8), name: "foo", offset: 1).ok else {
            throw BpyRuntimeError.invalidOutput("A partial input reached execution or could not be completed after refusal.")
        }
        let run = BpyRunJobRequest(sessionID: identifier, jobID: stagedID, expectedRevision: revision, source: source,
            inputNames: inputNames, fingerprint: fingerprint, admission: admission.id, admissionDeadline: admission.admissionDeadline)
        lock.withLock {
            jobFingerprints[stagedID] = fingerprint
            jobOrigins[stagedID] = (revision, Self.sha256(scene))
            submittedTransportIDs[stagedID] = identifier
            submittedJobIDs.insert(stagedID)
        }
        let accepted = try send("service-submit", request: Self.encode(run)) { $0.runJob($1, withReply: $2) }
        let joined = try send("service-submit-replay", request: Self.encode(run)) { $0.runJob($1, withReply: $2) }
        guard accepted.ok, joined.ok, joined.joinedExistingJob, joined.jobFingerprint == fingerprint else {
            throw BpyRuntimeError.invalidOutput("The actual service did not idempotently join its consumed Job ID.")
        }
        let complete = try waitForTerminal(jobID: stagedID, fingerprint: fingerprint, response: joined,
            admission: admission, cancellation: cancellation, authorizeInitial: false, observing: { method, request, response in
                if method == "jobStatus" {
                    requests["service-completed"] = request.base64EncodedString()
                    responses["service-completed"] = response.base64EncodedString()
                    exchangeOrder.append("service-completed")
                }
                completion.append(.init(method: method, request: request.base64EncodedString(), response: response.base64EncodedString()))
            })
        guard complete.state == .awaitingConfirmation else {
            let error = BpyRuntimeError.invalidOutput("The staged service job failed.")
            if let directory = Self.jobDiagnosticDirectory {
                let reply = completion.last.flatMap { Data(base64Encoded: $0.response) }
                Self.recordJobDiagnostic(directory: directory, jobID: stagedID, response: complete, initial: joined,
                    serverReply: reply.flatMap { $0.count <= Self.jobDiagnosticReplyBytes ? $0 : nil },
                    serverMethod: completion.last?.method ?? "unavailable", serverReplyBytes: reply?.count ?? 0,
                    permit: nil, error: error, returned: false, stagedOutputNames: complete.outputs.map(\.name))
            }
            throw error
        }
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
            schema: "nexgenvideo/bpy-native-protocol-evidence/4", requests: requests, chunks: chunks,
            responses: responses, exchangeOrder: exchangeOrder, completion: completion, restoreOpen: nil, restore: nil,
            storageReference: storageReference.base64EncodedString()))
    }

    func nativeProtocolRestoreProbe(addingTo evidence: Data) throws -> (ready: BpyServiceResponse, evidence: Data, checkpoint: Data) {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else {
            throw BpyRuntimeError.unavailable("The native restore probe requires explicit acceptance.")
        }
        var document = try JSONDecoder().decode(BpyNativeProtocolProbeEvidence.self, from: evidence)
        guard document.schema == "nexgenvideo/bpy-native-protocol-evidence/4", document.restore == nil else {
            throw BpyRuntimeError.invalidOutput("The protocol evidence already contains a restore.")
        }
        let probe = BpyNativeRestoreProbe()
        let ready = try ensureOpen(restoreProbe: probe)
        guard let checkpoint = probe.checkpoint, let open = probe.open, !probe.exchanges.isEmpty else {
            throw BpyRuntimeError.invalidOutput("No actual checkpoint upload occurred.")
        }
        guard let openBytes = Data(base64Encoded: open.request) else {
            throw BpyRuntimeError.invalidOutput("The restore probe has no open request bytes.")
        }
        document.restoreOpen = .init(method: open.method,
            request: try Self.storageEvidenceRequest(openBytes).base64EncodedString(),
            response: open.response)
        document.restore = probe.exchanges
        return (ready, try JSONEncoder().encode(document), checkpoint)
    }

    private func protocolProbeCheckpoint() throws -> (String?, Data?) {
        let current = try lock.withLock { (confirmedRevision, try confirmedSceneFile?.retained()) }
        defer { current.1?.release() }
        return (current.0, try current.1?.verifiedData(maximum: limits.inputBytes))
    }

    private func makeCheckpoint(_ payload: SpatialScenePayload, cancellation: BpyOperationCancellation) throws -> BpyRuntimeFile {
        try requireOperation(cancellation)
        guard payload.byteCount <= limits.inputBytes else { throw SpatialSceneError.changed }
        if let existing = try lock.withLock({ try confirmedSceneFile?.retained() }) {
            if existing.sha256 == payload.sha256 { return existing }
            existing.release()
        }
        let ledger = BpyRetentionLedger.shared
        try ledger.configure(slot: serviceName, limits: limits)
        let reservation = try ledger.reserve(slot: serviceName, owner: memoryOwner, kind: .checkpoint, bytes: payload.byteCount)
        defer { ledger.settle(reservation) }
        let url = stagingRoot.appendingPathComponent("checkpoints/" + UUID().uuidString + ".blend")
        let file = try ledger.creatingFile(reservation, bytes: payload.byteCount) {
            try payload.checkpoint(to: url, maximum: limits.inputBytes,
                checking: { try self.requireOperation(cancellation) }) { removed, identity in
                if removed { ledger.disposed(reservation, identity: identity, bytes: identity.bytes) }
            }
        }
        try ledger.bind(reservation, file: file)
        return file
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
        guard response.ok else {
            throw BpyRuntimeError.rejected(response.message ?? "The 3D output was rejected.")
        }
        guard response.jobID == jobID, response.jobFingerprint == fingerprint else {
            throw BpyRuntimeError.invalidOutput("The 3D output returned the wrong job identity.")
        }
        return chunk
    }

    private func recordMonitoredProcess(_ process: BpyObservedProcess?, transportID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard sessionID == transportID, !transportInvalidated else { return }
        activeProcessLease = process.map {
            .init(transportID: transportID, processIdentifier: $0.pid,
                  startAbsoluteTime: $0.start, executable: $0.executable)
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
        guard let monitor = lock.withLock({ hostMonitor }) else { throw BpyAdmissionFailure.closed }
        guard try monitor.authorize(execution: authorizationID, pid: processIdentifier, start: startAbsoluteTime) else {
            return response
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
              authorized.activeProcessAuthorizationID != authorizationID else {
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

    private static func storageEvidenceRequest(_ data: Data) throws -> Data {
        guard var request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BpyRuntimeError.invalidOutput("The storage probe request is not an object.")
        }
        if var pair = request["storagePair"] as? [String: Any] {
            for role in ["worker", "data"] {
                guard var storage = pair[role] as? [String: Any],
                      let encoded = storage.removeValue(forKey: "bookmark") as? String,
                      let bookmark = Data(base64Encoded: encoded) else { throw SpatialSceneError.changed }
                storage["bookmarkSHA256"] = Self.sha256(bookmark)
                pair[role] = storage
            }
            request["storagePair"] = pair
        }
        return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
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
    let storageReference: String
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
            NSApplication.shared.presentError(Self.cleanupError(reason: retiring[key]?.cleanupFailure))
        }
    }

    static func cleanupError(reason: String?) -> NSError {
        NSError(domain: "NexGenVideo.BpyRuntime", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "3D runtime cleanup failed.",
            NSLocalizedFailureReasonErrorKey: reason ?? "The runtime storage is still in use.",
            NSLocalizedRecoverySuggestionErrorKey: "Save your project, then choose Quit NexGenVideo to retry cleanup."
        ])
    }
}
