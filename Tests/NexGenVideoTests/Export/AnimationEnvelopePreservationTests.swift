import AVFoundation
import Foundation
import Testing
@testable import NexGenVideo

@Suite("Edited audio preserves actual gain ramps")
@MainActor
struct AnimationEnvelopePreservationTests {
    private func gain(_ ramps: [CompositionBuilder.AudioEnvelopeRamp], at offset: Double) -> Double {
        guard let ramp = ramps.first(where: { offset >= Double($0.startOffset) && offset <= Double($0.endOffset) }) else {
            Issue.record("No audio ramp covers offset \(offset)")
            return -.infinity
        }
        let t = (offset - Double(ramp.startOffset)) / Double(ramp.endOffset - ramp.startOffset)
        return Double(ramp.startGain) + (Double(ramp.endGain) - Double(ramp.startGain)) * t
    }

    private func editor(_ clip: Clip) -> EditorViewModel {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        return editor
    }

    @Test(arguments: [Interpolation.hold, .linear, .smooth])
    func splitInsideFadeAndVolumeSegmentPreservesActualSubframeGain(_ interpolation: Interpolation) throws {
        var original = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 100, trimStart: 40, trimEnd: 40)
        original.volumeTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: -55, interpolationOut: interpolation),
            Keyframe(frame: 100, value: 12),
        ])
        original.fadeInFrames = 40
        original.fadeOutFrames = 40
        original.fadeInInterpolation = interpolation
        original.fadeOutInterpolation = interpolation
        let originalRamps = CompositionBuilder.audioEnvelopeRamps(for: original)
        let editor = editor(original)
        let rightID = try #require(editor.splitClip(clipId: original.id, atFrame: 23).first)
        _ = editor.splitClip(clipId: rightID, atFrame: 77)
        for clip in editor.timeline.tracks[0].clips {
            let ramps = CompositionBuilder.audioEnvelopeRamps(for: clip)
            for quarterFrame in 0...(clip.durationFrames * 4) {
                let local = Double(quarterFrame) / 4
                let before = gain(originalRamps, at: Double(clip.startFrame) + local)
                let after = gain(ramps, at: local)
                #expect(abs(before - after) <= 0.000002)
            }
            for frame in clip.startFrame..<clip.endFrame {
                #expect(clip.volumeAt(frame: frame) == original.volumeAt(frame: frame))
            }
            let reopened = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
            #expect(CompositionBuilder.audioEnvelopeRamps(for: reopened) == ramps)
        }
    }

    @Test func newCutBoundaryUsesEmittedRampRatherThanRawSmoothCurve() throws {
        var original = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 100)
        original.volumeTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0, interpolationOut: .smooth),
            Keyframe(frame: 100, value: -20),
        ])
        let editor = editor(original)
        _ = editor.splitClip(clipId: original.id, atFrame: 60)
        let right = try #require(editor.timeline.tracks[0].clips.first { $0.startFrame == 60 })
        let first = try #require(CompositionBuilder.audioEnvelopeRamps(for: right).first)
        let gain50 = Float(pow(10, -10.0 / 20))
        let smooth63 = 0.63 * 0.63 * (3 - 2 * 0.63)
        let gain63 = Float(pow(10, (-20 * smooth63) / 20))
        let expected = gain50 + (gain63 - gain50) * Float(10.0 / 13)
        #expect(abs(first.startGain - expected) < 0.0000002)
        #expect(abs(Double(first.startGain) - original.rawVolumeAt(frame: 60)) > 0.0001)
    }

    @Test(arguments: [Interpolation.hold, .linear, .smooth])
    func shorteningRetainsFadeWhileExtensionReanchorsOnlyEditedEdge(_ interpolation: Interpolation) throws {
        var original = Fixtures.clip(id: "audio", mediaType: .audio, start: 20, duration: 100, trimStart: 40, trimEnd: 40)
        original.fadeInFrames = 20
        original.fadeOutFrames = 20
        original.fadeInInterpolation = interpolation
        original.fadeOutInterpolation = interpolation
        let editor = editor(original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        let before = editor.timeline
        editor.trimClips([(original.id, original.trimStartFrame + 9, original.trimEndFrame + 9)])
        let shortened = editor.timeline.tracks[0].clips[0]
        #expect(shortened.hasRetainedFade)
        for frame in shortened.startFrame..<shortened.endFrame {
            #expect(shortened.volumeAt(frame: frame) == original.volumeAt(frame: frame))
        }
        let after = editor.timeline
        undo.undo()
        #expect(editor.timeline == before)
        editor.trimClips([(original.id, original.trimStartFrame, original.trimEndFrame - 10)])
        let extended = editor.timeline.tracks[0].clips[0]
        #expect(extended.durationFrames == 110)
        #expect(extended.fadeOutFrames == 20)
        #expect(extended.animationEnvelope.tail.anchor == 110)
        #expect(extended.animationEnvelope.head == original.animationEnvelope.head)
        #expect(extended.volumeAt(frame: extended.endFrame - 1) > 0)
        undo.undo()
        #expect(editor.timeline == before)
        undo.redo()
        #expect(editor.timeline.tracks[0].clips[0] == extended)
        #expect(after != before)
    }

    @Test func leftExtensionReanchorsHeadAndPreservesTranslatedTail() {
        var original = Fixtures.clip(id: "audio", mediaType: .audio, start: 20, duration: 100, trimStart: 40, trimEnd: 40)
        original.fadeInFrames = 20
        original.fadeOutFrames = 12
        let editor = editor(original)
        editor.trimClips([(original.id, 30, 40)])
        let extended = editor.timeline.tracks[0].clips[0]
        #expect(extended.startFrame == 10)
        #expect(extended.durationFrames == 110)
        #expect(extended.fadeInFrames == 20)
        #expect(extended.fadeOutFrames == 12)
        #expect(extended.animationEnvelope.tail.anchor == 110)
        #expect(extended.volumeAt(frame: original.endFrame - 5) == original.volumeAt(frame: original.endFrame - 5))
    }

    @Test func nativeFadeEditAndResetKeepUnrelatedEffectsAndAutomation() throws {
        var original = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 100)
        original.fadeInFrames = 40
        original.volumeTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: -6), Keyframe(frame: 100, value: 0)])
        original.effects = [Effect(id: "unchanged", type: "color.exposure", params: ["ev": .init(value: 0.2)])]
        let editor = editor(original)
        let rightID = try #require(editor.splitClip(clipId: original.id, atFrame: 20).first)
        var right = try #require(editor.timeline.tracks[0].clips.first { $0.id == rightID })
        let keys = right.volumeTrack
        right.setFade(.left, frames: 10)
        right.setFadeInterpolation(.left, .smooth)
        #expect(right.animationEnvelope.head.anchor == 0)
        #expect(right.animationEnvelope.head.length == 10)
        #expect(right.fadeMultiplier(at: right.startFrame) == 0)
        right.resetFades()
        #expect(right.volumeTrack == keys)
        #expect(right.fadeMultiplier(at: right.startFrame) == 1)
        #expect(right.effects?.first { $0.id == "unchanged" } == original.effects?.first)
        #expect(EffectRegistry.descriptor(id: ClipAnimationEnvelope.effectType) == nil)
    }

    @Test func actualAVAudioMixRampsKeepTheSameGainAcrossSplit() async throws {
        let url = AVFoundationAudioDecoderTests.tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AVFoundationAudioDecoderTests.writeTone(to: url, seconds: 8, sr: 44_100, channels: 1)
        var original = Fixtures.clip(id: "audio", mediaType: .audio, start: 0, duration: 100)
        original.volumeTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: -18), Keyframe(frame: 100, value: 0)])
        original.fadeInFrames = 40
        original.fadeOutFrames = 40
        original.fadeInInterpolation = .smooth
        original.fadeOutInterpolation = .smooth
        let editor = editor(original)
        let before = editor.timeline
        let right = try #require(editor.splitClip(clipId: original.id, atFrame: 23).first)
        _ = editor.splitClip(clipId: right, atFrame: 77)
        let after = editor.timeline
        let beforeComposition = try await CompositionBuilder.build(timeline: before, resolveURL: { _ in url },
                                                                    renderSize: CGSize(width: 320, height: 180))
        let afterComposition = try await CompositionBuilder.build(timeline: after, resolveURL: { _ in url },
                                                                   renderSize: CGSize(width: 320, height: 180))
        let beforeParameters = try #require(beforeComposition.audioMix.inputParameters.first)
        let afterParameters = try #require(afterComposition.audioMix.inputParameters.first)
        func actualGain(_ parameters: AVAudioMixInputParameters, at time: CMTime) throws -> Double {
            var start: Float = 0, end: Float = 0
            var range = CMTimeRange()
            try #require(parameters.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range))
            let fraction = CMTimeSubtract(time, range.start).seconds / range.duration.seconds
            return Double(start) + (Double(end) - Double(start)) * fraction
        }
        for quarterFrame in 0..<400 {
            let time = CMTime(value: CMTimeValue(quarterFrame), timescale: CMTimeScale(before.fps * 4))
            let a = try actualGain(beforeParameters, at: time)
            let b = try actualGain(afterParameters, at: time)
            #expect(abs(a - b) <= 0.000002)
        }
    }

    @Test func malformedCarrierCannotSilentlyLoseItsEnvelopeOnReopen() throws {
        var clip = Fixtures.clip(start: 0, duration: 100)
        clip.effects = [Effect(type: ClipAnimationEnvelope.effectType, params: ["definition": .init(string: "invalid")])]
        let data = try JSONEncoder().encode(clip)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Clip.self, from: data) }
    }
}
