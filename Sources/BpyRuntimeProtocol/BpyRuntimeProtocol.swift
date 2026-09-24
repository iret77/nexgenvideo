import Foundation

public let bpyRuntimeServiceNames = [
    "de.h5ventures.nexgenvideo.bpy-service-0",
    "de.h5ventures.nexgenvideo.bpy-service-1",
]

@objc public protocol BpyRuntimeServiceProtocol {
    func openSession(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func stageInput(_ request: Data, chunk: Data, withReply reply: @escaping (Data) -> Void)
    func runJob(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func jobStatus(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func readOutput(_ request: Data, withReply reply: @escaping (Data, Data) -> Void)
    func confirmJob(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func cancelJob(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func closeSession(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func shutdown(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public struct BpyRuntimeLimits: Codable, Sendable, Equatable {
    public var timeoutSeconds: Int
    public var memoryBytes: UInt64
    public var inputBytes: UInt64
    public var outputBytes: UInt64
    public var stdoutBytes: Int
    public var objects: Int
    public var vertices: Int
    public var polygons: Int

    public init(
        timeoutSeconds: Int = 120,
        memoryBytes: UInt64 = 6 * 1_024 * 1_024 * 1_024,
        inputBytes: UInt64 = 512 * 1_024 * 1_024,
        outputBytes: UInt64 = 512 * 1_024 * 1_024,
        stdoutBytes: Int = 1_048_576,
        objects: Int = 20_000,
        vertices: Int = 20_000_000,
        polygons: Int = 20_000_000
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.memoryBytes = memoryBytes
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
        self.stdoutBytes = stdoutBytes
        self.objects = objects
        self.vertices = vertices
        self.polygons = polygons
    }

    public var isValid: Bool {
        (1...3_600).contains(timeoutSeconds)
            && (256 * 1_024 * 1_024...32 * 1_024 * 1_024 * 1_024).contains(memoryBytes)
            && inputBytes > 0 && inputBytes <= 512 * 1_024 * 1_024
            && outputBytes > 0 && outputBytes <= 512 * 1_024 * 1_024
            && (1...16 * 1_024 * 1_024).contains(stdoutBytes)
            && objects > 0 && vertices > 0 && polygons > 0
    }
}

public struct BpyOpenSessionRequest: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let documentID: String
    public let confirmedRevision: String?
    public let limits: BpyRuntimeLimits

    public init(
        sessionID: UUID,
        documentID: String,
        confirmedRevision: String? = nil,
        limits: BpyRuntimeLimits = .init()
    ) {
        self.sessionID = sessionID
        self.documentID = documentID
        self.confirmedRevision = confirmedRevision
        self.limits = limits
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

    public init(
        sessionID: UUID,
        jobID: UUID,
        expectedRevision: String?,
        source: String,
        inputNames: [String] = [],
        timeoutSeconds: Int? = nil
    ) {
        self.sessionID = sessionID
        self.jobID = jobID
        self.expectedRevision = expectedRevision
        self.source = source
        self.inputNames = inputNames
        self.timeoutSeconds = timeoutSeconds
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

    public var isTerminal: Bool {
        switch self {
        case .confirmed, .rejected, .failed, .cancelled, .timedOut, .crashed:
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
    public let sandboxed: Bool
    public let processIdentifier: Int32

    public init(
        pythonVersion: String,
        bpyVersion: String,
        executable: String,
        sandboxed: Bool,
        processIdentifier: Int32
    ) {
        self.pythonVersion = pythonVersion
        self.bpyVersion = bpyVersion
        self.executable = executable
        self.sandboxed = sandboxed
        self.processIdentifier = processIdentifier
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
    public var state: BpyRuntimeJobState?
    public var message: String?
    public var runtime: BpyRuntimeIdentity?
    public var progress: [BpyRuntimeProgress]
    public var outputs: [BpyOutputDescriptor]
    public var confirmedRevision: String?
    public var joinedExistingJob: Bool
    public var stdout: String?
    public var metrics: [String: Double]

    public init(
        ok: Bool,
        state: BpyRuntimeJobState? = nil,
        message: String? = nil,
        runtime: BpyRuntimeIdentity? = nil,
        progress: [BpyRuntimeProgress] = [],
        outputs: [BpyOutputDescriptor] = [],
        confirmedRevision: String? = nil,
        joinedExistingJob: Bool = false,
        stdout: String? = nil,
        metrics: [String: Double] = [:]
    ) {
        self.ok = ok
        self.state = state
        self.message = message
        self.runtime = runtime
        self.progress = progress
        self.outputs = outputs
        self.confirmedRevision = confirmedRevision
        self.joinedExistingJob = joinedExistingJob
        self.stdout = stdout
        self.metrics = metrics
    }
}
