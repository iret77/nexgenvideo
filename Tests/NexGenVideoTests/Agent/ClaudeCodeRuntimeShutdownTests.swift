import Foundation
import Testing
@testable import NexGenVideo

@MainActor
@Suite("Claude runtime awaited shutdown")
struct ClaudeCodeRuntimeShutdownTests {
    @Test func endAfterCancellationStillJoinsTheOwnedDriver() async throws {
        let driver = Driver()
        let adapter = ClaudeCodeRuntimeAdapter { _, _ in driver }
        let id = UUID()
        let context = AgentRuntimeHostContext(interfaceLanguage: .init(identifier: "en", displayName: "English"),
            baseInstructions: "Isolated shutdown unit test", pack: nil, phaseInstructions: nil,
            toolSchemas: [], authority: [])
        try adapter.start(.init(sessionID: id, runtimeGenerationID: UUID(), providerSessionID: nil,
            priorMessages: [], hostContext: context, workingDirectory: FileManager.default.temporaryDirectory,
            pluginDirectories: [], providerExtensions: [], mcpPort: 0, executeTool: { _, _, _ in .error("No tool") }))
        let message = AgentRuntimeMessage(role: .user, content: [.text("Controlled shutdown unit test")])
        _ = try adapter.send(.init(sessionID: id, turnID: UUID(), messages: [message], currentMessage: message))
        adapter.cancel(sessionID: id)
        var finished = false
        let ending = Task { @MainActor in
            let stopped = await adapter.endAndWait(sessionID: id)
            finished = true
            return stopped
        }
        for _ in 0..<100 where !driver.waitEntered { await Task.yield() }
        #expect(driver.waitEntered)
        #expect(driver.stops == 1)
        #expect(!finished)
        driver.release()
        #expect(await ending.value)
        #expect(finished)
    }

    @MainActor private final class Driver: ClaudeCodeRuntimeDriving {
        var stops = 0
        var waitEntered = false
        private var waiter: CheckedContinuation<Bool, Never>?
        private var released = false
        func send(text: String, context: String?, imageBlocks: [[String: Any]], hidden: Bool,
                  presentation: AgentUserPresentation?) -> Bool { true }
        func stop() { stops += 1 }
        func waitUntilStopped() async -> Bool {
            waitEntered = true
            if released { return true }
            return await withCheckedContinuation { waiter = $0 }
        }
        func release() { released = true; waiter?.resume(returning: true); waiter = nil }
    }
}
