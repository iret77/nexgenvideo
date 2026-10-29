import Foundation
import AVFoundation
import CoreGraphics
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Saved clip and range publication")
struct MediaSaveTransactionTests {
    @Test(arguments: ["project", "delete", "source"])
    func changedDestinationOrSourceDoesNotPublish(reason: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedMedia-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("Original.ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel(); editor.projectURL = package
        defer { editor.releaseWorkingCopy() }
        let source = directory.appendingPathComponent("Original.mp4")
        let bytes = Data("source bytes before rendering".utf8)
        try bytes.write(to: source)
        let asset = MediaAsset(url: source, type: .video, name: "Original", duration: 4)
        editor.importMediaAsset(asset)
        let clip = Fixtures.clip(mediaRef: asset.id, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])
        let before = editor.timeline
        let other = directory.appendingPathComponent("Other.ngv")
        try Fixtures.prepareProjectPackage(at: other)
        let rendered = directory.appendingPathComponent("Rendered.mp4")
        let task = try #require(editor.saveAsMedia(source: before, name: "Saved range", type: .video) { captured, resolver in
            #expect(captured == before)
            let frozen = try #require(resolver.resolveURL(for: asset.id))
            #expect(frozen != source && (try Data(contentsOf: frozen)) == bytes)
            try Data("rendered bytes".utf8).write(to: rendered)
            switch reason {
            case "project": editor.projectURL = other
            case "delete":
                let ids = Set(editor.mediaAssets.filter { $0.id != asset.id }.map(\.id))
                editor.deleteMediaAssets(ids: ids)
            default: try Data("different source bytes".utf8).write(to: source)
            }
            return rendered
        })
        let placeholder = try #require(editor.mediaAssets.first { $0.id != asset.id })
        await task.value
        #expect(!FileManager.default.fileExists(atPath: placeholder.url.path))
        #expect(!FileManager.default.fileExists(atPath: rendered.path))
        #expect(editor.timeline == before)
        if reason == "source" {
            guard case .failed = placeholder.generationStatus else {
                Issue.record("Source mutation must fail the saved-media job")
                return
            }
        } else {
            #expect(placeholder.generationStatus == .rendering)
            if reason == "delete" { #expect(!editor.mediaAssets.contains { $0 === placeholder }) }
        }
    }

    @Test(arguments: [(15, 60), (40, 55)])
    func rangeIgnoresOfflineSourcesOutsideSelectionAndPreservesBlackEnd(start: Int, end: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SavedRange-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("Range.ngv")
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel(); editor.projectURL = package
        defer { editor.releaseWorkingCopy() }
        let video = try await FixtureVideo.write(scenes: [.init(rgb: (255, 0, 0), seconds: 2)], fps: 30, size: 64)
        defer { try? FileManager.default.removeItem(at: video) }
        let asset = MediaAsset(url: video, type: .video, name: "Picture", duration: 2)
        editor.importMediaAsset(asset)
        editor.timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "picture", mediaRef: asset.id, start: 0, duration: 30),
            Fixtures.clip(id: "offline", mediaRef: "missing", start: 90, duration: 30)
        ])])
        editor.timeline.width = 64; editor.timeline.height = 64
        let before = editor.timeline
        editor.selectedTimelineRange = TimelineRangeSelection(startFrame: start, endFrame: end)
        let task = try #require(editor.saveTimelineRangeAsMedia())
        let saved = try #require(editor.mediaAssets.first { $0.id != asset.id })
        await task.value
        #expect(saved.generationStatus == .none)
        #expect(editor.timeline == before)
        let output = AVURLAsset(url: saved.url)
        let duration = try await output.load(.duration)
        #expect(Int((duration.seconds * 30).rounded()) == end - start)
        let generator = AVAssetImageGenerator(asset: output)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let last = try await generator.image(at: CMTime(value: Int64(end - start - 1), timescale: 30)).image
        var pixel = [UInt8](repeating: 255, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(last, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        #expect(pixel[0] < 8 && pixel[1] < 8 && pixel[2] < 8)
    }
}
