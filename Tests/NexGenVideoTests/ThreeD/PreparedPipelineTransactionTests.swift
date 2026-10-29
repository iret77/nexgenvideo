import Foundation
import Testing
@testable import NexGenVideo

@Suite("Prepared pipeline publication")
struct PreparedPipelineTransactionTests {
    @Test func stalePublicationLeavesConcurrentSourceUntouched() throws {
        try withPipeline { root in
            let file = root.appendingPathComponent("value.txt")
            try Data("original".utf8).write(to: file)
            let prepared = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { staging in
                try Data("candidate".utf8).write(to: staging.appendingPathComponent("value.txt"))
                return "candidate"
            }
            defer { prepared.discard() }
            try Data("concurrent".utf8).write(to: file)
            #expect(throws: SpatialSceneError.self) {
                _ = try prepared.commit { _ in
                    guard try Data(contentsOf: file) == Data("original".utf8) else { throw SpatialSceneError.changed }
                }
            }
            #expect(try Data(contentsOf: file) == Data("concurrent".utf8))
        }
    }

    @Test func successfulPublicationAtomicallyReplacesThePipeline() throws {
        try withPipeline { root in
            try Data("old".utf8).write(to: root.appendingPathComponent("value.txt"))
            let prepared = try ProjectWorkingCopy.preparePipelineTransaction(at: root) { staging in
                try Data("new".utf8).write(to: staging.appendingPathComponent("value.txt"))
                return 17
            }
            defer { prepared.discard() }
            #expect(try prepared.commit { _ in } == 17)
            #expect(try Data(contentsOf: root.appendingPathComponent("value.txt")) == Data("new".utf8))
        }
    }

    private func withPipeline(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = home.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(root)
    }
}
