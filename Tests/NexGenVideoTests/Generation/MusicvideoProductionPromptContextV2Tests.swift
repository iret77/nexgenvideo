import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Musicvideo V2 canonical prompt intent")
struct MusicvideoProductionPromptContextV2Tests {
    @Test func typedPlanPreservesBoundVisualFunctionAndPhraseRelativeMouthOwnership() throws {
        let reference = CanonicalArtifactReferenceV1(id: "track", role: "audio", path: "audio/song.wav", sha256: String(repeating: "0", count: 64))
        let segment = MusicPerformanceSegmentDraftV1(id: "chorus-phrase", shotIDs: ["performer-shot"],
            sourceStartSample: 480_000, sourceEndSample: 672_000, sampleRate: 48_000, timelineStartSeconds: 10,
            purpose: .performedSong, performerIDs: ["singer", "silent"], audibleVoiceIDs: ["lead"],
            mouthOwnership: [.init(performerID: "singer", voiceID: "lead", timelineStartSeconds: 11, timelineEndSeconds: 13)],
            routeInputRoleID: "core.audio-timing", phraseBoundaryEvidence: "Measured chorus phrase.")
        let arc = MusicVisualArcDraftV1(concept: "Widen the chorus performance.", motifs: [], sections: [
            .init(sectionID: "chorus", musicalFunction: "release", visualFunction: "open the spatial frame", motifIDs: [],
                shotIDs: ["performer-shot"], constants: [], variations: [], lyricsRelation: .literal, changeExplanation: "The chorus reveals the full stage.")])
        let coverage = MusicPerformanceCoverageItemV1(id: "dance", sectionIDs: ["chorus"], kind: .dance,
            requiredRoleIDs: ["master"], evidence: [.init(roleID: "master", shotIDs: ["performer-shot"], performerIDs: ["singer"],
                setupIDs: [], showsFullBody: true, showsFloorContact: true, showsHandsAndOrientation: false,
                minimumContinuousSeconds: 4, assemblyRoleID: "master", referenceDemandIDs: [])],
            approvedExceptionRoleIDs: [], choreographyBeatIDs: [])
        let music = MusicvideoProductionExtensionV2(header: .init(projectID: "song", revision: 1, origin: .agentProposal, inputs: []),
            track: reference, analysis: reference, treatment: reference, storyboardTiming: reference,
            performanceSegments: [.init(draft: segment, sourceTrackPath: reference.path, sourceTrackSHA256: reference.sha256,
                segmentPath: "phrase.wav", segmentSHA256: reference.sha256, segmentByteCount: 44, exportedSampleCount: 192_000)],
            performanceReceipts: [], finalMix: .init(originalSongTimelineStartSeconds: 0, originalSongOccurrences: 1,
                providerSongAudioMuted: true, approvedAdditionalLayerIDs: []), visualArc: arc, coverage: [coverage])
        let visual = PipelineMusicvideoPromptContextV2.visual(music: music, shotID: "performer-shot", still: false).joined(separator: "\n")
        #expect(visual.contains("open the spatial frame"))
        #expect(visual.contains("keep the full body visible"))
        #expect(visual.contains("keep floor contact visible"))
        #expect(PipelineMusicvideoPromptContextV2.visual(music: music, shotID: "other-shot", still: false).isEmpty)
        let still = PipelineMusicvideoPromptContextV2.visual(music: music, shotID: "performer-shot", still: true).joined(separator: "\n")
        #expect(still.contains("this boundary still"))
        #expect(!still.contains("hold role master continuously"))
        let performance = try PipelineMusicvideoPromptContextV2.performance(music: music, shotID: "performer-shot", audioLabel: "@Audio1").joined(separator: "\n")
        #expect(performance.contains("@Audio1"))
        #expect(performance.contains("from 1.000000s to 3.000000s"))
        #expect(performance.contains("only performer singer mouths voice lead"))
        #expect(performance.contains("silent"))
        #expect(throws: (any Error).self) {
            try PipelineMusicvideoPromptContextV2.performance(music: music, shotID: "performer-shot", audioLabel: nil)
        }
    }
}
