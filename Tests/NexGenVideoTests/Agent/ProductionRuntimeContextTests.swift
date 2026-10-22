import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Production runtime receives actual current phase and native repair evidence")
struct ProductionRuntimeContextTests {
    @Test(arguments: [AgentBackend.claudeCode, .anthropicAPI])
    func startResumeAndGateContinuationUseCurrentCanonicalPhase(backend: AgentBackend) async throws {
        let runtime = ProductionContextRuntime(backend: backend)
        let service = runtime.service(backend: backend)
        let fixture = try await ProductionPlanningAcceptanceFixture.makeScript(agentService: service)
        defer { service.cancel(); fixture.document.close() }
        #expect(service.send(text: "Continue the current production phase.", mentions: [], hidden: true))
        try await waitForTurn(1, runtime: runtime, service: service)
        let initial = try #require(runtime.sessions.last?.hostContext)
        #expect(initial.phaseInstructions?.contains("Use write_script") == true)
        #expect(initial.phaseInstructions?.contains("compile_storyboard_sketch") == false)
        #expect(initial.pack == nil)
        #expect(initial.interfaceLanguage == AgentInterfaceLanguage.current)
        service.cancel()
        #expect(service.send(text: "Resume the current work.", mentions: [], hidden: true))
        try await waitForTurn(2, runtime: runtime, service: service)
        #expect(runtime.sessions.last?.hostContext.phaseInstructions == initial.phaseInstructions)
        #expect(!runtime.resumes.isEmpty)
        service.cancel()
        service.isStreaming = true
        let origin = ToolCallOrigin.inAppChat(sessionID: try #require(service.currentSessionId))
        #expect(throws: ToolError.self) {
            try service.requestGateApproval(.init(phase: "script", dataRoot: fixture.dataRoot), origin: origin)
        }
        #expect(service.pendingGateApproval == nil)
        let contract = try #require(fixture.editor.declaredProductionContract)
        #expect(contract == .current)
        _ = try service.requestGateApproval(.init(phase: "script", dataRoot: fixture.dataRoot,
            declaredProductionContract: contract), origin: origin)
        #expect(await service.resolveGate(.approved, approvalID: service.pendingGateApproval?.id ?? "missing")?.isError == false)
        await fixture.editor.refreshEngineState()
        #expect(fixture.editor.projectState?.nextPhaseName == "storyboard")
        service.isStreaming = false
        service.noteRevisionRequest(origin: origin)
        #expect(service.resumePendingGateFollowUp())
        try await waitForTurn(3, runtime: runtime, service: service)
        let next = try #require(runtime.sessions.last?.hostContext)
        #expect(next.phaseInstructions?.contains("compile_storyboard_sketch") == true)
        #expect(next.phaseInstructions != initial.phaseInstructions)
        #expect(next.interfaceLanguage == initial.interfaceLanguage)
        #expect(service.messages.last(where: { $0.role == .user })?.hidden == true)
    }

    @Test(arguments: [AgentBackend.claudeCode, .anthropicAPI])
    func actualNativeFilmFindingsReachRepairTurnOnlyForTheirUnchangedCut(backend: AgentBackend) async throws {
        let runtime = ProductionContextRuntime(backend: backend)
        let service = runtime.service(backend: backend)
        let fixture = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly(agentService: service, presentation: .editorSession)
        defer { service.cancel(); fixture.document.close() }
        #expect(fixture.document.windowControllers.isEmpty)
        let editor = fixture.editor
        let snapshot = try await PipelineProductionSequenceReviewStore.capture(editor: editor)
        let finding = SequenceReviewFindingV1(id: "actual-context-occlusion", scope: .wholePlayback,
            category: .visualArtifact, severity: .blocking, shotIDs: [try #require(snapshot.shotIDs.first)],
            startFrame: 0, endFrame: 10, evidence: "The opening subject is visibly obscured.", recommendedAction: .localRepair,
            provenance: .init(kind: .nativeUser, reviewerID: "native-sequence-review"))
        try await PipelineProductionSequenceReviewStore.save(snapshot: snapshot, adjacentPairCompleted: true,
            wholePlaybackCompleted: true, findings: [finding], editor: editor)
        try NativeGateWriter.rewind(projectDir: try #require(editor.workingRoot), targetPhase: "render",
            declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
            declaredProductionContract: editor.declaredProductionContract, executionCoordinator: editor.pipelinePhaseRunCoordinator)
        await editor.refreshEngineState()
        #expect(service.send(text: "Repair the retained film observations.", mentions: [], hidden: true))
        try await waitForTurn(1, runtime: runtime, service: service)
        let prompt = try #require(runtime.sessions.last?.hostContext.phaseInstructions)
        #expect(prompt.contains("actual-context-occlusion"))
        #expect(prompt.contains("not current phase approval or delivery authorization"))
        service.cancel()
        let track = try #require(editor.timeline.tracks.firstIndex(where: { $0.type == .video && !$0.clips.isEmpty }))
        editor.timeline.tracks[track].clips[0].opacity = 0.5
        #expect(service.send(text: "Continue with the changed cut.", mentions: [], hidden: true))
        try await waitForTurn(2, runtime: runtime, service: service)
        let changed = try #require(runtime.sessions.last?.hostContext.phaseInstructions)
        #expect(!changed.contains("actual-context-occlusion"))
        #expect(changed.contains("Render"))
    }

    @Test func readonlyContextIgnoresUnrelatedOutputButRejectsChangedPhaseTruth() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeScript()
        defer { fixture.document.close(); fixture.editor.releaseWorkingCopy() }
        let root = fixture.dataRoot
        let declaration = ProjectPackGate.MutationDeclaration(packName: nil, binding: nil, productionContract: .current)
        let timeline = fixture.editor.timeline
        let resolver = fixture.editor.mediaResolver.snapshot()
        let prepared = try await Task.detached {
            try PipelineProductionRuntimeContext.prepare(dataRoot: root, declaration: declaration, timeline: timeline, resolver: resolver)
        }.value
        let output = root.appendingPathComponent("renders/unrelated-download.partial")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Unrelated in-flight provider output".utf8).write(to: output)
        try prepared.requireCurrent(dataRoot: root, workflow: HostWorkflowKey.core(.current), phase: "script")
        let gates = root.appendingPathComponent(PipelineLayout.gatesFile)
        let original = try Data(contentsOf: gates)
        try (original + Data("\n# changed phase truth\n".utf8)).write(to: gates)
        #expect(throws: (any Error).self) {
            try prepared.requireCurrent(dataRoot: root, workflow: HostWorkflowKey.core(.current), phase: "script")
        }
    }

    private func waitForTurn(_ count: Int, runtime: ProductionContextRuntime, service: AgentService) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while runtime.turns.count < count, service.streamError == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.streamError == nil)
        #expect(runtime.turns.count == count)
        guard runtime.turns.count == count else { throw GateBlocked("The real production runtime did not receive its prepared phase context.") }
    }
}

@MainActor
private final class ProductionContextRuntime: AgentRuntimeAdapter {
    let descriptor: AgentRuntimeDescriptor
    private(set) var state: AgentRuntimeState = .idle
    private(set) var sessions: [AgentRuntimeSessionRequest] = []
    private(set) var resumes: [AgentRuntimeSessionRequest] = []
    private(set) var turns: [AgentRuntimeTurnRequest] = []
    private var stream: AsyncStream<AgentRuntimeEventEnvelope>.Continuation?

    init(backend: AgentBackend) { descriptor = backend.runtimeDescriptor(toolNames: [], providerExtensions: []) }
    func service(backend: AgentBackend) -> AgentService {
        AgentService(backend: backend, refreshBackendStatusOnInit: false,
            runtimeAdapterFactory: { _ in self }, runtimeReadinessOverride: { nil })
    }
    func start(_ request: AgentRuntimeSessionRequest) throws {
        sessions.append(request); state = .ready(sessionID: request.sessionID)
    }
    func resume(_ request: AgentRuntimeSessionRequest) throws {
        resumes.append(request); sessions.append(request); state = .ready(sessionID: request.sessionID)
    }
    func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope> {
        turns.append(request); state = .running(sessionID: request.sessionID, turnID: request.turnID)
        return AsyncStream { stream = $0 }
    }
    func cancel(sessionID: UUID) { stream?.finish(); stream = nil; state = .ready(sessionID: sessionID) }
    func end(sessionID: UUID) { stream?.finish(); stream = nil; state = .ended(sessionID: sessionID) }
}
