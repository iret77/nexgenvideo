import Testing
import Foundation

@testable import NexGenVideo

@Suite("CostGuard — the user's final word on paid agent renders (M7)")
struct CostGuardTests {

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

    /// The gate suspends the render until the UI resolves it — and a swap carries the chosen model id
    /// back, so the agent cannot self-approve or self-pick.
    @MainActor
    @Test func approvalSuspendsUntilResolvedAndCarriesTheSwap() async {
        let editor = EditorViewModel()
        let service = editor.agentService
        let approval = SpendApproval(
            id: "spend-1", modelId: "m1", modelName: "Model One", providerLabel: "fal.ai",
            credits: 120,
            alternatives: [SpendAlternative(modelId: "m2", name: "Model Two", providerLabel: "Runway", credits: 40)],
            actionLabel: "Generate video")

        async let decision = service.requestSpendApproval(approval)
        for _ in 0..<20 where service.pendingSpendApproval == nil { await Task.yield() }
        #expect(service.pendingSpendApproval?.id == "spend-1")

        service.resolveSpend(.approved(modelId: "m2"))
        #expect(await decision == .approved(modelId: "m2"))
        #expect(service.pendingSpendApproval == nil)
    }

    @MainActor
    @Test func declineResolvesToDeclinedAndClears() async {
        let editor = EditorViewModel()
        let service = editor.agentService
        let approval = SpendApproval(
            id: "spend-2", modelId: "m1", modelName: "Model One", providerLabel: "fal.ai",
            credits: 120, alternatives: [], actionLabel: "Generate image")

        async let decision = service.requestSpendApproval(approval)
        for _ in 0..<20 where service.pendingSpendApproval == nil { await Task.yield() }
        service.resolveSpend(.declined)
        #expect(await decision == .declined)
        #expect(service.pendingSpendApproval == nil)
    }
}
