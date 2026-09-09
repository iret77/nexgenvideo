import Testing
@testable import NexGenEngine

@Suite("Music assembly proof")
struct MusicAssemblyProofTests {
    @Test("accepts one exact song and current coverage evidence")
    func acceptsCurrentProof() throws {
        try MusicAssemblyProofValidatorV1.validate(proof())
    }

    @Test("rejects duplicate additional audio assets")
    func rejectsDuplicateAudioAssets() {
        let layer = audioLayer(mediaID: "ambience", clipID: "ambience-1")
        let invalid = MusicAssemblyProofV1(
            projectID: "demo",
            performanceBindingSHA256: hash("b"),
            coveragePlanSHA256: hash("c"),
            timelineAssemblySHA256: hash("d"),
            originalSong: audioLayer(mediaID: "song", clipID: "song-1"),
            providerAudioSuppressed: true,
            additionalAudioLayers: [
                layer,
                audioLayer(mediaID: layer.mediaID, clipID: "ambience-2"),
            ],
            roles: []
        )

        #expect(throws: MusicvideoProductionValidationErrorV1.self) {
            try MusicAssemblyProofValidatorV1.validate(invalid)
        }
    }

    @Test("rejects coverage shorter than its declared continuous minimum")
    func rejectsShortCoverage() {
        let invalid = MusicAssemblyProofV1(
            projectID: "demo",
            performanceBindingSHA256: hash("b"),
            coveragePlanSHA256: hash("c"),
            timelineAssemblySHA256: hash("d"),
            originalSong: audioLayer(mediaID: "song", clipID: "song-1"),
            providerAudioSuppressed: true,
            additionalAudioLayers: [],
            roles: [
                .init(
                    coverageID: "dance-main",
                    roleID: "full-body",
                    assemblyRoleID: "dance-master",
                    shotIDs: ["s001"],
                    clipIDs: ["clip-1"],
                    minimumContinuousSeconds: 4,
                    provedContinuousSeconds: 3.5
                ),
            ]
        )

        #expect(throws: MusicvideoProductionValidationErrorV1.self) {
            try MusicAssemblyProofValidatorV1.validate(invalid)
        }
    }

    private func proof() -> MusicAssemblyProofV1 {
        MusicAssemblyProofV1(
            projectID: "demo",
            performanceBindingSHA256: hash("b"),
            coveragePlanSHA256: hash("c"),
            timelineAssemblySHA256: hash("d"),
            originalSong: audioLayer(mediaID: "song", clipID: "song-1"),
            providerAudioSuppressed: true,
            additionalAudioLayers: [
                audioLayer(mediaID: "ambience", clipID: "ambience-1"),
            ],
            roles: [
                .init(
                    coverageID: "dance-main",
                    roleID: "full-body",
                    assemblyRoleID: "dance-master",
                    shotIDs: ["s001"],
                    clipIDs: ["clip-1"],
                    minimumContinuousSeconds: 4,
                    provedContinuousSeconds: 4
                ),
            ]
        )
    }

    private func audioLayer(mediaID: String, clipID: String) -> MusicAssemblyAudioLayerV1 {
        MusicAssemblyAudioLayerV1(
            mediaID: mediaID,
            clipID: clipID,
            path: "audio/\(mediaID).wav",
            sha256: hash("a"),
            startFrame: 0,
            durationFrames: 120
        )
    }

    private func hash(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
