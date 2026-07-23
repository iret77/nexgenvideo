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
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test("copies (not moves), uniquifies against batch AND existing files, never overwrites")
    func copies() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("copy-\(UUID().uuidString)", isDirectory: true)
        let a = tmp.appendingPathComponent("a", isDirectory: true)
        let b = tmp.appendingPathComponent("b", isDirectory: true)
        let dest = tmp.appendingPathComponent("dest", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        // A pre-existing reference already in dest (e.g. from an earlier session) must be preserved.
        try Data("EXISTING".utf8).write(to: dest.appendingPathComponent("ref.jpg"))
        // Two different picked files with the SAME basename.
        try Data("A".utf8).write(to: a.appendingPathComponent("ref.jpg"))
        try Data("B".utf8).write(to: b.appendingPathComponent("ref.jpg"))

        let names = try AgentService.copyFilesUniquely(
            [a.appendingPathComponent("ref.jpg"), b.appendingPathComponent("ref.jpg")], into: dest)

        #expect(names == ["ref-2.jpg", "ref-3.jpg"])              // uniquified past the existing ref.jpg
        #expect(read(dest.appendingPathComponent("ref.jpg")) == "EXISTING")   // never overwritten
        #expect(read(dest.appendingPathComponent("ref-2.jpg")) == "A")        // contents match sources
        #expect(read(dest.appendingPathComponent("ref-3.jpg")) == "B")
        #expect(read(a.appendingPathComponent("ref.jpg")) == "A")             // sources untouched (copy)
        #expect(read(b.appendingPathComponent("ref.jpg")) == "B")
    }

    @Test("rolls back earlier copies when a later source fails")
    func rollsBackBatch() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("copy-rollback-\(UUID().uuidString)", isDirectory: true)
        let source = tmp.appendingPathComponent("source", isDirectory: true)
        let dest = tmp.appendingPathComponent("dest", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let valid = source.appendingPathComponent("valid.jpg")
        try Data("valid".utf8).write(to: valid)

        #expect(throws: (any Error).self) {
            try AgentService.copyFilesUniquely(
                [valid, source.appendingPathComponent("missing.jpg")],
                into: dest
            )
        }
        #expect((try fm.contentsOfDirectory(atPath: dest.path)).isEmpty)
    }
}
