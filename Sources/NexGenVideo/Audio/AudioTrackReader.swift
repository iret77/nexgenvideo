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
        if let range {
            guard range.lowerBound.isFinite, range.upperBound.isFinite,
                  range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
                throw ReadError.invalidRange
            }
            if range.lowerBound == range.upperBound { return }
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
            let timeScale: CMTimeScale
            do {
                timeScale = try await track.load(.naturalTimeScale)
            } catch {
                throw ReadError.readFailed(error.localizedDescription)
            }
            guard timeScale > 0 else {
                throw ReadError.readFailed("Audio track has no valid timebase")
            }
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: timeScale),
                end: CMTime(seconds: range.upperBound, preferredTimescale: timeScale)
            )
        }

        guard reader.startReading() else {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Reader could not start")
        }

        while let sample = output.copyNextSampleBuffer() {
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd) else { continue }
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            pcm.frameLength = frames
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList
            )
            guard status == noErr else {
                throw ReadError.readFailed("PCM copy failed (OSStatus \(status))")
            }
            try onBuffer(pcm)
        }

        if reader.status == .failed {
            throw ReadError.readFailed(reader.error?.localizedDescription ?? "Read failed")
        }
    }
}
