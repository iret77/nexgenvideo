import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

@Suite("Cumulative production style lineage")
struct ProductionStyleLineageTests {
    @Test("downstream identity copies do not invalidate earlier phases")
    func identityAdoptionDoesNotChangeUpstreamInputs() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        let root = try ProjectScaffold.initProject(home: home, name: "lineage")
        defer { try? FileManager.default.removeItem(at: home) }
        let source = root.appendingPathComponent(
            "import/characters/mouse/front.png"
        )
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("mouse".utf8).write(to: source)
        try ConfirmedIdentityAssetStoreV1.recordIntake(
            role: .character,
            identityName: "Mouse",
            identitySlug: "mouse",
            paths: ["import/characters/mouse/front.png"],
            dataRoot: root,
            confirmedAt: "2026-09-11T00:00:00Z"
        )
        let confirmationURL = root.appendingPathComponent(
            PipelineLayout.confirmedIdentityAssetsFile
        )
        let confirmationBeforeCopy = try Data(contentsOf: confirmationURL)
        #expect(
            try ConfirmedIdentityAssetStoreV1.intakeLineageSHA256(
                dataRoot: root
            ) == FileDigest.sha256(of: confirmationBeforeCopy)
        )
        let phases = ["brief", "production_design", "treatment", "storyboard"]
        let before = try phases.map {
            try MusicvideoPipelineLineage.snapshot(
                phase: $0,
                dataRoot: root
            ).inputFingerprint
        }
        let destination = root.appendingPathComponent("bible/mouse/front.png")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)

        #expect(try ConfirmedIdentityAssetStoreV1.adopt(
            from: "import/characters/mouse/front.png",
            to: "bible/mouse/front.png",
            dataRoot: root
        ))
        #expect(try Data(contentsOf: confirmationURL) == confirmationBeforeCopy)
        #expect(try ConfirmedIdentityAssetStoreV1.matchesCurrent(
            "bible/mouse/front.png",
            role: .character,
            identityID: "mouse",
            identityName: "Mouse",
            dataRoot: root
        ))
        let sourceEntry = try #require(
            ConfirmedIdentityAssetStoreV1.load(dataRoot: root).entries[
                "import/characters/mouse/front.png"
            ]
        )
        var legacyManifest = try ConfirmedIdentityAssetStoreV1.load(
            dataRoot: root
        )
        legacyManifest.entries["bible/mouse/front.png"] = ConfirmedIdentityAssetV1(
            id: "legacy-adoption",
            role: sourceEntry.role,
            identityName: sourceEntry.identityName,
            identitySlug: sourceEntry.identitySlug,
            path: "bible/mouse/front.png",
            sha256: sourceEntry.sha256,
            originalPath: sourceEntry.originalPath,
            originalSHA256: sourceEntry.originalSHA256,
            confirmedAt: sourceEntry.confirmedAt
        )
        try ConfirmedIdentityAssetStoreV1.save(
            legacyManifest,
            dataRoot: root
        )
        #expect(try Data(contentsOf: confirmationURL) != confirmationBeforeCopy)
        let after = try phases.map {
            try MusicvideoPipelineLineage.snapshot(
                phase: $0,
                dataRoot: root
            ).inputFingerprint
        }
        #expect(after == before)
    }

    @Test("style changes and explicit removal remain downstream inputs")
    func styleDependency() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = try ProjectScaffold.initProject(home: home, name: "lineage")
        defer { try? FileManager.default.removeItem(at: home) }
        let phases = ["treatment", "storyboard", "bible"]
        func fingerprints() throws -> [String] {
            try phases.map { try MusicvideoPipelineLineage.snapshot(phase: $0, dataRoot: root).inputFingerprint }
        }
        let legacy = try fingerprints()
        let style = root.appendingPathComponent(ResolvedProductionStyleV1.relativePath)
        try FileManager.default.createDirectory(at: style.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(try fingerprints() == legacy)
        try Data("style one".utf8).write(to: style)
        let first = try fingerprints()
        try Data("style two".utf8).write(to: style)
        let second = try fingerprints()
        #expect(zip(first, second).allSatisfy { $0 != $1 })
        try FileManager.default.removeItem(at: style)
        try PipelineLineageStore.record(phase: ProductionStyleStoreV1.lineageID,
            snapshot: .init(inputFingerprint: "fixture", artifactFingerprint: "none"), dataRoot: root)
        let cleared = try fingerprints()
        #expect(zip(cleared, legacy).allSatisfy { $0 != $1 })
    }
}
