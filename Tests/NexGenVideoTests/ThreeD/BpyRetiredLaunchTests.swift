import BpyRuntimeProtocol
import Darwin
import Foundation
import Testing
@testable import NexGenVideo

struct BpyRetiredLaunchTests {
    private struct Fixture {
        let transport = UUID(), execution = UUID(), epoch = UUID()
        let service = BpyObservedProcess(pid: 10, start: 100, parent: 1, executable: "/service", footprint: 1)
        let supervisor = BpyObservedProcess(pid: 20, start: 200, parent: 1, executable: "/supervisor", footprint: 1)
        let spec: BpyHostLaunchSpec
        let replay: BpyLaunchReplay
        let detached: BpyMonitorRequest
        let response: BpyMonitorResponse
        let record: BpyRetiredLaunch

        init(authorized: Bool = true) throws {
            spec = .init(permit: UUID(), job: nil, mode: .probe, workerLease: UUID(), dataLease: UUID(),
                workerRoot: "session/probe", configuration: "session/probe.json",
                configurationSHA256: String(repeating: "a", count: 64), readFiles: [])
            replay = .init(epoch: epoch, transport: transport, execution: execution, service: service, supervisor: supervisor)
            detached = .init(transport: transport, execution: execution, operation: .detach, epoch: epoch, sequence: 1, supervisorPID: 20)
            response = .init(status: .detached, request: detached, epoch: epoch, service: service,
                ended: authorized ? [supervisor, .init(pid: 30, start: 300, parent: 20, executable: "/python", footprint: 1)] : [supervisor],
                exitStatus: 0, stage: .childReady, firstRelease: authorized ? 1 : nil, outputComplete: true)
            _ = try replay.begin(detached, peer: service)
            try replay.complete(response, request: detached)
            record = try .init(spec: spec, service: service, supervisor: supervisor, authorized: authorized, replay: replay, response: response)
        }

        func request(_ operation: BpyMonitorRequest.Operation, sequence: UInt64, offset: UInt64 = 0) -> BpyMonitorRequest {
            .init(transport: transport, execution: execution, operation: operation, epoch: epoch,
                sequence: sequence, supervisorPID: 20, outputOffset: offset)
        }
    }

    @Test func detachReplaysItsKernelReceiptAndARefusalDoesNotWedgeTheNextExchange() throws {
        let fixture = try Fixture(), memory = BpyMemoryCoordinator()
        let replayed = try fixture.record.inspect(fixture.detached, peer: fixture.service, memory: memory)
        #expect(replayed.status == .detached && replayed.ended == fixture.response.ended)
        let invalid = fixture.request(.sample, sequence: 2, offset: 1)
        let refused = try fixture.record.inspect(invalid, peer: fixture.service, memory: memory)
        #expect(refused.status == .refused && refused.errorCode == EINVAL)
        let repeated = try fixture.record.inspect(invalid, peer: fixture.service, memory: memory)
        #expect(repeated.status == .refused && repeated.errorCode == refused.errorCode && repeated.sequence == refused.sequence)
        let next = try fixture.record.inspect(fixture.request(.detach, sequence: 3), peer: fixture.service, memory: memory)
        #expect(next.status == .detached && next.outputComplete && next.ended == fixture.response.ended)
        #expect(next.exitStatus == 0 && next.stage == .childReady && next.firstRelease == 1)
    }

    @Test func retiredIdentityRejectsForeignPeersRawPIDsAndChangedLaunchSpecs() throws {
        let fixture = try Fixture(), memory = BpyMemoryCoordinator()
        let request = fixture.request(.sample, sequence: 2)
        let foreign = BpyObservedProcess(pid: 10, start: 101, parent: 1, executable: "/service", footprint: 1)
        #expect(throws: POSIXError.self) { _ = try fixture.record.inspect(request, peer: foreign, memory: memory) }
        #expect(throws: POSIXError.self) { _ = try fixture.record.authorize(pid: 30, start: 300) }
        #expect(try fixture.record.authorize(pid: 20, start: 200))
        let launch = BpyMonitorRequest(transport: fixture.transport, execution: fixture.execution, operation: .launch, launch: fixture.spec)
        #expect(try fixture.record.launch(launch, spec: fixture.spec, peer: fixture.service).status == .gone)
        let changed = BpyHostLaunchSpec(permit: fixture.spec.permit, job: nil, mode: .probe,
            workerLease: fixture.spec.workerLease, dataLease: fixture.spec.dataLease, workerRoot: fixture.spec.workerRoot,
            configuration: "different.json", configurationSHA256: fixture.spec.configurationSHA256, readFiles: [])
        #expect(throws: POSIXError.self) { _ = try fixture.record.launch(launch, spec: changed, peer: fixture.service) }
        #expect(try fixture.record.inspect(request, peer: fixture.service, memory: memory).status == .gone)
    }

    @Test func compactionCannotDiscardUnacknowledgedOutput() throws {
        let fixture = try Fixture()
        let unread = BpyMonitorResponse(status: .detached, request: fixture.detached, epoch: fixture.epoch,
            service: fixture.service, ended: fixture.response.ended, exitStatus: 0,
            stdout: Data("unacknowledged".utf8), outputComplete: true)
        #expect(throws: POSIXError.self) {
            _ = try BpyRetiredLaunch(spec: fixture.spec, service: fixture.service, supervisor: fixture.supervisor,
                authorized: true, replay: fixture.replay, response: unread)
        }
    }

    @Test func anEndedUnreleasedGateDefersItsOwnedIdentityButRejectsAForgedIdentity() throws {
        let fixture = try Fixture(authorized: false)
        #expect(try !fixture.record.authorize(pid: 20, start: 200))
        #expect(throws: POSIXError.self) { _ = try fixture.record.authorize(pid: 20, start: 201) }
        #expect(throws: POSIXError.self) { _ = try fixture.record.authorize(pid: 30, start: 300) }
    }
}
