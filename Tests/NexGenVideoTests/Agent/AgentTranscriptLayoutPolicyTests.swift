import Foundation
import Testing

@Suite("Agent transcript layout policy")
struct AgentTranscriptLayoutPolicyTests {
    @Test func observedScrollViewHasNoSecondaryLayerOrAlignmentContainer() throws {
        let source = try agentPanelSource()
        let start = try #require(source.range(
            of: "private func scrollingMessages"
        ))
        let end = try #require(source.range(
            of: "private var errorBanner",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        #expect(!implementation.contains(".overlay"))
        #expect(!implementation.contains("ZStack"))
        #expect(!implementation.contains(".scrollEdgeEffectStyle"))
        #expect(!implementation.contains(".onScrollGeometryChange"))
        #expect(!implementation.contains("withAnimation"))
        #expect(!implementation.contains(".animation("))
        #expect(!implementation.contains("if isUserPinnedAway"))
    }

    @Test func transcriptHeaderIsInFlowInsteadOfLayeredOverMessages() throws {
        let source = try agentPanelSource()
        let start = try #require(source.range(of: "var body: some View"))
        let end = try #require(source.range(
            of: "private func refreshDiscoveredPlugins",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        #expect(!implementation.contains("ZStack"))
        #expect(implementation.contains("floatingTabBar\n            messageList"))
    }

    private func agentPanelSource() throws -> String {
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
        return try String(
            contentsOf: root
                .appendingPathComponent(
                    "Sources/NexGenVideo/Agent/Panel/AgentPanelView.swift"
            ),
            encoding: .utf8
        )
    }
}
