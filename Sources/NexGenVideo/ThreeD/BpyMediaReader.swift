import AVFoundation
import BpyRuntimeProtocol
import Foundation

nonisolated protocol BpyMediaLoading: AnyObject, Sendable {
    func cancelLoading()
}

nonisolated protocol BpyMediaReading: AnyObject, Sendable {
    func startReading() throws
    func cancelReading()
}

nonisolated private final class BpyAssetLoading: BpyMediaLoading, @unchecked Sendable {
    private let asset: AVURLAsset
    init(_ asset: AVURLAsset) { self.asset = asset }
    func cancelLoading() { asset.cancelLoading() }
}

nonisolated private final class BpyAssetReading: BpyMediaReading, @unchecked Sendable {
    private let reader: AVAssetReader
    init(_ reader: AVAssetReader) { self.reader = reader }
    func startReading() throws {
        guard reader.startReading() else { throw reader.error ?? SpatialSceneError.changed }
    }
    func cancelReading() { reader.cancelReading() }
}

nonisolated final class BpyMediaReader: @unchecked Sendable {
    private let lock = NSLock()
    private let operations = NSLock()
    private let asset: any BpyMediaLoading
    private let cancellation: BpyOperationCancellation
    private let work: BpyConsumerWork
    private let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.media.reader", qos: .utility)
    private var files: [BpyRuntimeFile]
    private var pin: BpyMediaFilePin?
    private var reader: (any BpyMediaReading)?
    private var registration: BpyOperationCancellation.Registration?
    private var timer: DispatchSourceTimer?
    private var lastProgress: TimeInterval?
    private var cleanupStarted: TimeInterval?
    private var timedOut = false
    private var cancelled = false
    private var bodyEnded = false
    private var cancellationEnded = false
    private var released = false
    private var cleanupActivity: NSObjectProtocol?

    private init(asset: any BpyMediaLoading, files: [BpyRuntimeFile], pin: BpyMediaFilePin?,
                 cancellation: BpyOperationCancellation, work: BpyConsumerWork) {
        self.asset = asset; self.files = files; self.pin = pin; self.cancellation = cancellation; self.work = work
        lastProgress = BpyRuntimeClock.read()?.awake
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        registration = cancellation.observe { [weak self] in self?.requestCancel() }
    }

    static func begin(asset: AVURLAsset, files: [BpyRuntimeFile] = [], pin: BpyMediaFilePin? = nil,
                      cancellation: BpyOperationCancellation, work: BpyConsumerWork) throws -> BpyMediaReader {
        try begin(backend: BpyAssetLoading(asset), files: files, pin: pin, cancellation: cancellation, work: work)
    }

    static func begin(backend: any BpyMediaLoading, files: [BpyRuntimeFile] = [], pin: BpyMediaFilePin? = nil,
                      cancellation: BpyOperationCancellation, work: BpyConsumerWork) throws -> BpyMediaReader {
        do {
            return try BpyMediaReader(asset: backend, files: files, pin: pin, cancellation: cancellation, work: work.retained())
        } catch {
            for file in files { file.release() }
            pin?.release()
            throw error
        }
    }

    func check() throws {
        if lock.withLock({ timedOut }) { throw BpyRuntimeError.timedOut }
        try work.check()
        try cancellation.check()
    }

    func progress() throws {
        try check()
        guard let now = BpyRuntimeClock.read()?.awake else { throw BpyAdmissionFailure.sensorUnavailable }
        lock.withLock { lastProgress = now }
    }

    func start(_ reader: AVAssetReader) throws {
        try start(backend: BpyAssetReading(reader))
    }

    func start(backend: any BpyMediaReading) throws {
        try operations.withLock {
            try check()
            try lock.withLock {
                guard !cancelled, !bodyEnded, self.reader == nil else { throw BpyAdmissionFailure.cancelled }
                self.reader = backend
            }
            try backend.startReading()
        }
        try progress()
    }

    private func tick() {
        guard let now = BpyRuntimeClock.read()?.awake else {
            _ = try? work.check()
            requestCancel()
            lock.withLock { timer?.cancel(); timer = nil }
            return
        }
        let state = lock.withLock { (released, cancelled, lastProgress, cleanupStarted) }
        guard !state.0 else { return }
        if !state.1, state.2.map({ now >= $0 + 30 }) ?? true {
            lock.withLock { timedOut = true }
            requestCancel()
        } else if state.1, let began = state.3, now >= began + BpyMemoryState.cleanupBudget {
            work.failCleanup(since: began)
            lock.withLock { timer?.cancel(); timer = nil }
        }
    }

    func requestCancel() {
        let begin = lock.withLock { () -> Bool in
            guard !cancelled, !released else { return false }
            cancelled = true
            cleanupStarted = BpyRuntimeClock.read()?.awake
            return true
        }
        guard begin else { return }
        cancellation.cancel()
        let activity = BpyObservedActivity.begin(options: .userInitiated, reason: "Stop reading a 3D movie", parent: work.id)
        lock.withLock { cleanupActivity = activity }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in self?.endCleanupActivity() }
        DispatchQueue.global(qos: .utility).async { [self] in
            operations.withLock {
                asset.cancelLoading()
                let reader = lock.withLock { self.reader }
                reader?.cancelReading()
            }
            lock.withLock { cancellationEnded = true }
            disposeIfFinished()
        }
    }

    func endBody(success: Bool) {
        lock.withLock { bodyEnded = true }
        if !success { requestCancel() }
        disposeIfFinished()
    }

    private func disposeIfFinished() {
        let owned = lock.withLock { () -> ([BpyRuntimeFile], BpyMediaFilePin?)? in
            guard !released, bodyEnded, !cancelled || cancellationEnded else { return nil }
            released = true
            timer?.cancel(); timer = nil; reader = nil
            let owned = (files, pin); files.removeAll(); pin = nil
            return owned
        }
        guard let owned else { return }
        for file in owned.0 { file.release() }
        owned.1?.release()
        endCleanupActivity()
        work.release()
    }

    private func endCleanupActivity() {
        let activity = lock.withLock { let value = cleanupActivity; cleanupActivity = nil; return value }
        if let activity { BpyObservedActivity.end(activity) }
    }

    deinit { timer?.cancel(); endCleanupActivity() }
}
