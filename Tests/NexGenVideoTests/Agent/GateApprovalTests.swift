import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

/// A phase gate is the USER's decision, not the agent's (HAX G11). The agent's approve_gate /
/// set_gate_state tools now SURFACE a confirmation in the composer dock and write the gate only after
/// the user approves. The async continuation + the SwiftUI card aren't unit-testable, so these cover
/// the pure logic (the model + the "does this state need confirmation" decision), the request/resolve
/// seam in isolation (mirroring the spend-approval tests), and the tool's approve-vs-decline outcome.
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

    // MARK: - Request / resolve seam (isolated, like the spend-approval tests)

    @Test("requestGateApproval suspends until the user resolves it")
    func requestSuspendsUntilResolved() async {
        let editor = EditorViewModel()
        let service = editor.agentService

        async let decision = service.requestGateApproval(GateApproval(phase: "brief"))
        for _ in 0..<20 where service.pendingGateApproval == nil { await Task.yield() }
        #expect(service.pendingGateApproval?.phase == "brief")

        service.resolveGate(.approved)
        #expect(await decision == .approved)
        #expect(service.pendingGateApproval == nil)
    }

    @Test("Declining resolves to .declined and clears the card")
    func declineResolvesAndClears() async {
        let editor = EditorViewModel()
        let service = editor.agentService

        async let decision = service.requestGateApproval(GateApproval(phase: "brief"))
        for _ in 0..<20 where service.pendingGateApproval == nil { await Task.yield() }
        service.resolveGate(.declined)
        #expect(await decision == .declined)
        #expect(service.pendingGateApproval == nil)
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
