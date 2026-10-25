import Foundation
import NexGenEngine

struct RecognizedLyrics: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case recognized
        case noVocalsDetected = "no_vocals_detected"
        case unavailable
        case failed
    }

    struct Word: Codable, Sendable, Equatable {
        let text: String
        let start: Double
        let end: Double
        let confidence: Double?
    }

    struct Line: Codable, Sendable, Equatable {
        let text: String
        let start: Double
        let end: Double
        let words: [Word]
    }

    let status: Status
    let reviewed: Bool
    let sourcePath: String
    let text: String
    let confidence: Double?
    let lines: [Line]

    enum CodingKeys: String, CodingKey {
        case status, reviewed, text, confidence, lines
        case sourcePath = "source_path"
    }

    static func transcript(_ words: [TranscribedWord], sourcePath: String,
                           duration: Double) throws -> Self {
        guard duration.isFinite, duration > 0 else { throw CocoaError(.coderInvalidValue) }
        var previousStart = 0.0
        var groups: [[Word]] = []
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, word.start.isFinite, word.end.isFinite,
                  word.start >= previousStart, word.start <= duration,
                  word.end >= word.start, word.end <= duration + 0.01,
                  word.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                throw CocoaError(.coderInvalidValue)
            }
            let value = Word(text: text, start: word.start, end: min(duration, word.end),
                             confidence: word.confidence)
            if let last = groups.last?.last,
               word.start - last.end <= 0.8,
               !".!?".contains(last.text.last ?? " "), groups.last!.count < 12 {
                groups[groups.count - 1].append(value)
            } else {
                groups.append([value])
            }
            previousStart = word.start
        }
        let lines = groups.map { group in
            Line(text: group.map(\.text).joined(separator: " "), start: group[0].start,
                 end: group.map(\.end).max()!, words: group)
        }
        let scores = words.compactMap(\.confidence)
        return Self(status: words.isEmpty ? .noVocalsDetected : .recognized, reviewed: false,
                    sourcePath: sourcePath, text: lines.map(\.text).joined(separator: "\n"),
                    confidence: scores.count == words.count && !scores.isEmpty
                        ? scores.reduce(0, +) / Double(scores.count) : nil,
                    lines: lines)
    }

    struct Measurement {
        let value: RecognizedLyrics
        let sourceSHA256: String
        let diagnostic: MusicvideoAnalysisRunner.StageDiagnostic
    }

    static func measure(transcriber: (any AudioTranscribing)?, vocals: URL?, song: URL,
                        dataRoot: URL, duration: Double, expectedSongSHA256: String? = nil) throws -> Measurement {
        try Task.checkCancellation()
        let songPath = FrameInventory.relativePath(of: song, to: dataRoot)
        let songDigest = try FileDigest.sha256(of: song)
        guard expectedSongSHA256.map({ $0 == songDigest }) ?? true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let transcriber else {
            return Measurement(value: Self(status: .unavailable, reviewed: false,
                sourcePath: songPath, text: "", confidence: nil, lines: []),
                sourceSHA256: songDigest, diagnostic: .init(stage: "lyrics_recognition",
                    status: .unavailable, detail: "No local speech recognizer is registered."))
        }
        let sources = vocals.map { $0 == song ? [song] : [$0, song] } ?? [song]
        var failures: [String] = []
        var emptyVocals = false
        for source in sources {
            try Task.checkCancellation()
            do {
                let path = FrameInventory.relativePath(of: source, to: dataRoot)
                let safeSource = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
                let digest = try FileDigest.sha256(of: safeSource)
                guard source != song || digest == songDigest else { throw CocoaError(.fileReadCorruptFile) }
                let rawWords = try transcriber.transcribe(safeSource, language: "auto")
                try Task.checkCancellation()
                let words = try lexicalWords(rawWords)
                guard try FileDigest.sha256(of: safeSource) == digest else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let value = try transcript(words, sourcePath: path, duration: duration)
                if words.isEmpty, source != song { emptyVocals = true; continue }
                let detail = words.isEmpty ? "No vocals detected in the mix."
                    : "Recognized \(words.count) words from \(source == song ? "mix" : "vocals"); text is unreviewed."
                let filtered = words.count != rawWords.count
                let quantizedEnd = words.contains { $0.end > duration }
                let uncertainty = emptyVocals && !words.isEmpty
                return Measurement(value: value, sourceSHA256: digest,
                    diagnostic: .init(stage: "lyrics_recognition",
                        status: failures.isEmpty && !filtered && !quantizedEnd && !uncertainty ? .succeeded : .degraded,
                        detail: detail
                            + (uncertainty ? " The vocal stem contained no recognized words; mix-only text is provisional." : "")
                            + (filtered ? " Non-lexical annotations were excluded." : "")
                            + (quantizedEnd ? " Word ends within 10 ms of the track end were bounded to its measured duration." : "")
                            + (failures.isEmpty ? "" : " Earlier attempts failed: " + failures.joined(separator: "; "))))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return Measurement(value: Self(status: .failed, reviewed: false, sourcePath: songPath,
            text: "", confidence: nil, lines: []), sourceSHA256: songDigest,
            diagnostic: .init(stage: "lyrics_recognition", status: .failed,
                detail: failures.joined(separator: "; ")))
    }

    static func lexicalWords(_ words: [TranscribedWord]) throws -> [TranscribedWord] {
        var bracketDepth = 0
        let lexical = words.filter { word in
            var annotation = bracketDepth > 0
            for character in word.text {
                if "[(".contains(character) { bracketDepth += 1; annotation = true }
                if "])".contains(character) { bracketDepth = max(0, bracketDepth - 1); annotation = true }
            }
            return !annotation && word.text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        guard bracketDepth == 0 else { throw CocoaError(.coderInvalidValue) }
        return lexical
    }

    static func verify(object: [String: Any], proof: AnalysisMeasurementProof,
                       dataRoot: URL, hasProvidedLyrics: Bool) throws {
        if object["recognized_lyrics"] == nil, proof.recognizedLyrics == nil { return }
        guard !hasProvidedLyrics, proof.lyricsAlignment == nil,
              let record = object["recognized_lyrics"] as? [String: Any],
              let measured = proof.recognizedLyrics,
              let duration = (object["duration_s"] as? NSNumber)?.doubleValue,
              measured.transcriptSHA256 == (try AnalysisMeasurementProofStore.recognitionFingerprint(object)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let value = try JSONDecoder().decode(Self.self,
            from: JSONSerialization.data(withJSONObject: record))
        let source = try ProjectLocalFile.resolve(measured.sourcePath, dataRoot: dataRoot)
        guard !value.reviewed, value.sourcePath == measured.sourcePath,
              value.sourcePath != (object["song_path"] as? String) || measured.sourceSHA256 == proof.songSHA256,
              try FileDigest.sha256(of: source) == measured.sourceSHA256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if value.status == .recognized {
            let words = value.lines.flatMap(\.words).map {
                TranscribedWord(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence)
            }
            guard !words.isEmpty,
                  try transcript(words, sourcePath: value.sourcePath, duration: duration) == value else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else if !value.text.isEmpty || !value.lines.isEmpty || value.confidence != nil {
            throw CocoaError(.fileReadCorruptFile)
        }
        let diagnostics = (object["stage_diagnostics"] as? [[String: Any]] ?? [])
            .filter { $0["stage"] as? String == "lyrics_recognition" }
        let statuses = value.status == .recognized || value.status == .noVocalsDetected
            ? ["succeeded", "degraded"] : [value.status.rawValue]
        guard diagnostics.count == 1,
              statuses.contains(diagnostics[0]["status"] as? String ?? ""),
              diagnostics[0]["timing_evidence"] == nil,
              diagnostics[0]["timing_method"] == nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
