import Foundation

public struct MeasuredMusicRange: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct MusicUnderstandingMeasurement: Sendable, Equatable {
    public let beats: [Double]
    public let bars: [Double]
    public let bpm: Double?
    public let sections: [MeasuredMusicRange]
    public let segments: [MeasuredMusicRange]
    public let phrases: [MeasuredMusicRange]

    public init(
        beats: [Double],
        bars: [Double],
        bpm: Double?,
        sections: [MeasuredMusicRange],
        segments: [MeasuredMusicRange],
        phrases: [MeasuredMusicRange]
    ) {
        self.beats = beats
        self.bars = bars
        self.bpm = bpm
        self.sections = sections
        self.segments = segments
        self.phrases = phrases
    }
}

public protocol MusicUnderstandingAnalyzing: Sendable {
    func analyze(_ audio: URL) throws -> MusicUnderstandingMeasurement
}
