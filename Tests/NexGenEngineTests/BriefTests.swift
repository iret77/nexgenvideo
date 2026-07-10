import Foundation
import Testing
@testable import NexGenEngine

@Suite("Brief")
struct BriefTests {
    /// A minimal valid Brief: `.liveActionRealistic` is the one VisualMedium
    /// that does not require `visualMediumNotes`.
    static func minimalBrief() throws -> Brief {
        try Brief(
            project: "basic-project",
            generated: "2026-01-01",
            mission: .demo,
            targetPlatform: "web",
            aspectRatio: .landscape16x9,
            projectMode: "beat",
            conceptType: .abstract,
            visualMedium: .liveActionRealistic,
            figures: .none,
            lyricsIntegration: .ignored
        )
    }

    @Test("YAML round-trip preserves equality")
    func yamlRoundTrip() throws {
        let brief = try Self.minimalBrief()
        let yaml = try YAMLCoding.encode(brief)
        let decoded = try YAMLCoding.decode(Brief.self, from: yaml)
        #expect(decoded == brief)
    }

    @Test("decodes a hand-written minimal YAML document")
    func decodesHandWrittenYAML() throws {
        let yaml = """
        project: hand-written
        generated: '2026-02-01'
        mission: single_release
        target_platform: youtube
        aspect_ratio: '9:16'
        project_mode: phrase
        concept_type: narrative
        visual_medium: live_action_realistic
        figures: artist_only
        lyrics_integration: literal
        """
        let brief = try YAMLCoding.decode(Brief.self, from: yaml)
        #expect(brief.schema == briefSchemaVersion)
        #expect(brief.project == "hand-written")
        #expect(brief.mission == .singleRelease)
        #expect(brief.aspectRatio == .vertical9x16)
        #expect(brief.projectMode == "phrase")
        #expect(brief.conceptType == .narrative)
        #expect(brief.visualMedium == .liveActionRealistic)
        #expect(brief.figures == .artistOnly)
        #expect(brief.lyricsIntegration == .literal)
        // Defaults applied when absent from the YAML.
        #expect(brief.generator == "brief-agent@v0.3")
        #expect(brief.modelPreference == .seedance2)
        #expect(brief.frameImageModel == .googleGemini3Pro)
        #expect(brief.budgetEur == 50.0)
        #expect(brief.stemsProvider == .demucs)
        #expect(brief.finalResolution == .res1080p)
        #expect(brief.previewMode == .skip)
        #expect(brief.cutHandlesMode == .withOverlap)
    }

    @Test("visual_medium_notes validator: live_action_realistic needs no notes")
    func liveActionRealisticNeedsNoNotes() throws {
        let brief = try Self.minimalBrief()
        #expect(brief.visualMedium == .liveActionRealistic)
        #expect(brief.visualMediumNotes == nil)
    }

    @Test("visual_medium_notes validator: stylized medium without notes throws")
    func stylizedMediumWithoutNotesThrows() throws {
        #expect(throws: Brief.ValidationError.self) {
            _ = try Brief(
                project: "basic-project",
                generated: "2026-01-01",
                mission: .demo,
                targetPlatform: "web",
                aspectRatio: .landscape16x9,
                projectMode: "beat",
                conceptType: .abstract,
                visualMedium: .cg3d,
                figures: .none,
                lyricsIntegration: .ignored
            )
        }
        do {
            _ = try Brief(
                project: "basic-project", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
                aspectRatio: .landscape16x9, projectMode: "beat", conceptType: .abstract, visualMedium: .cg3d,
                figures: .none, lyricsIntegration: .ignored
            )
            Issue.record("expected visualMediumNotesRequired to be thrown")
        } catch let error as Brief.ValidationError {
            #expect(error == .visualMediumNotesRequired(.cg3d))
        }
    }

    @Test("visual_medium_notes validator: empty/whitespace notes also throw")
    func blankNotesAlsoThrow() throws {
        #expect(throws: Brief.ValidationError.self) {
            _ = try Brief(
                project: "basic-project",
                generated: "2026-01-01",
                mission: .demo,
                targetPlatform: "web",
                aspectRatio: .landscape16x9,
                projectMode: "beat",
                conceptType: .abstract,
                visualMedium: .cg3d,
                visualMediumNotes: "   ",
                figures: .none,
                lyricsIntegration: .ignored
            )
        }
    }

    @Test("visual_medium_notes validator: stylized medium with notes decodes fine")
    func stylizedMediumWithNotesSucceeds() throws {
        let brief = try Brief(
            project: "basic-project",
            generated: "2026-01-01",
            mission: .demo,
            targetPlatform: "web",
            aspectRatio: .landscape16x9,
            projectMode: "beat",
            conceptType: .abstract,
            visualMedium: .cg3d,
            visualMediumNotes: "wie Pixar Arcane",
            figures: .none,
            lyricsIntegration: .ignored
        )
        #expect(brief.visualMedium == .cg3d)
        #expect(brief.visualMediumNotes == "wie Pixar Arcane")
    }

    @Test("decoding YAML with a stylized medium and no notes throws")
    func decodingStylizedWithoutNotesThrows() throws {
        let yaml = """
        project: bad-brief
        generated: '2026-01-01'
        mission: demo
        target_platform: web
        aspect_ratio: '16:9'
        project_mode: beat
        concept_type: abstract
        visual_medium: 3d_cg
        figures: none
        lyrics_integration: ignored
        """
        // Wrapped by Yams into DecodingError.dataCorrupted (underlying: ValidationError).
        #expect(throws: (any Error).self) {
            _ = try YAMLCoding.decode(Brief.self, from: yaml)
        }
    }

    @Test("parity: fixture brief.yaml matches the golden's key fields")
    func fixtureParityWithGolden() throws {
        let fixtureHome = try DataRootResolverTests.fixtureHome()
        let url = fixtureHome
            .appendingPathComponent("pipeline")
            .appendingPathComponent("brief.yaml")
        let brief = try YAMLCoding.decode(Brief.self, from: url)

        #expect(brief.project == "basic-project")
        #expect(brief.schema == "brief/v1")
        #expect(brief.mission == .demo)
        #expect(brief.aspectRatio == .landscape16x9)
        #expect(brief.visualMedium == .liveActionRealistic)
        #expect(brief.conceptType == .abstract)
        #expect(brief.figures == .none)
        #expect(brief.lyricsIntegration == .ignored)
        #expect(brief.stemsProvider == .demucs)
        #expect(brief.finalResolution == .res1080p)
        #expect(brief.previewMode == .skip)
        #expect(brief.cutHandlesMode == .withOverlap)

        // Additional fields present in both the fixture YAML and the golden JSON.
        #expect(brief.generated == "2026-01-01")
        #expect(brief.generator == "brief-agent@v0.3")
        #expect(brief.targetPlatform == "web")
        #expect(brief.lengthMode == "full_song")
        #expect(brief.projectMode == "beat")
        #expect(brief.modelPreference == .seedance2)
        #expect(brief.frameImageModel == .googleGemini3Pro)
        #expect(brief.budgetEur == 50.0)
        #expect(brief.tone == [])
        #expect(brief.styleReferences == [])
        #expect(brief.enableChordAnalysis == false)
        #expect(brief.allowGenreCrossPatterns == false)
        #expect(brief.allowTextOverlays == false)
        #expect(brief.visualMediumNotes == nil)
        #expect(brief.notes == nil)
        #expect(brief.directorPattern == nil)
        #expect(brief.bibleImageModel == nil)
        #expect(brief.compositeImageModel == nil)
    }
}
