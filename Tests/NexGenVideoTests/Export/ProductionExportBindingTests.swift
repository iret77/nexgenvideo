import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
struct ProductionExportBindingTests {
    @Test func resolverSnapshotsPreserveTheTrustedSessionAcrossProjectChanges() throws {
        var declaration = ProjectPackGate.MutationDeclaration(packName: nil, binding: nil, productionContract: .current)
        let resolver = MediaResolver(manifest: { .init() }, projectURL: { nil }, productionDeclaration: { declaration })
        let snapshot = resolver.snapshot()
        let frozen = resolver.snapshot(overriding: ["clip": URL(fileURLWithPath: "/frozen/clip.mov")])
        declaration = .init(packName: nil, binding: nil)
        #expect(resolver.trustedProductionDeclaration?.productionContract == nil)
        #expect(snapshot.trustedProductionDeclaration?.productionContract == .current)
        #expect(frozen.trustedProductionDeclaration?.productionContract == .current)
        #expect(frozen.expectedURL(for: "clip")?.path == "/frozen/clip.mov")
    }

    @Test func removedCoreBindingCannotSilentlyBecomeAnUnrestrictedExport() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try ProjectScaffold.initProject(home: home, name: "Export binding", mode: .generic)
        let generic = MediaResolver(manifest: { .init() }, projectURL: { home })
        #expect(try await ProductionExportBinding.capture(timeline: .init(), resolver: generic) == nil)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let trusted = ProjectPackGate.MutationDeclaration(packName: nil, binding: nil, productionContract: .current)
        let production = MediaResolver(manifest: { .init() }, projectURL: { home }, productionDeclaration: { trusted }).snapshot()
        try ProjectPluginSettings.setProductionContract(nil, projectURL: home)
        await #expect(throws: (any Error).self) {
            try await ProductionExportBinding.capture(timeline: .init(), resolver: production)
        }
    }

    @Test func unreadableProductionMarkerCannotBypassExportValidation() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = try ProjectScaffold.initProject(home: home, name: "Export marker", mode: .generic)
        try ProjectPluginSettings.setProductionContract(.current, projectURL: home)
        let trusted = ProjectPackGate.MutationDeclaration(packName: nil, binding: nil, productionContract: .current)
        let resolver = MediaResolver(manifest: { .init() }, projectURL: { home }, productionDeclaration: { trusted })
        try Data("incomplete".utf8).write(to: root.appendingPathComponent(PipelineLayout.projectFile))
        await #expect(throws: (any Error).self) {
            try await ProductionExportBinding.capture(timeline: .init(), resolver: resolver)
        }
    }
}
