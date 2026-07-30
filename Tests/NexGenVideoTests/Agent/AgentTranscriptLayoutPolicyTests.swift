import Foundation
import Testing

@Suite("Agent transcript layout policy")
struct AgentTranscriptLayoutPolicyTests {
    @Test func observedScrollViewHasNoSecondaryLayerOverlay() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/",
              !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Package.swift").path
              ) {
            root.deleteLastPathComponent()
        }
        try #require(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Package.swift").path
        ))
        let source = try String(
            contentsOf: root
                .appendingPathComponent(
                    "Sources/NexGenVideo/Agent/Panel/AgentPanelView.swift"
                ),
            encoding: .utf8
        )
        let start = try #require(source.range(
            of: "private func scrollingMessages"
        ))
        let end = try #require(source.range(
            of: "private func scrollToBottomButton",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        #expect(!implementation.contains(".overlay"))
        #expect(!implementation.contains(".onScrollGeometryChange"))
        #expect(!implementation.contains("withAnimation"))
        #expect(!implementation.contains(".animation("))
        #expect(!implementation.contains("if isUserPinnedAway"))
    }
}
