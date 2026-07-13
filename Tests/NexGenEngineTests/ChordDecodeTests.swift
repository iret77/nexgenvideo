import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// Pure chord decode (Viterbi smoothing + run-length merge) and the analysis seam that carries a
/// recognized chord progression through `toCanonical`. CI never runs the ONNX model — same split as
/// Demucs / Beat This!: the pure parts are covered here, real inference is validated on-device.
@Suite("ChordDecode")
struct ChordDecodeTests {
    private let vocab = ["N", "C", "Am", "G"]

    @Test("single dominant class per frame merges into one span, N dropped, times rounded")
    func basicMerge() {
        // Frames: C C C N Am Am  (hop 0.5s)
        let path = [1, 1, 1, 0, 2, 2]
        let chords = ChordDecode.segments(labels: path, vocabulary: vocab, hopSeconds: 0.5)
        #expect(chords == [
            RecognizedChord(start: 0.0, end: 1.5, label: "C"),
            RecognizedChord(start: 2.0, end: 3.0, label: "Am"),
        ])
    }

    @Test("Viterbi smooths a single-frame flicker back to the dominant label")
    func smoothsFlicker() {
        // Class 1 ("C") is strongly favored every frame except a weak flicker to class 2 at t=2.
        let logits: [[Double]] = [
            [0, 5, 0, 0],
            [0, 5, 0, 0],
            [0, 4, 4.3, 0],  // slight edge to class 2 in isolation
            [0, 5, 0, 0],
            [0, 5, 0, 0],
        ]
        // With no penalty the flicker survives; with a penalty it is smoothed away.
        let raw = ChordDecode.viterbi(logits: logits, transitionPenalty: 0)
        #expect(raw[2] == 2)
        let smoothed = ChordDecode.viterbi(logits: logits, transitionPenalty: 2.0)
        #expect(smoothed == [1, 1, 1, 1, 1])
    }

    @Test("decode end-to-end yields a single C span from a flickered input")
    func decodeEndToEnd() {
        let logits: [[Double]] = [
            [0, 5, 0, 0], [0, 5, 0, 0], [0, 4, 4.3, 0], [0, 5, 0, 0], [0, 5, 0, 0],
        ]
        let chords = ChordDecode.decode(
            logits: logits, vocabulary: vocab, hopSeconds: 0.5, transitionPenalty: 2.0)
        #expect(chords == [RecognizedChord(start: 0.0, end: 2.5, label: "C")])
    }

    @Test("empty / degenerate inputs are safe")
    func edgeCases() {
        #expect(ChordDecode.viterbi(logits: [], transitionPenalty: 1).isEmpty)
        #expect(ChordDecode.segments(labels: [], vocabulary: vocab, hopSeconds: 0.5).isEmpty)
        #expect(ChordDecode.segments(labels: [1], vocabulary: vocab, hopSeconds: 0).isEmpty)
        // All no-chord → no segments.
        #expect(ChordDecode.segments(labels: [0, 0, 0], vocabulary: vocab, hopSeconds: 0.5).isEmpty)
        // Out-of-range index treated as no-chord.
        #expect(ChordDecode.segments(labels: [9], vocabulary: vocab, hopSeconds: 0.5).isEmpty)
    }

    @Test("ties break to the lowest class index for stability")
    func stableTies() {
        let logits: [[Double]] = [[3, 3, 3, 3]]
        #expect(ChordDecode.viterbi(logits: logits, transitionPenalty: 0) == [0])
    }

    // MARK: - Analysis seam

    private func rawAnalysis() -> AudioAnalysis {
        AudioAnalysis(
            sampleRate: 22050, durationS: 12.0, bpm: 120.0,
            beats: [0.5, 1.0], downbeats: [0.5], downbeatSource: "librosa-heuristic",
            sections: [AudioSection(index: 0, start: 0.0, end: 12.0, cluster: 0, source: "consolidated")],
            energyCurve: [EnergyPoint(t: 0, rms: 0.1)], tempoCurve: [TempoPoint(t: 0, bpm: 120)])
    }

    @Test("toCanonical carries chords through and round-trips them via the schema")
    func chordsPassThrough() throws {
        let chords = [
            Chord(start: 0.0, end: 2.0, label: "C"),
            Chord(start: 2.0, end: 4.0, label: "Am"),
        ]
        let analysis = try MusicvideoAnalysisRunner.toCanonical(
            rawAnalysis(), project: "P", songPath: "audio/song.mp3", chords: chords,
            pipelineStages: ["load_audio", "rhythm", "structure", "features", "chords"])
        #expect(analysis.chordProgression == chords)
        #expect(analysis.pipelineStages.contains("chords"))

        let data = try MusicvideoAnalysisRunner.encodeArtifact(analysis)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"chord_progression\""))
        let decoded = try JSONDecoder().decode(Analysis.self, from: data)
        #expect(decoded.chordProgression == chords)
    }

    @Test("absent recognizer ⇒ empty chords, no chords stage")
    func absentRecognizer() throws {
        let analysis = try MusicvideoAnalysisRunner.toCanonical(
            rawAnalysis(), project: "P", songPath: "audio/song.mp3")
        #expect(analysis.chordProgression.isEmpty)
        #expect(!analysis.pipelineStages.contains("chords"))
    }
}
