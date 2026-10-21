import AppKit
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
struct PipelineLedgerStreamingUndoTests {
    @Test(arguments: [false, true])
    func nativeUndoWaitsForTheActualAgentTurnAndKeepsOlderHistory(cancelTurn: Bool) async throws {
        let runtime = LedgerUndoRuntime()
        let service = runtime.service()
        let context = try await ProductionPlanningAcceptanceFixture.makeBible(agentService: service)
        defer { service.cancel(); context.document.close() }
        let original = try? YAMLArtifactStore(dataRoot: context.dataRoot).load(Ledger.self, at: PipelineLayout.ledgerFile)
        try await ProductionPlanningAcceptanceFixture.run("set_ledger_attribute",
            args: ["kind": "film", "key": "lighting", "tag": "Original side light"], in: context)
        let first = try YAMLArtifactStore(dataRoot: context.dataRoot).load(Ledger.self, at: PipelineLayout.ledgerFile)
        #expect(service.send(text: "Revise the current lighting intent.", mentions: [], hidden: true))
        try await until { runtime.turn != nil }
        let result = try await runtime.execute("set_ledger_attribute",
            args: ["kind": "film", "key": "lighting", "tag": "Revised side light"])
        try #require(!result.isError)
        try #require(service.isStreaming)
        let second = try YAMLArtifactStore(dataRoot: context.dataRoot).load(Ledger.self, at: PipelineLayout.ledgerFile)
        let bytes = try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.ledgerFile))
        let manager = try #require(context.editor.undoManager)
        context.editor.mediaPanelToast = nil
        manager.undo()
        #expect(PipelineLedgerWriter.isRestoring(editor: context.editor))
        #expect(PipelineLedgerWriter.restoreMessage(editor: context.editor)?.contains("Let the agent finish") == true)
        let window = NSWindow()
        let controller = EditorWindowController(editorViewModel: context.editor, window: window)
        #expect(controller.windowWillReturnUndoManager(window) == nil)
        let restore = Task { try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: context.editor) }
        defer { restore.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.canRedo && context.editor.mediaPanelToast == nil)
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.ledgerFile)) == bytes)
        let lease = try #require(context.editor.pipelinePhaseRunCoordinator.beginMutation(
            projectRoot: context.dataRoot, label: "Check queued Ledger Undo releases publication"))
        context.editor.pipelinePhaseRunCoordinator.endMutation(projectRoot: context.dataRoot, id: lease)
        let refused = try await runtime.execute("set_ledger_attribute",
            args: ["kind": "film", "key": "lighting", "tag": "Must not replace queued Undo"])
        #expect(refused.isError)
        #expect(try Data(contentsOf: context.dataRoot.appendingPathComponent(PipelineLayout.ledgerFile)) == bytes)
        if cancelTurn { service.cancel() } else { runtime.complete() }
        try await until { !service.isStreaming }
        #expect(try await restore.value == first)
        #expect(!PipelineLedgerWriter.isRestoring(editor: context.editor))
        #expect(PipelineLedgerWriter.restoreMessage(editor: context.editor) == nil)
        #expect(controller.windowWillReturnUndoManager(window) === manager)
        manager.redo()
        #expect(try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: context.editor) == second)
        manager.undo()
        #expect(try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: context.editor) == first)
        manager.undo()
        #expect(try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: context.editor) == original)
        #expect(context.editor.mediaPanelToast == nil)
    }

    @Test func queuedUndoRefusesTheClosedProjectWithoutAStaleToast() async throws {
        let runtime = LedgerUndoRuntime()
        let service = runtime.service()
        let context = try await ProductionPlanningAcceptanceFixture.makeBible(agentService: service)
        defer { service.cancel(); if context.editor.workingRoot != nil { context.document.close() } }
        #expect(service.send(text: "Revise the current lighting intent.", mentions: [], hidden: true))
        try await until { runtime.turn != nil }
        let result = try await runtime.execute("set_ledger_attribute",
            args: ["kind": "film", "key": "lighting", "tag": "Pending side light"])
        try #require(!result.isError && service.isStreaming)
        let manager = try #require(context.editor.undoManager)
        context.editor.mediaPanelToast = nil
        manager.undo()
        var observing = false
        let restore = Task {
            observing = true
            return try await PipelineLedgerWriter.waitForPendingNativeRestore(editor: context.editor)
        }
        defer { restore.cancel() }
        try await until { observing }
        try await Task.sleep(for: .milliseconds(200))
        #expect(manager.canRedo && context.editor.mediaPanelToast == nil)
        #expect(PipelineLedgerWriter.isRestoring(editor: context.editor))
        context.document.close()
        try await until { context.editor.workingRoot == nil }
        #expect(!PipelineLedgerWriter.isRestoring(editor: context.editor))
        #expect(PipelineLedgerWriter.restoreMessage(editor: context.editor) == nil)
        do {
            _ = try await restore.value
            Issue.record("Queued Ledger Undo restored a closed project.")
        } catch let error as GateBlocked {
            #expect(error.message == "The Intent Ledger, project or production phase changed. Reload the selected object before revising or restoring its attributes.")
        }
        #expect(context.editor.mediaPanelToast == nil)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}

@MainActor
private final class LedgerUndoRuntime: AgentRuntimeAdapter {
    let descriptor = AgentBackend.anthropicAPI.runtimeDescriptor(toolNames: [], providerExtensions: [])
    private(set) var state: AgentRuntimeState = .idle
    private var session: AgentRuntimeSessionRequest?
    private(set) var turn: AgentRuntimeTurnRequest?
    private var stream: AsyncStream<AgentRuntimeEventEnvelope>.Continuation?

    func service() -> AgentService {
        AgentService(backend: .anthropicAPI, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in self }, runtimeReadinessOverride: { nil })
    }

    func start(_ request: AgentRuntimeSessionRequest) throws {
        session = request
        state = .ready(sessionID: request.sessionID)
    }

    func resume(_ request: AgentRuntimeSessionRequest) throws { try start(request) }

    func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        turn = request
        state = .running(sessionID: request.sessionID, turnID: request.turnID)
        return AsyncStream { stream = $0 }
    }

    func execute(_ name: String, args: [String: Any]) async throws -> ToolResult {
        let session = try #require(session), turn = try #require(turn)
        let id = UUID().uuidString
        let input = try #require(String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8))
        stream?.yield(.init(sessionID: turn.sessionID, turnID: turn.turnID,
            event: .toolCall(messageID: "controlled-ledger-turn", id: id, name: name, inputJSON: input)))
        await Task.yield()
        let result = await session.executeTool(id, name, input)
        stream?.yield(.init(sessionID: turn.sessionID, turnID: turn.turnID,
            event: .toolResult(id: id, content: result.content, isError: result.isError)))
        return result
    }

    func complete() {
        guard let turn else { return }
        stream?.yield(.init(sessionID: turn.sessionID, turnID: turn.turnID, event: .terminal(.completed(.endTurn))))
        stream?.finish()
        stream = nil
        state = .ready(sessionID: turn.sessionID)
    }

    func cancel(sessionID: UUID) { stream?.finish(); stream = nil; state = .ready(sessionID: sessionID) }
    func end(sessionID: UUID) { stream?.finish(); stream = nil; state = .ended(sessionID: sessionID) }
}
