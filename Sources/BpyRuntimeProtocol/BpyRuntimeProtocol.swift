import Foundation

public let bpyRuntimeServiceNames = [
    "de.h5ventures.nexgenvideo.bpy-service-0",
    "de.h5ventures.nexgenvideo.bpy-service-1",
]

@objc public protocol BpyRuntimeServiceProtocol {
    func runBoundaryProbe(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func openSession(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func restoreCheckpoint(_ request: Data, chunk: Data, withReply reply: @escaping (Data) -> Void)
    func stageInput(_ request: Data, chunk: Data, withReply reply: @escaping (Data) -> Void)
    func runJob(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func jobStatus(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func authorizeProcess(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func readOutput(_ request: Data, withReply reply: @escaping (Data, Data) -> Void)
    func confirmJob(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func cancelJob(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func releaseResources(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func closeSession(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func shutdown(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public struct BpyBoundaryProbeRequest: Codable, Sendable, Equatable {
    public let schema: String
    public let nonce: UUID
    public let execution: UUID
    public let mode: BpyBoundaryMode
    public let storagePair: BpyStoragePair
    public let admission: UUID
    public let admissionDeadline: TimeInterval
    public let limits: BpyRuntimeLimits

    public init(nonce: UUID, execution: UUID, mode: BpyBoundaryMode, storagePair: BpyStoragePair,
                admission: UUID, admissionDeadline: TimeInterval, limits: BpyRuntimeLimits) {
        schema = "nexgenvideo/bpy-boundary-probe-request/2"
        self.nonce = nonce; self.execution = execution; self.mode = mode
        self.storagePair = storagePair; self.admission = admission; self.admissionDeadline = admissionDeadline; self.limits = limits
    }
}

public struct BpyBoundaryProbeResult: Codable, Sendable, Equatable {
    public let schema: String
    public let nonce: UUID
    public let serviceProcessIdentifier: Int32
    public let serviceStartAbsoluteTime: UInt64
    public let supervisorProcessIdentifier: Int32
    public let supervisorParentProcessIdentifier: Int32
    public let supervisorStartAbsoluteTime: UInt64
    public let childProcessIdentifier: Int32
    public let childStartAbsoluteTime: UInt64
    public let childParentProcessIdentifier: Int32
    public let allowedWriteSucceeded: Bool
    public let outsideWriteDeniedErrno: Int32
    public let forkDeniedErrno: Int32
    public let networkDeniedErrno: Int32
    public let signalDeniedErrnos: [Int32]
    public let unlinkedBytesObserved: UInt64
    public let unlinkedLimitReason: String
    public let cleanupSupervisorGone: Bool
    public let cleanupChildGone: Bool
    public let internalLinkedWritableDeduplicated: Bool
    public let fileportRetentionDeniedErrno: Int32
    public let fileportRetentionDenied: Bool
    public let fileportBytesObserved: UInt64
    public let fileportLimitReason: String
    public let healthyFollowupSucceeded: Bool

    public init(
        nonce: UUID,
        serviceProcessIdentifier: Int32,
        serviceStartAbsoluteTime: UInt64,
        supervisorProcessIdentifier: Int32,
        supervisorParentProcessIdentifier: Int32,
        supervisorStartAbsoluteTime: UInt64,
        childProcessIdentifier: Int32,
        childStartAbsoluteTime: UInt64,
        childParentProcessIdentifier: Int32,
        allowedWriteSucceeded: Bool,
        outsideWriteDeniedErrno: Int32,
        forkDeniedErrno: Int32,
        networkDeniedErrno: Int32,
        signalDeniedErrnos: [Int32],
        unlinkedBytesObserved: UInt64,
        unlinkedLimitReason: String,
        cleanupSupervisorGone: Bool,
        cleanupChildGone: Bool,
        internalLinkedWritableDeduplicated: Bool,
        fileportRetentionDeniedErrno: Int32,
        fileportRetentionDenied: Bool,
        fileportBytesObserved: UInt64,
        fileportLimitReason: String,
        healthyFollowupSucceeded: Bool
    ) {
        schema = "nexgenvideo/bpy-boundary-probe/5"
        self.nonce = nonce
        self.serviceProcessIdentifier = serviceProcessIdentifier
        self.serviceStartAbsoluteTime = serviceStartAbsoluteTime
        self.supervisorProcessIdentifier = supervisorProcessIdentifier
        self.supervisorParentProcessIdentifier = supervisorParentProcessIdentifier
        self.supervisorStartAbsoluteTime = supervisorStartAbsoluteTime
        self.childProcessIdentifier = childProcessIdentifier
        self.childStartAbsoluteTime = childStartAbsoluteTime
        self.childParentProcessIdentifier = childParentProcessIdentifier
        self.allowedWriteSucceeded = allowedWriteSucceeded
        self.outsideWriteDeniedErrno = outsideWriteDeniedErrno
        self.forkDeniedErrno = forkDeniedErrno
        self.networkDeniedErrno = networkDeniedErrno
        self.signalDeniedErrnos = signalDeniedErrnos
        self.unlinkedBytesObserved = unlinkedBytesObserved
        self.unlinkedLimitReason = unlinkedLimitReason
        self.cleanupSupervisorGone = cleanupSupervisorGone
        self.cleanupChildGone = cleanupChildGone
        self.internalLinkedWritableDeduplicated = internalLinkedWritableDeduplicated
        self.fileportRetentionDeniedErrno = fileportRetentionDeniedErrno
        self.fileportRetentionDenied = fileportRetentionDenied
        self.fileportBytesObserved = fileportBytesObserved
        self.fileportLimitReason = fileportLimitReason
        self.healthyFollowupSucceeded = healthyFollowupSucceeded
    }
}

public enum BpyRuntimeMemoryPolicy: String, Codable, Sendable {
    case systemPressureV1 = "system-pressure-v1"
}

public struct BpyRuntimeLimits: Codable, Sendable, Equatable {
    public static let maximumOutputBytes: UInt64 = 512 * 1_024 * 1_024
    public static let maximumRenderPixels = 67_108_864
    public var timeoutSeconds: Int
    public var memoryPolicy: BpyRuntimeMemoryPolicy
    public var inputBytes: UInt64
    public var outputBytes: UInt64
    public var stdoutBytes: Int
    public var objects: Int
    public var vertices: Int
    public var polygons: Int
    public var diskBytes: UInt64
    public var files: Int
    public var renderWidth: Int
    public var renderHeight: Int
    public var renderPixels: Int

    public init(
        timeoutSeconds: Int = 120,
        memoryPolicy: BpyRuntimeMemoryPolicy = .systemPressureV1,
        inputBytes: UInt64 = 512 * 1_024 * 1_024,
        outputBytes: UInt64 = 512 * 1_024 * 1_024,
        stdoutBytes: Int = 1_048_576,
        objects: Int = 20_000,
        vertices: Int = 20_000_000,
        polygons: Int = 20_000_000,
        diskBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024,
        files: Int = 4_096,
        renderWidth: Int = 8_192,
        renderHeight: Int = 8_192,
        renderPixels: Int = 33_177_600
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.memoryPolicy = memoryPolicy
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.stdoutBytes = stdoutBytes
        self.objects = objects
        self.vertices = vertices
        self.polygons = polygons
        self.diskBytes = diskBytes
        self.files = files
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.renderPixels = renderPixels
    }

    public var physicalStorageBytes: UInt64 { max(diskBytes, 64 * 1_024 * 1_024) }

    public var retainedOutputBytes: UInt64? {
        let fourOutputs = outputBytes.multipliedReportingOverflow(by: 4)
        return fourOutputs.overflow ? nil : min(diskBytes, fourOutputs.partialValue)
    }

    public var dataStorageBytes: UInt64? {
        guard let retainedOutputBytes else { return nil }
        let checkpoint = max(inputBytes, outputBytes).multipliedReportingOverflow(by: 3)
        let payload = inputBytes.addingReportingOverflow(checkpoint.partialValue)
        let retained = payload.partialValue.addingReportingOverflow(retainedOutputBytes)
        let allowance = retained.partialValue.addingReportingOverflow(64 * 1_024 * 1_024)
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        let rounded = allowance.partialValue.addingReportingOverflow(gib - 1)
        guard !checkpoint.overflow, !payload.overflow, !retained.overflow,
              !allowance.overflow, !rounded.overflow else { return nil }
        let bytes = rounded.partialValue / gib * gib
        return bytes > 0 && bytes <= 8 * gib ? bytes : nil
    }

    public var isValid: Bool {
        (1...3_600).contains(timeoutSeconds)
            && memoryPolicy == .systemPressureV1
            && inputBytes > 0 && inputBytes <= 512 * 1_024 * 1_024 && inputBytes <= diskBytes
            && outputBytes > 0 && outputBytes <= Self.maximumOutputBytes
            && dataStorageBytes != nil
            && (1...16 * 1_024 * 1_024).contains(stdoutBytes)
            && objects > 0 && vertices > 0 && polygons > 0
            && diskBytes >= outputBytes && diskBytes <= 8 * 1_024 * 1_024 * 1_024
            && (64...65_536).contains(files)
            && (64...16_384).contains(renderWidth)
            && (64...16_384).contains(renderHeight)
            && renderPixels > 0 && renderPixels <= Self.maximumRenderPixels
    }
}

public struct BpyOpenSessionRequest: Codable, Sendable, Equatable {
    public let schema: String
    public let sessionID: UUID
    public let documentID: String
    public let confirmedRevision: String?
    public let limits: BpyRuntimeLimits
    public let diagnosticOpenFailure: Bool
    public let storage: BpyStorageLease?
    public let storagePair: BpyStoragePair?
    public let admission: UUID?
    public let admissionDeadline: TimeInterval?

    public init(
        sessionID: UUID,
        documentID: String,
        confirmedRevision: String? = nil,
        limits: BpyRuntimeLimits = .init(),
        diagnosticOpenFailure: Bool = false,
        storage: BpyStorageLease? = nil,
        storagePair: BpyStoragePair? = nil,
        admission: UUID? = nil,
        admissionDeadline: TimeInterval? = nil
    ) {
        schema = "nexgenvideo/bpy-open-session/2"
        self.sessionID = sessionID
        self.documentID = documentID
        self.confirmedRevision = confirmedRevision
        self.limits = limits
        self.diagnosticOpenFailure = diagnosticOpenFailure
        self.storage = storage
        self.storagePair = storagePair
        self.admission = admission
        self.admissionDeadline = admissionDeadline
    }
}

public struct BpyRestoreCheckpointRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let revision: String
    public let offset: UInt64
    public let totalBytes: UInt64
    public let sha256: String
    public let finalChunk: Bool

    public init(
        sessionID: UUID,
        revision: String,
        offset: UInt64,
        totalBytes: UInt64,
        sha256: String,
        finalChunk: Bool
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.offset = offset
        self.totalBytes = totalBytes
        self.sha256 = sha256
        self.finalChunk = finalChunk
    }
}

public struct BpyStageInputRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let jobID: UUID
    public let name: String
    public let offset: UInt64
    public let totalBytes: UInt64
    public let sha256: String
    public let finalChunk: Bool

    public init(
        sessionID: UUID,
        jobID: UUID,
        name: String,
        offset: UInt64,
        totalBytes: UInt64,
        sha256: String,
        finalChunk: Bool
    ) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.name = name
        self.offset = offset
        self.totalBytes = totalBytes
        self.sha256 = sha256
        self.finalChunk = finalChunk
    }
}

public struct BpyRunJobRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let jobID: UUID
    public let expectedRevision: String?
    public let source: String
    public let inputNames: [String]
    public let timeoutSeconds: Int?
    public let fingerprint: String
    public let diagnosticDeniedPaths: [String]
    public let diagnosticAutoexecPositiveControl: Bool
    public let diagnosticSupervisorIdentityWriteFailure: Bool
    public let diagnosticSupervisorIdentityCaptureFailure: Bool
    public let admission: UUID?
    public let admissionDeadline: TimeInterval?

    public init(
        sessionID: UUID,
        jobID: UUID,
        expectedRevision: String?,
        source: String,
        inputNames: [String] = [],
        timeoutSeconds: Int? = nil,
        fingerprint: String,
        diagnosticDeniedPaths: [String] = [],
        diagnosticAutoexecPositiveControl: Bool = false,
        diagnosticSupervisorIdentityWriteFailure: Bool = false,
        diagnosticSupervisorIdentityCaptureFailure: Bool = false,
        admission: UUID? = nil,
        admissionDeadline: TimeInterval? = nil
    ) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.expectedRevision = expectedRevision
        self.source = source
        self.inputNames = inputNames
        self.timeoutSeconds = timeoutSeconds
        self.fingerprint = fingerprint
        self.diagnosticDeniedPaths = diagnosticDeniedPaths
        self.diagnosticAutoexecPositiveControl = diagnosticAutoexecPositiveControl
        self.diagnosticSupervisorIdentityWriteFailure = diagnosticSupervisorIdentityWriteFailure
        self.diagnosticSupervisorIdentityCaptureFailure = diagnosticSupervisorIdentityCaptureFailure
        self.admission = admission
        self.admissionDeadline = admissionDeadline
    }
}

public struct BpyJobReference: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let jobID: UUID

    public init(sessionID: UUID, jobID: UUID) {
        self.sessionID = sessionID
        self.jobID = jobID
    }
}

public struct BpyReleaseResourcesRequest: Codable, Sendable {
    public enum Disposition: String, Codable, Sendable { case stagedInputs, transferredResult, abandonedResult }
    public let sessionID: UUID
    public let jobID: UUID
    public let disposition: Disposition
    public let fingerprint: String?
    public let outputs: [BpyOutputDescriptor]

    public init(sessionID: UUID, jobID: UUID, disposition: Disposition,
                fingerprint: String?, outputs: [BpyOutputDescriptor]) {
        self.sessionID = sessionID; self.jobID = jobID; self.disposition = disposition
        self.fingerprint = fingerprint; self.outputs = outputs
    }
}

public struct BpyAuthorizeProcessRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let jobID: UUID
    public let authorizationID: UUID
    public let processIdentifier: Int32
    public let processStartAbsoluteTime: UInt64
    public let processExecutable: String

    public init(
        sessionID: UUID,
        jobID: UUID,
        authorizationID: UUID,
        processIdentifier: Int32,
        processStartAbsoluteTime: UInt64,
        processExecutable: String
    ) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.authorizationID = authorizationID
        self.processIdentifier = processIdentifier
        self.processStartAbsoluteTime = processStartAbsoluteTime
        self.processExecutable = processExecutable
    }
}

public struct BpySessionReference: Codable, Sendable, Equatable {
    public let sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}

public struct BpyConfirmJobRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let jobID: UUID
    public let revision: String
    public let sceneSHA256: String

    public init(sessionID: UUID, jobID: UUID, revision: String, sceneSHA256: String) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.revision = revision
        self.sceneSHA256 = sceneSHA256
    }
}

public struct BpyReadOutputRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let jobID: UUID
    public let name: String
    public let offset: UInt64
    public let maximumBytes: Int

    public init(
        sessionID: UUID,
        jobID: UUID,
        name: String,
        offset: UInt64,
        maximumBytes: Int
    ) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.name = name
        self.offset = offset
        self.maximumBytes = maximumBytes
    }
}

public enum BpyRuntimeJobState: String, Codable, Sendable, Equatable {
    case accepted
    case running
    case awaitingConfirmation
    case confirmed
    case rejected
    case failed
    case cancelled
    case timedOut
    case crashed
    case resourceLimited

    public static func terminal(forStopReason reason: String) -> Self {
        switch reason {
        case "deadline": .timedOut
        case "pressure", "disk", "file-count", "process-count": .resourceLimited
        case "cancelled", "closed": .cancelled
        default: .failed
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .confirmed, .rejected, .failed, .cancelled, .timedOut, .crashed,
             .resourceLimited:
            true
        case .accepted, .running, .awaitingConfirmation:
            false
        }
    }
}

public struct BpyRuntimeIdentity: Codable, Sendable, Equatable {
    public let pythonVersion: String
    public let bpyVersion: String
    public let executable: String
    public let processIdentifier: Int32
    public let serviceProcessIdentifier: Int32

    public init(
        pythonVersion: String,
        bpyVersion: String,
        executable: String,
        processIdentifier: Int32,
        serviceProcessIdentifier: Int32
    ) {
        self.pythonVersion = pythonVersion
        self.bpyVersion = bpyVersion
        self.executable = executable
        self.processIdentifier = processIdentifier
        self.serviceProcessIdentifier = serviceProcessIdentifier
    }
}

public struct BpyRuntimeProgress: Codable, Sendable, Equatable {
    public let sequence: Int
    public let stage: String
    public let fraction: Double

    public init(sequence: Int, stage: String, fraction: Double) {
        self.sequence = sequence
        self.stage = stage
        self.fraction = fraction
    }
}

public struct BpyOutputDescriptor: Codable, Sendable, Equatable {
    public let name: String
    public let byteCount: UInt64
    public let sha256: String
    public let mediaType: String

    public init(name: String, byteCount: UInt64, sha256: String, mediaType: String) {
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
        self.mediaType = mediaType
    }
}

public struct BpyServiceResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var jobID: UUID?
    public var state: BpyRuntimeJobState?
    public var message: String?
    public var runtime: BpyRuntimeIdentity?
    public var progress: [BpyRuntimeProgress]
    public var outputs: [BpyOutputDescriptor]
    public var confirmedRevision: String?
    public var joinedExistingJob: Bool
    public var stdout: String?
    public var metrics: [String: Double]
    public var jobFingerprint: String?
    public var resultExpired: Bool
    public var activeProcessIdentifier: Int32?
    public var activeProcessStartAbsoluteTime: UInt64?
    public var activeProcessExecutable: String?
    public var activeProcessAuthorizationID: UUID?
    public var activeWorkerProcessIdentifier: Int32?
    public var storagePreparation: BpyStoragePreparation?
    public var firstRelease: TimeInterval?
    public var runningDeadline: TimeInterval?
    public var terminalCommit: TimeInterval?

    public init(
        ok: Bool,
        jobID: UUID? = nil,
        state: BpyRuntimeJobState? = nil,
        message: String? = nil,
        runtime: BpyRuntimeIdentity? = nil,
        progress: [BpyRuntimeProgress] = [],
        outputs: [BpyOutputDescriptor] = [],
        confirmedRevision: String? = nil,
        joinedExistingJob: Bool = false,
        stdout: String? = nil,
        metrics: [String: Double] = [:],
        jobFingerprint: String? = nil,
        resultExpired: Bool = false,
        activeProcessIdentifier: Int32? = nil,
        activeProcessStartAbsoluteTime: UInt64? = nil,
        activeProcessExecutable: String? = nil,
        activeProcessAuthorizationID: UUID? = nil,
        activeWorkerProcessIdentifier: Int32? = nil,
        storagePreparation: BpyStoragePreparation? = nil,
        firstRelease: TimeInterval? = nil, runningDeadline: TimeInterval? = nil, terminalCommit: TimeInterval? = nil
    ) {
        self.ok = ok
        self.jobID = jobID
        self.state = state
        self.message = message
        self.runtime = runtime
        self.progress = progress
        self.outputs = outputs
        self.confirmedRevision = confirmedRevision
        self.joinedExistingJob = joinedExistingJob
        self.stdout = stdout
        self.metrics = metrics
        self.jobFingerprint = jobFingerprint
        self.resultExpired = resultExpired
        self.activeProcessIdentifier = activeProcessIdentifier
        self.activeProcessStartAbsoluteTime = activeProcessStartAbsoluteTime
        self.activeProcessExecutable = activeProcessExecutable
        self.activeProcessAuthorizationID = activeProcessAuthorizationID
        self.activeWorkerProcessIdentifier = activeWorkerProcessIdentifier
        self.storagePreparation = storagePreparation
        self.firstRelease = firstRelease; self.runningDeadline = runningDeadline; self.terminalCommit = terminalCommit
    }
}
