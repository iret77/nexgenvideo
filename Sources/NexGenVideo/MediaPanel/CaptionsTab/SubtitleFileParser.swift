import Foundation
import UniformTypeIdentifiers

struct SubtitleTimestamp: Equatable, Comparable, Sendable {
    let milliseconds: Int64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.milliseconds < rhs.milliseconds
    }

    var seconds: Double { Double(milliseconds) / 1_000 }

    func frame(at fps: Int) throws -> Int {
        guard fps > 0 else { throw SubtitleFileParser.ParseError.invalidTimescale(fps) }
        let product = milliseconds.multipliedReportingOverflow(by: Int64(fps))
        guard !product.overflow else { throw SubtitleFileParser.ParseError.timeOutOfRange }
        let rounded = product.partialValue.addingReportingOverflow(500)
        guard !rounded.overflow,
              let frame = Int(exactly: rounded.partialValue / 1_000) else {
            throw SubtitleFileParser.ParseError.timeOutOfRange
        }
        return frame
    }
}

struct SubtitleCue: Equatable, Sendable {
    let text: String
    let start: SubtitleTimestamp
    let end: SubtitleTimestamp
    let sourceLine: Int
    let sourceIndex: Int
}

struct SubtitleDocument: Equatable, Sendable {
    let format: SubtitleFileParser.Format
    let cues: [SubtitleCue]
    let languageIdentifier: String?
}

enum SubtitleFileParser {
    enum Format: String, Equatable, Sendable {
        case srt
        case webVTT

        init?(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "srt": self = .srt
            case "vtt": self = .webVTT
            default: return nil
            }
        }
    }

    enum ParseError: LocalizedError, Equatable, Sendable {
        case unsupportedFileType(String)
        case missingWebVTTHeader
        case malformedCue(index: Int, line: Int, reason: String)
        case noCues
        case invalidTimescale(Int)
        case timeOutOfRange

        var errorDescription: String? {
            switch self {
            case .unsupportedFileType(let ext):
                "Unsupported caption file type “.\(ext)”. Use SRT or WebVTT."
            case .missingWebVTTHeader:
                "Not a WebVTT file — the WEBVTT header is missing."
            case .malformedCue(let index, let line, let reason):
                "Caption \(index) is malformed at line \(line): \(reason)"
            case .noCues:
                "The file contains no captions."
            case .invalidTimescale(let fps):
                "The timeline frame rate \(fps) is invalid."
            case .timeOutOfRange:
                "A caption timestamp is outside the supported timeline range."
            }
        }
    }

    private struct SourceLine: Sendable {
        let number: Int
        let text: String
    }

    private struct Block: Sendable {
        let lines: [SourceLine]
    }

    static var contentTypes: [UTType] {
        ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) }
    }

    @concurrent
    static func parseFile(at url: URL) async throws -> SubtitleDocument {
        guard let format = Format(fileExtension: url.pathExtension) else {
            throw ParseError.unsupportedFileType(url.pathExtension)
        }
        return try await parseFile(at: url, format: format)
    }

    @concurrent
    static func parseFile(at url: URL, format: Format) async throws -> SubtitleDocument {
        let data = try Data(contentsOf: url)
        let contents = decodedString(data)
        let parsed = try parse(contents, format: format)
        guard parsed.languageIdentifier == nil,
              let filenameLanguage = languageIdentifier(fromFilename: url.lastPathComponent) else {
            return parsed
        }
        return SubtitleDocument(
            format: parsed.format,
            cues: parsed.cues,
            languageIdentifier: filenameLanguage
        )
    }

    static func parse(_ contents: String, format: Format) throws -> SubtitleDocument {
        var normalized = contents
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        normalized = normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var blocks = makeBlocks(normalized)
        var languageIdentifier: String?
        if format == .webVTT {
            guard let header = blocks.first,
                  let signature = header.lines.first?.text,
                  isKeywordLine(signature, keyword: "WEBVTT") else {
                throw ParseError.missingWebVTTHeader
            }
            if let timing = header.lines.dropFirst().first(where: { $0.text.contains("-->") }) {
                throw ParseError.malformedCue(
                    index: 1,
                    line: timing.number,
                    reason: "insert a blank line after the WEBVTT header."
                )
            }
            for line in header.lines.dropFirst() {
                if let separator = line.text.firstIndex(of: ":") {
                    let key = line.text[..<separator].trimmingCharacters(in: .whitespaces)
                    let value = line.text[line.text.index(after: separator)...]
                        .trimmingCharacters(in: .whitespaces)
                    if key.caseInsensitiveCompare("language") == .orderedSame
                        || key.caseInsensitiveCompare("lang") == .orderedSame {
                        languageIdentifier = normalizeLanguageIdentifier(value)
                    }
                }
            }
            blocks.removeFirst()
        }

        var cues: [SubtitleCue] = []
        for block in blocks {
            guard let first = block.lines.first else { continue }
            if format == .webVTT,
               ["NOTE", "STYLE", "REGION"].contains(where: {
                   isKeywordLine(first.text, keyword: $0)
               }) {
                continue
            }

            let cueIndex = cues.count + 1
            guard let timingOffset = block.lines.prefix(2).firstIndex(where: {
                $0.text.contains("-->")
            }) else {
                throw ParseError.malformedCue(
                    index: cueIndex,
                    line: first.number,
                    reason: "missing timing line."
                )
            }
            let timingLine = block.lines[timingOffset]
            let timing = try parseTiming(
                timingLine.text,
                format: format,
                cueIndex: cueIndex,
                line: timingLine.number
            )

            let payload = block.lines.dropFirst(timingOffset + 1)
            guard !payload.isEmpty else {
                throw ParseError.malformedCue(
                    index: cueIndex,
                    line: timingLine.number,
                    reason: "missing caption text."
                )
            }
            var textLines: [String] = []
            for line in payload {
                guard !line.text.contains("-->") else {
                    throw ParseError.malformedCue(
                        index: cueIndex,
                        line: line.number,
                        reason: "cues must be separated by a blank line."
                    )
                }
                textLines.append(plainText(line.text))
            }
            let text = textLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw ParseError.malformedCue(
                    index: cueIndex,
                    line: payload.first?.number ?? timingLine.number,
                    reason: "caption text is empty after removing styling."
                )
            }
            cues.append(SubtitleCue(
                text: text,
                start: timing.start,
                end: timing.end,
                sourceLine: timingLine.number,
                sourceIndex: cueIndex
            ))
        }
        guard !cues.isEmpty else { throw ParseError.noCues }
        let ordered = cues.enumerated().sorted {
            if $0.element.start != $1.element.start {
                return $0.element.start < $1.element.start
            }
            return $0.offset < $1.offset
        }.map(\.element)
        return SubtitleDocument(
            format: format,
            cues: ordered,
            languageIdentifier: languageIdentifier
        )
    }

    static func plainText(_ line: String) -> String {
        var output = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "<",
               let close = line[index...].firstIndex(of: ">") {
                index = line.index(after: close)
                continue
            }
            if character == "{",
               let close = line[index...].firstIndex(of: "}") {
                index = line.index(after: close)
                continue
            }
            output.append(character)
            line.formIndex(after: &index)
        }
        for (entity, value) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", "\u{00A0}"),
            ("&lrm;", "\u{200E}"), ("&rlm;", "\u{200F}"), ("&amp;", "&"),
        ] {
            output = output.replacingOccurrences(of: entity, with: value)
        }
        return output.trimmingCharacters(in: .whitespaces)
    }

    private static func decodedString(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]),
           let value = String(data: data, encoding: .utf16LittleEndian) {
            return value
        }
        if data.starts(with: [0xFE, 0xFF]),
           let value = String(data: data, encoding: .utf16BigEndian) {
            return value
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    private static func makeBlocks(_ contents: String) -> [Block] {
        var blocks: [Block] = []
        var current: [SourceLine] = []
        let lines = contents.components(separatedBy: "\n")
        for (offset, raw) in lines.enumerated() {
            let text = raw.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                if !current.isEmpty {
                    blocks.append(Block(lines: current))
                    current = []
                }
            } else {
                current.append(SourceLine(number: offset + 1, text: text))
            }
        }
        if !current.isEmpty { blocks.append(Block(lines: current)) }
        return blocks
    }

    private static func isKeywordLine(_ line: String, keyword: String) -> Bool {
        line == keyword || line.hasPrefix(keyword + " ") || line.hasPrefix(keyword + "\t")
    }

    private static func parseTiming(
        _ lineText: String,
        format: Format,
        cueIndex: Int,
        line: Int
    ) throws -> (start: SubtitleTimestamp, end: SubtitleTimestamp) {
        let parts = lineText.components(separatedBy: "-->")
        guard parts.count == 2 else {
            throw ParseError.malformedCue(
                index: cueIndex,
                line: line,
                reason: "expected one --> separator."
            )
        }
        let startToken = parts[0].trimmingCharacters(in: .whitespaces)
        let endToken = parts[1].trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let start = timestamp(startToken, format: format),
              let end = timestamp(endToken, format: format) else {
            throw ParseError.malformedCue(
                index: cueIndex,
                line: line,
                reason: "invalid timestamp."
            )
        }
        guard end > start else {
            throw ParseError.malformedCue(
                index: cueIndex,
                line: line,
                reason: "end time must be after start time."
            )
        }
        return (start, end)
    }

    private static func timestamp(_ token: String, format: Format) -> SubtitleTimestamp? {
        let separator: Character
        if token.contains(".") {
            separator = "."
        } else if format == .srt, token.contains(",") {
            separator = ","
        } else {
            return nil
        }
        let fractionParts = token.split(separator: separator, omittingEmptySubsequences: false)
        guard fractionParts.count == 2,
              (1...3).contains(fractionParts[1].count),
              fractionParts[1].allSatisfy(\.isNumber),
              let fraction = Int64(fractionParts[1]) else { return nil }
        let clock = fractionParts[0].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 2 || clock.count == 3,
              clock.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }

        let hours: Int64
        let minutes: Int64
        let seconds: Int64
        if clock.count == 3 {
            guard clock[0].count <= 4,
                  let h = Int64(clock[0]), let m = Int64(clock[1]), let s = Int64(clock[2]) else {
                return nil
            }
            hours = h
            minutes = m
            seconds = s
        } else {
            guard let m = Int64(clock[0]), let s = Int64(clock[1]) else { return nil }
            hours = 0
            minutes = m
            seconds = s
        }
        guard minutes < 60, seconds < 60 else { return nil }
        let fractionMilliseconds = fraction * [100, 10, 1][fractionParts[1].count - 1]
        let totalSeconds = hours * 3_600 + minutes * 60 + seconds
        return SubtitleTimestamp(milliseconds: totalSeconds * 1_000 + fractionMilliseconds)
    }

    static func languageIdentifier(fromFilename filename: String) -> String? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let candidate = stem.split(separator: ".").last.map(String.init) ?? stem
        return normalizeLanguageIdentifier(candidate)
    }

    private static func normalizeLanguageIdentifier(_ raw: String) -> String? {
        let parts = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        guard let primary = parts.first,
              (2...3).contains(primary.count),
              primary.allSatisfy(\.isASCIIAlpha),
              parts.dropFirst().allSatisfy({
                  (1...8).contains($0.count) && $0.allSatisfy(\.isASCIIAlphaNumeric)
              }) else { return nil }
        return parts.enumerated().map { index, part in
            let value = String(part)
            if index == 0 { return value.lowercased() }
            if value.count == 4, value.allSatisfy(\.isASCIIAlpha) {
                return value.prefix(1).uppercased() + value.dropFirst().lowercased()
            }
            if value.count == 2, value.allSatisfy(\.isASCIIAlpha) {
                return value.uppercased()
            }
            return value.lowercased()
        }.joined(separator: "-")
    }
}

private extension Character {
    var isASCIIAlpha: Bool {
        guard unicodeScalars.count == 1, let value = unicodeScalars.first?.value else { return false }
        return (65...90).contains(value) || (97...122).contains(value)
    }

    var isASCIIAlphaNumeric: Bool {
        guard unicodeScalars.count == 1, let value = unicodeScalars.first?.value else { return false }
        return isASCIIAlpha || (48...57).contains(value)
    }
}
