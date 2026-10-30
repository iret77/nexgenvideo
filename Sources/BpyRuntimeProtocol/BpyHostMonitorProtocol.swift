import Foundation

@objc public protocol BpyHostMonitorProtocol {
    func inspect(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum BpyServiceStopCause: String, Codable, Sendable {
    case cancelled, disk, failure
    case fileCount = "file-count"
    case processCount = "process-count"
}

public struct BpyMonitorRequest: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable { case attach, launch, release, terminate, sample, detach, collecting, commit }
    public let schema: String
    public let transport: UUID
    public let execution: UUID
    public let operation: Operation
    public let epoch: UUID?
    public let sequence: UInt64
    public let supervisorPID: Int32
    public let launch: BpyHostLaunchSpec?
    public let outputOffset: UInt64
    public let stopCause: BpyServiceStopCause?

    public init(transport: UUID, execution: UUID, operation: Operation, epoch: UUID? = nil,
                sequence: UInt64 = 0, supervisorPID: Int32 = 0, launch: BpyHostLaunchSpec? = nil,
                outputOffset: UInt64 = 0, stopCause: BpyServiceStopCause? = nil) {
        schema = "nexgenvideo/bpy-monitor-request/2"
        self.transport = transport; self.execution = execution; self.operation = operation
        self.epoch = epoch; self.sequence = sequence; self.supervisorPID = supervisorPID
        self.launch = launch
        self.outputOffset = outputOffset
        self.stopCause = stopCause
    }
}

public struct BpyObservedProcess: Codable, Sendable, Equatable {
    public let pid: Int32
    public let start: UInt64
    public let parent: Int32
    public let executable: String
    public let footprint: UInt64

    public init(pid: Int32, start: UInt64, parent: Int32, executable: String, footprint: UInt64) {
        self.pid = pid; self.start = start; self.parent = parent
        self.executable = executable; self.footprint = footprint
    }
}

public struct BpyObservedVnode: Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let links: UInt16
    public let openFlags: UInt32?
    public let logical: Int64
    public let blocks: Int64
    public let path: String?

    public init(device: UInt64, inode: UInt64, links: UInt16, openFlags: UInt32?,
                logical: Int64, blocks: Int64, path: String?) {
        self.device = device; self.inode = inode; self.links = links; self.openFlags = openFlags
        self.logical = logical; self.blocks = blocks; self.path = path
    }
}

public struct BpyMonitorResponse: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case attached, launched, released, deferred, observed, detached, gone, refused, committed }
    public let schema: String
    public let status: Status
    public let transport: UUID
    public let execution: UUID
    public let epoch: UUID?
    public let sequence: UInt64
    public let service: BpyObservedProcess?
    public let supervisor: BpyObservedProcess?
    public let descendants: [BpyObservedProcess]
    public let worker: BpyObservedProcess?
    public let vnodes: [BpyObservedVnode]
    public let ended: [BpyObservedProcess]
    public let errorCode: Int32
    public let exitStatus: Int32?
    public let terminationSignal: Int32?
    public let stdout: Data?
    public let stage: BpyLaunchStage?
    public let firstRelease: TimeInterval?
    public let terminalCommit: TimeInterval?
    public let stopReason: String?
    public let nextOutputOffset: UInt64
    public let outputComplete: Bool
    public let admissionDeadline: TimeInterval?
    public let runningDeadline: TimeInterval?
    public let cleanupDeadline: TimeInterval?
    public let stopDeliveredAt: TimeInterval?
    public let diagnosticBaseline: BpyObservedProcess?
    public let diagnosticObserved: BpyObservedProcess?
    public let diagnosticThresholdBytes: UInt64?
    public let diagnosticSafetyBytes: UInt64?
    public let diagnosticChunks: [UInt64]
    public let diagnosticMapping: BpyMappingDiagnostic?
    public let diagnosticAllocationObjectBytes: Int?
    public let diagnosticStdout: BpyStdoutCapture?

    public init(status: Status, request: BpyMonitorRequest, epoch: UUID? = nil,
                service: BpyObservedProcess? = nil, supervisor: BpyObservedProcess? = nil,
                descendants: [BpyObservedProcess] = [], worker: BpyObservedProcess? = nil,
                vnodes: [BpyObservedVnode] = [], ended: [BpyObservedProcess] = [], errorCode: Int32 = 0,
                exitStatus: Int32? = nil, terminationSignal: Int32? = nil, stdout: Data? = nil,
                stage: BpyLaunchStage? = nil, firstRelease: TimeInterval? = nil,
                terminalCommit: TimeInterval? = nil, stopReason: String? = nil,
                nextOutputOffset: UInt64 = 0, outputComplete: Bool = false,
                admissionDeadline: TimeInterval? = nil, runningDeadline: TimeInterval? = nil,
                cleanupDeadline: TimeInterval? = nil, stopDeliveredAt: TimeInterval? = nil, diagnosticBaseline: BpyObservedProcess? = nil,
                diagnosticObserved: BpyObservedProcess? = nil, diagnosticThresholdBytes: UInt64? = nil,
                diagnosticSafetyBytes: UInt64? = nil, diagnosticChunks: [UInt64] = [], diagnosticMapping: BpyMappingDiagnostic? = nil,
                diagnosticAllocationObjectBytes: Int? = nil, diagnosticStdout: BpyStdoutCapture? = nil) {
        schema = "nexgenvideo/bpy-monitor-response/2"
        self.status = status; transport = request.transport; execution = request.execution
        self.epoch = epoch; sequence = request.sequence; self.service = service
        self.supervisor = supervisor; self.descendants = descendants; self.worker = worker
        self.vnodes = vnodes; self.ended = ended; self.errorCode = errorCode
        self.exitStatus = exitStatus; self.terminationSignal = terminationSignal
        self.stdout = stdout; self.stage = stage; self.firstRelease = firstRelease
        self.terminalCommit = terminalCommit; self.stopReason = stopReason
        self.nextOutputOffset = nextOutputOffset; self.outputComplete = outputComplete
        self.admissionDeadline = admissionDeadline; self.runningDeadline = runningDeadline
        self.cleanupDeadline = cleanupDeadline
        self.stopDeliveredAt = stopDeliveredAt
        self.diagnosticBaseline = diagnosticBaseline; self.diagnosticObserved = diagnosticObserved
        self.diagnosticThresholdBytes = diagnosticThresholdBytes
        self.diagnosticSafetyBytes = diagnosticSafetyBytes; self.diagnosticChunks = diagnosticChunks
        self.diagnosticMapping = diagnosticMapping
        self.diagnosticAllocationObjectBytes = diagnosticAllocationObjectBytes
        self.diagnosticStdout = diagnosticStdout
    }
}
