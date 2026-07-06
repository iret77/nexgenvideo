import Foundation
import Testing
@testable import NexGenEngine

@Suite("Treatment")
struct TreatmentTests {
    static func sampleMeta(version: Int = 1) throws -> TreatmentMeta {
        try TreatmentMeta(
            project: "basic-project",
            version: version,
            generated: "2026-01-01T00:00:00Z",
            origin: .agentProposal,
            generator: "treatment-agent@v0.3",
            summaryOneline: "A short one-line summary.",
            title: "Working Title",
            notes: "some notes"
        )
    }

    @Test("round-trips through serialize/parse")
    func roundTrip() throws {
        let meta = try Self.sampleMeta()
        let treatment = Treatment(meta: meta, bodyMarkdown: "# Act One\n\nSomething happens.\n")

        let raw = try treatment.serialized()
        let parsed = try Treatment.parsing(raw)

        #expect(parsed == treatment)
    }

    @Test("frontmatter matches a hand-written minimal example semantically")
    func frontmatterMatchesHandwritten() throws {
        let meta = try TreatmentMeta(
            project: "p",
            version: 1,
            generated: "2026-01-01",
            origin: .agentProposal,
            generator: "treatment-agent@v0.3",
            summaryOneline: "Short summary"
        )
        let treatment = Treatment(meta: meta, bodyMarkdown: "Body text.\n")
        let raw = try treatment.serialized()

        // Extract just the frontmatter portion (between the two "---" lines).
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let closingIndex = try #require(lines.dropFirst().firstIndex(where: { $0 == "---" }))
        let frontmatter = lines[1..<closingIndex].joined(separator: "\n")

        let handwritten = """
        schema: treatment/v1
        project: p
        version: 1
        generated: '2026-01-01'
        origin: agent_proposal
        generator: treatment-agent@v0.3
        summary_oneline: Short summary
        """
        #expect(try YAMLCoding.semanticYAMLEqual(frontmatter, handwritten))
    }

    @Test("parsing preserves the body verbatim, including leading blank lines")
    func bodyPreservedVerbatim() throws {
        let meta = try Self.sampleMeta()
        let body = "\nLine one.\n\nLine two.\n"
        let treatment = Treatment(meta: meta, bodyMarkdown: body)
        let raw = try treatment.serialized()
        let parsed = try Treatment.parsing(raw)
        #expect(parsed.bodyMarkdown == body)
    }

    @Test("version below 1 throws on construction")
    func versionMustBePositive() throws {
        #expect(throws: TreatmentMeta.ValidationError.self) {
            _ = try TreatmentMeta(
                project: "p",
                version: 0,
                generated: "2026-01-01",
                origin: .agentProposal,
                generator: "g",
                summaryOneline: "s"
            )
        }
    }

    @Test("version below 1 throws on decode")
    func versionMustBePositiveOnDecode() throws {
        let yaml = """
        project: p
        version: 0
        generated: '2026-01-01'
        origin: agent_proposal
        generator: g
        summary_oneline: s
        """
        #expect(throws: (any Error).self) {
            _ = try YAMLCoding.decode(TreatmentMeta.self, from: yaml)
        }
    }

    @Test(
        "all 8 origin literal values round-trip",
        arguments: [
            TreatmentOrigin.agentProposal,
            .agentRevision,
            .userSupplied,
            .userRevision,
            .brainstormClaude,
            .brainstormOpenai,
            .brainstormGemini,
            .brainstormSynthesis,
        ]
    )
    func originRoundTrips(_ origin: TreatmentOrigin) throws {
        let meta = try TreatmentMeta(
            project: "p",
            version: 1,
            generated: "2026-01-01",
            origin: origin,
            generator: "g",
            summaryOneline: "s"
        )
        let yaml = try YAMLCoding.encode(meta)
        let decoded = try YAMLCoding.decode(TreatmentMeta.self, from: yaml)
        #expect(decoded.origin == origin)
    }

    @Test("all 8 origin literal values match the exact Python raw strings")
    func originRawValuesMatchPython() {
        #expect(TreatmentOrigin.agentProposal.rawValue == "agent_proposal")
        #expect(TreatmentOrigin.agentRevision.rawValue == "agent_revision")
        #expect(TreatmentOrigin.userSupplied.rawValue == "user_supplied")
        #expect(TreatmentOrigin.userRevision.rawValue == "user_revision")
        #expect(TreatmentOrigin.brainstormClaude.rawValue == "brainstorm_claude")
        #expect(TreatmentOrigin.brainstormOpenai.rawValue == "brainstorm_openai")
        #expect(TreatmentOrigin.brainstormGemini.rawValue == "brainstorm_gemini")
        #expect(TreatmentOrigin.brainstormSynthesis.rawValue == "brainstorm_synthesis")
        #expect(TreatmentOrigin.allCases.count == 8)
    }

    @Test("parsing throws on missing frontmatter")
    func parsingMissingFrontmatterThrows() {
        #expect(throws: Treatment.ParseError.self) {
            _ = try Treatment.parsing("# Just a heading\n\nNo frontmatter here.\n")
        }
    }
}
