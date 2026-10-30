import AVFoundation
import BpyRuntimeProtocol
import Darwin
import Foundation

enum BpyMediaCancellationAcceptance {
    private final class DecodeAttempt: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var outcome: (String, TimeInterval, Bool)?
        func finish(_ failure: String, decoded: Bool) {
            lock.withLock { outcome = (failure, BpyRuntimeClock.read()?.awake ?? -1, decoded) }
            completed.signal()
        }
        func value() -> (String, TimeInterval, Bool)? { lock.withLock { outcome } }
    }

    static func run(session: BpyRuntimeSession) throws -> [String: Any] {
        let context = try session.nativeMediaContext()
        try context.memory.beginSelftest(owner: context.owner)
        defer { context.memory.endSelftest(owner: context.owner) }
        let token = BpyOperationCancellation()
        defer { token.cancel() }
        let work = try session.consumerWork(cancellation: token)
        defer { work.release() }
        let media = try BpyGeneratedMedia(slot: context.slot, owner: context.owner, limits: context.limits,
            filename: "native-critical.mov", width: 64, height: 64)
        defer { media.abandon() }
        let writer = try AVAssetWriter(outputURL: media.url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        guard writer.canAdd(input) else { throw SpatialSceneError.changed }
        writer.add(input)
        let lifetime = try BpyMediaWriter(writer: writer, pin: media.retainForIO(), cancellation: token, work: work)
        defer { lifetime.requestCancel() }
        guard try lifetime.perform({ writer.startWriting() }) else { throw writer.error ?? SpatialSceneError.changed }
        try lifetime.perform { writer.startSession(atSourceTime: .zero) }
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
              let pixel, CVPixelBufferLockBaseAddress(pixel, []) == kCVReturnSuccess else { throw SpatialSceneError.changed }
        guard let bytes = CVPixelBufferGetBaseAddress(pixel) else {
            CVPixelBufferUnlockBaseAddress(pixel, []); throw SpatialSceneError.changed
        }
        memset(bytes, 0x7f, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let deadline = try BpyRuntimeClock.awakeSeconds() + 30
        while !input.isReadyForMoreMediaData {
            try work.check()
            guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw BpyRuntimeError.timedOut }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard try lifetime.perform({ adaptor.append(pixel, withPresentationTime: .zero) }), writer.status == .writing else {
            throw writer.error ?? SpatialSceneError.changed
        }
        let statusBefore = status(writer.status)
        media.abandon()
        let owned = try media.diagnosticState()
        let charges = BpyRetentionLedger.shared.snapshot.filter { owned.reservations.contains($0.id) }
        var file = stat()
        guard owned.writers == 1, owned.abandoned, charges.count == 2,
              Set(charges.map(\.kind)) == [.retained, .transfer],
              charges.allSatisfy({ $0.owner == context.owner && $0.bytes == context.limits.outputBytes }),
              lstat(media.url.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG else { throw SpatialSceneError.changed }
        let event = try context.memory.selftestCriticalEvent(owner: context.owner)
        var cleanup = try lifetime.diagnosticCleanup()
        while cleanup.settled == nil {
            guard let requested = cleanup.requested, try BpyRuntimeClock.awakeSeconds() <= requested + 5 else {
                throw BpyAdmissionFailure.cleanupFailed
            }
            Thread.sleep(forTimeInterval: 0.005)
            cleanup = try lifetime.diagnosticCleanup()
        }
        guard let requested = cleanup.requested, let settled = cleanup.settled,
              requested >= event.awake, requested - event.awake <= 0.25,
              settled >= requested, settled - requested <= 5, writer.status == .cancelled else { throw SpatialSceneError.changed }
        while BpyRetentionLedger.shared.snapshot.contains(where: { owned.reservations.contains($0.id) }) {
            guard try BpyRuntimeClock.awakeSeconds() <= requested + 5 else { throw BpyAdmissionFailure.cleanupFailed }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard try media.diagnosticState().writers == 0, lstat(media.url.path, &file) != 0, errno == ENOENT else { throw SpatialSceneError.changed }
        let disposedAt = try BpyRuntimeClock.awakeSeconds()
        do { try work.check(); throw SpatialSceneError.changed }
        catch let stop as BpyExecutionInterruption where stop.reason == .pressure { }
        let encoder: [String: Any] = ["synthetic": true, "criticalObservedAt": event.awake,
            "stopRequestedAt": requested, "cancelSettledAt": settled, "width": 64, "height": 64,
            "framesAppended": 1, "statusBefore": statusBefore,
            "statusAfter": status(writer.status), "fileRetainedWhileWriting": true, "stop": "pressure",
            "owner": context.owner.uuidString, "slot": context.slot,
            "writerOwnersBefore": owned.writers, "writerOwnersAfter": 0,
            "chargedBefore": charges.map { ["id": $0.id.uuidString, "kind": $0.kind.rawValue, "bytes": $0.bytes] as [String: Any] },
            "chargedAfter": 0, "disposedAt": disposedAt]
        context.memory.endSelftest(owner: context.owner)
        let blocker = try BpyMediaDecode.diagnosticBlock()
        defer { BpyMediaDecode.diagnosticRelease(blocker) }
        let blocked = try BpyMediaDecode.diagnosticState()
        let queuedToken = BpyOperationCancellation(), attempt = DecodeAttempt()
        defer { queuedToken.cancel() }
        DispatchQueue.global(qos: .userInitiated).async {
            var decoded = false
            do {
                try BpyMediaDecode.withPixels(width: 64, height: 64, encodedBytes: 1,
                    owner: context.owner, slot: context.slot, cancellation: queuedToken,
                    checking: { attempt.entered.signal() }) { decoded = true }
                attempt.finish("unexpected-success", decoded: decoded)
            } catch let failure as BpyAdmissionFailure { attempt.finish(failure.rawValue, decoded: decoded) }
            catch { attempt.finish("unexpected-error", decoded: decoded) }
        }
        guard attempt.entered.wait(timeout: .now() + 2) == .success else { throw BpyRuntimeError.timedOut }
        let waiting = try BpyMediaDecode.diagnosticState()
        guard blocked.used > 0, blocked.queued == 0, waiting.used == blocked.used, waiting.queued == 1 else { throw SpatialSceneError.changed }
        let cancelled = try BpyRuntimeClock.awakeSeconds()
        queuedToken.cancel()
        guard attempt.completed.wait(timeout: .now() + 0.05) == .success,
              let outcome = attempt.value(), outcome.0 == "cancelled", !outcome.2,
              outcome.1 >= cancelled, outcome.1 - cancelled <= 0.05 else { throw SpatialSceneError.changed }
        let after = try BpyMediaDecode.diagnosticState()
        guard after.queued == 0, after.used == blocked.used else { throw SpatialSceneError.changed }
        return ["schema": "nexgenvideo/bpy-native-media-cancellation/1", "encoder": encoder,
            "queuedDecode": ["cancelledAt": cancelled, "completedAt": outcome.1, "failure": outcome.0,
                "decoded": outcome.2, "queuedBefore": waiting.queued, "queuedAfter": after.queued,
                "capacityHeldBefore": blocked.used, "capacityHeldAfter": after.used] as [String: Any]]
    }

    private static func status(_ value: AVAssetWriter.Status) -> String {
        switch value {
        case .unknown: "unknown"
        case .writing: "writing"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        @unknown default: "unrecognized"
        }
    }
}
