import Foundation

nonisolated struct BpyTerminalPollState {
    private(set) var finalRead = false
    private var started: TimeInterval?

    mutating func begin(at now: TimeInterval, deadline: TimeInterval) throws {
        guard now.isFinite, deadline.isFinite, started == nil, !finalRead else { throw BpyRuntimeError.timedOut }
        started = now
        if now >= deadline { finalRead = true }
    }

    mutating func end(at now: TimeInterval, deadline: TimeInterval, terminal: Bool) throws {
        guard let started, now.isFinite, now >= started, deadline.isFinite else { throw BpyRuntimeError.timedOut }
        self.started = nil
        if now >= deadline { finalRead = true }
        if finalRead && !terminal { throw BpyRuntimeError.timedOut }
    }

    static func timelyCommit(first: TimeInterval, timeout: TimeInterval, commit: TimeInterval) -> Bool {
        first.isFinite && timeout.isFinite && commit.isFinite && first >= 0 && timeout > 0
            && commit >= first && commit <= first + timeout + 15
    }
}
