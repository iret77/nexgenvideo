import Foundation
import Testing
@testable import NexGenVideo

@Suite("Pipeline source fence preserves package ownership")
struct PipelineSpatialSourceFenceTests {
    @Test("Independent package checkpoints preserve an unchanged pipeline fence")
    func independentCheckpoint() throws {
        try withProject { home, root in
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root)
            for name in [".dirty", "timeline.json", "editor-state.json"] {
                try Data("updated checkpoint".utf8).write(to: home.appendingPathComponent(name), options: .atomic)
            }
            try fence.requireUnchanged()
            try fence.requireCanonicalRootsUnchanged()
        }
    }

    @Test("Replacing package ownership is rejected even with the original pipeline directory")
    func replacedHome() throws {
        try withProject { home, root in
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root)
            let previous = home.deletingLastPathComponent().appendingPathComponent("previous")
            try FileManager.default.moveItem(at: home, to: previous)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: previous.appendingPathComponent("pipeline"), to: root)
            #expect(throws: SpatialSceneError.self) { try fence.requireUnchanged() }
            #expect(throws: SpatialSceneError.self) { try fence.requireCanonicalRootsUnchanged() }
        }
    }

    @Test("Removing the materialization sentinel invalidates the prepared pipeline fence")
    func removedMaterializationSentinel() throws {
        try withProject { home, root in
            let marker = home.appendingPathComponent(".ngv-materialized")
            try Data().write(to: marker)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root)
            try FileManager.default.removeItem(at: marker)
            #expect(throws: SpatialSceneError.self) { try fence.requireUnchanged() }
            #expect(throws: SpatialSceneError.self) { try fence.requireCanonicalRootsUnchanged() }
        }
    }

    @Test("Same-size pipeline byte edits are rejected with their modification date restored")
    func changedSourceBytes() throws {
        try withProject { _, root in
            let source = root.appendingPathComponent("source.json")
            try Data("first".utf8).write(to: source)
            let originalDate = try #require(FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root,
                additionalCanonicalPaths: ["source.json"])
            let handle = try FileHandle(forWritingTo: source)
            try handle.write(contentsOf: Data("other".utf8))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: source.path)
            #expect(throws: SpatialSceneError.self) { try fence.requireUnchanged() }
            #expect(throws: SpatialSceneError.self) { try fence.requireCanonicalRootsUnchanged() }
        }
    }

    @Test("Pipeline replacement and a symlink to the original directory are rejected")
    func replacedPipeline() throws {
        try withProject { home, root in
            let fence = try PipelineSpatialSceneAuthority.SourceFence.capture(dataRoot: root)
            let original = home.appendingPathComponent("original-pipeline")
            try FileManager.default.moveItem(at: root, to: original)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            #expect(throws: SpatialSceneError.self) { try fence.requireUnchanged() }
            #expect(throws: SpatialSceneError.self) { try fence.requireCanonicalRootsUnchanged() }
            let replacement = home.appendingPathComponent("replacement-pipeline")
            try FileManager.default.moveItem(at: root, to: replacement)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: original)
            #expect(throws: SpatialSceneError.self) { try fence.requireUnchanged() }
            #expect(throws: SpatialSceneError.self) { try fence.requireCanonicalRootsUnchanged() }
        }
    }

    private func withProject(_ operation: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("Project.ngv")
        let root = home.appendingPathComponent("pipeline")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try operation(home, root)
    }
}
