import AVFoundation
import CryptoKit
import Darwin
import Foundation
import NexGenEngine

enum PipelineGeometryVideoExport {
    private final class Cancellation: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
        func cancel() { session.cancelExport() }
    }

    static func export(source: URL, range: CMTimeRange, to destination: URL) async throws -> CMTime {
        try Task.checkCancellation()
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
              CMTimeCompare(range.start, .zero) >= 0, CMTimeCompare(range.duration, .zero) > 0 else { throw invalid() }
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let sourceTrack = tracks.first else {
            throw GateBlocked("Choose a blockout with one continuous video track.")
        }
        let actual = try await sourceTrack.load(.timeRange)
        guard CMTimeCompare(range.start, actual.start) >= 0, CMTimeCompare(range.end, actual.end) <= 0 else { throw invalid() }
        var coveredUntil = range.start
        for segment in try await sourceTrack.load(.segments) where !segment.isEmpty {
            let covered = CMTimeRangeGetIntersection(segment.timeMapping.target, range)
            guard covered.isValid, CMTimeCompare(covered.duration, .zero) > 0 else { continue }
            guard CMTimeCompare(covered.start, coveredUntil) <= 0 else { throw invalid() }
            if CMTimeCompare(covered.end, coveredUntil) > 0 { coveredUntil = covered.end }
        }
        guard CMTimeCompare(coveredUntil, range.end) >= 0 else { throw invalid() }
        let transform = try await sourceTrack.load(.preferredTransform)
        try Task.checkCancellation()
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw invalid() }
        try video.insertTimeRange(range, of: sourceTrack, at: .zero)
        video.preferredTransform = transform
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw invalid() }
        session.timeRange = CMTimeRange(start: .zero, duration: range.duration)
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        let cancellation = Cancellation(session)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await session.export(to: destination, as: .mov)
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        let output = AVURLAsset(url: destination)
        let duration = try await output.load(.duration)
        let outputTracks = try await output.load(.tracks)
        guard duration.isNumeric, duration.value > 0, !outputTracks.isEmpty,
              outputTracks.allSatisfy({ $0.mediaType == .video }),
              CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(duration, range.duration)),
                CMTimeMaximum(CMTime(value: 1, timescale: range.duration.timescale),
                    CMTime(value: 1, timescale: duration.timescale))) <= 0 else { throw invalid() }
        _ = try await AVAssetImageGenerator(asset: output).image(at: .zero)
        try Task.checkCancellation()
        return duration
    }

    static func copyVerified(source: URL, to destination: URL, expectedSHA256: String) throws {
        try Task.checkCancellation()
        let sourceFD = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw invalid() }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? input.close() }
        var attributes = stat()
        guard fstat(sourceFD, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { throw invalid() }
        let outputFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard outputFD >= 0 else { throw invalid() }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }
        var digest = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
            try output.write(contentsOf: bytes)
        }
        try Task.checkCancellation()
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == expectedSHA256 else { throw invalid() }
        try output.synchronize()
        complete = true
    }

    private static func invalid() -> GateBlocked {
        GateBlocked("The blockout source or selected range changed. Inspect the current video and attach it again.")
    }
}
