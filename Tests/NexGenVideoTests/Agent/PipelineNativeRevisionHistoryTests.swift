import AppKit
import NexGenEngine
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Native Undo during prepared publication")
struct PipelineNativeRevisionHistoryTests {
    @Test func nativeUndoWaitsForPublicationCancellationAndKeepsEveryRedo() async throws {
        let manager = UndoManager()
        var actual = 2
        var failures: [String] = []
        let history = PipelineNativeRevisionHistory<Int>(manager: manager, equivalent: ==,
            restore: { desired, expected in
                guard actual == expected else { throw GateBlocked("Unexpected native head") }
                actual = desired
                return desired
            }, failure: { failures.append($0.localizedDescription) })
        history.record(before: 0, after: 1, name: "First edit")
        history.record(before: 1, after: 2, name: "Second edit")
        try history.beginPublication()
        manager.undo()
        manager.undo()
        #expect(throws: (any Error).self) { try history.requireNoPendingRestore() }
        await Task.yield()
        #expect(actual == 2)
        #expect(failures.isEmpty)
        history.endPublication()
        #expect(try await history.waitForRestore() == 0)
        #expect(actual == 0)
        manager.redo()
        manager.redo()
        #expect(try await history.waitForRestore() == 2)
        #expect(actual == 2)
        #expect(failures.isEmpty)
    }
}
