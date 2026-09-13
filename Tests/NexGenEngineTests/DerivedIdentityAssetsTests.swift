import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

@Suite("Phase-owned identity provenance")
struct DerivedIdentityAssetsTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try YAMLArtifactStore(dataRoot: root).save(
            ProjectMeta(project: "identity-fixture", mode: .beat), to: PipelineLayout.projectFile
        )
        let source = "import/characters/mouse/front.png"
        try ProjectLocalFile.ensureDirectory("import/characters/mouse", dataRoot: root)
        try Data("confirmed image".utf8).write(to: root.appendingPathComponent(source))
        try ConfirmedIdentityAssetStoreV1.recordIntake(
            role: .character, identityName: "Mouse", identitySlug: "mouse",
            paths: [source], dataRoot: root, confirmedAt: "2026-09-01T00:00:00Z"
        )
        return root
    }

    @Test("legal phase aliases preserve intake bytes and all upstream fingerprints", arguments: ["production_design", "bible"])
    func copyPreservesIntake(phase: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "import/characters/mouse/front.png"
        let destination = "\(phase)/refs/mouse/front.png"
        let intakeURL = root.appendingPathComponent(PipelineLayout.confirmedIdentityAssetsFile)
        let intake = try Data(contentsOf: intakeURL)
        let brief = try MusicvideoPipelineLineage.snapshot(phase: "brief", dataRoot: root)
        try ProjectLocalFile.ensureDirectory("\(phase)/refs/mouse", dataRoot: root)
        try FileManager.default.copyItem(at: root.appendingPathComponent(source), to: root.appendingPathComponent(destination))
        #expect(try DerivedIdentityAssetStoreV1.record(phase: phase, from: source, to: destination, dataRoot: root))
        #expect(try Data(contentsOf: intakeURL) == intake)
        #expect(try MusicvideoPipelineLineage.snapshot(phase: "brief", dataRoot: root) == brief)
        let manifest = try DerivedIdentityAssetStoreV1.load(phase: phase, dataRoot: root)
        let entry = try #require(manifest.entries[destination])
        #expect(entry.sourcePath == source)
        #expect(entry.destinationPath == destination)
        #expect(entry.sourceSHA256 == entry.destinationSHA256)
        #expect(entry.role == .character)
        #expect(entry.phase == phase)
        let sidecar = root.appendingPathComponent(try DerivedIdentityAssetStoreV1.relativePath(phase: phase))
        let bytes = try Data(contentsOf: sidecar)
        #expect(try DerivedIdentityAssetStoreV1.record(phase: phase, from: source, to: destination, dataRoot: root))
        #expect(try Data(contentsOf: sidecar) == bytes)
    }

    @Test("phase ownership and replacement fail before provenance changes")
    func ownershipAndReplacement() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "import/characters/mouse/front.png"
        try ProjectLocalFile.ensureDirectory("bible/refs", dataRoot: root)
        let destination = "bible/refs/front.png"
        try Data("different image".utf8).write(to: root.appendingPathComponent(destination))
        #expect(throws: (any Error).self) {
            try DerivedIdentityAssetStoreV1.record(phase: "bible", from: source, to: destination, dataRoot: root)
        }
        #expect(throws: (any Error).self) {
            try DerivedIdentityAssetStoreV1.record(phase: "storyboard", from: source, to: destination, dataRoot: root)
        }
        #expect(throws: (any Error).self) {
            try DerivedIdentityAssetStoreV1.record(phase: "production_design", from: source, to: destination, dataRoot: root)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bible/derived-identity-assets.v1.json").path))
    }

    @Test("symlink aliases and replaced source images cannot prove identity")
    func symlinkAndChangedSource() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "import/characters/mouse/front.png"
        try ProjectLocalFile.ensureDirectory("bible/refs", dataRoot: root)
        let destination = "bible/refs/front.png"
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(destination), withDestinationURL: root.appendingPathComponent(source))
        #expect(throws: (any Error).self) {
            try DerivedIdentityAssetStoreV1.record(phase: "bible", from: source, to: destination, dataRoot: root)
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent(destination))
        try FileManager.default.copyItem(at: root.appendingPathComponent(source), to: root.appendingPathComponent(destination))
        #expect(try DerivedIdentityAssetStoreV1.record(phase: "bible", from: source, to: destination, dataRoot: root))
        try Data("replacement".utf8).write(to: root.appendingPathComponent(source), options: .atomic)
        #expect(throws: (any Error).self) {
            try DerivedIdentityAssetStoreV1.validate(try DerivedIdentityAssetStoreV1.load(phase: "bible", dataRoot: root), dataRoot: root)
        }
    }

    @Test("phase sidecar bytes participate in every downstream exact lineage", arguments: ["production_design", "bible"])
    func downstreamSidecarBytes(phase: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectLocalFile.ensureDirectory("\(phase)/refs", dataRoot: root)
        let destination = "\(phase)/refs/front.png"
        try FileManager.default.copyItem(at: root.appendingPathComponent("import/characters/mouse/front.png"), to: root.appendingPathComponent(destination))
        let consumers = Array(MusicvideoPipelineLineage.phases.drop { $0 != phase }.dropFirst())
        let before = try consumers.map { try MusicvideoPipelineLineage.snapshot(phase: $0, dataRoot: root) }
        _ = try DerivedIdentityAssetStoreV1.record(phase: phase, from: "import/characters/mouse/front.png", to: destination, dataRoot: root)
        let after = try consumers.map { try MusicvideoPipelineLineage.snapshot(phase: $0, dataRoot: root) }
        #expect(zip(before, after).allSatisfy { $0.0.inputFingerprint != $0.1.inputFingerprint })
        let sidecar = root.appendingPathComponent(try DerivedIdentityAssetStoreV1.relativePath(phase: phase))
        var bytes = try Data(contentsOf: sidecar)
        bytes.append(0x0a)
        try bytes.write(to: sidecar, options: .atomic)
        let changed = try consumers.map { try MusicvideoPipelineLineage.snapshot(phase: $0, dataRoot: root) }
        #expect(zip(after, changed).allSatisfy { $0.0.inputFingerprint != $0.1.inputFingerprint })
    }

    @Test("explicit recovery separates legacy aliases without touching saved project bytes")
    func recoverySeparatesAliases() throws {
        let original = try fixture()
        defer { try? FileManager.default.removeItem(at: original) }
        let copy = original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        try JSONSerialization.data(withJSONObject: [
            "id": "11111111-1111-1111-1111-111111111111", "activePlugin": "musicvideo",
            "activePluginVersion": "0.5.8", "activePluginProjectSchema": "musicvideo/2.0.0",
        ], options: [.sortedKeys]).write(to: original.appendingPathComponent("ngv.json"))
        try YAMLArtifactStore(dataRoot: original).save(Gates(project: "identity-fixture"), to: PipelineLayout.gatesFile)
        try Data("canonical brief".utf8).write(to: original.appendingPathComponent("brief.yaml"))
        try PipelineLineageStore.record(phase: "brief", snapshot: MusicvideoPipelineLineage.snapshot(phase: "brief", dataRoot: original, legacyIdentityLayout: true), dataRoot: original)
        try ProjectLocalFile.ensureDirectory("bible/refs", dataRoot: original)
        try FileManager.default.copyItem(at: original.appendingPathComponent("import/characters/mouse/front.png"), to: original.appendingPathComponent("bible/refs/front.png"))
        #expect(try ConfirmedIdentityAssetStoreV1.adopt(from: "import/characters/mouse/front.png", to: "bible/refs/front.png", dataRoot: original))
        let intakeBytes = try Data(contentsOf: original.appendingPathComponent(PipelineLayout.confirmedIdentityAssetsFile))
        let canonical = try Data(contentsOf: original.appendingPathComponent("brief.yaml"))
        try FileManager.default.copyItem(at: original, to: copy)
        try MusicvideoIdentityRecovery.prepare(projectURL: copy)
        #expect(try Data(contentsOf: original.appendingPathComponent(PipelineLayout.confirmedIdentityAssetsFile)) == intakeBytes)
        #expect(try Data(contentsOf: copy.appendingPathComponent("brief.yaml")) == canonical)
        #expect(try ConfirmedIdentityAssetStoreV1.load(dataRoot: copy).entries.count == 1)
        #expect(try DerivedIdentityAssetStoreV1.load(phase: "bible", dataRoot: copy).entries.count == 1)
        let receipt = try IdentityRecoveryReceiptStoreV1.load(dataRoot: copy)
        #expect(receipt.aliases.count == 1)
        #expect(receipt.sourceSchema == "musicvideo/2.0.0")
        #expect(receipt.targetSchema == "musicvideo/2.1.0")
        #expect(receipt.originalManifestSHA256 == FileDigest.sha256(of: intakeBytes))
        #expect(receipt.phases.isEmpty)
        #expect(receipt.stalePhases.isEmpty)
    }

    @Test("unaffected 2.0 recovery preserves manifests and exact lineage without a repair receipt")
    func unaffectedRecoveryPreservesBytes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: [
            "id": "11111111-1111-1111-1111-111111111111", "activePlugin": "musicvideo",
            "activePluginVersion": "0.5.8", "activePluginProjectSchema": "musicvideo/2.0.0",
        ]).write(to: root.appendingPathComponent("ngv.json"))
        let path = root.appendingPathComponent(PipelineLayout.confirmedIdentityAssetsFile)
        let before = try Data(contentsOf: path)
        let snapshots = try MusicvideoPipelineLineage.phases.map {
            try MusicvideoPipelineLineage.snapshot(phase: $0, dataRoot: root, legacyIdentityLayout: true)
        }
        try MusicvideoIdentityRecovery.prepare(projectURL: root)
        #expect(try Data(contentsOf: path) == before)
        #expect(try MusicvideoPipelineLineage.phases.map {
            try MusicvideoPipelineLineage.snapshot(phase: $0, dataRoot: root)
        } == snapshots)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(IdentityRecoveryReceiptStoreV1.relativePath).path))
    }

    @Test("changed legacy alias fails recovery before intake changes")
    func recoveryRejectsChangedAlias() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: [
            "id": "11111111-1111-1111-1111-111111111111", "activePlugin": "musicvideo",
            "activePluginVersion": "0.5.8", "activePluginProjectSchema": "musicvideo/2.0.0",
        ]).write(to: root.appendingPathComponent("ngv.json"))
        try ProjectLocalFile.ensureDirectory("bible/refs", dataRoot: root)
        try FileManager.default.copyItem(at: root.appendingPathComponent("import/characters/mouse/front.png"), to: root.appendingPathComponent("bible/refs/front.png"))
        _ = try ConfirmedIdentityAssetStoreV1.adopt(from: "import/characters/mouse/front.png", to: "bible/refs/front.png", dataRoot: root)
        let original = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.confirmedIdentityAssetsFile))
        try Data("changed".utf8).write(to: root.appendingPathComponent("bible/refs/front.png"), options: .atomic)
        #expect(throws: (any Error).self) { try MusicvideoIdentityRecovery.prepare(projectURL: root) }
        #expect(try Data(contentsOf: root.appendingPathComponent(PipelineLayout.confirmedIdentityAssetsFile)) == original)
    }
}
