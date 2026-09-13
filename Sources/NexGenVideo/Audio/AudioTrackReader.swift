import AVFoundation
import Foundation

/// Streams an asset's first audio track as decoded PCM buffers via AVAssetReader.
enum AudioTrackReader {
    enum ReadError: Error {
        case noAudioTrack(String)
        case readFailed(String)

        var message: String {
            switch self {
            case .noAudioTrack(let name): "No audio track in \(name)"
            case .readFailed(let reason): reason
            }
        }
    }

    /// Decode `url`'s first audio track with `outputSettings` (and optional `range`),
    /// invoking `onBuffer` for each PCM buffer. Throws `ReadError` on any failure.
    static func read(
        from url: URL,
        outputSettings: [String: Any],
        range: ClosedRange<Double>? = nil,
        onBuffer: (AVAudioPCMBuffer) throws -> Void
    ) async throws {
        try await readSamples(from: url, outputSettings: outputSettings, range: range) { sample in
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd) else {
                throw ReadError.readFailed("Invalid decoded audio format")
            }
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { return }
            guard count <= Int(Int32.max),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw ReadError.readFailed("Invalid decoded audio frame count")
            }
            pcm.frameLength = AVAudioFrameCount(count)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList
            ) == noErr else { throw ReadError.readFailed("Cannot copy decoded audio") }
            try onBuffer(pcm)
        }
    }

    static func readSamples(
        from url: URL,
        outputSettings: [String: Any],
        range: ClosedRange<Double>? = nil,
        onBuffer: (CMSampleBuffer) throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ReadError.noAudioTrack(url.lastPathComponent)
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw ReadError.readFailed(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else {
            throw ReadError.readFailed("Cannot read audio from \(url.lastPathComponent)")
        }
        reader.add(output)
        defer { if reader.status == .reading { reader.cancelReading() } }
        if let range {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            )
        }

        guard reader.startReading() else {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Reader could not start")
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try onBuffer(sample)
        }

        try Task.checkCancellation()
        if reader.status != .completed {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Read failed")
        }
    }
}
