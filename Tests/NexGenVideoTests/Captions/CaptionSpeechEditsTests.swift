import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Speech cuts preserve reviewed caption meaning and timing")
struct CaptionSpeechEditsTests {
    private let ranges = [CaptionSpeechEdits.Range(start: 30, end: 60)]
    private var words: [CaptionSpeechEdits.Word] {
        [.init(clipID: "voice", trackID: "audio", text: "Hello", startFrame: 0, endFrame: 30),
         .init(clipID: "voice", trackID: "audio", text: "um", startFrame: 30, endFrame: 60),
         .init(clipID: "voice", trackID: "audio", text: "world.", startFrame: 60, endFrame: 90)]
    }

    private func fixture() -> EditorViewModel {
        let editor = EditorViewModel()
        let video = Clip(id: "picture", mediaRef: "original-video", startFrame: 0, durationFrames: 180, linkGroupId: "linked")
        let audio = Clip(id: "voice", mediaRef: "original-audio", mediaType: .audio, sourceClipType: .audio,
            startFrame: 0, durationFrames: 180, linkGroupId: "linked")
        let caption = Clip(id: "caption", mediaRef: "text:caption", mediaType: .text, sourceClipType: .text,
            startFrame: 0, durationFrames: 90, captionGroupId: "subtitles", textContent: "Hello um world.")
        let follower = Clip(id: "follower", mediaRef: "text:follower", mediaType: .text, sourceClipType: .text,
            startFrame: 90, durationFrames: 30, captionGroupId: "subtitles", textContent: "Next line")
        editor.timeline = Timeline(fps: 30, width: 320, height: 180, settingsConfigured: true,
            tracks: [Track(id: "video", type: .video, clips: [video]), Track(id: "audio", type: .audio, clips: [audio]),
                     Track(id: "captions", type: .video, clips: [caption, follower])])
        return editor
    }

    private func prepare(_ editor: EditorViewModel, replacements: [String: String] = [:]) throws -> CaptionSpeechEdits.Plan {
        try CaptionSpeechEdits.prepare(timeline: editor.timeline, primaryTrackID: "audio", ranges: ranges,
            words: words, replacements: replacements)
    }

    @Test func spanningCaptionAndAdjacentFollowerAreReviewedAndCutInOneUndo() throws {
        let editor = fixture()
        let original = editor.timeline
        let manager = UndoManager(); manager.groupsByEvent = false; editor.undoManager = manager
        let plan = try prepare(editor)
        #expect(editor.timeline == original && !manager.canUndo)
        #expect(plan.changes.map { $0.before.id } == ["caption", "follower"])
        #expect(plan.changes[0].before.textContent == "Hello um world.")
        #expect(plan.changes[0].after?.textContent == "Hello world.")
        #expect(plan.changes[0].after?.durationFrames == 60)
        #expect(plan.changes[1].after?.startFrame == 60)
        let restored = try JSONDecoder().decode(CaptionSpeechEdits.Plan.self, from: JSONEncoder().encode(plan))
        #expect(restored == plan)
        try editor.preflightRippleDeleteRangesOnTrack(trackIndex: 1, ranges: [FrameRange(start: 30, end: 60)], captionEdits: restored)
        #expect(editor.timeline == original)
        let outcome = editor.rippleDeleteRangesOnTrack(trackIndex: 1, ranges: [FrameRange(start: 30, end: 60)], captionEdits: restored)
        guard case .ok(let report) = outcome else { Issue.record("A valid spanning caption cut was refused"); return }
        #expect(report.removedFrames == 30 && report.clearedTracks == 2)
        for track in editor.timeline.tracks.prefix(2) {
            #expect(track.clips.map(\.startFrame) == [0, 30])
            #expect(track.clips.map(\.durationFrames) == [30, 120])
            #expect(track.clips.map(\.trimStartFrame) == [0, 60])
        }
        #expect(editor.clipFor(id: "caption") == plan.changes[0].after)
        #expect(editor.clipFor(id: "follower") == plan.changes[1].after)
        let after = editor.timeline
        manager.undo(); #expect(editor.timeline == original && !manager.canUndo)
        manager.redo(); #expect(editor.timeline == after && !manager.canRedo)
    }

    @Test func translatedOrCorrectedCaptionNeedsExplicitBoundedReplacement() throws {
        let editor = fixture()
        editor.timeline.tracks[2].clips[0].textContent = "Hallo, ähm, Welt."
        #expect(throws: (any Error).self) { try prepare(editor) }
        let plan = try prepare(editor, replacements: ["caption": "Hallo, Welt."])
        #expect(plan.changes[0].after?.textContent == "Hallo, Welt." && plan.changes[0].after?.durationFrames == 60)
        #expect(throws: (any Error).self) { try prepare(editor, replacements: ["follower": "Unrelated rewrite"]) }
        #expect(throws: (any Error).self) { try prepare(editor, replacements: ["foreign": "Unrelated rewrite"]) }
        #expect(try prepare(editor, replacements: ["caption": ""]).changes[0].after == nil)
    }

    @Test func wholeCaptionRemovalAndUnlockedCaptionsAreExplicit() throws {
        let editor = fixture()
        editor.timeline.tracks[2].clips[0].startFrame = 30
        editor.timeline.tracks[2].clips[0].durationFrames = 30
        editor.timeline.tracks[2].clips[0].textContent = "um"
        #expect(try prepare(editor).changes[0].after == nil)
        #expect(throws: (any Error).self) { try prepare(editor, replacements: ["caption": "Cannot survive removed time"]) }
        editor.timeline.tracks[2].syncLocked = false
        let plan = try prepare(editor)
        #expect(plan.changes.isEmpty)
        let captions = editor.timeline.tracks[2]
        _ = editor.rippleDeleteRangesOnTrack(trackIndex: 1, ranges: [FrameRange(start: 30, end: 60)], captionEdits: plan)
        #expect(editor.timeline.tracks[2] == captions)
    }

    @Test func sourceWordClockAndCasePreserveActualTokenIdentity() throws {
        let editor = fixture()
        editor.timeline.tracks[2].clips[0].textContent = "HELLO um WORLD."
        #expect(try prepare(editor).changes[0].after?.textContent == "HELLO WORLD.")
        let wrongTrack = words.map { CaptionSpeechEdits.Word(clipID: $0.clipID, trackID: "foreign", text: $0.text,
            startFrame: $0.startFrame, endFrame: $0.endFrame) }
        #expect(throws: (any Error).self) {
            try CaptionSpeechEdits.prepare(timeline: editor.timeline, primaryTrackID: "audio", ranges: ranges, words: wrongTrack)
        }
        #expect(throws: (any Error).self) {
            try CaptionSpeechEdits.prepare(timeline: editor.timeline, primaryTrackID: "audio",
                ranges: [.init(start: 45, end: 60)], words: words)
        }
    }

    @Test func multipleCutsAndRepeatedTokensUseExactWordPositions() throws {
        let editor = fixture()
        editor.timeline.tracks[2].clips[0].textContent = "One um two er three"
        editor.timeline.tracks[2].clips[0].durationFrames = 150
        editor.timeline.tracks[2].clips[1].startFrame = 150
        let five = ["One", "um", "two", "er", "three"].enumerated().map { index, text in
            CaptionSpeechEdits.Word(clipID: "voice", trackID: "audio", text: text, startFrame: index * 30, endFrame: (index + 1) * 30)
        }
        let plan = try CaptionSpeechEdits.prepare(timeline: editor.timeline, primaryTrackID: "audio",
            ranges: [.init(start: 90, end: 120), .init(start: 30, end: 60)], words: five)
        #expect(plan.ranges == [.init(start: 30, end: 60), .init(start: 90, end: 120)])
        #expect(plan.changes[0].after?.textContent == "One two three" && plan.changes[0].after?.durationFrames == 90)
        #expect(plan.changes[1].after?.startFrame == 90)
        let repeated = fixture()
        repeated.timeline.tracks[2].clips[0].textContent = "Yes YES"
        repeated.timeline.tracks[2].clips[0].durationFrames = 60
        let actual = try CaptionSpeechEdits.prepare(timeline: repeated.timeline, primaryTrackID: "audio",
            ranges: [.init(start: 0, end: 30)], words: [
                .init(clipID: "voice", trackID: "audio", text: "Yes", startFrame: 0, endFrame: 30),
                .init(clipID: "voice", trackID: "audio", text: "yes", startFrame: 30, endFrame: 60)])
        #expect(actual.changes[0].after?.textContent == "YES" && actual.changes[0].after?.durationFrames == 30)
    }

    @Test func staleTimelineOrHiddenTransformEditRefusesBeforeAnyMutation() throws {
        let editor = fixture()
        let plan = try prepare(editor)
        editor.timeline.width += 1
        let changed = editor.timeline
        #expect(throws: (any Error).self) {
            try editor.preflightRippleDeleteRangesOnTrack(trackIndex: 1, ranges: [FrameRange(start: 30, end: 60)], captionEdits: plan)
        }
        guard case .refused = editor.rippleDeleteRangesOnTrack(trackIndex: 1, ranges: [FrameRange(start: 30, end: 60)], captionEdits: plan)
        else { Issue.record("A stale caption cut mutated the timeline"); return }
        #expect(editor.timeline == changed)
        editor.timeline.width -= 1
        var after = try #require(plan.changes[0].after)
        after.transform.centerX += 0.1
        let forged = CaptionSpeechEdits.Plan(primaryTrackID: plan.primaryTrackID, ranges: plan.ranges,
            timelineSHA256: plan.timelineSHA256, changes: [.init(trackID: "captions", before: plan.changes[0].before, after: after), plan.changes[1]])
        #expect(throws: (any Error).self) {
            try editor.preflightRippleDeleteRangesOnTrack(trackIndex: 1, ranges: [FrameRange(start: 30, end: 60)], captionEdits: forged)
        }
    }

    @Test func actualFollowerCollisionIsRefusedDuringBothProposalPreflightAndApply() throws {
        let editor = fixture()
        editor.timeline.tracks.append(Track(id: "unrelated", type: .audio, clips: [
            Clip(mediaRef: "other", mediaType: .audio, startFrame: 0, durationFrames: 120),
            Clip(mediaRef: "other", mediaType: .audio, startFrame: 120, durationFrames: 30)]))
        let plan = try prepare(editor), before = editor.timeline
        #expect(throws: (any Error).self) {
            try editor.preflightRippleDeleteRangesOnTrack(trackIndex: 1, ranges: [FrameRange(start: 30, end: 60)], captionEdits: plan)
        }
        guard case .refused = editor.rippleDeleteRangesOnTrack(trackIndex: 1, ranges: [FrameRange(start: 30, end: 60)], captionEdits: plan)
        else { Issue.record("A colliding sync-locked follower was accepted"); return }
        #expect(editor.timeline == before)
    }
}
