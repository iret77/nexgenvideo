import NexGenEngine
import SwiftUI

struct AgentPanelView: View {
    @Environment(EditorViewModel.self) var editor

    private static let starterPrompts: [AgentStarterPrompt] = [
        AgentStarterPrompt(
            title: "Develop or revise the project brief",
            systemImage: "doc.text",
            prompt: "Develop or revise this project's brief from the supplied instructions. Use the existing project tools, preserve approved artifacts, and request explicit rewind when phase gates require it.",
            requiresDirection: true
        ),
        AgentStarterPrompt(
            title: "Apply a project change",
            systemImage: "pencil",
            prompt: "Apply the supplied change to this project through its existing tools. Confirm ambiguous targets through a structured dialog, preserve approved artifacts, and obtain required phase and spending approvals.",
            requiresDirection: true
        ),
        AgentStarterPrompt(
            title: "Generate an AI video",
            systemImage: "sparkles",
            prompt: "Generate an AI video from the supplied direction.",
            requiresDirection: true
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
        (service.pendingFunction.map { !$0.requiresDirection || AgentService.hasWorkOrderDirection(service.draft, mentions: service.mentions) }
            ?? false)
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            taskBar
            taskResult
            AgentLiveStatusView(
                status: liveStatus,
                onCancel: { service.cancelRunningSpend() }
            )
            composerDock
            GenerationBatchProgressView(editor: editor)
        }
        .sheet(isPresented: $showDecisionHistory) {
            AgentDecisionHistoryView(messages: service.messages)
        }
        .sheet(isPresented: $showDiagnostics) { diagnosticTranscript }
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
            HangDiagnosticRecorder.shared.record(.context, values: [
                context.isStreaming ? 1 : 0, context.hasDialog ? 1 : 0,
                context.hasGateApproval ? 1 : 0, context.hasSpendApproval ? 1 : 0,
            ])
            service.captureDiagnosticTranscript()
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
                || editor.generationBatchCoordinator.pending != nil
                || service.currentSpendRun != nil
        )
    }

    private var surfaceState: AgentSurfaceState {
        let snapshot = editor.pipelinePhaseExecution.snapshot
        let activityVisible = runningTranscriptActivity != nil
        return AgentSurfaceState.resolve(.init(
            hasSpendApproval: service.pendingSpendApproval != nil || editor.generationBatchCoordinator.pending != nil,
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

    private var taskBar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("Tasks")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.sm)
                utilityButton(iconOnly: false)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.xs) { taskHistoryButtons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) { taskHistoryButtons }
            }
        }
        .padding(AppTheme.Spacing.md)
        .popover(isPresented: Binding(get: { editor.agentConversationHistoryPresented },
            set: { editor.agentConversationHistoryPresented = $0 })) {
            sessionHistory
        }
    }

    private var taskHistoryButtons: some View {
        Group {
            Button("Decisions") { showDecisionHistory = true }
                .buttonStyle(.capsule(.secondary, size: .small))
                .background {
                    if WorkspaceUIAcceptance.isRequested || ChatHangReplay.isRequested {
                        AppRelaunchClickProbe(identifier: "agent.decisions")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                }
            Button("Diagnostics") { showDiagnostics = true }
                .buttonStyle(.capsule(.secondary, size: .small))
                .background {
                    if WorkspaceUIAcceptance.isRequested || ChatHangReplay.isRequested {
                        AppRelaunchClickProbe(identifier: "agent.diagnostics")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                }
            Menu("Sessions") {
                Button("Resume Session") { editor.agentConversationHistoryPresented = true }
                Button("New Session") { service.startNewConversation() }
                    .disabled(!service.canStartNewConversation)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var sessionHistory: some View {
        ChatHistoryList(
            sessions: service.sessions.sorted { $0.updatedAt > $1.updatedAt },
            currentId: service.currentSessionId,
            cuesBySessionID: conversationCues,
            canSwitch: !service.isComposerBlocked && !service.isStreaming,
            onSelect: { id in
                service.selectSession(id)
                editor.agentConversationHistoryPresented = false
            },
            onDelete: { service.deleteSession($0) }
        )
    }

    @State private var showDecisionHistory = false
    @State private var showDiagnostics = false
    @State private var showUtilities = false
    @State private var discoveredPlugins: [PluginCommandCatalog.PluginInfo] = []

    /// The launcher shows when the active pack exposes at least one starter.
    private var pluginLauncherAvailable: Bool {
        discoveredPlugins.contains { !$0.commands.isEmpty }
    }

    private func utilityButton(iconOnly: Bool) -> some View {
        Button {
            refreshDiscoveredPlugins()
            showUtilities.toggle()
        } label: {
            Group {
                if iconOnly {
                    Image(systemName: "ellipsis")
                } else {
                    Label("More", systemImage: "ellipsis")
                }
            }
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.capsule(.secondary, size: .small))
        .controlSize(.small)
        .background {
            if WorkspaceUIAcceptance.isRequested || ChatHangReplay.isRequested {
                AppRelaunchClickProbe(
                    identifier: "agent.utilities",
                    acceptanceState: iconOnly
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .popover(isPresented: $showUtilities, arrowEdge: .top) {
            PluginLauncherPopover(
                plugins: pluginLauncherAvailable ? discoveredPlugins : [],
                canCloseConversation: !service.isComposerBlocked && !service.isStreaming,
                onRun: runPluginCommand,
                onCloseConversation: closeCurrentConversation
            )
        }
        .accessibilityLabel("More")
    }

    private func runPluginCommand(_ command: PluginCommandCatalog.PluginCommand) {
        showUtilities = false
        if command.requiresArgument {
            service.stageTask(.init(title: command.title, systemImage: "puzzlepiece.extension",
                prompt: command.command + " ", requiresDirection: true))
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
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Image(systemName: "chevron.down")
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Model for this conversation · Anthropic API key")
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

    private var taskResult: some View {
        let results = transcriptTurns.reversed().lazy.map { turn in
            turn.items.compactMap { item -> AgentMessage? in
                guard case .assistantResult(let message) = item else { return nil }
                return message
            }
        }.first(where: { !$0.isEmpty }) ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if !results.isEmpty {
                    Text("Task Result")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                    ForEach(results) { message in
                        AgentMessageView(message: message, toolResults: toolResults)
                    }
                    if let message = results.last {
                        Button("Reply to Agent") { service.stageReply(to: message.id) }
                            .buttonStyle(.capsule(.secondary, size: .small))
                            .disabled(service.isStreaming || service.isComposerBlocked)
                    }
                } else if !service.isStreaming {
                    emptyState
                }
                errorBanner
            }
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diagnosticTranscript: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Diagnostic Transcript")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Done") { showDiagnostics = false }
                    .buttonStyle(.inlineAction())
                    .background {
                        if WorkspaceUIAcceptance.isRequested || ChatHangReplay.isRequested {
                            AppRelaunchClickProbe(identifier: "agent.diagnostics.done")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                        }
                    }
            }
            ScrollView {
                AgentTranscriptLayout(spacing: AppTheme.Spacing.xl) {
                    ForEach(transcriptTurns) { turn in
                        AgentTranscriptTurnView(turn: turn, toolResults: toolResults)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.chatColumnMax, height: AppTheme.ComponentSize.agentAssetPickerHeight)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = currentFailureMessage,
           surfaceState.dockOwner == .composer {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(message)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .multilineTextAlignment(.leading)
                if let cta = errorCTA(for: service.streamError) {
                    Button(action: cta.action) {
                        Text(cta.title)
                            .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
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
                Text("Choose a task:")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
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
        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: AppTheme.Layout.chatColumnMax, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var composerDock: some View {
        switch surfaceState.dockOwner {
        case .spendApproval:
            if editor.generationBatchCoordinator.pending != nil {
                GenerationBatchCard(editor: editor)
            } else if let approval = service.pendingSpendApproval {
                SpendApprovalCard(
                    approval: approval,
                    error: service.spendApprovalError,
                    isWorking: service.spendApprovalIsRunning,
                    onApprove: { option in
                        Task { await service.approveSpend(option) }
                    },
                    onDecline: { service.declineSpend() },
                    onRefresh: { service.refreshSpendApproval() },
                    onPrepare: { service.prepareSpendOption($0) }
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
                    externalDraft: Binding(
                        get: { service.pendingDialog?.id == dialog.id ? service.dialogDraft : AgentDialogDraft() },
                        set: { if service.pendingDialog?.id == dialog.id { service.dialogDraft = $0 } }
                    ),
                    accent: editor.activePackAccentColor ?? AppTheme.Accent.primary,
                    libraryAssets: editor.agentPickableMediaAssets,
                    libraryAssetRoles: editor.mediaManifest.intakeRoleByAssetID,
                    libraryPickerState: editor.mediaPickerState(for: .intake(dialog.id)),
                    onRevealLibraryAsset: { editor.revealAssetInMedia($0) },
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
        let sessionID = service.currentSessionId
        return VStack(spacing: AppTheme.Spacing.sm) {
            Menu("Choose Task") {
                ForEach(Self.starterPrompts) { starter in
                    Button(starter.title) { runStarter(starter) }
                }
                if let task = editor.selectedObjectRevisionTask {
                    Button("Revise Selected Object") { service.stageTask(task) }
                }
            }
            .menuStyle(.borderlessButton)
            .disabled(service.isStreaming || service.isComposerBlocked)
            if let fn = service.pendingFunction {
                HStack(spacing: AppTheme.Spacing.xs) {
                    FunctionPill(title: fn.title, systemImage: fn.systemImage) {
                        service.pendingFunction = nil
                    }
                    Spacer(minLength: AppTheme.Spacing.none)
                }
            }
            if service.pendingFunction != nil {
                AgentInputBox(
                    draft: $service.draft,
                    mentions: $service.mentions,
                    composerHeight: $service.composerHeight,
                    initiallyFocused: service.composerShouldFocus,
                    isSending: service.isStreaming,
                    canSend: canSend,
                    onSend: submit,
                    onCancel: { service.cancel() },
                    onFocusChange: { service.recordComposerFocus($0, for: sessionID) }
                ) {
                    modelPicker
                }
                .id(sessionID)
            } else {
                if !service.isStreaming {
                    Text(service.draft.isEmpty ? "Choose a task to continue." : "Choose a task to use the saved instructions.")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    modelPicker
                    Spacer(minLength: AppTheme.Spacing.sm)
                    if service.isStreaming {
                        Button("Stop Task") { service.cancel() }
                            .buttonStyle(.capsule(.secondary, size: .small))
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.bottom, AppTheme.Spacing.mdLg)
        .padding(.top, AppTheme.Spacing.xs)
        .frame(maxWidth: AppTheme.Layout.chatColumnMax)
        .frame(maxWidth: .infinity)
    }

    private func submit() {
        guard canSend, let function = service.pendingFunction,
              service.sendWorkOrder(function, direction: service.draft, mentions: service.mentions) else { return }
        service.pendingFunction = nil
        service.draft = ""
        service.mentions.removeAll()
    }

    private func runStarter(_ starter: AgentStarterPrompt) {
        service.stageTask(.init(title: starter.title, systemImage: starter.systemImage,
            prompt: starter.prompt, requiresDirection: starter.requiresDirection))
    }

}

private struct AgentStarterPrompt: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let prompt: String
    var requiresDirection: Bool = false
}

private struct AgentStarterPromptButton: View {
    let starterPrompt: AgentStarterPrompt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: starterPrompt.systemImage)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                Text(starterPrompt.title)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
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
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
            Text(title)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.bold)
            }
            .buttonStyle(.plain)
            .help("Remove function")
        }
        .foregroundStyle(AppTheme.Accent.primary)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .background(Capsule(style: .continuous).fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted)))
        .overlay(Capsule(style: .continuous).strokeBorder(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium), lineWidth: AppTheme.BorderWidth.thin))
    }
}
