import Foundation
import Testing
@testable import NexGenEngine

/// Port of `plugins/musicvideo/tests/test_analysis_schema.py`, plus targeted
/// coverage for `Analysis.perceivedBpm` and validation.
@Suite("Musicvideo Analysis Schema", .serialized)
struct AnalysisSchemaTests {
    @Test("schema version")
    func schemaVersion() {
        #expect(analysisSchemaVersion == "analysis/v2")
    }

    @Test("perceivedBpm defaults to bpm when tempoMultiplier is 1.0")
    func perceivedBpmDefault() throws {
        let analysis = try Analysis(
            project: "p", songPath: "audio/song.wav", sampleRate: 44100, durationS: 180.0, bpm: 120.0,
            beats: [], downbeats: [], downbeatSource: .librosaHeuristic, sections: []
        )
        #expect(analysis.perceivedBpm == 120.0)
    }

    @Test("perceivedBpm applies the tempo multiplier")
    func perceivedBpmAppliesMultiplier() throws {
        let analysis = try Analysis(
            project: "p", songPath: "audio/song.wav", sampleRate: 44100, durationS: 180.0, bpm: 160.0,
            tempoMultiplier: 0.5, beats: [], downbeats: [], downbeatSource: .madmom, sections: []
        )
        #expect(analysis.perceivedBpm == 80.0)
    }

    @Test("duration_s must be positive")
    func durationMustBePositive() throws {
        #expect(throws: Analysis.ValidationError.self) {
            try Analysis(
                project: "p", songPath: "audio/song.wav", sampleRate: 44100, durationS: 0.0, bpm: 120.0,
                beats: [], downbeats: [], downbeatSource: .librosaHeuristic, sections: []
            )
        }
    }

    @Test("bpm must be positive")
    func bpmMustBePositive() throws {
        #expect(throws: Analysis.ValidationError.self) {
            try Analysis(
                project: "p", songPath: "audio/song.wav", sampleRate: 44100, durationS: 180.0, bpm: 0.0,
                beats: [], downbeats: [], downbeatSource: .librosaHeuristic, sections: []
            )
        }
    }

    @Test("Analysis round-trips through YAML")
    func analysisRoundTripsThroughYAML() throws {
        let analysis = try Analysis(
            project: "p", songPath: "audio/song.wav", sampleRate: 44100, durationS: 180.0, bpm: 120.0,
            beats: [0.5, 1.0], downbeats: [0.5], downbeatSource: .madmom,
            sections: [AnalysisSection(index: 0, start: 0.0, end: 180.0, cluster: 0, source: "consolidated")]
        )
        let yaml = try YAMLCoding.encode(analysis)
        let decoded = try YAMLCoding.decode(Analysis.self, from: yaml)
        #expect(decoded == analysis)
    }
}
