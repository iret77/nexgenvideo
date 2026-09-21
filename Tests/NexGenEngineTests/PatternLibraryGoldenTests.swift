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
            #expect(PatternSchemaValidator.validate(pattern).isEmpty, "\(url.lastPathComponent)")
            #expect(!pattern.craftSignature.isEmpty, "\(url.lastPathComponent): no craft signature")
            #expect(pattern.craftSignature.allSatisfy { !$0.pipelineLevers.isEmpty })
            #expect(!text.contains("approximation_basis:"), "legacy blanket provenance must not survive")
            #expect(!text.contains("camera_vocabulary:"), "legacy camera field must not survive")
            #expect(!text.contains("lighting_signature:"), "legacy lighting field must not survive")
        }
    }

    @Test("measured values require the exact reference video")
    func measuredValuesRequireReferenceVideo() throws {
        var pattern = try #require(try Patterns.loadAllPatterns().first)
        pattern.aslRange.basis = .measured
        pattern.aslRange.referenceVideo = nil
        #expect(PatternSchemaValidator.validate(pattern).contains {
            $0 == "asl_range.reference_video is required for measured evidence"
        })

        pattern.aslRange.referenceVideo = PatternReferenceVideo(
            title: "Measured reference",
            url: "https://example.com/reference"
        )
        #expect(!PatternSchemaValidator.validate(pattern).contains {
            $0.hasPrefix("asl_range.reference_video")
        })
    }

    @Test("the hard cutover rejects legacy and facade-only fields")
    func rejectsLegacyAndUnknownFields() throws {
        let url = try #require(PackKnowledge.patternLibraryURLs().first)
        let current = try String(contentsOf: url, encoding: .utf8)
        let legacy = current + "\napproximation_basis: legacy\n"
        #expect(throws: PatternLibraryError.self) {
            _ = try Patterns.loadPattern(yaml: legacy, fileName: "legacy.yaml")
        }

        let facade = current.replacingOccurrences(
            of: "  basis: inferred\n  sources:",
            with: "  dead_directive: ignored\n  basis: inferred\n  sources:",
            maxReplacements: 1
        )
        #expect(throws: PatternLibraryError.self) {
            _ = try Patterns.loadPattern(yaml: facade, fileName: "facade.yaml")
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

private extension String {
    func replacingOccurrences(
        of target: String,
        with replacement: String,
        maxReplacements: Int
    ) -> String {
        var result = self
        for _ in 0..<maxReplacements {
            guard let range = result.range(of: target) else { break }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
