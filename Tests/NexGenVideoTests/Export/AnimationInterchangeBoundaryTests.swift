import Foundation
import Testing
@testable import NexGenVideo

@Suite("Animation interchange samples legal clip boundaries")
@MainActor
struct AnimationInterchangeBoundaryTests {
    @Test func xmlExportsRetainedFadeSamplesAndReportsApproximation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("source.mov")
        try Data().write(to: media)
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "source", name: "Source", type: .video,
                                               source: .external(absolutePath: media.path), duration: 10)]
        let snapshot = manifest
        let resolver = MediaResolver(manifest: { snapshot }, projectURL: { nil })
        var original = Fixtures.clip(id: "clip", mediaRef: "source", start: 0, duration: 100)
        original.fadeInFrames = 60
        original.fadeInInterpolation = .smooth
        original.opacityTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: 0.2, interpolationOut: .linear),
                                                         Keyframe(frame: 100, value: 0.8)])
        var fragment = original.animationWindow(originOffset: 23, duration: 37)
        fragment.startFrame = 23
        fragment.trimStartFrame = 23
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [fragment])])
        let out = root.appendingPathComponent("edited.xml")
        try XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: out)
        let document = try XMLDocument(contentsOf: out)
        #expect(try document.nodes(forXPath: "//transitionitem").isEmpty)
        let whens = try document.nodes(forXPath: "//keyframe/when").compactMap { Int($0.stringValue ?? "") }
        #expect(!whens.isEmpty)
        #expect(whens.allSatisfy { $0 >= 0 && $0 <= 37 })
        let values = try document.nodes(forXPath: "//parameter[parameterid='opacity']/keyframe/value")
        let first = try #require(Double(values.first?.stringValue ?? ""))
        #expect(abs(first - original.opacityAt(frame: 23) * 100) <= 0.06)
        #expect(XMLExporter.limitationSummary(timeline: timeline).contains { $0.contains("Retained fade") })
        let rendered = try FCPXMLExporter.render(timeline: timeline, resolver: resolver)
        #expect(rendered.warnings.contains { $0.code == "fades_not_exported" })
    }
}
