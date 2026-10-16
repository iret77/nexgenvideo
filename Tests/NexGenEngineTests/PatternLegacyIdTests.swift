import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// Stored projects keep retired pattern ids, so every lookup must resolve them.
@Suite("Pattern legacy ids", .serialized)
struct PatternLegacyIdTests {
    private static let retired = "visual-album-khalil-joseph"
    private static let current = "visual-album-kahlil-joseph"

    private func renamedPattern() throws -> Pattern {
        try #require(try Patterns.loadAllPatterns().first { $0.id == Self.current })
    }

    @Test("every retired id points at a bundled pattern and shadows no live id")
    func aliasTableIsConsistent() throws {
        let ids = Set(try Patterns.loadAllPatterns().map(\.id))
        #expect(Patterns.legacyIds[Self.retired] == Self.current)
        for (retiredId, currentId) in Patterns.legacyIds {
            #expect(ids.contains(currentId), "\(retiredId) points at the missing pattern \(currentId)")
            #expect(!ids.contains(retiredId), "\(retiredId) is still a live pattern id")
        }
    }

    @Test("an old director_pattern value resolves to the renamed pattern")
    func retiredValueResolves() throws {
        let library = try Patterns.loadAllPatterns()
        #expect(Patterns.pattern(withId: Self.retired, in: library)?.id == Self.current)
        #expect(Patterns.pattern(withId: "  \(Self.retired)  ", in: library)?.id == Self.current)
        #expect(Patterns.pattern(withId: Self.current, in: library)?.id == Self.current)
        #expect(Patterns.pattern(withId: "   ", in: library) == nil)
        #expect(Patterns.pattern(withId: "no-such-pattern-xyz", in: library) == nil)
    }

    @Test("get_pattern returns the renamed pattern for the retired id")
    func providerResolvesRetiredId() throws {
        let data = try #require(try MusicvideoPatternProvider().get(id: Self.retired))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? String == Self.current)
    }

    @Test("PATTERN_DRIFT holds the shotlist to the pattern behind a retired brief director_pattern")
    func driftResolvesRetiredBriefValue() throws {
        let framing = try PatternDriftTests.rarestFraming(try renamedPattern())
        let shots = try (1...6).map { try PatternDriftTests.shot($0, framing: framing) }
        let ctx = AuditContext(
            shotlist: try PatternDriftTests.shotlist(shots),
            brief: try PatternDriftTests.brief(pattern: Self.retired))
        let findings = try MusicvideoChecks.patternDriftCheck(ctx)
        #expect(findings.contains {
            $0.code == "PATTERN_DRIFT" && $0.message.contains("pattern \"\(Self.current)\"")
        })
    }

    @Test("PATTERN_DRIFT resolves a retired section pattern_override")
    func driftResolvesRetiredSectionOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-pattern-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try StoryboardStore.save(
            try Storyboard(
                meta: try StoryboardMeta(
                    project: "proj", version: 1, generated: "2026-01-01T00:00:00Z",
                    summaryOneline: "Section override with a retired pattern id."),
                sections: [try Section(id: "verse", patternOverride: Self.retired)]),
            to: root)

        let framing = try PatternDriftTests.rarestFraming(try renamedPattern())
        let shots = try (1...6).map { try PatternDriftTests.shot($0, framing: framing) }
        let ctx = AuditContext(
            shotlist: try PatternDriftTests.shotlist(shots),
            brief: try PatternDriftTests.brief(pattern: nil),
            extra: ["data_root": root.path])
        let findings = try MusicvideoChecks.patternDriftCheck(ctx)
        #expect(findings.contains {
            $0.code == "PATTERN_DRIFT" && $0.message.contains("Section \"verse\"")
                && $0.message.contains("pattern \"\(Self.current)\"")
        })
    }

    @Test("a retired id in excluded_pattern_ids binds the same project profile as the current id")
    func retiredExclusionMatchesCurrentId() throws {
        let brief = try PatternDriftTests.brief(pattern: nil)
        func profileHash(excluding id: String) throws -> String {
            try PatternFitLibrary.recommend(brief: brief, perceivedBpm: 92, excludedPatternIds: [id])
                .set.projectProfileSha256
        }
        #expect(try profileHash(excluding: Self.retired) == (try profileHash(excluding: Self.current)))
        #expect(try profileHash(excluding: Self.retired) != (try profileHash(excluding: "no-such-pattern-xyz")))
    }
}
