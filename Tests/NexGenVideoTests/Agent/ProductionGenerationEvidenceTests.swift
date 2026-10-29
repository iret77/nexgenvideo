import Foundation
import Testing
import NexGenEngine
@testable import NexGenVideo

@Suite("Pipeline generation evidence namespaces")
struct ProductionGenerationEvidenceTests {
    @Test("Existing home references remain valid, but a declared pipeline mirror cannot fall back home")
    func explicitNamespace() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("pipeline"), bytes = Data("original receipt bytes".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = CanonicalArtifactReferenceV1(id: "receipt", role: "host.generation-output-receipt",
            path: "generation-output-receipts/example.json", sha256: FileDigest.sha256(of: bytes))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(original.path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: home.appendingPathComponent(original.path))
        #expect(try ProjectLocalFile.requireHash(original.sha256, at: original.path, dataRoot: root) == home.appendingPathComponent(original.path))
        #expect(try PipelineGenerationEvidenceSnapshot.requireReferences(originals: [original], inputs: [original],
            home: home, dataRoot: root, area: .frames) == [original])
        let mirror = PipelineGenerationEvidenceSnapshot.reference(mirroring: original, area: .frames)
        let wrongNamespace = home.appendingPathComponent(mirror.path)
        try FileManager.default.createDirectory(at: wrongNamespace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: wrongNamespace)
        #expect(try ProjectLocalFile.requireHash(mirror.sha256, at: mirror.path, dataRoot: root) == wrongNamespace)
        #expect(throws: (any Error).self) {
            try PipelineGenerationEvidenceSnapshot.requireReferences(originals: [original], inputs: [mirror], home: home, dataRoot: root, area: .frames)
        }
    }

    @Test("Home evidence and pipeline mirrors must both retain their exact bytes")
    func separateRoots() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("pipeline")
        let bytes = Data("actual original artifact".utf8)
        let original = CanonicalArtifactReferenceV1(id: "output", role: "host.generated-output",
            path: "media/image.png", sha256: FileDigest.sha256(of: bytes))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("media"), withIntermediateDirectories: true)
        try bytes.write(to: home.appendingPathComponent(original.path))
        for area in [PipelineGenerationEvidenceSnapshot.Area.frames, .storyboard] {
            let mirror = PipelineGenerationEvidenceSnapshot.reference(mirroring: original, area: area)
            try FileManager.default.createDirectory(at: root.appendingPathComponent(mirror.path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent(mirror.path))
            try PipelineGenerationEvidenceSnapshot.require(mirror, original: original, home: home, dataRoot: root, area: area)
            #expect(throws: (any Error).self) {
                try PipelineGenerationEvidenceSnapshot.require(original, original: original, home: home, dataRoot: root, area: area)
            }
            try Data("changed mirror".utf8).write(to: root.appendingPathComponent(mirror.path))
            #expect(throws: (any Error).self) {
                try PipelineGenerationEvidenceSnapshot.require(mirror, original: original, home: home, dataRoot: root, area: area)
            }
            try bytes.write(to: root.appendingPathComponent(mirror.path))
            try Data("changed source".utf8).write(to: home.appendingPathComponent(original.path))
            #expect(throws: (any Error).self) {
                try PipelineGenerationEvidenceSnapshot.require(mirror, original: original, home: home, dataRoot: root, area: area)
            }
            try bytes.write(to: home.appendingPathComponent(original.path))
        }
    }

    @Test("A matching image outside the pipeline cannot replace its evidence mirror")
    func escapingMirror() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("pipeline"), bytes = Data("identical bytes".utf8)
        let original = CanonicalArtifactReferenceV1(id: "output", role: "host.generated-output",
            path: "image.png", sha256: FileDigest.sha256(of: bytes))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: home.appendingPathComponent(original.path))
        let mirror = PipelineGenerationEvidenceSnapshot.reference(mirroring: original, area: .frames)
        let destination = root.appendingPathComponent(mirror.path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: home.appendingPathComponent(original.path))
        #expect(throws: (any Error).self) {
            try PipelineGenerationEvidenceSnapshot.require(mirror, original: original, home: home, dataRoot: root, area: .frames)
        }
    }
}
