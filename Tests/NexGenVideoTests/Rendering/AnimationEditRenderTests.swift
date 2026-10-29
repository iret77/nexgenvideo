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
        _ = editor.splitClip(clipId: original.id, atFrame: 38)
        let after = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(editor.timeline))
        for frame in [17, 47, 83] {
            let originalFrame = try await CompositorRenderTests.render(before, frame: frame, imageURLs: ["pattern": png])
            let editedFrame = try await CompositorRenderTests.render(after, frame: frame, imageURLs: ["pattern": png])
            #expect(originalFrame.bytes == editedFrame.bytes)
        }
        editor.timeline = before
        editor.trimClips([(original.id, 17, 13)])
        let trimmed = editor.timeline
        for frame in [21, 47, 83] {
            let originalFrame = try await CompositorRenderTests.render(before, frame: frame, imageURLs: ["pattern": png])
            let editedFrame = try await CompositorRenderTests.render(trimmed, frame: frame, imageURLs: ["pattern": png])
            #expect(originalFrame.bytes == editedFrame.bytes)
        }
    }
}
