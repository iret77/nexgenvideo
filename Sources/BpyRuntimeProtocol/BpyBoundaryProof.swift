import Foundation

public struct BpySupervisorWorkerIdentity: Codable, Sendable {
    public let processIdentifier: Int32
    public let startAbsoluteTime: UInt64

    public init(
        processIdentifier: Int32,
        startAbsoluteTime: UInt64
    ) {
        self.processIdentifier = processIdentifier
        self.startAbsoluteTime = startAbsoluteTime
    }
}

public struct BpyBoundaryChildReport: Codable, Sendable {
    public let schema: String
    public let mode: String
    public let processIdentifier: Int32
    public let parentProcessIdentifier: Int32
    public let allowedWriteSucceeded: Bool
    public let outsideWriteDeniedErrno: Int32
    public let forkDeniedErrno: Int32
    public let networkDeniedErrno: Int32
    public let signalDeniedErrnos: [Int32]
    public let resourceBytes: UInt64
    public let retentionDeniedErrno: Int32

    public init(
        schema: String,
        mode: String,
        processIdentifier: Int32,
        parentProcessIdentifier: Int32,
        allowedWriteSucceeded: Bool,
        outsideWriteDeniedErrno: Int32,
        forkDeniedErrno: Int32,
        networkDeniedErrno: Int32,
        signalDeniedErrnos: [Int32],
        resourceBytes: UInt64,
        retentionDeniedErrno: Int32
    ) {
        self.schema = schema
        self.mode = mode
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
        self.allowedWriteSucceeded = allowedWriteSucceeded
        self.outsideWriteDeniedErrno = outsideWriteDeniedErrno
        self.forkDeniedErrno = forkDeniedErrno
        self.networkDeniedErrno = networkDeniedErrno
        self.signalDeniedErrnos = signalDeniedErrnos
        self.resourceBytes = resourceBytes
        self.retentionDeniedErrno = retentionDeniedErrno
    }
}

public struct BpyBoundaryRun: Codable, Sendable {
    public let supervisorProcessIdentifier: Int32
    public let supervisorParentProcessIdentifier: Int32
    public let supervisorStartAbsoluteTime: UInt64
    public let child: BpySupervisorWorkerIdentity
    public let report: BpyBoundaryChildReport
    public let supervisorGone: Bool
    public let childGone: Bool
    public let observedRetainedBytes: UInt64
    public let limitReason: String?
    public let internalLinkedWritableDeduplicated: Bool
    public let retentionDenied: Bool

    public init(
        supervisorProcessIdentifier: Int32,
        supervisorParentProcessIdentifier: Int32,
        supervisorStartAbsoluteTime: UInt64,
        child: BpySupervisorWorkerIdentity,
        report: BpyBoundaryChildReport,
        supervisorGone: Bool,
        childGone: Bool,
        observedRetainedBytes: UInt64,
        limitReason: String?,
        internalLinkedWritableDeduplicated: Bool,
        retentionDenied: Bool
    ) {
        self.supervisorProcessIdentifier = supervisorProcessIdentifier
        self.supervisorParentProcessIdentifier = supervisorParentProcessIdentifier
        self.supervisorStartAbsoluteTime = supervisorStartAbsoluteTime
        self.child = child
        self.report = report
        self.supervisorGone = supervisorGone
        self.childGone = childGone
        self.observedRetainedBytes = observedRetainedBytes
        self.limitReason = limitReason
        self.internalLinkedWritableDeduplicated = internalLinkedWritableDeduplicated
        self.retentionDenied = retentionDenied
    }
}
