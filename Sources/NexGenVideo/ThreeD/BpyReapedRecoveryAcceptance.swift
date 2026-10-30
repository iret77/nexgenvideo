import BpyRuntimeProtocol
import Foundation

enum BpyReapedRecoveryAcceptance {
    private enum Route: String, CaseIterable, Codable { case transportLoss, ownerClose }
    private struct Evidence: Codable {
        let route: Route
        let response: BpyMonitorResponse
        let before: BpyMemoryCoordinator.PermitReceipt
        let after: BpyMemoryCoordinator.PermitReceipt
        let checkedAt: BpyClockReading
        let reapedBeforeCleanup: Bool
        let recoveredAfter: Bool
        let cleanupFailed: Bool
        let successor: BpyMemoryCoordinator.PermitReceipt
    }

    static func run(output: URL, serviceName: String) throws -> [String: String] {
        var evidence: [Evidence] = []
        for route in Route.allCases {
            let memory = BpyMemoryCoordinator()
            let session = BpyRuntimeSession(documentID: "reaped-recovery-" + UUID().uuidString,
                serviceName: serviceName, memoryCoordinator: memory)
            defer { _ = session.close() }
            _ = try session.ready()
            let context = try session.nativeMediaContext(), monitor = try session.nativeRecoveryMonitor()
            var captured: Evidence?
            _ = try session.nativeMemoryDiagnostic(.diagnosticVirtualMapping) { response, before in
                guard response.status == .gone, response.outputComplete else { return }
                let reaped = try monitor.diagnosticReapedLaunch(execution: response.execution)
                guard captured == nil, before.stop == nil, !before.cleanupComplete, reaped else { throw SpatialSceneError.changed }
                if route == .ownerClose { memory.close(owner: context.owner) }
                else {
                    let recovered = DispatchSemaphore(value: 0)
                    monitor.recover(disposition: .loss) { _ in recovered.signal() }
                    guard recovered.wait(timeout: .now() + 5) == .success else { throw BpyAdmissionFailure.cleanupFailed }
                }
                guard let began = try memory.receipt(before.identity.id).cleanupStarted else { throw SpatialSceneError.changed }
                while !(try memory.receipt(before.identity.id).cleanupComplete) {
                    guard try BpyRuntimeClock.awakeSeconds() < began + 5 else { throw BpyAdmissionFailure.cleanupFailed }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                while try BpyRuntimeClock.awakeSeconds() < began + 6 { Thread.sleep(forTimeInterval: 0.01) }
                let after = try memory.receipt(before.identity.id)
                let cleanupFailed = try memory.diagnosticCleanupFailed(), recoveredAfter = try monitor.diagnosticRecovered()
                guard let checkedAt = BpyRuntimeClock.read(), !cleanupFailed, recoveredAfter,
                      after.stop == (route == .ownerClose ? .closed : .transportLost), after.cleanupComplete,
                      let finished = after.cleanupFinishedAt, finished >= began, finished <= began + 5,
                      checkedAt.awake >= began + 6 else { throw SpatialSceneError.changed }
                let owner = UUID(), generation = UUID(), token = BpyOperationCancellation()
                try memory.register(owner: owner, generation: generation)
                defer { memory.close(owner: owner); memory.retire(owner: owner) }
                let successor = try memory.admit(owner: owner, generation: generation, transport: UUID(), job: nil,
                    kind: .boundary, timeout: 5, cancellation: token)
                defer { memory.finish(successor.id); memory.forget(successor.id) }
                let admitted = try memory.receipt(successor.id)
                guard admitted.failure == nil, admitted.stop == nil, let granted = admitted.grantedAt,
                      granted >= checkedAt.awake, admitted.identity.id != before.identity.id else { throw SpatialSceneError.changed }
                captured = .init(route: route, response: response, before: before, after: after, checkedAt: checkedAt,
                    reapedBeforeCleanup: reaped, recoveredAfter: recoveredAfter, cleanupFailed: cleanupFailed, successor: admitted)
            }
            guard let captured, session.close() else { throw BpyAdmissionFailure.cleanupFailed }
            evidence.append(captured)
        }
        let data = try JSONEncoder().encode(evidence), name = "native-reaped-recovery.json"
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
        return ["file": name, "sha256": SpatialSceneStore.digest(data)]
    }
}
