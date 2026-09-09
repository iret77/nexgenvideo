import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// references / REF_BUDGET (reference-planner). The planner filters by on-disk file
/// existence, so the fixture tests create real (empty) files in a temp project dir.
@Suite("references / REF_BUDGET")
struct ReferencePlannerTests {
    @Test("view scoring priority matches the reference")
    func scoring() {
        #expect(ReferencePlanner.scoreView("front", requested: "front") == 1.0)   // exact requested match wins
        #expect(ReferencePlanner.scoreView("floorplan", requested: nil) == 0.95)
        #expect(ReferencePlanner.scoreView("front", requested: nil) == 0.7)
        #expect(ReferencePlanner.scoreView("wide", requested: nil) == 0.65)
        #expect(ReferencePlanner.scoreView("lighting_anchor", requested: nil) == 0.55)
        #expect(ReferencePlanner.scoreView("side", requested: nil) == 0.4)
        #expect(ReferencePlanner.scoreView("back", requested: nil) == 0.4)
        #expect(ReferencePlanner.scoreView("expression_smile", requested: nil) == 0.35)
        #expect(ReferencePlanner.scoreView("", requested: nil) == 0.45)
        #expect(ReferencePlanner.scoreView("threequarter", requested: nil) == 0.5)
    }

    @Test("image-model reference caps")
    func caps() {
        #expect(ImageModelCaps.maxReferenceImages(.googleGemini3Pro) == 6)
        #expect(ImageModelCaps.maxReferenceImages(.openaiGptImage2) == 10)
        #expect(ImageModelCaps.maxReferenceImages(.runwayGen4Image) == 3)
        #expect(ImageModelCaps.maxReferenceImages(.falGptImage1) == 4)
        #expect(ImageModelCaps.maxReferenceImages(.googleImagen4Ultra) == nil)   // supports_refs == false → fallback
        #expect(ImageModelCaps.maxReferenceImages(.other) == nil)
    }

    /// A temp project dir populated with the given (empty) relative files.
    static func fixtureDir(_ relPaths: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refplan-" + UUID().uuidString)
        for rel in relPaths {
            let url = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return dir
    }

    @Test("planner keeps the highest-priority ref and drops the rest past the cap")
    func dropsOverCap() throws {
        // Valid Character sheet keys are front/side/back/expression_*. front (0.7) is
        // the unique top; with a cap of 1 the three lower-scored sheets are dropped.
        let sheets = ["front": "b/front.png", "side": "b/side.png",
                      "back": "b/back.png", "expression_smile": "b/smile.png"]
        let dir = try Self.fixtureDir(Array(sheets.values))
        defer { try? FileManager.default.removeItem(at: dir) }
        let char = try Character(id: "hero", name: "Hero", visualPrompt: "p", sheets: sheets)
        let bible = try Bible(project: "p", generated: "t", generator: "g", characters: [char])
        let plan = ReferencePlanner.planShotRefs(
            projectDir: dir, bible: bible, characterRefs: ["hero"], locationRef: nil, propRefs: [],
            characterViews: [:], locationView: nil, propViews: [:], maxRefs: 1)
        #expect(plan.refs.map(\.view) == ["front"])
        #expect(Set(plan.dropped.map(\.view)) == ["side", "back", "expression_smile"])
    }

    @Test("refs whose files don't exist are filtered out")
    func missingFilesFiltered() throws {
        let dir = try Self.fixtureDir(["b/front.png"])   // side.png intentionally absent
        defer { try? FileManager.default.removeItem(at: dir) }
        let char = try Character(id: "hero", name: "Hero", visualPrompt: "p",
                                 sheets: ["front": "b/front.png", "side": "b/side.png"])
        let bible = try Bible(project: "p", generated: "t", generator: "g", characters: [char])
        let plan = ReferencePlanner.planShotRefs(
            projectDir: dir, bible: bible, characterRefs: ["hero"], locationRef: nil, propRefs: [],
            characterViews: [:], locationView: nil, propViews: [:], maxRefs: 9)
        #expect(plan.refs.map(\.view) == ["front"])
        #expect(plan.dropped.isEmpty)
    }

    @Test("required semantic jobs are never discarded to fit the offering cap")
    func explicitReferencesArePlanned() throws {
        let dir = try Self.fixtureDir([
            "explicit/board.png",
            "b/front.png",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let character = try Character(
            id: "hero",
            name: "Hero",
            visualPrompt: "p",
            sheets: ["front": "b/front.png"]
        )
        let bible = try Bible(
            project: "p",
            generated: "t",
            generator: "g",
            characters: [character]
        )
        let plan = ReferencePlanner.planShotRefs(
            projectDir: dir,
            bible: bible,
            characterRefs: ["hero"],
            locationRef: nil,
            propRefs: [],
            characterViews: [:],
            locationView: nil,
            propViews: [:],
            referenceImageRefs: ["explicit/board.png"],
            maxRefs: 1
        )

        #expect(plan.refs.map(\.path) == ["explicit/board.png", "b/front.png"])
        #expect(plan.dropped.isEmpty)
        #expect(plan.deficits.contains {
            $0.requirementID == "offering:image-reference-capacity"
        })
    }

    static func briefWith(_ model: FrameImageModel) throws -> Brief {
        try Brief(project: "p", generated: "t", mission: .demo, targetPlatform: "web",
                  aspectRatio: .landscape16x9, projectMode: "beat", frameImageModel: model,
                  conceptType: .abstract, visualMedium: .liveActionRealistic, figures: .none, lyricsIntegration: .ignored)
    }

    static func shotlist(_ shot: Shot) throws -> Shotlist {
        try Shotlist(
            schema_: shotlistSchemaVersion, mode: .beat, project: "p",
            song: try Song(title: "t", audioPath: "audio/s.wav", analysisPath: "analysis/s.json",
                           bpm: 120, tempoMultiplier: 1, durationS: 180),
            generated: "t", generator: "g", shots: [shot])
    }

    @Test("optional alternate views may be dropped without violating the semantic budget")
    func refBudgetCheck() throws {
        let sheets = ["front": "b/front.png", "side": "b/side.png",
                      "back": "b/back.png", "expression_smile": "b/smile.png"]
        let dir = try Self.fixtureDir(Array(sheets.values))
        defer { try? FileManager.default.removeItem(at: dir) }
        let char = try Character(id: "hero", name: "Hero", visualPrompt: "p", sheets: sheets)
        let bible = try Bible(project: "p", generated: "t", generator: "g", characters: [char])
        let shot = try Shot(id: "s001", section: "verse", timeStart: 0, timeEnd: 4, durationS: 4,
                            type: .performance, description: "d", visualPrompt: "p", mood: "m",
                            characterRefs: ["hero"], keyframeStrategy: .start)
        let ctx = AuditContext(shotlist: try Self.shotlist(shot),
                               brief: try Self.briefWith(.runwayGen4Image),   // cap 3 → 4 sheets → 1 dropped
                               bible: bible, extra: ["data_root": dir.path])
        #expect(try MusicvideoChecks.referenceBudgetCheck(ctx).isEmpty)
    }

    @Test("no finding when refs fit under the cap")
    func underCapClean() throws {
        let dir = try Self.fixtureDir(["b/front.png"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let char = try Character(id: "hero", name: "Hero", visualPrompt: "p", sheets: ["front": "b/front.png"])
        let bible = try Bible(project: "p", generated: "t", generator: "g", characters: [char])
        let shot = try Shot(id: "s001", section: "verse", timeStart: 0, timeEnd: 4, durationS: 4,
                            type: .performance, description: "d", visualPrompt: "p", mood: "m",
                            characterRefs: ["hero"], keyframeStrategy: .start)
        let ctx = AuditContext(shotlist: try Self.shotlist(shot),
                               brief: try Self.briefWith(.googleGemini3Pro), bible: bible, extra: ["data_root": dir.path])
        #expect(try MusicvideoChecks.referenceBudgetCheck(ctx).isEmpty)
    }

    @Test("multiple identities location prop and lighting all remain required")
    func semanticCoverageIsRequired() throws {
        let files = [
            "characters/ari.png", "characters/bea.png", "locations/studio.png",
            "props/mic.png", "look/light.png",
        ]
        let dir = try Self.fixtureDir(files)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ari = try Character(
            id: "ari", name: "Ari", visualPrompt: "p",
            sheets: ["front": "characters/ari.png"]
        )
        let bea = try Character(
            id: "bea", name: "Bea", visualPrompt: "p",
            sheets: ["front": "characters/bea.png"]
        )
        let location = try Location(
            id: "studio", name: "Studio", visualPrompt: "p",
            sheets: ["wide": "locations/studio.png"]
        )
        let prop = try Prop(
            id: "mic", name: "Mic", visualPrompt: "p",
            sheets: ["front": "props/mic.png"]
        )
        let bible = try Bible(
            project: "p", generated: "t", generator: "g",
            characters: [ari, bea], props: [prop], locations: [location],
            look: LookGuide(style: "film", lightingAnchor: "look/light.png")
        )
        let plan = ReferencePlanner.planShotRefs(
            projectDir: dir,
            bible: bible,
            characterRefs: ["ari", "bea"],
            locationRef: "studio",
            propRefs: ["mic"],
            characterViews: [:],
            locationView: nil,
            propViews: [:],
            maxRefs: 4
        )

        #expect(plan.refs.count == 5)
        #expect(plan.refs.allSatisfy { $0.isRequired })
        #expect(Set(plan.refs.flatMap(\.requirementIDs)) == Set([
            "character:ari", "character:bea", "location:studio", "prop:mic",
            "lighting:look",
        ]))
        #expect(plan.deficits.contains {
            $0.requirementID == "offering:image-reference-capacity"
        })

        let ctx = AuditContext(
            shotlist: try Self.shotlist(try Shot(
                id: "s001", section: "verse", timeStart: 0, timeEnd: 4,
                durationS: 4, type: .performance, description: "d",
                visualPrompt: "p", mood: "m", characterRefs: ["ari", "bea"],
                locationRef: "studio", propRefs: ["mic"],
                keyframeStrategy: .start
            )),
            brief: try Self.briefWith(.runwayGen4Image),
            bible: bible,
            extra: ["data_root": dir.path]
        )
        #expect(try MusicvideoChecks.referenceBudgetCheck(ctx).contains {
            $0.level == .error
                && $0.code == "REF_BUDGET_EXCEEDED"
                && $0.shotId == "s001"
        })
    }
}
