import Foundation
import Testing
@testable import NexGenEngine

@Suite("ProjectMeta")
struct ProjectMetaTests {
    @Test("YAML round-trip preserves equality")
    func yamlRoundTrip() throws {
        let meta = ProjectMeta(project: "basic-project", mode: .beat, budgetEur: 50.0, created: "2026-07-06")
        let yaml = try YAMLCoding.encode(meta)
        let decoded = try YAMLCoding.decode(ProjectMeta.self, from: yaml)
        #expect(decoded == meta)
    }

    @Test("decodes a hand-written minimal document, defaulting budget_eur")
    func decodesHandWrittenYAML() throws {
        let yaml = "project: p\nmode: section\n"
        let meta = try YAMLCoding.decode(ProjectMeta.self, from: yaml)
        #expect(meta.project == "p")
        #expect(meta.mode == .section)
        #expect(meta.budgetEur == 50.0)
        #expect(meta.created == nil)
    }

    @Test("budget_eur must be > 0")
    func budgetMustBePositive() throws {
        #expect(throws: ProjectMeta.ValidationError.self) {
            try ProjectMeta(project: "p", mode: .beat, budgetEur: 0).validate()
        }
        #expect(throws: ProjectMeta.ValidationError.self) {
            try ProjectMeta(project: "p", mode: .beat, budgetEur: -5).validate()
        }
    }

    @Test("decoding a non-positive budget throws")
    func decodingNonPositiveBudgetThrows() throws {
        let yaml = "project: p\nmode: beat\nbudget_eur: 0\n"
        // Yams wraps init(from:) validation errors in DecodingError.dataCorrupted;
        // the underlying error carries the ValidationError.
        #expect(throws: (any Error).self) {
            try YAMLCoding.decode(ProjectMeta.self, from: yaml)
        }
    }

    @Test("Mode enum matches the Python raw values")
    func modeRawValues() {
        #expect(Mode.beat.rawValue == "beat")
        #expect(Mode.phrase.rawValue == "phrase")
        #expect(Mode.section.rawValue == "section")
        #expect(Mode.multicam.rawValue == "multicam")
    }

    @Test("parity: fixture project.yaml matches the golden's key fields")
    func fixtureParityWithGolden() throws {
        let fixtureHome = try DataRootResolverTests.fixtureHome()
        let url = fixtureHome.appendingPathComponent("pipeline").appendingPathComponent("project.yaml")
        let meta = try YAMLCoding.decode(ProjectMeta.self, from: url)
        #expect(meta.project == "basic-project")
        #expect(meta.mode == .beat)
        #expect(meta.budgetEur == 50.0)
        #expect(meta.created == "2026-07-06")
    }
}
