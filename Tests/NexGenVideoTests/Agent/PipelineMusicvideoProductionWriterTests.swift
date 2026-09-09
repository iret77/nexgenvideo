import Testing
@testable import NexGenVideo
import NexGenEngine

@Suite("Musicvideo production prompt projection")
struct PipelineMusicvideoProductionWriterTests {
    @Test("approved visual-arc parameters reach only their bound shots")
    func visualArcParametersBecomeDirectives() {
        let arc = MusicVisualArcDraftV1(
            concept: "A recurring doorway changes with the chorus.",
            motifs: [MusicArcMotifV1(
                id: "doorway",
                description: "The doorway remains the spatial anchor.",
                setupIDs: ["wide"]
            )],
            sections: [MusicArcSectionV1(
                sectionID: "chorus-2",
                musicalFunction: "second release",
                visualFunction: "widen the performance",
                motifIDs: ["doorway"],
                shotIDs: ["s002"],
                constants: [MusicArcParameterV1(
                    kind: .lighting,
                    targetID: "doorway",
                    value: "keep the amber doorway practical",
                    rationale: "Preserve recognition across choruses."
                )],
                variations: [MusicArcParameterV1(
                    kind: .camera,
                    targetID: "wide",
                    value: "increase lateral travel to two meters",
                    rationale: "Express the second chorus expansion."
                )],
                lyricsRelation: .unused,
                changeExplanation: "The motif stays constant while camera energy increases."
            )]
        )

        let directives = PipelineMusicvideoProductionWriter.visualArcDirectives(
            visualArc: arc,
            shotID: "s002"
        )
        #expect(directives.contains { $0.contains("keep the amber doorway practical") })
        #expect(directives.contains { $0.contains("increase lateral travel to two meters") })
        #expect(directives.contains { $0.contains("chorus-2") })
        #expect(PipelineMusicvideoProductionWriter.visualArcDirectives(
            visualArc: arc,
            shotID: "unbound-shot"
        ).isEmpty)
    }
}
