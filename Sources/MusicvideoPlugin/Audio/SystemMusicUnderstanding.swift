import Foundation
import NexGenEngine

enum SystemMusicUnderstandingContract {
    static let rhythmToleranceS = 0.05

    struct CanonicalRhythm: Equatable {
        let beats: [Double]
        let bars: [Double]
        let bpm: Double
    }

    struct Assessment: Equatable {
        let measurement: MusicUnderstandingMeasurement
        let canonicalRhythm: CanonicalRhythm?
    }

    static func assess(
        _ measurement: MusicUnderstandingMeasurement,
        durationS: Double
    ) -> Assessment {
        let beats = normalizedTimes(measurement.beats, durationS: durationS)
        let bars = normalizedTimes(measurement.bars, durationS: durationS)
        let bpm = measurement.bpm.flatMap { value in
            value.isFinite && value > 0 ? Energy.round3(value) : nil
        }
        let normalized = MusicUnderstandingMeasurement(
            beats: beats,
            bars: bars,
            bpm: bpm,
            sections: measurement.sections,
            segments: measurement.segments,
            phrases: measurement.phrases
        )
        let rhythm: CanonicalRhythm?
        if let bpm,
           hasConsistentRhythm(
               beats: beats,
               bars: bars,
               bpm: bpm,
               durationS: durationS
           ) {
            rhythm = CanonicalRhythm(beats: beats, bars: bars, bpm: bpm)
        } else {
            rhythm = nil
        }
        return Assessment(measurement: normalized, canonicalRhythm: rhythm)
    }

    static func normalizedTimes(_ values: [Double], durationS: Double) -> [Double] {
        guard durationS.isFinite, durationS > 0 else { return [] }
        var result: [Double] = []
        for value in values.filter({ $0.isFinite }).sorted()
        where value >= 0 && value <= durationS + rhythmToleranceS {
            let rounded = (value * 1000).rounded() / 1000
            if result.last != rounded {
                result.append(rounded)
            }
        }
        return result
    }

    static func hasConsistentRhythm(
        beats: [Double],
        bars: [Double],
        bpm: Double?,
        durationS: Double
    ) -> Bool {
        guard beats.count >= 2,
              !bars.isEmpty,
              let bpm,
              bpm.isFinite,
              bpm > 0,
              durationS.isFinite,
              durationS > 0 else { return false }
        guard bars.allSatisfy({ bar in
            beats.contains { abs($0 - bar) <= rhythmToleranceS }
        }) else { return false }
        let intervals = zip(beats, beats.dropFirst())
            .map { $0.1 - $0.0 }
            .filter { $0 > 0.01 }
            .sorted()
        guard !intervals.isEmpty else { return false }
        let medianBeat = intervals[intervals.count / 2]
        let expectedBeat = 60.0 / bpm
        return abs(medianBeat - expectedBeat) <= max(0.03, expectedBeat * 0.2)
    }
}
