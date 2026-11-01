import BpyRuntimeProtocol
import Foundation

nonisolated enum BpyLaunchLifecycle {
    enum Channel: Equatable, Sendable { case output, errors, report }
    enum Stream: Equatable, Sendable {
        case open, eof, failing(Int32), failed(Int32)
        var terminal: Bool { switch self { case .eof, .failed: true; case .open, .failing: false } }
        var errorCode: Int32? { switch self { case .failing(let code), .failed(let code): code; default: nil } }
        mutating func reachedEOF() { if self == .open { self = .eof } }
    }

    struct Streams: Sendable {
        var output = Stream.open
        var errors = Stream.open
        var report = Stream.open
        var terminal: Bool { output.terminal && errors.terminal && report == .eof }
        var errorCode: Int32 { output.errorCode ?? errors.errorCode ?? report.errorCode ?? 0 }
        subscript(_ channel: Channel) -> Stream {
            get { switch channel { case .output: output; case .errors: errors; case .report: report } }
            set { switch channel { case .output: output = newValue; case .errors: errors = newValue; case .report: report = newValue } }
        }
    }

    @discardableResult
    static func finishUnstarted(permit: UUID, memory: BpyMemoryCoordinator, claim: () -> Bool) -> Bool {
        guard claim() else { return false }
        memory.launchEnded(permit)
        memory.finish(permit)
        return true
    }

    static func poll(hasProcess: Bool, isRunning: () throws -> Bool, reap: () throws -> Void,
                     hasSupervisor: () -> Bool, spawnFinished: () -> Bool, stopped: () -> Bool,
                     failure: () -> BpyMemoryStop?, reportEOF: () -> Bool, workerEnded: () throws -> Bool,
                     stop: (BpyMemoryStop) -> Void, finish: () -> Void) throws -> Bool {
        guard hasProcess else { return false }
        if try !isRunning() {
            try reap()
            if let reason = failure(), !stopped() { stop(reason) }
            guard reportEOF() else { return false }
            guard try workerEnded() else {
                if !stopped() { stop(.orphanedWorker) }
                return false
            }
            finish()
            return false
        }
        guard !stopped() else { return false }
        if let reason = failure() { stop(reason); return false }
        guard hasSupervisor() else {
            if spawnFinished() { stop(.launchFailed) }
            return false
        }
        return true
    }

    static func recover(until deadline: TimeInterval?, clock: () -> BpyClockReading?,
                        cleanupDeadline: () -> TimeInterval?, cleanup: () -> Void,
                        recovered: () -> Bool, pause: (TimeInterval) -> Void) -> Bool {
        guard var limit = deadline, limit.isFinite, limit >= 0 else { return false }
        var previous = 0.0
        while true {
            if let original = cleanupDeadline() {
                guard original.isFinite, original >= 0 else { return false }
                limit = min(limit, original)
            }
            guard let before = clock(), before.isValid, before.awake >= previous, before.awake <= limit else { return false }
            cleanup()
            let done = recovered()
            guard let after = clock(), after.isValid, after.awake >= before.awake, after.awake <= limit else { return false }
            if done { return true }
            let remaining = limit - after.awake
            guard remaining > 0 else { return false }
            previous = after.awake
            pause(min(0.005, remaining))
        }
    }
}
