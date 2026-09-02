import NexGenEngine
import SwiftUI

struct AgentPanelView: View {
    @Environment(EditorViewModel.self) var editor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let starterPrompts: [AgentStarterPrompt] = [
        AgentStarterPrompt(
            title: "Generate an AI video",
            systemImage: "sparkles",
            prompt: "Generate an AI video of "
        ),
        AgentStarterPrompt(
            title: "Generate B-roll",
            systemImage: "film",
            prompt: "Generate B-roll for my timeline. Inspect the current edit, identify sections that would benefit from cutaways, generate suitable B-roll, and place it where it supports the story."
        ),
        AgentStarterPrompt(
            title: "Create a letterbox opening",
            systemImage: "camera.aperture",
            prompt: "Create a cinematic opening for my timeline. Use the first visual clip, animate a subtle letterbox matte with top and bottom crop keyframes, starting from crop to uncrop, and keep the motion restrained and polished."
        ),
        AgentStarterPrompt(
            title: "Add captions to my timeline",
            systemImage: "captions.bubble",
            prompt: "Add captions to my timeline. Transcribe spoken audio in timeline clips, build readable caption phrases on word boundaries, and place them as text clips aligned to the edit."
        ),
        AgentStarterPrompt(
            title: "Create a voiceover",
            systemImage: "waveform",
            prompt: "Create a voiceover for my timeline. Draft concise narration for the current edit, generate the voiceover, and add it to an audio track aligned with the timeline."
        ),
        AgentStarterPrompt(
            title: "Generate music and sync to my timeline",
            systemImage: "music.note",
            prompt: "Score my timeline with music. Inspect the edit's mood and pacing, generate music for the full timeline, and place it on an audio track aligned to the edit."
        ),
        AgentStarterPrompt(
            title: "Organize my media into structured folders",
            systemImage: "folder",
            prompt: "Organize my media into structured folders. Review all assets, create clearly named folders by role, scene, or type, move assets into them, and rename generic files when useful. Don't delete anything or change the timeline."
        ),
    ]

    private var service: AgentService { editor.agentService }

    private var pendingGateIsBlockedByPhaseRun: Bool {
        _ = editor.pipelinePhaseExecution.snapshot
        guard let root = service.pendingGateApproval?.dataRoot else {
            return false
        }
        return editor.pipelinePhaseRunCoordinator.runningPhase(
            projectRoot: root
        ) != nil
    }

    private var canSend: Bool {
        // A pending dialog card (or spend / gate approval) owns the input — the composer is locked, so
        // neither the Send button, Return-to-send, nor submit() may fire a stale draft past the card.
        !service.isComposerBlocked &&
        !service.isStreaming &&
        service.canStream &&
        (service.pendingFunction != nil ||
         !service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        let turns = transcriptTurns
        VStack(spacing: AppTheme.Spacing.none) {
            conversationBar
            messageList(turns: turns)
            AgentLiveStatusView(
                status: liveStatus,
                onCancel: { service.cancelRunningSpend() }
            )
            composerDock
        }
        .onAppear {
            refreshDiscoveredPlugins()
            service.refreshBackendStatus()
        }
        // A pack activating AFTER the panel appeared (project open, Start production) must swap the
        // generic starters for the pack's own — otherwise the chips stay stale-generic.
        .onChange(of: editor.activePluginName) { _, _ in refreshDiscoveredPlugins() }
        // The project state loads ASYNCHRONOUSLY after the panel appears — and again after every gate
        // approval. Without this the chip is built while progress is still unknown and then never
        // updated, so a reopened project keeps offering "start" for the rest of the session.
        .onChange(of: packProgress) { _, _ in refreshDiscoveredPlugins() }
        .onChange(of: hangContext, initial: true) { _, context in
            MainThreadHangWatchdog.shared.update(context: context)
        }
        .onChange(of: surfaceState.dockOwner) { previous, current in
            if previous != .composer, current == .composer {
                service.restoreComposerFocus()
            }
        }
        .onDisappear {
            MainThreadHangWatchdog.shared.resetContext()
        }
    }

    private func refreshDiscoveredPlugins() {
        // Installed ≠ active: chips and launcher surface only the project's ACTIVE pack. Native pack
        // starters are plain-text prompts, so they work under either backend (no runtime gate).
        // The pack gets the project's real progress so a reopened, half-finished project is offered
        // "continue with <phase>" instead of a chip that restarts it.
        discoveredPlugins = PluginCommandCatalog.discover(progress: packProgress)
            .filter { $0.name == editor.activePluginName }
    }

    private var packProgress: PackProgress {
        guard let state = editor.projectState else { return .untouched }
        return PackProgress(
            nextPhase: state.nextPhaseName,
            approvedPhases: state.phases.filter(\.approved).count,
            totalPhases: state.phases.count
        )
    }

    private var hangContext: MainThreadHangContext {
        let execution = editor.pipelinePhaseExecution.snapshot
        return MainThreadHangContext(
            surface: "agentTranscript",
            phase: execution?.phase ?? editor.projectState?.nextPhaseName,
            stage: execution?.stageID,
            isStreaming: service.isStreaming,
            hasDialog: service.pendingDialog != nil,
            hasGateApproval: service.pendingGateApproval != nil,
            hasSpendApproval: service.pendingSpendApproval != nil
                || service.currentSpendRun != nil
        )
    }

    private var surfaceState: AgentSurfaceState {
        let snapshot = editor.pipelinePhaseExecution.snapshot
        let activityVisible = runningTranscriptActivity != nil
        return AgentSurfaceState.resolve(.init(
            hasSpendApproval: service.pendingSpendApproval != nil,
            hasGateApproval: service.pendingGateApproval != nil,
            hasDialog: service.pendingDialog != nil,
            hasSpendRun: service.currentSpendRun != nil,
            phaseIsRunning: snapshot?.isRunning == true,
            phaseHasTranscriptActivity: activityVisible,
            phaseHasFailed: {
                if case .failed? = snapshot?.status { return true }
                return false
            }(),
            hasHostFollowUp: service.hasPendingHostFollowUp,
            isStreaming: service.isStreaming,
            streamHasTranscriptActivity: activityVisible,
            hasTurnFailure: service.streamError != nil && !showsAuthenticationError,
            isCheckingBackend: service.isCheckingBackend,
            needsBackendRecovery: !service.isCheckingBackend
                && (!service.canStream || showsAuthenticationError)
        ))
    }

    private var liveStatus: AgentLiveStatus {
        switch surfaceState.statusOwner {
        case .spendRun:
            guard let run = service.currentSpendRun else {
                return AgentLiveStatus(state: .working, title: "Generation in progress")
            }
            return AgentLiveStatus(
                state: .working,
                title: run.cancellationRequested
                    ? "Cancelling generation"
                    : "Generation in progress",
                detail: "\(run.actionLabel) · \(run.modelName) via \(run.providerName)",
                canCancel: true,
                cancellationRequested: run.cancellationRequested
            )
        case .phaseRun:
            guard let snapshot = editor.pipelinePhaseExecution.snapshot else {
                return AgentLiveStatus(state: .working, title: "Working")
            }
            if surfaceState.statusHasTranscriptActivity {
                return AgentLiveStatus(state: .streaming, title: "Working")
            }
            let presentation = PipelinePhaseProgressPresentation(
                stageID: snapshot.stageID
            )
            let count = snapshot.totalUnitCount > 0
                ? " · \(snapshot.completedUnitCount) of \(snapshot.totalUnitCount)"
                : ""
            return AgentLiveStatus(
                state: .working,
                title: presentation.title,
                detail: "\(PhaseDisplay.label(snapshot.phase))\(count)"
            )
        case .phaseFailure:
            return AgentLiveStatus(
                state: .failed,
                title: "Stopped"
            )
        case .actionRequired:
            return AgentLiveStatus(state: .waiting, title: "Action required")
        case .hostFollowUp:
            return AgentLiveStatus(
                state: .working,
                title: "Resuming agent"
            )
        case .stream:
            if surfaceState.statusHasTranscriptActivity {
                return AgentLiveStatus(state: .streaming, title: "Working")
            }
            return AgentLiveStatus(
                state: .working,
                title: "Agent is working"
            )
        case .turnFailure:
            return AgentLiveStatus(state: .failed, title: "Stopped")
        case .backendChecking:
            return AgentLiveStatus(state: .working, title: "Checking Agent")
        case .backendUnavailable:
            return AgentLiveStatus(state: .unavailable, title: "Agent unavailable")
        case .ready:
            return AgentLiveStatus(state: .ready, title: "Ready")
        }
    }

    private var runningTranscriptActivity: AgentActivity? {
        transcriptTurns
            .flatMap(\.items)
            .compactMap { item -> AgentActivity? in
                guard case .activity(let activity) = item,
                      activity.isRunning else { return nil }
                return activity
            }
            .last
    }

    private var transcriptOwnsTerminalError: Bool {
        let terminalActivity = transcriptTurns
            .flatMap(\.items)
            .compactMap { item -> AgentActivity? in
                guard case .activity(let activity) = item else { return nil }
                return activity
            }
            .last
        guard let activity = terminalActivity else { return false }
        return activity.steps.contains { toolResults[$0.id]?.isError == true }
    }

    private var conversationBar: some View {
        GlassEffectContainer {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    historyButton
                        .frame(minWidth: AppTheme.ComponentSize.agentConversationTitleMinWidth)
                    Spacer(minLength: AppTheme.Spacing.none)
                    conversationActions(equalWidth: false)
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    historyButton
                        .frame(maxWidth: .infinity, alignment: .leading)
                    conversationActions(equalWidth: true)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity)
            .frame(minHeight: AppTheme.Layout.panelHeaderHeight)
            .glassEffect(.regular, in: Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: AppTheme.BorderWidth.hairline)
            }
        }
    }

    private func conversationActions(equalWidth: Bool) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            latestButton.frame(maxWidth: equalWidth ? .infinity : nil)
            newConversationButton.frame(maxWidth: equalWidth ? .infinity : nil)
            utilityButton.frame(maxWidth: equalWidth ? .infinity : nil)
        }
        .frame(maxWidth: equalWidth ? .infinity : nil)
    }

    private var newConversationButton: some View {
        Button { service.newChat() } label: {
            Label("New", systemImage: "plus")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
        }
        .buttonStyle(.capsule(.secondary, size: .small))
        .controlSize(.small)
        .focusable(false)
        .disabled(service.isComposerBlocked || service.isStreaming)
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityLabel("New conversation")
    }

    private var latestButton: some View {
        Button {
            isUserPinnedAway = false
            programmaticScrollPending = true
            scrollToLatestRequest &+= 1
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
        }
        .buttonStyle(.capsule(.secondary, size: .small))
        .controlSize(.small)
        .focusable(false)
        .opacity(isUserPinnedAway ? AppTheme.Opacity.opaque : AppTheme.Opacity.transparent)
        .allowsHitTesting(isUserPinnedAway)
        .accessibilityHidden(!isUserPinnedAway)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: AppTheme.Anim.quick),
            value: isUserPinnedAway
        )
    }

    @State private var showHistory = false
    @State private var isUserPinnedAway = false
    @State private var programmaticScrollPending = false
    @State private var scrollToLatestRequest: UInt = 0
    @State private var showUtilities = false
    @State private var discoveredPlugins: [PluginCommandCatalog.PluginInfo] = []

    /// The launcher shows when the active pack exposes at least one starter.
    private var pluginLauncherAvailable: Bool {
        discoveredPlugins.contains { !$0.commands.isEmpty }
    }

    private var utilityButton: some View {
        Button {
            refreshDiscoveredPlugins()
            showUtilities.toggle()
        } label: {
            Label("More", systemImage: "ellipsis")
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
        }
        .buttonStyle(.capsule(.secondary, size: .small))
        .controlSize(.small)
        .focusable(false)
        .popover(isPresented: $showUtilities, arrowEdge: .top) {
            PluginLauncherPopover(
                plugins: pluginLauncherAvailable ? discoveredPlugins : [],
                canCloseConversation: !service.isComposerBlocked && !service.isStreaming,
                onRun: runPluginCommand,
                onCloseConversation: closeCurrentConversation
            )
        }
    }

    private func runPluginCommand(_ command: PluginCommandCatalog.PluginCommand) {
        showUtilities = false
        if command.requiresArgument {
            service.prefillInput(command.command + " ")
        } else {
            editor.runActivePackStarter()
        }
    }

    private func closeCurrentConversation() {
        showUtilities = false
        guard let id = service.currentSessionId,
              !service.isComposerBlocked,
              !service.isStreaming else { return }
        service.closeTab(id)
    }

    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "clock.arrow.circlepath")
                Text(currentConversationTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let cue = currentConversationCue {
                    Label(cue.label, systemImage: cue.symbol)
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(cue.color)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(
                        size: AppTheme.FontSize.micro,
                        weight: AppTheme.FontWeight.semibold
                    ))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.capsule(.secondary, size: .small))
        .controlSize(.small)
        .focusable(false)
        .keyboardShortcut("h", modifiers: [.command, .shift])
        .accessibilityLabel("Switch conversation, \(currentConversationTitle)")
        .accessibilityValue(currentConversationCue?.label ?? "Current")
        .popover(isPresented: $showHistory, arrowEdge: .top) {
            ChatHistoryList(
                sessions: service.sessions.sorted { $0.updatedAt > $1.updatedAt },
                currentId: service.currentSessionId,
                cuesBySessionID: conversationCues,
                canSwitch: !service.isComposerBlocked && !service.isStreaming,
                onSelect: { id in
                    service.selectSession(id)
                    showHistory = false
                },
                onDelete: { service.deleteSession($0) }
            )
        }
    }

    private var currentConversationTitle: String {
        guard let id = service.currentSessionId else { return "New conversation" }
        return service.sessions.first(where: { $0.id == id })?.title ?? "New conversation"
    }

    private var currentConversationCue: ChatHistoryCue? {
        guard let id = service.currentSessionId else { return nil }
        return conversationCues[id]
    }

    private var conversationCues: [UUID: ChatHistoryCue] {
        Dictionary(uniqueKeysWithValues: service.sessions.compactMap { session in
            guard let attention = service.sessionAttention(for: session.id) else { return nil }
            return (session.id, Self.historyCue(for: attention))
        })
    }

    private static func historyCue(for attention: ChatSessionAttention) -> ChatHistoryCue {
        switch attention {
        case .actionRequired:
            return ChatHistoryCue(
                symbol: "exclamationmark.circle.fill",
                color: AppTheme.Status.warningColor,
                label: "Needs action"
            )
        case .running:
            return ChatHistoryCue(
                symbol: "circle.fill",
                color: AppTheme.Status.successColor,
                label: "Running"
            )
        case .unreadResult:
            return ChatHistoryCue(
                symbol: "circle.fill",
                color: AppTheme.Accent.primary,
                label: "Unread result"
            )
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        if service.backend == .anthropicAPI && service.hasApiKey {
            Menu {
                ForEach(service.availableModels, id: \.self) { m in
                    Button(m.displayName) { service.model = m }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(service.effectiveModel.displayName)
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var byokIndicator: some View {
        if service.backend == .anthropicAPI && service.hasApiKey {
            Text("using API key")
                .font(.system(size: AppTheme.FontSize.xs).italic())
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .help("Streaming through your Anthropic API key (BYOK)")
        }
    }

    private var toolResults: [String: ToolRunResult] {
        var out: [String: ToolRunResult] = [:]
        for msg in service.messages where msg.role == .user {
            for block in msg.blocks {
                if case let .toolResult(id, content, isError) = block {
                    out[id] = ToolRunResult(content: content, isError: isError)
                }
            }
        }
        return out
    }

    private var transcriptTurns: [AgentTranscriptTurn] {
        AgentTranscriptProjection.turns(
            messages: service.messages,
            isStreaming: service.isStreaming
        )
    }

    private var showsAuthenticationError: Bool {
        if case .authenticationRequired? = service.streamError { return true }
        return false
    }

    private func messageList(turns: [AgentTranscriptTurn]) -> some View {
        Group {
            if turns.isEmpty && !service.isStreaming {
                // Scrollable: in a short pane (Edit-focus sidebar) a fixed empty state would
                // overflow centered — covering the sidebar tabs above and running out below.
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.smMd) {
                        emptyState
                        errorBanner
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppTheme.Spacing.lgXl)
                    .padding(.top, AppTheme.Spacing.md)
                    .padding(.bottom, AppTheme.Spacing.md)
                }
            } else {
                scrollingMessages(turns: turns)
            }
        }
        .onChange(of: service.currentSessionId) { _, _ in
            isUserPinnedAway = false
            programmaticScrollPending = false
        }
    }

    private func scrollingMessages(turns: [AgentTranscriptTurn]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    let results = toolResults
                    ForEach(turns) { turn in
                        AgentTranscriptTurnView(turn: turn, toolResults: results)
                    }
                    if service.isStreaming && runningTranscriptActivity == nil {
                        ThinkingDots().id("streaming-indicator")
                    }
                    errorBanner
                        .padding(.top, AppTheme.Spacing.sm)
                    AppTheme.Background.clearColor
                        .frame(height: AppTheme.Spacing.none)
                        .id(AgentTranscriptScrollPolicy.endID)
                }
                .padding(.horizontal, AppTheme.Spacing.lgXl)
                .padding(.top, AppTheme.Spacing.sm)
                .padding(.bottom, AppTheme.Spacing.smMd)
                .frame(maxWidth: AppTheme.Layout.chatColumnMax)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .id(service.currentSessionId)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(
                isUserPinnedAway ? nil : .bottom,
                for: .sizeChanges
            )
            .onScrollPhaseChange { _, newPhase, context in
                let suppressProgrammaticUpdate = programmaticScrollPending
                if newPhase == .interacting
                        || newPhase == .decelerating
                        || newPhase == .idle {
                    programmaticScrollPending = false
                }
                guard let away = AgentTranscriptScrollPolicy.pinState(
                    for: newPhase,
                    suppressProgrammaticUpdate: suppressProgrammaticUpdate,
                    contentHeight: context.geometry.contentSize.height,
                    contentOffsetY: context.geometry.contentOffset.y,
                    containerHeight: context.geometry.containerSize.height,
                    threshold: AppTheme.ComponentSize.agentScrollAwayThreshold
                ) else { return }
                if away != isUserPinnedAway {
                    isUserPinnedAway = away
                }
            }
            .onChange(of: scrollToLatestRequest) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = currentFailureMessage,
           surfaceState.dockOwner == .composer,
           !transcriptOwnsTerminalError {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(message)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .multilineTextAlignment(.leading)
                if let cta = errorCTA(for: service.streamError) {
                    Button(action: cta.action) {
                        Text(cta.title)
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    }
                    .buttonStyle(.capsule(.secondary))
                    .controlSize(.small)
                }
            }
        }
    }

    private var currentFailureMessage: String? {
        if let error = service.streamError, !showsAuthenticationError {
            return error.localizedDescription
        }
        if case .failed(let message)? = editor.pipelinePhaseExecution.snapshot?.status {
            return message
        }
        return nil
    }

    private struct ErrorCTA {
        let title: String
        let action: () -> Void
    }

    private func errorCTA(for error: AgentStreamError?) -> ErrorCTA? {
        guard let error else { return nil }
        if service.hasPendingHostFollowUp {
            return ErrorCTA(
                title: "Retry",
                action: { service.retryPendingHostFollowUp() }
            )
        }
        switch error {
        case .upstream:
            return nil
        case .authenticationRequired:
            return ErrorCTA(
                title: "Agent settings",
                action: { SettingsWindowController.shared.show(tab: .agent) }
            )
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.isComposerBlocked {
            EmptyView()
        } else if service.canStream {
            VStack(spacing: AppTheme.Spacing.smMd) {
                Text("Ask anything, or start with:")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .multilineTextAlignment(.center)
                VStack(spacing: AppTheme.Spacing.xs) {
                    if showPackStarters {
                        // A pack is active → its own starters replace the generic chips.
                        ForEach(entryCommands) { command in
                            let starter = AgentStarterPrompt(
                                title: command.description ?? command.title,
                                systemImage: "puzzlepiece.extension",
                                prompt: command.command
                            )
                            AgentStarterPromptButton(starterPrompt: starter) {
                                editor.runActivePackStarter()
                            }
                        }
                    } else {
                        ForEach(Self.starterPrompts) { starterPrompt in
                            AgentStarterPromptButton(starterPrompt: starterPrompt) {
                                runStarter(starterPrompt)
                            }
                        }
                    }
                }
            }
            .onAppear { refreshDiscoveredPlugins() }
        }
    }

    /// Entry-point plugin commands (argument-free) surfaced as one-tap chips in a fresh chat —
    /// the active pack's own starters.
    private var entryCommands: [PluginCommandCatalog.PluginCommand] {
        discoveredPlugins.flatMap { $0.commands }.filter { !$0.requiresArgument }
    }

    /// The active pack offers starters → show them instead of the generic chips.
    private var showPackStarters: Bool {
        editor.activePluginName != nil && !entryCommands.isEmpty
    }

    @ViewBuilder
    private var backendRecoveryDock: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(service.backendSetupMessage)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                Text("Open Agent Settings")
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.small)
        }
        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: AppTheme.Layout.chatColumnMax, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(AgentTranscriptScrollPolicy.endID, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var composerDock: some View {
        switch surfaceState.dockOwner {
        case .spendApproval:
            if let approval = service.pendingSpendApproval {
                SpendApprovalCard(
                    approval: approval,
                    error: service.spendApprovalError,
                    isWorking: service.spendApprovalIsRunning,
                    onApprove: { option in
                        Task { await service.approveSpend(option) }
                    },
                    onDecline: { service.declineSpend() },
                    onRefresh: { service.refreshSpendApproval() }
                )
                .padding(.bottom, AppTheme.Spacing.xs)
            }
        case .gateApproval:
            if let gate = service.pendingGateApproval {
                GateApprovalCard(
                    approval: gate,
                    error: service.gateApprovalError,
                    surface: editor.uiContract?.phases[gate.phase]?.surface,
                    isWorking: service.gateApprovalIsWriting,
                    isBlocked: pendingGateIsBlockedByPhaseRun,
                    onApprove: {
                        Task { await service.resolveGate(.approved) }
                    },
                    onDecline: {
                        Task { await service.resolveGate(.declined) }
                    }
                )
                .padding(.bottom, AppTheme.Spacing.xs)
            }
        case .dialog:
            if let dialog = service.pendingDialog {
                @Bindable var service = service
                AgentDialogCard(
                    dialog: dialog,
                    externalSelections: $service.dialogChoiceSelections,
                    accent: editor.activePackAccentColor ?? AppTheme.Accent.primary,
                    libraryAssets: editor.agentPickableMediaAssets,
                    libraryAssetRoles: editor.mediaManifest.intakeRoleByAssetID,
                    submissionError: service.dialogSubmissionError,
                    isSubmitting: service.submittingDialogID == dialog.id,
                    onSubmit: { result in service.submitDialog(dialog, result: result) },
                    onComplete: { service.completeDialog(dialog) },
                    onCancel: { service.cancelDialog() }
                )
                .id(dialog.id)
                .padding(.bottom, AppTheme.Spacing.xs)
            }
        case .backendRecovery:
            backendRecoveryDock
        case .composer:
            footer
        }
    }

    private var footer: some View {
        @Bindable var service = editor.agentService
        return VStack(spacing: AppTheme.Spacing.sm) {
            if let fn = service.pendingFunction {
                HStack(spacing: AppTheme.Spacing.xs) {
                    FunctionPill(title: fn.title, systemImage: fn.systemImage) {
                        service.pendingFunction = nil
                    }
                    Spacer(minLength: 0)
                }
            }
            AgentInputBox(
                draft: $service.draft,
                mentions: $service.mentions,
                isSending: service.isStreaming,
                canSend: canSend,
                onSend: submit,
                onCancel: { service.cancel() },
                onFocusChange: { service.recordComposerFocus($0) }
            ) {
                modelPicker
                byokIndicator
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.bottom, AppTheme.Spacing.mdLg)
        .padding(.top, AppTheme.Spacing.xs)
        .frame(maxWidth: AppTheme.Layout.chatColumnMax)
        .frame(maxWidth: .infinity)
    }

    private func submit() {
        guard canSend else { return }
        if let fn = service.pendingFunction {
            let note = service.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if note.isEmpty {
                // One-tap starter, no note of the user's own → seed the agent hidden; the raw prompt
                // is never the user's words, so it must not appear as a chat bubble.
                service.send(text: fn.prompt, mentions: service.mentions, hidden: true)
            } else {
                // The user added their own direction → that IS their message; keep it visible.
                service.send(
                    text: AgentService.composedFunctionMessage(prompt: fn.prompt, note: note),
                    mentions: service.mentions
                )
            }
        } else {
            service.send(text: service.draft, mentions: service.mentions)
        }
        service.pendingFunction = nil
        service.draft = ""
        service.mentions.removeAll()
    }

    /// A starter chip is a one-tap action: clicking it RUNS the starter immediately. Sent DIRECTLY, not
    /// staged as a composer pill first — staging then submitting in the same update briefly flashes the
    /// pill. The raw prompt is never the user's words, so a note-less run seeds the agent hidden; a note
    /// the user already typed becomes their visible message.
    private func runStarter(_ starter: AgentStarterPrompt) {
        let note = service.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.isEmpty {
            service.send(text: starter.prompt, mentions: service.mentions, hidden: true)
        } else {
            service.send(
                text: AgentService.composedFunctionMessage(prompt: starter.prompt, note: note),
                mentions: service.mentions
            )
        }
        service.pendingFunction = nil
        service.draft = ""
        service.mentions.removeAll()
    }
}

private struct AgentStarterPrompt: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let prompt: String
}

private struct AgentStarterPromptButton: View {
    let starterPrompt: AgentStarterPrompt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: starterPrompt.systemImage)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                Text(starterPrompt.title)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Background.raisedColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Add function")
    }
}

/// A staged starter/pack function in the composer dock: an accent-tinted pill that hides the
/// underlying prose prompt and signals a pre-made function is armed. Removable via the trailing ✕.
private struct FunctionPill: View {
    let title: String
    let systemImage: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
            Text(title)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.bold))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Remove function")
        }
        .foregroundStyle(AppTheme.Accent.primary)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(Capsule(style: .continuous).fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted)))
        .overlay(Capsule(style: .continuous).strokeBorder(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium), lineWidth: AppTheme.BorderWidth.thin))
    }
}
