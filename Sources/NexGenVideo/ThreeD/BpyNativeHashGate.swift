import BpyRuntimeProtocol
import Darwin
import Foundation

final class BpyNativeHashGate: @unchecked Sendable {
    struct Sample: Sendable {
        let progress: BpyRuntimeHashObservation.Progress
        let context: BpyRuntimeHashObservation.Context
        let clock: BpyClockReading
    }
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var registration: BpyRuntimeHashObservation.Registration?
    private var observed: Sample?
    private var released = false
    private var expired = false
    private var cancelledChunks = 0
    let device: UInt64
    let inode: UInt64
    let bytes: UInt64

    init(file: URL, operation: UUID? = nil, excludingOperation: UUID? = nil,
         purpose: String? = nil, followReplacements: Bool = false) throws {
        var status = stat()
        guard lstat(file.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size > 65_536 else {
            throw SpatialSceneError.changed
        }
        self.device = UInt64(UInt32(bitPattern: status.st_dev)); self.inode = status.st_ino; self.bytes = UInt64(status.st_size)
        let device = self.device, inode = self.inode, bytes = self.bytes
        registration = try BpyRuntimeHashObservation.observe { [weak self] progress, context in
            guard let self, !Thread.isMainThread, context.callerOwned,
                  operation == nil || operation == context.id, purpose == nil || purpose == context.purpose,
                  excludingOperation == nil || excludingOperation != context.id,
                  progress.hashedBytes > 0,
                  progress.hashedBytes < progress.bytes, let clock = BpyRuntimeClock.read() else { return }
            if followReplacements {
                var current = stat()
                guard lstat(file.path, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
                      UInt64(UInt32(bitPattern: current.st_dev)) == progress.device, current.st_ino == progress.inode,
                      current.st_size > 65_536, UInt64(current.st_size) == progress.bytes else { return }
            } else {
                guard progress.device == device, progress.inode == inode, progress.bytes == bytes else { return }
            }
            let first = lock.withLock {
                if context.isCancelled() { cancelledChunks += 1 }
                guard observed == nil, !released else { return false }
                observed = .init(progress: progress, context: context, clock: clock)
                return true
            }
            guard first else { return }
            if resume.wait(timeout: .now() + 30) != .success { lock.withLock { expired = true } }
        }
    }

    var sample: Sample? { lock.withLock { observed } }
    var timedOut: Bool { lock.withLock { expired } }
    var chunksAfterCancellation: Int { lock.withLock { cancelledChunks } }

    func release() {
        let first = lock.withLock { if released { return false }; released = true; return true }
        if first { resume.signal() }
    }
}
