import Foundation
import Testing
@testable import NexGenEngine

/// Proves the 23 pattern YAMLs bundled under `Resources/MusicvideoPack/library/`
/// (copied verbatim from `plugins/musicvideo/nexgen_pack_musicvideo/library/`)
/// parse and validate through the Swift `Pattern` Codable schema — the M8b
/// knowledge migration is only sound if every file in the copied library
/// round-trips through `Patterns.loadPattern`.
@Suite("Musicvideo Pattern Library Golden", .serialized)
struct PatternLibraryGoldenTests {
    @Test("every bundled pattern YAML file parses and validates")
    func everyPatternYAMLParses() throws {
        let urls = PackKnowledge.patternLibraryURLs()
        #expect(urls.count == 23, "expected all 23 pattern YAMLs to be bundled as resources")

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

    @Test("loadAllPatterns returns all 23 patterns sorted by filename")
    func loadAllPatternsReturnsAll23() throws {
        let library = try Patterns.loadAllPatterns()
        #expect(library.count == 23)
        #expect(Set(library.map(\.id)).count == 23, "pattern ids must be unique across the library")
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
