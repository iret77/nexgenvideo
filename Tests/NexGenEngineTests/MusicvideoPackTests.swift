import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// Port of `plugins/musicvideo/tests/test_pack.py`.
@Suite("Musicvideo Pack", .serialized)
struct MusicvideoPackTests {
    @Test("pack registers music behavior")
    func packRegistersMusicBehavior() {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        #expect(reg.engine.durationPolicy != nil)
        #expect(reg.engine.projectDirs.contains("audio"))
        #expect(reg.engine.projectDirs.contains("analysis"))
        #expect(reg.engine.sanityChecks["tempo"] != nil)
        #expect(reg.engine.phases["analysis"] != nil)
        #expect(reg.engine.progressPhaseRunners["analysis"] != nil)
    }

    @Test("music duration bands")
    func musicDurationBands() {
        let policy = MusicDurationPolicy()
        let band = policy.band(for: .section, context: [:])
        #expect((band.minS, band.maxS) == (6.0, 60.0))
    }

    @Test("all mode duration bands carried over exactly")
    func allModeDurationBandsExact() {
        let policy = MusicDurationPolicy()
        #expect((policy.band(for: .beat, context: [:]).minS, policy.band(for: .beat, context: [:]).maxS) == (4.0, 15.0))
        #expect(
            (policy.band(for: .phrase, context: [:]).minS, policy.band(for: .phrase, context: [:]).maxS) == (4.0, 15.0)
        )
        #expect(
            (policy.band(for: .section, context: [:]).minS, policy.band(for: .section, context: [:]).maxS)
                == (6.0, 60.0)
        )
        #expect(
            (policy.band(for: .multicam, context: [:]).minS, policy.band(for: .multicam, context: [:]).maxS)
                == (30.0, 600.0)
        )
    }

    @Test("pack satisfies the Pack contract")
    func packSatisfiesContract() {
        let pack: Pack = MusicvideoPack()
        #expect(pack.name == "musicvideo")
        #expect(pack.version == "0.0.16")
        #expect(pack.manifest.minAppVersion == "1.0.9")
    }

    @Test("pack exposes gallery manifest and a starter")
    func packExposesManifestAndStarters() throws {
        let pack: Pack = MusicvideoPack()
        // Mirrors plugins/musicvideo.json.
        #expect(pack.manifest.displayName == "Music Video")
        #expect(pack.manifest.tagline.isEmpty == false)
        // Badge ships inside the pack's own resource bundle (self-contained).
        let badge = try #require(pack.manifest.badgeURL)
        #expect(FileManager.default.fileExists(atPath: badge.path))
        #expect(pack.starters.isEmpty == false)
    }

    @Test("pack registers the analysis UI contract entry")
    func packRegistersUIContract() {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        let entry = reg.engine.uiContracts["analysis"]
        #expect(entry?.surface == "choice")
        #expect(entry?.taskClass == "classification")
    }

    @Test("pack registers every declared project-schema migration")
    func packRegistersProjectMigrations() {
        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        let migrations = reg.engine.projectSchemaMigrations
        #expect(migrations.contains {
            $0.from == "musicvideo/legacy" && $0.to == "musicvideo/1.0.0"
        })
        #expect(migrations.count == 1)
    }

    @Test("legacy schema adoption preserves existing pack artifacts byte-for-byte")
    func legacySchemaAdoptionIsDataIdentical() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "musicvideo-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("project.yaml")
        let before = Data("project: legacy\n".utf8)
        try before.write(to: artifact)

        let reg = PackRegistry()
        reg.load(MusicvideoPack())
        let migration = try #require(
            reg.engine.projectSchemaMigrations.first
        )
        try migration.migrate(root)

        #expect(try Data(contentsOf: artifact) == before)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: root.path
            ) == ["project.yaml"]
        )
    }
}
