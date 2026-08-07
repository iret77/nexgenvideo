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

        for forbidden in [
            "ZStack",
            ".overlay",
            ".background(",
            ".glassEffect",
            ".scrollEdgeEffectStyle",
        ] {
            #expect(!implementation.contains(forbidden))
        }
        #expect(implementation.range(
            of: #"floatingTabBar\s+messageList"#,
            options: .regularExpression
        ) != nil)
    }

    @Test func sidebarKeepsTranscriptContainerFreeOfSecondaryLayers() throws {
        let source = try sourceFile("Sources/NexGenVideo/Editor/LeftSidebarView.swift")
        let start = try #require(source.range(of: "Group {"))
        let end = try #require(source.range(
            of: "private var tabStrip",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        for forbidden in [
            "ZStack",
            ".overlay",
            ".background(",
            ".clipShape",
            ".clipped",
            ".glassEffect",
            ".scrollEdgeEffectStyle",
            "alignment:",
        ] {
            #expect(!implementation.contains(forbidden))
        }
    }

    @Test func panelShellIsOutsideTheSwiftUILayoutTree() throws {
        let source = try sourceFile("Sources/NexGenVideo/Editor/EditorView.swift")
        let start = try #require(source.range(of: "private func makeHosting"))
        let end = try #require(source.range(
            of: "override func viewDidLayout()",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        #expect(implementation.contains("PanelHostingController"))
        #expect(!implementation.contains(".overlay"))
        #expect(!implementation.contains(".background("))
        #expect(!implementation.contains(".clipShape"))
        #expect(!source.contains("private struct PanelFocusRing: View"))
        #expect(source.contains("container.layer?.addSublayer(focusRing)"))
    }

    @Test func workflowReferenceCopiesRunOutsideTheMainActor() throws {
        let source = try sourceFile("Sources/NexGenVideo/Agent/AgentService.swift")
        let identityStart = try #require(source.range(of: "private func attachIdentityAssets"))
        let identityEnd = try #require(source.range(
            of: "nonisolated static func identitySlug",
            range: identityStart.upperBound..<source.endIndex
        ))
        let styleStart = try #require(source.range(of: "private func attachStyleRefs"))
        let styleEnd = try #require(source.range(
            of: "private func intakeRoleConflict",
            range: styleStart.upperBound..<source.endIndex
        ))

        #expect(source[identityStart.lowerBound..<identityEnd.lowerBound].contains(
            "Task.detached(priority: .userInitiated)"
        ))
        #expect(source[styleStart.lowerBound..<styleEnd.lowerBound].contains(
            "Task.detached(priority: .userInitiated)"
        ))
    }

    private func agentPanelSource() throws -> String {
        try sourceFile("Sources/NexGenVideo/Agent/Panel/AgentPanelView.swift")
    }

    private func sourceFile(_ path: String) throws -> String {
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
            contentsOf: root.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
