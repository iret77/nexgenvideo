import BpyRuntimeProtocol
import Foundation
import Testing

struct BpyProcessAuthorizationsTests {
    @Test func lateAcknowledgementCannotAuthorizeTheNextPhaseOrLoseAnEndedPhase() throws {
        let session = UUID(), job = UUID()
        func request(_ pid: Int32) -> BpyAuthorizeProcessRequest {
            .init(sessionID: session, jobID: job, authorizationID: UUID(), processIdentifier: pid,
                processStartAbsoluteTime: UInt64(pid) * 10, processExecutable: "/host/supervisor")
        }
        let worker = request(10), verifier = request(20), autoexec = request(30)
        var receipts = BpyProcessAuthorizations()
        try receipts.record(worker)
        #expect(try receipts.acknowledge(worker, active: worker.authorizationID))
        try receipts.record(verifier)
        #expect(try !receipts.acknowledge(worker, active: verifier.authorizationID))
        #expect(try receipts.acknowledge(verifier, active: verifier.authorizationID))
        try receipts.record(autoexec)
        #expect(!receipts.canRecord)
        #expect(try !receipts.acknowledge(worker, active: nil))
        #expect(try !receipts.acknowledge(autoexec, active: nil))
        try receipts.record(worker)
        #expect(throws: (any Error).self) { try receipts.record(request(40)) }
        let forged = BpyAuthorizeProcessRequest(sessionID: session, jobID: job, authorizationID: worker.authorizationID,
            processIdentifier: worker.processIdentifier, processStartAbsoluteTime: 999, processExecutable: worker.processExecutable)
        #expect(throws: (any Error).self) { _ = try receipts.acknowledge(forged, active: worker.authorizationID) }
        #expect(throws: (any Error).self) { try receipts.record(forged) }
    }
}
