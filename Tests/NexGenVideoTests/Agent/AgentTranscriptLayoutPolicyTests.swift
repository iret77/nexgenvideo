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
        #expect(!implementation.contains(".onChange(of: service.transcriptRevision)"))
        #expect(!implementation.contains(".onChange(of: service.isStreaming)"))
        #expect(implementation.contains(
            ".defaultScrollAnchor(.bottom, for: .initialOffset)"
        ))
        #expect(implementation.contains("for: .sizeChanges"))
        #expect(implementation.contains("AgentTranscriptScrollPolicy.pinState("))
        #expect(implementation.contains("if away != isUserPinnedAway"))
        #expect(!implementation.contains(".onChange(of: service.currentSessionId)"))
        #expect(implementation.contains(".id(service.currentSessionId)"))
        #expect(implementation.contains(".id(AgentTranscriptScrollPolicy.endID)"))
    }

    @Test func sessionPinResetLivesOnTheAlwaysPresentMessageList() throws {
        let source = try agentPanelSource()
        let start = try #require(source.range(of: "private func messageList"))
        let end = try #require(source.range(
            of: "private func scrollingMessages",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        #expect(implementation.contains(".onChange(of: service.currentSessionId)"))
        #expect(implementation.contains("isUserPinnedAway = false"))
    }

    @Test func backendSetupNoticeIsIndependentFromWorkflowIntake() throws {
        let source = try agentPanelSource()
        let bodyStart = try #require(source.range(of: "var body: some View"))
        let bodyEnd = try #require(source.range(
            of: "private func refreshDiscoveredPlugins",
            range: bodyStart.upperBound..<source.endIndex
        ))
        let messageStart = try #require(source.range(of: "private func messageList"))
        let messageEnd = try #require(source.range(
            of: "private func scrollingMessages",
            range: messageStart.upperBound..<source.endIndex
        ))
        let emptyStart = try #require(source.range(of: "private var emptyState"))
        let emptyEnd = try #require(source.range(
            of: "private var entryCommands",
            range: emptyStart.upperBound..<source.endIndex
        ))

        let body = source[bodyStart.lowerBound..<bodyEnd.lowerBound]
        let messageList = source[messageStart.lowerBound..<messageEnd.lowerBound]
        let emptyState = source[emptyStart.lowerBound..<emptyEnd.lowerBound]

        #expect(body.contains("service.refreshBackendStatus()"))
        #expect(messageList.contains("if showsBackendSetupNotice"))
        #expect(messageList.contains("backendSetupNotice"))
        #expect(!emptyState.contains("backendSetupNotice"))
        #expect(source.contains("SettingsWindowController.shared.show(tab: .agent)"))
        #expect(source.contains("Open Agent Settings"))
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

    @Test func liveStatusIsAPersistentInFlowSiblingAboveTheComposer() throws {
        let source = try agentPanelSource()
        let start = try #require(source.range(of: "var body: some View"))
        let end = try #require(source.range(
            of: "private func refreshDiscoveredPlugins",
            range: start.upperBound..<source.endIndex
        ))
        let implementation = source[start.lowerBound..<end.lowerBound]

        let status = try #require(implementation.range(
            of: "AgentLiveStatusView(status: liveStatus)"
        ))
        let footer = try #require(implementation.range(
            of: "footer",
            range: status.upperBound..<implementation.endIndex
        ))
        #expect(status.lowerBound < footer.lowerBound)
        #expect(implementation.contains("if let dialog = service.pendingDialog"))
        #expect(implementation.contains("} else if let gate = service.pendingGateApproval"))
        #expect(implementation.contains("} else if let dialog = service.pendingDialog"))

        let statusSource = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentLiveStatusView.swift"
        )
        #expect(!statusSource.contains(".overlay"))
        #expect(!statusSource.contains("ZStack"))
    }

    @Test func runningTranscriptActivityOwnsTheOnlyOperationSpinnerAndLabel() throws {
        let panel = try agentPanelSource()
        let streamingStart = try #require(panel.range(
            of: "if service.isStreaming"
        ))
        let streamingEnd = try #require(panel.range(
            of: "if service.isCheckingBackend",
            range: streamingStart.upperBound..<panel.endIndex
        ))
        let streaming = panel[streamingStart.lowerBound..<streamingEnd.lowerBound]
        #expect(streaming.contains("runningTranscriptActivity"))
        #expect(streaming.contains("state: .streaming"))
        #expect(!streaming.contains("ToolRunPresentation.label"))

        let statusSource = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentLiveStatusView.swift"
        )
        let stateStart = try #require(statusSource.range(of: "case .streaming:"))
        let stateEnd = try #require(statusSource.range(
            of: "case .waiting:",
            range: stateStart.upperBound..<statusSource.endIndex
        ))
        let streamingIcon = statusSource[stateStart.lowerBound..<stateEnd.lowerBound]
        #expect(streamingIcon.contains("Image(systemName: \"ellipsis\")"))
        #expect(!streamingIcon.contains("ProgressView"))
    }

    @Test func dialogChoiceChipsUseBoundedCompactTitles() throws {
        let source = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentDialogCard.swift"
        )
        let start = try #require(source.range(of: "private struct FlowChips"))
        let implementation = source[start.lowerBound..<source.endIndex]

        #expect(implementation.contains("Text(option.shortLabel)"))
        #expect(!implementation.contains("Text(option.label)"))
        #expect(implementation.contains("agentChoiceChipMaxWidth"))
        #expect(implementation.contains(".help(option.label)"))
        #expect(!implementation.contains(".fixedSize()"))
    }

    @Test func spendApprovalKeepsValidProviderAndModelChoicesInTheCard() throws {
        let card = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/SpendApprovalCard.swift"
        )
        let executor = try sourceFile(
            "Sources/NexGenVideo/Agent/Tools/ToolExecutor+Generate.swift"
        )

        #expect(card.contains("approval.options.filter { $0.isCurrentlyAvailable }"))
        #expect(card.contains("Picker(\"Provider\""))
        #expect(card.contains("Picker(\"Model\""))
        #expect(!card.contains("CHEAPER OPTIONS"))
        #expect(executor.contains("availableImageAlternatives"))
        #expect(executor.contains("target: approved.target"))
        #expect(executor.contains("PromptCompiler.recompile"))
    }

    @Test func sidebarKeepsTranscriptContainerFreeOfSecondaryLayers() throws {
        let source = try sourceFile("Sources/NexGenVideo/Editor/LeftSidebarView.swift")
        let start = try #require(source.range(of: "var body: some View"))
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
