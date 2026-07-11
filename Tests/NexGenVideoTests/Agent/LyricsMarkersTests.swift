import Foundation
import Testing
@testable import NexGenVideo

@Suite("Lyrics section markers")
struct LyricsMarkersTests {
    @Test("extracts [Section] markers in order, ignoring plain lines, blanks, and empty brackets")
    func extracts() {
        let text = """
        [Intro]

        [Verse 1]
        walking down the street
        [Chorus]
        she runs the show
        [ ]
        [Verse 2]
        """
        #expect(AgentService.lyricsSectionMarkers(text) == ["Intro", "Verse 1", "Chorus", "Verse 2"])
    }

    @Test("lyrics without markers yield no sections")
    func none() {
        #expect(AgentService.lyricsSectionMarkers("just\nsome\nplain lyrics").isEmpty)
    }
}
