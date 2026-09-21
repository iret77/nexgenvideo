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
        onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void
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

        let operation = ReadOperation(
            url: url,
            asset: asset,
            track: track,
            outputSettings: outputSettings,
            range: range,
            remainingRangeSeconds: remainingRangeSeconds,
            onBuffer: onBuffer
        )
        // copyNextSampleBuffer blocks; keep it off Swift's cooperative executor.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try operation.run()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class ReadOperation: @unchecked Sendable {
        let url: URL
        let asset: AVURLAsset
        let track: AVAssetTrack
        let outputSettings: [String: Any]
        let range: ClosedRange<Double>?
        var remainingRangeSeconds: Double?
        let onBuffer: (AVAudioPCMBuffer) throws -> Void

        init(
            url: URL,
            asset: AVURLAsset,
            track: AVAssetTrack,
            outputSettings: [String: Any],
            range: ClosedRange<Double>?,
            remainingRangeSeconds: Double?,
            onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void
        ) {
            self.url = url
            self.asset = asset
            self.track = track
            self.outputSettings = outputSettings
            self.range = range
            self.remainingRangeSeconds = remainingRangeSeconds
            self.onBuffer = onBuffer
        }

        func run() throws {
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

                var reachesRangeEnd = false
                if let remaining = remainingRangeSeconds {
                    let sampleRate = format.sampleRate
                    guard sampleRate.isFinite, sampleRate > 0 else {
                        throw ReadError.readFailed("Decoded audio has no valid sample rate")
                    }
                    let requestedFrames = remaining * sampleRate
                    guard requestedFrames.isFinite else { throw ReadError.invalidRange }
                    if requestedFrames <= Double(frames) {
                        frames = AVAudioFrameCount(max(1, Int(requestedFrames.rounded(.up))))
                        reachesRangeEnd = true
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

                if reachesRangeEnd {
                    reader.cancelReading()
                    break
                }
                if let remaining = remainingRangeSeconds {
                    remainingRangeSeconds = max(0, remaining - Double(frames) / format.sampleRate)
                }
            }

            if reader.status == .failed {
                throw ReadError.readFailed(reader.error?.localizedDescription ?? "Read failed")
            }
        }
    }
}
