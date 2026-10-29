import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Production input media bindings")
struct ProductionInputMediaTests {
    @Test("selected range and exact source bytes cannot change under a preparation receipt")
    func rejectsChangedRangeAndSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBytes = Data("original source bytes".utf8)
        let outputBytes = Data("encoded selected range bytes".utf8)
        try sourceBytes.write(to: root.appendingPathComponent("source.mov"))
        try outputBytes.write(to: root.appendingPathComponent("selected.mov"))
        let timebase = RationalTimebaseV1(ticksPerSecond: 600, fpsNumerator: 30)
        let source = CanonicalArtifactReferenceV1(id: "original", role: "source", path: "source.mov", sha256: FileDigest.sha256(of: sourceBytes))
        let selection = PipelineProductionInputMedia.Selection(source: source, timebase: timebase, startTicks: 600, durationTicks: 1200, modality: .video)
        let receipt = PipelineProductionInputMedia.Receipt(schema: "production-input-media/v1", selection: selection,
            output: .init(id: "selected", role: "core.source-video", path: "selected.mov", sha256: FileDigest.sha256(of: outputBytes)),
            durationValue: 1200, durationTimescale: 600, encoder: "avfoundation-highest-quality-mov/v1", recordedAt: "2026-10-18T12:00:00Z")
        try PipelineProductionInputMedia.require(receipt, selection: selection, dataRoot: root)
        let changedRange = PipelineProductionInputMedia.Selection(source: source, timebase: timebase, startTicks: 0, durationTicks: 1200, modality: .video)
        #expect(throws: (any Error).self) { try PipelineProductionInputMedia.require(receipt, selection: changedRange, dataRoot: root) }
        try Data("substituted original bytes".utf8).write(to: root.appendingPathComponent("source.mov"))
        #expect(throws: (any Error).self) { try PipelineProductionInputMedia.require(receipt, selection: selection, dataRoot: root) }
    }

    @Test("whole source duration cannot masquerade as a shorter selected input")
    func rejectsDifferentOutputDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("source".utf8)
        try bytes.write(to: root.appendingPathComponent("source.mov"))
        let source = CanonicalArtifactReferenceV1(id: "source", role: "source", path: "source.mov", sha256: FileDigest.sha256(of: bytes))
        let selection = PipelineProductionInputMedia.Selection(source: source, timebase: .init(ticksPerSecond: 600, fpsNumerator: 30),
            startTicks: 600, durationTicks: 600, modality: .video)
        let receipt = PipelineProductionInputMedia.Receipt(schema: "production-input-media/v1", selection: selection,
            output: .init(id: "selected", role: "core.source-video", path: source.path, sha256: source.sha256), durationValue: 1200, durationTimescale: 600,
            encoder: "avfoundation-highest-quality-mov/v1", recordedAt: "2026-10-18T12:00:00Z")
        #expect(throws: (any Error).self) { try PipelineProductionInputMedia.require(receipt, selection: selection, dataRoot: root) }
    }
}
