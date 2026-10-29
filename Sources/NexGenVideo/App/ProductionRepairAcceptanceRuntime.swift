import Foundation
import NexGenEngine

@MainActor
final class ProductionRepairAcceptanceRuntime: AgentRuntimeAdapter {
    let descriptor = AgentBackend.claudeCode.runtimeDescriptor(toolNames: ["write_treatment", "write_shotlist"], providerExtensions: [])
    private(set) var state: AgentRuntimeState = .idle
    private(set) var completedCalls = 0
    private var session: AgentRuntimeSessionRequest?
    private var next: (tool: String, json: String, text: String)?
    private var task: Task<Void, Never>?

    func service() -> AgentService {
        AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in self }, runtimeReadinessOverride: { nil })
    }

    func arm(_ json: String, expectedText: String, tool: String = "write_treatment") { next = (tool, json, expectedText) }
    func start(_ request: AgentRuntimeSessionRequest) throws {
        guard WorkspaceUIAcceptance.isRequested, request.hostContext.pack == nil else { throw GateBlocked("The planning transport is confined to actual Core acceptance.") }
        session = request; state = .ready(sessionID: request.sessionID)
    }
    func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }
    func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        guard let session, session.sessionID == request.sessionID else { throw GateBlocked("The native planning session changed.") }
        guard let next else {
            state = .ready(sessionID: request.sessionID)
            return AsyncStream { continuation in
                continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID,
                    event: .text(messageID: nil, value: "The isolated transport received the actual current phase.", isDelta: false)))
                continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: .terminal(.completed(.endTurn))))
                continuation.finish()
            }
        }
        guard request.currentMessage.content.contains(where: { if case .text(let text) = $0 { return text.contains(next.text) }; return false }),
              ["write_treatment", "write_shotlist"].contains(next.tool),
              session.hostContext.phaseInstructions?.contains(next.tool) == true else {
            throw GateBlocked("The planning response did not originate from the current native scoped revision command.")
        }
        self.next = nil; state = .running(sessionID: request.sessionID, turnID: request.turnID)
        return AsyncStream { continuation in
            task = Task { @MainActor in
                let id = "native-repair-" + UUID().uuidString
                func emit(_ event: AgentRuntimeEvent) { continuation.yield(.init(sessionID: request.sessionID, turnID: request.turnID, event: event)) }
                emit(.toolCall(messageID: nil, id: id, name: next.tool, inputJSON: next.json))
                let result = await session.executeTool(id, next.tool, next.json)
                emit(.toolResult(id: id, content: result.content, isError: result.isError))
                if !result.isError { completedCalls += 1 }
                emit(.terminal(result.isError ? .failed : .completed(.endTurn)))
                state = .ready(sessionID: request.sessionID); continuation.finish()
            }
        }
    }
    func cancel(sessionID: UUID) { task?.cancel(); task = nil; state = .ready(sessionID: sessionID) }
    func end(sessionID: UUID) { task?.cancel(); task = nil; session = nil; state = .ended(sessionID: sessionID) }
}
