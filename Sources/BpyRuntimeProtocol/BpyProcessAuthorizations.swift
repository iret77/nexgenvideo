import Foundation

public struct BpyProcessAuthorizations: Sendable {
    private var issued: [UUID: BpyAuthorizeProcessRequest] = [:]
    public init() {}
    public var canRecord: Bool { issued.count < 3 }

    public mutating func record(_ request: BpyAuthorizeProcessRequest) throws {
        if let prior = issued[request.authorizationID] {
            guard prior == request else { throw CocoaError(.fileWriteNoPermission) }
            return
        }
        guard canRecord, request.processIdentifier > 1, request.processStartAbsoluteTime > 0,
              !request.processExecutable.isEmpty,
              issued.values.allSatisfy({ $0.sessionID == request.sessionID && $0.jobID == request.jobID }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        issued[request.authorizationID] = request
    }

    public func acknowledge(_ request: BpyAuthorizeProcessRequest, active: UUID?) throws -> Bool {
        guard issued[request.authorizationID] == request else { throw CocoaError(.fileWriteNoPermission) }
        return active == request.authorizationID
    }
}
