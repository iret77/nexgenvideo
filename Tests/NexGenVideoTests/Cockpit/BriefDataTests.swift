import Foundation
import Testing

@testable import NexGenVideo
import NexGenEngine

/// The brief is the artifact the user is asked to approve, so the app's read-model has to mirror the
/// engine `Brief` completely — an earlier version decoded ~11 of 42 fields and the rest were simply
/// invisible. The payload here is the real wire shape: an engine `Brief`, JSON-encoded exactly as
/// `NativeCockpitReader.briefJSON` does it.
@Suite("BriefData — full brief")
struct BriefDataTests {

    /// Every optional set, so a dropped field shows up as a nil instead of hiding behind a default.
    private func fullBrief() throws -> Brief {
        try Brief(
            project: "demo", generated: "2026-01-01", mission: .other, missionOther: "gallery loop",
            targetPlatform: "Vimeo", targetAudience: "festival programmers",
            aspectRatio: .other, aspectRatioOther: "2.39:1", lengthMode: "excerpt",
            projectMode: "beat", modelPreference: .other, modelPreferenceOther: "in-house model",
            frameImageModel: .other, frameImageModelOther: "in-house stills",
            bibleImageModel: .googleGemini3Pro, compositeImageModel: .falFluxPro11,
            budgetEur: 120, budgetStopEur: 150,
            conceptType: .other, conceptTypeOther: "essay film",
            visualMedium: .other, visualMediumOther: "collage",
            visualMediumNotes: "Paper cut-outs over 16mm plates",
            tone: [.melancholic, .poetic], toneOther: "wistful",
            styleReferences: ["Chris Marker", "Sans Soleil"],
            figures: .other, figuresOther: "a crowd, never in focus", figureCountHint: "6-8",
            lyricsIntegration: .other, lyricsIntegrationOther: "fragments as intertitles",
            enableChordAnalysis: true, stemsProvider: .lalal,
            finalResolution: .res720p, previewMode: .smallest, cutHandlesMode: .backToBack,
            directorPattern: "essayistic-drift",
            allowGenreCrossPatterns: true, allowTextOverlays: true,
            notes: "Keep the grain."
        )
    }

    private func encoded(_ brief: Brief) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(brief)
    }

    private func decode(_ data: Data) throws -> BriefData {
        try JSONDecoder().decode(BriefData.self, from: data)
    }

    @Test("a full brief round-trips into every BriefData field")
    func fullBriefDecodes() throws {
        let data = try decode(try encoded(try fullBrief()))

        #expect(data.project == "demo")
        #expect(data.generated == "2026-01-01")
        #expect(data.schema == briefSchemaVersion)

        #expect(data.mission == "other")
        #expect(data.missionOther == "gallery loop")
        #expect(data.targetPlatform == "Vimeo")
        #expect(data.targetAudience == "festival programmers")

        #expect(data.aspectRatio == "other")
        #expect(data.aspectRatioOther == "2.39:1")
        #expect(data.lengthMode == "excerpt")

        #expect(data.projectMode == "beat")
        #expect(data.conceptType == "other")
        #expect(data.conceptTypeOther == "essay film")
        #expect(data.visualMedium == "other")
        #expect(data.visualMediumOther == "collage")
        #expect(data.visualMediumNotes == "Paper cut-outs over 16mm plates")

        #expect(data.tone == ["melancholic", "poetic"])
        #expect(data.toneOther == "wistful")
        #expect(data.styleReferences == ["Chris Marker", "Sans Soleil"])

        #expect(data.figures == "other")
        #expect(data.figuresOther == "a crowd, never in focus")
        #expect(data.figureCountHint == "6-8")
        #expect(data.lyricsIntegration == "other")
        #expect(data.lyricsIntegrationOther == "fragments as intertitles")
        #expect(data.notes == "Keep the grain.")
    }

    /// The fields the old read-model dropped on the floor. Each one is a decision the pipeline acts
    /// on, so each one has to survive the trip.
    @Test("the previously dropped fields all arrive")
    func previouslyDroppedFieldsArrive() throws {
        let data = try decode(try encoded(try fullBrief()))

        #expect(data.budgetEur == 120)
        #expect(data.budgetStopEur == 150)
        #expect(data.stemsProvider == "lalal")
        #expect(data.finalResolution == "720p")
        #expect(data.previewMode == "smallest")
        #expect(data.cutHandlesMode == "back_to_back")
        #expect(data.allowTextOverlays == true)
        #expect(data.allowGenreCrossPatterns == true)
        #expect(data.enableChordAnalysis == true)
        #expect(data.directorPattern == "essayistic-drift")
        #expect(data.modelPreference == "other")
        #expect(data.modelPreferenceOther == "in-house model")
        #expect(data.frameImageModel == "other")
        #expect(data.frameImageModelOther == "in-house stills")
        #expect(data.bibleImageModel == "google:gemini-3-pro-image-preview")
        #expect(data.compositeImageModel == "fal:fal-ai/flux-pro/v1.1")
    }

    /// The encoder omits nil optionals, so a minimal brief carries only the required keys. Absent
    /// must read as "not set", never as a decode failure.
    @Test("a sparse brief decodes; unset optionals stay nil")
    func sparseBriefDecodes() throws {
        let brief = try Brief(
            project: "demo", generated: "2026-01-01", mission: .demo, targetPlatform: "web",
            aspectRatio: .landscape16x9, projectMode: "section",
            conceptType: .abstract, visualMedium: .liveActionRealistic,
            figures: .none, lyricsIntegration: .ignored)
        let data = try decode(try encoded(brief))

        #expect(data.project == "demo")
        #expect(data.mission == "demo")
        #expect(data.visualMedium == "live_action_realistic")
        #expect(data.budgetStopEur == nil)
        #expect(data.directorPattern == nil)
        #expect(data.targetAudience == nil)
        #expect(data.missionOther == nil)
        #expect(data.visualMediumNotes == nil)
        #expect(data.notes == nil)
        #expect(data.tone.isEmpty)
        #expect(data.styleReferences.isEmpty)
    }

    /// Hand-written minimum: the app must not require keys the engine only happens to emit.
    @Test("a payload with only the required keys decodes")
    func requiredKeysOnlyDecodes() throws {
        let json = #"{"project":"demo","mission":"demo","visual_medium":"live_action_realistic"}"#
        let data = try decode(Data(json.utf8))

        #expect(data.project == "demo")
        #expect(data.mission == "demo")
        #expect(data.targetPlatform.isEmpty)
        #expect(data.budgetEur == 0)
        #expect(data.finalResolution == nil)
        #expect(data.enableChordAnalysis == nil)
    }

    /// A newer engine may add fields; that must not blank the panel for an older app.
    @Test("an unknown key is ignored")
    func unknownKeyIgnored() throws {
        var object = try JSONSerialization.jsonObject(
            with: try encoded(try fullBrief())) as? [String: Any] ?? [:]
        object["future_field"] = ["nested": true]
        let data = try decode(try JSONSerialization.data(withJSONObject: object))

        #expect(data.project == "demo")
        #expect(data.cutHandlesMode == "back_to_back")
    }

    /// A wrong-typed value costs that one field, not the whole brief — the panel is the only place
    /// the user can read what they are approving.
    @Test("a wrong-typed field reads as unset instead of failing the whole brief")
    func wrongTypedFieldDegrades() throws {
        var object = try JSONSerialization.jsonObject(
            with: try encoded(try fullBrief())) as? [String: Any] ?? [:]
        object["director_pattern"] = 42
        object["allow_text_overlays"] = "yes"
        let data = try decode(try JSONSerialization.data(withJSONObject: object))

        #expect(data.directorPattern == nil)
        #expect(data.allowTextOverlays == nil)
        #expect(data.project == "demo")
        #expect(data.budgetStopEur == 150)
    }

    @Test("a corrupt CORE field still fails the read, so the unreadable banner fires")
    func corruptCoreFieldFails() throws {
        // Tolerance stops at the fields that make a brief a brief. `briefUnreadable` is set only when
        // this decode THROWS, and that banner is the difference between "the brief says almost
        // nothing" and "this brief can't be read" — a legacy schema must never render as the former.
        for key in ["project", "mission", "aspect_ratio", "project_mode", "visual_medium"] {
            var object = try JSONSerialization.jsonObject(
                with: try encoded(try fullBrief())) as? [String: Any] ?? [:]
            object[key] = 42  // wrong type, not merely absent
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) { try self.decode(data) }
        }
    }

    @Test("an ABSENT core field is not a failure — that's a sparse brief, not a broken one")
    func absentCoreFieldIsTolerated() throws {
        var object = try JSONSerialization.jsonObject(
            with: try encoded(try fullBrief())) as? [String: Any] ?? [:]
        object.removeValue(forKey: "target_audience")
        object.removeValue(forKey: "length_mode")
        let data = try decode(try JSONSerialization.data(withJSONObject: object))
        #expect(data.lengthMode == "")
        #expect(data.targetAudience == nil)
    }
}
