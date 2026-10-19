import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Compiled prompt records are immutable")
struct ProductionCompiledPromptStoreTests {
    @Test func concurrentIdenticalPublishersReuseOneCompleteRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ir = Data("compiler input".utf8)
        let compiled = CompiledPrompt(text: "compiled scene", token: "storage-test", notes: [],
            binding: PromptBinding(projectKey: "project", shotId: "shot", shotFingerprint: "fingerprint",
                promptIRSHA256: FileDigest.sha256(of: ir)), sourceIRData: ir)
        let references = try await withThrowingTaskGroup(of: CanonicalArtifactReferenceV1.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try ProductionCompiledPromptStore.record(compiled, modelID: "model", modality: "image",
                        projectID: "project", dataRoot: root)
                }
            }
            var values: [CanonicalArtifactReferenceV1] = []
            for try await reference in group { values.append(reference) }
            return values
        }
        let reference = try #require(references.first)
        #expect(references.count == 16 && references.allSatisfy { $0 == reference })
        let url = try ProjectLocalFile.requireHash(reference.sha256, at: reference.path, dataRoot: root)
        let bytes = try Data(contentsOf: url)
        let record = try JSONDecoder().decode(ProductionCompiledPromptStore.Record.self, from: bytes)
        #expect(record.sourceIR == ir && record.binding == compiled.binding && record.text == compiled.text)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            == [url.lastPathComponent])
        #expect(throws: GateBlocked.self) {
            try ProductionCompiledPromptStore.record(compiled, modelID: "model", modality: "image",
                projectID: "different-project", dataRoot: root)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
