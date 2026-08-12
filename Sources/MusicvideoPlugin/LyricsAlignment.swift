import Foundation

/// A transcribed word with its measured time span — the shape a Whisper transcriber yields per token.
/// The engine is transcriber-agnostic: the app layer (WhisperKit / whisper.cpp, run on Demucs-isolated
/// vocals) converts its output into `[TranscriptToken]` and hands it here. `score` is the transcriber's
/// per-word confidence, passed through onto matched lyric words.
public struct TranscriptToken: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var score: Double?
    public init(text: String, start: Double, end: Double, score: Double? = nil) {
        self.text = text; self.start = start; self.end = end; self.score = score
    }
}

/// Aligns lyric truth to timed ASR tokens without fabricating unmapped lines.
public enum LyricsAlignment {
    /// A lyric word: display surface + normalized matching key.
    private struct Tok { let surface: String; let key: String }
    private struct LyricLine { let text: String; let marker: String?; let tokens: [Tok] }

    /// Below this token similarity a Needleman–Wunsch diagonal is NOT treated as a real anchor — and,
    /// crucially, it's scored as a gap INSIDE the DP too (not just discarded in backtracking), so the DP
    /// never optimizes a path around matches it will later drop. Keeps genuine mishearings
    /// ("colour"~"color" ≈ 0.83) while rejecting weak short-word collisions (e.g. "the"~"she" ≈ 0.67),
    /// so a line the ASR truly missed finds no anchor and is dropped — near the original difflib
    /// behavior, which only ever anchored on exact tokens.
    private static let matchThreshold = 0.7

    struct Result: Sendable, Equatable {
        let lines: [AlignmentLine]
        let lyricLineCount: Int
        let mappedLineCount: Int
        let lyricTokenCount: Int
        let matchedTokenCount: Int
        let markerCount: Int
        let mappedMarkerCount: Int
        let reliableMarkerCount: Int

        var hasReliableStructureEvidence: Bool {
            markerCount > 0
                && mappedMarkerCount == markerCount
                && reliableMarkerCount == markerCount
        }
    }

    /// Normalize a token to a comparison key: fold diacritics + case, strip non-alphanumerics.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
    }

    /// `[Verse 1]` → `verse1`; `[Chorus – Final]` → `chorus-final`; `[Pre-Chorus]` → `pre-chorus`.
    /// Port of `alignment.py::_normalize_marker` — lowercases, unifies dashes, collapses whitespace
    /// around/within hyphen chains, but KEEPS hyphens.
    static func normalizeMarker(_ label: String) -> String {
        var s = label.trimmingCharacters(in: .whitespaces).lowercased()
        s = s.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        s = replacing(s, pattern: #"\s*-\s*"#, with: "-")
        s = replacing(s, pattern: #"\s+"#, with: "")
        return s
    }

    private static func replacing(_ text: String, pattern: String, with repl: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: repl)
    }

    private static func fullMatch(_ raw: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let m = re.firstMatch(in: raw, range: range), m.range == range else { return nil }
        if m.numberOfRanges > 1, let g = Range(m.range(at: 1), in: raw) { return String(raw[g]) }
        return ""
    }

    /// Levenshtein ratio in [0,1] — 1 = identical.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Split lyrics into sung lines, extract `[Section]` markers (numbering repeats), drop
    /// `(stage directions)`. Port of `alignment.py::parse_lyrics`.
    private static func parseLyrics(_ lyrics: String) -> [LyricLine] {
        var out: [LyricLine] = []
        var pending: String?
        var markerCounts: [String: Int] = [:]
        for raw in lyrics.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if let inner = fullMatch(raw, #"^\s*\[([^\]]+)\]\s*$"#) {
                let marker = normalizeMarker(inner)
                guard !marker.isEmpty else {
                    pending = nil
                    continue
                }
                let hasDigit = marker.rangeOfCharacter(from: .decimalDigits) != nil
                let hasQualifier = marker.contains("-")
                if hasDigit || hasQualifier {
                    pending = marker
                } else {
                    let count = markerCounts[marker, default: 0]
                    markerCounts[marker] = count + 1
                    pending = count == 0 ? marker : "\(marker)\(count + 1)"
                }
                continue
            }
            if fullMatch(raw, #"^\s*\(.*?\)\s*$"#) != nil { continue }  // stage direction
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { Tok(surface: String($0), key: normalize(String($0))) }
                .filter { !$0.key.isEmpty }
            out.append(LyricLine(text: line, marker: pending, tokens: toks))
            pending = nil
        }
        return out
    }

    /// Returns one alignment per mapped lyric line.
    public static func align(lyrics: String, transcript: [TranscriptToken]) -> [AlignmentLine] {
        alignDetailed(lyrics: lyrics, transcript: transcript).lines
    }

    static func alignDetailed(lyrics: String, transcript: [TranscriptToken]) -> Result {
        let lyricLines = parseLyrics(lyrics)
        let asr = transcript.filter { !normalize($0.text).isEmpty }
        let lyricTokenCount = lyricLines.reduce(0) { $0 + $1.tokens.count }
        let markerCount = lyricLines.filter { $0.marker != nil }.count
        guard !lyricLines.isEmpty, !asr.isEmpty else {
            return Result(
                lines: [], lyricLineCount: lyricLines.count, mappedLineCount: 0,
                lyricTokenCount: lyricTokenCount, matchedTokenCount: 0,
                markerCount: markerCount, mappedMarkerCount: 0, reliableMarkerCount: 0
            )
        }
        let asrKeys = asr.map { normalize($0.text) }

        // Flatten lyric tokens for one global sequence alignment.
        var toks: [Tok] = []
        for line in lyricLines {
            toks.append(contentsOf: line.tokens)
        }
        guard !toks.isEmpty else {
            return Result(
                lines: [], lyricLineCount: lyricLines.count, mappedLineCount: 0,
                lyricTokenCount: 0, matchedTokenCount: 0,
                markerCount: markerCount, mappedMarkerCount: 0, reliableMarkerCount: 0
            )
        }

        let matchOf = needlemanWunsch(lyric: toks.map(\.key), asr: asrKeys)

        // Group matched ASR indices per line (order-preserving thanks to global alignment).
        var out: [AlignmentLine] = []
        var mappedMarkerCount = 0
        var reliableMarkerCount = 0
        var cursor = 0
        for line in lyricLines {
            let range = cursor..<(cursor + line.tokens.count)
            cursor += line.tokens.count
            let matchedAsr = range.compactMap { matchOf[$0] }
            guard let lo = matchedAsr.min(), let hi = matchedAsr.max() else { continue }  // ASR missed the line → drop
            if line.marker != nil {
                mappedMarkerCount += 1
                let requiredAnchors = line.tokens.count == 1 ? 1 : 2
                if Set(matchedAsr).count >= requiredAnchors { reliableMarkerCount += 1 }
            }
            let lineStart = round3(asr[lo].start)
            let lineEnd = round3(max(asr[hi].end, asr[lo].start))
            out.append(AlignmentLine(
                start: lineStart, end: lineEnd, text: line.text, sectionMarker: line.marker,
                words: buildWords(line: line, tokenRange: range, matchOf: matchOf, asr: asr,
                                  lineStart: lineStart, lineEnd: lineEnd)))
        }
        return Result(
            lines: out.sorted { $0.start < $1.start },
            lyricLineCount: lyricLines.count,
            mappedLineCount: out.count,
            lyricTokenCount: lyricTokenCount,
            matchedTokenCount: matchOf.compactMap { $0 }.count,
            markerCount: markerCount,
            mappedMarkerCount: mappedMarkerCount,
            reliableMarkerCount: reliableMarkerCount
        )
    }

    /// Fuzzy global alignment. Returns, per lyric token, the ASR index it anchors to (nil = gap).
    /// Score: exact +2, fuzzy `2·sim−1`, gap −1. A diagonal below `matchThreshold` is demoted to a gap.
    private static func needlemanWunsch(lyric: [String], asr: [String]) -> [Int?] {
        let n = lyric.count, m = asr.count
        let gap = -1.0
        func sub(_ i: Int, _ j: Int) -> Double {
            if lyric[i] == asr[j] { return 2.0 }
            let s = similarity(lyric[i], asr[j])
            // Sub-threshold pairs cost the same as gapping both tokens, so the DP has no incentive to
            // route through diagonals the backtrack would discard anyway (DP/backtrack stay consistent).
            return s >= matchThreshold ? (2.0 * s - 1.0) : (2.0 * gap)
        }
        var score = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 1...n { score[i][0] = Double(i) * gap }
        if m >= 1 { for j in 1...m { score[0][j] = Double(j) * gap } }
        if n >= 1 && m >= 1 {
            for i in 1...n {
                for j in 1...m {
                    score[i][j] = max(score[i - 1][j - 1] + sub(i - 1, j - 1),
                                      max(score[i - 1][j] + gap, score[i][j - 1] + gap))
                }
            }
        }
        var matchOf = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            if score[i][j] == score[i - 1][j - 1] + sub(i - 1, j - 1) {
                if similarity(lyric[i - 1], asr[j - 1]) >= matchThreshold { matchOf[i - 1] = j - 1 }
                i -= 1; j -= 1
            } else if score[i][j] == score[i - 1][j] + gap {
                i -= 1
            } else {
                j -= 1
            }
        }
        return matchOf
    }

    /// Per-word timings for one kept line: matched words inherit the ASR span + confidence; intra-line
    /// gaps interpolate between the surrounding anchors, clamped to the line span (score nil).
    private static func buildWords(
        line: LyricLine, tokenRange: Range<Int>, matchOf: [Int?], asr: [TranscriptToken],
        lineStart: Double, lineEnd: Double
    ) -> [AlignmentWord] {
        let toks = Array(line.tokens)
        let localMatch = tokenRange.map { matchOf[$0] }
        var starts = [Double?](repeating: nil, count: toks.count)
        var ends = [Double?](repeating: nil, count: toks.count)
        var scores = [Double?](repeating: nil, count: toks.count)
        for k in toks.indices {
            guard let a = localMatch[k] else { continue }
            starts[k] = asr[a].start
            ends[k] = asr[a].end
            let sim = similarity(toks[k].key, normalize(asr[a].text))
            scores[k] = (asr[a].score ?? 1.0) * sim
        }
        interpolate(starts: &starts, ends: &ends, lo: lineStart, hi: lineEnd)
        return toks.indices.map { k in
            AlignmentWord(text: toks[k].surface, start: round3(starts[k] ?? lineStart),
                          end: round3(max(ends[k] ?? lineStart, starts[k] ?? lineStart)), score: scores[k])
        }
    }

    /// Fill nil spans by linear interpolation between known anchors, clamped to [lo, hi].
    private static func interpolate(starts: inout [Double?], ends: inout [Double?], lo: Double, hi: Double) {
        let n = starts.count
        var k = 0
        while k < n {
            if starts[k] != nil { k += 1; continue }
            let g0 = k
            var g1 = k
            while g1 < n && starts[g1] == nil { g1 += 1 }
            let before = g0 > 0 ? ends[g0 - 1] : nil
            let after = g1 < n ? starts[g1] : nil
            let a = before ?? lo
            let b = after ?? hi
            let span = g1 - g0
            for (offset, idx) in (g0..<g1).enumerated() {
                starts[idx] = a + (b - a) * Double(offset) / Double(max(span, 1))
                ends[idx] = a + (b - a) * Double(offset + 1) / Double(max(span, 1))
            }
            k = g1
        }
    }

    private static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// Test seam: exposes the parsed (sung line, section marker) pairs — the `parse_lyrics` contract
    /// the original locks with dedicated tests (marker numbering, hyphen keeping, stage-direction skip).
    static func linesAndMarkers(_ lyrics: String) -> [(text: String, marker: String?)] {
        parseLyrics(lyrics).map { ($0.text, $0.marker) }
    }
}
