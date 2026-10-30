import BpyRuntimeProtocol
import Foundation

extension Process {
    nonisolated func runCoordinated() throws {
        try BpySpawnGuard.withLock { try run() }
    }
}
