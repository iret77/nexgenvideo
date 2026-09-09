import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Production style prompt consumers")
struct ProductionStylePromptTests {
    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("style-prompt-\(UUID().uuidString)")
        let root = try ProjectScaffold.initProject(home: home, name: "style-test")
        try Data("approved brief bytes".utf8).write(to: root.appendingPathComponent(PipelineLayout.briefFile))
        let design = try ProductionDesign(project: "style-test", generated: "2026-09-08", generator: "test",
                                         visualMedium: .liveActionRealistic, colorScript: ["opening": "amber"])
        let selection = ProductionStyleSelectionV1(
            directorID: "director-wes-anderson-symmetry-deadpan", signatureID: "dop-vittorio-storaro",
            signatureDimensions: [.color], overrides: [
                .init(dimension: .color, value: "Cobalt shadows and amber highlights.",
                      reason: "Use the selected act palette.", sourceEntryID: "dop-vittorio-storaro", verification: .init(scope: .frame, evidenceKind: .image,
                        criterion: "Cobalt shadows and amber highlights.")),
            ]
        )
        try ProductionStyleStoreV1.write(design: design, selection: selection, clearStyle: false, dataRoot: root)
        return home
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
