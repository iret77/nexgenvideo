import Foundation
import Testing

@testable import NexGenEngine

/// Port of `engine/tests/test_costs.py` plus the estimate branches and the
/// Python-oracle golden. Numeric equality is exact — the Swift `estimate` must
/// reproduce the same rounded values as the Python `render.costs.estimate`.
@Suite("Costs")
struct CostsTests {
    // MARK: - Ports of engine/tests/test_costs.py

    /// Port of `test_dataclasses_construct_directly`.
    @Test("dataclasses construct directly")
    func dataclassesConstructDirectly() throws {
        let pricing = ModelPricing(eurPerSecond: 0.10, maxDurationS: 10.0, defaultRatio: "16:9")
        #expect(pricing.eurPerSecond(for: nil) == 0.10)
        #expect(pricing.eurPerSecond(for: "1080p") == 0.10)  // no per-resolution table

        let pro = ModelPricing(
            eurPerSecond: 0.68, maxDurationS: 10.0, defaultRatio: "16:9", minDurationS: 5.0,
            eurPerSecondByResolution: ["720p": 0.30, "1080p": 0.68]
        )
        #expect(pro.eurPerSecond(for: "720p") == 0.30)
        #expect(pro.eurPerSecond(for: "1080p") == 0.68)
        #expect(pro.eurPerSecond(for: "4k") == 0.68)  // unknown → fallback

        let cfg = CostsConfig(
            pricing: ["seedance2": pricing],
            modelMap: ["SEEDANCE_2_0": "seedance2"],
            defaults: ["preview": "seedance2", "final": "seedance2"],
            overlapPreS: 1.5, overlapPostS: 1.5, pollingIntervalS: 5, pollingTimeoutS: 600
        )
        #expect(try cfg.price("seedance2") == pricing)
        // `isinstance(cfg.cost_guard, CostGuard)` → the default is populated.
        #expect(cfg.costGuard == CostGuard())
    }

    /// Port of `test_load_costs_from_yaml`.
    @Test("load costs from YAML")
    func loadCostsFromYAML() throws {
        let yaml = """
            pricing:
              seedance2:
                eur_per_second: 0.10
                max_duration_s: 10.0
                default_ratio: "16:9"
              "fal:bytedance/seedance-2.0/pro":
                eur_per_second: 0.68
                max_duration_s: 10.0
                default_ratio: "16:9"
                min_duration_s: 5.0
                eur_per_second_by_resolution:
                  720p: 0.30
                  1080p: 0.68
            model_map:
              SEEDANCE_2_0: seedance2
            defaults:
              preview: seedance2
              final: "fal:bytedance/seedance-2.0/pro"
            overlap:
              pre_s: 1.5
              post_s: 1.5
            polling:
              interval_s: 5
              timeout_s: 600
            cost_guard:
              confirm_threshold_eur: 12.0
              project_wide_budget: true
            """
        let cfg = try loadCosts(fromYAML: yaml)

        #expect(Set(cfg.pricing.keys) == ["seedance2", "fal:bytedance/seedance-2.0/pro"])
        #expect(cfg.pricing["seedance2"]?.eurPerSecond == 0.10)
        let pro = try #require(cfg.pricing["fal:bytedance/seedance-2.0/pro"])
        #expect(pro.minDurationS == 5.0)
        #expect(pro.eurPerSecondByResolution == ["720p": 0.30, "1080p": 0.68])
        #expect(cfg.modelMap == ["SEEDANCE_2_0": "seedance2"])
        #expect(cfg.defaults["final"] == "fal:bytedance/seedance-2.0/pro")
        #expect(cfg.overlapPreS == 1.5)
        #expect(cfg.pollingTimeoutS == 600)
        #expect(cfg.costGuard.confirmThresholdEur == 12.0)
        #expect(cfg.costGuard.projectWideBudget == true)
    }

    /// Port of `test_already_spent_in_project`.
    @Test("already spent in project sums manifests and honors exclude_phase")
    func alreadySpentInProjectPort() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let renders = tmp.appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)

        // The Python fixtures carry only `eur_spent` — the M1 decoder maps that
        // into `costEur`. `status` absent → the tolerant `_from_disk` path.
        try #"{"shots": [{"shot_id": "s001", "eur_spent": 1.5}, {"shot_id": "s002", "eur_spent": 2.0}]}"#
            .write(
                to: renders.appendingPathComponent("manifest-preview.json"), atomically: true,
                encoding: .utf8
            )
        try #"{"shots": [{"shot_id": "s001", "eur_spent": 10.0}]}"#.write(
            to: renders.appendingPathComponent("manifest-final.json"), atomically: true,
            encoding: .utf8
        )

        #expect(alreadySpentInProject(dataRoot: tmp) == 13.5)
        // exclude the final phase → only preview counts
        #expect(alreadySpentInProject(dataRoot: tmp, excludePhase: .final) == 3.5)
        // empty project dir → 0.0
        #expect(alreadySpentInProject(dataRoot: tmp.appendingPathComponent("nope")) == 0.0)
    }

    // MARK: - Golden parity (frozen Python-oracle fixtures; see Goldens/README.md)

    /// Reproduces the exact `ShotEstimate`/`ProjectEstimate` numbers the Python
    /// `estimate()` produced from the same fixture shotlist, priced from the
    /// same values as `CostsConfig.bundledDefault`.
    @Test("estimate reproduces the Python-oracle golden from the fixture shotlist")
    func estimateMatchesGolden() throws {
        let dataRoot = try Self.fixtureDataRoot()
        let shotlist = try #require(try loadShotlist(dataRoot: dataRoot), "fixture shotlist missing")

        let est = estimate(
            shotlist: shotlist, costs: .bundledDefault, phase: .final, finalResolution: "1080p"
        )

        let golden = try Self.costGolden()
        #expect(est.phase.rawValue == golden["phase"] as? String)
        #expect(est.mode.rawValue == golden["mode"] as? String)
        #expect(est.totalEur == golden["total_eur"] as? Double)
        #expect(est.budgetEur == golden["budget_eur"] as? Double)
        #expect(est.overBudget == golden["over_budget"] as? Bool)

        let goldenShots = try #require(golden["shot_estimates"] as? [[String: Any]])
        #expect(est.shotEstimates.count == goldenShots.count)
        for (se, g) in zip(est.shotEstimates, goldenShots) {
            #expect(se.shotId == g["shot_id"] as? String)
            #expect(se.runwayModel == g["runway_model"] as? String)
            #expect(se.durationS == g["duration_s"] as? Double)
            #expect(se.eur == g["eur"] as? Double)
            #expect(se.truncated == g["truncated"] as? Bool)
            #expect(se.notes == g["notes"] as? String)
        }

        // Also assert the concrete numbers, so a golden regeneration that
        // silently changed the fixture would be caught.
        #expect(est.totalEur == 15.8)
        #expect(est.shotEstimates.map(\.eur) == [6.82, 3.41, 4.774, 0.8])
        #expect(est.shotEstimates.map(\.durationS) == [10.0, 5.0, 7.0, 8.0])
        #expect(est.shotEstimates.map(\.runwayModel) == [
            "fal:bytedance/seedance-2.0/pro", "fal:bytedance/seedance-2.0/pro",
            "fal:bytedance/seedance-2.0/pro", "seedance2",
        ])
        #expect(est.shotEstimates.map(\.notes) == [
            "truncated to 10.0s; @1080p",
            "padded to provider-min 5.0s (actual shot 3.0s); @1080p",
            "@1080p",
            "",
        ])
    }

    // MARK: - Source modes (hybrid production, issue #129)

    /// imported shots cost 0 with note "imported"; ai_enhanced shots are billed identically to
    /// generated (a provider video-to-video pass). A section shotlist so pricing hits the stitch branch.
    @Test("estimate — live_action bills 0, ai_enhanced bills like generated")
    func estimateSourceModes() throws {
        let song = try Song(
            title: "s", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 60.0
        )
        // Two shots with identical timing/provider, differing only in source_mode.
        let generatedShot = try makeShot(
            id: "s001", provider: .fal, suggestion: nil, section: "verse",
            timeStart: 0.0, timeEnd: 8.0, sourceMode: .generated
        )
        let enhancedShot = try makeShot(
            id: "s002", provider: .fal, suggestion: nil, section: "chorus",
            timeStart: 8.0, timeEnd: 16.0, sourceMode: .aiEnhanced
        )
        let liveShot = try makeShot(
            id: "s003", provider: .fal, suggestion: nil, section: "bridge",
            timeStart: 16.0, timeEnd: 24.0, sourceMode: .imported
        )
        let shotlist = try Shotlist(
            schema_: "shotlist/v3", mode: .section, project: "p", song: song,
            generated: "2026-01-01", generator: "test", shots: [generatedShot, enhancedShot, liveShot]
        )
        let est = estimate(
            shotlist: shotlist, costs: .bundledDefault, phase: .final, finalResolution: "1080p"
        )

        // s002 (ai_enhanced) is billed identically to s001 (generated) — same duration, provider, price.
        #expect(est.shotEstimates[1].eur == est.shotEstimates[0].eur)
        #expect(est.shotEstimates[1].eur > 0)
        #expect(est.shotEstimates[1].runwayModel == est.shotEstimates[0].runwayModel)

        // s003 (live_action) contributes 0 with the "imported" note and empty model.
        #expect(est.shotEstimates[2].eur == 0.0)
        #expect(est.shotEstimates[2].notes == "imported")
        #expect(est.shotEstimates[2].runwayModel == "")
        #expect(est.shotEstimates[2].truncated == false)
        // The live shot's declared duration is preserved (rounded), not zeroed.
        #expect(est.shotEstimates[2].durationS == 8.0)

        // Project total excludes the live shot but includes the enhanced one.
        #expect(est.totalEur == pyRound(est.shotEstimates[0].eur + est.shotEstimates[1].eur, 2))
    }

    // MARK: - Branch coverage the BEAT golden doesn't exercise

    /// Bug-24: a FAL shot must never pick up the Runway-legacy `seedance2`
    /// price. `runwayModel(for:)` returns `defaults[phase]` when it's a fal
    /// model, ignoring `model_suggestion` entirely.
    @Test("Bug-24 — FAL shot ignores model_suggestion, uses fal defaults")
    func bug24FalPath() throws {
        let cfg = CostsConfig.bundledDefault
        let falShot = try makeShot(id: "s001", provider: .fal, suggestion: .seedance20)
        #expect(cfg.runwayModel(for: falShot, phase: .final) == "fal:bytedance/seedance-2.0/pro")
        #expect(cfg.runwayModel(for: falShot, phase: .preview) == "fal:bytedance/seedance-2.0/fast")

        // FAL + defaults pointing at a Runway model → safe fal fallback.
        let staleCfg = CostsConfig(
            pricing: cfg.pricing, modelMap: cfg.modelMap,
            defaults: ["preview": "seedance2", "final": "seedance2"],
            overlapPreS: 1.5, overlapPostS: 1.5, pollingIntervalS: 5, pollingTimeoutS: 600
        )
        #expect(staleCfg.runwayModel(for: falShot, phase: .final) == "fal:bytedance/seedance-2.0/fast")
    }

    /// The Runway (legacy) path: the lookup is keyed by the enum *value*
    /// (`"seedance-2.0"`), but the bundled `model_map` key is the enum *name*
    /// (`SEEDANCE_2_0`), so the suggestion misses and it falls through to
    /// `defaults[phase]` → a fal model → the `"seedance2"` legacy fallback.
    @Test("Runway path — suggestion misses model_map, falls back to seedance2")
    func runwayLegacyFallback() throws {
        let cfg = CostsConfig.bundledDefault
        let runwayShot = try makeShot(id: "s001", provider: .runway, suggestion: .seedance20)
        #expect(cfg.runwayModel(for: runwayShot, phase: .final) == "seedance2")

        // With a model_map keyed by the enum value, the suggestion hits.
        let valueKeyedCfg = CostsConfig(
            pricing: cfg.pricing, modelMap: ["seedance-2.0": "seedance2"],
            defaults: cfg.defaults, overlapPreS: 1.5, overlapPostS: 1.5, pollingIntervalS: 5,
            pollingTimeoutS: 600
        )
        #expect(valueKeyedCfg.runwayModel(for: runwayShot, phase: .final) == "seedance2")

        // Runway + defaults on a real Runway slug, no suggestion → defaults.
        let runwayDefaults = CostsConfig(
            pricing: cfg.pricing, modelMap: [:],
            defaults: ["preview": "seedance2", "final": "seedance2"],
            overlapPreS: 1.5, overlapPostS: 1.5, pollingIntervalS: 5, pollingTimeoutS: 600
        )
        let noSuggestion = try makeShot(id: "s001", provider: .runway, suggestion: nil)
        #expect(runwayDefaults.runwayModel(for: noSuggestion, phase: .final) == "seedance2")
    }

    /// `resolutionForPhase` per model/phase — the preview branch, the Fast
    /// 1080p→720p clamp, and the Runway (non-fal) → nil branch.
    @Test("resolution_for_phase — preview/final, Fast clamp, Runway nil")
    func resolutionForPhaseBranches() {
        // Runway model → nil (ratios carry resolution).
        #expect(resolutionForPhase(modelId: "seedance2", phase: .final) == nil)
        #expect(resolutionForPhase(modelId: "seedance2", phase: .preview) == nil)
        // Fast has no 1080p → clamps to 720p on final.
        #expect(
            resolutionForPhase(
                modelId: "fal:bytedance/seedance-2.0/fast", phase: .final, finalResolution: "1080p"
            ) == "720p")
        // Fast at an explicit 720p final stays 720p.
        #expect(
            resolutionForPhase(
                modelId: "fal:bytedance/seedance-2.0/fast", phase: .final, finalResolution: "720p"
            ) == "720p")
        // Pro final honors the brief resolution.
        #expect(
            resolutionForPhase(
                modelId: "fal:bytedance/seedance-2.0/pro", phase: .final, finalResolution: "1080p"
            ) == "1080p")
        // Preview → smallest available (720p) for any fal model.
        #expect(
            resolutionForPhase(modelId: "fal:bytedance/seedance-2.0/pro", phase: .preview) == "720p")
        #expect(
            resolutionForPhase(modelId: "fal:bytedance/seedance-2.0/fast", phase: .preview) == "720p")
    }

    /// `stitchedSegments` — `max(1, ceil(total/limit))`.
    @Test("stitched_segments — ceil, floored at 1")
    func stitchedSegmentsMath() {
        #expect(stitchedSegments(totalS: 5.0, modelLimitS: 10.0) == 1)
        #expect(stitchedSegments(totalS: 10.0, modelLimitS: 10.0) == 1)
        #expect(stitchedSegments(totalS: 10.1, modelLimitS: 10.0) == 2)
        #expect(stitchedSegments(totalS: 25.0, modelLimitS: 10.0) == 3)
    }

    /// The stitch (non-BEAT/PHRASE) branch of `estimate`: SECTION mode bills the
    /// full duration (no truncate/pad) and annotates `stitch=N` when segmented.
    @Test("estimate stitch branch — SECTION mode bills full duration with stitch note")
    func estimateStitchBranch() throws {
        // Two long section shots, FAL → Pro 1080p @ 0.682/s, max 10s per call.
        let song = try Song(
            title: "s", audioPath: "a.wav", analysisPath: "an.json", bpm: 120.0, durationS: 60.0
        )
        let shots = [
            try makeShot(
                id: "s001", provider: .fal, suggestion: nil, section: "verse",
                timeStart: 0.0, timeEnd: 25.0
            ),
            try makeShot(
                id: "s002", provider: .fal, suggestion: nil, section: "chorus",
                timeStart: 25.0, timeEnd: 33.0
            ),
        ]
        let shotlist = try Shotlist(
            schema_: "shotlist/v3", mode: .section, project: "p", song: song,
            generated: "2026-01-01", generator: "test", shots: shots
        )
        let est = estimate(
            shotlist: shotlist, costs: .bundledDefault, phase: .final, finalResolution: "1080p"
        )

        // s001: 25s billed in full → 25 * 0.682 = 17.05; ceil(25/10)=3 segments.
        #expect(est.shotEstimates[0].durationS == 25.0)
        #expect(est.shotEstimates[0].eur == pyRound(25.0 * 0.682, 3))
        #expect(est.shotEstimates[0].eur == 17.05)
        #expect(est.shotEstimates[0].truncated == false)
        #expect(est.shotEstimates[0].notes == "stitch=3; @1080p")
        // s002: 8s ≤ 10s → 1 segment → no stitch prefix, just @1080p.
        #expect(est.shotEstimates[1].durationS == 8.0)
        #expect(est.shotEstimates[1].eur == pyRound(8.0 * 0.682, 3))
        #expect(est.shotEstimates[1].notes == "@1080p")
        #expect(est.totalEur == pyRound(17.05 + pyRound(8.0 * 0.682, 3), 2))
    }

    // MARK: - Cost guard

    /// `costGuardCheck` wiring: prior spend (exclude current phase) + the
    /// confirm threshold + over-budget flags. Port of the semantics of
    /// `cost_guard_check` / `CostGuardVerdict`.
    @Test("cost_guard_check — prior spend, confirm threshold, over-budget")
    func costGuardCheckWiring() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let renders = tmp.appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        try #"{"shots": [{"shot_id": "s001", "eur_spent": 4.0}]}"#.write(
            to: renders.appendingPathComponent("manifest-preview.json"), atomically: true,
            encoding: .utf8
        )
        // A stale final manifest from a previous run of the SAME phase must be
        // excluded so it doesn't double-count.
        try #"{"shots": [{"shot_id": "s001", "eur_spent": 99.0}]}"#.write(
            to: renders.appendingPathComponent("manifest-final.json"), atomically: true,
            encoding: .utf8
        )

        let verdict = costGuardCheck(
            dataRoot: tmp, estimateEur: 12.0, phase: .final, budgetEur: 10.0, guard: CostGuard()
        )
        #expect(verdict.newRunEur == 12.0)
        #expect(verdict.alreadySpentEur == 4.0)  // final excluded, only preview
        #expect(verdict.projectTotalEur == 16.0)
        #expect(verdict.overBudget == true)  // 16 > 10
        #expect(verdict.needsConfirmation == true)  // 12 >= 10
        #expect(verdict.confirmThresholdEur == 10.0)

        // projectWideBudget=false → prior spend ignored.
        let noWide = costGuardCheck(
            dataRoot: tmp, estimateEur: 5.0, phase: .final, budgetEur: 10.0,
            guard: CostGuard(confirmThresholdEur: 10.0, projectWideBudget: false)
        )
        #expect(noWide.alreadySpentEur == 0.0)
        #expect(noWide.projectTotalEur == 5.0)
        #expect(noWide.overBudget == false)
        #expect(noWide.needsConfirmation == false)  // 5 < 10
    }

    /// The bundled default and its YAML serialization price identically —
    /// guards against the two drifting apart (they're hand-kept in lockstep in
    /// `LoadCosts.swift`, mirrored by the regen script's inline YAML).
    @Test("bundledDefault equals load of bundledDefaultYAML")
    func bundledDefaultMatchesYAML() throws {
        let fromYAML = try loadCosts(fromYAML: CostsConfig.bundledDefaultYAML)
        #expect(fromYAML == .bundledDefault)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "costs-test-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeShot(
        id: String, provider: SceneVideoProvider, suggestion: ModelSuggestion?,
        section: String? = "verse", timeStart: Double = 0.0, timeEnd: Double = 8.0,
        sourceMode: SourceMode = .generated
    ) throws -> Shot {
        try Shot(
            id: id, section: section, timeStart: timeStart, timeEnd: timeEnd,
            durationS: timeEnd - timeStart, type: .performance, sourceMode: sourceMode,
            description: "d", visualPrompt: "v", mood: "calm", modelSuggestion: suggestion,
            sceneVideoProvider: provider
        )
    }

    private static func fixtureDataRoot() throws -> URL {
        let url = try #require(
            Bundle.module.url(
                forResource: "project", withExtension: "yaml",
                subdirectory: "Fixtures/basic-project/pipeline"
            ),
            "fixture project.yaml not found in test bundle"
        )
        return url.deletingLastPathComponent()
    }

    static func costGolden() throws -> [String: Any] {
        let url = try #require(
            Bundle.module.url(
                forResource: "cost-estimate", withExtension: "json",
                subdirectory: "Goldens/basic-project"
            ),
            "cost-estimate.json not found in test bundle"
        )
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        return try #require(object as? [String: Any], "cost-estimate.json is not a JSON object")
    }
}
