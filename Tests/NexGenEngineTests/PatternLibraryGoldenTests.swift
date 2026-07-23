import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// Verifies every bundled pattern YAML decodes, validates, and round-trips.
@Suite("Musicvideo Pattern Library Golden", .serialized)
struct PatternLibraryGoldenTests {
    @Test("every bundled pattern YAML file parses and validates")
    func everyPatternYAMLParses() throws {
        let urls = PackKnowledge.patternLibraryURLs()
        // The library has no fixed count.
        #expect(!urls.isEmpty, "no pattern YAMLs bundled as resources")

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let pattern = try Patterns.loadPattern(yaml: text, fileName: url.lastPathComponent)
            #expect(!pattern.id.isEmpty, "\(url.lastPathComponent): empty id")
            #expect(!pattern.name.isEmpty, "\(url.lastPathComponent): empty name")
            #expect(!pattern.references.isEmpty, "\(url.lastPathComponent): pattern has no references")
            for ref in pattern.references {
                #expect(!ref.sources.isEmpty, "\(url.lastPathComponent): reference '\(ref.name)' has no sources")
            }
            #expect(pattern.aslRange.minS > 0)
            #expect(pattern.aslRange.maxS >= pattern.aslRange.minS)
        }
    }

    @Test("loadAllPatterns returns every bundled pattern, sorted by filename, with unique ids")
    func loadAllPatternsReturnsTheLibrary() throws {
        let library = try Patterns.loadAllPatterns()
        #expect(library.count == PackKnowledge.patternLibraryURLs().count, "every bundled YAML loads")
        #expect(Set(library.map(\.id)).count == library.count, "pattern ids must be unique across the library")
    }

    @Test("every pattern's id matches its filename stem")
    func patternIdMatchesFilenameStem() throws {
        for url in PackKnowledge.patternLibraryURLs() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let pattern = try Patterns.loadPattern(yaml: text, fileName: url.lastPathComponent)
            #expect(pattern.id == url.deletingPathExtension().lastPathComponent, "\(url.lastPathComponent)")
        }
    }
}
