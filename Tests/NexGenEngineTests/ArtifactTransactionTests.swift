import Foundation
import Testing
@testable import NexGenEngine

@Suite("Artifact publication rollback")
struct ArtifactTransactionTests {
    @Test("a failed publication restores existing bytes and removes new evidence")
    func restoresAllArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("audit.yaml")
        let created = root.appendingPathComponent("receipt.json")
        let original = Data("original audit".utf8)
        try original.write(to: existing)
        #expect(throws: (any Error).self) {
            try ArtifactTransaction.perform(paths: [existing, created], dataRoot: root) {
                try Data("replacement audit".utf8).write(to: existing)
                try Data("new receipt".utf8).write(to: created)
                throw GateBlocked("simulated lineage publication failure")
            }
        }
        #expect(try Data(contentsOf: existing) == original)
        #expect(!FileManager.default.fileExists(atPath: created.path))
    }
    @Test("rollback failure preserves the original publication failure")
    func reportsBothFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let parent = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = parent.appendingPathComponent("audit.yaml")
        try Data("original".utf8).write(to: file)
        do {
            try ArtifactTransaction.perform(paths: [file], dataRoot: root) {
                try FileManager.default.removeItem(at: parent)
                try Data("parent is now a file".utf8).write(to: parent)
                throw GateBlocked("Original publication failure")
            }
            Issue.record("Expected publication failure")
        } catch {
            #expect(error.localizedDescription.contains("Original publication failure"))
            #expect(error.localizedDescription.contains("Rollback failed"))
            #expect(error.localizedDescription.contains("audit.yaml"))
        }
    }

}
