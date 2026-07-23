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
    func requestReturnsPending() {
        let editor = EditorViewModel()
        let service = editor.agentService

        let request = service.requestGateApproval(GateApproval(phase: "brief"))
        #expect(request.isNew)
        #expect(service.pendingGateApproval?.phase == "brief")
    }

    @Test("A retry preserves the original card and request id")
    func retryIsIdempotent() {
        let editor = EditorViewModel()
        let service = editor.agentService

        let first = service.requestGateApproval(GateApproval(phase: "brief"))
        let retry = service.requestGateApproval(GateApproval(phase: "brief"))

        #expect(retry.isNew == false)
        #expect(retry.matchesRequestedApproval)
        #expect(retry.approval.id == first.approval.id)
        #expect(service.pendingGateApproval?.id == first.approval.id)
    }

    @Test("A competing request cannot replace the open card")
    func competingRequestKeepsFirstCard() {
        let editor = EditorViewModel()
        let service = editor.agentService

        let first = service.requestGateApproval(GateApproval(phase: "brief"))
        let competing = service.requestGateApproval(GateApproval(phase: "analysis"))

        #expect(competing.isNew == false)
        #expect(competing.matchesRequestedApproval == false)
        #expect(competing.approval.id == first.approval.id)
        #expect(service.pendingGateApproval?.phase == "brief")
    }

    @Test("Cancelling the model transport does not decide or remove the gate")
    func transportCancellationKeepsCard() {
        let editor = EditorViewModel()
        let service = editor.agentService

        _ = service.requestGateApproval(GateApproval(phase: "brief"))
        service.cancel()

        #expect(service.pendingGateApproval?.phase == "brief")
    }

    @Test("Declining is an explicit decision and clears the card")
    func declineClears() {
        let editor = EditorViewModel()
        let service = editor.agentService

        _ = service.requestGateApproval(GateApproval(phase: "brief"))
        let result = service.resolveGate(.declined)

        #expect(result?.isError == false)
        #expect(service.pendingGateApproval == nil)
    }

    @Test("An external MCP approval does not start an unrelated in-app turn")
    func externalApprovalDoesNotSendInAppMessage() async {
        let editor = EditorViewModel()
        let service = editor.agentService

        _ = service.requestGateApproval(GateApproval(phase: "brief"))
        _ = service.resolveGate(.declined)
        await Task.yield()

        #expect(service.messages.isEmpty)
        #expect(service.streamError?.errorDescription == nil)
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
        #expect(payload?["status"] as? String == "approval_pending")
        #expect(h.editor.agentService.pendingGateApproval?.phase == "project_init")

        let state = try await h.runOK("get_project_state", args: ["project_dir": dataRoot.path]) as? [String: Any]
        let phases = try #require(state?["phases"] as? [[String: Any]])
        #expect(phases.first { $0["phase"] as? String == "project_init" }?["state"] as? String == "pending")
    }

    @Test("A failed host write leaves the card open with the real reason")
    func failedWriteKeepsCard() {
        let editor = EditorViewModel()
        let service = editor.agentService
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-gate-root-\(UUID().uuidString)", isDirectory: true)

        _ = service.requestGateApproval(GateApproval(
            phase: "project_init",
            dataRoot: missingRoot
        ))
        let result = service.resolveGate(.approved)

        #expect(result?.isError == true)
        #expect(service.pendingGateApproval?.phase == "project_init")
        #expect(service.gateApprovalError?.isEmpty == false)
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
