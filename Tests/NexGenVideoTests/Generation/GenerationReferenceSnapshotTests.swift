import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo

@Suite("Exact generation reference snapshots")
struct GenerationReferenceSnapshotTests {
    @Test func replacingAReferenceCannotChangeTheUploadedSnapshotOrKeepApprovalValid() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.png"), second = root.appendingPathComponent("second.png")
        try Data("first reference".utf8).write(to: first)
        try Data("second reference".utf8).write(to: second)
        let snapshot = try await GenerationReferenceSnapshot.capture(sources: [
            .init(assetID: "first", displayName: "First", type: "image", url: first),
            .init(assetID: "second", displayName: "Second", type: "image", url: second),
        ])
        try await snapshot.requireUnchanged()
        #expect(snapshot.receipts.map(\.assetID) == ["first", "second"])
        #expect(try Data(contentsOf: snapshot.urls[0]) == Data("first reference".utf8))
        try Data("replacement reference".utf8).write(to: first, options: .atomic)
        #expect(try Data(contentsOf: snapshot.urls[0]) == Data("first reference".utf8))
        await #expect(throws: (any Error).self) { try await snapshot.requireUnchanged() }
    }

    @Test func transformationsBindOriginalAndSubmittedBytesSeparately() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original.mp4"), derived = root.appendingPathComponent("trimmed.mp4")
        try Data("full source".utf8).write(to: source)
        try Data("reviewed source range".utf8).write(to: derived)
        let original = try await GenerationReferenceSnapshot.capture(sources: [
            .init(assetID: "video", displayName: "Video", type: "video", url: source),
        ])
        let trimmed = try await GenerationReferenceSnapshot.capture(sources: original.sources,
            submittedURLs: [derived], sourceReceipts: original.receipts)
        #expect(trimmed.receipts[0].sourceSHA256 == original.receipts[0].sourceSHA256)
        #expect(trimmed.receipts[0].submittedSHA256 == (try FileDigest.sha256(of: derived)))
        #expect(trimmed.receipts[0].submittedSHA256 != trimmed.receipts[0].sourceSHA256)
        try await trimmed.requireUnchanged()
        try FileManager.default.removeItem(at: derived)
        try await trimmed.requireUnchanged()
        let link = root.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        await #expect(throws: (any Error).self) {
            try await GenerationReferenceSnapshot.capture(sources: [
                .init(assetID: "link", displayName: "Link", type: "video", url: link),
            ])
        }
    }

    @MainActor
    @Test func changingASelectedAssetIsNotTheSameRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("reference.png")
        try Data("reference".utf8).write(to: source)
        let asset = MediaAsset(id: "reference", url: source, type: .image, name: "Reference")
        let snapshot = try await GenerationReferenceSnapshot.prepare(references: [asset])
        try snapshot.requireIdentity([asset])
        let replacement = MediaAsset(id: "replacement", url: source, type: .image, name: "Replacement")
        #expect(throws: (any Error).self) { try snapshot.requireIdentity([replacement]) }
        await #expect(throws: (any Error).self) {
            try await GenerationReferenceSnapshot.prepare(references: [asset], preUploadedURLs: ["https://example.invalid/unbound.png"])
        }
    }
}
