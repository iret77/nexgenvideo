import Foundation
import Testing
@testable import NexGenVideo

@Suite("Split and trim preserve actual composited frames")
@MainActor
struct AnimationEditRenderTests {
    @Test func splitInsideSmoothFadeAndEffectsProducesIdenticalPixels() async throws {
        let png = try CompositorFixtures.midtonePNG(size: CompositorFixtures.renderSize)
        var original = Fixtures.clip(id: "animated", mediaRef: "pattern", mediaType: .image, start: 0, duration: 100)
        original.fadeInFrames = 60
        original.fadeInInterpolation = .smooth
        original.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: 0.4), Keyframe(frame: 100, value: 0.9)])
        original.rotationTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: -5), Keyframe(frame: 100, value: 15)])
        original.scaleTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: AnimPair(a: 0.75, b: 0.75)),
                                                       Keyframe(frame: 100, value: AnimPair(a: 0.9, b: 0.9))])
        original.cropTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: Crop()),
                                                      Keyframe(frame: 100, value: Crop(left: 0.1, top: 0.05, right: 0, bottom: 0))])
        original.effects = [Effect(type: "color.exposure", params: ["ev": .init(track: KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: -0.3), Keyframe(frame: 100, value: 0.3),
        ]))])]
        let editor = EditorViewModel()
        editor.timeline = CompositorFixtures.timeline([Fixtures.videoTrack(clips: [original])])
        let before = editor.timeline
        let rightIDs = editor.splitClip(clipId: original.id, atFrame: 38)
        #expect(rightIDs.count == 1)
        let after = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(editor.timeline))
        let split = after.tracks[0].clips
        #expect(split.count == 2)
        #expect(split.map(\.id) == [original.id] + rightIDs)
        #expect(split.map(\.startFrame) == [0, 38])
        #expect(split.map(\.durationFrames) == [38, 62])
        #expect(after != before)
        for frame in [17, 47, 83] {
            let originalFrame = try await CompositorRenderTests.render(before, frame: frame, imageURLs: ["pattern": png])
            let editedFrame = try await CompositorRenderTests.render(after, frame: frame, imageURLs: ["pattern": png])
            #expect(originalFrame.bytes == editedFrame.bytes)
        }
        editor.timeline = before
        editor.trimClips([(original.id, 17, 13)])
        let trimmed = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(editor.timeline))
        #expect(trimmed.tracks[0].clips.count == 1)
        let remaining = try #require(trimmed.tracks[0].clips.first)
        #expect(remaining.id == original.id && remaining.startFrame == 17 && remaining.durationFrames == 70)
        #expect(remaining.trimStartFrame == 17 && remaining.trimEndFrame == 13)
        #expect(trimmed != before)
        for frame in [21, 47, 83] {
            let originalFrame = try await CompositorRenderTests.render(before, frame: frame, imageURLs: ["pattern": png])
            let editedFrame = try await CompositorRenderTests.render(trimmed, frame: frame, imageURLs: ["pattern": png])
            #expect(originalFrame.bytes == editedFrame.bytes)
        }
    }
}
