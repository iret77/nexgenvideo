import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

@Suite("Cumulative production style lineage")
struct ProductionStyleLineageTests {
    @Test("style changes and explicit removal remain downstream inputs")
    func styleDependency() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = try ProjectScaffold.initProject(home: home, name: "lineage")
        defer { try? FileManager.default.removeItem(at: home) }
        let phases = ["treatment", "storyboard", "bible"]
        func fingerprints() throws -> [String] {
            try phases.map { try MusicvideoPipelineLineage.snapshot(phase: $0, dataRoot: root).inputFingerprint }
        }
        let legacy = try fingerprints()
        let style = root.appendingPathComponent(ResolvedProductionStyleV1.relativePath)
        try FileManager.default.createDirectory(at: style.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(try fingerprints() == legacy)
        try Data("style one".utf8).write(to: style)
        let first = try fingerprints()
        try Data("style two".utf8).write(to: style)
        let second = try fingerprints()
        #expect(zip(first, second).allSatisfy { $0 != $1 })
        try FileManager.default.removeItem(at: style)
        try PipelineLineageStore.record(phase: ProductionStyleStoreV1.lineageID,
            snapshot: .init(inputFingerprint: "fixture", artifactFingerprint: "none"), dataRoot: root)
        let cleared = try fingerprints()
        #expect(zip(cleared, legacy).allSatisfy { $0 != $1 })
    }
}
