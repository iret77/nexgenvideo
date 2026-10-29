import Foundation
import Testing
@testable import NexGenVideo

@Suite("Native take selection source fence")
struct NativeTakeSelectionSourceFenceTests {
    @Test("Replacing a completed request while selection is prepared invalidates the commit")
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
    }
}
