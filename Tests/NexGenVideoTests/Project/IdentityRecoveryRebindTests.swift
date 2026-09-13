import Foundation
import Testing
@testable import NexGenVideo
@testable import NexGenEngine
@testable import MusicvideoPlugin

@MainActor
@Suite("Reviewed identity recovery")
struct IdentityRecoveryRebindTests {
    private static let order = ["project_init", "analysis", "brief", "production_design"]

    private struct Fixture {
        let saved: URL
        let root: URL
        let key: String
        let registry: EngineRegistry
        let original: [String: Data]
    }

    private func fixture(invalidPhase: String? = nil, missingDesign: Bool = false, approved: Bool = true) throws -> Fixture {
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID().uuidString).ngv")
        try Fixtures.prepareProjectPackage(at: saved)
        let root = try ProjectScaffold.initProject(home: saved, name: "rebind", mode: .beat)
        let sourceBinding = try #require(ProjectPackBinding(id: "musicvideo", version: "0.5.8", projectSchema: "musicvideo/2.0.0"))
        try ProjectPluginSettings.setActivePlugin(sourceBinding, projectURL: saved)
        let store = YAMLArtifactStore(dataRoot: root)
        var gates = Gates(project: "rebind")
        if approved { for phase in Self.order { GatesOperations.approve(&gates, phase: phase) } }
        try store.save(gates, to: PipelineLayout.gatesFile)
        try ProjectLocalFile.ensureDirectory("audio", dataRoot: root)
        try Data("source-track".utf8).write(to: root.appendingPathComponent("audio/song.wav"))
        try ProjectLocalFile.ensureDirectory("analysis", dataRoot: root)
        try JSONSerialization.data(withJSONObject: [
            "project": "rebind", "bpm": 120,
            "song_sha256": FileDigest.sha256(of: Data("source-track".utf8)),
        ], options: [.sortedKeys]).write(to: root.appendingPathComponent("analysis/song.json"))
        try ProjectLocalFile.ensureDirectory("import/characters/mouse", dataRoot: root)
        let source = "import/characters/mouse/front.png"
        try Data("exact identity image".utf8).write(to: root.appendingPathComponent(source))
        try ConfirmedIdentityAssetStoreV1.recordIntake(role: .character, identityName: "Mouse", identitySlug: "mouse",
            paths: [source], dataRoot: root, confirmedAt: "2026-09-01T00:00:00Z")
        try store.save(try Brief(project: "rebind", generated: "2026-09-01T00:00:00Z", mission: .demo,
            targetPlatform: invalidPhase == "brief" ? " " : "YouTube", aspectRatio: .landscape16x9,
            projectMode: "beat", conceptType: .narrative, visualMedium: .liveActionRealistic,
            figures: .none, lyricsIntegration: .metaphorical), to: PipelineLayout.briefFile)
        for phase in ["analysis", "brief"] {
            try PipelineLineageStore.record(phase: phase,
                snapshot: MusicvideoPipelineLineage.snapshot(phase: phase, dataRoot: root, legacyIdentityLayout: true), dataRoot: root)
        }
        let destination = "production_design/refs/front.png"
        try ProjectLocalFile.ensureDirectory("production_design/refs", dataRoot: root)
        try FileManager.default.copyItem(at: root.appendingPathComponent(source), to: root.appendingPathComponent(destination))
        _ = try ConfirmedIdentityAssetStoreV1.adopt(from: source, to: destination, dataRoot: root)
        try store.save(try ProductionDesign(project: "rebind", generated: "2026-09-01T00:00:00Z", generator: "fixture",
            visualMedium: invalidPhase == "production_design" ? .animation2d : .liveActionRealistic,
            refs: [ProductionDesignReference(path: destination)]), to: PipelineLayout.productionDesignFile)
        try PipelineLineageStore.record(phase: "production_design",
            snapshot: MusicvideoPipelineLineage.snapshot(phase: "production_design", dataRoot: root, legacyIdentityLayout: true), dataRoot: root)
        if missingDesign { try FileManager.default.removeItem(at: root.appendingPathComponent(PipelineLayout.productionDesignFile)) }
        let original = try fileBytes(in: saved)
        let key = try ProjectIdentity.key(for: saved)
        let recovery = try ProjectWorkingCopy.materialize(key: key, packageURL: saved)
        let registry = EngineRegistry()
        for phase in Self.order {
            if phase != "project_init" {
                registry.registerPhaseLineageProvider(phase) { try MusicvideoPipelineLineage.snapshot(phase: phase, dataRoot: $0) }
            }
            registry.registerGateRequirement(phase) { try Self.requireStructure(phase: phase, root: $0) }
        }
        let target = try #require(ProjectPackBinding(id: "musicvideo", version: "0.5.9", projectSchema: "musicvideo/2.1.0"))
        try ProjectWorkingCopy.transact(key: key) { staging in
            try MusicvideoIdentityRecovery.prepare(projectURL: staging, registry: registry)
            try ProjectPluginSettings.setActivePlugin(target, projectURL: staging)
        }
        return Fixture(saved: saved, root: try #require(DataRootResolver.dataRoot(of: recovery)), key: key, registry: registry, original: original)
    }

    nonisolated private static func requireStructure(phase: String, root: URL) throws {
        let store = YAMLArtifactStore(dataRoot: root)
        let project = try store.load(ProjectMeta.self, at: PipelineLayout.projectFile)
        switch phase {
        case "project_init":
            try project.validate()
            _ = try ProjectLocalFile.resolve("audio/song.wav", dataRoot: root)
        case "analysis":
            let data = try Data(contentsOf: ProjectLocalFile.resolve("analysis/song.json", dataRoot: root))
            guard let measured = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  measured["project"] as? String == project.project,
                  (measured["bpm"] as? Double ?? 0) > 0,
                  measured["song_sha256"] as? String == (try FileDigest.sha256(of: ProjectLocalFile.resolve("audio/song.wav", dataRoot: root))) else {
                throw GateBlocked("Analysis does not prove the current track.")
            }
        case "brief":
            try MusicvideoGateChecks.requireRealBrief(dataRoot: root)
        case "production_design":
            let design = try store.load(ProductionDesign.self, at: PipelineLayout.productionDesignFile)
            let brief = try store.load(Brief.self, at: PipelineLayout.briefFile)
            try design.validate()
            guard design.project == project.project, design.visualMedium == brief.visualMedium else {
                throw GateBlocked("Production Design does not match the approved Brief.")
            }
            for reference in design.refs { _ = try ProjectLocalFile.resolve(reference.path, dataRoot: root) }
            try DerivedIdentityAssetStoreV1.validate(DerivedIdentityAssetStoreV1.load(phase: phase, dataRoot: root), dataRoot: root)
        default: throw GateBlocked("Unknown fixture phase.")
        }
    }

    private func fileBytes(in root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private func cleanup(_ fixture: Fixture) {
        ProjectWorkingCopy.discard(key: fixture.key)
        try? FileManager.default.removeItem(at: fixture.saved)
    }

    @Test("real migration candidates rebind transactionally without changing saved or canonical bytes")
    func reviewedRebind() throws {
        let f = try fixture()
        defer { cleanup(f) }
        let receipt = try IdentityRecoveryReceiptStoreV1.load(dataRoot: f.root)
        #expect(Set(receipt.phases.keys) == ["analysis", "brief", "production_design"])
        #expect(receipt.stalePhases.isEmpty)
        #expect(receipt.phases["production_design"]?.original != receipt.phases["production_design"]?.recovered)
        let preview = try #require(IdentityRecoveryRebind.preview(dataRoot: f.root, order: Self.order, registry: f.registry))
        #expect(preview.phases == ["analysis", "brief", "production_design"])
        let canonical = try Data(contentsOf: f.root.appendingPathComponent(PipelineLayout.productionDesignFile))
        let receiptBytes = try Data(contentsOf: f.root.appendingPathComponent(IdentityRecoveryReceiptStoreV1.relativePath))
        try ProjectWorkingCopy.transact(key: f.key) { staging in
            try IdentityRecoveryRebind.apply(preview, dataRoot: #require(DataRootResolver.dataRoot(of: staging)), order: Self.order, registry: f.registry)
        }
        #expect(try ProjectStateBuilder.approvalValidity(dataRoot: f.root, order: Self.order, registry: f.registry)["production_design"]?.isCurrent == true)
        #expect(try Data(contentsOf: f.root.appendingPathComponent(PipelineLayout.productionDesignFile)) == canonical)
        #expect(try Data(contentsOf: f.root.appendingPathComponent(IdentityRecoveryReceiptStoreV1.relativePath)) == receiptBytes)
        #expect(try fileBytes(in: f.saved) == f.original)
        #expect(try IdentityRecoveryRebind.preview(dataRoot: f.root, order: Self.order, registry: f.registry) == nil)
    }

    @Test("migration filters structurally invalid approval candidates and descendants", arguments: ["brief", "production_design"])
    func filtersInvalidCandidates(phase: String) throws {
        let f = try fixture(invalidPhase: phase)
        defer { cleanup(f) }
        let receipt = try IdentityRecoveryReceiptStoreV1.load(dataRoot: f.root)
        #expect(Set(receipt.phases.keys) == (phase == "brief" ? ["analysis"] : ["analysis", "brief"]))
        #expect(Set(receipt.stalePhases) == (phase == "brief" ? ["brief", "production_design"] : ["production_design"]))
        #expect(try fileBytes(in: f.saved) == f.original)
    }

    @Test("missing canonical bytes remain stale during actual migration")
    func filtersMissingCanonical() throws {
        let f = try fixture(missingDesign: true)
        defer { cleanup(f) }
        let receipt = try IdentityRecoveryReceiptStoreV1.load(dataRoot: f.root)
        #expect(receipt.phases["production_design"] == nil)
        #expect(receipt.stalePhases.contains("production_design"))
        #expect(try fileBytes(in: f.saved) == f.original)
    }

    @Test("changed or missing canonical bytes after preview cannot rebind", arguments: [false, true])
    func rejectsChangedPreview(missing: Bool) throws {
        let f = try fixture()
        defer { cleanup(f) }
        let preview = try #require(IdentityRecoveryRebind.preview(dataRoot: f.root, order: Self.order, registry: f.registry))
        let lineage = try Data(contentsOf: f.root.appendingPathComponent(PipelineLayout.lineageFile))
        let canonical = f.root.appendingPathComponent(PipelineLayout.productionDesignFile)
        if missing { try FileManager.default.removeItem(at: canonical) }
        else { var bytes = try Data(contentsOf: canonical); bytes.append(0x0a); try bytes.write(to: canonical, options: .atomic) }
        #expect(throws: (any Error).self) {
            try ProjectWorkingCopy.transact(key: f.key) { staging in
                try IdentityRecoveryRebind.apply(preview, dataRoot: #require(DataRootResolver.dataRoot(of: staging)), order: Self.order, registry: f.registry)
            }
        }
        #expect(try Data(contentsOf: f.root.appendingPathComponent(PipelineLayout.lineageFile)) == lineage)
        #expect(try fileBytes(in: f.saved) == f.original)
    }

    @Test("failed migration or rebind transaction preserves the prior Recovery bytes", arguments: [false, true])
    func failedTransactionPreservesLineage(migration: Bool) throws {
        let f = try fixture()
        defer { cleanup(f) }
        if migration { _ = try ProjectWorkingCopy.materialize(key: f.key, packageURL: f.saved) }
        let preview = try IdentityRecoveryRebind.preview(dataRoot: f.root, order: Self.order, registry: f.registry)
        let before = try fileBytes(in: f.root)
        #expect(throws: (any Error).self) {
            try ProjectWorkingCopy.transact(key: f.key) { staging in
                if migration {
                    try MusicvideoIdentityRecovery.prepare(projectURL: staging, registry: f.registry)
                } else {
                    try IdentityRecoveryRebind.apply(#require(preview), dataRoot: #require(DataRootResolver.dataRoot(of: staging)), order: Self.order, registry: f.registry)
                }
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(try fileBytes(in: f.root) == before)
        #expect(try fileBytes(in: f.saved) == f.original)
    }

    @Test("rebind restores exact lineage when the shared structural check rejects publication")
    func structuralRebindFailureRestoresLineage() throws {
        let f = try fixture()
        defer { cleanup(f) }
        let preview = try #require(IdentityRecoveryRebind.preview(dataRoot: f.root, order: Self.order, registry: f.registry))
        let lineage = try Data(contentsOf: f.root.appendingPathComponent(PipelineLayout.lineageFile))
        f.registry.registerGateRequirement("production_design") { root in
            try Self.requireStructure(phase: "production_design", root: root)
            throw GateBlocked("An independent review requirement changed.")
        }
        #expect(throws: (any Error).self) {
            try IdentityRecoveryRebind.apply(preview, dataRoot: f.root, order: Self.order, registry: f.registry)
        }
        #expect(try Data(contentsOf: f.root.appendingPathComponent(PipelineLayout.lineageFile)) == lineage)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(IdentityRecoveryReceiptStoreV1.rebindPath).path))
        #expect(try fileBytes(in: f.saved) == f.original)
    }

    @Test("a migration-produced provenance-only receipt needs no review after rewind")
    func noBindingsDoNotRequireReview() throws {
        let f = try fixture(approved: false)
        defer { cleanup(f) }
        #expect(try IdentityRecoveryReceiptStoreV1.load(dataRoot: f.root).phases.isEmpty)
        try YAMLArtifactStore(dataRoot: f.root).save(Gates(project: "rebind"), to: PipelineLayout.gatesFile)
        #expect(try IdentityRecoveryRebind.preview(dataRoot: f.root, order: Self.order, registry: f.registry) == nil)
        #expect(try fileBytes(in: f.saved) == f.original)
    }
}
