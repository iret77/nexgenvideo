import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Music Video additional audio ranges")
struct ProductionMusicMixRangeTests {
    @Test("A declared audio layer retains its actual source clock and explicit NLE range")
    func exactNativeRange() throws {
        let source = CanonicalArtifactReferenceV1(id: "ambience", role: "musicvideo.additional-audio",
            path: "audio/ambience.wav", sha256: String(repeating: "0", count: 64))
        let layer = PipelineProductionMusicMix.Layer(assetID: source.id, trackID: "audio-track", clipID: "audio-clip",
            source: source, sourceStartValue: 48_000, sourceStartTimescale: 48_000,
            sourceEndValue: 480_001, sourceEndTimescale: 48_000, sourceTimescale: 48_000)
        var clip = Clip(id: layer.clipID, mediaRef: source.id, mediaType: .audio, sourceClipType: .audio,
            startFrame: 90, durationFrames: 270, trimStartFrame: 30)
        try PipelineProductionMusicMix.requireRange(clip, layer: layer, fps: 30)
        clip.trimStartFrame = 0
        #expect(throws: (any Error).self) { try PipelineProductionMusicMix.requireRange(clip, layer: layer, fps: 30) }
        clip.trimStartFrame = 30
        clip.durationFrames = 272
        #expect(throws: (any Error).self) { try PipelineProductionMusicMix.requireRange(clip, layer: layer, fps: 30) }
        clip.durationFrames = 270
        clip.speed = 2
        #expect(throws: (any Error).self) { try PipelineProductionMusicMix.requireRange(clip, layer: layer, fps: 30) }
    }
    @Test func actualLibraryCopyMustMatchApprovedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("native-effect.wav")
        let library = root.appendingPathComponent("library-copy.wav")
        let bytes = Data("actual imported audio bytes".utf8)
        try bytes.write(to: source)
        try FileManager.default.copyItem(at: source, to: library)
        let expected = FileDigest.sha256(of: bytes)
        #expect(PipelineProductionMusicMix.matchesSource(library, sha256: expected))
        try Data("different audio bytes".utf8).write(to: library)
        #expect(!PipelineProductionMusicMix.matchesSource(library, sha256: expected))
        #expect(!PipelineProductionMusicMix.matchesSource(root, sha256: expected))
    }

    @Test func nativeStartupSongIsReplacedOnlyWhenItsActualSourceAndTrackAreExclusive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("song.wav")
        let bytes = Data("actual native song bytes".utf8)
        try bytes.write(to: url)
        let source = CanonicalArtifactReferenceV1(id: "original-song", role: "musicvideo.original-song",
            path: "audio/song.wav", sha256: FileDigest.sha256(of: bytes))
        let song = Clip(mediaRef: "native-song", mediaType: .audio, sourceClipType: .audio, startFrame: 0, durationFrames: 240)
        let track = Track(type: .audio, clips: [song])
        var timeline = Timeline(); timeline.tracks = [track]
        var manifest = MediaManifest(); manifest.songAnchorAssetId = song.mediaRef
        manifest.intakeRoleByAssetID[song.mediaRef] = "song"
        let media = [PipelineProductionAssemblyWriter.ExistingMedia(id: song.mediaRef, path: "media/song.wav", url: url, type: .audio)]
        #expect(try PipelineProductionMusicMix.startupSongTrack(timeline: timeline, manifest: manifest, media: media, source: source) == track.id)
        try PipelineProductionMusicMix.requireNoForeignTracks(timeline, owned: [track.id])
        timeline.tracks[0].clips.append(Clip(mediaRef: "other", mediaType: .audio, sourceClipType: .audio, startFrame: 240, durationFrames: 30))
        #expect(throws: (any Error).self) {
            try PipelineProductionMusicMix.startupSongTrack(timeline: timeline, manifest: manifest, media: media, source: source)
        }
        timeline.tracks = [track, Track(type: .text, clips: [.init(mediaRef: "title", mediaType: .text, sourceClipType: .text, startFrame: 0, durationFrames: 30)])]
        #expect(throws: (any Error).self) { try PipelineProductionMusicMix.requireNoForeignTracks(timeline, owned: [track.id]) }
        timeline.tracks = [track]
        try Data("changed native source".utf8).write(to: url)
        #expect(throws: (any Error).self) {
            try PipelineProductionMusicMix.startupSongTrack(timeline: timeline, manifest: manifest, media: media, source: source)
        }
    }

}
