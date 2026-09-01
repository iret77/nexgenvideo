import Testing
@testable import NexGenVideo
import NexGenEngine

@Suite("Pipeline production-input refresh")
struct PipelineProductionInputsWriterTests {
    @Test("refresh regenerates frame and shot-local audio timing inputs")
    func refreshReplacesDynamicInputs() {
        let predecessor = ReferenceDemandV1(
            id: "predecessor-last-frame",
            assetID: "asset-predecessor",
            modality: .image,
            semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
            isRequired: true,
            priority: 0,
            inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
            modeID: "image-to-video",
            expectedSourceShotID: "shot-001"
        )
        let audioTiming = ReferenceDemandV1(
            id: "audio-timing",
            assetID: "asset-song-audio",
            modality: .audio,
            semanticJobID: CoreReferenceSemanticJobIDV1.audioTiming,
            isRequired: true,
            priority: 0,
            inputSlotID: CoreReferenceInputSlotIDV1.audioTiming,
            modeID: "audio-to-video"
        )

        let preserved = PipelineProductionInputsWriter.demandsPreservedAcrossRefresh([
            predecessor,
            audioTiming,
        ])

        #expect(preserved.isEmpty)
    }
}
