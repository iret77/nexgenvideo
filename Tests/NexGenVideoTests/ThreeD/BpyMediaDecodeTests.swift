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

    @Test func cancellationRemovesTheFIFOHeadWithoutConsumingAnotherWaitersSpace() throws {
        let pool = BpyMediaDecode.Pool(capacity: 6)
        let first = try pool.reserve(4, cancellation: .init(), timeout: 2, checking: {})
        defer { pool.release(first) }
        let head = Attempt(), follower = Attempt(), cancellation = BpyOperationCancellation()
        DispatchQueue.global().async {
            head.finish(Result { try pool.reserve(4, cancellation: cancellation, timeout: 2,
                checking: { head.entered.signal() }) })
        }
        #expect(head.entered.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().async {
            follower.finish(Result { try pool.reserve(2, cancellation: .init(), timeout: 2,
                checking: { follower.entered.signal() }) })
        }
        #expect(follower.entered.wait(timeout: .now() + 1) == .success)
        #expect(follower.completed.wait(timeout: .now() + 0.05) == .timedOut)
        cancellation.cancel()
        #expect(head.completed.wait(timeout: .now() + 1) == .success)
        #expect(throws: BpyAdmissionFailure.self) { _ = try head.value() }
        #expect(follower.completed.wait(timeout: .now() + 1) == .success)
        pool.release(try follower.value())
    }

    @Test func perSlotCapacityWaitsForItsActualOwnerAndTimeoutDoesNotLeakAReservation() throws {
        let pool = BpyMediaDecode.Pool(capacity: 8)
        let first = try pool.reserve(4, slot: "slot-a", slotCapacity: 4, cancellation: .init(), timeout: 2, checking: {})
        let waiting = Attempt()
        DispatchQueue.global().async {
            waiting.finish(Result { try pool.reserve(1, slot: "slot-a", slotCapacity: 4,
                cancellation: .init(), timeout: 0.1, checking: { waiting.entered.signal() }) })
        }
        #expect(waiting.entered.wait(timeout: .now() + 1) == .success)
        #expect(waiting.completed.wait(timeout: .now() + 1) == .success)
        #expect(throws: BpyRuntimeError.self) { _ = try waiting.value() }
        pool.release(first)
        let replacement = try pool.reserve(8, cancellation: .init(), timeout: 2, checking: {})
        pool.release(replacement)
    }
}
