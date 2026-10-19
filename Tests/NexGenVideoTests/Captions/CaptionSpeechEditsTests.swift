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

    @Test(arguments: ["Next line", String(repeating: "Ä", count: 4_001)])
    func spanningCaptionAndAdjacentFollowerAreReviewedAndCutInOneUndo(followerText: String) throws {
        let editor = fixture()
        let subtitle = try SubtitleFileParser.parse("1\n00:00:03,000 --> 00:00:04,000\n" + followerText + "\n", format: .srt)
        let importedText = try #require(subtitle.cues.first?.text)
        #expect(importedText == followerText)
        editor.timeline.tracks[2].clips[1].textContent = importedText
        let original = editor.timeline
        let manager = UndoManager(); manager.groupsByEvent = false; editor.undoManager = manager
        let plan = try prepare(editor)
        #expect(editor.timeline == original && !manager.canUndo)
        #expect(plan.changes.map { $0.before.id } == ["caption", "follower"])
        #expect(plan.changes[0].before.textContent == "Hello um world.")
        #expect(plan.changes[0].after.first?.textContent == "Hello world.")
        #expect(plan.changes[0].after.first?.durationFrames == 60)
        #expect(plan.changes[1].after.first?.startFrame == 60)
        var expectedFollower = original.tracks[2].clips[1]
        expectedFollower.startFrame = 60
        #expect(plan.changes[1].after == [expectedFollower])
        var rewrittenFollower = expectedFollower
        rewrittenFollower.textContent = importedText + "!"
        let forged = CaptionSpeechEdits.Plan(primaryTrackID: plan.primaryTrackID, ranges: plan.ranges,
            timelineSHA256: plan.timelineSHA256, changes: [plan.changes[0],
                .init(trackID: plan.changes[1].trackID, before: plan.changes[1].before, after: [rewrittenFollower])])
        #expect(throws: (any Error).self) {
            try CaptionSpeechEdits.requireCurrent(forged, timeline: original, primaryTrackID: "audio", ranges: ranges)
        }
        #expect(editor.timeline == original)
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
        #expect(editor.clipFor(id: "caption") == plan.changes[0].after.first)
        #expect(editor.clipFor(id: "follower") == plan.changes[1].after.first)
        let after = editor.timeline
        manager.undo(); #expect(editor.timeline == original && !manager.canUndo)
        manager.redo(); #expect(editor.timeline == after && !manager.canRedo)
    }

    @Test func translatedOrCorrectedCaptionNeedsExplicitBoundedReplacement() throws {
        let editor = fixture()
        editor.timeline.tracks[2].clips[0].textContent = "Hallo, ähm, Welt."
        #expect(throws: (any Error).self) { try prepare(editor) }
        let plan = try prepare(editor, replacements: ["caption": "Hallo, Welt."])
        #expect(plan.changes[0].after.first?.textContent == "Hallo, Welt." && plan.changes[0].after.first?.durationFrames == 60)
        #expect(throws: (any Error).self) { try prepare(editor, replacements: ["follower": "Unrelated rewrite"]) }
        #expect(throws: (any Error).self) { try prepare(editor, replacements: ["foreign": "Unrelated rewrite"]) }
        #expect(throws: (any Error).self) { try prepare(editor, replacements: ["caption": String(repeating: "Ä", count: 4_001)]) }
        #expect(try prepare(editor, replacements: ["caption": ""]).changes[0].after.isEmpty)
    }

    @Test func wholeCaptionRemovalAndUnlockedCaptionsAreExplicit() throws {
        let editor = fixture()
        editor.timeline.tracks[2].clips[0].startFrame = 30
        editor.timeline.tracks[2].clips[0].durationFrames = 30
        editor.timeline.tracks[2].clips[0].textContent = "um"
        #expect(try prepare(editor).changes[0].after.isEmpty)
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
        #expect(try prepare(editor).changes[0].after.first?.textContent == "HELLO WORLD.")
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
        #expect(plan.changes[0].after.first?.textContent == "One two three" && plan.changes[0].after.first?.durationFrames == 90)
        #expect(plan.changes[1].after.first?.startFrame == 90)
        let repeated = fixture()
        repeated.timeline.tracks[2].clips[0].textContent = "Yes YES"
        repeated.timeline.tracks[2].clips[0].durationFrames = 60
        let actual = try CaptionSpeechEdits.prepare(timeline: repeated.timeline, primaryTrackID: "audio",
            ranges: [.init(start: 0, end: 30)], words: [
                .init(clipID: "voice", trackID: "audio", text: "Yes", startFrame: 0, endFrame: 30),
                .init(clipID: "voice", trackID: "audio", text: "yes", startFrame: 30, endFrame: 60)])
        #expect(actual.changes[0].after.first?.textContent == "YES" && actual.changes[0].after.first?.durationFrames == 30)
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
        var after = try #require(plan.changes[0].after.first)
        after.transform.centerX += 0.1
        let forged = CaptionSpeechEdits.Plan(primaryTrackID: plan.primaryTrackID, ranges: plan.ranges,
            timelineSHA256: plan.timelineSHA256, changes: [.init(trackID: "captions", before: plan.changes[0].before, after: [after]), plan.changes[1]])
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
    private func animatedCaption(_ interpolation: Interpolation, kind: String = "all") -> Clip {
        var caption = fixture().timeline.tracks[2].clips[0]
        func track<V: Codable & Sendable & Equatable>(_ first: V, _ last: V) -> KeyframeTrack<V> {
            .init(keyframes: [.init(frame: 0, value: first, interpolationOut: interpolation),
                              .init(frame: 90, value: last, interpolationOut: .hold)])
        }
        if kind == "all" {
            caption.opacityTrack = track(0.2, 0.9)
            caption.positionTrack = track(AnimPair(a: 0.1, b: 0.2), AnimPair(a: 0.3, b: 0.4))
            caption.scaleTrack = track(AnimPair(a: 0.7, b: 0.6), AnimPair(a: 0.9, b: 0.8))
            caption.rotationTrack = track(-10.0, 30.0)
            caption.cropTrack = track(Crop(), Crop(left: 0.1, top: 0.05, right: 0.1, bottom: 0.05))
            caption.volumeTrack = track(-18.0, -2.0)
        }
        if kind != "effects" {
            caption.fadeInFrames = 20
            caption.fadeOutFrames = 35
            caption.fadeInInterpolation = interpolation
            caption.fadeOutInterpolation = interpolation
        }
        if kind != "fades" {
            caption.effects = [Effect(id: "caption-effect", type: "color.exposure", params: [
                "ev": .init(value: 0, string: "preserved", track: track(-0.4, 0.4))])]
        }
        caption.linkGroupId = "caption-links"
        return caption
    }

    private func samples(_ clip: Clip, frame: Int) -> [Double] {
        let position = clip.topLeftAt(frame: frame), size = clip.sizeAt(frame: frame), crop = clip.cropAt(frame: frame)
        var result = [clip.opacityAt(frame: frame), clip.volumeAt(frame: frame), clip.rotationAt(frame: frame),
                      position.x, position.y, size.width, size.height, crop.left, crop.top, crop.right, crop.bottom]
        for effect in clip.effects ?? [] where effect.type != ClipAnimationEnvelope.effectType {
            for key in effect.params.keys.sorted() {
                if let parameter = effect.params[key], parameter.track != nil {
                    result.append(parameter.resolved(at: frame - clip.startFrame, default: 0))
                }
            }
        }
        return result
    }

    @Test(arguments: [Interpolation.linear, .hold, .smooth])
    func interiorSpeechCutsRetainEverySurvivingAnimationSampleAndExactUndo(_ interpolation: Interpolation) throws {
        for kind in ["all", "effects", "fades"] {
            let editor = fixture(), caption = animatedCaption(interpolation, kind: kind)
            editor.timeline.tracks[2].clips[0] = caption
            let before = editor.timeline
            let manager = UndoManager(); manager.groupsByEvent = false; editor.undoManager = manager
            let plan = try prepare(editor)
            let fragments = plan.changes[0].after
            #expect(fragments.map(\.startFrame) == [0, 30] && fragments.map(\.durationFrames) == [30, 30])
            #expect(fragments[0].id == caption.id && fragments[1].id != caption.id)
            #expect(fragments.allSatisfy { $0.textContent == "Hello world." && $0.captionGroupId == caption.captionGroupId
                && $0.linkGroupId == caption.linkGroupId && $0.captionProvenance == caption.captionProvenance })
            let decoded = try JSONDecoder().decode(CaptionSpeechEdits.Plan.self, from: JSONEncoder().encode(plan))
            #expect(decoded == plan && (try prepare(editor)) == plan)
            guard case .ok = editor.rippleDeleteRangesOnTrack(trackIndex: 1,
                ranges: [FrameRange(start: 30, end: 60)], captionEdits: decoded) else {
                Issue.record("An exact animated caption split was refused"); return
            }
            let after = editor.timeline
            for fragment in after.tracks[2].clips where fragment.id != "follower" {
                for frame in fragment.startFrame..<fragment.endFrame {
                    let sourceFrame = frame < 30 ? frame : frame + 30
                    #expect(samples(fragment, frame: frame) == samples(caption, frame: sourceFrame))
                }
                #expect(fragment.allKeyframeFrames.allSatisfy { fragment.contains(timelineFrame: $0) })
            }
            if kind != "effects" { #expect(fragments[1].fadeMultiplier(at: 59) == caption.fadeMultiplier(at: 89)) }
            manager.undo(); #expect(editor.timeline == before && !manager.canUndo)
            manager.redo(); #expect(editor.timeline == after && !manager.canRedo)
            #expect(try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(after)) == after)
        }
    }

    @Test func repeatedInteriorCutsUseCollisionFreeDeterministicFragments() throws {
        let editor = fixture(), caption = animatedCaption(.smooth)
        editor.timeline.tracks[2].clips[0] = caption
        let cuts = [CaptionSpeechEdits.Range(start: 15, end: 25), .init(start: 45, end: 55)]
        func proposal() throws -> CaptionSpeechEdits.Plan {
            try CaptionSpeechEdits.prepare(timeline: editor.timeline, primaryTrackID: "audio", ranges: cuts,
                words: words, replacements: [caption.id: "Reviewed remainder"])
        }
        let initial = try proposal(), reserved = initial.changes[0].after[1].id
        editor.timeline.tracks.append(Track(id: "unrelated", type: .video, syncLocked: false,
            clips: [Clip(id: reserved, mediaRef: "text:unrelated", mediaType: .text, startFrame: 0, durationFrames: 90)]))
        let originalTrack = editor.timeline.tracks[3]
        let plan = try proposal(), fragments = plan.changes[0].after
        #expect(fragments.count == 3 && fragments[1].id != reserved)
        #expect(Set(fragments.map(\.id)).count == 3 && (try proposal()) == plan)
        guard case .ok = editor.rippleDeleteRangesOnTrack(trackIndex: 1,
            ranges: cuts.map { FrameRange(start: $0.start, end: $0.end) }, captionEdits: plan) else {
            Issue.record("A valid collision-free multi-cut caption split was refused"); return
        }
        #expect(editor.timeline.tracks[3] == originalTrack)
        for fragment in fragments {
            for frame in fragment.startFrame..<fragment.endFrame {
                let sourceFrame = frame < 15 ? frame : (frame < 35 ? frame + 10 : frame + 20)
                #expect(samples(fragment, frame: frame) == samples(caption, frame: sourceFrame))
            }
        }
    }

    @Test func identicalClipIDsOnOtherTracksAreNotDeletedOrMisinterpreted() throws {
        let editor = fixture()
        var untouched = editor.timeline.tracks[2].clips[0]
        untouched.textContent = "Unrelated locked-off caption"
        editor.timeline.tracks.append(Track(id: "unlocked", type: .video, syncLocked: false, clips: [untouched]))
        var shifted = editor.timeline.tracks[2].clips[1]
        shifted.captionGroupId = nil
        shifted.textContent = "An independent title with the same identity"
        editor.timeline.tracks.append(Track(id: "titles", type: .video, clips: [shifted]))
        let before = editor.timeline
        let manager = UndoManager(); manager.groupsByEvent = false; editor.undoManager = manager
        let plan = try prepare(editor)
        guard case .ok = editor.rippleDeleteRangesOnTrack(trackIndex: 1,
            ranges: [FrameRange(start: 30, end: 60)], captionEdits: plan) else {
            Issue.record("An unambiguous track-scoped caption edit was refused"); return
        }
        #expect(editor.timeline.tracks[3] == before.tracks[3])
        shifted.startFrame = 60
        #expect(editor.timeline.tracks[4].clips == [shifted])
        #expect(editor.timeline.tracks[2].clips == plan.changes.flatMap(\.after))
        let after = editor.timeline
        manager.undo(); #expect(editor.timeline == before)
        manager.redo(); #expect(editor.timeline == after)
    }

    @Test func automaticAlignedCaptionsWithSameIDOnDifferentTracksHaveSeparateSnapshots() throws {
        let editor = fixture()
        editor.timeline.tracks.append(Track(id: "second-captions", type: .video, clips: [editor.timeline.tracks[2].clips[0]]))
        let plan = try prepare(editor)
        #expect(plan.changes.map(\.trackID) == ["captions", "captions", "second-captions"])
        #expect(plan.changes[0].before.id == plan.changes[2].before.id)
        guard case .ok = editor.rippleDeleteRangesOnTrack(trackIndex: 1,
            ranges: [FrameRange(start: 30, end: 60)], captionEdits: plan) else {
            Issue.record("Aligned captions with distinct track identities were refused"); return
        }
        #expect(editor.timeline.tracks[2].clips == plan.changes[0].after + plan.changes[1].after)
        #expect(editor.timeline.tracks[3].clips == plan.changes[2].after)
    }

}
