import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

/// PromptComposer per-shot compile: deterministic camera/framing projection + compliance drift linter
/// on the running compile path (#197). Ports the camera/composition projection of
/// `frames/generate.py::_payload_from_shot` + the per-frame `lint_prompt_against_shot` call.
@Suite("prompt compose: shot projection + drift (#197)")
struct PromptComposerShotTests {
    static func shot(
        height: CameraHeight,
        framing: Framing,
        productionPlan: ShotProductionPlan? = nil,
        characterBlocking: [CharacterBlocking] = []
    ) throws -> Shot {
        try Shot(id: "s001", section: "verse", timeStart: 0, timeEnd: 4, durationS: 4,
                 type: .performance, description: "d", visualPrompt: "p", mood: "m",
                 characterRefs: characterBlocking.map(\.characterRef),
                 keyframeStrategy: .start, framing: framing,
                 cameraSetup: CameraSetup(height: height, angle: .frontal),
                 characterBlocking: characterBlocking,
                 productionPlan: productionPlan)
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

    @Test("production plan projects motion only into video and continuity into both modalities")
    func projectsProductionPlan() async throws {
        let plan = try ShotProductionPlan(
            primaryAction: "the performer raises one hand",
            cameraMovement: .dollyIn,
            cameraMovementDetail: "35mm follow from full shot to medium close-up",
            narrativeBeat: .reaction,
            renderability: .green,
            matchActionCue: "raised hand reaches eye level",
            continuityLocks: ["red jacket remains zipped"]
        )
        let shot = try Self.shot(height: .eyeLevel, framing: .full, productionPlan: plan)
        let projection = PromptComposer.ShotProjection(shot)
        let video = try await PromptComposer.compose(
            intent: "the performer runs away while the camera pans right",
            modality: .video, modelId: "fal/seedance-2.0", projectDir: nil,
            setting: "inside the red rehearsal room",
            lighting: "soft window light from camera left",
            style: "restrained hand-drawn animation",
            shot: projection
        )
        let image = try await PromptComposer.compose(
            intent: "the performer holds the marked t=0 pose",
            modality: .image, modelId: "openai/gpt-image-2", projectDir: nil,
            setting: "caller supplied rehearsal room",
            lighting: "caller supplied window light",
            style: "caller supplied oil paint",
            shot: projection
        )

        #expect(video.text.contains("the performer raises one hand"))
        #expect(video.text.contains("Match-action cue: raised hand reaches eye level"))
        #expect(!image.text.contains("the performer raises one hand"))
        #expect(!image.text.contains("Match-action cue: raised hand reaches eye level"))
        #expect(video.text.contains("Continuity lock: red jacket remains zipped"))
        #expect(image.text.contains("Continuity lock: red jacket remains zipped"))
        #expect(video.text.contains("single controlled dolly-in"))
        #expect(!video.text.contains("runs away"))
        #expect(!video.text.contains("pans right"))
        #expect(!video.text.contains("inside the red rehearsal room"))
        #expect(!video.text.contains("soft window light from camera left"))
        #expect(!video.text.contains("restrained hand-drawn animation"))
        #expect(!image.text.contains("single controlled dolly-in"))
        #expect(!image.text.contains("35mm follow"))
        #expect(!image.text.contains("caller supplied rehearsal room"))
        #expect(!image.text.contains("caller supplied window light"))
        #expect(!image.text.contains("caller supplied oil paint"))
        #expect(ProductionPromptPolicy.videoPromptViolations(
            video.text,
            expectedMovement: plan.cameraMovement,
            expectedMovementDetail: plan.cameraMovementDetail
        ).isEmpty)
        #expect(ProductionPromptPolicy.stillPromptViolations(image.text).isEmpty)
        #expect(ComplianceLinter.lintLockedDirectives(
            video.text,
            lockedDirectives: shot.videoProductionPromptRequirements
        ).isEmpty)
        #expect(ComplianceLinter.lintLockedDirectives(
            image.text,
            lockedDirectives: shot.stillProductionPromptRequirements
        ).isEmpty)
    }

    @Test("planned still compilation blocks synonym camera motion in caller intent")
    func blocksStillCameraMotion() async throws {
        let plan = try ShotProductionPlan(
            primaryAction: "the performer raises one hand",
            cameraMovement: .dollyIn,
            renderability: .green
        )
        let shot = try Self.shot(
            height: .eyeLevel,
            framing: .full,
            productionPlan: plan
        )

        await #expect(throws: PromptComposer.ComposeError.self) {
            try await PromptComposer.compose(
                intent: "the performer holds still while the view glides forward",
                modality: .image,
                modelId: "openai/gpt-image-2",
                projectDir: nil,
                shot: PromptComposer.ShotProjection(shot)
            )
        }
    }

    @Test("camera-motion synonyms are rejected independently of exact plan prose")
    func rejectsCameraMotionSynonyms() {
        #expect(!ProductionPromptPolicy.stillPromptViolations("Static subject, pan left").isEmpty)
        #expect(!ProductionPromptPolicy.stillPromptViolations("Static subject, tilt up").isEmpty)
        #expect(!ProductionPromptPolicy.stillPromptViolations("Static subject, zoom in").isEmpty)
        #expect(!ProductionPromptPolicy.stillPromptViolations(
            "Static subject while the camera glides forward"
        ).isEmpty)
        for prompt in [
            "Static subject while the camera dollies forward",
            "Static subject while the camera dollies backward",
            "Static subject while the camera is dollying",
            "Static subject while the camera drifts forward",
            "Static subject while the camera creeps in",
            "Static subject while the camera eases back",
            "Static subject while the camera floats past",
            "Static subject while the camera crawls closer",
            "Static subject while the camera swoops down",
            "Static subject while the frame rises",
            "Static subject while the view descends",
        ] {
            #expect(!ProductionPromptPolicy.stillPromptViolations(prompt).isEmpty)
        }
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Locked-off static camera. The camera dollies forward.",
            expectedMovement: .static,
            expectedMovementDetail: nil
        ).isEmpty)
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Single controlled dolly-in. The view pans right.",
            expectedMovement: .dollyIn,
            expectedMovementDetail: nil
        ).isEmpty)
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Single controlled pan. The camera pans right.",
            expectedMovement: .pan,
            expectedMovementDetail: nil
        ).isEmpty)
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Single controlled pan. Single controlled pan.",
            expectedMovement: .pan,
            expectedMovementDetail: nil
        ).isEmpty)
        #expect(ProductionPromptPolicy.videoPromptViolations(
            "Single pedestal rise.",
            expectedMovement: .other,
            expectedMovementDetail: "single pedestal rise"
        ).isEmpty)
        #expect(!ProductionPromptPolicy.videoPromptViolations(
            "Single pedestal rise. The camera pans right.",
            expectedMovement: .other,
            expectedMovementDetail: "single pedestal rise"
        ).isEmpty)
    }

    @Test("risky plans project their exact rescue cut into render requirements")
    func projectsRescueCut() throws {
        let plan = try ShotProductionPlan(
            primaryAction: "the performer turns toward the doorway",
            cameraMovement: .static,
            renderability: .yellow,
            risks: [.complexInteraction],
            rescueCut: "cut to a close reaction at the doorway"
        )
        let shot = try Self.shot(
            height: .eyeLevel,
            framing: .full,
            productionPlan: plan
        )

        #expect(shot.videoProductionPromptRequirements.contains(
            "Approved rescue-cut fallback: cut to a close reaction at the doorway"
        ))
    }

    @Test("named blocking anchors project into video and still prompts")
    func projectsBlockingAnchor() async throws {
        let blocking = try CharacterBlocking(
            characterRef: "performer",
            position: "left third",
            pose: "standing",
            gaze: "toward the yard",
            relationToSet: "beside the doorway"
        )
        let plan = try ShotProductionPlan(
            primaryAction: "the performer waits",
            cameraMovement: .static,
            renderability: .green,
            blockingAnchors: [
                ProductionBlockingAnchor(
                    characterRef: "performer",
                    setAnchor: "hall doorway"
                ),
            ]
        )
        let shot = try Self.shot(
            height: .eyeLevel,
            framing: .full,
            productionPlan: plan,
            characterBlocking: [blocking]
        )
        let projection = PromptComposer.ShotProjection(shot)
        let video = try await PromptComposer.compose(
            intent: "the performer waits",
            modality: .video,
            modelId: "fal/seedance-2.0",
            projectDir: nil,
            shot: projection
        )
        let image = try await PromptComposer.compose(
            intent: "the performer waits",
            modality: .image,
            modelId: "openai/gpt-image-2",
            projectDir: nil,
            shot: projection
        )

        #expect(video.text.contains("hall doorway"))
        #expect(image.text.contains("hall doorway"))
    }
}
