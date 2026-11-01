import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyTerminalSettlementTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var awake = 100.0
        func read() -> BpyClockReading { lock.withLock { .init(awake: awake, continuous: awake) } }
        func advance(to value: TimeInterval) { lock.withLock { awake = value } }
    }

    private struct Fixture {
        let clock: Clock
        let memory: BpyMemoryCoordinator
        let admission: BpyAdmissionIdentity

        init() throws {
            let clock = Clock()
            self.clock = clock
            memory = .init(sensor: { .init(level: .normal, error: nil, permanent: false) }, clock: clock.read)
            let owner = UUID(), generation = UUID()
            try memory.register(owner: owner, generation: generation)
            admission = try memory.admit(owner: owner, generation: generation, transport: UUID(), job: UUID(),
                kind: .job, timeout: 30, cancellation: .init())
        }

        func prepare(released: Bool = false) throws {
            try memory.prepareLaunch(admission.id)
            if released {
                clock.advance(to: 100.1)
                _ = try memory.releaseChild(admission.id, child: .worker, release: {})
            }
        }

        func stop(_ reason: BpyMemoryStop, finished: Bool = true) throws -> BpyMemoryCoordinator.PermitReceipt {
            clock.advance(to: 100.2)
            memory.cancel(admission.id, reason: reason)
            if finished { finishCleanup() }
            return try memory.receipt(admission.id)
        }

        func finishCleanup() {
            clock.advance(to: 100.3)
            memory.childExited(admission.id)
            memory.launchEnded(admission.id)
            memory.finish(admission.id)
        }

        func cleanup() {
            memory.close(owner: admission.owner)
            memory.childExited(admission.id)
            memory.launchEnded(admission.id)
            memory.finish(admission.id)
            memory.forget(admission.id)
            memory.retire(owner: admission.owner)
        }

        func reply(_ state: BpyRuntimeJobState) -> BpyServiceResponse {
            .init(ok: true, jobID: admission.job, state: state, message: "job exceeded the launchFailed limit")
        }
    }

    @Test func acceptedLaunchFailureBeforeReleaseSettlesFailedAfterCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.prepare()
        let pending = try fixture.stop(.launchFailed, finished: false)
        #expect(!pending.cleanupComplete)
        #expect(throws: BpyAdmissionFailure.launchFailed) {
            try BpyTerminalPollState.settle(fixture.reply(.resourceLimited), receipt: pending, timeout: 30)
        }
        fixture.finishCleanup()
        let receipt = try fixture.memory.receipt(fixture.admission.id)
        #expect(receipt.failure == nil && receipt.grantedAt != nil)
        #expect(receipt.firstRelease == nil && receipt.releases.isEmpty)
        #expect(receipt.stop == .launchFailed && receipt.cleanupStarted != nil && receipt.cleanupComplete)
        for state in [BpyRuntimeJobState.resourceLimited, .failed] {
            let result = try BpyTerminalPollState.settle(fixture.reply(state), receipt: receipt, timeout: 30)
            #expect(result.state == .failed && result.state != .resourceLimited)
            #expect(result.outputs.isEmpty)
            #expect(result.message == BpyAdmissionFailure.launchFailed.errorDescription)
        }
    }

    @Test func preReleaseEnvironmentStopsAndUnlaunchedLaunchFailureStillThrow() throws {
        let cases: [(BpyMemoryStop, BpyAdmissionFailure)] = [
            (.pressure, .pressure), (.monitorUnavailable, .sensorUnavailable),
            (.monitorUnresponsive, .sensorUnresponsive), (.transportLost, .transportLost),
            (.deadline, .timedOut), (.closed, .closed), (.cancelled, .cancelled), (.cleanupFailed, .cleanupFailed),
        ]
        for (reason, failure) in cases {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.prepare()
            let receipt = try fixture.stop(reason)
            #expect(receipt.failure == nil && receipt.firstRelease == nil)
            #expect(throws: failure) {
                try BpyTerminalPollState.settle(fixture.reply(.failed), receipt: receipt, timeout: 30)
            }
        }
        let unlaunched = try Fixture()
        defer { unlaunched.cleanup() }
        let receipt = try unlaunched.stop(.launchFailed)
        #expect(receipt.failure == .launchFailed && receipt.stop == nil && receipt.cleanupComplete)
        #expect(throws: BpyAdmissionFailure.launchFailed) {
            try BpyTerminalPollState.settle(unlaunched.reply(.failed), receipt: receipt, timeout: 30)
        }
    }

    @Test func hostStopClassificationAgreesBetweenServiceAndClient() throws {
        let cases: [(String, BpyRuntimeJobState)] = [
            ("diagnosticMemory", .failed), ("pressure", .resourceLimited), ("monitorUnavailable", .failed),
            ("monitorUnresponsive", .failed), ("deadline", .timedOut), ("serviceStall", .failed),
            ("cancelled", .cancelled), ("closed", .cancelled), ("cleanupFailed", .failed),
            ("diagnosticSafety", .failed), ("executionFailed", .failed), ("launchFailed", .failed),
            ("transportLost", .failed), ("ownershipViolation", .failed), ("orphanedWorker", .failed),
            ("observationFailed", .failed), ("disk", .resourceLimited),
            ("file-count", .resourceLimited), ("process-count", .resourceLimited),
        ]
        for (raw, expected) in cases {
            let reason = try #require(BpyMemoryStop(rawValue: raw))
            let serviceState = BpyRuntimeJobState.terminal(forStopReason: raw)
            #expect(serviceState == expected)
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            try fixture.prepare(released: true)
            let receipt = try fixture.stop(reason)
            var response = fixture.reply(serviceState)
            response.outputs = [.init(name: "untrusted.blend", byteCount: 1,
                                      sha256: String(repeating: "0", count: 64), mediaType: "application/x-blender")]
            let result = try BpyTerminalPollState.settle(response, receipt: receipt, timeout: 30)
            #expect(result.state == serviceState && result.state == expected)
            #expect(result.outputs.isEmpty && receipt.cleanupComplete && receipt.firstRelease != nil)
        }
        for raw in ["", "bogus"] {
            #expect(BpyRuntimeJobState.terminal(forStopReason: raw) == .failed)
        }
    }
}
