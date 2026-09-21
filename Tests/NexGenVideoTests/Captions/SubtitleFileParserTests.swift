import Foundation
import Testing
@testable import NexGenVideo

@Suite("Caption file parser")
struct SubtitleFileParserTests {
    @Test func parsesSRTBOMCRLFMultilineUnicodeAndVariantFractions() throws {
        let source = "\u{FEFF}2\r\n00:00:01.5 --> 00:00:02,050\r\nGrüße 世界 👋\r\nsecond line\r\n\r\n"
            + "1\r\n00:00:00,001 --> 00:00:00,999\r\nFirst\r\n"

        let document = try SubtitleFileParser.parse(source, format: .srt)

        #expect(document.cues.map(\.text) == ["First", "Grüße 世界 👋\nsecond line"])
        #expect(document.cues.map(\.start.milliseconds) == [1, 1_500])
        #expect(document.cues.map(\.end.milliseconds) == [999, 2_050])
    }

    @Test func parsesValidWebVTTMetadataIdentifiersSettingsAndPlainText() throws {
        let source = """
        WEBVTT - Interview
        Kind: captions
        Language: pt-br

        NOTE production note
        This block is not a cue.

        STYLE
        ::cue { color: lime }

        intro
        00:05.000 --> 00:07.500 align:start line:10%
        <v Ana><i>Olá</i> &amp; <00:06.250>bem-vindos</v>{\\an8}

        01:00:00.000 --> 01:00:01.000 position:50%
        Escapes: &lt;tag&gt; &amp;lt;
        """

        let document = try SubtitleFileParser.parse(source, format: .webVTT)

        #expect(document.languageIdentifier == "pt-BR")
        #expect(document.cues.map(\.text) == ["Olá & bem-vindos", "Escapes: <tag> &lt;"])
        #expect(document.cues.map(\.start.milliseconds) == [5_000, 3_600_000])
    }

    @Test(arguments: [
        "1\n00:00:xx,000 --> 00:00:01,000\nBad start.\n",
        "1\n00:00:01,000 --> 00:00:01,000\nZero duration.\n",
        "1\n00:60:00,000 --> 00:60:01,000\nBad minute.\n",
        "1\n00:00:01,0000 --> 00:00:02,000\nBad fraction.\n",
        "1\n00:00:01,000 --> 00:00:02,000\n<i></i>\n",
        "1\n00:00:01,000 --> 00:00:02,000\nFirst\n2\n00:00:03,000 --> 00:00:04,000\nSecond\n",
    ])
    func rejectsMalformedCueWithoutReturningPartialResults(_ source: String) {
        #expect(throws: SubtitleFileParser.ParseError.self) {
            try SubtitleFileParser.parse(source, format: .srt)
        }
    }

    @Test func rejectsMissingWebVTTHeaderAndCueFreeFiles() {
        #expect(throws: SubtitleFileParser.ParseError.missingWebVTTHeader) {
            try SubtitleFileParser.parse("00:00.000 --> 00:01.000\nText", format: .webVTT)
        }
        #expect(throws: SubtitleFileParser.ParseError.noCues) {
            try SubtitleFileParser.parse("WEBVTT\n\nNOTE only metadata", format: .webVTT)
        }
    }

    @Test func preservesUnclosedMarkupInsteadOfDroppingCaptionText() throws {
        let document = try SubtitleFileParser.parse(
            "1\n00:00:01,000 --> 00:00:02,000\nKeep <this text\n",
            format: .srt
        )

        #expect(document.cues.first?.text == "Keep <this text")
    }

    @Test func parsesTenThousandCuesInStableSourceOrder() throws {
        let source = (0..<10_000).map { index in
            let seconds = index % 60
            let minutes = index / 60 % 60
            let hours = index / 3_600
            return "\(index + 1)\n\(String(format: "%02d:%02d:%02d,000", hours, minutes, seconds)) --> \(String(format: "%02d:%02d:%02d,500", hours, minutes, seconds))\nCue \(index)"
        }.joined(separator: "\n\n")

        let document = try SubtitleFileParser.parse(source, format: .srt)

        #expect(document.cues.count == 10_000)
        #expect(document.cues.first?.text == "Cue 0")
        #expect(document.cues.last?.text == "Cue 9999")
        #expect(document.cues.last?.start.milliseconds == 9_999_000)
    }

    @Test func convertsEveryTimestampDirectlyWithIntegerTimescaleMath() throws {
        let values: [Int64] = [1, 500, 1_001, 60_001, 43_200_123, 35_999_999_999]
        for fps in [23, 24, 25, 29, 30, 60] {
            for milliseconds in values {
                let expected = Int((milliseconds * Int64(fps) + 500) / 1_000)
                #expect(try SubtitleTimestamp(milliseconds: milliseconds).frame(at: fps) == expected)
            }
        }
    }

    @Test func assignsOverlappingCuesToDeterministicTracksWithoutChangingTimes() async throws {
        let document = try SubtitleFileParser.parse(
            "1\n00:00:00,000 --> 00:00:02,000\nOne\n\n"
                + "2\n00:00:01,000 --> 00:00:03,000\nTwo\n\n"
                + "3\n00:00:03,000 --> 00:00:04,000\nThree\n",
            format: .srt
        )
        let provenance = CaptionProvenance(
            sourceFilename: "dialogue.en.srt",
            sourceFormat: "srt",
            languageIdentifier: "en",
            sourceAssetID: "asset-1"
        )

        let plan = try await SubtitleCaptionBuilder.build(
            document: document,
            fps: 30,
            canvasWidth: 1920,
            canvasHeight: 1080,
            style: TextStyle(),
            center: AppTheme.Caption.defaultCenter,
            provenance: provenance
        )

        #expect(plan.cueCount == 3)
        #expect(plan.trackCount == 2)
        #expect(plan.overlappingCueCount == 1)
        #expect(plan.specs.map(\.trackIndex) == [0, 1, 0])
        #expect(plan.specs.map(\.startFrame) == [0, 30, 90])
        #expect(plan.specs.map(\.durationFrames) == [60, 60, 30])
        #expect(plan.specs.allSatisfy { $0.captionProvenance == provenance })
    }
}
