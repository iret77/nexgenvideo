import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Verified production object links")
struct ProductionObjectNavigationTests {
    @Test func linksUseAssemblyIDsAndRefuseChangedBytesWithoutGuessingPaths() async throws {
        let fixture = try await ProductionPlanningAcceptanceFixture.makeImportedAssembly()
        defer { fixture.document.close() }
        let editor = fixture.editor
        let captured = try #require(ProductionObjectNavigation.Context(editor))
        let initial = try await Task.detached { try ProductionObjectNavigation.read(captured) }.value
        #expect(initial.links.count == 2)
        #expect(initial.unavailableClipIDs.isEmpty)
        let first = try #require(initial.links.first)
        #expect(first.input == nil)
        #expect(try await Task.detached { try ProductionObjectNavigation.origin(mediaID: first.mediaID, context: captured) }.value == nil)
        let original = editor.timeline
        for track in editor.timeline.tracks.indices {
            editor.timeline.tracks[track].clips.removeAll { $0.id == first.clipID }
        }
        let removed = try #require(ProductionObjectNavigation.Context(editor))
        let missing = try await Task.detached { try ProductionObjectNavigation.read(removed) }.value
        #expect(missing.unavailableClipIDs == [first.clipID])
        #expect(!missing.links.contains { $0.clipID == first.clipID })
        #expect(missing.hasUnavailableLink(shotID: first.shotID))
        #expect(missing.hasUnavailableLink(mediaID: first.mediaID))
        let other = try #require(initial.links.first { $0.shotID != first.shotID })
        #expect(!missing.hasUnavailableLink(shotID: other.shotID))
        #expect(!missing.hasUnavailableLink(shotID: "unassembled-shot"))
        #expect(!missing.hasUnavailableLink(mediaID: "unassembled-media"))
        editor.timeline = original
        let asset = try #require(captured.assets.first { $0.id == first.mediaID })
        let bytes = try Data(contentsOf: asset.url)
        defer { try? bytes.write(to: asset.url, options: .atomic) }
        try Data("different source revision".utf8).write(to: asset.url, options: .atomic)
        do {
            _ = try await Task.detached { try ProductionObjectNavigation.read(captured) }.value
            Issue.record("Changed media bytes must not resolve to the old production shot.")
        } catch let error as GateBlocked {
            #expect(error.localizedDescription.contains("production source or assembled clip changed"))
        } catch { Issue.record("Changed source failed for an unrelated reason: \(error)") }
        do {
            _ = try await Task.detached { try ProductionObjectNavigation.verifiedOrigin(mediaID: first.mediaID, context: captured) }.value
            Issue.record("Changed media bytes must not reveal their previous production origin.")
        } catch let error as GateBlocked {
            #expect(error.localizedDescription.contains("production source or assembled clip changed"))
        } catch { Issue.record("Changed origin failed for an unrelated reason: \(error)") }
        try bytes.write(to: asset.url, options: .atomic)
        #expect(try await Task.detached { try ProductionObjectNavigation.read(captured) }.value == initial)
    }

    @Test func normalizedCompletedInputUsesTheImmutablePackageIdentity() async throws {
        let editor = EditorViewModel(agentService: AgentService(refreshBackendStatusOnInit: false))
        let (_, package) = try await GenerationPackageFixture.prepare(editor: editor)
        #expect(package.payload.generationInput.generationPackageID == nil)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("generation-packages"), withIntermediateDirectories: true)
        try GenerationPackageV1.canonicalData(package).write(to: home.appendingPathComponent("generation-packages/\(package.id).json"))
        let hash = String(repeating: "a", count: 64)
        let receipt = GenerationOutputReceipt(schema: "generation-output-receipt/v1", projectKey: "fixture",
            assetID: "fixture-output", modality: "image", output: .init(id: "fixture-output", role: "fixture", path: "fixture.png", sha256: hash),
            package: .init(id: package.id, role: "host.generation-package", path: "generation-packages/\(package.id).json",
                sha256: FileDigest.sha256(of: try GenerationPackageV1.canonicalData(package))),
            input: package.payload.generationInput, activity: .init(model: package.payload.target.modelId, costCredits: nil,
                createdAt: Date(timeIntervalSince1970: 123), spendTransactionId: "fixture-transaction"), spendEvents: [])
        let origin = try ProductionObjectNavigation.origin(completed: receipt, outputSHA256: hash, home: home)
        #expect(origin.package == package)
        #expect(origin.input.generationPackageID == package.id)
        #expect(origin.input.spendTransactionId == "fixture-transaction")
        #expect(origin.input.createdAt == Date(timeIntervalSince1970: 123))
        #expect(GenerationPackageV1.normalized(origin.input) == package.payload.generationInput)
        #expect(throws: (any Error).self) {
            try ProductionObjectNavigation.origin(completed: receipt, outputSHA256: String(repeating: "b", count: 64), home: home)
        }
    }
}
