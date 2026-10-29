import Foundation

final class GenerationBatchExecutionLifetime: @unchecked Sendable {
    @TaskLocal static var current: GenerationBatchExecutionLifetime?
    private let lock = NSLock()
    private var abandoned = false

    var isAbandoned: Bool { lock.withLock { abandoned } }
    func abandon() { lock.withLock { abandoned = true } }

    static func requireActive() throws {
        if current?.isAbandoned == true { throw CancellationError() }
    }
}
