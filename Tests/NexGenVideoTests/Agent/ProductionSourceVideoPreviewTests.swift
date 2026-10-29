import AVFoundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Source inspection uses the selected video interval")
@MainActor
struct ProductionSourceVideoPreviewTests {
    @Test func trimmedPreviewStartsAtChosenSceneAndPreservesPortraitTransform() async throws {
        let transform = CGAffineTransform(translationX: 160, y: 0).rotated(by: .pi / 2)
        let url = try await FixtureVideo.write(scenes: [
            .init(rgb: (255, 0, 0), seconds: 2), .init(rgb: (0, 0, 255), seconds: 2),
        ], fps: 10, size: 160, transform: transform)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = AVURLAsset(url: url)
        let range = ProductionInputRange(timebase: .init(ticksPerSecond: 600, fpsNumerator: 30), startTicks: 1200, durationTicks: 600)
        let preview = try await ProductionSourceVideoPreview.asset(source: source, range: range)
        #expect(CMTimeCompare(preview.duration, CMTime(value: 1, timescale: 1)) == 0)
        let originalTrack = try #require(try await source.loadTracks(withMediaType: .video).first)
        let previewTrack = try #require(preview.tracks(withMediaType: .video).first)
        let originalTransform = try await originalTrack.load(.preferredTransform)
        #expect(!originalTransform.isIdentity)
        #expect(previewTrack.preferredTransform == originalTransform)
        let thumbnail = try await ProductionSourceVideoPreview.thumbnail(source: source, range: range)
        let thumbnailPixel = try rgb(thumbnail)
        #expect(thumbnailPixel[2] > 200)
        #expect(thumbnailPixel[0] < 50)
        let generator = AVAssetImageGenerator(asset: preview)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { withExtendedLifetime(generator) {} }
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: ToolError("The preview frame could not be decoded.")) }
            }
        }
        let pixel = try rgb(image)
        #expect(pixel[2] > 200)
        #expect(pixel[0] < 50)
    }

    @Test func outOfSourceRangeAndChangedSourceBytesAreRejected() async throws {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (0, 0, 255), seconds: 1)], fps: 10, size: 160)
        defer { try? FileManager.default.removeItem(at: url) }
        let timebase = RationalTimebaseV1(ticksPerSecond: 600, fpsNumerator: 30)
        let tooLong = ProductionInputRange(timebase: timebase, startTicks: 300, durationTicks: 600)
        await #expect(throws: (any Error).self) {
            _ = try await ProductionSourceVideoPreview.asset(source: AVURLAsset(url: url), range: tooLong)
        }
        let hash = try FileDigest.sha256(of: url)
        let reference = CanonicalArtifactReferenceV1(id: "source", role: "core.source-footage", path: url.lastPathComponent, sha256: hash)
        let valid = SourceFootageRangeV1(source: reference, timebase: timebase, startTicks: 0, durationTicks: 300)
        try await PipelineShotPlanningEditor.requireReadableRange(valid, dataRoot: url.deletingLastPathComponent())
        let replacement = try await FixtureVideo.write(scenes: [.init(rgb: (255, 0, 0), seconds: 1)], fps: 10, size: 160)
        defer { try? FileManager.default.removeItem(at: replacement) }
        try Data(contentsOf: replacement).write(to: url)
        await #expect(throws: (any Error).self) {
            try await PipelineShotPlanningEditor.requireReadableRange(valid, dataRoot: url.deletingLastPathComponent())
        }
        let current = CanonicalArtifactReferenceV1(id: reference.id, role: reference.role, path: reference.path,
            sha256: try FileDigest.sha256(of: url))
        try await PipelineShotPlanningEditor.requireReadableRange(
            .init(source: current, timebase: timebase, startTicks: 0, durationTicks: 300), dataRoot: url.deletingLastPathComponent())
    }

    private func rgb(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        #expect(drawn)
        return bytes
    }
}
