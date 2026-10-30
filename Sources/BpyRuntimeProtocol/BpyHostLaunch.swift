import Foundation

public enum BpyLaunchMode: String, Codable, Sendable {
    case probe, job, verify
    case autoexecPositive = "autoexec-positive"
    case boundary
}

public enum BpyBoundaryMode: String, Codable, Sendable {
    case denials
    case diagnosticFootprint = "diagnostic-footprint"
    case diagnosticFootprintAfterExec = "diagnostic-footprint-after-exec"
    case diagnosticVirtualMapping = "diagnostic-virtual-mapping"
    case diagnosticPressureWait = "diagnostic-pressure-wait"
    case diagnosticPythonFootprint = "diagnostic-python-footprint"
    case diagnosticStdoutBurst = "diagnostic-stdout-burst"

    public var isMemoryDiagnostic: Bool {
        [.diagnosticFootprint, .diagnosticFootprintAfterExec, .diagnosticVirtualMapping, .diagnosticPressureWait, .diagnosticPythonFootprint].contains(self)
    }
    public var isFootprintDiagnostic: Bool {
        [.diagnosticFootprint, .diagnosticFootprintAfterExec, .diagnosticPythonFootprint].contains(self)
    }
    public var isHostDiagnostic: Bool { isMemoryDiagnostic || self == .diagnosticStdoutBurst }
    case openUnlinked = "open-unlinked-hold"
    case readonlyUnlinked = "readonly-unlinked-hold"
    case mappedUnlinked = "mapped-unlinked-hold"
    case externalReadonly = "external-readonly-hold"
    case internalWritable = "internal-linked-writable-hold"
    case fileportUnlinked = "fileport-unlinked-hold"
}

public enum BpyLaunchInjection: String, Codable, Sendable {
    case failAfterChildStart, failChildIdentityCapture, childIgnoreTerm
}

public struct BpyHostLaunchSpec: Codable, Equatable, Sendable {
    public let schema: String
    public let permit: UUID
    public let job: UUID?
    public let mode: BpyLaunchMode
    public let workerLease: UUID
    public let dataLease: UUID
    public let workerRoot: String
    public let configuration: String
    public let configurationSHA256: String
    public let readFiles: [String]
    public let workerReadFiles: [String]
    public let boundary: BpyBoundaryMode?
    public let injections: [BpyLaunchInjection]

    public init(permit: UUID, job: UUID?, mode: BpyLaunchMode, workerLease: UUID,
                dataLease: UUID, workerRoot: String, configuration: String, configurationSHA256: String, readFiles: [String],
                workerReadFiles: [String] = [], boundary: BpyBoundaryMode? = nil, injections: [BpyLaunchInjection] = []) {
        schema = "nexgenvideo/bpy-host-launch/2"
        self.permit = permit; self.job = job; self.mode = mode
        self.workerLease = workerLease; self.dataLease = dataLease
        self.workerRoot = workerRoot; self.configuration = configuration
        self.configurationSHA256 = configurationSHA256
        self.readFiles = readFiles; self.boundary = boundary; self.injections = injections
        self.workerReadFiles = workerReadFiles
    }
}

public enum BpyLaunchDescriptors {
    public static let release: Int32 = 199
    public static let report: Int32 = 200
    public static let childRelease: Int32 = 201
    public static let root: Int32 = 202
    public static let configuration: Int32 = 203
    public static let childReport: Int32 = 204
    public static let diagnosticRelease: Int32 = 205
    public static let source: Int32 = 206
}

public enum BpyLaunchStage: Int32, Codable, Sendable {
    case supervisorReady = 0, childReady = 1, diagnosticReady = 2, diagnosticExecReady = 3, virtualMappingSucceeded = 4
    case diagnosticProgress = 5, diagnosticAllocationCap = 6
    case stdoutBurstComplete = 7
    case sandboxUnavailable = 80, sandboxRejected = 81, denialCheckFailed = 82, execFailed = 83
    case invalidLaunch = 84, identityCaptureFailed = 85
}

public struct BpyMappingDiagnostic: Codable, Sendable {
    public let bytes: UInt64
    public let protection: Int32
    public let deallocated: Bool
    public init(bytes: UInt64, protection: Int32, deallocated: Bool) {
        self.bytes = bytes; self.protection = protection; self.deallocated = deallocated
    }
}

public struct BpyStdoutBurst: Codable, Sendable {
    public let flags: Int32
    public let bytes: Int
    public let started: BpyClockReading
    public let finished: BpyClockReading
    public init(flags: Int32, bytes: Int, started: BpyClockReading, finished: BpyClockReading) {
        self.flags = flags; self.bytes = bytes; self.started = started; self.finished = finished
    }
}

public struct BpyStdoutCapture: Codable, Sendable {
    public let burst: BpyStdoutBurst
    public let capturedBytes: UInt64
    public let capturedSHA256: String
    public let paused: BpyClockReading
    public let resumed: BpyClockReading
    public let childReadyWritten: BpyClockReading
    public let childReadyReceived: BpyClockReading
    public init(burst: BpyStdoutBurst, capturedBytes: UInt64, capturedSHA256: String, paused: BpyClockReading,
                resumed: BpyClockReading, childReadyWritten: BpyClockReading, childReadyReceived: BpyClockReading) {
        self.burst = burst; self.capturedBytes = capturedBytes; self.capturedSHA256 = capturedSHA256
        self.paused = paused; self.resumed = resumed; self.childReadyWritten = childReadyWritten; self.childReadyReceived = childReadyReceived
    }
}

public struct BpyLaunchReport: Codable, Sendable {
    public let schema: String
    public let stage: BpyLaunchStage
    public let pid: Int32
    public let requestedBytes: UInt64?
    public let mapping: BpyMappingDiagnostic?
    public let allocationObjectBytes: Int?
    public let clock: BpyClockReading?
    public let stdoutBurst: BpyStdoutBurst?

    public init(stage: BpyLaunchStage, pid: Int32, requestedBytes: UInt64? = nil, mapping: BpyMappingDiagnostic? = nil,
                allocationObjectBytes: Int? = nil, clock: BpyClockReading? = nil, stdoutBurst: BpyStdoutBurst? = nil) {
        schema = "nexgenvideo/bpy-launch-report/1"
        self.stage = stage; self.pid = pid
        self.requestedBytes = requestedBytes
        self.mapping = mapping
        self.allocationObjectBytes = allocationObjectBytes
        self.clock = clock; self.stdoutBurst = stdoutBurst
    }
}

public struct BpySupervisorConfiguration: Codable, Sendable {
    public let schema: String
    public let hostPID: Int32
    public let hostStart: UInt64
    public let mode: BpyLaunchMode
    public let python: String
    public let worker: String
    public let runtime: String
    public let readPaths: [String]
    public let canaryRead: String
    public let canaryWrite: String
    public let boundary: BpyBoundaryMode?
    public let boundaryPath: String?
    public let injections: [BpyLaunchInjection]
    public let environment: [String: String]

    public init(hostPID: Int32, hostStart: UInt64, mode: BpyLaunchMode, python: String,
                worker: String, runtime: String, readPaths: [String], canaryRead: String,
                canaryWrite: String, boundary: BpyBoundaryMode?, boundaryPath: String? = nil, injections: [BpyLaunchInjection],
                environment: [String: String]) {
        schema = "nexgenvideo/bpy-supervisor/2"
        self.hostPID = hostPID; self.hostStart = hostStart; self.mode = mode
        self.python = python; self.worker = worker; self.runtime = runtime; self.readPaths = readPaths
        self.canaryRead = canaryRead; self.canaryWrite = canaryWrite
        self.boundary = boundary; self.injections = injections; self.environment = environment
        self.boundaryPath = boundaryPath
    }
}
