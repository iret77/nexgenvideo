import AVFoundation
import Foundation

/// Streams an asset's first audio track as decoded PCM buffers via AVAssetReader.
enum AudioTrackReader {
    enum ReadError: Error {
        case noAudioTrack(String)
        case invalidRange
        case readFailed(String)

        var message: String {
            switch self {
            case .noAudioTrack(let name): "No audio track in \(name)"
            case .invalidRange: "Invalid audio time range"
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
        var remainingRangeSeconds: Double?
        if let range {
            guard range.lowerBound.isFinite, range.upperBound.isFinite,
                  range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
                throw ReadError.invalidRange
            }
            if range.lowerBound == range.upperBound { return }
            remainingRangeSeconds = range.upperBound - range.lowerBound
        }

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
        if let range {
            let start = CMTime(seconds: range.lowerBound, preferredTimescale: 1_000_000_000)
            let end = CMTime(seconds: range.upperBound, preferredTimescale: 1_000_000_000)
            guard start.isNumeric, end.isNumeric, start <= end else {
                throw ReadError.invalidRange
            }
            reader.timeRange = CMTimeRange(start: start, end: end)
        }

        guard reader.startReading() else {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Reader could not start")
        }

        while let sample = output.copyNextSampleBuffer() {
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd) else {
                throw ReadError.readFailed("Decoded audio has no valid format")
            }
            var frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0 else {
                throw ReadError.readFailed("Audio reader returned an empty sample buffer")
            }
            if let remaining = remainingRangeSeconds {
                let sampleRate = format.sampleRate
                guard sampleRate.isFinite, sampleRate > 0 else {
                    throw ReadError.readFailed("Decoded audio has no valid sample rate")
                }
                let requestedFrames = remaining * sampleRate
                guard requestedFrames.isFinite else { throw ReadError.invalidRange }
                if requestedFrames < Double(frames) {
                    frames = AVAudioFrameCount(max(1, Int(requestedFrames.rounded(.up))))
                }
            }
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw ReadError.readFailed("Could not allocate a decoded audio buffer")
            }
            pcm.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            guard status == noErr else {
                throw ReadError.readFailed("PCM copy failed (OSStatus \(status))")
            }
            try onBuffer(pcm)
            if let remaining = remainingRangeSeconds {
                let nextRemaining = max(0, remaining - Double(frames) / format.sampleRate)
                remainingRangeSeconds = nextRemaining
                if nextRemaining == 0 {
                    reader.cancelReading()
                    break
                }
            }
        }

        if reader.status == .failed {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Read failed")
        }
    }
}
