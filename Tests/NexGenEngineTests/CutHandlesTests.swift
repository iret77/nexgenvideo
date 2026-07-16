import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// Cut handles as content (#213) — derivation from planned transitions + global override, gross
/// duration, the temporal-structure prompt, the handle_discipline check, and backward-compatible decode.
@Suite("cut handles (#213)")
struct CutHandlesTests {
    static func shot(
        _ id: String, duration: Double = 4, tin: TransitionType = .hardCut,
        tout: TransitionType = .hardCut, motion: String? = nil, visual: String = "a figure walks"
    ) throws -> Shot {
        try Shot(id: id, section: "verse", timeStart: 0, timeEnd: duration, durationS: duration,
                 type: .performance, description: "d", visualPrompt: visual, motion: motion, mood: "m",
                 transitionIn: tin, transitionOut: tout)
    }

    static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        try Shotlist(schema_: shotlistSchemaVersion, mode: .beat, project: "p",
                     song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                                    bpm: 120, tempoMultiplier: 1, durationS: 180),
                     generated: "t", generator: "g", shots: shots)
    }

    // MARK: - Derivation

    @Test("a hard-cut shot carries no handle: gross equals net")
    func hardCutNoHandle() throws {
        let s = try Self.shot("s1")
        let h = CutHandles.handles(for: s, forceAll: false)
        #expect(h.pre == 0 && h.post == 0)
        #expect(CutHandles.grossDuration(for: s, forceAll: false) == 4)
        #expect(CutHandles.temporalStructure(for: s, forceAll: false) == nil)
    }

    @Test("a fade side gets a handle on that side only")
    func fadeSideGetsHandle() throws {
        let s = try Self.shot("s1", tout: .fade)
        let h = CutHandles.handles(for: s, forceAll: false)
        #expect(h.pre == 0)
        #expect(h.post == CutHandles.handleSeconds)
        #expect(CutHandles.grossDuration(for: s, forceAll: false) == 4 + CutHandles.handleSeconds)
    }

    @Test("crossfade on both sides handles both")
    func crossfadeBothSides() throws {
        let s = try Self.shot("s1", tin: .crossfade, tout: .crossfade)
        let h = CutHandles.handles(for: s, forceAll: false)
        #expect(h.pre == CutHandles.handleSeconds && h.post == CutHandles.handleSeconds)
    }

    @Test("the global override forces handles on a hard-cut shot")
    func globalOverrideForcesHandles() throws {
        let s = try Self.shot("s1")  // hard cut both sides
        let h = CutHandles.handles(for: s, forceAll: true)
        #expect(h.pre == CutHandles.handleSeconds && h.post == CutHandles.handleSeconds)
        #expect(CutHandles.grossDuration(for: s, forceAll: true) == 4 + 2 * CutHandles.handleSeconds)
    }

    // MARK: - Temporal structure prompt

    @Test("temporal structure describes a held pre-beat and post-hold for a handled shot")
    func temporalStructureContent() throws {
        let s = try Self.shot("s1", tin: .fade, tout: .fade)
        let text = try #require(CutHandles.temporalStructure(for: s, forceAll: false))
        #expect(text.lowercased().contains("micro-motion"))
        #expect(text.contains("action"))
        #expect(text.lowercased().contains("hold"))
    }

    // MARK: - Cost bills gross

    @Test("estimate feeds the gross duration into billing — handled bills at least as much as plain")
    func estimateBillsGross() throws {
        let plain = try Self.shotlist([try Self.shot("s1")])
        let handled = try Self.shotlist([try Self.shot("s1", tout: .fade)])
        let costs = CostsConfig.bundledDefault
        let ePlain = estimate(shotlist: plain, costs: costs, phase: .final)
        let eHandled = estimate(shotlist: handled, costs: costs, phase: .final)
        // The billed duration can be clamped to the model's min/max, so assert the relationship, not a
        // fixed number. The exact gross is pinned config-independently on CutHandles.grossDuration above.
        #expect(eHandled.shotEstimates[0].eur >= ePlain.shotEstimates[0].eur)
        #expect(eHandled.shotEstimates[0].durationS >= ePlain.shotEstimates[0].durationS)
    }

    @Test("forceHandles feeds a larger gross into billing than the un-forced pass")
    func estimateForceHandles() throws {
        let sl = try Self.shotlist([try Self.shot("s1")])
        let costs = CostsConfig.bundledDefault
        let plain = estimate(shotlist: sl, costs: costs, phase: .final, forceHandles: false)
        let forced = estimate(shotlist: sl, costs: costs, phase: .final, forceHandles: true)
        #expect(forced.shotEstimates[0].durationS >= plain.shotEstimates[0].durationS)
    }

    // MARK: - handle_discipline check

    @Test("flags a handled shot whose motion can't hold at the edge")
    func handleDisciplineFlagsUnholdable() throws {
        let ctx = AuditContext(shotlist: try Self.shotlist([
            try Self.shot("s1", tout: .fade, motion: "a fast whip pan across the room"),
        ]))
        let findings = try MusicvideoChecks.handleDisciplineCheck(ctx)
        #expect(findings.contains { $0.code == "HANDLE_HOLD_IMPLAUSIBLE" && $0.shotId == "s1" })
    }

    @Test("does not flag a hard-cut shot even with unholdable motion (no handle rendered)")
    func handleDisciplineIgnoresHardCut() throws {
        let ctx = AuditContext(shotlist: try Self.shotlist([
            try Self.shot("s1", motion: "a violent whip pan"),
        ]))
        #expect(try MusicvideoChecks.handleDisciplineCheck(ctx).isEmpty)
    }

    @Test("does not flag a handled shot that can hold")
    func handleDisciplinePassesHoldable() throws {
        let ctx = AuditContext(shotlist: try Self.shotlist([
            try Self.shot("s1", tout: .fade, motion: "a slow drift toward the window"),
        ]))
        #expect(try MusicvideoChecks.handleDisciplineCheck(ctx).isEmpty)
    }

    // MARK: - Backward compatibility

    @Test("a shotlist shot without transition fields decodes as hard cut")
    func decodeDefaultsHardCut() throws {
        let json = """
        {"id":"s1","time_start":0,"time_end":4,"duration_s":4,"type":"performance",
         "description":"d","visual_prompt":"p","mood":"m"}
        """
        let shot = try JSONDecoder().decode(Shot.self, from: Data(json.utf8))
        #expect(shot.transitionIn == .hardCut)
        #expect(shot.transitionOut == .hardCut)
        #expect(CutHandles.grossDuration(for: shot, forceAll: false) == 4)
    }
}
