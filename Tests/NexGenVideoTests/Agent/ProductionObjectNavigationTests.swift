import Foundation
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
        editor.timeline = original
        let asset = try #require(captured.assets.first { $0.id == first.mediaID })
        let bytes = try Data(contentsOf: asset.url)
        defer { try? bytes.write(to: asset.url, options: .atomic) }
        try Data("different source revision".utf8).write(to: asset.url, options: .atomic)
        do {
            _ = try await Task.detached { try ProductionObjectNavigation.read(captured) }.value
            Issue.record("Changed media bytes must not resolve to the old production shot.")
        } catch { }
        try bytes.write(to: asset.url, options: .atomic)
        #expect(try await Task.detached { try ProductionObjectNavigation.read(captured) }.value == initial)
    }
}
