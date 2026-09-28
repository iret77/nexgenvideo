import Accelerate
import AVFoundation
import Foundation

enum WaveformExtractor {
    static let samplesPerSecond: Double = 200
    static let noiseFloorDb: Float = -50
    static let maxSamples = 240_000

    static func peakEnvelope(from url: URL, range: ClosedRange<Double>? = nil) async throws -> [Float] {
        var accumulator = WaveformPeakAccumulator(
            samplesPerSecond: samplesPerSecond,
            noiseFloorDb: noiseFloorDb,
            maxSamples: maxSamples
        )
        try await AudioTrackReader.read(from: url, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], range: range) { pcm in
            accumulator.append(pcm)
        }
        return accumulator.finish()
    }
}

struct WaveformPeakAccumulator {
    let samplesPerSecond: Double
    let noiseFloorDb: Float
    let maxSamples: Int

    private(set) var peakSamples: [Float] = []
    private var hopFrames = 0
    private var compressionFactor = 1
    private var sampleRate: Double = 0
    private var carryPeak: Float = 0
    private var carryFrames = 0

    init(samplesPerSecond: Double, noiseFloorDb: Float, maxSamples: Int) {
        precondition(samplesPerSecond.isFinite && samplesPerSecond > 0)
        precondition(noiseFloorDb.isFinite && noiseFloorDb < 0)
        precondition(maxSamples > 0 && maxSamples <= Int.max / 2)
        self.samplesPerSecond = samplesPerSecond
        self.noiseFloorDb = noiseFloorDb
        self.maxSamples = maxSamples
        peakSamples.reserveCapacity(maxSamples)
    }

    mutating func append(_ pcm: AVAudioPCMBuffer) {
        guard let channel = pcm.floatChannelData else { return }
        let count = Int(pcm.frameLength)
        guard count > 0, prepare(sampleRate: pcm.format.sampleRate) else { return }

        var offset = 0
        while offset < count {
            let take = min(hopFrames - carryFrames, count - offset)
            var localPeak: Float = 0
            vDSP_maxmgv(channel[0] + offset, 1, &localPeak, vDSP_Length(take))
            accept(peak: localPeak, frameCount: take)
            offset += take
        }
    }

    mutating func append(peak: Float, frameCount: Int, sampleRate: Double) {
        guard frameCount > 0, prepare(sampleRate: sampleRate) else { return }
        var remaining = frameCount
        while remaining > 0 {
            let take = min(hopFrames - carryFrames, remaining)
            accept(peak: peak, frameCount: take)
            remaining -= take
        }
    }

    mutating func finish() -> [Float] {
        flushCarry()
        while peakSamples.count > maxSamples {
            compress()
        }
        return peakSamples
    }

    private mutating func prepare(sampleRate newSampleRate: Double) -> Bool {
        guard newSampleRate.isFinite, newSampleRate > 0 else { return false }
        guard sampleRate != newSampleRate || hopFrames == 0 else { return true }
        flushCarry()
        sampleRate = newSampleRate
        let requestedHop = (newSampleRate / samplesPerSecond) * Double(compressionFactor)
        if !requestedHop.isFinite || requestedHop >= Double(Int.max) {
            hopFrames = Int.max
        } else {
            hopFrames = max(1, Int(requestedHop.rounded()))
        }
        return true
    }

    private mutating func accept(peak: Float, frameCount: Int) {
        if peak.isFinite {
            carryPeak = max(carryPeak, abs(peak))
        } else if peak.isInfinite {
            carryPeak = .greatestFiniteMagnitude
        }
        carryFrames += frameCount
        if carryFrames == hopFrames {
            appendNormalized(carryPeak)
            carryPeak = 0
            carryFrames = 0
        }
    }

    private mutating func flushCarry() {
        guard carryFrames > 0 else { return }
        appendNormalized(carryPeak)
        carryPeak = 0
        carryFrames = 0
    }

    private mutating func appendNormalized(_ peak: Float) {
        peakSamples.append(Self.normalized(peak: peak, noiseFloorDb: noiseFloorDb))
        if peakSamples.count == maxSamples * 2 {
            compress()
        }
    }

    private mutating func compress() {
        guard peakSamples.count > 1 else { return }
        var compressed: [Float] = []
        compressed.reserveCapacity((peakSamples.count + 1) / 2)
        var index = 0
        while index < peakSamples.count {
            if index + 1 < peakSamples.count {
                compressed.append(min(peakSamples[index], peakSamples[index + 1]))
            } else {
                compressed.append(peakSamples[index])
            }
            index += 2
        }
        peakSamples = compressed
        compressionFactor = compressionFactor <= Int.max / 2 ? compressionFactor * 2 : Int.max
        hopFrames = hopFrames <= Int.max / 2 ? hopFrames * 2 : Int.max
    }

    static func normalized(peak: Float, noiseFloorDb: Float) -> Float {
        guard peak > 0 else { return 1 }
        guard peak.isFinite else { return 0 }
        let db = 20 * log10(peak)
        let clamped = min(0, max(noiseFloorDb, db))
        return clamped / noiseFloorDb
    }
}
