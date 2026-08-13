import Foundation
import Testing
@testable import MusicvideoPlugin

@Suite("LyricsAlignment (native known-text alignment)")
struct LyricsAlignmentTests {
    @Test("exact single line inherits ASR word timings")
    func exactSingleLine() {
        let lines = LyricsAlignment.align(
            lyrics: "Hello world",
            transcript: [.init(text: "hello", start: 0, end: 1), .init(text: "world", start: 1, end: 2)])
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.text == "Hello world")
        #expect(line.sectionMarker == nil)
        #expect(line.words.count == 2)
        #expect(line.words[0].text == "Hello")
        #expect(line.words[0].start == 0 && line.words[0].end == 1)
        #expect(line.words[1].start == 1 && line.words[1].end == 2)
        #expect(line.words[0].score == 1.0)
        #expect(line.start == 0 && line.end == 2)
    }

    @Test("section markers ride onto the following line only")
    func sectionMarkers() {
        let lyrics = """
        [Verse 1]
        Hello world
        [Chorus]
        La la la
        """
        let asr: [TranscriptToken] = [
            .init(text: "hello", start: 0, end: 1), .init(text: "world", start: 1, end: 2),
            .init(text: "la", start: 3, end: 3.5), .init(text: "la", start: 3.5, end: 4),
            .init(text: "la", start: 4, end: 4.5),
        ]
        let lines = LyricsAlignment.align(lyrics: lyrics, transcript: asr)
        #expect(lines.count == 2)
        #expect(lines[0].sectionMarker == "verse1")
        #expect(lines[1].sectionMarker == "chorus")
        // Only marker-following lines carry evidence for structure fusion.
        #expect(lines.filter { $0.sectionMarker != nil }.count == 2)
    }

    @Test("structure evidence requires every marker line to have enough transcript anchors")
    func markerReliability() {
        let complete = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nhello world\n[Chorus]\nwide open",
            transcript: [
                .init(text: "hello", start: 0, end: 0.2),
                .init(text: "world", start: 0.2, end: 0.4),
                .init(text: "wide", start: 2, end: 2.2),
                .init(text: "open", start: 2.2, end: 2.4),
            ]
        )
        #expect(complete.hasReliableStructureEvidence)
        #expect(complete.markerCount == 2)
        #expect(complete.reliableMarkerCount == 2)

        let partial = LyricsAlignment.alignDetailed(
            lyrics: "[Verse]\nhello world\n[Chorus]\nmissing line",
            transcript: [
                .init(text: "hello", start: 0, end: 0.2),
                .init(text: "world", start: 0.2, end: 0.4),
            ]
        )
        #expect(!partial.hasReliableStructureEvidence)
        #expect(partial.markerCount == 2)
        #expect(partial.reliableMarkerCount == 1)
    }

    @Test("fuzzy ASR mishearing still matches the lyric word")
    func fuzzyMatch() {
        let lines = LyricsAlignment.align(
            lyrics: "bright colour",
            transcript: [.init(text: "bright", start: 0, end: 1), .init(text: "color", start: 1, end: 2)])
        #expect(lines.count == 1)
        #expect(lines[0].words.count == 2)
        // "colour" ~ "color" is a fuzzy hit: it inherits the ASR time, not an interpolated one.
        #expect(lines[0].words[1].start == 1 && lines[0].words[1].end == 2)
        #expect((lines[0].words[1].score ?? 0) > 0.7)
    }

    @Test("a word the ASR dropped is interpolated between its neighbors")
    func interpolatesMissingWord() {
        let lines = LyricsAlignment.align(
            lyrics: "one two three",
            transcript: [.init(text: "one", start: 0, end: 1), .init(text: "three", start: 2, end: 3)])
        #expect(lines.count == 1)
        let words = lines[0].words
        #expect(words.count == 3)
        #expect(words[1].text == "two")
        // Interpolated into the [1, 2] gap between the matched anchors, low confidence.
        #expect(words[1].start >= 1 && words[1].end <= 2)
        #expect(words[1].score == nil)
        // Monotonic non-decreasing timing across the line.
        #expect(words[0].start <= words[1].start && words[1].start <= words[2].start)
    }

    @Test("empty lyrics or empty transcript yield no alignment")
    func emptyInputs() {
        #expect(LyricsAlignment.align(lyrics: "", transcript: [.init(text: "x", start: 0, end: 1)]).isEmpty)
        #expect(LyricsAlignment.align(lyrics: "hello", transcript: []).isEmpty)
    }

    @Test("normalization folds case, diacritics and punctuation")
    func normalization() {
        #expect(LyricsAlignment.normalize("Café,") == "cafe")
        #expect(LyricsAlignment.normalize("HÉLLO!") == "hello")
        #expect(LyricsAlignment.normalize("...") == "")
    }

    // parse_lyrics parity — the marker/stage-direction rules the original locks with dedicated tests.

    @Test("markers: hyphen kept, repeats numbered from the second occurrence")
    func markerNumbering() {
        let lyrics = """
        [Chorus]
        First chorus line

        [Verse 2]
        Second verse line

        [Chorus]
        Second chorus line

        [Chorus – Final]
        Final chorus line
        """
        let markers = LyricsAlignment.linesAndMarkers(lyrics).map(\.marker)
        #expect(markers == ["chorus", "verse2", "chorus2", "chorus-final"])
    }

    @Test("markers: pre-chorus with a number keeps its hyphen and digit")
    func preChorusMarker() {
        #expect(LyricsAlignment.linesAndMarkers("[Pre-Chorus 1]\nRising tension")[0].marker == "pre-chorus1")
    }

    @Test("stage directions in parentheses are not sung lines")
    func stageDirectionsSkipped() {
        let lyrics = """
        [Intro]
        (Instrumental – 4 bars)

        [Verse 1]
        Morning light is falling
        """
        let parsed = LyricsAlignment.linesAndMarkers(lyrics)
        #expect(parsed.count == 1)
        #expect(parsed[0].text == "Morning light is falling")
        #expect(parsed[0].marker == "verse1")  // intro marker was consumed by the skipped direction
    }

    @Test("transcription context contains sung text but no structure markup")
    func transcriptionContext() {
        let context = LyricsAlignment.transcriptionContext(
            "[Verse 1]\nHello world\n(Instrumental)\n[Chorus]\nWide open"
        )
        #expect(context == "Hello world\nWide open")
    }

    @Test("markdown hard-break trailing spaces still parse")
    func hardBreaks() {
        let parsed = LyricsAlignment.linesAndMarkers("[Verse 1]  \nMorning light is falling  ")
        #expect(parsed.count == 1)
        #expect(parsed[0] == ("Morning light is falling", "verse1"))
    }

    @Test("whitespace-only markers do not create structure evidence")
    func whitespaceOnlyMarker() {
        let parsed = LyricsAlignment.linesAndMarkers("[Verse]\n[   ]\nMorning light is falling")
        #expect(parsed.count == 1)
        #expect(parsed[0].text == "Morning light is falling")
        #expect(parsed[0].marker == nil)
    }

    @Test("ad-lib ASR words between lines are not pulled into a line")
    func adLibsExcluded() {
        let lines = LyricsAlignment.align(
            lyrics: "hello world\ngood day",
            transcript: [
                .init(text: "hello", start: 1.0, end: 1.3), .init(text: "world", start: 1.3, end: 1.8),
                .init(text: "ohh", start: 1.8, end: 2.4), .init(text: "yeah", start: 2.4, end: 2.6),
                .init(text: "good", start: 3.0, end: 3.3), .init(text: "day", start: 3.3, end: 3.8),
            ])
        #expect(lines.count == 2)
        #expect(lines[0].end == 1.8)   // stops before the ad-libs
        #expect(lines[1].start == 3.0)
    }

    @Test("a line the ASR never transcribed is dropped, not fabricated")
    func unmappedLineDropped() {
        let lines = LyricsAlignment.align(
            lyrics: "hello world\nthis was swallowed by whisper\nfinal line here",
            transcript: [
                .init(text: "hello", start: 1.0, end: 1.3), .init(text: "world", start: 1.3, end: 1.8),
                .init(text: "final", start: 5.0, end: 5.3), .init(text: "line", start: 5.3, end: 5.6),
                .init(text: "here", start: 5.6, end: 5.9),
            ])
        #expect(lines.count == 2)
        #expect(lines[0].text == "hello world" && lines[0].end == 1.8)
        #expect(lines[1].text == "final line here" && lines[1].start == 5.0)
    }
}
