import AVFoundation
import Foundation

struct WaveformEnvelopeV2: Codable, Equatable, Sendable {
    let version: Int
    let samples: [Float]
    let sourceStartTime: Double
    let decodedDuration: Double
    let samplePeriod: Double

    init(samples: [Float], sourceStartTime: Double, decodedDuration: Double, samplePeriod: Double) {
        version = 2
        self.samples = samples
        self.sourceStartTime = sourceStartTime
        self.decodedDuration = decodedDuration
        self.samplePeriod = samplePeriod
    }

    init(cacheData: Data) throws {
        guard cacheData.count <= 8_000_000 else { throw WaveformExtractor.ExtractionError.invalidEnvelope }
        self = try JSONDecoder().decode(Self.self, from: cacheData)
        guard isValid else { throw WaveformExtractor.ExtractionError.invalidEnvelope }
    }

    func cacheData() throws -> Data {
        guard isValid else { throw WaveformExtractor.ExtractionError.invalidEnvelope }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    private var isValid: Bool {
        guard version == 2, samples.count <= WaveformExtractor.sampleLimit,
              sourceStartTime.isFinite, decodedDuration.isFinite, decodedDuration >= 0,
              (sourceStartTime + decodedDuration).isFinite,
              samplePeriod.isFinite, samplePeriod >= 0.005,
              samples.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return false }
        if samples.isEmpty { return decodedDuration == 0 }
        let bins = decodedDuration / samplePeriod
        return bins.isFinite && bins > Double(samples.count - 1) && bins <= Double(samples.count) + 0.000001
    }

    func loudestSample(from start: Double, to end: Double) -> Float {
        guard start.isFinite, end.isFinite, end > start, !samples.isEmpty,
              end > sourceStartTime, start < sourceStartTime + decodedDuration else { return 1 }
        let lower = max(0, (start - sourceStartTime) / samplePeriod)
        let upper = min(Double(samples.count), (end - sourceStartTime) / samplePeriod)
        guard lower.isFinite, upper.isFinite, lower < upper else { return 1 }
        let first = min(samples.count, Int(floor(Self.snapBoundary(lower))))
        let last = min(samples.count, Int(ceil(Self.snapBoundary(upper))))
        guard first < last else { return 1 }
        return samples[first..<last].min() ?? 1
    }

    fileprivate static func snapBoundary(_ value: Double) -> Double {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.000001 ? rounded : value
    }
}

protocol WaveformSampleSource {
    func read(_ consume: (CMSampleBuffer) throws -> Void) async throws
}

enum WaveformExtractor {
    static let sampleLimit = 240_000

    enum ExtractionError: Error {
        case invalidPCM
        case invalidTimestamp
        case invalidEnvelope
    }

    private struct AssetSource: WaveformSampleSource {
        let url: URL

        func read(_ consume: (CMSampleBuffer) throws -> Void) async throws {
            try await AudioTrackReader.readSamples(from: url, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
            ], onBuffer: consume)
        }
    }

    static func extract(from url: URL, maxSamples: Int = sampleLimit) async throws -> WaveformEnvelopeV2 {
        try await extract(from: AssetSource(url: url), maxSamples: maxSamples)
    }

    static func extract(from source: any WaveformSampleSource, maxSamples: Int = sampleLimit) async throws -> WaveformEnvelopeV2 {
        try Task.checkCancellation()
        var accumulator = Accumulator(limit: min(sampleLimit, max(1, maxSamples)))
        try await source.read { try accumulator.append($0) }
        try Task.checkCancellation()
        return accumulator.envelope
    }

    private struct Accumulator {
        let limit: Int
        var peaks: [Float] = []
        var sourceStart: Double?
        var sourceEnd = 0.0
        var period = 0.005

        var envelope: WaveformEnvelopeV2 {
            WaveformEnvelopeV2(
                samples: peaks.map { $0 <= 0.00316227766 ? 1 : min(1, max(0, -20 * log10($0) / 50)) },
                sourceStartTime: sourceStart ?? 0,
                decodedDuration: sourceStart.map { sourceEnd - $0 } ?? 0,
                samplePeriod: period
            )
        }

        mutating func append(_ sample: CMSampleBuffer) throws {
            try Task.checkCancellation()
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0 else { return }
            guard count <= Int(Int32.max), let description = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: asbd),
                  format.commonFormat == .pcmFormatFloat32, format.channelCount == 1,
                  format.sampleRate.isFinite, format.sampleRate > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(count, 16_384))) else {
                throw ExtractionError.invalidPCM
            }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            let pts = timestamp.seconds
            let duration = Double(count) / format.sampleRate
            guard pts.isFinite, duration.isFinite, duration > 0, (pts + duration).isFinite else {
                throw ExtractionError.invalidTimestamp
            }
            let frameDuration: CMTime
            if format.sampleRate.rounded() == format.sampleRate, format.sampleRate <= Double(Int32.max) {
                frameDuration = CMTime(value: Int64(count), timescale: Int32(format.sampleRate))
            } else {
                frameDuration = CMTime(seconds: duration, preferredTimescale: 1_000_000_000)
            }
            let bufferEnd = CMTimeAdd(timestamp, frameDuration).seconds
            guard bufferEnd.isFinite else { throw ExtractionError.invalidTimestamp }
            if sourceStart == nil { sourceStart = pts; sourceEnd = pts }
            let origin = sourceStart!
            let previousEnd = sourceEnd
            for offset in stride(from: 0, to: count, by: 16_384) {
                try Task.checkCancellation()
                let frames = min(16_384, count - offset)
                pcm.frameLength = AVAudioFrameCount(frames)
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sample, at: Int32(offset), frameCount: Int32(frames), into: pcm.mutableAudioBufferList
                ) == noErr, let values = pcm.floatChannelData?[0] else { throw ExtractionError.invalidPCM }
                for index in 0..<frames {
                    let frame = offset + index
                    let start = max(sourceEnd, pts + Double(frame) / format.sampleRate)
                    let end = pts + Double(frame + 1) / format.sampleRate
                    guard end - start > 0.000001 / format.sampleRate else { continue }
                    let relativeEnd = end - origin
                    guard relativeEnd.isFinite, relativeEnd > 0 else { throw ExtractionError.invalidTimestamp }
                    while WaveformEnvelopeV2.snapBoundary(relativeEnd / period) > Double(limit) {
                        compact()
                        guard period.isFinite else { throw ExtractionError.invalidTimestamp }
                    }
                    let first = max(0, min(limit - 1, Int(floor(WaveformEnvelopeV2.snapBoundary((start - origin) / period)))))
                    let last = max(first + 1, min(limit, Int(ceil(WaveformEnvelopeV2.snapBoundary(relativeEnd / period)))))
                    if peaks.count < last { peaks.append(contentsOf: repeatElement(0, count: last - peaks.count)) }
                    let amplitude = values[index].isFinite ? min(1, abs(values[index])) : 0
                    for bin in first..<last { peaks[bin] = max(peaks[bin], amplitude) }
                    sourceEnd = end
                }
            }
            sourceEnd = max(previousEnd, bufferEnd)
        }

        private mutating func compact() {
            var destination = 0
            for index in stride(from: 0, to: peaks.count, by: 2) {
                peaks[destination] = max(peaks[index], index + 1 < peaks.count ? peaks[index + 1] : 0)
                destination += 1
            }
            peaks.removeLast(peaks.count - destination)
            period *= 2
        }
    }
}
