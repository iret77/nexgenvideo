import Testing
@testable import NexGenEngine

@Suite("Shot delivery modes")
struct ShotDeliveryModeTests {
    @Test("only the explicit image plus timeline contract resolves as an animated still")
    func resolvesAnimatedStillContract() {
        let still = executionShot(
            requirement: GenerationRequirementV1(
                modalityID: "image",
                modeIDs: [ShotDeliveryModeResolverV1.timelineAnimatedStillModeID],
                visibleEntityCount: 0
            )
        )
        let ordinaryImage = executionShot(
            requirement: GenerationRequirementV1(
                modalityID: "image",
                modeIDs: ["text_to_image"],
                visibleEntityCount: 0
            )
        )
        let video = executionShot(
            requirement: GenerationRequirementV1(
                modalityID: "video",
                modeIDs: ["text_to_video"],
                visibleEntityCount: 0
            )
        )

        #expect(ShotDeliveryModeResolverV1.resolve(still) == .timelineAnimatedStill)
        #expect(ShotDeliveryModeResolverV1.resolve(ordinaryImage) == nil)
        #expect(ShotDeliveryModeResolverV1.resolve(video) == .providerVideo)
    }

    @Test("timeline proof rejects still images without deterministic motion")
    func validatesStillMotion() throws {
        let valid = TimelineAssemblyProofV1(
            project: "demo",
            phase: "final",
            timelineFPS: 30,
            videoTrackID: "video-1",
            audioTrackID: nil,
            generatedAt: "2026-09-08T00:00:00Z",
            placements: [
                .init(
                    shotID: "s001",
                    clipID: "clip-1",
                    sourcePath: "media/s001.png",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sourceKind: .stillImage,
                    startFrame: 0,
                    durationFrames: 90,
                    motion: .init(
                        kind: .kenBurnsZoom,
                        startScale: 1,
                        endScale: 1.08
                    )
                ),
            ]
        )
        try TimelineAssemblyProofValidatorV1.validate(valid)

        let invalid = TimelineAssemblyProofV1(
            project: valid.project,
            phase: valid.phase,
            timelineFPS: valid.timelineFPS,
            videoTrackID: valid.videoTrackID,
            audioTrackID: valid.audioTrackID,
            generatedAt: valid.generatedAt,
            placements: [
                .init(
                    shotID: "s001",
                    clipID: "clip-1",
                    sourcePath: "media/s001.png",
                    sourceSHA256: String(repeating: "a", count: 64),
                    sourceKind: .stillImage,
                    startFrame: 0,
                    durationFrames: 90,
                    motion: nil
                ),
            ]
        )
        #expect(throws: TimelineAssemblyProofValidationErrorV1.self) {
            try TimelineAssemblyProofValidatorV1.validate(invalid)
        }
    }

    private func executionShot(
        requirement: GenerationRequirementV1
    ) -> ExecutionShotV1 {
        ExecutionShotV1(
            id: "s001",
            sourceMode: .generated,
            startState: .init(summary: "Opening state."),
            endState: .init(summary: "Closing state."),
            primaryAction: "Hold the composition.",
            camera: .init(movementID: "static"),
            renderability: .green,
            acceptance: [
                .init(
                    id: "composition",
                    requirement: "The composition matches.",
                    severity: "required"
                ),
            ],
            generationRequirement: requirement
        )
    }
}
