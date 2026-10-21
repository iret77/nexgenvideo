import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

/// Covers durable user-gate requests and host-owned decisions.
@MainActor
@Suite("Gate approval — the user's decision (HAX G11)")
struct GateApprovalTests {

    // MARK: - Pure model

    @Test("GateApproval carries the human phase label, not the raw id")
    func carriesHumanPhaseLabel() {
        let approval = GateApproval(phase: "brief", notes: "looks good")
        #expect(approval.phase == "brief")
        #expect(approval.phaseLabel == PhaseDisplay.label("brief"))
        #expect(approval.phaseLabel == "Brief")
        #expect(approval.notes == "looks good")
        #expect(approval.sourceToolName == ToolName.approveGate.rawValue)

        // A snake_case id resolves to its curated title, never leaking the raw key to the card.
        #expect(GateApproval(phase: "production_design").phaseLabel == "Production Design")
    }

    @Test("gate approvals preserve the requesting tool for diagnostics")
    func preservesSourceTool() {
        let approval = GateApproval(
            phase: "brief",
            sourceToolName: ToolName.setGateState.rawValue
        )

        #expect(approval.scoped(to: UUID()).sourceToolName == ToolName.setGateState.rawValue)
        #expect(!approval.matchesRequest(GateApproval(phase: "brief")))
    }

    @Test("Only the approving states surface a user confirmation")
    func onlyApprovingStatesNeedConfirmation() {
        #expect(GateApproval.isApproval(.approved))
        #expect(GateApproval.isApproval(.approvedWithNotes))
        #expect(GateApproval.isApproval(.needsRevision) == false)
        #expect(GateApproval.isApproval(.pending) == false)
    }

    // MARK: - Request / resolve seam

    @Test("requestGateApproval returns immediately and leaves one durable card")
    func requestReturnsPending() throws {
        let editor = EditorViewModel()
        let service = editor.agentService

        let request = try service.requestGateApproval(GateApproval(phase: "brief"))
        #expect(request.isNew)
        #expect(service.pendingGateApproval?.phase == "brief")
    }

    @Test("A retry preserves the original card and request id")
    func retryIsIdempotent() throws {
        let editor = EditorViewModel()
        let service = editor.agentService

        let first = try service.requestGateApproval(GateApproval(phase: "brief"))
        let retry = try service.requestGateApproval(GateApproval(phase: "brief"))

        #expect(retry.isNew == false)
        #expect(retry.matchesRequestedApproval)
        #expect(retry.approval.id == first.approval.id)
        #expect(service.pendingGateApproval?.id == first.approval.id)
    }

    @Test("A competing request cannot replace the open card")
    func competingRequestKeepsFirstCard() throws {
        let editor = EditorViewModel()
        let service = editor.agentService

        let first = try service.requestGateApproval(GateApproval(phase: "brief"))
        let competing = try service.requestGateApproval(GateApproval(phase: "analysis"))

        #expect(competing.isNew == false)
        #expect(competing.matchesRequestedApproval == false)
        #expect(competing.approval.id == first.approval.id)
        #expect(service.pendingGateApproval?.phase == "brief")

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
        #expect(service.pendingGateApproval?.id == first.approval.id)
    }

    @Test("A dialog prevents a gate card from being added")
    func dialogBlocksGateRequest() throws {
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

        #expect(throws: ToolError.self) {
            try service.requestGateApproval(GateApproval(phase: "brief"))
        }
        #expect(service.pendingGateApproval == nil)
        #expect(service.pendingDialog?.id == dialog.id)
    }

    @Test("A native gate mutation and composer decisions exclude each other")
    func nativeGateMutationOwnsDecisionBoundary() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let mutationID = try #require(service.beginNativeGateMutation())

        #expect(throws: ToolError.self) {
            try service.requestGateApproval(GateApproval(phase: "brief"))
        }
        let option = SpendOption(
            modelId: "model",
            modelName: "Model",
            target: ResolvedGenerationTarget(
                modelId: "model",
                provider: .fal,
                endpoint: "model",
                binding: nil
            ),
            credits: 1,
            requiresCatalogAvailability: false
        )
        let spend = SpendApproval(
            id: "spend",
            recommendedOptionId: option.id,
            options: [option],
            actionLabel: "Generate image"
        )
        #expect(throws: ToolError.self) {
            try service.requestSpendApproval(
                spend,
                origin: .direct,
                editor: editor,
                execute: { _, _ in .ok("unexpected") }
            )
        }

        service.endNativeGateMutation(mutationID)
        #expect(try service.requestGateApproval(GateApproval(phase: "brief")).isNew)
        #expect(service.beginNativeGateMutation() == nil)
    }

    @Test("Cancelling the model transport does not decide or remove the gate")
    func transportCancellationKeepsCard() throws {
        let editor = EditorViewModel()
        let service = editor.agentService

        _ = try service.requestGateApproval(GateApproval(phase: "brief"))
        service.cancel()

        #expect(service.pendingGateApproval?.phase == "brief")
    }

    @Test("Declining is an explicit decision and clears the card")
    func declineClears() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService

        _ = try service.requestGateApproval(GateApproval(phase: "brief"))
        let result = await service.resolveGate(.declined, approvalID: service.pendingGateApproval?.id ?? "missing")

        #expect(result?.isError == false)
        #expect(service.pendingGateApproval == nil)
    }

    @Test("A delayed decision cannot resolve a replacement approval", arguments: [GateDecision.approved, .declined])
    func delayedDecisionKeepsReplacement(decision: GateDecision) async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let original = try service.requestGateApproval(GateApproval(phase: "brief")).approval
        _ = await service.resolveGate(.declined, approvalID: original.id)
        let replacement = try service.requestGateApproval(GateApproval(phase: "analysis")).approval
        let result = await service.resolveGate(decision, approvalID: original.id)
        #expect(result == nil)
        #expect(service.pendingGateApproval?.id == replacement.id)
        #expect(service.gateApprovalError == nil)
        #expect(!service.gateApprovalIsWriting)
    }

    @Test("an embedded gate keeps its resume owner")
    func embeddedGateKeepsResumeOwner() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        service.newChat()
        service.isStreaming = true
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: try #require(service.currentSessionId),
            runtimeGenerationID: UUID()
        )

        _ = try service.requestGateApproval(
            GateApproval(phase: "brief"),
            origin: origin
        )
        _ = await service.resolveGate(.declined, approvalID: service.pendingGateApproval?.id ?? "missing")

        #expect(service.pendingGateApproval == nil)
        #expect(service.hasPendingHostFollowUp)
        #expect(service.isComposerBlocked)

        service.isStreaming = false
        #expect(!service.resumePendingGateFollowUp())
        #expect(service.hasPendingHostFollowUp)
    }

    @Test("An external MCP approval does not start an unrelated in-app turn")
    func externalApprovalDoesNotSendInAppMessage() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService

        _ = try service.requestGateApproval(GateApproval(phase: "brief"))
        _ = await service.resolveGate(.declined, approvalID: service.pendingGateApproval?.id ?? "missing")
        await Task.yield()

        #expect(service.messages.isEmpty)
        #expect(service.streamError?.errorDescription == nil)
    }

    @Test("caller origin, never global streaming state, owns gate resumption")
    func explicitCallerOriginOwnsResumption() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        service.newChat()
        service.isStreaming = true
        let unrelatedChat = try #require(service.currentSessionId)
        let externalSession = UUID()

        _ = try service.requestGateApproval(
            GateApproval(phase: "brief"),
            origin: .externalMCP(sessionID: externalSession)
        )
        #expect(service.pendingGateApproval?.sessionId == nil)
        _ = await service.resolveGate(.declined, approvalID: service.pendingGateApproval?.id ?? "missing")
        #expect(service.messages.isEmpty)

        _ = try service.requestGateApproval(
            GateApproval(phase: "brief"),
            origin: .embeddedRuntime(
                chatSessionID: unrelatedChat,
                runtimeGenerationID: UUID()
            )
        )
        #expect(service.pendingGateApproval?.sessionId == unrelatedChat)
    }

    @Test("an unknown embedded chat header is treated as external MCP")
    func unknownEmbeddedChatCannotClaimResumption() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }

        let result = await h.executor.execute(
            name: "approve_gate",
            args: ["project_dir": dataRoot.path, "phase": "project_init"],
            origin: .embeddedRuntime(
                chatSessionID: UUID(),
                runtimeGenerationID: UUID()
            )
        )

        #expect(result.turnDisposition == .suspendTurn)
        #expect(h.editor.agentService.pendingGateApproval?.sessionId == nil)
    }

    @Test("approve_gate returns approval_pending without waiting or writing")
    func toolReturnsPending() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }

        let result = await h.runRaw(
            "approve_gate",
            args: ["project_dir": dataRoot.path, "phase": "project_init"]
        )
        let payload = try JSONSerialization.jsonObject(
            with: Data(ToolHarness.textOf(result).utf8)
        ) as? [String: Any]

        #expect(result.isError == false)
        #expect(result.turnDisposition == .suspendTurn)
        #expect(payload?["status"] as? String == "approval_pending")
        #expect(payload?["approval_surface"] as? String == "Tasks")
        let route = PipelineSurfaceRouting.route(for: "project_init", contract: h.editor.uiContract,
            availablePackSurfaces: h.editor.availableCockpitPackSurfaces)
        #expect(payload?["review_surface"] as? String == (route?.destinationLabel ?? "Pipeline"))
        #expect(h.editor.agentService.pendingGateApproval?.phase == "project_init")

        let state = try await h.runOK("get_project_state", args: ["project_dir": dataRoot.path]) as? [String: Any]
        let phases = try #require(state?["phases"] as? [[String: Any]])
        #expect(phases.first { $0["phase"] as? String == "project_init" }?["state"] as? String == "pending")
    }

    @Test("a pending gate records checked without recording approval")
    func pendingGateRecordsCheckedState() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        h.editor.agentService.newChat()
        let sessionID = try #require(h.editor.agentService.currentSessionId)
        h.editor.agentService.messages = [AgentMessage(
            role: .assistant,
            blocks: [.toolUse(id: "gate", name: "approve_gate", inputJSON: "{}")]
        )]

        let result = await h.executor.execute(
            name: "approve_gate",
            args: ["project_dir": dataRoot.path, "phase": "project_init"],
            origin: .inAppChat(sessionID: sessionID),
            toolUseID: "gate"
        )

        #expect(!result.isError)
        #expect(result.turnDisposition == .suspendTurn)
        let state = h.editor.agentService.messages.flatMap(\.hostStateRecords).last
        #expect(state?.state == .checked)
        #expect(state?.state != .approved)
        #expect(h.editor.agentService.pendingGateApproval?.phase == "project_init")
    }

    @Test("set_gate_state approval request does not mark the project edited")
    func setStateApprovalRequestDoesNotDirty() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        var dirtied = 0
        h.editor.onPipelineChanged = { dirtied += 1 }

        let result = await h.runRaw("set_gate_state", args: [
            "project_dir": dataRoot.path,
            "phase": "project_init",
            "state": "approved",
        ])
        let payload = try JSONSerialization.jsonObject(
            with: Data(ToolHarness.textOf(result).utf8)
        ) as? [String: Any]

        #expect(payload?["status"] as? String == "approval_pending")
        #expect(dirtied == 0)
    }

    @Test("set_gate_state immediate write marks the project edited once")
    func setStateImmediateWriteDirtiesOnce() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        var dirtied = 0
        h.editor.onPipelineChanged = { dirtied += 1 }

        let result = await h.runRaw("set_gate_state", args: [
            "project_dir": dataRoot.path,
            "phase": "project_init",
            "state": "needs_revision",
        ])

        #expect(result.isError == false)
        #expect(dirtied == 1)
    }

    @Test("set_gate_state cannot mark an unreached phase for revision")
    func setStateRejectsFuturePhase() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }

        let result = await h.runRaw("set_gate_state", args: [
            "project_dir": dataRoot.path,
            "phase": "brief",
            "state": "needs_revision",
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("future phase"))
    }

    @Test("a missing project keeps approval open for reopen recovery")
    func missingProjectKeepsApprovalOpen() async throws {
        let (h, savedRoot, cleanup) = try scaffold()
        let home = FrameInventory.projectHome(of: savedRoot)
        try Fixtures.prepareProjectPackage(at: home)
        h.editor.projectURL = home
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let service = h.editor.agentService
        let liveRoot = try #require(h.editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) })
        let request = try service.requestGateApproval(GateApproval(
            phase: "project_init",
            dataRoot: liveRoot
        ))
        try FileManager.default.removeItem(at: liveRoot)
        let review = GateReviewModel()
        #expect(review.isChecking)
        await review.refresh(approval: request.approval, editor: h.editor)
        #expect(!review.isChecking)
        #expect(!review.isReady)
        #expect(review.readyApprovalID == nil)
        #expect(review.blocker != nil)
        let result = await service.resolveGate(.approved, approvalID: service.pendingGateApproval?.id ?? "missing")

        #expect(result?.isError == true)
        #expect(service.pendingGateApproval?.id == request.approval.id)
        #expect(service.pendingGateApproval?.phase == "project_init")
        #expect(service.gateApprovalError?.contains("Reopen") == true)
    }

    @Test("a competing approval never records checked for the requested phase")
    func competingApprovalDoesNotRecordChecked() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let service = h.editor.agentService
        service.newChat()
        let sessionID = try #require(service.currentSessionId)
        let origin = ToolCallOrigin.inAppChat(sessionID: sessionID)
        service.messages = [AgentMessage(
            role: .assistant,
            blocks: [.toolUse(id: "competing", name: "approve_gate", inputJSON: "{}")]
        )]
        _ = try service.requestGateApproval(
            GateApproval(phase: "brief"),
            origin: origin
        )

        let result = await h.executor.execute(
            name: "approve_gate",
            args: ["project_dir": dataRoot.path, "phase": "project_init"],
            origin: origin,
            toolUseID: "competing"
        )

        #expect(!result.isError)
        #expect(result.turnDisposition == .suspendTurn)
        #expect(service.pendingGateApproval?.phase == "brief")
        #expect(service.messages.flatMap(\.hostStateRecords).isEmpty)
    }

    @Test("gate structure failure is agent correction, not wait-and-retry")
    func gateStructureFailureIsAgentCorrection() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let service = h.editor.agentService
        service.newChat()
        let sessionID = try #require(service.currentSessionId)
        service.messages = [AgentMessage(
            role: .assistant,
            blocks: [.toolUse(id: "gate", name: "approve_gate", inputJSON: "{}")]
        )]
        let pending = await h.executor.execute(
            name: "approve_gate",
            args: ["project_dir": dataRoot.path, "phase": "project_init"],
            origin: .inAppChat(sessionID: sessionID),
            toolUseID: "gate"
        )
        #expect(!pending.isError)
        try FileManager.default.removeItem(
            at: PipelineLayout.url(PipelineLayout.gatesFile, in: dataRoot)
        )

        let result = await service.resolveGate(.approved, approvalID: service.pendingGateApproval?.id ?? "missing")

        #expect(result?.isError == true)
        #expect(service.pendingGateApproval == nil)
        let state = try #require(service.messages.flatMap(\.hostStateRecords).last)
        #expect(state.state == .approvalFailed)
        #expect(state.action == .agentCorrection)
    }

    @Test("An approved gate cannot resume the agent across a host-owned intake card")
    func approvalDefersFollowUpUntilIntakeCompletes() async throws {
        let (h, savedRoot, cleanup) = try scaffold()
        let home = FrameInventory.projectHome(of: savedRoot)
        try Fixtures.prepareProjectPackage(at: home)
        h.editor.projectURL = home
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let dataRoot = try #require(h.editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) })
        let service = h.editor.agentService
        service.newChat()
        service.isStreaming = true
        _ = try service.requestGateApproval(GateApproval(
            phase: "project_init",
            dataRoot: dataRoot
        ), origin: .inAppChat(sessionID: try #require(service.currentSessionId)))
        service.isStreaming = false

        let intake = AgentDialog(
            id: "hardstep.brief.script",
            title: "Existing story",
            symbol: "doc.text",
            intro: nil,
            costHint: nil,
            confirmLabel: "Continue",
            textField: nil,
            sections: [],
            fileIntake: AgentDialog.FileIntake(
                accept: ["text"],
                prompt: nil,
                allowsMultiple: false,
                attachAs: "script",
                namePrompt: nil,
                required: false
            ),
            purpose: .workflowIntake
        )
        let result = await service.resolveGate(.approved, approvalID: service.pendingGateApproval?.id ?? "missing")
        #expect(result?.isError == false)
        try service.presentDialog(intake)
        #expect(!service.resumePendingGateFollowUp())
        await Task.yield()
        #expect(service.pendingDialog?.id == intake.id)

        service.abandonDialog()
        #expect(!service.resumePendingGateFollowUp())
        #expect(service.hasPendingHostFollowUp)
    }

    @Test("a gate decision suspends the tool batch before later calls execute")
    func gateSuspendsRemainingToolBatch() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let service = h.editor.agentService
        service.newChat()
        let sessionID = try #require(service.currentSessionId)
        let assistant = AgentMessage(
            role: .assistant,
            blocks: [
                .toolUse(
                    id: "gate",
                    name: "approve_gate",
                    inputJSON: "{\"project_dir\":\"\(dataRoot.path)\",\"phase\":\"project_init\"}"
                ),
                .toolUse(id: "later", name: "get_timeline", inputJSON: "{}"),
            ]
        )
        service.messages = [assistant]

        let suspended = await service.runPendingToolUses(
            assistantID: assistant.id,
            origin: .inAppChat(sessionID: sessionID)
        )

        #expect(suspended)
        let results = try #require(service.messages.last?.blocks)
        #expect(results.count == 2)
        guard case .toolResult(_, _, let gateError) = results[0],
              case .toolResult(_, let laterContent, let laterError) = results[1]
        else {
            Issue.record("Expected one gate result and one skipped result")
            return
        }
        #expect(!gateError)
        #expect(laterError)
        #expect(laterContent.contains { block in
            if case .text(let text) = block {
                return text.contains("Not executed")
            }
            return false
        })
    }

    @Test("fast external resolution keeps the old logical MCP turn fenced")
    func fastExternalResolutionKeepsTurnFenced() async throws {
        let h = ToolHarness()
        let origin = ToolCallOrigin.externalMCP(sessionID: UUID())

        _ = try h.editor.agentService.requestGateApproval(
            GateApproval(phase: "brief"),
            origin: origin
        )
        _ = await h.editor.agentService.resolveGate(.declined, approvalID: h.editor.agentService.pendingGateApproval?.id ?? "missing")

        let stale = await h.executor.execute(
            name: "get_timeline",
            args: [:],
            origin: origin
        )
        #expect(stale.isError)
        #expect(ToolHarness.textOf(stale).contains("logical agent turn is suspended"))

        let reinitialized = await h.executor.execute(
            name: "get_timeline",
            args: [:],
            origin: .externalMCP(sessionID: UUID())
        )
        #expect(!reinitialized.isError)
    }

    @Test("an embedded follow-up cannot revive its superseded MCP turn")
    func embeddedFollowUpKeepsOldMCPSessionFenced() async throws {
        let h = ToolHarness()
        h.editor.agentService.newChat()
        let chatID = try #require(h.editor.agentService.currentSessionId)
        let origin = ToolCallOrigin.embeddedRuntime(
            chatSessionID: chatID,
            runtimeGenerationID: UUID()
        )

        _ = try h.editor.agentService.requestGateApproval(
            GateApproval(phase: "brief"),
            origin: origin
        )
        _ = await h.editor.agentService.resolveGate(.declined, approvalID: h.editor.agentService.pendingGateApproval?.id ?? "missing")
        #expect(!h.editor.agentService.resumePendingGateFollowUp())
        #expect(h.editor.agentService.hasPendingHostFollowUp)

        let stale = await h.executor.execute(
            name: "get_timeline",
            args: [:],
            origin: origin
        )
        #expect(stale.isError)

        let replacement = await h.executor.execute(
            name: "get_timeline",
            args: [:],
            origin: .embeddedRuntime(
                chatSessionID: chatID,
                runtimeGenerationID: UUID()
            )
        )
        #expect(!replacement.isError)
    }

    @Test("Deleting a chat clears its gate follow-up and resumes its tool origin")
    func deletingChatClearsGateFollowUp() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        service.newChat()
        service.isStreaming = true
        let chatID = try #require(service.currentSessionId)
        let origin = ToolCallOrigin.inAppChat(sessionID: chatID)

        _ = try service.requestGateApproval(
            GateApproval(phase: "brief"),
            origin: origin
        )
        _ = await service.resolveGate(.declined, approvalID: service.pendingGateApproval?.id ?? "missing")
        #expect(service.toolCallBlockReason(
            tool: .getTimeline,
            args: [:],
            origin: origin
        ) != nil)

        service.deleteSession(chatID)

        #expect(!service.hasPendingHostFollowUp)
        #expect(service.toolCallBlockReason(
            tool: .getTimeline,
            args: [:],
            origin: origin
        ) == nil)
    }

    @Test("Reconnected revision requests reuse the pending host decision")
    func revisionRetryIsIdempotent() throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let origin = ToolCallOrigin.externalMCP(sessionID: UUID())
        let approval = GateApproval(phase: "storyboard",
            action: .rewind(gatesSHA256: "unchanged", phases: ["storyboard", "bible"]),
            sourceToolName: ToolName.rewind.rawValue)
        let first = try service.requestGateApproval(approval, origin: origin)
        #expect(service.toolCallBlockReason(tool: .rewind,
            args: ["target_phase": "storyboard"], origin: origin) == nil)
        let retry = try service.requestGateApproval(approval, origin: origin)
        #expect(!retry.isNew)
        #expect(first.approval.id == retry.approval.id)
        #expect(service.toolCallBlockReason(tool: .writeShotlist, args: [:], origin: origin) != nil)
    }

    @Test("External repair recovery stays visible and unblocks only its own origin")
    func externalRepairRecovery() {
        let editor = EditorViewModel()
        let service = editor.agentService
        service.newChat()
        let origin = ToolCallOrigin.externalMCP(sessionID: UUID())
        let other = ToolCallOrigin.externalMCP(sessionID: UUID())
        service.pausePipelineRepair(tool: "write_shotlist", detail: "invalid input", origin: origin)
        #expect(service.currentPipelineRepairFailure != nil)
        #expect(service.toolCallBlockReason(tool: .getProjectState, args: [:], origin: origin) != nil)
        service.clearPipelineRepair(origin: other)
        #expect(service.currentPipelineRepairFailure != nil)
        service.retryPipelineRepair()
        #expect(service.currentPipelineRepairFailure == nil)
        #expect(service.toolCallBlockReason(tool: .getProjectState, args: [:], origin: origin) == nil)
        #expect(!service.hasPendingHostFollowUp)
    }

    @Test("root-bound approvals reject unopened, foreign, or differently declared projects",
          arguments: ["unopened", "foreign-root", "different-workflow"])
    func rootedApprovalRequiresMatchingOpenedProject(scope: String) throws {
        let (h, savedRoot, cleanup) = try scaffold()
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        var root = savedRoot
        if scope != "unopened" { root = try h.openProject(dataRoot: savedRoot) }
        var requestedRoot = root
        if scope == "foreign-root" {
            requestedRoot = try ProjectScaffold.initProject(
                home: cleanup.appendingPathComponent("other", isDirectory: true), name: "other", mode: .beat)
        }
        let gatesURL = PipelineLayout.url(PipelineLayout.gatesFile, in: requestedRoot)
        let before = try Data(contentsOf: gatesURL)
        #expect(h.editor.declaredProductionContract == nil)

        #expect(throws: ToolError.self) {
            try h.editor.agentService.requestGateApproval(GateApproval(
                phase: "project_init", dataRoot: requestedRoot,
                declaredProductionContract: scope == "different-workflow" ? .current : nil))
        }

        #expect(h.editor.agentService.pendingGateApproval == nil)
        #expect(try Data(contentsOf: gatesURL) == before)
    }

    // MARK: - Tool outcome (approve writes, decline does not)

    private func scaffold(openProject: Bool = false) throws -> (ToolHarness, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-approval-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        let harness = ToolHarness()
        let root: URL
        if openProject { root = try harness.openProject(dataRoot: dataRoot) }
        else { root = dataRoot }
        return (harness, root, tmp)
    }

    @Test("approve_gate declined leaves the gate unwritten and tells the agent to stay on the phase")
    func declineDoesNotWrite() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let dir = dataRoot.path

        // A decline wrote nothing, so it must NOT mark the document edited — otherwise the user is
        // prompted to save changes that never happened.
        var dirtied = 0
        h.editor.onPipelineChanged = { dirtied += 1 }

        let result = await h.runGate("approve_gate", args: ["project_dir": dir, "phase": "project_init"], decision: .declined)
        // A decline is NOT an error — it's a non-error result steering the agent back to the phase.
        #expect(result.isError == false)
        #expect(ToolHarness.textOf(result).contains("did not approve"))
        #expect(h.editor.agentService.pendingGateApproval == nil)
        #expect(dirtied == 0)

        // The gate was never written — project_init is still pending.
        let state = try await h.runOK("get_project_state", args: ["project_dir": dir]) as? [String: Any]
        let phases = try #require(state?["phases"] as? [[String: Any]])
        let projectInit = phases.first { $0["phase"] as? String == "project_init" }
        #expect(projectInit?["state"] as? String == "pending")
    }

    @Test("approve_gate approved writes the gate")
    func approveWrites() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let dir = dataRoot.path

        var dirtied = 0
        h.editor.onPipelineChanged = { dirtied += 1 }

        let approved = try await h.runGateOK("approve_gate", args: ["project_dir": dir, "phase": "project_init"]) as? [String: Any]
        #expect(approved?["approved"] as? Bool == true)
        #expect(h.editor.agentService.pendingGateApproval == nil)
        // A real write DID mark the document edited, so ⌘S persists it.
        #expect(dirtied == 1)

        let state = try await h.runOK("get_project_state", args: ["project_dir": dir]) as? [String: Any]
        let phases = try #require(state?["phases"] as? [[String: Any]])
        let projectInit = phases.first { $0["phase"] as? String == "project_init" }
        #expect(projectInit?["state"] as? String == "approved")
    }

    @Test("Project reload cannot replace an approval before its commit returns")
    func projectReloadDuringCommitKeepsDecisionOwnership() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let service = h.editor.agentService
        let requested = await h.runRaw("approve_gate", args: ["project_dir": dataRoot.path, "phase": "project_init"])
        #expect(!requested.isError)
        let original = try #require(service.pendingGateApproval)
        var observedCommit = false
        var replacementBlocked = false
        h.editor.onPipelineChanged = {
            observedCommit = service.gateApprovalIsWriting
            service.loadSessions(from: nil)
            do { _ = try service.requestGateApproval(GateApproval(phase: "analysis")) }
            catch is ToolError { replacementBlocked = true }
            catch { Issue.record("Unexpected replacement refusal: \(error)") }
        }
        let result = await service.resolveGate(.approved, approvalID: original.id)
        h.editor.onPipelineChanged = nil
        #expect(result?.isError == false)
        #expect(observedCommit)
        #expect(replacementBlocked)
        #expect(!service.gateApprovalIsWriting)
        let replacement = try service.requestGateApproval(GateApproval(phase: "analysis")).approval
        #expect(service.pendingGateApproval?.id == replacement.id)
        #expect(service.gateApprovalError == nil)
    }

    @Test("approval click keeps its card open when pipeline mutation owns the project")
    func approvalClickWaitsForPipelineMutation() async throws {
        let (h, dataRoot, cleanup) = try scaffold(openProject: true)
        defer {
            h.editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: cleanup)
        }
        let args: [String: Any] = [
            "project_dir": dataRoot.path,
            "phase": "project_init",
        ]
        let pending = await h.executor.execute(name: "approve_gate", args: args)
        #expect(!pending.isError)
        #expect(h.editor.agentService.pendingGateApproval?.phase == "project_init")

        let competingMutation = try #require(
            h.editor.pipelinePhaseRunCoordinator.beginMutation(
                projectRoot: dataRoot,
                label: "record_render"
            )
        )
        let blockedResult = await h.editor.agentService.resolveGate(.approved, approvalID: h.editor.agentService.pendingGateApproval?.id ?? "missing")
        let blocked = try #require(blockedResult)
        #expect(blocked.isError)
        #expect(ToolHarness.textOf(blocked).contains("record_render"))
        #expect(h.editor.agentService.pendingGateApproval?.phase == "project_init")

        h.editor.pipelinePhaseRunCoordinator.endMutation(
            projectRoot: dataRoot,
            id: competingMutation
        )
        let approvedResult = await h.editor.agentService.resolveGate(.approved, approvalID: h.editor.agentService.pendingGateApproval?.id ?? "missing")
        let approved = try #require(approvedResult)
        #expect(!approved.isError)
        #expect(h.editor.agentService.pendingGateApproval == nil)
    }
}
