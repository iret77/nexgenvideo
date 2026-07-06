import Foundation
import Testing
@testable import NexGenEngine

@Suite("SchemaVersions")
struct SchemaVersionsTests {
    @Test("matrix carries the current + supported versions per family")
    func matrixContents() {
        #expect(SchemaVersions.matrix["bible"]?.current == "bible/v5")
        #expect(SchemaVersions.matrix["bible"]?.supported == ["bible/v4", "bible/v5"])
        #expect(SchemaVersions.matrix["shotlist"]?.current == "shotlist/v3")
        #expect(SchemaVersions.matrix["shotlist"]?.supported == ["shotlist/v1", "shotlist/v2", "shotlist/v3"])
        #expect(SchemaVersions.matrix["brief"]?.current == "brief/v1")
        #expect(SchemaVersions.matrix["ledger"]?.current == "ledger/v1")
        #expect(SchemaVersions.matrix["frame_audit"]?.current == "frame_audit/v1")
        #expect(SchemaVersions.matrix["storyboard"]?.current == "storyboard/v1")
        // Treatment has no versioned `schema` field — not in the matrix.
        #expect(SchemaVersions.matrix["treatment"] == nil)
    }

    @Test("parseVersion extracts the trailing integer")
    func parseVersion() {
        #expect(SchemaVersions.parseVersion("bible/v5") == 5)
        #expect(SchemaVersions.parseVersion("shotlist/v12") == 12)
        #expect(SchemaVersions.parseVersion("no-version-here") == nil)
        #expect(SchemaVersions.parseVersion("") == nil)
    }

    @Test("classify: matching version")
    func classifyMatch() {
        let (status, _) = SchemaVersions.classify(projectVersion: "bible/v5", schemaKey: "bible")
        #expect(status == .match)
    }

    @Test("classify: behind but supported (migration possible)")
    func classifyBehind() {
        let (status, _) = SchemaVersions.classify(projectVersion: "bible/v4", schemaKey: "bible")
        #expect(status == .behind)
    }

    @Test("classify: ahead — project version newer than the skill knows (hard stop)")
    func classifyAhead() {
        let (status, _) = SchemaVersions.classify(projectVersion: "bible/v6", schemaKey: "bible")
        #expect(status == .ahead)
    }

    @Test("classify: unknown — declared version neither current nor supported, and not numerically ahead")
    func classifyUnknown() {
        let (status, _) = SchemaVersions.classify(projectVersion: "bible/vX", schemaKey: "bible")
        #expect(status == .unknown)
    }

    @Test("classify: missing — no project version at all")
    func classifyMissing() {
        let (status, _) = SchemaVersions.classify(projectVersion: nil, schemaKey: "bible")
        #expect(status == .missing)
    }

    @Test("anyAhead is true only when at least one finding is ahead")
    func anyAheadDetection() {
        let findings: [SchemaVersions.Finding] = [
            .init(artifact: "a", schemaField: "bible", projectVersion: "bible/v5", skillCurrent: "bible/v5", status: .match, message: ""),
            .init(artifact: "b", schemaField: "shotlist", projectVersion: "shotlist/v1", skillCurrent: "shotlist/v3", status: .behind, message: ""),
        ]
        #expect(SchemaVersions.anyAhead(findings) == false)
        let withAhead = findings + [
            .init(artifact: "c", schemaField: "storyboard", projectVersion: "storyboard/v2", skillCurrent: "storyboard/v1", status: .ahead, message: ""),
        ]
        #expect(SchemaVersions.anyAhead(withAhead) == true)
    }

    @Test("checkProjectVersions: missing artifacts report status .missing")
    func checkProjectVersionsAllMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexgen-schema-versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let findings = SchemaVersions.checkProjectVersions(dataRoot: tmp)
        #expect(findings.count == 4)
        #expect(findings.allSatisfy { $0.status == .missing })
        #expect(SchemaVersions.anyAhead(findings) == false)
    }

    @Test("checkProjectVersions: reads the schema field from a real file on disk")
    func checkProjectVersionsReadsRealFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexgen-schema-versions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try "schema: brief/v1\nproject: p\n".write(
            to: tmp.appendingPathComponent("brief.yaml"), atomically: true, encoding: .utf8
        )

        let findings = SchemaVersions.checkProjectVersions(dataRoot: tmp)
        let brief = try #require(findings.first { $0.schemaField == "brief" })
        #expect(brief.projectVersion == "brief/v1")
        #expect(brief.status == .match)
    }

    @Test("parity: fixture brief.yaml is on the current schema version")
    func fixtureBriefIsCurrent() throws {
        let fixtureHome = try DataRootResolverTests.fixtureHome()
        let dataRoot = fixtureHome.appendingPathComponent("_studio")
        let findings = SchemaVersions.checkProjectVersions(dataRoot: dataRoot)
        let brief = try #require(findings.first { $0.schemaField == "brief" })
        #expect(brief.projectVersion == "brief/v1")
        #expect(brief.status == .match)
        #expect(SchemaVersions.anyAhead(findings) == false)
    }
}
