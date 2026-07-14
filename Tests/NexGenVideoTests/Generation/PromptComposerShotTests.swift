import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

/// PromptComposer per-shot compile: deterministic camera/framing projection + compliance drift linter
/// on the running compile path (#197). Ports the camera/composition projection of
/// `frames/generate.py::_payload_from_shot` + the per-frame `lint_prompt_against_shot` call.
@Suite("prompt compose: shot projection + drift (#197)")
struct PromptComposerShotTests {
    static func shot(height: CameraHeight, framing: Framing) throws -> Shot {
        try Shot(id: "s001", section: "verse", timeStart: 0, timeEnd: 4, durationS: 4,
                 type: .performance, description: "d", visualPrompt: "p", mood: "m",
                 keyframeStrategy: .start, framing: framing,
                 cameraSetup: CameraSetup(height: height, angle: .frontal))
    }

    @Test("shot camera + framing are projected into the compiled prompt from the spec")
    func projectsCamera() async throws {
        let shot = try Self.shot(height: .high, framing: .wide)
        let c = try await PromptComposer.compose(
            intent: "a lone figure stands at the edge of a rooftop overlooking the city",
            modality: .video, modelId: "fal/seedance-2.0", projectDir: nil,
            shot: PromptComposer.ShotProjection(shot))
        #expect(c.text.contains("high camera height"))
        #expect(c.text.contains("wide framing"))
    }

    @Test("drift linter fires in compose when the prompt contradicts the shot's camera height")
    func driftFires() async throws {
        let shot = try Self.shot(height: .eyeLevel, framing: .ms)
        let c = try await PromptComposer.compose(
            intent: "a lone figure on a rooftop, aerial view of the rooftop far below",
            modality: .video, modelId: "fal/seedance-2.0", projectDir: nil,
            shot: PromptComposer.ShotProjection(shot))
        #expect(c.notes.contains { $0.contains("CAMERA_HEIGHT_MISMATCH") })
    }

    @Test("without a shot, no camera is injected and no drift note is raised")
    func noShotNoProjection() async throws {
        let c = try await PromptComposer.compose(
            intent: "a lone figure on a rooftop, aerial view of the rooftop far below",
            modality: .video, modelId: "fal/seedance-2.0", projectDir: nil)
        #expect(!c.notes.contains { $0.contains("CAMERA_HEIGHT_MISMATCH") })
    }
}
