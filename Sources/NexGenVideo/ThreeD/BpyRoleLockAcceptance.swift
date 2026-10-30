import BpyRuntimeProtocol
import Foundation

struct BpyRoleLockEvidence: Codable, Sendable {
    let control: String
    let hold: BpyRuntimeVolume.RoleHold
    let workerRoleFinishedAt: BpyClockReading
    let launchedSlot: String
    let source: String
    let response: BpyServiceResponse
    let receipt: BpyMemoryCoordinator.PermitReceipt
    let holdingRevisionBefore: String
    let holdingRevisionAfter: String
    let launchingRevisionBefore: String
    let launchingRevisionAfter: String
}

enum BpyRoleLockAcceptance {
    private final class HoldAttempt: @unchecked Sendable {
        let acquired = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<BpyRuntimeVolume.RoleHold, any Error>?
        private var released = false
        func release() { lock.withLock { released = true } }
        func shouldRelease() -> Bool { lock.withLock { released } }
        func complete(_ value: Result<BpyRuntimeVolume.RoleHold, any Error>) { lock.withLock { result = value }; finished.signal() }
        func value() -> Result<BpyRuntimeVolume.RoleHold, any Error>? { lock.withLock { result } }
    }

    static func run(holding session: BpyRuntimeSession, launching counterpart: BpyRuntimeSession,
                    expectedRevision: String) throws -> BpyRoleLockEvidence {
        let held = try session.nativeMediaContext(), launched = try counterpart.nativeMediaContext()
        guard held.slot != launched.slot, held.memory === launched.memory else { throw SpatialSceneError.changed }
        guard let previous = session.confirmedRevision else { throw SpatialSceneError.changed }
        let token = BpyOperationCancellation(), attempt = HoldAttempt()
        defer {
            token.cancel()
            if attempt.value() == nil { _ = attempt.finished.wait(timeout: .now() + 8) }
        }
        DispatchQueue.global(qos: .utility).async {
            attempt.complete(Result { try BpyRuntimeVolume.nativeHoldDataRole(slot: held.slot, cancellation: token,
                maximumDuration: 2 * Double(launched.limits.timeoutSeconds) + 15 + 30 + 5,
                releaseRequested: { attempt.shouldRelease() },
                acquired: { _ in attempt.acquired.signal() }) })
        }
        guard attempt.acquired.wait(timeout: .now() + 2) == .success else { throw BpyRuntimeError.timedOut }
        let workerRole = try session.nativeRefreshWorkerRole()
        let job = UUID(), source = "print('ROLE_LOCK_PROGRESS', flush=True)\nbpy.context.scene.render.resolution_x = 64\nbpy.context.scene.render.resolution_y = 64"
        let result = try counterpart.runJob(id: job, expectedRevision: expectedRevision, source: source)
        defer { result.release(); _ = try? counterpart.cancel(jobID: job) }
        attempt.release()
        if attempt.value() == nil {
            guard attempt.finished.wait(timeout: .now() + 8) == .success else { throw BpyRuntimeError.timedOut }
        }
        guard let hold = try attempt.value()?.get(), let receipt = result.lease?.execution,
              result.response.state == .awaitingConfirmation, result.response.stdout?.contains("ROLE_LOCK_PROGRESS") == true,
              receipt.cleanupComplete, receipt.stop == nil, let commit = receipt.terminalCommit,
              receipt.releases.map(\.child) == [.worker, .verifier], let first = receipt.firstRelease,
              hold.heldThrough.awake - hold.acquired.awake >= 5,
              workerRole.awake >= hold.acquired.awake, workerRole.awake < hold.heldThrough.awake,
              first >= workerRole.awake, first < hold.heldThrough.awake,
              receipt.releases.allSatisfy({ $0.clock.awake < hold.heldThrough.awake }), commit < hold.heldThrough.awake,
              session.confirmedRevision == previous, counterpart.confirmedRevision == expectedRevision else {
            throw BpyRuntimeError.invalidOutput("A held data-role lock blocked the other storage role or runtime slot.")
        }
        return .init(control: "host-owned-mutex-hold", hold: hold, workerRoleFinishedAt: workerRole,
            launchedSlot: launched.slot, source: source, response: result.response, receipt: receipt,
            holdingRevisionBefore: previous, holdingRevisionAfter: session.confirmedRevision ?? "",
            launchingRevisionBefore: expectedRevision, launchingRevisionAfter: counterpart.confirmedRevision ?? "")
    }
}
