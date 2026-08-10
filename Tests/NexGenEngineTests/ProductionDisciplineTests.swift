import Testing
@testable import NexGenEngine

@Suite("Production discipline")
struct ProductionDisciplineTests {
    private static func plan(
        beat: NarrativeBeat? = .action,
        rating: RenderabilityRating = .green,
        risks: [RenderabilityRisk] = [],
        rescue: String? = nil
    ) throws -> ShotProductionPlan {
        try ShotProductionPlan(
            primaryAction: "The subject crosses the doorway.",
            cameraMovement: .static,
            narrativeBeat: beat,
            renderability: rating,
            risks: risks,
            rescueCut: rescue,
            continuityLocks: ["subject exits screen-right"]
        )
    }

    private static func shot(
        id: String = "s001",
        start: Double = 0,
        end: Double = 8,
        characters: [String] = [],
        plan: ShotProductionPlan? = nil,
        section: String? = "scene",
        sourceMode: SourceMode = .generated,
        cameraId: String? = nil,
        characterBlocking: [CharacterBlocking] = []
    ) throws -> Shot {
        try Shot(
            id: id,
            section: section,
            timeStart: start,
            timeEnd: end,
            durationS: end - start,
            type: .establishing,
            sourceMode: sourceMode,
            description: "A direct production test shot.",
            visualPrompt: "Static wide shot of a subject crossing a doorway.",
            mood: "controlled",
            characterRefs: characters,
            characterBlocking: characterBlocking,
            cameraId: cameraId,
            productionPlan: plan
        )
    }

    private static func shotlist(_ shots: [Shot]) throws -> Shotlist {
        let duration = shots.map(\.timeEnd).max() ?? 8
        return try Shotlist(
            schema_: shotlistSchemaVersion,
            mode: .section,
            project: "production-test",
            song: Song(
                title: "test",
                audioPath: "audio/test.wav",
                analysisPath: "analysis/test.json",
                bpm: 120,
                durationS: duration
            ),
            generated: "2026-08-08T00:00:00Z",
            generator: "test",
            shots: shots
        )
    }

    @Test("inactive profiles do not impose film-production checks")
    func inactiveProfile() throws {
        let ctx = AuditContext(shotlist: try Self.shotlist([Self.shot()]))
        #expect(try productionRenderabilityCheck(ctx).isEmpty)
    }

    @Test("legacy shots are readable but flagged for a production plan")
    func legacyShotWarning() throws {
        let ctx = AuditContext(
            shotlist: try Self.shotlist([Self.shot()]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).map(\.code) == ["PRODUCTION_PLAN_MISSING"])
    }

    @Test("imported shots do not require a production plan")
    func importedShotNeedsNoPlan() throws {
        let ctx = AuditContext(
            shotlist: try Self.shotlist([Self.shot(sourceMode: .imported)]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).isEmpty)
    }

    @Test("generated long takes and crowded shots fail deterministically")
    func renderabilityErrors() throws {
        let shot = try Self.shot(
            end: 13,
            characters: ["a", "b", "c"],
            plan: Self.plan()
        )
        let ctx = AuditContext(
            shotlist: try Self.shotlist([shot]),
            productionProfileIDs: [.generativeFilm]
        )
        let codes = Set(try productionRenderabilityCheck(ctx).map(\.code))
        #expect(codes == ["TOO_MANY_VISIBLE_CHARACTERS", "LONG_TAKE_RISK_UNDECLARED"])
    }

    @Test("declared long takes carry a rescue cut")
    func declaredLongTake() throws {
        let shot = try Self.shot(
            end: 13,
            plan: Self.plan(
                rating: .yellow,
                risks: [.longTake],
                rescue: "Split at the doorway and continue on the reaction."
            )
        )
        let ctx = AuditContext(
            shotlist: try Self.shotlist([shot]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).isEmpty)
    }

    @Test("AI-enhanced shots do not inherit generated-shot feasibility limits")
    func enhancedShotFeasibility() throws {
        let blocking = try CharacterBlocking(
            characterRef: "a",
            position: "right third",
            pose: "standing",
            gaze: "toward camera",
            relationToSet: "camera center"
        )
        let shot = try Self.shot(
            end: 20,
            characters: ["a", "b", "c"],
            plan: Self.plan(),
            sourceMode: .aiEnhanced,
            characterBlocking: [blocking]
        )
        let ctx = AuditContext(
            shotlist: try Self.shotlist([shot]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).isEmpty)
    }

    @Test("planned generated blocking names a set anchor")
    func blockingAnchorRequired() throws {
        let blocking = try CharacterBlocking(
            characterRef: "subject",
            position: "near the doorway",
            pose: "standing",
            gaze: "toward the hall"
        )
        let base = try Self.shot(
            characters: ["subject"],
            plan: Self.plan()
        )
        let shot = try Shot(
            id: base.id,
            section: base.section,
            timeStart: base.timeStart,
            timeEnd: base.timeEnd,
            durationS: base.durationS,
            type: base.type,
            description: base.description,
            visualPrompt: base.visualPrompt,
            mood: base.mood,
            characterRefs: base.characterRefs,
            characterBlocking: [blocking],
            productionPlan: base.productionPlan
        )
        let ctx = AuditContext(
            shotlist: try Self.shotlist([shot]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).map(\.code) == ["BLOCKING_ANCHOR_MISSING"])
    }

    @Test("screen direction prose without a set anchor is rejected")
    func screenDirectionIsNotAnchor() throws {
        let blocking = try CharacterBlocking(
            characterRef: "subject",
            position: "right third",
            pose: "standing",
            gaze: "toward the hall",
            relationToSet: "screen-right"
        )
        let base = try Self.shot(
            characters: ["subject"],
            plan: Self.plan()
        )
        let shot = try Shot(
            id: base.id,
            section: base.section,
            timeStart: base.timeStart,
            timeEnd: base.timeEnd,
            durationS: base.durationS,
            type: base.type,
            description: base.description,
            visualPrompt: base.visualPrompt,
            mood: base.mood,
            characterRefs: base.characterRefs,
            characterBlocking: [blocking],
            productionPlan: base.productionPlan
        )
        let ctx = AuditContext(
            shotlist: try Self.shotlist([shot]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).map(\.code) == ["BLOCKING_ANCHOR_MISSING"])
    }

    @Test("spatial prose cannot substitute for a named set anchor")
    func spatialProseIsNotAnchor() throws {
        let blocking = try CharacterBlocking(
            characterRef: "subject",
            position: "right third",
            pose: "standing",
            gaze: "toward the hall",
            relationToSet: "stage centre third"
        )
        let shot = try Self.shot(
            characters: ["subject"],
            plan: Self.plan(),
            characterBlocking: [blocking]
        )
        let ctx = AuditContext(
            shotlist: try Self.shotlist([shot]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).map(\.code) == ["BLOCKING_ANCHOR_MISSING"])
    }

    @Test("screen direction alone cannot substitute for a named set anchor")
    func screenDirectionIsNotAnchor() throws {
        let blocking = try CharacterBlocking(
            characterRef: "subject",
            position: "right third",
            pose: "standing",
            gaze: "toward the hall",
            relationToSet: "beside the doorway",
            setAnchor: "screen-right"
        )
        let shot = try Self.shot(
            characters: ["subject"],
            plan: Self.plan(),
            characterBlocking: [blocking]
        )
        let ctx = AuditContext(
            shotlist: try Self.shotlist([shot]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).map(\.code) == ["BLOCKING_ANCHOR_MISSING"])
    }

    @Test("a named anchor still requires its spatial relationship")
    func namedAnchorRequiresRelationship() throws {
        let blocking = try CharacterBlocking(
            characterRef: "subject",
            position: "right third",
            pose: "standing",
            gaze: "toward the hall",
            setAnchor: "hall doorway"
        )
        let shot = try Self.shot(
            characters: ["subject"],
            plan: Self.plan(),
            characterBlocking: [blocking]
        )
        let ctx = AuditContext(
            shotlist: try Self.shotlist([shot]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).map(\.code) == ["BLOCKING_ANCHOR_MISSING"])
    }

    @Test("a named set anchor satisfies generated blocking")
    func namedSetAnchor() throws {
        let blocking = try CharacterBlocking(
            characterRef: "subject",
            position: "right third",
            pose: "standing",
            gaze: "toward the hall",
            relationToSet: "beside the doorway",
            setAnchor: "hall doorway"
        )
        let shot = try Self.shot(
            characters: ["subject"],
            plan: Self.plan(),
            characterBlocking: [blocking]
        )
        let ctx = AuditContext(
            shotlist: try Self.shotlist([shot]),
            productionProfileIDs: [.generativeFilm]
        )
        #expect(try productionRenderabilityCheck(ctx).isEmpty)
    }

    @Test("narrative profiles require a beat on every shot")
    func narrativeBeatRequired() throws {
        let ctx = AuditContext(
            shotlist: try Self.shotlist([Self.shot(plan: Self.plan(beat: nil))]),
            productionProfileIDs: [.narrativeStorytelling]
        )
        #expect(try narrativeStructureCheck(ctx).map(\.code) == ["NARRATIVE_BEAT_MISSING"])
    }

    @Test("legacy narrative sequences defer beat checks until production plans exist")
    func legacyNarrativeSequence() throws {
        let shots = try [
            Self.shot(id: "s001", start: 0, end: 4),
            Self.shot(id: "s002", start: 4, end: 8),
            Self.shot(id: "s003", start: 8, end: 12),
        ]
        let ctx = AuditContext(
            shotlist: try Self.shotlist(shots),
            productionProfileIDs: [.narrativeStorytelling]
        )
        #expect(try narrativeStructureCheck(ctx).isEmpty)
    }

    @Test("narrative sequence checks preserve causal beat order")
    func narrativeBeatOrder() throws {
        let shots = try [
            Self.shot(id: "s001", start: 0, end: 4, plan: Self.plan(beat: .reaction)),
            Self.shot(id: "s002", start: 4, end: 8, plan: Self.plan(beat: .action)),
            Self.shot(id: "s003", start: 8, end: 12, plan: Self.plan(beat: .establish)),
        ]
        let ctx = AuditContext(
            shotlist: try Self.shotlist(shots),
            productionProfileIDs: [.narrativeStorytelling]
        )
        let codes = Set(try narrativeStructureCheck(ctx).map(\.code))
        #expect(codes == ["NARRATIVE_CONTEXT_MISSING", "NARRATIVE_CONSEQUENCE_MISSING"])
    }

    @Test("a later consequence remains valid after an earlier detail")
    func consequenceAfterAction() throws {
        let shots = try [
            Self.shot(id: "s001", start: 0, end: 4, plan: Self.plan(beat: .establish)),
            Self.shot(id: "s002", start: 4, end: 8, plan: Self.plan(beat: .detail)),
            Self.shot(id: "s003", start: 8, end: 12, plan: Self.plan(beat: .action)),
            Self.shot(id: "s004", start: 12, end: 16, plan: Self.plan(beat: .reaction)),
        ]
        let ctx = AuditContext(
            shotlist: try Self.shotlist(shots),
            productionProfileIDs: [.narrativeStorytelling]
        )
        #expect(try narrativeStructureCheck(ctx).isEmpty)
    }

    @Test("narrative sequences surface a missing action beat")
    func narrativeActionRequired() throws {
        let shots = try [
            Self.shot(id: "s001", start: 0, end: 4, plan: Self.plan(beat: .establish)),
            Self.shot(id: "s002", start: 4, end: 8, plan: Self.plan(beat: .reaction)),
            Self.shot(id: "s003", start: 8, end: 12, plan: Self.plan(beat: .detail)),
        ]
        let ctx = AuditContext(
            shotlist: try Self.shotlist(shots),
            productionProfileIDs: [.narrativeStorytelling]
        )
        #expect(try narrativeStructureCheck(ctx).map(\.code) == ["NARRATIVE_ACTION_MISSING"])
    }

    @Test("imported footage does not exempt a planned narrative sequence")
    func importedShotDoesNotExemptPlannedSequence() throws {
        let shots = try [
            Self.shot(
                id: "s001", start: 0, end: 4, section: "scene",
                sourceMode: .imported
            ),
            Self.shot(id: "s002", start: 4, end: 8, plan: Self.plan(beat: .establish)),
            Self.shot(id: "s003", start: 8, end: 12, plan: Self.plan(beat: .reaction)),
            Self.shot(id: "s004", start: 12, end: 16, plan: Self.plan(beat: .detail)),
        ]
        let ctx = AuditContext(
            shotlist: try Self.shotlist(shots),
            productionProfileIDs: [.narrativeStorytelling]
        )
        #expect(try narrativeStructureCheck(ctx).map(\.code) == ["NARRATIVE_ACTION_MISSING"])
    }

    @Test("performance-only sections are not forced into a causal story shape")
    func performanceSection() throws {
        let shots = try [
            Self.shot(id: "s001", start: 0, end: 4, plan: Self.plan(beat: .performance)),
            Self.shot(id: "s002", start: 4, end: 8, plan: Self.plan(beat: .atmosphere)),
            Self.shot(id: "s003", start: 8, end: 12, plan: Self.plan(beat: .performance)),
        ]
        let ctx = AuditContext(
            shotlist: try Self.shotlist(shots),
            productionProfileIDs: [.narrativeStorytelling]
        )
        #expect(try narrativeStructureCheck(ctx).isEmpty)
    }

    @Test("narrative section findings have stable section order")
    func narrativeSectionOrder() throws {
        let beats: [NarrativeBeat] = [.establish, .reaction, .detail]
        var shots: [Shot] = []
        for (index, section) in ["beta", "beta", "beta", "alpha", "alpha", "alpha"].enumerated() {
            shots.append(try Self.shot(
                id: "s00\(index + 1)",
                start: Double(index * 4),
                end: Double((index + 1) * 4),
                plan: Self.plan(beat: beats[index % beats.count]),
                section: section
            ))
        }
        let ctx = AuditContext(
            shotlist: try Self.shotlist(shots),
            productionProfileIDs: [.narrativeStorytelling]
        )
        #expect(try narrativeStructureCheck(ctx).map(\.message) == [
            "Section alpha has no observable action beat.",
            "Section beta has no observable action beat.",
        ])
    }

    @Test("equal-time narrative beats use shot id as a deterministic tiebreak")
    func equalTimeBeatOrder() throws {
        let shots = try [
            Self.shot(
                id: "s001", start: 0, end: 8, plan: Self.plan(beat: .reaction),
                section: nil, cameraId: "cam01"
            ),
            Self.shot(
                id: "s002", start: 0, end: 8, plan: Self.plan(beat: .action),
                section: nil, cameraId: "cam02"
            ),
            Self.shot(
                id: "s003", start: 0, end: 8, plan: Self.plan(beat: .establish),
                section: nil, cameraId: "cam03"
            ),
        ]
        let shotlist = try Shotlist(
            schema_: shotlistSchemaVersion,
            mode: .multicam,
            project: "production-test",
            song: Song(
                title: "test",
                audioPath: "audio/test.wav",
                analysisPath: "analysis/test.json",
                bpm: 120,
                durationS: 8
            ),
            generated: "2026-08-08T00:00:00Z",
            generator: "test",
            shots: shots
        )
        let ctx = AuditContext(
            shotlist: shotlist,
            productionProfileIDs: [.narrativeStorytelling]
        )
        #expect(try narrativeStructureCheck(ctx).map(\.code) == [
            "NARRATIVE_CONTEXT_MISSING",
            "NARRATIVE_CONSEQUENCE_MISSING",
        ])
    }
}
