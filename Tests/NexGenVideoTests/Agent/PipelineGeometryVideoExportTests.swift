import AVFoundation
import CoreGraphics
import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Geometry clips keep pixels and timing without source audio or private metadata")
struct PipelineGeometryVideoExportTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-video-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func image(_ asset: AVAsset, at time: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        defer { withExtendedLifetime(generator) {} }
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: ToolError("The geometry frame could not be decoded.")) }
            }
        }
        return image
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data)
        return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    @Test func realRotatedClipLosesAudioAndIdentifyingMetadataButKeepsTheSelectedPictures() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let asset = AVURLAsset(url: fixture)
        let visual = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let videoTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let full = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        try videoTrack.insertTimeRange(full, of: visual, at: .zero)
        try audioTrack.insertTimeRange(full, of: audio, at: .zero)
        videoTrack.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0)
        let marker = "Private source marker " + UUID().uuidString
        let metadata = AVMutableMetadataItem()
        metadata.identifier = .commonIdentifierDescription
        metadata.value = marker as NSString
        let source = root.appendingPathComponent("source.mov")
        let sourceExport = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        sourceExport.metadata = [metadata]
        try await sourceExport.export(to: source, as: .mov)
        let sourceAsset = AVURLAsset(url: source)
        let sourceMetadata = try await sourceAsset.load(.metadata)
        var sourceHasMarker = false
        for item in sourceMetadata {
            if try await item.load(.stringValue) == marker { sourceHasMarker = true }
        }
        #expect(sourceHasMarker)
        #expect(!(try await sourceAsset.loadTracks(withMediaType: .audio)).isEmpty)
        let sourceHash = try FileDigest.sha256(of: source)
        let original = root.appendingPathComponent("original.mov")
        try PipelineGeometryVideoExport.copyVerified(source: source, to: original, expectedSHA256: sourceHash)
        let range = CMTimeRange(start: CMTime(value: 600, timescale: 600), duration: CMTime(value: 1200, timescale: 600))
        let result = root.appendingPathComponent("geometry.mov")
        let measured = try await PipelineGeometryVideoExport.export(source: original, range: range, to: result)
        #expect(CMTimeCompare(measured, range.duration) == 0)
        let geometry = AVURLAsset(url: result)
        #expect((try await geometry.loadTracks(withMediaType: .audio)).isEmpty)
        #expect((try await geometry.loadTracks(withMediaType: .metadata)).isEmpty)
        for item in try await geometry.load(.metadata) { #expect(try await item.load(.stringValue) != marker) }
        let before = try await image(sourceAsset, at: range.start)
        let after = try await image(geometry, at: .zero)
        #expect(before.width == 90 && before.height == 160)
        #expect(after.width == before.width && after.height == before.height)
        let a = try pixels(before), b = try pixels(after)
        try #require(a.count == b.count)
        let meanError = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) / 255
        #expect(meanError < 0.035)
        #expect(try FileDigest.sha256(of: source) == sourceHash)
        #expect(try FileDigest.sha256(of: original) == sourceHash)
        let ordinary = root.appendingPathComponent("ordinary-source.mov")
        _ = try await PipelineProductionInputMedia.exportRange(source: source, range: range, modality: .video, to: ordinary)
        #expect(!(try await AVURLAsset(url: ordinary).loadTracks(withMediaType: .audio)).isEmpty)
        await #expect(throws: GateBlocked.self) {
            _ = try await PipelineGeometryVideoExport.export(source: original,
                range: CMTimeRange(start: CMTime(value: 7, timescale: 1), duration: CMTime(value: 2, timescale: 1)),
                to: root.appendingPathComponent("outside.mov"))
        }
        let fractionalRange = CMTimeRange(start: CMTime(value: 90_000, timescale: 90_000),
            duration: CMTime(value: 180_181, timescale: 90_000))
        let fractional = try await PipelineGeometryVideoExport.export(source: original, range: fractionalRange,
            to: root.appendingPathComponent("fractional.mov"))
        #expect(abs(fractional.seconds - fractionalRange.duration.seconds) <= 1.0 / Double(fractional.timescale))
    }

    @Test func inspectionUsesTheVideoIntervalWhenTheSoundtrackExtendsBeyondIt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await ProductionPlanningAcceptanceFixture.makeSourceVideo()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let asset = AVURLAsset(url: fixture)
        let visual = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let videoTrack = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let audioTrack = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1)),
            of: visual, at: CMTime(value: 1, timescale: 1))
        try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 8, timescale: 1)), of: audio, at: .zero)
        let source = root.appendingPathComponent("short-video-long-audio.mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: source, as: .mov)
        let saved = AVURLAsset(url: source)
        let savedTrack = try #require(try await saved.loadTracks(withMediaType: .video).first)
        let actual = try await savedTrack.load(.timeRange)
        let inspected = try await PipelineNativeBlockoutStore.inspect(source)
        #expect(CMTimeCompare(inspected.videoRange.start, actual.start) == 0)
        #expect(CMTimeCompare(inspected.videoRange.end, actual.end) == 0)
        #expect(CMTimeCompare(inspected.videoRange.end, try await saved.load(.duration)) < 0)
    }

    @Test func streamedCopyChecksEveryChunkAndCannotOverwriteOrPublishAfterCancellation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let bytes = Data((0..<(5 * 1_048_576 + 71)).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: source)
        let hash = FileDigest.sha256(of: bytes)
        let copied = root.appendingPathComponent("copy.bin")
        try PipelineGeometryVideoExport.copyVerified(source: source, to: copied, expectedSHA256: hash)
        #expect(try FileDigest.sha256(of: copied) == hash)
        #expect(throws: GateBlocked.self) {
            try PipelineGeometryVideoExport.copyVerified(source: source, to: copied, expectedSHA256: hash)
        }
        #expect(try FileDigest.sha256(of: copied) == hash)
        let rejected = root.appendingPathComponent("rejected.bin")
        #expect(throws: GateBlocked.self) {
            try PipelineGeometryVideoExport.copyVerified(source: source, to: rejected, expectedSHA256: String(repeating: "0", count: 64))
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
        let cancelled = root.appendingPathComponent("cancelled.bin")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try PipelineGeometryVideoExport.copyVerified(source: source, to: cancelled, expectedSHA256: hash)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        let link = root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: GateBlocked.self) {
            try PipelineGeometryVideoExport.copyVerified(source: link, to: rejected, expectedSHA256: hash)
        }
        #expect(!FileManager.default.fileExists(atPath: rejected.path))
    }
}
