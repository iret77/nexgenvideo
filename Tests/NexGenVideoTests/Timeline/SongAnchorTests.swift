import Foundation
import Testing

@testable import NexGenVideo

/// The song is the project's spine — every cut keys to its beats. It must be on the timeline from the
/// moment it arrives, not only after the final assembly, or the editor shows an empty timeline through
/// the entire production of a music video.
@MainActor
@Suite("song anchored on the timeline")
struct SongAnchorTests {

    private func songAsset(duration: Double = 199.0) -> MediaAsset {
        MediaAsset(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-claude-mouse.mp3"),
            type: .audio, name: "claude-mouse", duration: duration)
    }

    private func anchor(_ asset: MediaAsset, in editor: EditorViewModel) {
        let index = editor.timeline.tracks.firstIndex { $0.type == .audio }
            ?? editor.insertTrack(at: editor.timeline.tracks.count, type: .audio)
        let frames = max(1, Int((asset.duration * Double(editor.timeline.fps)).rounded()))
        _ = editor.placeClip(asset: asset, trackIndex: index, startFrame: 0,
                             durationFrames: frames, addLinkedAudio: false)
    }

    @Test("the song lands at frame 0 on an audio track, full length")
    func songLandsAtZero() {
        let editor = EditorViewModel()
        let song = songAsset()
        editor.importMediaAsset(song)

        anchor(song, in: editor)

        let track = editor.timeline.tracks.first { $0.type == .audio }
        let clip = track?.clips.first { $0.mediaRef == song.id }
        #expect(clip?.startFrame == 0)
        #expect(clip?.durationFrames == Int((199.0 * Double(editor.timeline.fps)).rounded()))
    }

    @Test("anchoring twice does not duplicate the song")
    func anchorIsIdempotent() {
        // `assemble_timeline` places the song too and keys its skip on exactly this check — mediaRef at
        // frame 0 on an audio track. Two anchors would mean the song plays twice.
        let editor = EditorViewModel()
        let song = songAsset()
        editor.importMediaAsset(song)
        anchor(song, in: editor)

        let alreadyAnchored = editor.timeline.tracks.contains { track in
            track.type == .audio && track.clips.contains { $0.mediaRef == song.id && $0.startFrame == 0 }
        }
        #expect(alreadyAnchored)

        let clipCount = editor.timeline.tracks
            .filter { $0.type == .audio }
            .reduce(0) { $0 + $1.clips.filter { $0.mediaRef == song.id }.count }
        #expect(clipCount == 1)
    }

    @Test("an audio track that already exists is reused, not stacked")
    func reusesExistingAudioTrack() {
        let editor = EditorViewModel()
        let existing = editor.insertTrack(at: editor.timeline.tracks.count, type: .audio)
        let before = editor.timeline.tracks.count
        let song = songAsset()
        editor.importMediaAsset(song)

        anchor(song, in: editor)

        #expect(editor.timeline.tracks.count == before)
        #expect(editor.timeline.tracks[existing].clips.contains { $0.mediaRef == song.id })
    }
}
