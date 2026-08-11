import Foundation
import Testing

@testable import NexGenEngine

/// #202: the auto-migrate mechanism the LOCKED storage model mandates. Before this, a schema bump
/// stranded existing `.ngv` projects with a warning pointing at a CLI that was never ported.
@Suite("Schema migration")
struct SchemaMigratorTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexgen-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A valid bible written down to the OLD schema — exactly what an existing project on disk holds.
    private func writeBibleV4(in dataRoot: URL) throws -> URL {
        var bible = try BibleTests.minimalBible()
        bible.schema = "bible/v4"
        let url = dataRoot.appendingPathComponent("bible/bible.yaml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try YAMLCoding.encode(bible).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func schemaField(at url: URL) -> String? { SchemaVersions.readSchemaField(at: url) }

    @Test("a v4 bible is lifted to v5, keeps its content, and leaves a pre-migration backup")
    func migratesBibleV4ToV5() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeBibleV4(in: root)
        let before = try String(contentsOf: url, encoding: .utf8)

        let results = try SchemaMigrator.migrateProject(dataRoot: root)

        let bible = try #require(results.first { $0.artifact == "bible/bible.yaml" })
        #expect(bible.from == "bible/v4")
        #expect(bible.to == "bible/v5")
        #expect(schemaField(at: url) == "bible/v5")

        // The migration re-stamps the schema and nothing else: content survives.
        let migrated = try YAMLCoding.decode(Bible.self, from: url)
        let original = try BibleTests.minimalBible()
        #expect(migrated.characters == original.characters)
        #expect(migrated.locations == original.locations)
        #expect(migrated.project == original.project)

        // The pre-migration file is preserved verbatim, so a bad migration stays inspectable.
        let backup = try #require(bible.backup)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try String(contentsOf: backup, encoding: .utf8) == before)
        #expect(backup.lastPathComponent.contains("pre-bible-v4"))
    }

    @Test("migration is idempotent — a second open migrates nothing and writes nothing")
    func idempotent() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeBibleV4(in: root)

        #expect(try SchemaMigrator.migrateProject(dataRoot: root).count == 1)
        let afterFirst = try String(contentsOf: url, encoding: .utf8)

        #expect(try SchemaMigrator.migrateProject(dataRoot: root).isEmpty)
        #expect(try String(contentsOf: url, encoding: .utf8) == afterFirst)
        // Exactly one backup — the no-op pass must not litter.
        let backups = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("pre-bible") }
        #expect(backups.count == 1)
    }

    @Test("a dry run reports the migration but touches nothing")
    func dryRunWritesNothing() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeBibleV4(in: root)
        let before = try String(contentsOf: url, encoding: .utf8)

        let results = try SchemaMigrator.migrateProject(dataRoot: root, dryRun: true)
        #expect(results.count == 1)
        #expect(results.first?.backup == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
        #expect(schemaField(at: url) == "bible/v4")
    }

    /// A project written by a NEWER engine must never be "migrated" down — that would drop fields the
    /// running engine doesn't know. Hard stop, file untouched.
    @Test("a project ahead of the engine throws and is left alone")
    func aheadOfEngineIsAHardStop() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("bible/bible.yaml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bible = try BibleTests.minimalBible()
        bible.schema = "bible/v5"
        var yaml = try YAMLCoding.encode(bible)
        yaml = yaml.replacingOccurrences(of: "schema: bible/v5", with: "schema: bible/v9")
        try yaml.write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: SchemaMigrator.MigrationError.projectAheadOfEngine(
            artifact: "bible/bible.yaml", projectVersion: "bible/v9", engineCurrent: "bible/v5")) {
            try SchemaMigrator.migrateProject(dataRoot: root)
        }
        #expect(schemaField(at: url) == "bible/v9")
    }

    @Test("an empty project migrates nothing")
    func emptyProjectIsANoOp() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try SchemaMigrator.migrateProject(dataRoot: root).isEmpty)
    }

    /// The shotlist lives as `shotlist/vN.yaml` (no `current.yaml` mirror). The version check used to
    /// look for `shotlist/current.yaml`, so a shotlist was invisible to it — always `.missing`, never
    /// migratable. Uses the real fixture, downgraded, so this runs against a shotlist the engine
    /// actually writes.
    @Test("a shotlist is found at its real versioned path and lifted v1 -> v4")
    func migratesShotlistAtVersionedPath() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try DataRootResolverTests.fixtureHome()
            .appendingPathComponent("pipeline/shotlist/v1.yaml")
        let url = root.appendingPathComponent("shotlist/v1.yaml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let downgraded = try String(contentsOf: fixture, encoding: .utf8)
            .replacingOccurrences(of: "schema: shotlist/v4", with: "schema: shotlist/v1")
        try downgraded.write(to: url, atomically: true, encoding: .utf8)

        // The check must SEE it — the bug this guards is it reporting `.missing`.
        let finding = try #require(
            SchemaVersions.checkProjectVersions(dataRoot: root).first { $0.schemaField == "shotlist" })
        #expect(finding.artifact == "shotlist/v1.yaml")
        #expect(finding.status == .behind)

        let results = try SchemaMigrator.migrateProject(dataRoot: root)
        let shotlist = try #require(results.first { $0.artifact.hasPrefix("shotlist/") })
        #expect(shotlist.from == "shotlist/v1")
        #expect(shotlist.to == "shotlist/v4")
        #expect(schemaField(at: url) == "shotlist/v4")
        // Shots survive the round-trip intact.
        let migrated = try #require(try loadShotlist(dataRoot: root))
        #expect(migrated.shots.map(\.id) == ["s001", "s002", "s003", "s004"])
    }

    @Test("the highest shotlist revision is the one checked and migrated")
    func picksHighestShotlistRevision() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("shotlist")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixture = try String(
            contentsOf: DataRootResolverTests.fixtureHome()
                .appendingPathComponent("pipeline/shotlist/v1.yaml"), encoding: .utf8)
        try fixture.replacingOccurrences(of: "schema: shotlist/v4", with: "schema: shotlist/v1")
            .write(to: dir.appendingPathComponent("v1.yaml"), atomically: true, encoding: .utf8)
        try fixture.write(to: dir.appendingPathComponent("v2.yaml"), atomically: true, encoding: .utf8)

        // v2.yaml is the live document and is already current → nothing to migrate; the stale v1.yaml
        // revision is not resurrected.
        #expect(try SchemaMigrator.migrateProject(dataRoot: root).isEmpty)
        #expect(schemaField(at: dir.appendingPathComponent("v1.yaml")) == "shotlist/v1")
    }
}
