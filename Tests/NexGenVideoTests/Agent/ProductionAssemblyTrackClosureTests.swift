import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Production assembly track closure")
struct ProductionAssemblyTrackClosureTests {
    @Test("Render layout rejects extra effective overlays, audio and changed track order")
    func exactTrackClosure() throws {
        let video = Track(id: "picture", type: .video, clips: [Clip(mediaRef: "picture-source", mediaType: .video,
            sourceClipType: .video, startFrame: 0, durationFrames: 120)])
        let audio = Track(id: "sound", type: .audio, clips: [Clip(mediaRef: "song", mediaType: .audio,
            sourceClipType: .audio, startFrame: 0, durationFrames: 120)])
        let receipt = PipelineProductionAssemblyWriter.Receipt(schema: "production-assembly-host/v1", projectKey: "project",
            workflow: try .core(.current), assembly: .init(id: "assembly", role: "core.production-assembly",
                path: ProductionPlanAssemblyProofV1.relativePath, sha256: String(repeating: "0", count: 64)),
            fps: 30, tracks: [video, audio], media: [], audioPreparation: nil,
            soundtrackTrackID: audio.id, linkedAudio: [:])
        var timeline = Timeline(tracks: [video, audio])
        try PipelineProductionAssemblyWriter.requireTimeline(receipt, timeline: timeline, mediaURLs: nil, exactVisuals: true)
        for type in [ClipType.video, .text, .audio] {
            let clip = Clip(mediaRef: "unapproved", mediaType: type, sourceClipType: type, startFrame: 0, durationFrames: 120)
            let extra = Track(type: type == .audio ? .audio : .video, clips: [clip])
            timeline.tracks.append(extra)
            #expect(throws: (any Error).self) {
                try PipelineProductionAssemblyWriter.requireTimeline(receipt, timeline: timeline, mediaURLs: nil, exactVisuals: true)
            }
            timeline.tracks.removeLast()
        }
        timeline.tracks.reverse()
        #expect(throws: (any Error).self) {
            try PipelineProductionAssemblyWriter.requireTimeline(receipt, timeline: timeline, mediaURLs: nil, exactVisuals: true)
        }
        timeline.tracks.reverse()
        try PipelineProductionAssemblyWriter.requireTimeline(receipt, timeline: timeline, mediaURLs: nil, exactVisuals: true)
        timeline.tracks.append(Track(type: .audio, muted: true, clips: [audio.clips[0]]))
        timeline.tracks.append(Track(type: .video, hidden: true, clips: [video.clips[0]]))
        timeline.tracks.append(Track(type: .video))
        try PipelineProductionAssemblyWriter.requireTimeline(receipt, timeline: timeline, mediaURLs: nil, exactVisuals: true)
    }

    @Test("Multicam visual and audio tracks use the exact receipt order")
    func multicamTrackOrder() throws {
        let first = Track(id: "camera-a", type: .video, clips: [Clip(mediaRef: "first", mediaType: .video, sourceClipType: .video, startFrame: 0, durationFrames: 120)])
        let firstAudio = Track(id: "audio-a", type: .audio)
        let second = Track(id: "camera-b", type: .video, clips: [Clip(mediaRef: "second", mediaType: .video, sourceClipType: .video, startFrame: 0, durationFrames: 120)])
        let secondAudio = Track(id: "audio-b", type: .audio)
        let ordered = PipelineProductionAssemblyWriter.orderedTracks([first, firstAudio, second, secondAudio])
        #expect(ordered.map(\.id) == [first.id, second.id, firstAudio.id, secondAudio.id])
        let receipt = PipelineProductionAssemblyWriter.Receipt(schema: "production-assembly-host/v1", projectKey: "project",
            workflow: try .core(.current), assembly: .init(id: "assembly", role: "core.production-assembly",
                path: ProductionPlanAssemblyProofV1.relativePath, sha256: String(repeating: "0", count: 64)),
            fps: 30, tracks: ordered, media: [], audioPreparation: nil, soundtrackTrackID: nil, linkedAudio: [:])
        try PipelineProductionAssemblyWriter.requireTimeline(receipt, timeline: Timeline(tracks: [first, second, firstAudio, secondAudio]),
            mediaURLs: nil, exactVisuals: true)
        #expect(throws: (any Error).self) {
            try PipelineProductionAssemblyWriter.requireTimeline(receipt, timeline: Timeline(tracks: [first, firstAudio, second, secondAudio]),
                mediaURLs: nil, exactVisuals: true)
        }
    }

}
