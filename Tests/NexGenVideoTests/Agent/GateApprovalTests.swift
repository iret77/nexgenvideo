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

        // A snake_case id resolves to its curated title, never leaking the raw key to the card.
        #expect(GateApproval(phase: "production_design").phaseLabel == "Production Design")
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
        #expect(await service.requestSpendApproval(spend) == .blocked(
            reason: "A native pipeline gate change is already being applied."
        ))

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
        let result = await service.resolveGate(.declined)

        #expect(result?.isError == false)
        #expect(service.pendingGateApproval == nil)
    }

    @Test("An external MCP approval does not start an unrelated in-app turn")
    func externalApprovalDoesNotSendInAppMessage() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService

        _ = try service.requestGateApproval(GateApproval(phase: "brief"))
        _ = await service.resolveGate(.declined)
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
        _ = await service.resolveGate(.declined)
        #expect(service.messages.isEmpty)

        _ = try service.requestGateApproval(
            GateApproval(phase: "brief"),
            origin: .embeddedRuntime(
                chatSessionID: unrelatedChat,
                mcpSessionID: UUID()
            )
        )
        #expect(service.pendingGateApproval?.sessionId == unrelatedChat)
    }

    @Test("an unknown embedded chat header is treated as external MCP")
    func unknownEmbeddedChatCannotClaimResumption() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        let result = await h.executor.execute(
            name: "approve_gate",
            args: ["project_dir": dataRoot.path, "phase": "project_init"],
            origin: .embeddedRuntime(
                chatSessionID: UUID(),
                mcpSessionID: UUID()
            )
        )

        #expect(result.turnDisposition == .suspendTurn)
        #expect(h.editor.agentService.pendingGateApproval?.sessionId == nil)
    }

    @Test("approve_gate returns approval_pending without waiting or writing")
    func toolReturnsPending() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }

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
        #expect(h.editor.agentService.pendingGateApproval?.phase == "project_init")

        let state = try await h.runOK("get_project_state", args: ["project_dir": dataRoot.path]) as? [String: Any]
        let phases = try #require(state?["phases"] as? [[String: Any]])
        #expect(phases.first { $0["phase"] as? String == "project_init" }?["state"] as? String == "pending")
    }

    @Test("set_gate_state approval request does not mark the project edited")
    func setStateApprovalRequestDoesNotDirty() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
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
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
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
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        let result = await h.runRaw("set_gate_state", args: [
            "project_dir": dataRoot.path,
            "phase": "brief",
            "state": "needs_revision",
        ])

        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("future phase"))
    }

    @Test("A failed host write leaves the card open with the real reason")
    func failedWriteKeepsCard() async throws {
        let editor = EditorViewModel()
        let service = editor.agentService
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-gate-root-\(UUID().uuidString)", isDirectory: true)

        _ = try service.requestGateApproval(GateApproval(
            phase: "project_init",
            dataRoot: missingRoot
        ))
        let result = await service.resolveGate(.approved)

        #expect(result?.isError == true)
        #expect(service.pendingGateApproval?.phase == "project_init")
        #expect(service.gateApprovalError?.isEmpty == false)
    }

    @Test("An approved gate cannot resume the agent across a host-owned intake card")
    func approvalDefersFollowUpUntilIntakeCompletes() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
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
        let result = await service.resolveGate(.approved)
        #expect(result?.isError == false)
        try service.presentDialog(intake)
        #expect(!service.resumePendingGateFollowUp())
        await Task.yield()
        #expect(service.pendingDialog?.id == intake.id)

        service.abandonDialog()
        #expect(service.resumePendingGateFollowUp())
    }

    @Test("a gate decision suspends the tool batch before later calls execute")
    func gateSuspendsRemainingToolBatch() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
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
        _ = await h.editor.agentService.resolveGate(.declined)

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
            mcpSessionID: UUID()
        )

        _ = try h.editor.agentService.requestGateApproval(
            GateApproval(phase: "brief"),
            origin: origin
        )
        _ = await h.editor.agentService.resolveGate(.declined)
        #expect(h.editor.agentService.resumePendingGateFollowUp())

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
                mcpSessionID: UUID()
            )
        )
        #expect(!replacement.isError)
    }

    // MARK: - Tool outcome (approve writes, decline does not)

    private func scaffold() throws -> (ToolHarness, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-approval-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        return (ToolHarness(), dataRoot, tmp)
    }

    @Test("approve_gate declined leaves the gate unwritten and tells the agent to stay on the phase")
    func declineDoesNotWrite() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
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
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
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
}
