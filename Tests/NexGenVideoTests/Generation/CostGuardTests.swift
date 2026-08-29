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

    @MainActor
    private final class RefreshableApprovalFixture {
        let approval: SpendApproval
        let initial: SpendOption
        let discovered: SpendOption
        var includeDiscovered = false

        init(approval: SpendApproval, initial: SpendOption, discovered: SpendOption) {
            self.approval = approval
            self.initial = initial
            self.discovered = discovered
        }

        func currentApproval() -> SpendApproval {
            SpendApproval(
                id: approval.id,
                recommendedOptionId: initial.id,
                options: includeDiscovered ? [initial, discovered] : [initial],
                actionLabel: approval.actionLabel
            )
        }
    }

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
    @Test func approvalEndsTheTurnAndRunsTheStoredOperationAfterTheClick() async throws {
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
        var executed: SpendOption?
        let result = try service.requestSpendApproval(
            approval,
            origin: .direct,
            editor: editor,
            execute: { _, option in
                executed = option
                return .ok("started")
            }
        )

        #expect(result.turnDisposition == .suspendTurn)
        #expect(service.pendingSpendApproval?.id == "spend-1")
        await service.approveSpend(selected)
        #expect(executed == selected)
        #expect(service.pendingSpendApproval == nil)
    }

    @MainActor
    @Test func declineCancelsTheStoredOperationAndClears() throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let selected = option(modelId: "m1", name: "Model One", provider: .fal, credits: 120)
        let approval = SpendApproval(
            id: "spend-2",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        var cancelled = false
        _ = try service.requestSpendApproval(
            approval,
            origin: .direct,
            editor: editor,
            cancel: { _ in cancelled = true },
            execute: { _, _ in .ok("unexpected") }
        )
        service.declineSpend()
        #expect(cancelled)
        #expect(service.pendingSpendApproval == nil)
    }

    @MainActor
    @Test func embeddedTurnCannotRetryWhileItsHostApprovalIsOpen() throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        service.newChat()
        let chatSessionID = try #require(service.currentSessionId)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: chatSessionID,
            mcpSessionID: UUID()
        )
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "embedded-spend",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        var executed = false
        let result = try service.requestSpendApproval(
            approval,
            origin: origin,
            editor: editor,
            execute: { _, _ in
                executed = true
                return .ok("unexpected")
            }
        )

        #expect(result.turnDisposition == .suspendTurn)
        let blockReason = service.toolCallBlockReason(
            tool: .generateImage,
            args: [:],
            origin: origin
        )
        #expect(blockReason?.contains("suspended at a host decision") == true)
        #expect(!executed)

        service.cancel()
        #expect(service.pendingSpendApproval == nil)
    }

    @MainActor
    @Test func approvedOperationFailureIsTerminalAndCannotLeaveAStaleCard() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "failed-spend",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        var released = false
        _ = try service.requestSpendApproval(
            approval,
            origin: .direct,
            editor: editor,
            cancel: { _ in released = true },
            execute: { _, _ in throw ToolError("preflight failed") }
        )

        await service.approveSpend(selected)

        #expect(released)
        #expect(service.pendingSpendApproval == nil)
        #expect(!service.spendApprovalIsRunning)
    }

    @MainActor
    @Test func pendingApprovalCanRefreshItsProviderAndModelOptions() throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let initial = option(modelId: "m1", name: "Model One", provider: .fal, credits: 120)
        let discovered = option(modelId: "m2", name: "Model Two", provider: .higgsfield, credits: 40)
        let approval = SpendApproval(
            id: "refreshable-spend",
            recommendedOptionId: initial.id,
            options: [initial],
            actionLabel: "Generate image"
        )
        let fixture = RefreshableApprovalFixture(
            approval: approval,
            initial: initial,
            discovered: discovered
        )

        _ = try service.requestSpendApproval(
            approval,
            origin: .direct,
            editor: editor,
            refresh: fixture.currentApproval,
            execute: { _, _ in .ok("started") }
        )
        fixture.includeDiscovered = true
        service.refreshSpendApproval()

        #expect(service.pendingSpendApproval?.options == [initial, discovered])
        service.declineSpend()
    }

    @MainActor
    @Test func gateApprovalBlocksSpendWithoutAddingOrReplacingACard() throws {
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

        #expect(throws: ToolError.self) {
            try service.requestSpendApproval(
                approval,
                origin: .direct,
                editor: editor,
                execute: { _, _ in .ok("unexpected") }
            )
        }
        #expect(service.pendingSpendApproval == nil)
        #expect(service.pendingGateApproval?.phase == "brief")
    }

    @MainActor
    @Test func dialogBlocksSpendWithoutAddingOrReplacingACard() throws {
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

        #expect(throws: ToolError.self) {
            try service.requestSpendApproval(
                approval,
                origin: .direct,
                editor: editor,
                execute: { _, _ in .ok("unexpected") }
            )
        }
        #expect(service.pendingSpendApproval == nil)
        #expect(service.pendingDialog?.id == dialog.id)
    }

    @MainActor
    @Test func secondSpendAndGateCannotReplacePendingSpend() throws {
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

        _ = try service.requestSpendApproval(
            first,
            origin: .direct,
            editor: editor,
            execute: { _, _ in .ok("started") }
        )
        #expect(throws: ToolError.self) {
            try service.requestSpendApproval(
                second,
                origin: .direct,
                editor: editor,
                execute: { _, _ in .ok("unexpected") }
            )
        }
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

        service.declineSpend()
    }

    @MainActor
    @Test func pendingSpendOperationDoesNotRetainItsEditor() async throws {
        var editor: EditorViewModel? = EditorViewModel()
        weak var weakEditor = editor
        let service = try #require(editor?.agentService)
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "weak-editor",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )

        _ = try service.requestSpendApproval(
            approval,
            origin: .direct,
            editor: try #require(editor),
            execute: { editor, _ in
                _ = editor.timeline
                return .ok("unexpected")
            }
        )

        editor = nil
        #expect(weakEditor == nil)
        await service.approveSpend(selected)
        #expect(service.pendingSpendApproval == nil)
    }
}
