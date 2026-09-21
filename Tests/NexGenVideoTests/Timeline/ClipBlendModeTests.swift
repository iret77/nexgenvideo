import Foundation
import Testing
@testable import NexGenVideo

@Suite("Clip compositing — persistence and editing")
@MainActor
struct ClipBlendModeTests {
    @Test func oldProjectsDefaultToNormalWithoutMaterializingCarrier() throws {
        let data = Data(#"{"id":"old","mediaRef":"source","startFrame":0,"durationFrames":30}"#.utf8)
        let clip = try JSONDecoder().decode(Clip.self, from: data)
        #expect(clip.blendMode == .normal)
        #expect(clip.compositing == nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String: Any]
        #expect(encoded?["compositing"] == nil)
    }

    @Test(arguments: ClipBlendMode.allCases)
    func timelineRoundTrip(mode: ClipBlendMode) throws {
        var clip = Fixtures.clip(id: "clip", start: 0, duration: 30)
        clip.blendMode = mode
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let restored = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(timeline))
        #expect(restored == timeline)
        #expect(restored.tracks[0].clips[0].blendMode == mode)
    }

    @Test func futureModeAndVersionRemainIntactUntilExplicitEdit() throws {
        for carrier in [ClipCompositingV1(blendMode: "future"), ClipCompositingV1(version: 2, blendMode: "multiply")] {
            var clip = Fixtures.clip(id: "clip", start: 0, duration: 30)
            clip.compositing = carrier
            let restored = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
            #expect(restored.blendMode == .normal)
            #expect(restored.compositing == carrier)
            #expect(restored.blendModeTitle == "Normal (Unsupported Mode)")
            let editor = EditorViewModel()
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [restored])])
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undoManager = undo
            try editor.setClipBlendMode(.normal, clipIds: [clip.id])
            #expect(editor.clipFor(id: clip.id)?.compositing == nil)
            undo.undo()
            #expect(editor.clipFor(id: clip.id)?.compositing == carrier)
            undo.redo()
            #expect(editor.clipFor(id: clip.id)?.compositing == nil)
        }
    }

    @Test func inspectorMutationIsAtomicAndUndoableAcrossVisualTypes() throws {
        let clips = [ClipType.video, .image, .text, .lottie].enumerated().map { index, type in
            Fixtures.clip(id: "c\(index)", mediaType: type, start: index * 30, duration: 30)
        }
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: clips)])
        let before = editor.timeline
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        try editor.setClipBlendMode(.screen, clipIds: clips.map(\.id) + ["c0"])
        #expect(editor.timeline.tracks[0].clips.allSatisfy { $0.blendMode == .screen })
        undo.undo()
        #expect(editor.timeline == before)
        undo.redo()
        #expect(editor.timeline.tracks[0].clips.allSatisfy { $0.blendMode == .screen })
        let after = editor.timeline
        #expect(throws: ToolError.self) { try editor.setClipBlendMode(.multiply, clipIds: ["c0", "missing"]) }
        #expect(editor.timeline == after)
    }

    @Test func splitDuplicateAndClipboardRetainBlendMode() throws {
        var clip = Fixtures.clip(id: "clip", start: 0, duration: 60)
        clip.blendMode = .overlay
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        _ = editor.splitClip(clipId: clip.id, atFrame: 30)
        editor.selectedClipIds = [clip.id]
        editor.copySelectedClipsToClipboard()
        editor.pasteClips(atTrack: 0, atFrame: 90)
        editor.duplicateClipsToPositions([(clipId: clip.id, toTrack: 0, toFrame: 120)])
        #expect(editor.timeline.tracks[0].clips.count == 4)
        #expect(editor.timeline.tracks[0].clips.allSatisfy { $0.blendMode == .overlay })
    }
}
