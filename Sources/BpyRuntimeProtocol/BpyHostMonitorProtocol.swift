import Foundation

@objc public protocol BpyHostMonitorProtocol {
    func inspect(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public struct BpyMonitorRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case attach, sample, detach }
    public let transport: UUID
    public let execution: UUID
    public let operation: Operation
    public let epoch: UUID?
    public let sequence: UInt64
    public let supervisorPID: Int32

    public init(transport: UUID, execution: UUID, operation: Operation, epoch: UUID? = nil,
                sequence: UInt64 = 0, supervisorPID: Int32) {
        self.transport = transport; self.execution = execution; self.operation = operation
        self.epoch = epoch; self.sequence = sequence; self.supervisorPID = supervisorPID
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
    public enum Status: String, Codable, Sendable { case attached, observed, detached, gone, refused }
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

    public init(status: Status, request: BpyMonitorRequest, epoch: UUID? = nil,
                service: BpyObservedProcess? = nil, supervisor: BpyObservedProcess? = nil,
                descendants: [BpyObservedProcess] = [], worker: BpyObservedProcess? = nil,
                vnodes: [BpyObservedVnode] = [], ended: [BpyObservedProcess] = [], errorCode: Int32 = 0) {
        self.status = status; transport = request.transport; execution = request.execution
        self.epoch = epoch; sequence = request.sequence; self.service = service
        self.supervisor = supervisor; self.descendants = descendants; self.worker = worker
        self.vnodes = vnodes; self.ended = ended; self.errorCode = errorCode
    }
}
