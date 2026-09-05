import Foundation
import Testing
@testable import NexGenVideo

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

    @Test func backendRecoveryLivesInTheDockInsteadOfTheTranscript() throws {
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
        let dockStart = try #require(source.range(of: "private var composerDock"))
        let dockEnd = try #require(source.range(
            of: "private var footer",
            range: dockStart.upperBound..<source.endIndex
        ))

        let body = source[bodyStart.lowerBound..<bodyEnd.lowerBound]
        let messageList = source[messageStart.lowerBound..<messageEnd.lowerBound]
        let dock = source[dockStart.lowerBound..<dockEnd.lowerBound]

        #expect(body.contains("service.refreshBackendStatus()"))
        #expect(!messageList.contains("backendRecoveryDock"))
        #expect(dock.contains("case .backendRecovery:"))
        #expect(dock.contains("backendRecoveryDock"))
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
            of: #"conversationBar\s+messageList"#,
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
            of: "AgentLiveStatusView("
        ))
        let dock = try #require(implementation.range(
            of: "composerDock",
            range: status.upperBound..<implementation.endIndex
        ))
        #expect(status.lowerBound < dock.lowerBound)

        let dockStart = try #require(source.range(of: "private var composerDock"))
        let dockEnd = try #require(source.range(
            of: "private var footer",
            range: dockStart.upperBound..<source.endIndex
        ))
        let dockImplementation = source[dockStart.lowerBound..<dockEnd.lowerBound]
        #expect(dockImplementation.contains("switch surfaceState.dockOwner"))
        #expect(dockImplementation.contains("case .spendApproval:"))
        #expect(dockImplementation.contains("case .gateApproval:"))
        #expect(dockImplementation.contains("case .dialog:"))
        #expect(dockImplementation.contains("case .backendRecovery:"))
        #expect(dockImplementation.contains("case .composer:\n            footer"))

        let statusSource = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentLiveStatusView.swift"
        )
        #expect(!statusSource.contains(".overlay"))
        #expect(!statusSource.contains("ZStack"))
        #expect(statusSource.contains("if status.canCancel"))
        #expect(statusSource.contains("onCancel()"))
        #expect(implementation.contains("service.cancelRunningSpend()"))
    }

    @Test func runningTranscriptActivityLeavesAStaticStatusLandmark() throws {
        let panel = try agentPanelSource()
        let state = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentSurfaceState.swift"
        )
        #expect(panel.contains("streamHasTranscriptActivity: activityVisible"))
        #expect(panel.contains("phaseHasTranscriptActivity: activityVisible"))
        #expect(state.contains("case .phaseRun: input.phaseHasTranscriptActivity"))
        #expect(state.contains("case .stream: input.streamHasTranscriptActivity"))
        #expect(panel.contains("surfaceState.statusHasTranscriptActivity"))
        #expect(!panel.contains("detail: \"Current operation appears in the transcript\""))

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

    @Test func completedActivityUsesOneDisclosureWithFlatTechnicalDetail() throws {
        let source = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentMessageView.swift"
        )
        let start = try #require(source.range(of: "struct AgentActivityView"))
        let end = try #require(source.range(
            of: "private struct ToolRunRow",
            range: start.upperBound..<source.endIndex
        ))
        let activity = source[start.lowerBound..<end.lowerBound]

        #expect(activity.contains("activity.operationLabel"))
        #expect(activity.contains("ToolRunDetail("))
        #expect(!activity.contains("ToolRunRow("))
        #expect(activity.contains("accessibilityReduceMotion"))
        #expect(activity.contains("Hide technical details"))
        #expect(activity.contains("Show technical details"))
    }

    @Test func generatedImagesHaveLegiblePreviewsAndAnInspectableViewer() throws {
        let source = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentMessageView.swift"
        )
        let start = try #require(source.range(of: "private struct ToolResultImageView"))
        let implementation = source[start.lowerBound..<source.endIndex]

        #expect(AppTheme.ComponentSize.toolImagePreviewMaxHeight >= 180)
        #expect(implementation.contains("Label(\"Open image\""))
        #expect(implementation.contains(".sheet(isPresented: $showsPreview)"))
        #expect(implementation.contains("ToolResultImagePreview(image: image)"))
        #expect(implementation.contains("MagnifyGesture()"))
        #expect(implementation.contains("Button(\"Fit\")"))
    }

    @Test func composerIsAbsentWhileAHostDecisionIsOpen() throws {
        let panel = try agentPanelSource()
        let input = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentInputBox.swift"
        )
        let dockStart = try #require(panel.range(of: "private var composerDock"))
        let dockEnd = try #require(panel.range(
            of: "private var footer",
            range: dockStart.upperBound..<panel.endIndex
        ))
        let dock = panel[dockStart.lowerBound..<dockEnd.lowerBound]

        #expect(dock.contains("SpendApprovalCard("))
        #expect(dock.contains("GateApprovalCard("))
        #expect(dock.contains("AgentDialogCard("))
        #expect(dock.contains("case .composer:\n            footer"))
        #expect(!input.contains("blockedHint"))
        #expect(!input.contains(".disabled(blocked)"))
        #expect(input.contains("onFocusChange(value)"))
        #expect(panel.contains("service.restoreComposerFocus()"))
        #expect(panel.contains("service.recordComposerFocus($0, for: sessionID)"))
    }

    @Test func conversationHeaderHasOneLabeledNavigator() throws {
        let panel = try agentPanelSource()
        let start = try #require(panel.range(of: "private var conversationBar"))
        let end = try #require(panel.range(
            of: "private var modelPicker",
            range: start.upperBound..<panel.endIndex
        ))
        let header = panel[start.lowerBound..<end.lowerBound]

        #expect(header.contains("historyButton"))
        #expect(header.contains("utilityButton"))
        #expect(header.contains("newConversationButton"))
        #expect(header.contains("Label(\"Latest\""))
        #expect(header.contains("ViewThatFits(in: .horizontal)"))
        #expect(header.contains("currentConversationTitle"))
        #expect(header.contains(".truncationMode(.middle)"))
        #expect(header.contains(".opacity(isUserPinnedAway"))
        #expect(!header.contains("ForEach(service.openSessions)"))
        #expect(!header.contains(".focusable(false)"))
        #expect(!panel.contains("ChatTabView"))

        let history = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/ChatHistoryList.swift"
        )
        let utilities = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/PluginLauncherPopover.swift"
        )
        #expect(history.contains("Search conversations"))
        #expect(history.contains(".confirmationDialog("))
        #expect(history.contains("cue.label"))
        #expect(history.contains("session.title, updated"))
        #expect(!history.contains(".focusable(false)"))
        #expect(utilities.contains("Close conversation"))
        #expect(utilities.contains("Search workflows"))
        #expect(!utilities.contains(".focusable(false)"))
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

    @Test func everyDecisionCardHasOneBoundedInternalScrollRegion() throws {
        for path in [
            "Sources/NexGenVideo/Agent/Panel/AgentDialogCard.swift",
            "Sources/NexGenVideo/Agent/Panel/GateApprovalCard.swift",
            "Sources/NexGenVideo/Agent/Panel/SpendApprovalCard.swift",
        ] {
            let source = try sourceFile(path)
            #expect(source.contains("ScrollView {"))
            #expect(source.contains("AppTheme.ComponentSize.agentDecisionMaxHeight"))
            #expect(source.contains(".accessibilityElement(children: .contain)"))
            #expect(source.contains(".accessibilityLabel("))
        }

        let dialog = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/AgentDialogCard.swift"
        )
        #expect(dialog.components(separatedBy: "ScrollView {").count == 2)
        #expect(dialog.contains("requestInitialFocus()"))
        #expect(dialog.contains(".focused($focusedControl"))
    }

    @Test func gateApprovalUsesBodyTypographyForDecisionContent() throws {
        let source = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/GateApprovalCard.swift"
        )
        let start = try #require(source.range(of: "private var summary"))
        let end = try #require(source.range(
            of: "private var footerRow",
            range: start.upperBound..<source.endIndex
        ))
        let summary = source[start.lowerBound..<end.lowerBound]

        #expect(summary.contains(".interfaceFont(size: AppTheme.Typography.ui)"))
        #expect(!summary.contains("AppTheme.FontSize.xxs"))
        #expect(!summary.contains("AppTheme.Text.mutedColor"))
    }

    @Test func spendApprovalKeepsValidProviderAndModelChoicesInTheCard() throws {
        let card = try sourceFile(
            "Sources/NexGenVideo/Agent/Panel/SpendApprovalCard.swift"
        )
        let executor = try sourceFile(
            "Sources/NexGenVideo/Agent/Tools/ToolExecutor+Generate.swift"
        )
        let service = try sourceFile(
            "Sources/NexGenVideo/Agent/AgentService.swift"
        )

        #expect(card.contains("private var availableOptions: [SpendOption]"))
        #expect(card.contains("approval.options"))
        #expect(!card.contains("$0.isCurrentlyAvailable"))
        #expect(card.contains("let scope = selectedProvider.map { [$0] }"))
        #expect(card.contains("Picker(\"Provider\""))
        #expect(card.contains("Picker(\"Model\""))
        #expect(!card.contains("CHEAPER OPTIONS"))
        #expect(service.contains("guard option.isCurrentlyAvailable else"))
        #expect(service.contains("SpendSelectionPreferences.record(option, for: approval)"))
        #expect(executor.contains("availableImageSpendOptions"))
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
