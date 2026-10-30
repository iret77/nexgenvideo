import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyConsumerCleanupTests {
    @Test func delayedHostCleanupRetainsItsOwnerAndAllowsTheOtherSlotToStart() throws {
        let memory = BpyMemoryCoordinator(sensor: { .init(level: .normal, error: nil, permanent: false) },
            clock: { .init(awake: 100, continuous: 100) })
        let token = BpyOperationCancellation(), first = UUID(), second = UUID(), generation = UUID()
        let work = try memory.beginConsumer(owner: first, cancellation: token)
        let cleanup = try work.retained()
        defer { work.release(); cleanup.release() }
        token.cancel()
        cleanup.failCleanup(since: 94)
        work.release()
        do { try cleanup.check(); Issue.record("The retained consumer lost its cleanup state.") }
        catch let interruption as BpyExecutionInterruption { #expect(interruption.reason == .cleanupFailed) }
        try memory.register(owner: second, generation: generation)
        let admission = try memory.admit(owner: second, generation: generation, transport: UUID(), job: nil,
            kind: .probe, timeout: 10, cancellation: .init())
        defer { memory.finish(admission.id); memory.forget(admission.id) }
        #expect(try memory.receipt(admission.id).failure == nil)
        let other = try memory.beginConsumer(owner: second, cancellation: .init())
        defer { other.release() }
        try other.check()
    }
}
