import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

@Suite("Recognized lyrics")
struct RecognizedLyricsTests {
    struct Recognizer: AudioTranscribing {
        let responses: [String: [TranscribedWord]]
        func transcribe(_ audio: URL, language: String) throws -> [TranscribedWord] {
            #expect(language == "auto")
            guard let words = responses[audio.lastPathComponent] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return words
        }
    }

    private let words = [
        TranscribedWord(text: "Morning", start: 1, end: 1.3, confidence: 0.8),
        TranscribedWord(text: "light.", start: 1.3, end: 1.8, confidence: 0.6),
        TranscribedWord(text: "Stay", start: 3, end: 3.5, confidence: 0.4),
    ]

    @Test("the runner selects recognition only when lyrics were omitted")
    func runnerLyricsSelection() throws {
        let input = try inputs()
        let recognizer = Recognizer(responses: ["song.wav": words])
        let hash = try FileDigest.sha256(of: input.song)
        let omitted = try MusicvideoAnalysisRunner.measureLyrics(lyrics: nil, lyricsLoadError: nil,
            transcriber: recognizer, stems: nil, song: input.song, dataRoot: input.root,
            duration: 5, songSHA256: hash)
        #expect(omitted.recognition?.value.text == "Morning light.\nStay")
        #expect(omitted.alignment.isEmpty)
        #expect(omitted.stages == ["lyrics_recognition"])
        let supplied = try MusicvideoAnalysisRunner.measureLyrics(lyrics: "Morning light.\nStay", lyricsLoadError: nil,
            transcriber: recognizer, stems: nil, song: input.song, dataRoot: input.root,
            duration: 5, songSHA256: hash)
        #expect(supplied.recognition == nil)
        #expect(!supplied.alignment.isEmpty)
        let unreadable = try MusicvideoAnalysisRunner.measureLyrics(lyrics: nil, lyricsLoadError: "unreadable",
            transcriber: recognizer, stems: nil, song: input.song, dataRoot: input.root,
            duration: 5, songSHA256: hash)
        #expect(unreadable.recognition == nil)
        #expect(unreadable.diagnostics.first?.status == .unavailable)
    }

    struct CancelledRecognizer: AudioTranscribing {
        func transcribe(_ audio: URL, language: String) throws -> [TranscribedWord] { throw CancellationError() }
    }

    @Test("cancellation is propagated instead of treated as a fallback failure")
    func cancellation() throws {
        let input = try inputs()
        #expect(throws: CancellationError.self) {
            try RecognizedLyrics.measure(transcriber: CancelledRecognizer(), vocals: input.vocals,
                song: input.song, dataRoot: input.root, duration: 5)
        }
    }

    private func inputs() throws -> (root: URL, song: URL, vocals: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("analysis/stems"), withIntermediateDirectories: true)
        let song = root.appendingPathComponent("audio/song.wav")
        let vocals = root.appendingPathComponent("analysis/stems/vocals.wav")
        try Data("mix".utf8).write(to: song)
        try Data("vocals".utf8).write(to: vocals)
        return (root, song, vocals)
    }

    @Test("vocals yield unreviewed text, measured times and actual confidence")
    func prefersVocals() throws {
        let input = try inputs()
        let result = try RecognizedLyrics.measure(transcriber: Recognizer(responses: ["vocals.wav": words]),
            vocals: input.vocals, song: input.song, dataRoot: input.root, duration: 5)
        #expect(result.value.status == .recognized)
        #expect(result.value.sourcePath == "analysis/stems/vocals.wav")
        #expect(result.value.text == "Morning light.\nStay")
        #expect(result.value.reviewed == false)
        #expect(result.value.lines.count == 2)
        #expect(result.value.lines[0].start == 1)
        #expect(result.value.lines[0].end == 1.8)
        #expect(abs(try #require(result.value.confidence) - 0.6) < 0.0001)
        #expect(result.value.lines[1].words[0].confidence == 0.4)
        #expect(!FileManager.default.fileExists(atPath: input.root.appendingPathComponent("lyrics/lyrics.txt").path))
    }

    @Test("failed and empty vocals both fall back to mix", arguments: [false, true])
    func fallback(emptyVocals: Bool) throws {
        let input = try inputs()
        var responses = ["song.wav": words]
        if emptyVocals { responses["vocals.wav"] = [] }
        let result = try RecognizedLyrics.measure(transcriber: Recognizer(responses: responses),
            vocals: input.vocals, song: input.song, dataRoot: input.root, duration: 5)
        #expect(result.value.sourcePath == "audio/song.wav")
        #expect(result.value.text == "Morning light.\nStay")
        #expect(result.diagnostic.status == .degraded)
        if emptyVocals { #expect(result.diagnostic.detail.contains("mix-only text is provisional")) }
    }

    @Test("silence, failed inference and missing recognizer are distinct")
    func emptyAndFailure() throws {
        let input = try inputs()
        let silence = try RecognizedLyrics.measure(transcriber: Recognizer(responses: ["song.wav": []]),
            vocals: nil, song: input.song, dataRoot: input.root, duration: 5)
        #expect(silence.value.status == .noVocalsDetected)
        #expect(silence.value.text.isEmpty)
        #expect(silence.value.confidence == nil)
        #expect(silence.diagnostic.status == .succeeded)
        let failed = try RecognizedLyrics.measure(transcriber: Recognizer(responses: [:]),
            vocals: nil, song: input.song, dataRoot: input.root, duration: 5)
        #expect(failed.value.status == .failed)
        let missing = try RecognizedLyrics.measure(transcriber: nil,
            vocals: nil, song: input.song, dataRoot: input.root, duration: 5)
        #expect(missing.value.status == .unavailable)
    }

    @Test("musical symbols and split bracketed annotations are not lyrics")
    func annotationsAreNotLyrics() throws {
        let input = try inputs()
        let annotations = ["♪", "[Music]", "(", "instrumental", ")"].enumerated().map {
            TranscribedWord(text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.2)
        }
        let result = try RecognizedLyrics.measure(transcriber: Recognizer(responses: ["song.wav": annotations]),
            vocals: nil, song: input.song, dataRoot: input.root, duration: 5)
        #expect(result.value.status == .noVocalsDetected)
        #expect(result.value.text.isEmpty)
        #expect(result.value.lines.isEmpty)
        #expect(try RecognizedLyrics.lexicalWords(annotations + words) == words)
        let unclosed = try RecognizedLyrics.measure(transcriber: Recognizer(responses: ["song.wav": [
            TranscribedWord(text: "(oh", start: 0, end: 0.3),
        ] + words]), vocals: nil, song: input.song, dataRoot: input.root, duration: 5)
        #expect(unclosed.value.status == .failed)
        #expect(unclosed.diagnostic.status == .failed)
    }

    @Test("decoder quantization does not discard a valid final word")
    func lastWordQuantization() throws {
        let result = try RecognizedLyrics.transcript([
            TranscribedWord(text: "Stay", start: 4.8, end: 5.005, confidence: 0.7),
        ], sourcePath: "audio/song.wav", duration: 5)
        #expect(result.lines[0].words[0].end == 5)
        #expect(result.text == "Stay")
    }

    @Test("recognition refuses a track changed since acoustic measurement")
    func changedTrack() throws {
        let input = try inputs()
        let original = try FileDigest.sha256(of: input.song)
        try Data("replacement".utf8).write(to: input.song)
        #expect(throws: (any Error).self) {
            try RecognizedLyrics.measure(transcriber: Recognizer(responses: ["song.wav": words]),
                vocals: nil, song: input.song, dataRoot: input.root, duration: 5, expectedSongSHA256: original)
        }
    }

    @Test("encoding keeps recognized context outside the public alignment layout")
    func encodedContext() throws {
        let input = try inputs()
        let value = try RecognizedLyrics.transcript(words, sourcePath: "audio/song.wav", duration: 5)
        let analysis = try Analysis(project: "test", songPath: "audio/song.wav", sampleRate: 44_100,
            durationS: 5, bpm: 120, beats: [0, 0.5, 1], downbeats: [0], downbeatSource: .librosaHeuristic,
            sections: [], pipelineStages: ["lyrics_recognition"])
        let data = try MusicvideoAnalysisRunner.encodeArtifact(analysis, stageDiagnostics: [
            .init(stage: "lyrics_recognition", status: .succeeded, detail: "Measured recognition."),
        ], recognizedLyrics: value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(Analysis.self, from: data)
        #expect(decoded.alignment.isEmpty)
        #expect(decoded.pipelineStages == ["lyrics_recognition"])
        let record = try #require(object["recognized_lyrics"] as? [String: Any])
        #expect(record["text"] as? String == "Morning light.\nStay")
        let proof = AnalysisMeasurementProof(project: "test", songSHA256: try FileDigest.sha256(of: input.song), lyricsAlignment: nil,
            recognizedLyrics: .init(sourcePath: "audio/song.wav", sourceSHA256: try FileDigest.sha256(of: input.song),
                transcriptSHA256: try AnalysisMeasurementProofStore.recognitionFingerprint(object)))
        try RecognizedLyrics.verify(object: object, proof: proof, dataRoot: input.root, hasProvidedLyrics: false)
    }

    @Test("invalid timing and confidence cannot become successful recognition")
    func rejectsInvalidWords() throws {
        for word in [TranscribedWord(text: "word", start: -1, end: 1),
                     TranscribedWord(text: "word", start: 2, end: 1),
                     TranscribedWord(text: "word", start: 0, end: 6),
                     TranscribedWord(text: "word", start: 0, end: 1, confidence: .nan)] {
            #expect(throws: (any Error).self) {
                try RecognizedLyrics.transcript([word], sourcePath: "audio/song.wav", duration: 5)
            }
        }
        let unknown = try RecognizedLyrics.transcript([TranscribedWord(text: "word", start: 0, end: 1)],
            sourcePath: "audio/song.wav", duration: 5)
        #expect(unknown.confidence == nil)
    }

    @Test("proof rejects modified text, replaced source and supplied-lyrics conflict")
    func verifiesEvidence() throws {
        let input = try inputs()
        let result = try RecognizedLyrics.measure(transcriber: Recognizer(responses: ["vocals.wav": words]),
            vocals: input.vocals, song: input.song, dataRoot: input.root, duration: 5)
        var object: [String: Any] = ["duration_s": 5.0,
            "recognized_lyrics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.value)),
            "stage_diagnostics": [["stage": "lyrics_recognition", "status": "succeeded"]]]
        let proof = AnalysisMeasurementProof(project: "test", songSHA256: "test", lyricsAlignment: nil,
            recognizedLyrics: .init(sourcePath: result.value.sourcePath, sourceSHA256: result.sourceSHA256,
                transcriptSHA256: try AnalysisMeasurementProofStore.recognitionFingerprint(object)))
        try RecognizedLyrics.verify(object: object, proof: proof, dataRoot: input.root, hasProvidedLyrics: false)
        #expect(throws: (any Error).self) {
            try RecognizedLyrics.verify(object: object, proof: proof, dataRoot: input.root, hasProvidedLyrics: true)
        }
        var modified = try #require(object["recognized_lyrics"] as? [String: Any])
        modified["text"] = "different lyrics"
        let original = object["recognized_lyrics"]
        object["recognized_lyrics"] = modified
        #expect(throws: (any Error).self) {
            try RecognizedLyrics.verify(object: object, proof: proof, dataRoot: input.root, hasProvidedLyrics: false)
        }
        object["recognized_lyrics"] = original
        try Data("replaced vocals".utf8).write(to: input.vocals)
        #expect(throws: (any Error).self) {
            try RecognizedLyrics.verify(object: object, proof: proof, dataRoot: input.root, hasProvidedLyrics: false)
        }
    }
}
