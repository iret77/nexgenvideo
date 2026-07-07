import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

/// M7: the production-pipeline (engine) tools driven through ToolExecutor against a temp scaffolded
/// project. Each tool is passed an explicit `project_dir` (the harness editor has no open project),
/// exercising the same native NexGenEngine paths the `nexgen` MCP will call. Return shapes are
/// asserted against the Python `mcp_server` contract (and, for state, the committed golden's keys).
@MainActor
@Suite("Workflow (engine) tools")
struct WorkflowToolsTests {

    /// A throwaway scaffolded project; returns (harness, dataRoot, cleanup-root).
    private func scaffold() throws -> (ToolHarness, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-tools-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        return (ToolHarness(), dataRoot, tmp)
    }

    /// Mark the given data root's project package (parent of `_studio`) active with `pack` by writing
    /// its `ngv.json` — the same file `ProjectPluginSettings` reads. Proves the pack resolves from the
    /// project HOME, not the data root.
    private func activatePack(_ pack: String, dataRoot: URL) throws {
        let home = FrameInventory.projectHome(of: dataRoot)
        let data = try JSONSerialization.data(withJSONObject: ["activePlugin": pack], options: [])
        try data.write(to: home.appendingPathComponent("ngv.json"))
    }

    private func minimalShotlist(project: String = "demo") throws -> Shotlist {
        let shot = try Shot(
            id: "s001", section: "verse", timeStart: 0.0, timeEnd: 4.0, durationS: 4.0,
            type: .performance, description: "d", visualPrompt: "p", mood: "m"
        )
        let song = try Song(title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 4.0)
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: .section, project: project, song: song,
            generated: "2026-01-01", generator: "test", shots: [shot]
        )
    }

    // MARK: - init_project → get_project_state

    @Test("init_project scaffolds a project and get_project_state matches the state.json golden keys")
    func initThenState() async throws {
        let (h, _, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        // init_project into a fresh home, then read its state.
        let freshHome = cleanup.appendingPathComponent("fresh", isDirectory: true)
        let initJSON = try await h.runOK("init_project", args: [
            "home_dir": freshHome.path, "name": "basic-project",
        ]) as? [String: Any]
        #expect(initJSON?["created"] as? Bool == true)
        #expect(initJSON?["project"] as? String == "basic-project")
        let dataRoot = try #require(initJSON?["data_root"] as? String)

        let state = try await h.runOK("get_project_state", args: ["project_dir": dataRoot]) as? [String: Any]
        // The committed golden's top-level keys (Tests/NexGenEngineTests/Goldens/basic-project/state.json).
        for key in ["project", "mode", "budget_eur", "budget_spent_eur", "budget_remaining_eur", "phases", "next_phase"] {
            #expect(state?[key] != nil, "state missing key \(key)")
        }
        #expect(state?["project"] as? String == "basic-project")
        #expect(state?["mode"] as? String == "beat")
        #expect(state?["next_phase"] as? String == "project_init")
        let phases = try #require(state?["phases"] as? [[String: Any]])
        #expect(phases.first?["phase"] as? String == "project_init")
        #expect(phases.first?["state"] as? String == "pending")
    }

    @Test("init_project on an existing project errors, not crashes")
    func initTwiceErrors() async throws {
        let (h, _, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let home = cleanup.appendingPathComponent("dupe", isDirectory: true)
        _ = try await h.runOK("init_project", args: ["home_dir": home.path, "name": "x"])
        let result = await h.runRaw("init_project", args: ["home_dir": home.path, "name": "x"])
        #expect(result.isError)
    }

    // MARK: - list_phases / get_ui_contract

    @Test("list_phases returns the ordered core pipeline")
    func listPhases() async throws {
        let h = ToolHarness()
        let phases = try await h.runOK("list_phases") as? [Any]
        #expect(phases?.first as? String == "project_init")
        #expect(phases?.last as? String == "render")
        #expect(phases?.count == coreGatePhases.count)
    }

    @Test("list_phases folds in the active pack's phases at their declared placement")
    func listPhasesWithPack() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)

        let phases = try await h.runOK("list_phases", args: ["project_dir": dataRoot.path]) as? [String]
        #expect(phases?.first == "project_init")
        #expect(phases?.contains("analysis") == true)  // the pack gate is present…
        // musicvideo declares `analysis` right after project_init (it gates before brief).
        #expect(phases?[1] == "analysis")
        #expect(phases?.dropFirst(2).first == "brief")  // analysis precedes brief
        #expect(phases?.count == coreGatePhases.count + 1)
    }

    @Test("get_project_state places the active pack's analysis gate before brief")
    func stateWithPack() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)

        let state = try await h.runOK("get_project_state", args: ["project_dir": dataRoot.path]) as? [String: Any]
        let phases = try #require(state?["phases"] as? [[String: Any]])
        let names = phases.compactMap { $0["phase"] as? String }
        #expect(names.contains("analysis"))
        // analysis is inserted right after project_init, ahead of brief — not appended at the end.
        let analysisIdx = try #require(names.firstIndex(of: "analysis"))
        let briefIdx = try #require(names.firstIndex(of: "brief"))
        #expect(names[analysisIdx - 1] == "project_init")
        #expect(analysisIdx < briefIdx)
    }

    @Test("get_ui_contract exposes surfaces and a per-phase entry")
    func uiContract() async throws {
        let h = ToolHarness()
        let contract = try await h.runOK("get_ui_contract") as? [String: Any]
        #expect(contract?["surfaces"] as? [String] == ["choice", "prose", "review"])
        let phases = try #require(contract?["phases"] as? [String: Any])
        let brief = try #require(phases["brief"] as? [String: Any])
        #expect(brief["surface"] as? String == "prose")
        #expect(brief["task_class"] as? String == "interpretation")
    }

    // MARK: - approve_gate / set_gate_state / rewind round-trip

    @Test("approve_gate, set_gate_state, and rewind round-trip through gates.yaml")
    func gateRoundTrip() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let dir = dataRoot.path

        let approved = try await h.runOK("approve_gate", args: ["project_dir": dir, "phase": "brief", "notes": "ok"]) as? [String: Any]
        #expect(approved?["approved"] as? Bool == true)
        #expect(approved?["phase"] as? String == "brief")
        #expect(approved?["notes"] as? String == "ok")

        // set_gate_state to needs_revision keeps the phase blocked (approved == false).
        let revised = try await h.runOK("set_gate_state", args: ["project_dir": dir, "phase": "brief", "state": "needs_revision", "notes": "redo"]) as? [String: Any]
        #expect(revised?["state"] as? String == "needs_revision")
        #expect(revised?["approved"] as? Bool == false)

        // Approve treatment, then rewind to brief resets brief + everything after it.
        _ = try await h.runOK("approve_gate", args: ["project_dir": dir, "phase": "treatment"])
        let rewound = try await h.runOK("rewind", args: ["project_dir": dir, "target_phase": "brief"]) as? [String: Any]
        #expect(rewound?["target"] as? String == "brief")
        let reset = try #require(rewound?["reset_phases"] as? [String])
        #expect(reset.first == "brief")
        #expect(reset.contains("treatment"))
        #expect(reset.last == "render")
    }

    @Test("set_gate_state rejects an unknown state")
    func setGateStateBadValue() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let result = await h.runRaw("set_gate_state", args: ["project_dir": dataRoot.path, "phase": "brief", "state": "vibes"])
        #expect(result.isError)
    }

    // MARK: - Ledger set / lock / remove

    @Test("ledger set, lock, and remove round-trip; a locked attribute refuses removal")
    func ledgerRoundTrip() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let dir = dataRoot.path

        let set = try await h.runOK("set_ledger_attribute", args: [
            "project_dir": dir, "kind": "look", "key": "palette", "tag": "warm amber",
        ]) as? [String: Any]
        #expect(set?["tag"] as? String == "warm amber")
        #expect(set?["directive"] as? String == "warm amber")  // directive defaults to tag
        #expect(set?["locked"] as? Bool == false)

        let locked = try await h.runOK("lock_ledger_attribute", args: [
            "project_dir": dir, "kind": "look", "key": "palette",
        ]) as? [String: Any]
        #expect(locked?["locked"] as? Bool == true)

        // Locked → removal refused (the lock guard).
        let refused = await h.runRaw("remove_ledger_attribute", args: ["project_dir": dir, "kind": "look", "key": "palette"])
        #expect(refused.isError)

        // Unlock, then remove.
        _ = try await h.runOK("lock_ledger_attribute", args: ["project_dir": dir, "kind": "look", "key": "palette", "locked": false])
        let removed = try await h.runOK("remove_ledger_attribute", args: ["project_dir": dir, "kind": "look", "key": "palette"]) as? [String: Any]
        #expect(removed?["removed"] as? Bool == true)

        // get_ledger reflects the empty ledger.
        let ledger = try await h.runOK("get_ledger", args: ["project_dir": dir]) as? [String: Any]
        #expect(ledger?["schema"] as? String == "ledger/v1")
        let objects = try #require(ledger?["objects"] as? [String: Any])
        #expect(objects["look"] == nil)
    }

    @Test("set_ledger_attribute for an entity kind without object_id errors")
    func ledgerEntityNeedsObjectId() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let result = await h.runRaw("set_ledger_attribute", args: [
            "project_dir": dataRoot.path, "kind": "character", "key": "wardrobe", "tag": "red jacket",
        ])
        #expect(result.isError)
    }

    // MARK: - resolve_model

    @Test("resolve_model returns the task-class floor and one-step escalation")
    func resolveModel() async throws {
        let h = ToolHarness()
        let distill = try await h.runOK("resolve_model", args: ["task_class": "distill"]) as? [String: Any]
        #expect(distill?["tier"] as? String == "fast")
        #expect(distill?["effort"] as? String == "low")
        #expect(distill?["escalated"] as? Bool == false)
        #expect(distill?["model"] as? String == ModelRouter.defaultManifest["fast"])

        let escalated = try await h.runOK("resolve_model", args: ["task_class": "distill", "escalate": true]) as? [String: Any]
        #expect(escalated?["tier"] as? String == "medium")
        #expect(escalated?["escalated"] as? Bool == true)
    }

    @Test("resolve_model rejects an unknown task class")
    func resolveModelUnknown() async throws {
        let h = ToolHarness()
        let result = await h.runRaw("resolve_model", args: ["task_class": "vibes"])
        #expect(result.isError)
    }

    // MARK: - run_sanity on a minimal shotlist

    @Test("run_sanity on a project with no shotlist returns the no-shotlist marker")
    func sanityNoShotlist() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let report = try await h.runOK("run_sanity", args: ["project_dir": dataRoot.path]) as? [String: Any]
        #expect(report?["error"] as? String == "no shotlist")
    }

    @Test("run_sanity on a minimal shotlist returns findings with the four contract fields")
    func sanityWithShotlist() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)

        let report = try await h.runOK("run_sanity", args: ["project_dir": dataRoot.path]) as? [String: Any]
        #expect(report?["project"] as? String == "demo")
        let findings = try #require(report?["findings"] as? [[String: Any]])
        // The "p" prompt is too short → PROMPT_TOO_SHORT proves core checks ran.
        #expect(findings.contains { ($0["code"] as? String) == "PROMPT_TOO_SHORT" })
        for f in findings {
            #expect(f["level"] != nil)
            #expect((f["code"] as? String)?.isEmpty == false)
            #expect((f["message"] as? String)?.isEmpty == false)
            #expect(f.keys.contains("shot_id"))  // present, possibly NSNull
        }
    }

    // MARK: - estimate_cost / render manifest / show_artifact / run_phase / get_bible

    @Test("estimate_cost returns the spent/remaining budget picture")
    func estimateCost() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let cost = try await h.runOK("estimate_cost", args: ["project_dir": dataRoot.path]) as? [String: Any]
        #expect(cost?["project"] as? String == "demo")
        #expect(cost?["budget_eur"] as? Double == 50.0)
        #expect(cost?["spent_eur"] as? Double == 0.0)
        #expect(cost?["remaining_eur"] as? Double == 50.0)
        #expect(cost?["over_budget"] as? Bool == false)
        #expect(cost?.keys.contains("next_phase") == true)
    }

    @Test("record_render then get_render_manifest / next_render_shot reflect the entry")
    func renderManifestRoundTrip() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)
        let dir = dataRoot.path

        let recorded = try await h.runOK("record_render", args: [
            "project_dir": dir, "phase": "preview", "shot_id": "s001", "output": "s001.png", "cost_eur": 1.5,
        ]) as? [String: Any]
        #expect(recorded?["shot_id"] as? String == "s001")
        #expect(recorded?["status"] as? String == "rendered")
        #expect(recorded?["spent_eur"] as? Double == 1.5)

        let manifest = try await h.runOK("get_render_manifest", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(manifest?["phase"] as? String == "preview")
        let entries = try #require(manifest?["entries"] as? [String: Any])
        #expect(entries["s001"] != nil)
        let summary = try #require(manifest?["summary"] as? [String: Any])
        #expect(summary["total"] as? Int == 1)
        #expect(summary["rendered"] as? Int == 1)
        #expect(summary["spent_eur"] as? Double == 1.5)

        // s001 rendered → next_render_shot reports done.
        let next = try await h.runOK("next_render_shot", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(next?["done"] as? Bool == true)
    }

    @Test("next_render_shot surfaces the first unrendered shot's prompt")
    func nextRenderShotPending() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try minimalShotlist(), to: dataRoot)
        let next = try await h.runOK("next_render_shot", args: ["project_dir": dataRoot.path, "phase": "preview"]) as? [String: Any]
        #expect(next?["done"] as? Bool == false)
        #expect(next?["shot_id"] as? String == "s001")
        #expect(next?["visual_prompt"] as? String == "p")
        #expect(next?["source_mode"] as? String == "generated")
    }

    /// A 3-shot shotlist: s001 imported, s002 generated, s003 ai_enhanced.
    private func hybridShotlist() throws -> Shotlist {
        func shot(_ id: String, _ start: Double, _ mode: SourceMode) throws -> Shot {
            try Shot(
                id: id, section: "verse", timeStart: start, timeEnd: start + 4.0, durationS: 4.0,
                type: .performance, sourceMode: mode, description: "d", visualPrompt: "p", mood: "m"
            )
        }
        let song = try Song(title: "t", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 12.0)
        return try Shotlist(
            schema_: shotlistSchemaVersion, mode: .section, project: "demo", song: song,
            generated: "2026-01-01", generator: "test",
            shots: [
                try shot("s001", 0.0, .imported),
                try shot("s002", 4.0, .generated),
                try shot("s003", 8.0, .aiEnhanced),
            ]
        )
    }

    @Test("next_render_shot skips imported shots and returns ai_enhanced with its source_mode")
    func nextRenderShotSkipsLiveAction() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        _ = try saveShotlist(try hybridShotlist(), to: dataRoot)
        let dir = dataRoot.path

        // s001 is imported → skipped; the first render shot is the generated s002.
        let first = try await h.runOK("next_render_shot", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(first?["shot_id"] as? String == "s002")
        #expect(first?["source_mode"] as? String == "generated")

        // Record s002 → the enhanced s003 is next (enhanced shots ARE queued).
        _ = try await h.runOK("record_render", args: [
            "project_dir": dir, "phase": "preview", "shot_id": "s002", "output": "s002.mp4", "cost_eur": 1.0,
        ])
        let second = try await h.runOK("next_render_shot", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(second?["shot_id"] as? String == "s003")
        #expect(second?["source_mode"] as? String == "ai_enhanced")

        // Record s003 → done. s001 (imported) never appears, so the queue is empty.
        _ = try await h.runOK("record_render", args: [
            "project_dir": dir, "phase": "preview", "shot_id": "s003", "output": "s003.mp4", "cost_eur": 1.0,
        ])
        let done = try await h.runOK("next_render_shot", args: ["project_dir": dir, "phase": "preview"]) as? [String: Any]
        #expect(done?["done"] as? Bool == true)
    }

    @Test("get_bible returns null on a fresh project")
    func bibleNull() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let result = await h.runRaw("get_bible", args: ["project_dir": dataRoot.path])
        #expect(result.isError == false)
        #expect(ToolHarness.textOf(result).trimmingCharacters(in: .whitespacesAndNewlines) == "null")
    }

    @Test("run_phase reports the agent-driven no-runner shape for a planning phase")
    func runPhaseNoRunner() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let result = try await h.runOK("run_phase", args: ["project_dir": dataRoot.path, "phase": "brief"]) as? [String: Any]
        #expect(result?["phase"] as? String == "brief")
        #expect(result?["runner"] is NSNull)
        #expect((result?["note"] as? String)?.contains("agent-driven") == true)
    }

    @Test("run_phase reaches the active pack's analysis runner (resolved from the project home)")
    func runPhaseReachesPackRunner() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        try activatePack("musicvideo", dataRoot: dataRoot)

        // With the pack active but no song in audio/, the runner IS reached and returns its actionable
        // blocker — NOT the "no code runner" shape (which is what the pre-fix nil-pack resolution gave).
        let result = try #require(try await h.runOK("run_phase", args: ["project_dir": dataRoot.path, "phase": "analysis"]) as? [String: Any])
        #expect(result["phase"] as? String == "analysis")
        #expect(result["note"] == nil)  // the no-runner branch never fired
        #expect(result["error"] as? String == "phase_failed")
        #expect((result["detail"] as? String)?.contains("audio/") == true)
    }

    @Test("show_artifact yields a markdown envelope; nothing-yet for a fresh brief")
    func showArtifact() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        let shown = try await h.runOK("show_artifact", args: ["project_dir": dataRoot.path, "gate": "brief"]) as? [String: Any]
        #expect(shown?["gate"] as? String == "brief")
        #expect(shown?["markdown"] is String)

        // An unknown gate never raises — it returns the "no display artifact" note.
        let unknown = try await h.runOK("show_artifact", args: ["project_dir": dataRoot.path, "gate": "nope"]) as? [String: Any]
        #expect((unknown?["markdown"] as? String)?.contains("no display artifact") == true)
    }
}
