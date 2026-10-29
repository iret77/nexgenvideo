import Foundation

final class AgentReviewChildStreamControl: @unchecked Sendable {
    private let lock = NSLock()
    private let guardRequest: @Sendable (Data) async throws -> Void
    private var tasks: [Task<Void, Never>] = []
    private var stopped = false

    init(guardRequest: @escaping @Sendable (Data) async throws -> Void) {
        self.guardRequest = guardRequest
    }

    func register(_ task: Task<Void, Never>) {
        let cancelled = lock.withLock {
            tasks.append(task)
            return stopped
        }
        if cancelled { task.cancel() }
    }

    func requireRequest(_ bytes: Data) async throws {
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
        try Task.checkCancellation()
        try await guardRequest(bytes)
        try Task.checkCancellation()
        guard !lock.withLock({ stopped }) else { throw CancellationError() }
    }

    func shutdown() async {
        let owned = lock.withLock {
            stopped = true
            return tasks
        }
        for task in owned { task.cancel() }
        for task in owned { await task.value }
    }
}
