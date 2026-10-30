import BpyRuntimeProtocol
import Darwin
import Foundation
@testable import NexGenVideo
import Testing

@Suite("Bpy host launch reply identity")
struct BpyLaunchReplayTests {
    private struct Fixture {
        let transport = UUID(), execution = UUID(), epoch = UUID()
        let service = BpyObservedProcess(pid: 10, start: 100, parent: 1, executable: "/service", footprint: 1)
        let supervisor = BpyObservedProcess(pid: 20, start: 200, parent: 1, executable: "/supervisor", footprint: 1)
        var replay: BpyLaunchReplay { .init(epoch: epoch, transport: transport, execution: execution, service: service, supervisor: supervisor) }
        func request(_ operation: BpyMonitorRequest.Operation, sequence: UInt64, offset: UInt64 = 0) -> BpyMonitorRequest {
            .init(transport: transport, execution: execution, operation: operation, epoch: epoch,
                sequence: sequence, supervisorPID: supervisor.pid, outputOffset: offset)
        }
    }

    @Test func lostSampleReplyReplaysTheSameBytesWithoutConsumingAnotherChunk() throws {
        let f = Fixture(), replay = f.replay
        let request = f.request(.sample, sequence: 1)
        #expect(try replay.begin(request, peer: f.service) == nil)
        let original = BpyMonitorResponse(status: .observed, request: request, epoch: f.epoch,
            service: f.service, supervisor: f.supervisor, stdout: Data("actual bytes".utf8), nextOutputOffset: 12)
        try replay.complete(original, request: request)
        let recovered = try #require(replay.begin(request, peer: f.service))
        #expect(recovered.stdout == original.stdout)
        #expect(recovered.nextOutputOffset == 12 && recovered.sequence == 1)
        #expect(throws: POSIXError.self) { try replay.begin(f.request(.sample, sequence: 1, offset: 12), peer: f.service) }
        #expect(try replay.begin(f.request(.sample, sequence: 2, offset: 12), peer: f.service) == nil)
    }

    @Test func lostDetachReplyKeepsExactEndedIdentitiesAndEpoch() throws {
        let f = Fixture(), replay = f.replay
        let request = f.request(.detach, sequence: 1)
        _ = try replay.begin(request, peer: f.service)
        let original = BpyMonitorResponse(status: .detached, request: request, epoch: f.epoch,
            service: f.service, ended: [f.supervisor], exitStatus: 0, outputComplete: true)
        try replay.complete(original, request: request)
        for _ in 0..<2 {
            let recovered = try #require(replay.begin(request, peer: f.service))
            #expect(recovered.ended == [f.supervisor])
            #expect(recovered.epoch == f.epoch && recovered.supervisor == nil)
        }
        #expect(throws: POSIXError.self) { try replay.begin(f.request(.sample, sequence: 1), peer: f.service) }
    }

    @Test func wrongTransportExecutionEpochSequenceSupervisorAndPeerCannotJoin() throws {
        let f = Fixture()
        let invalid = [
            BpyMonitorRequest(transport: UUID(), execution: f.execution, operation: .sample, epoch: f.epoch, sequence: 1, supervisorPID: 20),
            BpyMonitorRequest(transport: f.transport, execution: UUID(), operation: .sample, epoch: f.epoch, sequence: 1, supervisorPID: 20),
            BpyMonitorRequest(transport: f.transport, execution: f.execution, operation: .sample, epoch: UUID(), sequence: 1, supervisorPID: 20),
            BpyMonitorRequest(transport: f.transport, execution: f.execution, operation: .sample, epoch: f.epoch, sequence: 2, supervisorPID: 20),
            BpyMonitorRequest(transport: f.transport, execution: f.execution, operation: .sample, epoch: f.epoch, sequence: 1, supervisorPID: 30),
        ]
        for request in invalid {
            let replay = f.replay
            #expect(throws: POSIXError.self) { try replay.begin(request, peer: f.service) }
            #expect(try replay.begin(f.request(.sample, sequence: 1), peer: f.service) == nil)
        }
        for peer in [BpyObservedProcess(pid: 10, start: 101, parent: 1, executable: "/service", footprint: 1),
                     BpyObservedProcess(pid: 10, start: 100, parent: 1, executable: "/foreign", footprint: 1)] {
            #expect(throws: POSIXError.self) { try f.replay.begin(f.request(.sample, sequence: 1), peer: peer) }
        }
    }

    @Test func inFlightRetryCannotExecuteTwiceAndFailureReplyIsStable() throws {
        let f = Fixture(), replay = f.replay
        let request = f.request(.commit, sequence: 1)
        _ = try replay.begin(request, peer: f.service)
        #expect(throws: POSIXError.self) { try replay.begin(request, peer: f.service) }
        let failure = BpyMonitorResponse(status: .refused, request: request, epoch: f.epoch, service: f.service, errorCode: ETIMEDOUT)
        try replay.complete(failure, request: request)
        let recovered = try #require(replay.begin(request, peer: f.service))
        #expect(recovered.status == .refused && recovered.errorCode == ETIMEDOUT)
    }
}
