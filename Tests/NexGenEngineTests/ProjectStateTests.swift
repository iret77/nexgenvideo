import Foundation
import Testing
@testable import NexGenEngine

/// Port of the snapshot cases in `engine/tests/test_state_mcp.py` (next open phase, budget math)
/// plus golden parity: the `state` dictionary the native seam produces matches the committed
/// state.json Python oracle for the fixture project.
@Suite("ProjectState")
struct ProjectStateTests {

    private func scaffold(mode: Mode = .beat, budget: Double = 50.0) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-\(UUID().uuidString)")
        return try ProjectScaffold.initProject(
            home: tmp.appendingPathComponent("p"), name: "demo", mode: mode, budgetEur: budget
        )
    }

    private func cleanup(_ dataRoot: URL) {
        try? FileManager.default.removeItem(
            at: dataRoot.deletingLastPathComponent().deletingLastPathComponent()
        )
    }

    // MARK: - test_snapshot_tracks_next_open_phase

    @Test("snapshot tracks the next open phase")
    func snapshotTracksNextOpenPhase() throws {
        let dataRoot = try scaffold(mode: .beat)
        defer { cleanup(dataRoot) }

        var snap = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot)
        #expect(snap.project == "demo")
        #expect(snap.mode == "beat")
        #expect(snap.nextPhase == "project_init")  // nothing approved → first phase

        let store = YAMLArtifactStore(dataRoot: dataRoot)
        var gates = try store.load(Gates.self, at: StudioLayout.gatesFile)
        GatesOperations.approve(&gates, phase: "project_init")
        try store.save(gates, to: StudioLayout.gatesFile)

        snap = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot)
        #expect(snap.nextPhase == "brief")
    }

    // MARK: - test_snapshot_includes_budget

    @Test("snapshot includes budget math for a fresh project")
    func snapshotIncludesBudget() throws {
        let dataRoot = try scaffold(mode: .beat, budget: 80.0)
        defer { cleanup(dataRoot) }

        let snap = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot)
        #expect(snap.budgetEur == 80.0)
        #expect(snap.budgetSpentEur == 0.0)       // fresh project, nothing rendered
        #expect(snap.budgetRemainingEur == 80.0)
    }

    @Test("spent aggregates render-manifest costs and reduces remaining")
    func spentAggregatesManifests() throws {
        let dataRoot = try scaffold(mode: .beat, budget: 50.0)
        defer { cleanup(dataRoot) }

        var manifest = RenderManifest(project: "demo", phase: "preview")
        record(&manifest, shotId: "s1", output: "out1.mp4", costEur: 12.5, phase: "preview")
        record(&manifest, shotId: "s2", output: "out2.mp4", costEur: 7.25, phase: "preview")
        try saveRenderManifest(manifest, dataRoot: dataRoot)

        let snap = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot)
        #expect(snap.budgetSpentEur == 19.75)
        #expect(snap.budgetRemainingEur == 30.25)
    }

    @Test("mode is carried through as its raw value (section)")
    func modeCarriedThrough() throws {
        let dataRoot = try scaffold(mode: .section)
        defer { cleanup(dataRoot) }
        let snap = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot)
        #expect(snap.mode == "section")
        #expect(snap.phases.contains { $0.phase == "bible" })
    }

    // MARK: - golden parity: native `state` JSON == committed state.json oracle

    /// Reproduces `NativeCockpitReader.stateDictionary` (which lives in the app target) so the
    /// NexGenEngine-only test can prove the seam's `state` bytes match the Python oracle.
    private func stateDictionary(_ s: ProjectStateBuilder.ProjectState) -> [String: Any] {
        let phases: [[String: Any]] = s.phases.map { p in
            ["phase": p.phase, "approved": p.approved, "state": p.state.rawValue,
             "notes": p.notes.map { $0 as Any } ?? NSNull()]
        }
        return [
            "project": s.project, "mode": s.mode,
            "budget_eur": s.budgetEur, "budget_spent_eur": s.budgetSpentEur,
            "budget_remaining_eur": s.budgetRemainingEur,
            "phases": phases, "next_phase": s.nextPhase.map { $0 as Any } ?? NSNull(),
        ]
    }

    @Test("native state JSON matches the committed state.json golden for the fixture")
    func stateMatchesGolden() throws {
        let home = try #require(
            Bundle.module.url(forResource: "basic-project", withExtension: nil, subdirectory: "Fixtures")
        )
        let dataRoot = try #require(DataRootResolver.dataRoot(of: home))
        let snap = try ProjectStateBuilder.buildSnapshot(dataRoot: dataRoot)

        let produced = try JSONSerialization.data(
            withJSONObject: stateDictionary(snap), options: [.sortedKeys]
        )
        let goldenURL = try #require(
            Bundle.module.url(forResource: "state", withExtension: "json", subdirectory: "Goldens/basic-project")
        )
        let golden = try Data(contentsOf: goldenURL)

        let producedObj = try JSONSerialization.jsonObject(with: produced) as? [String: Any]
        let goldenObj = try JSONSerialization.jsonObject(with: golden) as? [String: Any]
        #expect(NSDictionary(dictionary: try #require(producedObj))
            .isEqual(to: try #require(goldenObj)))
    }
}
