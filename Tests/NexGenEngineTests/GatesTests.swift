import Foundation
import Testing
@testable import NexGenEngine

@Suite("Gates")
struct GatesTests {
    @Test("YAML round-trip preserves equality")
    func yamlRoundTrip() throws {
        var gates = Gates(project: "basic-project")
        gates.set("brief", Gate(approved: true, approvedAt: "2026-01-01T00:00:00Z", approvedBy: "user"))
        let yaml = try YAMLCoding.encode(gates)
        let decoded = try YAMLCoding.decode(Gates.self, from: yaml)
        #expect(decoded == gates)
    }

    @Test("decodes a hand-written minimal document")
    func decodesHandWrittenYAML() throws {
        let yaml = """
        project: basic-project
        schema: gates/v2
        gates: {}
        """
        let gates = try YAMLCoding.decode(Gates.self, from: yaml)
        #expect(gates.project == "basic-project")
        #expect(gates.schema == "gates/v2")
        #expect(gates.gates.isEmpty)
    }

    @Test("schema defaults to gates/v2 when absent")
    func schemaDefaultsWhenAbsent() throws {
        let gates = try YAMLCoding.decode(Gates.self, from: "project: p\n")
        #expect(gates.schema == "gates/v2")
    }

    @Test("core gate phases match the Python pipeline order")
    func corePhasesOrder() {
        #expect(coreGatePhases == [
            "project_init", "brief", "production_design", "treatment", "storyboard",
            "bible", "shotlist", "sanity", "frames", "render",
        ])
    }

    @Test("get() returns a pending default gate for an unset phase")
    func getDefaultsToPending() {
        let gates = Gates(project: "p")
        let gate = gates.get("brief")
        #expect(gate.approved == false)
        #expect(gate.state == .pending)
    }

    // MARK: - _derive_state reconciliation (Gate init)

    @Test("approved=true with pending/needs_revision state derives approved")
    func deriveStateApprovedNoNotes() {
        let gate = Gate(approved: true, state: .pending)
        #expect(gate.state == .approved)
    }

    @Test("approved=true with notes derives approved_with_notes")
    func deriveStateApprovedWithNotes() {
        let gate = Gate(approved: true, notes: "tighten the prop list", state: .needsRevision)
        #expect(gate.state == .approvedWithNotes)
    }

    @Test("approved=false with an approved-family state resets to pending (contradictory hand-edit)")
    func deriveStateContradictoryResetsToPending() {
        let gate = Gate(approved: false, state: .approved)
        #expect(gate.state == .pending)
        let gate2 = Gate(approved: false, state: .approvedWithNotes)
        #expect(gate2.state == .pending)
    }

    // MARK: - GatesOperations (port of test_gates_state.py)

    @Test("set_state needs_revision keeps the phase blocked")
    func setStateNeedsRevisionKeepsBlocked() {
        var gates = Gates(project: "demo")
        GatesOperations.setState(&gates, phase: "storyboard", state: .needsRevision, notes: "pacing too flat")
        let gate = gates.get("storyboard")
        #expect(gate.approved == false)
        #expect(gate.state == .needsRevision)
        #expect(gate.notes == "pacing too flat")
    }

    @Test("set_state approved_with_notes unblocks the phase")
    func setStateApprovedWithNotesUnblocks() {
        var gates = Gates(project: "demo")
        GatesOperations.setState(&gates, phase: "bible", state: .approvedWithNotes, notes: "tighten the prop list")
        #expect(gates.get("bible").approved == true)
        #expect(gates.get("bible").state == .approvedWithNotes)
    }

    @Test("legacy approve() derives state, with/without notes")
    func legacyApproveDerivesState() {
        var gates = Gates(project: "demo")
        GatesOperations.approve(&gates, phase: "brief")
        #expect(gates.get("brief").state == .approved)
        GatesOperations.approve(&gates, phase: "treatment", notes: "ok with caveats")
        #expect(gates.get("treatment").state == .approvedWithNotes)
    }

    @Test("setState('approved', notes: non-empty) becomes approved_with_notes")
    func setStateApprovedWithNonEmptyNotesBecomesWithNotes() {
        var gates = Gates(project: "demo")
        GatesOperations.setState(&gates, phase: "brief", state: .approved, notes: "looks good")
        #expect(gates.get("brief").state == .approvedWithNotes)
        #expect(gates.get("brief").approved == true)
    }

    @Test("require() throws GateBlocked when the gate is not approved")
    func requireThrowsWhenNotApproved() {
        let gates = Gates(project: "demo")
        #expect(throws: GateBlocked.self) {
            _ = try GatesOperations.require(gates, phase: "brief")
        }
    }

    @Test("require() returns the gate when approved")
    func requireReturnsWhenApproved() throws {
        var gates = Gates(project: "demo")
        GatesOperations.approve(&gates, phase: "brief")
        let gate = try GatesOperations.require(gates, phase: "brief")
        #expect(gate.approved == true)
    }

    @Test("rewind_to resets the target phase and everything after it")
    func rewindToResetsTargetAndFollowing() throws {
        var gates = Gates(project: "demo")
        for phase in coreGatePhases { GatesOperations.approve(&gates, phase: phase) }
        let affected = try GatesOperations.rewindTo(&gates, target: "storyboard")
        #expect(affected == Array(coreGatePhases[coreGatePhases.firstIndex(of: "storyboard")!...]))
        #expect(gates.get("storyboard").approved == false)
        #expect(gates.get("bible").approved == false)
        #expect(gates.get("render").approved == false)
        // Untouched: everything before the target stays approved.
        #expect(gates.get("brief").approved == true)
        #expect(gates.get("treatment").approved == true)
    }

    @Test("rewind_to an unknown gate throws")
    func rewindToUnknownGateThrows() {
        var gates = Gates(project: "demo")
        #expect(throws: GatesOperations.RewindError.self) {
            _ = try GatesOperations.rewindTo(&gates, target: "not-a-phase")
        }
    }

    @Test("parity: fixture gates.yaml matches the golden")
    func fixtureParityWithGolden() throws {
        let fixtureHome = try DataRootResolverTests.fixtureHome()
        let url = fixtureHome.appendingPathComponent("pipeline").appendingPathComponent("gates.yaml")
        let gates = try YAMLCoding.decode(Gates.self, from: url)
        #expect(gates.project == "basic-project")
        #expect(gates.schema == "gates/v2")
        #expect(gates.gates.isEmpty)
    }
}
