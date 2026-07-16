import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// Cut handles as content (#213) — derivation from planned transitions + global override, gross
/// duration, the temporal-structure prompt, the handle_discipline check, and backward-compatible decode.
@Suite("cut handles (#213)")
struct CutHandlesTests {
    static func shot(
        _ id: String, start: Double = 0, duration: Double = 4, tin: TransitionType = .hardCut,
        tout: TransitionType = .hardCut, motion: String? = nil, visual: String = "a figure walks"
    ) throws -> Shot {
        try Shot(id: id, section: "verse", timeStart: start, timeEnd: start + duration, durationS: duration,
                 type: .performance, description: "d", visualPrompt: visual, motion: motion, mood: "m",
                 transitionIn: tin, transitionOut: tout)
    }

    static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        try Shotlist(schema_: shotlistSchemaVersion, mode: .beat, project: "p",
                     song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                                    bpm: 120, tempoMultiplier: 1, durationS: 180),
                     generated: "t", generator: "g", shots: shots)
    }

    static func brief(cutHandles: CutHandlesMode) throws -> Brief {
        try Brief(project: "p", generated: "t", mission: .demo, targetPlatform: "web",
                  aspectRatio: .landscape16x9, projectMode: "beat", conceptType: .abstract,
                  visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored,
                  cutHandlesMode: cutHandles)
    }

    // MARK: - Derivation

    @Test("a hard-cut shot carries no handle: gross equals net")
    func hardCutNoHandle() throws {
        let s = try Self.shot("s001")
        let h = CutHandles.handles(for: s, forceAll: false)
        #expect(h.pre == 0 && h.post == 0)
        #expect(CutHandles.grossDuration(for: s, forceAll: false) == 4)
        #expect(CutHandles.temporalStructure(for: s, forceAll: false) == nil)
    }

    @Test("a fade side gets a handle on that side only")
    func fadeSideGetsHandle() throws {
        let s = try Self.shot("s001", tout: .fade)
        let h = CutHandles.handles(for: s, forceAll: false)
        #expect(h.pre == 0)
        #expect(h.post == CutHandles.handleSeconds)
        #expect(CutHandles.grossDuration(for: s, forceAll: false) == 4 + CutHandles.handleSeconds)
    }

    @Test("crossfade on both sides handles both")
    func crossfadeBothSides() throws {
        let s = try Self.shot("s001", tin: .crossfade, tout: .crossfade)
        let h = CutHandles.handles(for: s, forceAll: false)
        #expect(h.pre == CutHandles.handleSeconds && h.post == CutHandles.handleSeconds)
    }

    @Test("the global override forces handles on a hard-cut shot")
    func globalOverrideForcesHandles() throws {
        let s = try Self.shot("s001")  // hard cut both sides
        let h = CutHandles.handles(for: s, forceAll: true)
        #expect(h.pre == CutHandles.handleSeconds && h.post == CutHandles.handleSeconds)
        #expect(CutHandles.grossDuration(for: s, forceAll: true) == 4 + 2 * CutHandles.handleSeconds)
    }

    @Test("the orderable gross is a whole second, even for a fractional beat-derived net")
    func orderableGrossIsWholeSecond() throws {
        // A beat-derived net is routinely fractional; the ordered duration must still be orderable.
        let s = try Self.shot("s001", duration: 3.5, tout: .fade)
        #expect(CutHandles.grossDuration(for: s, forceAll: false) == 4.5)
        #expect(CutHandles.orderableGrossDuration(for: s, forceAll: false) == 5)  // ceil(4.5)
        // Already whole → unchanged, no gratuitous inflation.
        let whole = try Self.shot("s002", duration: 4, tout: .fade)
        #expect(CutHandles.orderableGrossDuration(for: whole, forceAll: false) == 5)
    }

    @Test("orderable gross never rounds below a renderable second")
    func orderableGrossFloor() throws {
        let tiny = try Self.shot("s001", duration: 0.4)
        #expect(CutHandles.orderableGrossDuration(for: tiny, forceAll: false) >= 1)
    }

    // MARK: - Temporal structure prompt

    @Test("temporal structure describes a held pre-beat and post-hold for a handled shot")
    func temporalStructureContent() throws {
        let s = try Self.shot("s001", tin: .fade, tout: .fade)
        let text = try #require(CutHandles.temporalStructure(for: s, forceAll: false))
        #expect(text.lowercased().contains("micro-motion"))
        #expect(text.contains("action"))
        #expect(text.lowercased().contains("hold"))
    }

    // MARK: - Cost bills gross

    @Test("estimate feeds the gross duration into billing — handled bills at least as much as plain")
    func estimateBillsGross() throws {
        let plain = try Self.shotlist([try Self.shot("s001")])
        let handled = try Self.shotlist([try Self.shot("s001", tout: .fade)])
        let costs = CostsConfig.bundledDefault
        let ePlain = estimate(shotlist: plain, costs: costs, phase: .final)
        let eHandled = estimate(shotlist: handled, costs: costs, phase: .final)
        // The billed duration can be clamped to the model's min/max, so assert the relationship, not a
        // fixed number. The exact gross is pinned config-independently on CutHandles.grossDuration above.
        #expect(eHandled.shotEstimates[0].eur >= ePlain.shotEstimates[0].eur)
        #expect(eHandled.shotEstimates[0].durationS >= ePlain.shotEstimates[0].durationS)
    }

    @Test("a handled shot is priced at exactly the whole second the agent is told to order")
    func pricesTheOrderedDuration() throws {
        // Fractional net + a fade handle: ordered = ceil(3.5 + 1) = 5s. Pricing the raw 4.5 would
        // under-estimate, and the budget stop (#198) is pre-flight — an under-estimate lets spend
        // through that the user's limit should have blocked. Asserted on the pricing input directly, so
        // it holds regardless of the provider's own min/max clamp.
        let handled = try Self.shot("s001", duration: 3.5, tout: .fade)
        let priced = seedanceRenderDuration(
            handled, costs: CostsConfig.bundledDefault, mode: .beat, forceHandles: false)
        #expect(priced == 5)
        #expect(priced == Double(CutHandles.orderableGrossDuration(for: handled, forceAll: false)))
    }

    @Test("an unhandled shot's pricing is untouched by #213")
    func unhandledPricingUnchanged() throws {
        // No handle → the shot's own (possibly fractional) duration reaches pricing exactly as before.
        // What the agent rounds a bare fractional net to is a separate, pre-existing question.
        let plain = try Self.shot("s001", duration: 3.5)
        let priced = seedanceRenderDuration(
            plain, costs: CostsConfig.bundledDefault, mode: .beat, forceHandles: false)
        #expect(priced == 3.5)
    }

    @Test("forceHandles feeds a larger gross into billing than the un-forced pass")
    func estimateForceHandles() throws {
        let sl = try Self.shotlist([try Self.shot("s001")])
        let costs = CostsConfig.bundledDefault
        let plain = estimate(shotlist: sl, costs: costs, phase: .final, forceHandles: false)
        let forced = estimate(shotlist: sl, costs: costs, phase: .final, forceHandles: true)
        #expect(forced.shotEstimates[0].durationS >= plain.shotEstimates[0].durationS)
    }

    // MARK: - handle_discipline check

    @Test("flags a handled shot whose motion can't hold at the edge")
    func handleDisciplineFlagsUnholdable() throws {
        let ctx = AuditContext(shotlist: try Self.shotlist([
            try Self.shot("s001", tout: .fade, motion: "a fast whip pan across the room"),
        ]))
        let findings = try MusicvideoChecks.handleDisciplineCheck(ctx)
        #expect(findings.contains { $0.code == "HANDLE_HOLD_IMPLAUSIBLE" && $0.shotId == "s001" })
    }

    @Test("does not flag a hard-cut shot even with unholdable motion (no handle rendered)")
    func handleDisciplineIgnoresHardCut() throws {
        let ctx = AuditContext(shotlist: try Self.shotlist([
            try Self.shot("s001", motion: "a violent whip pan"),
        ]))
        #expect(try MusicvideoChecks.handleDisciplineCheck(ctx).isEmpty)
    }

    @Test("does not flag a handled shot that can hold")
    func handleDisciplinePassesHoldable() throws {
        let ctx = AuditContext(shotlist: try Self.shotlist([
            try Self.shot("s001", tout: .fade, motion: "a slow drift toward the window"),
        ]))
        #expect(try MusicvideoChecks.handleDisciplineCheck(ctx).isEmpty)
    }

    @Test("flags a one-sided fade/crossfade boundary between adjacent shots")
    func handleBoundaryMismatch() throws {
        // s001 fades out, but s002 comes in on a hard cut — the blend is starved on s002's side.
        let ctx = AuditContext(shotlist: try Self.shotlist([
            try Self.shot("s001", start: 0, tout: .crossfade),
            try Self.shot("s002", start: 4),
        ]))
        let findings = try MusicvideoChecks.handleDisciplineCheck(ctx)
        #expect(findings.contains { $0.code == "HANDLE_BOUNDARY_MISMATCH" && $0.shotId == "s001" })
    }

    @Test("a matched crossfade boundary is not flagged")
    func handleBoundaryMatched() throws {
        let ctx = AuditContext(shotlist: try Self.shotlist([
            try Self.shot("s001", start: 0, tout: .crossfade),
            try Self.shot("s002", start: 4, tin: .crossfade),
        ]))
        #expect(!(try MusicvideoChecks.handleDisciplineCheck(ctx)).contains { $0.code == "HANDLE_BOUNDARY_MISMATCH" })
    }

    @Test("under the global override, a forced hard-cut shot's warning names the override, not a no-op")
    func forcedHandleMessageNamesOverride() throws {
        let ctx = AuditContext(
            shotlist: try Self.shotlist([try Self.shot("s001", motion: "a violent whip pan")]),
            brief: try Self.brief(cutHandles: .withOverlap))
        let findings = try MusicvideoChecks.handleDisciplineCheck(ctx)
        let hold = try #require(findings.first { $0.code == "HANDLE_HOLD_IMPLAUSIBLE" })
        #expect(hold.message.contains("with_overlap"))
        // Nothing was planned, so advising a hard cut would be a no-op — it must not appear.
        #expect(!hold.message.contains("drop the planned transition"))
    }

    @Test("a shot both forced AND planned names both remedies, not just one")
    func mixedForcedAndPlannedRemedy() throws {
        // transition_out is a planned fade (post handle); the override forces the pre handle too.
        // Advising only the hard cut would leave the forced pre-handle in place.
        let ctx = AuditContext(
            shotlist: try Self.shotlist([
                try Self.shot("s001", tout: .fade, motion: "a violent whip pan"),
            ]),
            brief: try Self.brief(cutHandles: .withOverlap))
        let hold = try #require(
            try MusicvideoChecks.handleDisciplineCheck(ctx).first { $0.code == "HANDLE_HOLD_IMPLAUSIBLE" })
        #expect(hold.message.contains("drop the planned transition"))
        #expect(hold.message.contains("with_overlap"))
    }

    // MARK: - Backward compatibility

    @Test("a shotlist shot without transition fields decodes as hard cut")
    func decodeDefaultsHardCut() throws {
        let json = """
        {"id":"s001","time_start":0,"time_end":4,"duration_s":4,"type":"performance",
         "description":"d","visual_prompt":"p","mood":"m"}
        """
        let shot = try JSONDecoder().decode(Shot.self, from: Data(json.utf8))
        #expect(shot.transitionIn == .hardCut)
        #expect(shot.transitionOut == .hardCut)
        #expect(CutHandles.grossDuration(for: shot, forceAll: false) == 4)
    }
}
