import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo
@testable import MusicvideoPlugin

@Suite("Production style prompt consumers")
@MainActor
struct ProductionStylePromptTests {
    private func fixture(color: String = "Cobalt shadows and amber highlights.", pattern: String? = nil) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("style-prompt-\(UUID().uuidString)")
        let root = try ProjectScaffold.initProject(home: home, name: "style-test")
        let brief = try Brief(project: "style-test", generated: "2026-10-17", mission: .demo,
            targetPlatform: "web", aspectRatio: .landscape16x9, projectMode: "beat",
            conceptType: .abstract, visualMedium: .liveActionRealistic,
            figures: .none, lyricsIntegration: .ignored, directorPattern: pattern)
        try YAMLArtifactStore(dataRoot: root).save(brief, to: PipelineLayout.briefFile)
        if pattern != nil { try activatePatternLibrary(home: home) }
        let design = try ProductionDesign(project: "style-test", generated: "2026-09-08", generator: "test",
                                         visualMedium: .liveActionRealistic, colorScript: ["opening": "amber"])
        let selection = ProductionStyleSelectionV1(
            directorID: "director-wes-anderson-symmetry-deadpan", signatureID: "dop-vittorio-storaro",
            signatureDimensions: [.color], overrides: [
                .init(dimension: .color, value: color,
                      reason: "Use the selected act palette.", sourceEntryID: "dop-vittorio-storaro", verification: .init(scope: .frame, evidenceKind: .image,
                        criterion: color)),
            ]
        )
        try ProductionStyleStoreV1.write(design: design, selection: selection, clearStyle: false, dataRoot: root)
        return home
    }

    private func activatePatternLibrary(home: URL) throws {
        try Fixtures.prepareProjectPackage(at: home)
        let pack = MusicvideoPack()
        PackCatalog.register(pack)
        let binding = try #require(ProjectPackBinding(id: pack.name, version: pack.version, projectSchema: "musicvideo/2.0.0"))
        try ProjectPluginSettings.setActivePlugin(binding, projectURL: home)
    }

    @Test func approvedBlueSkyNeverInheritsThePatternsSkyNegation() async throws {
        let home = try fixture(color: "Blue sky in clear midday light.", pattern: "cartoon-adult-swim-tartakovsky")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try #require(DataRootResolver.dataRoot(of: home))
        try YAMLArtifactStore(dataRoot: root).save(
            Gates(project: "style-test", gates: ["production_design": Gate(approved: true)]), to: PipelineLayout.gatesFile)
        for (modality, model) in [(PromptComposer.Modality.image, "fal-ai/flux-pro"), (.video, "fal/seedance-2.0")] {
            let composition = try await PromptComposer.compose(intent: "A quiet street with a traveler standing beside a stone wall",
                modality: modality, modelId: model, projectDir: home)
            #expect(composition.text.localizedCaseInsensitiveContains("blue sky"))
            #expect(!composition.text.localizedCaseInsensitiveContains("no blue sky"))
        }
    }

    @Test func everyBundledPatternRemainsOrientationRatherThanPromptText() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pattern-prompt-\(UUID().uuidString)")
        let root = try ProjectScaffold.initProject(home: home, name: "style-test")
        defer { try? FileManager.default.removeItem(at: home) }
        try activatePatternLibrary(home: home)
        let patterns = try Patterns.loadAllPatterns()
        #expect(!patterns.isEmpty)
        for pattern in patterns {
            let brief = try Brief(project: "style-test", generated: "2026-10-17", mission: .demo,
                targetPlatform: "web", aspectRatio: .landscape16x9, projectMode: "beat",
                conceptType: .abstract, visualMedium: .liveActionRealistic,
                figures: .none, lyricsIntegration: .ignored, directorPattern: pattern.id)
            try YAMLArtifactStore(dataRoot: root).save(brief, to: PipelineLayout.briefFile)
            for (modality, model) in [(PromptComposer.Modality.image, "fal-ai/flux-pro"), (.video, "fal/seedance-2.0")] {
                let composition = try await PromptComposer.compose(intent: "A quiet street under soft daylight with a traveler beside a stone wall",
                    modality: modality, modelId: model, projectDir: home)
                let libraryText = [pattern.lighting.description, pattern.color.description] + pattern.craftSignature.map(\.directive)
                for text in libraryText where !text.isEmpty {
                    #expect(!composition.text.localizedCaseInsensitiveContains(text), "Raw pattern prose from \(pattern.id) reached the prompt")
                }
            }
        }
    }

    @Test func explicitContradictionsBetweenLedgerAndApprovedStyleBlockComposition() async throws {
        let home = try fixture(color: "Blue sky in clear midday light.")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try #require(DataRootResolver.dataRoot(of: home))
        let store = YAMLArtifactStore(dataRoot: root)
        try store.save(Gates(project: "style-test", gates: ["production_design": Gate(approved: true)]), to: PipelineLayout.gatesFile)
        try store.save(Ledger(objects: ["look": ["sky": Attribute(tag: "sky", directive: "No blue sky.", locked: true)]]), to: PipelineLayout.ledgerFile)
        for (modality, model) in [(PromptComposer.Modality.image, "fal-ai/flux-pro"), (.video, "fal/seedance-2.0")] {
            do {
                _ = try await PromptComposer.compose(intent: "A traveler stands beside a quiet street in midday light",
                    modality: modality, modelId: model, projectDir: home)
                Issue.record("Contradictory directives reached a model-ready prompt")
            } catch PromptComposer.ComposeError.lintBlocked(let code, _) {
                #expect(code == "CONTRADICTORY_DIRECTIVES")
            }
        }
    }

    @Test func contradictionCheckDoesNotTreatUnrelatedNegativesAsAConflict() {
        #expect(PromptDirectiveConflict.first(in: ["Blue sky above the street.", "No blue sky."]) == "blue sky")
        #expect(PromptDirectiveConflict.first(in: ["No blue sky.", "Without blue sky."]) == nil)
        #expect(PromptDirectiveConflict.first(in: ["Warm daylight and blue sky.", "No text."]) == nil)
        #expect(PromptDirectiveConflict.first(in: ["A textured stone wall.", "No text."]) == nil)
    }

    @Test("draft still previews use the chosen palette but cannot approve production video")
    func approvalBoundary() async throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let still = try await PromptComposer.compose(intent: "A solitary traveler at a quiet station",
            modality: .image, modelId: "fal-ai/flux-pro", projectDir: home)
        #expect(still.text.contains("Cobalt shadows and amber highlights"))
        #expect(still.notes.contains { $0.contains("does not approve") })
        await #expect(throws: (any Error).self) {
            try await PromptComposer.compose(intent: "A solitary traveler walks along a station platform",
                modality: .video, modelId: "fal/seedance-2.0", projectDir: home)
        }
    }

    @Test("an unrelated sound request does not consume a broken visual style")
    func audioIndependence() async throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try #require(DataRootResolver.dataRoot(of: home))
        try Data("broken style".utf8).write(to: root.appendingPathComponent(ResolvedProductionStyleV1.relativePath))
        let audio = try await PromptComposer.compose(intent: "Steady rain falling on a metal station roof",
            modality: .audio, modelId: "elevenlabs/sound-effects", projectDir: home)
        #expect(!audio.text.isEmpty)
        #expect(!audio.text.contains("Cobalt"))
    }
    @Test("conflicting free styles are rejected instead of silently overwritten")
    func conflictIsExplicit() async throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        await #expect(throws: (any Error).self) {
            try await PromptComposer.compose(intent: "A traveler at a quiet station", modality: .image,
                modelId: "fal-ai/flux-pro", projectDir: home, style: "Monochrome green night vision")
        }
        let root = try #require(DataRootResolver.dataRoot(of: home))
        try Data("changed upstream brief".utf8).write(to: root.appendingPathComponent(PipelineLayout.briefFile))
        let context = try #require(try ProductionStyleContext.prompt(
            dataRoot: root,
            phase: "render"
        ))
        #expect(context.contains("Read-only diagnosis remains available"))
        #expect(context.contains("explicit rewind"))
        await #expect(throws: (any Error).self) {
            try await PromptComposer.compose(intent: "A traveler at a quiet station", modality: .image,
                modelId: "fal-ai/flux-pro", projectDir: home)
        }
    }

}
