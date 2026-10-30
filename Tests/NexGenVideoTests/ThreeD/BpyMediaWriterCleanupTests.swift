import AVFoundation
import BpyRuntimeProtocol
import Foundation
import Testing
@testable import NexGenVideo

struct BpyMediaWriterCleanupTests {
    private final class Writer: BpyMediaWriting, @unchecked Sendable {
        let started = DispatchSemaphore(value: 0), allowCompletion = DispatchSemaphore(value: 0), finishing = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var state = AVAssetWriter.Status.writing
        private var completion: (@Sendable () -> Void)?
        var status: AVAssetWriter.Status { lock.withLock { state } }
        var error: (any Error)? { nil }
        func cancelWriting() {
            started.signal()
            _ = allowCompletion.wait(timeout: .now() + 10)
            lock.withLock { state = .cancelled }
        }
        func finishWriting(_ completion: @escaping @Sendable () -> Void) {
            lock.withLock { self.completion = completion }
            finishing.signal()
        }
        func fireFinish() {
            let action = lock.withLock { let action = completion; completion = nil; return action }
            action?()
        }
    }

    @Test func aSixSecondCancelKeepsItsMediaChargeAndPinWhileAnotherOwnerStarts() async throws {
        let memory = BpyMemoryCoordinator(sensor: { .init(level: .normal, error: nil, permanent: false) })
        let owner = UUID(), otherOwner = UUID(), generation = UUID(), token = BpyOperationCancellation()
        let work = try memory.beginConsumer(owner: owner, cancellation: token), consumerID = work.id
        defer { work.release() }
        let ledger = BpyRetentionLedger(), slot = bpyRuntimeServiceNames[0]
        let limits = BpyRuntimeLimits(outputBytes: 256 * 1_024)
        try ledger.configure(slot: slot, limits: limits)
        let media = try BpyGeneratedMedia(slot: slot, owner: owner, limits: limits,
            filename: "delayed-cancel.mov", width: 64, height: 64, ledger: ledger)
        defer { media.abandon() }
        let bytes = Data("encoder-owned".utf8)
        try bytes.write(to: media.url)
        let backend = Writer()
        defer { backend.allowCompletion.signal() }
        var lifetime: BpyMediaWriter? = try .init(backend: backend, pin: media.retainForIO(), cancellation: token, work: work)
        defer { lifetime?.requestCancel() }
        work.release()
        media.abandon()
        let finishDeadline = try BpyRuntimeClock.awakeSeconds() + 30
        let finishing = Task.detached { [lifetime] in
            guard let lifetime else { throw SpatialSceneError.changed }
            try await lifetime.finish(deadline: finishDeadline, checking: {})
        }
        let writerFinishing = await wait(backend.finishing, until: .now() + 1)
        #expect(writerFinishing == .success)
        token.cancel()
        let writerCancelling = await wait(backend.started, until: .now() + 1)
        #expect(writerCancelling == .success)
        backend.fireFinish()
        try await Task.sleep(for: .seconds(6))
        switch await finishing.result {
        case .success: Issue.record("An in-flight cancellation was completed by the finish callback.")
        case .failure(let failure): #expect((failure as? BpyAdmissionFailure) == .cleanupFailed)
        }
        #expect(ledger.snapshot.count == 2)
        #expect(ledger.snapshot.allSatisfy { $0.bytes == limits.outputBytes })
        #expect(try Data(contentsOf: media.url) == bytes)
        do { try memory.checkConsumer(consumerID); Issue.record("The cleanup overrun was lost.") }
        catch let stop as BpyExecutionInterruption { #expect(stop.reason == .cleanupFailed) }
        try memory.register(owner: otherOwner, generation: generation)
        let admission = try memory.admit(owner: otherOwner, generation: generation, transport: UUID(), job: nil,
            kind: .probe, timeout: 10, cancellation: .init())
        defer { memory.finish(admission.id); memory.forget(admission.id) }
        let other = try memory.beginConsumer(owner: otherOwner, cancellation: .init())
        defer { other.release() }
        try other.check()
        backend.allowCompletion.signal()
        let deadline = try BpyRuntimeClock.awakeSeconds() + 3
        while !ledger.snapshot.isEmpty, try BpyRuntimeClock.awakeSeconds() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ledger.snapshot.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: media.url.path))
        #expect(backend.status == .cancelled)
        lifetime = nil
        do { try memory.checkConsumer(consumerID); Issue.record("The completed consumer retained its scope.") }
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
