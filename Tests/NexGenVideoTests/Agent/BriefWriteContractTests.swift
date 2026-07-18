import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

/// #247 — the `write_brief` tool wraps the engine `Brief` type. These guard the two invariants that
/// make the tool a single source of truth: (1) the agent-facing field set stays exactly the `Brief`
/// wire keys minus the server-owned ones (drift guard), and (2) every enum field's schema options are
/// literally `EnumType.allCases.map(\.rawValue)`. Plus a round-trip through the executor.
@MainActor
@Suite("write_brief contract")
struct BriefWriteContractTests {

    private let serverOwned: Set<String> = ["schema", "project", "generated", "generator"]

    /// A `Brief` with EVERY optional field populated, so the synthesized encoder emits all wire keys
    /// (nil optionals are omitted). If a field is added to `Brief` without a matching contract entry,
    /// the drift test below sees an extra encoded key and fails.
    private func fullyPopulated() throws -> Brief {
        try Brief(
            schema: briefSchemaVersion, project: "p", generated: "g", generator: "gen",
            mission: .singleRelease, missionOther: "x", targetPlatform: "YouTube", targetAudience: "fans",
            aspectRatio: .landscape16x9, aspectRatioOther: "x", lengthMode: "full_song",
            projectMode: "section", modelPreference: .seedance2, modelPreferenceOther: "x",
            frameImageModel: .googleGemini3Pro, frameImageModelOther: "x",
            bibleImageModel: .falNanoBanana, compositeImageModel: .runwayGen4Image,
            budgetEur: 50, budgetStopEur: 100,
            conceptType: .narrative, conceptTypeOther: "x",
            visualMedium: .liveActionStylized, visualMediumOther: "x", visualMediumNotes: "gritty grade",
            tone: [.dark, .poetic], toneOther: "x", styleReferences: ["ref"],
            figures: .artistOnly, figuresOther: "x", figureCountHint: "1",
            lyricsIntegration: .literal, lyricsIntegrationOther: "x",
            enableChordAnalysis: true, stemsProvider: .demucs, finalResolution: .res720p,
            previewMode: .smallest, cutHandlesMode: .backToBack, directorPattern: "pat",
            allowGenreCrossPatterns: true, allowTextOverlays: true, notes: "n")
    }

    @Test("drift guard: encoded Brief wire keys minus server-owned equal the contract's agent-facing keys")
    func driftGuard() throws {
        let data = try JSONEncoder().encode(try fullyPopulated())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wireKeys = Set(object.keys)
        let agentFacing = Set(BriefWriteContract.fields.map(\.key))
        #expect(wireKeys.subtracting(serverOwned) == agentFacing)
        // The server-owned fields must NOT appear in the agent-facing contract.
        #expect(agentFacing.isDisjoint(with: serverOwned))
    }

    @Test("every enum field's schema options equal EnumType.allCases.map(\\.rawValue)")
    func enumOptionsFromAllCases() throws {
        let expected: [String: [String]] = [
            "mission": Mission.allCases.map(\.rawValue),
            "aspect_ratio": AspectRatio.allCases.map(\.rawValue),
            "model_preference": ModelPreference.allCases.map(\.rawValue),
            "frame_image_model": FrameImageModel.allCases.map(\.rawValue),
            "bible_image_model": FrameImageModel.allCases.map(\.rawValue),
            "composite_image_model": FrameImageModel.allCases.map(\.rawValue),
            "concept_type": ConceptType.allCases.map(\.rawValue),
            "visual_medium": VisualMedium.allCases.map(\.rawValue),
            "figures": FigurePresence.allCases.map(\.rawValue),
            "lyrics_integration": LyricsIntegration.allCases.map(\.rawValue),
            "stems_provider": StemsProvider.allCases.map(\.rawValue),
            "final_resolution": VideoResolution.allCases.map(\.rawValue),
            "preview_mode": PreviewMode.allCases.map(\.rawValue),
            "cut_handles_mode": CutHandlesMode.allCases.map(\.rawValue),
            "tone": ToneTag.allCases.map(\.rawValue),
            // Derived independently here: every real Mode EXCEPT the two the brief may not carry.
            // A new Mode case appears automatically on both sides — that is intended.
            "project_mode": Mode.allCases.map(\.rawValue).filter { $0 != "phrase" && $0 != "generic" },
        ]
        // Every enum/enum-array field in the contract must be covered here, and match exactly.
        for field in BriefWriteContract.fields {
            guard let options = field.enumOptions else { continue }
            let want = try #require(expected[field.key])
            if options != want {
                Issue.record("field \(field.key) options \(options) != allCases \(want)")
            }
        }
        // No enum field slipped past the expected map.
        let enumKeys = Set(BriefWriteContract.fields.filter { $0.enumOptions != nil }.map(\.key))
        #expect(enumKeys == Set(expected.keys))
    }

    // MARK: - Executor round-trip

    private func scaffold() throws -> (ToolHarness, URL, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("write-brief-\(UUID().uuidString)", isDirectory: true)
        let home = tmp.appendingPathComponent("proj", isDirectory: true)
        let dataRoot = try ProjectScaffold.initProject(home: home, name: "demo", mode: .beat)
        return (ToolHarness(), dataRoot, tmp)
    }

    private func validArgs(dataRoot: URL) -> [String: Any] {
        [
            "project_dir": dataRoot.path,
            "mission": "single_release", "target_platform": "YouTube", "aspect_ratio": "16:9",
            "project_mode": "section", "concept_type": "narrative",
            "visual_medium": "live_action_realistic", "figures": "artist_only",
            "lyrics_integration": "literal",
        ]
    }

    @Test("a valid payload passes through the executor and reloads as a valid Brief")
    func validRoundTrip() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }

        let res = try await h.runOK("write_brief", args: validArgs(dataRoot: dataRoot)) as? [String: Any]
        #expect(res?["written"] as? Bool == true)
        #expect(res?["project"] as? String == "demo")

        let brief = try YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
        #expect(brief.mission == .singleRelease)
        #expect(brief.visualMedium == .liveActionRealistic)
        #expect(brief.project == "demo")
        #expect(brief.schema == briefSchemaVersion)
        #expect(brief.generator == "brief-agent@write_brief")
    }

    @Test("an invalid enum value is rejected and names the field")
    func invalidEnumRejected() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        var args = validArgs(dataRoot: dataRoot)
        args["visual_medium"] = "hologram"

        let raw = await h.runRaw("write_brief", args: args)
        #expect(raw.isError)
        let text = ToolHarness.textOf(raw)
        #expect(text.contains("visual_medium"))
        #expect(text.contains("hologram"))
    }

    @Test("a missing required field is rejected and names the field")
    func missingRequiredRejected() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        var args = validArgs(dataRoot: dataRoot)
        args.removeValue(forKey: "mission")

        let raw = await h.runRaw("write_brief", args: args)
        #expect(raw.isError)
        #expect(ToolHarness.textOf(raw).contains("mission"))
    }

    @Test("visual_medium_notes required for a stylized medium — validation error names it")
    func stylizedMediumNeedsNotes() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        var args = validArgs(dataRoot: dataRoot)
        args["visual_medium"] = "2d_animation"  // no visual_medium_notes

        let raw = await h.runRaw("write_brief", args: args)
        #expect(raw.isError)
        #expect(ToolHarness.textOf(raw).contains("visual_medium_notes"))
    }

    @Test("a deferred cut mode is rejected — project_mode is constrained, not free text")
    func deferredProjectModeRejected() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        // `phrase` needs forced alignment the analysis can't produce; the pack docs tell the agent to
        // fall back from it. Before it was constrained, this wrote a brief no phase could execute.
        var args = validArgs(dataRoot: dataRoot)
        args["project_mode"] = "phrase"

        let raw = await h.runRaw("write_brief", args: args)
        #expect(raw.isError)
        #expect(ToolHarness.textOf(raw).contains("project_mode"))
        // …and a plain typo dies the same way.
        var typo = validArgs(dataRoot: dataRoot)
        typo["project_mode"] = "sektion"
        #expect(await h.runRaw("write_brief", args: typo).isError)
    }

    @Test("a server-owned field supplied by the agent is rejected as an unknown key")
    func serverOwnedFieldRejected() async throws {
        let (h, dataRoot, cleanup) = try scaffold()
        defer { try? FileManager.default.removeItem(at: cleanup) }
        var args = validArgs(dataRoot: dataRoot)
        args["generator"] = "agent-tried-to-set-this"

        let raw = await h.runRaw("write_brief", args: args)
        #expect(raw.isError)
        #expect(ToolHarness.textOf(raw).contains("generator"))
    }
}
