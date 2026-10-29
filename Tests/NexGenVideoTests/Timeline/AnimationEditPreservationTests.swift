import AppKit
import AVFoundation
import Testing
@testable import NexGenVideo

@Suite("Clip edits retain interpolation support and exact undo")
@MainActor
struct AnimationEditPreservationTests {
    private func animated(_ interpolation: Interpolation, speed: Double = 1) -> Clip {
        func track<V: Codable & Sendable & Equatable>(_ first: V, _ last: V) -> KeyframeTrack<V> {
            KeyframeTrack(keyframes: [Keyframe(frame: 0, value: first, interpolationOut: interpolation),
                                     Keyframe(frame: 100, value: last, interpolationOut: .hold)])
        }
        var clip = Fixtures.clip(id: "animated", start: 25, duration: 100, trimStart: 40, trimEnd: 40, speed: speed)
        clip.opacityTrack = track(0.2, 0.9)
        clip.positionTrack = track(AnimPair(a: 0.1, b: 0.15), AnimPair(a: 0.2, b: 0.3))
        clip.scaleTrack = track(AnimPair(a: 0.7, b: 0.7), AnimPair(a: 0.8, b: 0.9))
        clip.rotationTrack = track(0.0, 30.0)
        clip.cropTrack = track(Crop(), Crop(left: 0.1, top: 0.05, right: 0.1, bottom: 0.05))
        clip.volumeTrack = track(-18.0, -2.0)
        clip.effects = [
            Effect(id: "exposure", type: "color.exposure", enabled: true,
                   params: ["ev": .init(value: 0, string: "unchanged", track: track(-0.4, 0.4))]),
            Effect(id: "temperature", type: "color.temperature", enabled: false,
                   params: ["temperature": .init(value: 5500, track: track(4700.0, 6500.0)),
                            "tint": .init(value: 0.1), "label": .init(string: "keep")]),
        ]
        return clip
    }

    private func samples(_ clip: Clip, at frame: Int) -> [Double] {
        let position = clip.topLeftAt(frame: frame), size = clip.sizeAt(frame: frame), crop = clip.cropAt(frame: frame)
        var values = [clip.opacityAt(frame: frame), position.x, position.y, size.width, size.height,
                      clip.rotationAt(frame: frame), crop.left, crop.top, crop.right, crop.bottom,
                      clip.volumeAt(frame: frame)]
        for effect in clip.effects ?? [] where effect.type != ClipAnimationEnvelope.effectType {
            for key in effect.params.keys.sorted() {
                if let parameter = effect.params[key], parameter.track != nil {
                    values.append(parameter.resolved(at: frame - clip.startFrame, default: 0))
                }
            }
        }
        return values
    }

    private func editor(_ clip: Clip) -> EditorViewModel {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        return editor
    }

    @Test(arguments: [Interpolation.hold, .linear, .smooth])
    func repeatedSplitMatchesEveryOriginalSampleAndRestoresExactly(_ interpolation: Interpolation) throws {
        let original = animated(interpolation)
        let editor = editor(original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let before = editor.timeline
        let right = try #require(editor.splitClip(clipId: original.id, atFrame: 63).first)
        _ = editor.splitClip(clipId: right, atFrame: 102)
        let after = editor.timeline
        #expect(after.tracks[0].clips.count == 3)
        for clip in after.tracks[0].clips {
            for frame in clip.startFrame..<clip.endFrame {
                #expect(samples(clip, at: frame) == samples(original, at: frame))
            }
            #expect(clip.keyframeFrames(for: .opacity).allSatisfy { clip.contains(timelineFrame: $0) })
            #expect(clip.allKeyframeFrames.allSatisfy { clip.contains(timelineFrame: $0) })
            #expect(clip.effects?.first { $0.id == "temperature" }?.enabled == false)
            #expect(clip.effects?.first { $0.id == "exposure" }?.params["ev"]?.string == "unchanged")
        }
        undo.undo()
        undo.undo()
        #expect(editor.timeline == before)
        undo.redo()
        undo.redo()
        #expect(editor.timeline == after)
        let reopened = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(after))
        #expect(reopened == after)
    }

    @Test(arguments: [Interpolation.hold, .linear, .smooth])
    func ordinarySourceTrimsAtFractionalSpeedKeepEverySurvivingSample(_ interpolation: Interpolation) {
        let original = animated(interpolation, speed: 1.5)
        let editor = editor(original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let before = editor.timeline
        editor.trimClips([(original.id, original.trimStartFrame + 30, original.trimEndFrame + 15)])
        let trimmed = editor.timeline.tracks[0].clips[0]
        #expect(trimmed.startFrame == original.startFrame + 20)
        #expect(trimmed.durationFrames == 70)
        for frame in trimmed.startFrame..<trimmed.endFrame {
            #expect(samples(trimmed, at: frame) == samples(original, at: frame))
        }
        #expect(trimmed.opacityTrack?.keyframes.map(\.frame) == [-20, 80])
        let after = editor.timeline
        undo.undo()
        #expect(editor.timeline == before)
        undo.redo()
        #expect(editor.timeline == after)
    }

    @Test(arguments: [Interpolation.hold, .linear, .smooth])
    func rippleLeftTrimKeepsOriginalClockWhileTimelineStartStaysFixed(_ interpolation: Interpolation) throws {
        let original = animated(interpolation)
        let editor = editor(original)
        _ = try #require(editor.rippleTrimClip(clipId: original.id, edge: .left, deltaFrames: 17, propagateToLinked: false))
        let trimmed = editor.timeline.tracks[0].clips[0]
        #expect(trimmed.startFrame == original.startFrame)
        for frame in trimmed.startFrame..<trimmed.endFrame {
            #expect(samples(trimmed, at: frame) == samples(original, at: frame + 17))
        }
    }

    @Test(arguments: [Interpolation.hold, .linear, .smooth])
    func overwriteRetainsAnimationInBothSurvivingFragments(_ interpolation: Interpolation) {
        let original = animated(interpolation)
        let editor = editor(original)
        editor.clearRegion(trackIndex: 0, start: 63, end: 82)
        #expect(editor.timeline.tracks[0].clips.count == 2)
        for clip in editor.timeline.tracks[0].clips {
            for frame in clip.startFrame..<clip.endFrame {
                #expect(samples(clip, at: frame) == samples(original, at: frame))
            }
        }
    }

    @Test func trimPreviewShortThenExtendAlwaysUsesUnmodifiedAnimationBasis() {
        var original = animated(.smooth)
        original.fadeOutFrames = 12
        let before = original
        let shortened = original.animationWindow(originOffset: 0, duration: 70)
        let extended = original.animationWindow(originOffset: 0, duration: 120, extendedEdges: [.right])
        #expect(original == before)
        #expect(shortened.durationFrames == 70)
        #expect(extended.fadeOutFrames == 12)
        #expect(extended.animationEnvelope.tail.anchor == 120)
        #expect(extended.opacityTrack == original.opacityTrack)
        #expect(extended.effects?.first { $0.id == "exposure" } == original.effects?.first { $0.id == "exposure" })
        #expect(extended.fadeMultiplier(at: extended.endFrame - 1) > 0)
    }

    @Test func speedDragReturnsToOriginalKeysEffectsAndFadesWithoutRoundingDrift() {
        var original = animated(.smooth)
        original.opacityTrack?.upsert(Keyframe(frame: 3, value: 0.25, interpolationOut: .linear))
        original.effects?[0].params["ev"]?.track?.upsert(Keyframe(frame: 3, value: -0.2, interpolationOut: .hold))
        original.fadeInFrames = 13
        original.fadeOutFrames = 17
        let editor = editor(original)
        let before = editor.timeline
        editor.applyClipSpeed(clipId: original.id, newSpeed: 2)
        editor.applyClipSpeed(clipId: original.id, newSpeed: 0.5)
        editor.applyClipSpeed(clipId: original.id, newSpeed: 1)
        #expect(editor.timeline == before)
        editor.commitClipSpeed(ids: [original.id], newSpeed: 1)
        #expect(editor.timeline == before)
    }

    @Test func fpsCollisionUndoRestoresEveryKeyAndBothPlayheads() {
        var original = animated(.linear)
        original.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 1, value: 0.2), Keyframe(frame: 2, value: 0.8)])
        original.effects?[0].params["ev"]?.track = KeyframeTrack(keyframes: [Keyframe(frame: 1, value: 1), Keyframe(frame: 2, value: 2)])
        let editor = editor(original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        editor.currentFrame = 17
        editor.sourcePlayheadFrame = 9
        let before = editor.timeline
        editor.applyTimelineSettings(fps: 15, width: 1920, height: 1080)
        #expect(editor.timeline.tracks[0].clips[0].opacityTrack?.keyframes.map(\.frame) == [1])
        #expect(editor.timeline.tracks[0].clips[0].effects?[0].params["ev"]?.track?.keyframes.map(\.frame) == [1])
        let after = editor.timeline
        undo.undo()
        #expect(editor.timeline == before)
        #expect(editor.currentFrame == 17)
        #expect(editor.sourcePlayheadFrame == 9)
        undo.redo()
        #expect(editor.timeline == after)
    }

    @Test(arguments: [Interpolation.hold, .linear])
    func valueEditKeepsExistingInterpolationAndRejectsSupportKeys(_ interpolation: Interpolation) {
        var clip = animated(interpolation)
        clip.upsertKeyframe(in: \.opacityTrack, frame: clip.startFrame, value: 0.4)
        #expect(clip.opacityTrack?.keyframes[0].interpolationOut == interpolation)
        let before = clip
        clip.upsertKeyframe(in: \.opacityTrack, frame: clip.endFrame, value: 0.5)
        clip.upsertKeyframe(in: \.opacityTrack, frame: clip.startFrame - 1, value: 0.5)
        #expect(clip == before)
        clip.rebaseKeyframes(by: -25)
        clip.startFrame += 25
        clip.setDuration(75)
        #expect(clip.keyframeFrames(for: .opacity).isEmpty)
        #expect(clip.exportKeyframeFrames(for: .opacity) == [clip.startFrame, clip.endFrame])
        #expect(InspectorKeyframeTarget.effect(type: "color.exposure", key: "ev").frames(in: clip).isEmpty)
    }
}
