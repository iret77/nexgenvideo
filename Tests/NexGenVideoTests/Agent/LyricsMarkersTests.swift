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

@Suite("Identity slug")
struct IdentitySlugTests {
    @Test("names become filesystem-safe folder slugs")
    func slugs() {
        #expect(AgentService.identitySlug("Claude Mouse") == "claude-mouse")
        #expect(AgentService.identitySlug("  The AI Cat!!  ") == "the-ai-cat")
        #expect(AgentService.identitySlug("Café_déjà 2") == "café-déjà-2")
        #expect(AgentService.identitySlug("---") == "")
    }
}

@Suite("Copy files uniquely")
struct CopyFilesUniquelyTests {
    @Test("copies (not moves), uniquifies duplicate basenames, keeps sources")
    func copies() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)", isDirectory: true)
        let a = tmp.appendingPathComponent("a", isDirectory: true)
        let b = tmp.appendingPathComponent("b", isDirectory: true)
        let dest = tmp.appendingPathComponent("dest", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        // Two different files with the SAME basename.
        try Data("A".utf8).write(to: a.appendingPathComponent("ref.jpg"))
        try Data("B".utf8).write(to: b.appendingPathComponent("ref.jpg"))

        let names = try AgentService.copyFilesUniquely(
            [a.appendingPathComponent("ref.jpg"), b.appendingPathComponent("ref.jpg")], into: dest)

        #expect(names == ["ref.jpg", "ref-2.jpg"])            // uniquified, count truthful
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("ref.jpg").path))
        #expect(fm.fileExists(atPath: dest.appendingPathComponent("ref-2.jpg").path))
        #expect(fm.fileExists(atPath: a.appendingPathComponent("ref.jpg").path))  // sources untouched (copy)
        #expect(fm.fileExists(atPath: b.appendingPathComponent("ref.jpg").path))
    }
}
