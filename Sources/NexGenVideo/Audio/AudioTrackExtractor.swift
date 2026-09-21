import AVFoundation
import Foundation

struct AudioTrackDescriptor: Identifiable, Sendable, Equatable {
    let id: Int
    let number: Int
    let channelCount: Int?

    var label: String {
        let layout = switch channelCount {
        case 1: "Mono"
        case 2: "Stereo"
        case let count?: "\(count) channels"
        case nil: "Audio"
        }
        return "Track \(number) (\(layout))"
    }
}

struct AudioTrackExtractionClient: Sendable {
    var tracks: @Sendable (URL) async throws -> [AudioTrackDescriptor]
    var extract: @Sendable (URL, Int, URL) async throws -> Void

    static let live = AudioTrackExtractionClient(
        tracks: { try await AudioTrackExtractor.tracks(sourceURL: $0) },
        extract: {
            try await AudioTrackExtractor.extract(
                sourceURL: $0,
                trackIndex: $1,
                destinationURL: $2
            )
        }
    )
}

enum AudioTrackExtractor {
    struct ExtractionError: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { "Audio extraction failed: \(reason)" }
    }

    static func tracks(sourceURL: URL) async throws -> [AudioTrackDescriptor] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try Task.checkCancellation()
        var descriptors: [AudioTrackDescriptor] = []
        for (index, track) in audioTracks.enumerated() {
            try Task.checkCancellation()
            let description = try? await track.load(.formatDescriptions).first
            let channels = description.flatMap { description in
                CMAudioFormatDescriptionGetStreamBasicDescription(description)
                    .map { Int($0.pointee.mChannelsPerFrame) }
            }
            descriptors.append(AudioTrackDescriptor(
                id: index,
                number: index + 1,
                channelCount: channels
            ))
        }
        return descriptors
    }

    static func extract(
        sourceURL: URL,
        trackIndex: Int,
        destinationURL: URL
    ) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.indices.contains(trackIndex) else {
            throw ExtractionError(reason: "the selected audio track is no longer available")
        }
        let audioTrack = audioTracks[trackIndex]
        let timeRange = try await audioTrack.load(.timeRange)
        guard timeRange.duration.isNumeric, timeRange.duration > .zero else {
            throw ExtractionError(reason: "the selected audio track is empty")
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExtractionError(reason: "an audio composition couldn't be created")
        }
        try compositionTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExtractionError(reason: "M4A export is unavailable")
        }
        nonisolated(unsafe) let unsafeSession = session
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await unsafeSession.export(to: destinationURL, as: .m4a)
            try Task.checkCancellation()
        } onCancel: {
            unsafeSession.cancelExport()
        }
    }
}
