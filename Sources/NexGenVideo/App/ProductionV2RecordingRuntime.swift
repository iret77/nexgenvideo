import Foundation
import NexGenEngine

@MainActor
final class ProductionV2RecordingRuntime: AgentRuntimeAdapter {
    let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: [], providerExtensions: [])
    private(set) var state: AgentRuntimeState = .idle
    private(set) var phases: [String] = []
    private(set) var instructionHashes: [String] = []
    private var phase: String?
    private var instructionHash: String?

    func service() -> AgentService {
        AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in self }, runtimeReadinessOverride: { nil })
    }

    func start(_ request: AgentRuntimeSessionRequest) throws {
        guard WorkspaceUIAcceptance.isRequested, request.hostContext.pack == nil,
              let home = request.workingDirectory, let root = DataRootResolver.dataRoot(of: home),
              let workflow = try PhaseContractRuntime.resolveWorkflow(dataRoot: root, expectedPack: nil, expectedProductionContract: .current),
              workflow == (try HostWorkflowKey.core(.current)) else {
            throw GateBlocked("The Core recording runtime received a different workflow identity.")
        }
        let project = try JSONDecoder().decode(ProjectStateData.self,
            from: NativeCockpitReader.stateJSON(dataRoot: root, workflow: workflow))
        if project.isComplete {
            guard request.hostContext.phaseInstructions == nil else { throw GateBlocked("The completed Core film received another phase.") }
            phase = "complete"; instructionHash = nil
        } else {
            guard let current = project.nextPhaseName, let actual = request.hostContext.phaseInstructions else {
                throw GateBlocked("The Core recording runtime received no actual phase instructions.")
            }
            let expected = try PhaseContractRuntime.contract(workflow: workflow).instructions(for: current)
            guard !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, actual.contains(expected) else {
                throw GateBlocked("The Core request omitted its exact packaged phase document.")
            }
            phase = current; instructionHash = FileDigest.sha256(of: Data(actual.utf8))
        }
        state = .ready(sessionID: request.sessionID)
    }

    func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }

    func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        guard let phase else { throw GateBlocked("The recording turn has no current production phase.") }
        phases.append(phase); instructionHashes.append(instructionHash ?? "complete")
        state = .running(sessionID: request.sessionID, turnID: request.turnID)
        return AsyncStream { continuation in
            continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                event: .text(messageID: nil, value: "Acceptance transport received " + phase + ".", isDelta: false)))
            continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.completed(.endTurn))))
            continuation.finish()
        }
    }

    func cancel(sessionID: UUID) { state = .ready(sessionID: sessionID) }
    func end(sessionID: UUID) { state = .ended(sessionID: sessionID) }
}
