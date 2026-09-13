import Foundation
import Testing
@testable import NexGenVideo
@testable import NexGenEngine
@testable import MusicvideoPlugin

@MainActor
@Suite("Reviewed identity recovery")
struct IdentityRecoveryRebindTests {
    private func fixture() throws -> (URL, EngineRegistry) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = try ProjectScaffold.initProject(home: home, name: "rebind", mode: .beat)
        try JSONSerialization.data(withJSONObject: [
            "id": "11111111-1111-1111-1111-111111111111", "activePlugin": "musicvideo",
            "activePluginVersion": "0.5.8", "activePluginProjectSchema": "musicvideo/2.0.0",
        ]).write(to: home.appendingPathComponent("ngv.json"))
        var gates = Gates(project: "rebind")
        for phase in ["project_init", "analysis", "brief"] { GatesOperations.approve(&gates, phase: phase) }
        try YAMLArtifactStore(dataRoot: root).save(gates, to: PipelineLayout.gatesFile)
        _ = try ProjectLocalFile.ensureDirectory("import/characters/mouse", dataRoot: root)
        try Data("exact image".utf8).write(to: root.appendingPathComponent("import/characters/mouse/front.png"))
        try ConfirmedIdentityAssetStoreV1.recordIntake(role: .character, identityName: "Mouse", identitySlug: "mouse", paths: ["import/characters/mouse/front.png"], dataRoot: root, confirmedAt: "2026-09-01T00:00:00Z")
        try Data("exact canonical artifact".utf8).write(to: root.appendingPathComponent("brief.yaml"))
        let registry = EngineRegistry()
        for phase in ["analysis", "brief"] {
            try PipelineLineageStore.record(phase: phase, snapshot: MusicvideoPipelineLineage.snapshot(phase: phase, dataRoot: root, legacyIdentityLayout: true), dataRoot: root)
            registry.registerPhaseLineageProvider(phase) { try MusicvideoPipelineLineage.snapshot(phase: phase, dataRoot: $0) }
            registry.registerGateRequirement(phase) { root in
                try PipelineLineageStore.requireCurrent(phase: phase, snapshot: MusicvideoPipelineLineage.snapshot(phase: phase, dataRoot: root), dataRoot: root)
            }
        }
        _ = try ProjectLocalFile.ensureDirectory("bible/refs", dataRoot: root)
        try FileManager.default.copyItem(at: root.appendingPathComponent("import/characters/mouse/front.png"), to: root.appendingPathComponent("bible/refs/front.png"))
        _ = try ConfirmedIdentityAssetStoreV1.adopt(from: "import/characters/mouse/front.png", to: "bible/refs/front.png", dataRoot: root)
        let historical = try #require(PipelineLineageStore.loadIfPresent(dataRoot: root))
        try MusicvideoIdentityRecovery.prepare(projectURL: home)
        let evidence = try IdentityRecoveryReceiptStoreV1.load(dataRoot: root)
        var phases: [String: IdentityRecoveryPhaseBindingV1] = [:]
        for phase in ["analysis", "brief"] {
            let original = try #require(historical.phases[phase])
            phases[phase] = IdentityRecoveryPhaseBindingV1(original: original, recovered: PhaseLineageEntry(snapshot: try MusicvideoPipelineLineage.snapshot(phase: phase, dataRoot: root), recordedAt: original.recordedAt))
        }
        try JSONArtifactStore(dataRoot: root).save(IdentityRecoveryReceiptV1(
            projectID: evidence.projectID, originalManifestSHA256: evidence.originalManifestSHA256,
            recoveredManifestSHA256: evidence.recoveredManifestSHA256,
            originalLineageSHA256: evidence.originalLineageSHA256, gatesSHA256: evidence.gatesSHA256,
            aliases: evidence.aliases, phases: phases, stalePhases: []
        ), to: IdentityRecoveryReceiptStoreV1.relativePath)
        return (root, registry)
    }

    @Test("one reviewed rebind restores only proven current approvals")
    func reviewedRebind() throws {
        let (root, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let order = ["project_init", "analysis", "brief"]
        let preview = try #require(IdentityRecoveryRebind.preview(dataRoot: root, order: order, registry: registry))
        let canonical = try Data(contentsOf: root.appendingPathComponent("brief.yaml"))
        try IdentityRecoveryRebind.apply(preview, dataRoot: root, order: order, registry: registry)
        #expect(try ProjectStateBuilder.approvalValidity(dataRoot: root, order: order, registry: registry)["brief"]?.isCurrent == true)
        #expect(try Data(contentsOf: root.appendingPathComponent("brief.yaml")) == canonical)
        #expect(try IdentityRecoveryRebind.preview(dataRoot: root, order: order, registry: registry) == nil)
    }

    @Test("a provenance-only receipt does not leave a disabled recovery card after rewind")
    func noBindingsDoNotRequireReview() throws {
        let (root, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let prior = try IdentityRecoveryReceiptStoreV1.load(dataRoot: root)
        try JSONArtifactStore(dataRoot: root).save(IdentityRecoveryReceiptV1(
            projectID: prior.projectID, originalManifestSHA256: prior.originalManifestSHA256,
            recoveredManifestSHA256: prior.recoveredManifestSHA256,
            originalLineageSHA256: prior.originalLineageSHA256, gatesSHA256: prior.gatesSHA256,
            aliases: prior.aliases, phases: [:], stalePhases: ["brief"]
        ), to: IdentityRecoveryReceiptStoreV1.relativePath)
        try YAMLArtifactStore(dataRoot: root).save(Gates(project: "rebind"), to: PipelineLayout.gatesFile)
        #expect(try IdentityRecoveryRebind.preview(dataRoot: root, order: ["project_init", "analysis", "brief"], registry: registry) == nil)
    }

    @Test("a source change after preview rejects rebind without changing lineage")
    func rejectsChangedPreview() throws {
        let (root, registry) = try fixture()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let order = ["project_init", "analysis", "brief"]
        let preview = try #require(IdentityRecoveryRebind.preview(dataRoot: root, order: order, registry: registry))
        let lineage = try Data(contentsOf: root.appendingPathComponent(PipelineLayout.lineageFile))
        try Data("changed".utf8).write(to: root.appendingPathComponent("import/characters/mouse/front.png"), options: .atomic)
        #expect(throws: (any Error).self) { try IdentityRecoveryRebind.apply(preview, dataRoot: root, order: order, registry: registry) }
        #expect(try Data(contentsOf: root.appendingPathComponent(PipelineLayout.lineageFile)) == lineage)
    }
}
