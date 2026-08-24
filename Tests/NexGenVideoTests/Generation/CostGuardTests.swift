import Testing
import Foundation

@testable import NexGenVideo

// `.serialized`: every test here mutates the same global `UserDefaults` key
// (`CostGuard.autoApproveKey`) via `withThreshold`. swift-testing runs a suite's
// tests in parallel by default, so without serialization they race on that shared
// key — one test's threshold leaks into another's `needsApproval` read (observed:
// `rendersAtOrUnderCeilingArePreApproved` intermittently failing on credits: 51).
@Suite("CostGuard — the user's final word on paid agent renders (M7)", .serialized)
struct CostGuardTests {

    private func option(
        modelId: String,
        name: String,
        provider: GenerationProvider,
        credits: Int?
    ) -> SpendOption {
        let binding = ProviderBinding(
            provider: provider,
            transport: .api,
            kind: .generation,
            providerRef: modelId,
            billing: .perCall
        )
        return SpendOption(
            modelId: modelId,
            modelName: name,
            target: ResolvedGenerationTarget(
                modelId: modelId,
                provider: provider,
                endpoint: modelId,
                binding: binding
            ),
            credits: credits,
            requiresCatalogAvailability: false
        )
    }

    private func withThreshold(_ n: Int, _ body: () -> Void) {
        let key = CostGuard.autoApproveKey
        let old = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(n, forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        body()
    }

    @Test func freeRenderNeverNeedsApproval() {
        withThreshold(0) { #expect(CostGuard.needsApproval(credits: 0) == false) }
    }

    @Test func everyPaidRenderNeedsApprovalAtZeroCeiling() {
        withThreshold(0) {
            #expect(CostGuard.needsApproval(credits: 1))
            #expect(CostGuard.needsApproval(credits: 200))
        }
    }

    @Test func unknownCostIsTreatedAsOverBudget() {
        withThreshold(1000) { #expect(CostGuard.needsApproval(credits: nil)) }
    }

    @Test func rendersAtOrUnderCeilingArePreApproved() {
        withThreshold(50) {
            #expect(CostGuard.needsApproval(credits: 49) == false)
            #expect(CostGuard.needsApproval(credits: 50) == false)
            #expect(CostGuard.needsApproval(credits: 51))
        }
    }

    @MainActor
    @Test func approvalSuspendsUntilResolvedAndCarriesTheSwap() async {
        let editor = EditorViewModel()
        let service = editor.agentService
        let recommended = option(modelId: "m1", name: "Model One", provider: .fal, credits: 120)
        let selected = option(modelId: "m2", name: "Model Two", provider: .runway, credits: 40)
        let approval = SpendApproval(
            id: "spend-1",
            recommendedOptionId: recommended.id,
            options: [recommended, selected],
            actionLabel: "Generate video"
        )

        async let decision = service.requestSpendApproval(approval)
        for _ in 0..<20 where service.pendingSpendApproval == nil { await Task.yield() }
        #expect(service.pendingSpendApproval?.id == "spend-1")

        #expect(service.approveSpend(selected) == nil)
        #expect(await decision == .approved(option: selected))
        #expect(service.pendingSpendApproval == nil)
    }

    @MainActor
    @Test func declineResolvesToDeclinedAndClears() async {
        let editor = EditorViewModel()
        let service = editor.agentService
        let selected = option(modelId: "m1", name: "Model One", provider: .fal, credits: 120)
        let approval = SpendApproval(
            id: "spend-2",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )

        async let decision = service.requestSpendApproval(approval)
        for _ in 0..<20 where service.pendingSpendApproval == nil { await Task.yield() }
        service.resolveSpend(.declined)
        #expect(await decision == .declined)
        #expect(service.pendingSpendApproval == nil)
    }

    @MainActor
    @Test func gateApprovalBlocksSpendWithoutAddingOrReplacingACard() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        _ = try service.requestGateApproval(GateApproval(phase: "brief"))
        let selected = option(modelId: "m1", name: "Model One", provider: .fal, credits: 120)
        let approval = SpendApproval(
            id: "blocked-by-gate",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )

        let decision = await service.requestSpendApproval(approval)

        #expect(decision == .blocked(reason: "A gate approval is already waiting for the user."))
        #expect(service.pendingSpendApproval == nil)
        #expect(service.pendingGateApproval?.phase == "brief")
    }

    @MainActor
    @Test func dialogBlocksSpendWithoutAddingOrReplacingACard() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let dialog = AgentDialog(
            id: "existing-dialog",
            title: "Choose",
            symbol: "questionmark",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: nil,
            sections: []
        )
        try service.presentDialog(dialog)
        let selected = option(modelId: "m1", name: "Model One", provider: .fal, credits: 120)
        let approval = SpendApproval(
            id: "blocked-by-dialog",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )

        let decision = await service.requestSpendApproval(approval)

        #expect(decision == .blocked(reason: "A host-owned dialog is already waiting for the user."))
        #expect(service.pendingSpendApproval == nil)
        #expect(service.pendingDialog?.id == dialog.id)
    }

    @MainActor
    @Test func secondSpendAndGateCannotReplacePendingSpend() async {
        let editor = EditorViewModel()
        let service = editor.agentService
        let selected = option(modelId: "m1", name: "Model One", provider: .fal, credits: 120)
        let first = SpendApproval(
            id: "first-spend",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        let second = SpendApproval(
            id: "second-spend",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )

        async let firstDecision = service.requestSpendApproval(first)
        for _ in 0..<20 where service.pendingSpendApproval == nil { await Task.yield() }
        let secondDecision = await service.requestSpendApproval(second)

        #expect(secondDecision == .blocked(reason: "A spend approval is already waiting for the user."))
        #expect(service.pendingSpendApproval?.id == first.id)
        #expect(throws: ToolError.self) {
            try service.requestGateApproval(GateApproval(phase: "brief"))
        }
        #expect(service.pendingSpendApproval?.id == first.id)
        let dialog = AgentDialog(
            id: "blocked-dialog",
            title: "Choose",
            symbol: "questionmark",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: nil,
            sections: []
        )
        #expect(throws: ToolError.self) {
            try service.presentDialog(dialog)
        }
        #expect(service.pendingDialog == nil)
        #expect(service.pendingSpendApproval?.id == first.id)

        service.resolveSpend(.declined)
        #expect(await firstDecision == .declined)
    }
}
