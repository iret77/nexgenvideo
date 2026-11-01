import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyReceiptLifetimeTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var awake = 100.0
        func read() -> BpyClockReading { lock.withLock { .init(awake: awake, continuous: awake) } }
        func advance(to value: TimeInterval) { lock.withLock { awake = value } }
    }

    @Test func callerForgetKeepsTheOriginalReceiptUntilEveryHostReaderReleases() throws {
        let clock = Clock()
        let memory = BpyMemoryCoordinator(sensor: { .init(level: .normal, error: nil, permanent: false) }, clock: clock.read)
        let owner = UUID(), generation = UUID()
        try memory.register(owner: owner, generation: generation)
        let admission = try memory.admit(owner: owner, generation: generation, transport: UUID(), job: UUID(),
            kind: .job, timeout: 30, cancellation: .init())
        defer { memory.close(owner: owner); memory.finish(admission.id); memory.forget(admission.id); memory.retire(owner: owner) }
        try memory.prepareLaunch(admission.id)
        try memory.retainHostReplies(admission.id)
        try memory.retainHostReplies(admission.id)
        #expect(memory.cleanupDeadline(for: admission.transport) == nil)
        defer { memory.releaseHostReplies(admission.id); memory.releaseHostReplies(admission.id) }
        clock.advance(to: 100.1)
        let released = try memory.releaseChild(admission.id, child: .worker, release: {})
        clock.advance(to: 100.2)
        memory.cancel(admission.id, reason: .transportLost)
        #expect(memory.cleanupDeadline(for: admission.transport) == 105.2)
        memory.forget(admission.id)
        let stopping = try memory.receipt(admission.id)
        #expect(!stopping.cleanupComplete)
        clock.advance(to: 100.3)
        memory.childExited(admission.id)
        memory.launchEnded(admission.id)
        memory.finish(admission.id)
        let finished = try memory.receipt(admission.id)
        #expect(finished.identity == admission)
        #expect(finished.firstRelease == released.firstRelease)
        #expect(finished.stop == .transportLost)
        #expect(finished.cleanupStarted == stopping.cleanupStarted)
        #expect(finished.cleanupComplete && finished.cleanupFinishedAt == 100.3)
        #expect(memory.cleanupDeadline(for: admission.transport) == 105.2)
        memory.releaseHostReplies(admission.id)
        #expect(try memory.receipt(admission.id).cleanupFinishedAt == finished.cleanupFinishedAt)
        memory.releaseHostReplies(admission.id)
        #expect(throws: BpyAdmissionFailure.closed) { try memory.receipt(admission.id) }
        #expect(memory.cleanupDeadline(for: admission.transport) == nil)
    }

    @Test func hostReleaseBeforeCallerForgetDoesNotRetireTheCallerReceipt() throws {
        let clock = Clock()
        let memory = BpyMemoryCoordinator(sensor: { .init(level: .normal, error: nil, permanent: false) }, clock: clock.read)
        let owner = UUID(), generation = UUID()
        try memory.register(owner: owner, generation: generation)
        let admission = try memory.admit(owner: owner, generation: generation, transport: UUID(), job: UUID(),
            kind: .job, timeout: 30, cancellation: .init())
        defer { memory.close(owner: owner); memory.finish(admission.id); memory.forget(admission.id); memory.retire(owner: owner) }
        try memory.retainHostReplies(admission.id)
        defer { memory.releaseHostReplies(admission.id) }
        memory.finish(admission.id)
        let original = try memory.receipt(admission.id)
        memory.releaseHostReplies(admission.id)
        let retained = try memory.receipt(admission.id)
        #expect(retained.identity == original.identity)
        #expect(retained.cleanupComplete && retained.cleanupFinishedAt == original.cleanupFinishedAt)
        memory.forget(admission.id)
        #expect(throws: BpyAdmissionFailure.closed) { try memory.receipt(admission.id) }
        #expect(throws: BpyAdmissionFailure.closed) { try memory.retainHostReplies(admission.id) }
    }
}
