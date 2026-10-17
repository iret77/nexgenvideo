import Testing
@testable import NexGenVideo

@Suite("Requested generation model selection")
@MainActor
struct SpendRequestedModelTests {
    private func option(_ id: String, provider: GenerationProvider) -> SpendOption {
        .init(modelId: id, modelName: id,
            target: .init(modelId: id, provider: provider, endpoint: id, binding: nil),
            credits: 0, requiresCatalogAvailability: false)
    }

    @Test func recommendationKeepsTheRequestedModelAcrossProviderAndOptionOrder() {
        let other = option("other-model", provider: .fal)
        let requested = option("requested-model", provider: .fal)
        let unavailableDefault = option("requested-model", provider: .runway).target
        for choices in [[other, requested], [requested, other]] {
            #expect(SpendOptionBuilder.recommended(from: choices, currentModelId: requested.modelId,
                defaultTarget: unavailableDefault) == requested)
        }
        #expect(SpendOptionBuilder.recommended(from: [other], currentModelId: requested.modelId,
            defaultTarget: unavailableDefault) == nil)
    }

    @Test func unavailableRequestedModelRequiresAnExplicitChoiceEvenIfAnAlternativeIsFree() async throws {
        let service = AgentService(backend: .claudeCode, refreshBackendStatusOnInit: false)
        let editor = EditorViewModel(agentService: service)
        let executor = ToolExecutor(editor: editor, enforceHardGates: false)
        let alternative = option("other-model", provider: .fal)
        var dispatches = 0
        let result = try await executor.withSpendApproval(editor,
            currentModelId: "requested-model", currentModelName: "Requested model", credits: 0,
            actionLabel: "Generate image", selectionScope: .image, pipelineTool: .generateImage,
            origin: .direct, currentIsCompatible: false,
            noCompatibleModelReason: "The requested model does not support these reference inputs.",
            alternatives: { [] }, exactOptions: { [alternative] },
            execute: { _, _ in
                dispatches += 1
                return .ok("unexpected generation")
            })
        #expect(result.turnDisposition == .suspendTurn)
        #expect(dispatches == 0)
        let approval = try #require(service.pendingSpendApproval)
        #expect(approval.modelRequirement?.modelId == "requested-model")
        #expect(approval.modelRequirement?.unavailableReason?.contains("reference inputs") == true)
        #expect(approval.recommendedOptionId.isEmpty)
        #expect(approval.options == [alternative])
        #expect(SpendApprovalSelection.optionID(approval: approval, current: "").isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }
}
