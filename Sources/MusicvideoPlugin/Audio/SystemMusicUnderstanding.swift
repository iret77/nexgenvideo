import Foundation
import NexGenEngine

enum SystemMusicUnderstandingContract {
    static let rhythmToleranceS = 0.05

    static func normalizedTimes(_ values: [Double], durationS: Double) -> [Double] {
        var result: [Double] = []
        for value in values.sorted()
        where value.isFinite && value >= 0 && value <= durationS + rhythmToleranceS {
            let rounded = (value * 1000).rounded() / 1000
            if result.last.map({ abs($0 - rounded) <= 0.001 }) != true {
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
