import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyMediaReaderCleanupTests {
    private final class Loader: BpyMediaLoading, @unchecked Sendable {
        let cancelled = DispatchSemaphore(value: 0)
        func cancelLoading() { cancelled.signal() }
    }

    private final class Reader: BpyMediaReading, @unchecked Sendable {
        let cancelling = DispatchSemaphore(value: 0), allowCompletion = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var started = false
        func startReading() throws { lock.withLock { started = true } }
        func cancelReading() {
            cancelling.signal()
            _ = allowCompletion.wait(timeout: .now() + 10)
            returned.signal()
        }
        var wasStarted: Bool { lock.withLock { started } }
    }

    @Test func aSixSecondReaderCancelKeepsItsPinAndFileAfterTheCallingBodyEnds() async throws {
        let memory = BpyMemoryCoordinator(sensor: { .init(level: .normal, error: nil, permanent: false) })
        let owner = UUID(), otherOwner = UUID(), generation = UUID(), token = BpyOperationCancellation()
        let work = try memory.beginConsumer(owner: owner, cancellation: token), consumerID = work.id
        defer { work.release() }
        let ledger = BpyRetentionLedger(), slot = bpyRuntimeServiceNames[0], limits = BpyRuntimeLimits(outputBytes: 256 * 1_024)
        try ledger.configure(slot: slot, limits: limits)
        let media = try BpyGeneratedMedia(slot: slot, owner: owner, limits: limits,
            filename: "reader-cancel.mov", width: 64, height: 64, ledger: ledger)
        defer { media.abandon() }
        let bytes = Data("reader-owned".utf8)
        try bytes.write(to: media.url)
        let asset = Loader(), backend = Reader()
        defer { backend.allowCompletion.signal() }
        let reading = try BpyMediaReader.begin(backend: asset, pin: media.retainForIO(), cancellation: token, work: work)
        try reading.start(backend: backend)
        #expect(backend.wasStarted)
        work.release()
        media.abandon()
        reading.endBody(success: false)
        let assetCancelled = await wait(asset.cancelled, until: .now() + 1)
        #expect(assetCancelled == .success)
        let readerCancelling = await wait(backend.cancelling, until: .now() + 1)
        #expect(readerCancelling == .success)
        try await Task.sleep(for: .seconds(6))
        #expect(ledger.snapshot.count == 2)
        #expect(ledger.snapshot.allSatisfy { $0.bytes == limits.outputBytes })
        #expect(try Data(contentsOf: media.url) == bytes)
        let returnedBeforeRelease = await wait(backend.returned, until: .now())
        #expect(returnedBeforeRelease == .timedOut)
        do { try memory.checkConsumer(consumerID); Issue.record("The reader cleanup overrun was lost.") }
        catch let stop as BpyExecutionInterruption { #expect(stop.reason == .cleanupFailed) }
        try memory.register(owner: otherOwner, generation: generation)
        let admission = try memory.admit(owner: otherOwner, generation: generation, transport: UUID(), job: nil,
            kind: .probe, timeout: 10, cancellation: .init())
        defer { memory.finish(admission.id); memory.forget(admission.id) }
        let other = try memory.beginConsumer(owner: otherOwner, cancellation: .init())
        defer { other.release() }
        try other.check()
        backend.allowCompletion.signal()
        let returnedAfterRelease = await wait(backend.returned, until: .now() + 1)
        #expect(returnedAfterRelease == .success)
        let deadline = try BpyRuntimeClock.awakeSeconds() + 3
        while !ledger.snapshot.isEmpty, try BpyRuntimeClock.awakeSeconds() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ledger.snapshot.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: media.url.path))
        reading.endBody(success: false)
        do { try memory.checkConsumer(consumerID); Issue.record("The completed reader retained its consumer scope.") }
        catch let stop as BpyExecutionInterruption { #expect(stop.reason == .closed) }
        try other.check()
    }

    private func wait(_ semaphore: DispatchSemaphore, until deadline: DispatchTime) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: deadline))
            }
        }
    }
}
