import BpyRuntimeProtocol
import Foundation

struct BpyHeldGateEvidence: Codable, Sendable {
    let execution: UUID
    let permit: UUID
    let process: BpyObservedProcess
    let clock: BpyClockReading
    let sourceSHA256: String
    let configurationSHA256: String
}

struct BpySourceBindingEvidence: Codable, Sendable {
    let target: String
    let source: String
    let originalSHA256: String
    let replacementSHA256: String
    let originalInode: UInt64
    let replacementInode: UInt64
    let mutatedAt: BpyClockReading
    let authorizedAt: BpyClockReading
    let gateBefore: BpyHeldGateEvidence
    let gateAfter: BpyHeldGateEvidence
    let response: BpyServiceResponse
    let ended: BpyMonitorResponse
    let receipt: BpyMemoryCoordinator.PermitReceipt
}

struct BpySourceBindingCase: Codable, Sendable {
    let mutation: BpySourceBindingEvidence
    let retry: BpyHealthyRetryEvidence
}

nonisolated final class BpyDiagnosticJobResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<BpyRuntimeJobResult, any Error>?
    private var abandoned = false

    func complete(_ result: Result<BpyRuntimeJobResult, any Error>) {
        let discard = lock.withLock {
            if abandoned { return true }
            value = result
            return false
        }
        if discard, case .success(let result) = result { result.release() }
    }

    func take() -> Result<BpyRuntimeJobResult, any Error>? {
        lock.withLock { let result = value; value = nil; return result }
    }

    func abandon() {
        let previous = lock.withLock { abandoned = true; let result = value; value = nil; return result }
        if case .success(let result) = previous { result.release() }
    }
}
