import Foundation
import Testing
@testable import NexGenVideo

@Suite("Native take selection source fence")
struct NativeTakeSelectionSourceFenceTests {
    @Test("Replacing or rewriting a selected source invalidates its captured fence")
    func changedSource() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("receipt.json")
        try Data("first".utf8).write(to: source)
        let fence = try PipelineNativeTakeSourceFence.capture([source])
        try fence.requireUnchanged()
        try Data("other".utf8).write(to: source, options: .atomic)
        #expect(throws: (any Error).self) { try fence.requireUnchanged() }
        let current = try PipelineNativeTakeSourceFence.capture([source])
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data("third".utf8))
        try handle.close()
        #expect(throws: (any Error).self) { try current.requireUnchanged() }
    }
}
