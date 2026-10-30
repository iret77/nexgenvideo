import Foundation
import Testing
@testable import NexGenVideo

struct BpyMediaDecodeTests {
    private final class Attempt: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<UUID, any Error>?
        let entered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        func finish(_ value: Result<UUID, any Error>) { lock.withLock { result = value }; completed.signal() }
        func value() throws -> UUID { try lock.withLock { try #require(result).get() } }
    }

    @Test func cancellationRemovesTheFIFOHeadWithoutConsumingAnotherWaitersSpace() async throws {
        let pool = BpyMediaDecode.Pool(capacity: 6)
        let first = try pool.reserve(4, cancellation: .init(), timeout: 2, checking: {})
        defer { pool.release(first) }
        let head = Attempt(), follower = Attempt(), cancellation = BpyOperationCancellation()
        Thread {
            head.finish(Result { try pool.reserve(4, cancellation: cancellation, timeout: 2,
                checking: { head.entered.signal() }) })
        }.start()
        let headEntered = await waitForBpyTestSignal(head.entered, until: .now() + 1)
        #expect(headEntered == .success)
        Thread {
            follower.finish(Result { try pool.reserve(2, cancellation: .init(), timeout: 2,
                checking: { follower.entered.signal() }) })
        }.start()
        let followerEntered = await waitForBpyTestSignal(follower.entered, until: .now() + 1)
        #expect(followerEntered == .success)
        let followerBeforeCancellation = await waitForBpyTestSignal(follower.completed, until: .now() + 0.05)
        #expect(followerBeforeCancellation == .timedOut)
        cancellation.cancel()
        let headCompleted = await waitForBpyTestSignal(head.completed, until: .now() + 1)
        #expect(headCompleted == .success)
        #expect(throws: BpyAdmissionFailure.self) { _ = try head.value() }
        let followerCompleted = await waitForBpyTestSignal(follower.completed, until: .now() + 1)
        #expect(followerCompleted == .success)
        pool.release(try follower.value())
    }

    @Test func perSlotCapacityWaitsForItsActualOwnerAndTimeoutDoesNotLeakAReservation() async throws {
        let pool = BpyMediaDecode.Pool(capacity: 8)
        let first = try pool.reserve(4, slot: "slot-a", slotCapacity: 4, cancellation: .init(), timeout: 2, checking: {})
        let waiting = Attempt()
        Thread {
            waiting.finish(Result { try pool.reserve(1, slot: "slot-a", slotCapacity: 4,
                cancellation: .init(), timeout: 0.1, checking: { waiting.entered.signal() }) })
        }.start()
        let entered = await waitForBpyTestSignal(waiting.entered, until: .now() + 1)
        #expect(entered == .success)
        let completed = await waitForBpyTestSignal(waiting.completed, until: .now() + 1)
        #expect(completed == .success)
        #expect(throws: BpyRuntimeError.self) { _ = try waiting.value() }
        pool.release(first)
        let replacement = try pool.reserve(8, cancellation: .init(), timeout: 2, checking: {})
        pool.release(replacement)
    }
}
