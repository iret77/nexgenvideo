import AVFoundation
import BpyRuntimeProtocol
import Foundation

nonisolated protocol BpyMediaWriting: AnyObject, Sendable {
    var status: AVAssetWriter.Status { get }
    var error: (any Error)? { get }
    func cancelWriting()
    func finishWriting(_ completion: @escaping @Sendable () -> Void)
}

nonisolated private final class BpyAssetWriting: BpyMediaWriting, @unchecked Sendable {
    private let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) { self.writer = writer }
    var status: AVAssetWriter.Status { writer.status }
    var error: (any Error)? { writer.error }
    func cancelWriting() { writer.cancelWriting() }
    func finishWriting(_ completion: @escaping @Sendable () -> Void) { writer.finishWriting(completionHandler: completion) }
}

nonisolated final class BpyMediaFilePin: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func release() {
        let action = lock.withLock { let value = self.action; self.action = nil; return value }
        action?()
    }
    deinit { release() }
}

nonisolated final class BpyMediaWriter: @unchecked Sendable {
    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var token: NSObjectProtocol?
        init(parent: UUID) {
            token = BpyObservedActivity.begin(options: .userInitiated, reason: "Stop a 3D video encoder", parent: parent)
        }
        func end() {
            let token = lock.withLock { let value = self.token; self.token = nil; return value }
            if let token { BpyObservedActivity.end(token) }
        }
        deinit { end() }
    }

    private let writer: any BpyMediaWriting
    private let lock = NSLock()
    private let operations = NSLock()
    private let cancellation: BpyOperationCancellation
    private let work: BpyConsumerWork
    private var pin: BpyMediaFilePin?
    private var cancelled = false
    private var settled = false
    private var cancellationEnded = false
    private var cleanupStarted: TimeInterval?
    private var settledAt: TimeInterval?
    private var activity: Activity?
    private var registration: BpyOperationCancellation.Registration?

    convenience init(writer: AVAssetWriter, pin: BpyMediaFilePin, cancellation: BpyOperationCancellation, work: BpyConsumerWork) throws {
        try self.init(backend: BpyAssetWriting(writer), pin: pin, cancellation: cancellation, work: work)
    }

    init(backend: any BpyMediaWriting, pin: BpyMediaFilePin, cancellation: BpyOperationCancellation, work: BpyConsumerWork) throws {
        writer = backend; self.pin = pin; self.cancellation = cancellation; self.work = try work.retained()
        registration = cancellation.observe { [weak self] in self?.requestCancel() }
    }

    func perform<Value>(_ operation: () throws -> Value) throws -> Value {
        try operations.withLock {
            guard lock.withLock({ !cancelled && !settled }) else { throw BpyAdmissionFailure.cancelled }
            try cancellation.check()
            try work.check()
            return try operation()
        }
    }

    func requestCancel() {
        let start = lock.withLock { () -> Bool in
            guard !cancelled, !settled else { return false }
            cancelled = true
            cleanupStarted = BpyRuntimeClock.read()?.awake
            return true
        }
        guard start else { return }
        cancellation.cancel()
        let activity = Activity(parent: work.id)
        let retain = lock.withLock { () -> Bool in
            guard !settled else { return false }
            self.activity = activity
            return true
        }
        if !retain { activity.end() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self, activity] in
            activity.end()
            guard let self else { return }
            if !lock.withLock({ settled }) { work.failCleanup(since: lock.withLock { cleanupStarted }) }
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            operations.withLock { writer.cancelWriting() }
            finishOwnership(cancelledWriting: true)
        }
    }

    private func finishOwnership(cancelledWriting: Bool = false) {
        let released = lock.withLock { () -> (BpyMediaFilePin?, Activity?) in
            if cancelledWriting { cancellationEnded = true }
            guard !settled, !cancelled || cancellationEnded else { return (nil, nil) }
            settled = true
            settledAt = BpyRuntimeClock.read()?.awake
            let released = (pin, activity); pin = nil; activity = nil
            return released
        }
        released.0?.release(); released.1?.end()
    }

    func diagnosticCleanup() throws -> (requested: TimeInterval?, settled: TimeInterval?) {
        guard ProcessInfo.processInfo.environment["NGV_SELFTEST_BPY"]?.isEmpty == false else { throw BpyAdmissionFailure.closed }
        return lock.withLock { (cleanupStarted, settledAt) }
    }

    private func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(5)) { continuation.resume() }
        }
    }

    func cancelAndWait() async throws {
        requestCancel()
        while !lock.withLock({ settled }) {
            guard let began = lock.withLock({ cleanupStarted }), let now = BpyRuntimeClock.read()?.awake,
                  now < began + BpyMemoryState.cleanupBudget else {
                work.failCleanup(since: lock.withLock { cleanupStarted })
                throw BpyAdmissionFailure.cleanupFailed
            }
            await pause()
        }
    }

    func finish(deadline: TimeInterval, checking: () throws -> Void) async throws {
        guard deadline.isFinite else { throw BpyRuntimeError.timedOut }
        try await withTaskCancellationHandler {
            do {
                try perform { writer.finishWriting { [self] in finishOwnership() } }
                while !lock.withLock({ settled }) {
                    try cancellation.check(); try work.check(); try checking()
                    guard try BpyRuntimeClock.awakeSeconds() < deadline else { throw BpyRuntimeError.timedOut }
                    await pause()
                }
                try cancellation.check(); try work.check(); try checking()
                guard writer.status == .completed else { throw writer.error ?? SpatialSceneError.changed }
            } catch {
                try await cancelAndWait()
                try work.rethrowAfterCleanup(error)
            }
        } onCancel: { self.requestCancel() }
    }

    deinit { work.release() }
}
