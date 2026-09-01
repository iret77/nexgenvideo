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

    @MainActor
    private final class PendingExecutionFixture {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var didStart = false

        func wait() async {
            didStart = true
            await withCheckedContinuation { continuation = $0 }
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class HostFollowUpFixture {
        var readinessError: AgentStreamError?
        private(set) var sent: [String] = []

        func send(_ text: String, imageBlocks: [[String: Any]]) -> Bool {
            sent.append(text)
            return true
        }
    }

    @MainActor
    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for the spend state to settle")
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

    @MainActor
    private func pipelineEditor() throws -> (
        editor: EditorViewModel,
        dataRoot: URL,
        package: URL
    ) {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("spend-lease-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let pipeline = package.appendingPathComponent("pipeline", isDirectory: true)
        try FileManager.default.createDirectory(
            at: pipeline,
            withIntermediateDirectories: true
        )
        try Data("project: spend-lease\nmode: test\n".utf8).write(
            to: pipeline.appendingPathComponent("project.yaml")
        )
        let editor = EditorViewModel()
        editor.projectURL = package
        let workingRoot = try #require(editor.workingRoot)
        let dataRoot = try #require(DataRootResolver.dataRoot(of: workingRoot))
        return (editor, dataRoot, package)
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

    @Test func providerDiagnosticScopeSurvivesAnEmptyOptionRefresh() {
        let approval = SpendApproval(
            id: "provider-outage",
            recommendedOptionId: "",
            options: [],
            actionLabel: "Generate image",
            providerScope: [.fal, .higgsfield]
        )

        #expect(approval.providerScope == [.fal, .higgsfield])
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
        let fixture = PendingExecutionFixture()
        let result = try service.requestSpendApproval(
            approval,
            origin: .direct,
            editor: editor,
            execute: { _, option in
                executed = option
                await fixture.wait()
                return .ok("started")
            }
        )

        #expect(result.turnDisposition == .suspendTurn)
        #expect(service.pendingSpendApproval?.id == "spend-1")
        await service.approveSpend(selected)
        #expect(service.pendingSpendApproval == nil)
        #expect(service.currentSpendRun?.id == approval.id)
        #expect(!service.isComposerBlocked)

        await waitUntil { fixture.didStart }
        #expect(executed == selected)
        #expect(service.spendApprovalIsRunning)

        fixture.finish()
        await waitUntil { !service.spendApprovalIsRunning }
        #expect(!service.spendApprovalIsRunning)
    }

    @MainActor
    @Test func pendingApprovalDoesNotLeaseThePipelineDuringHumanWait() throws {
        let fixture = try pipelineEditor()
        defer {
            fixture.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: fixture.package)
        }
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "human-wait-has-no-lease",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )

        _ = try fixture.editor.agentService.requestSpendApproval(
            approval,
            origin: .direct,
            editor: fixture.editor,
            pipelineScope: SpendPipelineScope(
                dataRoot: fixture.dataRoot,
                phase: nil,
                tool: .generateImage,
                declaredPack: nil,
                bindingResolution: .absent
            ),
            execute: { _, _ in .ok("unexpected") }
        )

        #expect(
            fixture.editor.pipelinePhaseRunCoordinator.runningPhase(
                projectRoot: fixture.dataRoot
            ) == nil
        )
        let mutation = fixture.editor.pipelinePhaseRunCoordinator.beginMutation(
            projectRoot: fixture.dataRoot,
            label: "Rewind brief"
        )
        #expect(mutation != nil)
        fixture.editor.pipelinePhaseRunCoordinator.endMutation(
            projectRoot: fixture.dataRoot,
            id: try #require(mutation)
        )
        fixture.editor.agentService.declineSpend()
    }

    @MainActor
    @Test func pipelineSpendApprovalFailsClosedWithoutAnExecutionScope() throws {
        let fixture = try pipelineEditor()
        defer {
            fixture.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: fixture.package)
        }
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )

        #expect(throws: ToolError.self) {
            try fixture.editor.agentService.requestSpendApproval(
                SpendApproval(
                    id: "missing-pipeline-spend-scope",
                    recommendedOptionId: selected.id,
                    options: [selected],
                    actionLabel: "Generate image"
                ),
                origin: .direct,
                editor: fixture.editor,
                execute: { _, _ in .ok("unexpected") }
            )
        }
        #expect(fixture.editor.agentService.pendingSpendApproval == nil)
    }

    @MainActor
    @Test func approvedSpendExcludesConcurrentRewindAndPhaseRunUntilSettlement() async throws {
        let fixture = try pipelineEditor()
        defer {
            fixture.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: fixture.package)
        }
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "approved-spend-lease",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        let execution = PendingExecutionFixture()
        _ = try fixture.editor.agentService.requestSpendApproval(
            approval,
            origin: .direct,
            editor: fixture.editor,
            pipelineScope: SpendPipelineScope(
                dataRoot: fixture.dataRoot,
                phase: nil,
                tool: .generateImage,
                declaredPack: nil,
                bindingResolution: .absent
            ),
            execute: { _, _ in
                await execution.wait()
                return .ok("rendered")
            }
        )

        await fixture.editor.agentService.approveSpend(selected)
        await waitUntil { execution.didStart }
        #expect(
            fixture.editor.pipelinePhaseRunCoordinator.runningPhase(
                projectRoot: fixture.dataRoot
            ) == "Generate image"
        )

        let phaseOutcome = await fixture.editor.pipelinePhaseRunCoordinator.run(
            projectRoot: fixture.dataRoot,
            phase: "render",
            sourceFilename: nil,
            runner: { _ in },
            progressRunner: nil,
            state: fixture.editor.pipelinePhaseExecution
        )
        #expect(phaseOutcome == .refused(activePhase: "Generate image"))

        do {
            _ = try ToolExecutor(editor: fixture.editor).rewindTool(
                fixture.editor,
                [
                    "project_dir": fixture.dataRoot.path,
                    "target_phase": "brief",
                ]
            )
            Issue.record("Rewind started during an approved paid operation")
        } catch let error as ToolError {
            #expect(error.message.contains("Generate image"))
        }

        execution.finish()
        await waitUntil { !fixture.editor.agentService.spendApprovalIsRunning }
        #expect(
            fixture.editor.pipelinePhaseRunCoordinator.runningPhase(
                projectRoot: fixture.dataRoot
            ) == nil
        )
    }

    @MainActor
    @Test func approvalConflictFailsBeforeCallingTheProvider() async throws {
        let fixture = try pipelineEditor()
        defer {
            fixture.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: fixture.package)
        }
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "spend-conflict-before-provider",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        var providerWasCalled = false
        _ = try fixture.editor.agentService.requestSpendApproval(
            approval,
            origin: .direct,
            editor: fixture.editor,
            pipelineScope: SpendPipelineScope(
                dataRoot: fixture.dataRoot,
                phase: nil,
                tool: .generateImage,
                declaredPack: nil,
                bindingResolution: .absent
            ),
            execute: { _, _ in
                providerWasCalled = true
                return .ok("unexpected")
            }
        )
        let conflictingMutation = try #require(
            fixture.editor.pipelinePhaseRunCoordinator.beginMutation(
                projectRoot: fixture.dataRoot,
                label: "Rewind brief"
            )
        )

        await fixture.editor.agentService.approveSpend(selected)

        #expect(!providerWasCalled)
        #expect(fixture.editor.agentService.pendingSpendApproval?.id == approval.id)
        #expect(!fixture.editor.agentService.spendApprovalIsRunning)
        #expect(
            fixture.editor.agentService.spendApprovalError?.contains("Rewind brief") == true
        )
        fixture.editor.pipelinePhaseRunCoordinator.endMutation(
            projectRoot: fixture.dataRoot,
            id: conflictingMutation
        )
        fixture.editor.agentService.declineSpend()
    }

    @MainActor
    @Test func changedPipelineBindingFailsBeforeCallingTheProvider() async throws {
        let fixture = try pipelineEditor()
        defer {
            fixture.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: fixture.package)
        }
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        var providerWasCalled = false
        _ = try fixture.editor.agentService.requestSpendApproval(
            SpendApproval(
                id: "spend-binding-change",
                recommendedOptionId: selected.id,
                options: [selected],
                actionLabel: "Generate image"
            ),
            origin: .direct,
            editor: fixture.editor,
            pipelineScope: SpendPipelineScope(
                dataRoot: fixture.dataRoot,
                phase: nil,
                tool: .generateImage,
                declaredPack: nil,
                bindingResolution: .absent
            ),
            execute: { _, _ in
                providerWasCalled = true
                return .ok("unexpected")
            }
        )
        try ProjectPluginSettings.setActivePlugin(
            "musicvideo",
            projectURL: try #require(fixture.editor.workingRoot)
        )

        await fixture.editor.agentService.approveSpend(selected)

        #expect(!providerWasCalled)
        #expect(fixture.editor.agentService.pendingSpendApproval != nil)
        #expect(
            fixture.editor.agentService.spendApprovalError?
                .contains("format binding changed") == true
        )
        fixture.editor.agentService.declineSpend()
    }

    @MainActor
    @Test func embeddedApprovalKeepsItsResumeOwner() async throws {
        let editor = EditorViewModel()
        let service = AgentService(
            backend: .claudeCode,
            refreshBackendStatusOnInit: false
        )
        service.editor = editor
        service.newChat()
        let unavailable = ClaudeCodeLocator.Status(
            executableURL: nil,
            version: nil,
            isAuthenticated: false
        )
        NotificationCenter.default.post(
            name: .claudeCodeStatusChanged,
            object: unavailable
        )
        #expect(!service.canStream)
        service.isStreaming = true
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: try #require(service.currentSessionId),
            mcpSessionID: UUID()
        )
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "owned-spend",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        _ = try service.requestSpendApproval(
            approval,
            origin: origin,
            editor: editor,
            execute: { _, _ in .ok("rendered") }
        )

        await service.approveSpend(selected)
        await waitUntil { service.hasPendingHostFollowUp }

        #expect(service.pendingSpendApproval == nil)
        #expect(service.hasPendingHostFollowUp)
        #expect(service.isComposerBlocked)

        NotificationCenter.default.post(
            name: .claudeCodeStatusChanged,
            object: unavailable
        )
        service.isStreaming = false
        #expect(!service.resumePendingSpendFollowUp())
        #expect(service.hasPendingHostFollowUp)
        #expect(service.toolCallBlockReason(
            tool: .generateImage,
            args: [:],
            origin: origin
        )?.contains("suspended at a host decision") == true)
        guard case .authenticationRequired? = service.streamError else {
            Issue.record("Expected the unavailable backend to remain visible before retry")
            return
        }
    }

    @MainActor
    @Test func approvedEmbeddedImageResumesExactlyOnceWhenTheSuspendedTurnEnds() async throws {
        let editor = EditorViewModel()
        let followUp = HostFollowUpFixture()
        let service = AgentService(
            backend: .claudeCode,
            refreshBackendStatusOnInit: false,
            embeddedHostFollowUpSender: followUp.send
        )
        service.editor = editor
        service.newChat()
        NotificationCenter.default.post(
            name: .claudeCodeStatusChanged,
            object: ClaudeCodeLocator.Status(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                version: "test",
                isAuthenticated: true
            )
        )
        let sessionID = try #require(service.currentSessionId)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: sessionID,
            mcpSessionID: UUID()
        )
        let selected = option(
            modelId: "fal-ai/nano-banana-pro/edit",
            name: "Nano Banana Pro (edit)",
            provider: .fal,
            credits: 120
        )
        service.messages = [AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "lighting-anchor",
                content: [.text("The spend approval card is open. End this turn and wait for the host result; do not retry this tool call.")],
                isError: false
            ),
        ])]
        service.isStreaming = true
        _ = try service.requestSpendApproval(
            SpendApproval(
                id: "resume-image-once",
                recommendedOptionId: selected.id,
                options: [selected],
                actionLabel: "Generate image"
            ),
            origin: origin,
            editor: editor,
            execute: { _, _ in .ok("Lighting anchor rendered.") }
        )

        await service.approveSpend(selected)
        await waitUntil { service.hasPendingHostFollowUp }
        #expect(followUp.sent.isEmpty)

        service.isStreaming = false
        await waitUntil { followUp.sent.count == 1 }
        #expect(followUp.sent[0].contains("Lighting anchor rendered."))
        #expect(!service.hasPendingHostFollowUp)
        #expect(!service.resumePendingSpendFollowUp())
        #expect(followUp.sent.count == 1)
    }

    @MainActor
    @Test func approvedImageReplacesTheSuspendedResultWithVisibleMedia() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        service.newChat()
        let chatSessionID = try #require(service.currentSessionId)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: chatSessionID,
            mcpSessionID: UUID()
        )
        let selected = option(
            modelId: "fal-ai/nano-banana-pro/edit",
            name: "Nano Banana Pro (edit)",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "visible-result",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        let suspended = "The spend approval card is open. End this turn and wait for the host result; do not retry this tool call."
        service.messages = [
            AgentMessage(role: .assistant, blocks: [
                .toolUse(id: "image-tool", name: ToolName.generateImage.rawValue, inputJSON: "{}")
            ]),
            AgentMessage(role: .user, blocks: [
                .toolResult(toolUseId: "image-tool", content: [.text(suspended)], isError: false)
            ]),
        ]
        service.isStreaming = true
        _ = try service.requestSpendApproval(
            approval,
            origin: origin,
            editor: editor,
            execute: { _, _ in
                ToolResult(
                    content: [
                        .text("Generation completed. Asset ID: image-1."),
                        .image(base64: "aW1hZ2U=", mediaType: "image/png"),
                    ],
                    isError: false
                )
            }
        )

        await service.approveSpend(selected)
        await waitUntil { !service.spendApprovalIsRunning }

        let resultContent = service.messages
            .flatMap(\.blocks)
            .compactMap { block -> [ToolResult.Block]? in
                guard case .toolResult(let id, let content, _) = block,
                      id == "image-tool" else { return nil }
                return content
            }
            .first
        #expect(resultContent?.contains(where: {
            guard case .image(let base64, let mediaType) = $0 else { return false }
            return base64 == "aW1hZ2U=" && mediaType == "image/png"
        }) == true)
    }

    @MainActor
    @Test func workingCopyFailurePreservesAndRetryStartsExactEmbeddedFollowUp() async throws {
        let editor = EditorViewModel()
        let fixture = HostFollowUpFixture()
        fixture.readinessError = .upstream("The project working copy is unavailable.")
        let service = AgentService(
            backend: .claudeCode,
            refreshBackendStatusOnInit: false,
            hostFollowUpReadinessOverride: { fixture.readinessError },
            embeddedHostFollowUpSender: fixture.send
        )
        service.editor = editor
        service.newChat()
        NotificationCenter.default.post(
            name: .claudeCodeStatusChanged,
            object: ClaudeCodeLocator.Status(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                version: "test",
                isAuthenticated: true
            )
        )
        let sessionID = try #require(service.currentSessionId)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: sessionID,
            mcpSessionID: UUID()
        )
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "working-copy-retry",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        service.messages = [AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "working-copy-image",
                content: [.text("The spend approval card is open. End this turn and wait for the host result; do not retry this tool call.")],
                isError: false
            ),
        ])]
        service.isStreaming = true
        _ = try service.requestSpendApproval(
            approval,
            origin: origin,
            editor: editor,
            execute: { _, _ in .ok("rendered") }
        )

        await service.approveSpend(selected)
        await waitUntil { service.hasPendingHostFollowUp }
        service.isStreaming = false
        #expect(!service.resumePendingSpendFollowUp())
        #expect(service.hasPendingHostFollowUp)
        #expect(fixture.sent.isEmpty)
        #expect(service.streamError?.errorDescription?.contains("working copy") == true)

        fixture.readinessError = nil
        service.retryPendingHostFollowUp()
        #expect(!service.hasPendingHostFollowUp)
        #expect(fixture.sent.count == 1)
        #expect(fixture.sent[0].contains("Host generation result: rendered"))
        #expect(service.currentSessionId == sessionID)
    }

    @MainActor
    @Test func completedImageReturnsToItsOriginatingChatAfterTabSwitch() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        service.newChat()
        let originSessionID = try #require(service.currentSessionId)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: originSessionID,
            mcpSessionID: UUID()
        )
        let selected = option(
            modelId: "fal-ai/nano-banana-pro/edit",
            name: "Nano Banana Pro (edit)",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "tab-switch-result",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        service.messages = [AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "image-tool",
                content: [.text("The spend approval card is open. End this turn and wait for the host result; do not retry this tool call.")],
                isError: false
            ),
        ])]
        let fixture = PendingExecutionFixture()
        _ = try service.requestSpendApproval(
            approval,
            origin: origin,
            editor: editor,
            execute: { _, _ in
                await fixture.wait()
                return ToolResult(
                    content: [
                        .text("Generation completed. Asset ID: switched-image."),
                        .image(base64: "c3dpdGNoZWQ=", mediaType: "image/png"),
                    ],
                    isError: false
                )
            }
        )

        await service.approveSpend(selected)
        #expect(service.spendApprovalIsRunning)
        await waitUntil { fixture.didStart }
        service.newChat()
        let newSessionID = try #require(service.currentSessionId)
        #expect(newSessionID != originSessionID)
        #expect(service.currentSpendRun == nil)
        #expect(!service.isComposerBlocked)

        fixture.finish()
        await waitUntil { !service.spendApprovalIsRunning }

        #expect(service.currentSessionId == newSessionID)
        #expect(!service.hasPendingHostFollowUp)

        let originSession = try #require(
            service.sessions.first(where: { $0.id == originSessionID })
        )
        #expect(originSession.messages.flatMap(\.blocks).contains { block in
            guard case .toolResult(_, let content, _) = block else { return false }
            return content.contains {
                guard case .image(let base64, _) = $0 else { return false }
                return base64 == "c3dpdGNoZWQ="
            }
        })

        service.selectSession(originSessionID)
        #expect(service.currentSessionId == originSessionID)
        #expect(service.hasPendingHostFollowUp)
    }

    @MainActor
    @Test func runningGenerationCanBeCancelledAndSettlesExactlyOnce() async throws {
        let fixture = try pipelineEditor()
        defer {
            fixture.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: fixture.package)
        }
        let editor = fixture.editor
        let service = editor.agentService
        service.newChat()
        let sessionID = try #require(service.currentSessionId)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: sessionID,
            mcpSessionID: UUID()
        )
        let selected = option(
            modelId: "fal-ai/nano-banana-pro/edit",
            name: "Nano Banana Pro (edit)",
            provider: .fal,
            credits: 120
        )
        let approval = SpendApproval(
            id: "cancel-running-spend",
            recommendedOptionId: selected.id,
            options: [selected],
            actionLabel: "Generate image"
        )
        service.messages = [AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "cancelled-image",
                content: [.text("The spend approval card is open. End this turn and wait for the host result; do not retry this tool call.")],
                isError: false
            ),
        ])]
        service.isStreaming = true
        var didStart = false
        var cancellationCount = 0
        _ = try service.requestSpendApproval(
            approval,
            origin: origin,
            editor: editor,
            pipelineScope: SpendPipelineScope(
                dataRoot: fixture.dataRoot,
                phase: nil,
                tool: .generateImage,
                declaredPack: nil,
                bindingResolution: .absent
            ),
            cancel: { _ in cancellationCount += 1 },
            execute: { _, _ in
                didStart = true
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return .ok("unexpected")
            }
        )

        await service.approveSpend(selected)
        await waitUntil { didStart }
        #expect(service.currentSpendRun?.cancellationRequested == false)

        service.cancelRunningSpend()
        service.cancelRunningSpend()
        #expect(service.currentSpendRun?.cancellationRequested == true)
        await waitUntil { !service.spendApprovalIsRunning }

        #expect(cancellationCount == 1)
        #expect(service.hasPendingHostFollowUp)
        #expect(
            editor.pipelinePhaseRunCoordinator.runningPhase(
                projectRoot: fixture.dataRoot
            ) == nil
        )
        let results = service.messages.flatMap(\.blocks).compactMap { block -> ([ToolResult.Block], Bool)? in
            guard case .toolResult(let id, let content, let isError) = block,
                  id == "cancelled-image" else { return nil }
            return (content, isError)
        }
        #expect(results.count == 1)
        #expect(results.first?.1 == true)
        let cancelledContent = try #require(results.first?.0)
        #expect(cancelledContent.contains { block in
            guard case .text(let text) = block else { return false }
            return text == "Generation cancelled."
        })
    }

    @MainActor
    @Test func completedSpendFollowUpsRemainOwnedByEachInactiveChat() async throws {
        let editor = EditorViewModel()
        let followUps = HostFollowUpFixture()
        let service = AgentService(
            backend: .claudeCode,
            refreshBackendStatusOnInit: false,
            embeddedHostFollowUpSender: followUps.send
        )
        service.editor = editor
        service.newChat()
        NotificationCenter.default.post(
            name: .claudeCodeStatusChanged,
            object: ClaudeCodeLocator.Status(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                version: "test",
                isAuthenticated: true
            )
        )

        let firstSessionID = try #require(service.currentSessionId)
        let firstOrigin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: firstSessionID,
            mcpSessionID: UUID()
        )
        let selected = option(
            modelId: "m1",
            name: "Model One",
            provider: .fal,
            credits: 120
        )
        let suspensionText = "The spend approval card is open. End this turn and wait for the host result; do not retry this tool call."
        service.messages = [AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "first-image",
                content: [.text(suspensionText)],
                isError: false
            ),
        ])]
        let firstExecution = PendingExecutionFixture()
        _ = try service.requestSpendApproval(
            SpendApproval(
                id: "first-inactive-chat",
                recommendedOptionId: selected.id,
                options: [selected],
                actionLabel: "Generate first image"
            ),
            origin: firstOrigin,
            editor: editor,
            execute: { _, _ in
                await firstExecution.wait()
                return .ok("first chat result")
            }
        )

        await service.approveSpend(selected)
        await waitUntil { firstExecution.didStart }
        service.newChat()
        let secondSessionID = try #require(service.currentSessionId)
        firstExecution.finish()
        await waitUntil { !service.spendApprovalIsRunning }

        let secondOrigin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: secondSessionID,
            mcpSessionID: UUID()
        )
        service.messages = [AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "second-image",
                content: [.text(suspensionText)],
                isError: false
            ),
        ])]
        let secondExecution = PendingExecutionFixture()
        _ = try service.requestSpendApproval(
            SpendApproval(
                id: "second-inactive-chat",
                recommendedOptionId: selected.id,
                options: [selected],
                actionLabel: "Generate second image"
            ),
            origin: secondOrigin,
            editor: editor,
            execute: { _, _ in
                await secondExecution.wait()
                return .ok("second chat result")
            }
        )

        await service.approveSpend(selected)
        await waitUntil { secondExecution.didStart }
        service.newChat()
        let inactiveSessionID = try #require(service.currentSessionId)
        secondExecution.finish()
        await waitUntil { !service.spendApprovalIsRunning }

        #expect(service.currentSessionId == inactiveSessionID)
        #expect(!service.hasPendingHostFollowUp)
        #expect(followUps.sent.isEmpty)

        service.selectSession(firstSessionID)
        await waitUntil { followUps.sent.count == 1 }
        let firstFollowUp = try #require(followUps.sent.first)
        #expect(firstFollowUp.contains("Host generation result: first chat result"))
        #expect(!firstFollowUp.contains("second chat result"))
        #expect(!service.hasPendingHostFollowUp)

        service.selectSession(secondSessionID)
        await waitUntil { followUps.sent.count == 2 }
        let secondFollowUp = try #require(followUps.sent.dropFirst().first)
        #expect(secondFollowUp.contains("Host generation result: second chat result"))
        #expect(!secondFollowUp.contains("first chat result"))
        #expect(!service.hasPendingHostFollowUp)
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
        service.messages = [AgentMessage(role: .user, blocks: [
            .toolResult(
                toolUseId: "pending-image",
                content: [.text("The spend approval card is open. End this turn and wait for the host result; do not retry this tool call.")],
                isError: false
            ),
        ])]
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
        #expect(service.toolCallBlockReason(
            tool: .generateImage,
            args: [:],
            origin: origin
        ) == nil)
        #expect(service.messages.flatMap(\.blocks).contains { block in
            guard case .toolResult(let id, _, let isError) = block else { return false }
            return id == "pending-image" && isError
        })
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
        await waitUntil { !service.spendApprovalIsRunning }

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
        await waitUntil { !service.spendApprovalIsRunning }
        #expect(service.pendingSpendApproval == nil)
    }
}
