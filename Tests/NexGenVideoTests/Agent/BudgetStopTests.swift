import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

/// #198: the OPTIONAL hard spending stop, enforced at `next_render_shot` — the boundary that hands
/// a shot out for rendering.
///
/// The whole point is that it is optional. Without a stated limit nothing is ever blocked; the
/// costs are only reported. `Brief.budgetEur` must NOT act as the limit: it defaults to 50 on every
/// project, so gating on it would impose a stop nobody chose.
@MainActor
@Suite("Budget stop (#198)")
struct BudgetStopTests {

    private func scaffold() throws -> (ToolHarness, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        return (ToolHarness(), dataRoot, tmp)
    }

    /// One expensive shot, so an estimate exists to compare against a limit.
    private func shotlist() throws -> Shotlist {
        let shot = try Shot(
            id: "s001", section: "verse", timeStart: 0.0, timeEnd: 10.0, durationS: 10.0,
            type: .performance, description: "d", visualPrompt: "p", mood: "m")
        let song = try Song(title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 10.0)
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: .section, project: "demo", song: song, shots: [shot])
    }

    private func writeBrief(stop: Double?, to dataRoot: URL) throws {
        let brief = try Brief(
            project: "demo", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "beat", budgetStopEur: stop,
            conceptType: .abstract, visualMedium: .liveActionRealistic, figures: .none,
            lyricsIntegration: .ignored)
        try YAMLArtifactStore(dataRoot: dataRoot).save(brief, at: PipelineLayout.briefFile)
    }

    /// The default. No limit stated → the shot is handed out, whatever it costs.
    @Test("no stop set: nothing is blocked")
    func noStopMeansNoBlock() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try shotlist(), to: dataRoot)
        try writeBrief(stop: nil, to: dataRoot)

        let next = try await h.runOK("next_render_shot", args: [
            "project_dir": dataRoot.path, "phase": "final",
        ]) as? [String: Any]
        #expect(next?["shot_id"] as? String == "s001")
        #expect(next?["done"] as? Bool == false)
    }

    /// `budgetEur` is a planning figure, not a limit — it defaults to 50 everywhere. A 10s shot
    /// estimates well over that, and must still be handed out.
    @Test("budgetEur alone never blocks — only an explicit stop does")
    func planningBudgetIsNotALimit() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try shotlist(), to: dataRoot)
        try writeBrief(stop: nil, to: dataRoot)   // budgetEur defaults to 50

        let next = try await h.runOK("next_render_shot", args: [
            "project_dir": dataRoot.path, "phase": "final",
        ]) as? [String: Any]
        #expect(next?["shot_id"] as? String == "s001", "the default 50 EUR budget must not gate")
    }

    /// A stated limit the estimate would blow through: refused, before the money is gone.
    @Test("a stated stop refuses the render")
    func statedStopBlocks() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try shotlist(), to: dataRoot)
        try writeBrief(stop: 0.01, to: dataRoot)   // any real render exceeds a cent

        let raw = await h.runRaw("next_render_shot", args: [
            "project_dir": dataRoot.path, "phase": "final",
        ])
        #expect(raw.isError, "the render must be refused, not handed out")
        #expect(ToolHarness.textOf(raw).contains("Budget stop reached"))
        // The refusal must be actionable and must not invite a workaround.
        #expect(ToolHarness.textOf(raw).contains("Do NOT work around this"))
    }

    /// A stop the estimate stays under: handed out normally.
    @Test("a generous stop does not block")
    func generousStopAllows() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try shotlist(), to: dataRoot)
        try writeBrief(stop: 10_000, to: dataRoot)

        let next = try await h.runOK("next_render_shot", args: [
            "project_dir": dataRoot.path, "phase": "final",
        ]) as? [String: Any]
        #expect(next?["shot_id"] as? String == "s001")
    }

    /// Prior spend counts: the limit is about the PROJECT, not one render.
    @Test("already-spent EUR counts toward the stop")
    func priorSpendCounts() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try shotlist(), to: dataRoot)
        try writeBrief(stop: 12, to: dataRoot)

        // Spend 11.50 in an earlier phase; a 10s shot's estimate then crosses 12.
        _ = try await h.runOK("record_render", args: [
            "project_dir": dataRoot.path, "phase": "preview", "shot_id": "s001",
            "output": "s001.mp4", "cost_eur": 11.5,
        ])
        let raw = await h.runRaw("next_render_shot", args: [
            "project_dir": dataRoot.path, "phase": "final",
        ])
        #expect(raw.isError, "prior spend must count toward the project limit")
        #expect(ToolHarness.textOf(raw).contains("already spent"))
    }

    /// A stop of zero or less is never what someone means — they mean "no stop", expressed by
    /// leaving it out. Caught at validation rather than silently blocking everything.
    @Test("a non-positive stop is rejected at validation")
    func nonPositiveStopIsInvalid() throws {
        #expect(throws: Brief.ValidationError.budgetStopNotPositive(0)) {
            let brief = try Brief(
                project: "demo", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
                aspectRatio: .landscape16x9, projectMode: "beat", budgetStopEur: 0,
                conceptType: .abstract, visualMedium: .liveActionRealistic, figures: .none,
                lyricsIntegration: .ignored)
            try brief.validate()
        }
    }

    /// Absent in the YAML → absent in the model. An old project can never inherit a surprise stop.
    @Test("a brief without the field decodes to no stop")
    func absentFieldMeansNoStop() throws {
        let (_, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try writeBrief(stop: nil, to: dataRoot)
        let loaded = try YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
        #expect(loaded.budgetStopEur == nil)
        #expect(loaded.budgetEur == 50.0, "the planning budget is untouched")
    }
}
