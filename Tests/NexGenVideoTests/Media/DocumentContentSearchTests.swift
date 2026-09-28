import Foundation
import Testing
@testable import NexGenVideo

@Suite("Document content search")
struct DocumentContentSearchTests {
    @Test("search reads current source bytes and never creates an editable copy")
    func currentBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Scene 12: A café at dawn.".utf8).write(to: url)
        let sources = [DocumentContentSearch.Source(id: "document", url: url)]
        let first = await DocumentContentSearch.search(query: "CAFE", sources: sources)
        #expect(first.hits.map(\.id) == ["document"])
        #expect(first.hits.first?.excerpt.contains("café") == true)
        try Data("Scene 12: The harbor at night.".utf8).write(to: url)
        let revised = await DocumentContentSearch.search(query: "cafe", sources: sources)
        #expect(revised.hits.isEmpty)
        #expect(revised.unavailableIDs.isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "Scene 12: The harbor at night.")
    }

    @Test("RTF matches rendered text rather than control words")
    func richText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".rtf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{\rtf1\ansi A \b silver\b0  moon.}"#.utf8).write(to: url)
        let sources = [DocumentContentSearch.Source(id: "rtf", url: url)]
        let result = await DocumentContentSearch.search(query: "silver moon", sources: sources)
        #expect(result.hits.map(\.id) == ["rtf"])
        #expect(result.hits.first?.excerpt.contains("rtf1") == false)
    }

    @Test("missing and oversized files are reported instead of silently searched partially")
    func unavailableFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 65, count: DocumentContentSearch.maximumBytes + 1).write(to: url)
        let result = await DocumentContentSearch.search(query: "A", sources: [
            .init(id: "large", url: url),
            .init(id: "missing", url: url.appendingPathExtension("missing")),
        ])
        #expect(result.hits.isEmpty)
        #expect(result.unavailableIDs == ["large", "missing"])
    }
}
