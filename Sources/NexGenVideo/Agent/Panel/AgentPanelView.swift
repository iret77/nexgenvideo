import NexGenEngine
import SwiftUI

struct AgentPanelView: View {
    @Environment(EditorViewModel.self) var editor
    var presentation: AgentPanelPresentation = .tasks
    var replayTranscriptOnly = false
    var onClose: (() -> Void)?

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
            prompt: "Inspect my media and use propose_media_organization to prepare a selectable plan for folder paths and display names. Wait for native approval before any change.",
            mediaOrganization: true
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

    @ViewBuilder var body: some View {
        if replayTranscriptOnly {
            diagnosticReplayTranscript
        } else {
            panelContents
        }
    }

    private var panelContents: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            if presentation != .decision {
                taskBar
                AgentLiveStatusView(
                status: liveStatus,
                onCancel: {
                    if service.currentSpendRun != nil {
                        service.cancelRunningSpend()
                    } else if let batchID = editor.generationBatchCoordinator.activeBatchID {
                        editor.generationBatchCoordinator.cancelRemaining(batchID: batchID, editor: editor)
                    } else { service.cancel() }
                },
                    onOpenPipeline: presentation == .tasks && editor.hasProductionPipeline
                        ? { editor.revealCockpit(.pipeline) } : nil
                )
                activityProgress
            }
            if surfaceState.dockOwner != .composer && surfaceState.dockOwner != .backendRecovery {
                if presentation != .activity { composerDock.layoutPriority(1) }
            }
            if presentation != .decision {
                taskResult
                workTimeSummary
                if surfaceState.dockOwner == .composer || surfaceState.dockOwner == .backendRecovery {
                    composerDock
                }
                GenerationBatchProgressView(editor: editor)
            }
        }
        .sheet(isPresented: $showDecisionHistory) {
            AgentDecisionHistoryView(messages: service.messages)
        }
        .sheet(isPresented: $showDiagnostics) { diagnosticTranscript }
        .onAppear {
            guard presentation != .decision else { return }
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
            guard presentation != .decision else { return }
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
            if presentation != .decision { MainThreadHangWatchdog.shared.resetContext() }
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
            gateApprovalBlocked: pendingGateIsBlockedByPhaseRun,
            gateApprovalIsWriting: service.gateApprovalIsWriting,
            spendApprovalIsRunning: service.spendApprovalIsRunning
                || editor.generationBatchCoordinator.approving || editor.generationBatchCoordinator.isRecovering,
            hasDialog: service.pendingDialog != nil,
            hasSpendRun: service.currentSpendRun != nil,
            hasBatchRun: editor.generationBatchCoordinator.activeBatchID != nil,
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
                && (!service.canStream || showsAuthenticationError),
            hasRepairPause: service.currentPipelineRepairFailure != nil,
            hasOutdatedApproval: !outdatedApprovalPhases.isEmpty
        ))
    }

    private var outdatedApprovalPhases: [String] {
        (editor.projectState?.phases ?? [])
            .filter { $0.approved && !$0.approvalCurrent }
            .map { PhaseDisplay.label($0.phase) }
    }

    private var liveStatus: AgentLiveStatus {
        switch surfaceState.statusOwner {
        case .repairPaused:
            guard let failure = service.currentPipelineRepairFailure else {
                return AgentLiveStatus(state: .ready, title: "No task running")
            }
            return failure.kind == .unrequestedRevision
                ? AgentLiveStatus(state: .waiting, title: "Revision paused",
                    detail: "The agent asked to revise approved work again without new direction. Choose how to continue below.")
                : AgentLiveStatus(state: .failed, title: "Planning needs repair",
                    detail: "Repeated attempts stopped. Review the recovery action below.")
        case .approvalOutdated:
            return AgentLiveStatus(state: .waiting,
                title: "Approval outdated: " + outdatedApprovalPhases.joined(separator: ", "),
                detail: "An approved artifact no longer matches its approval. Check Pipeline for the next step.")
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
                cancellationRequested: run.cancellationRequested,
                stopLabel: String(localized: "Stop generation")
            )
        case .batchRun:
            let coordinator = editor.generationBatchCoordinator
            let hasQueued = coordinator.snapshots.first { $0.batch.id == coordinator.activeBatchID }?
                .journal.executions.contains { $0.state == .queued } == true
            return AgentLiveStatus(state: .working, title: String(localized: "Generation batch in progress"),
                detail: hasQueued ? String(localized: "Stop requests that have not been submitted. Accepted provider jobs continue.")
                    : String(localized: "No queued requests remain. Accepted provider jobs continue; results appear in Generation batches."),
                canCancel: hasQueued, stopLabel: String(localized: "Stop remaining requests"))
        case .decisionWorking:
            return AgentLiveStatus(state: .working,
                title: surfaceState.dockOwner == .gateApproval
                    ? String(localized: "Recording approval") : String(localized: "Preparing generation options"))
        case .phaseRun:
            guard let snapshot = editor.pipelinePhaseExecution.snapshot, snapshot.isRunning else {
                return AgentLiveStatus(state: .working, title: "Finishing the current phase",
                    detail: "Approval is unavailable until this operation finishes.", canCancel: service.isStreaming,
                    stopLabel: String(localized: "Stop agent"))
            }
            let presentation = PipelinePhaseProgressPresentation(
                stageID: snapshot.stageID
            )
            let count = snapshot.totalUnitCount > 0
                ? " · \(snapshot.completedUnitCount) of \(snapshot.totalUnitCount)"
                : ""
            let stopping = service.isStreaming ? " · The phase operation continues if you stop the agent." : ""
            return AgentLiveStatus(
                state: .working,
                title: taskActivity.title,
                detail: pendingGateIsBlockedByPhaseRun
                    ? "\(presentation.title)\(count) · Approval is unavailable until this operation finishes.\(stopping)"
                    : "\(presentation.title)\(count)\(stopping)",
                canCancel: service.isStreaming,
                stopLabel: String(localized: "Stop agent")
            )
        case .phaseFailure:
            return AgentLiveStatus(
                state: .failed,
                title: editor.pipelinePhaseExecution.snapshot.map { "\(PhaseDisplay.label($0.phase)) failed" } ?? "Phase failed"
            )
        case .actionRequired:
            if surfaceState.dockOwner == .gateApproval, let gate = service.pendingGateApproval {
                return AgentLiveStatus(state: .waiting, title: gate.isRewind ? "Revision requested: \(gate.phaseLabel)" : "\(gate.phaseLabel): approval requested",
                    detail: decisionLocation)
            }
            return AgentLiveStatus(state: .waiting,
                title: surfaceState.dockOwner == .spendApproval ? "Generation approval requested" : "Your response is needed",
                detail: decisionLocation)
        case .hostFollowUp:
            return AgentLiveStatus(
                state: .working,
                title: "Resuming agent"
            )
        case .stream:
            return AgentLiveStatus(state: .working, title: taskActivity.title,
                detail: [taskActivity.expectedResult, service.activityEvents.last?.label]
                    .compactMap { $0 }.joined(separator: " · "), canCancel: true)
        case .turnFailure:
            return AgentLiveStatus(state: .failed, title: "Agent request failed")
        case .backendChecking:
            return AgentLiveStatus(state: .working, title: "Checking Agent")
        case .backendUnavailable:
            return AgentLiveStatus(state: .unavailable, title: "Agent unavailable")
        case .ready:
            return AgentLiveStatus(state: .ready, title: service.stoppedAgent ? "Agent stopped; submitted provider jobs may continue" : "No task running",
                detail: editor.hasProductionPipeline ? "No approval request is open. Check Pipeline for the next step." : nil)
        }
    }

    private var taskActivity: AgentTaskActivityPresentation {
        if service.isStreaming {
            return AgentTaskActivityPresentation(task: service.currentTaskActivity)
        }
        return AgentTaskActivityPresentation(messages: [], phase: editor.pipelinePhaseExecution.snapshot?.phase)
    }

    private var decisionLocation: String {
        presentation == .activity
            ? String(localized: "Respond in the phase dock.")
            : String(localized: "Respond in the decision area.")
    }

    @ViewBuilder private var pipelineRepairRecovery: some View {
        if let failure = service.currentPipelineRepairFailure {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if failure.kind == .unrequestedRevision {
                    Label("Revision paused", systemImage: "arrow.uturn.backward.circle")
                    Text("The agent asked to revise approved work again without new direction from you. All approvals are kept.")
                    Text(failure.origin.chatSessionID == nil
                        ? "Allow the connected agent one more revision request. It still needs your approval."
                        : "Continue keeps every approval. Afterwards, tell the agent what should change if you want a revision.")
                } else {
                    Label("Planning paused after repeated attempts without progress", systemImage: "exclamationmark.triangle")
                    Text("Existing artifacts are preserved. Retry planning with the current project and tool definitions; no new generation is authorized.")
                    if failure.origin.chatSessionID == nil {
                        Text("Allow the connected agent to resubmit its corrected plan. This does not start a new in-app task.")
                    }
                }
                Button(repairActionTitle(failure)) { service.retryPipelineRepair() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(service.isStreaming)
                DisclosureGroup("Diagnostic details") {
                    Text(failure.detail).textSelection(.enabled)
                }
            }
            .interfaceFont(size: AppTheme.Typography.ui)
            .fixedSize(horizontal: false, vertical: true)
            .padding(AppTheme.Spacing.mdLg)
        }
    }

    private func repairActionTitle(_ failure: AgentService.PipelineRepairFailure) -> String {
        switch (failure.kind, failure.origin.chatSessionID == nil) {
        case (.unrequestedRevision, true): "Allow one more revision request"
        case (.unrequestedRevision, false): "Continue without revision"
        case (.repeatedAttempts, true): "Allow connected agent to retry"
        case (.repeatedAttempts, false): "Retry planning"
        }
    }

    @ViewBuilder private var workTimeSummary: some View {
        let time = service.currentWorkTime.flatMap { $0.isEmpty ? nil : $0 }
        let usage = service.currentTokenUsage
        if time != nil || usage != nil {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                if let time {
                    DisclosureGroup("Time in this chat") {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text("Agent \(Self.clock(time.agentSeconds))")
                            Text("Tools \(Self.clock(time.toolSeconds))")
                            Text("Provider generation \(Self.clock(time.providerSeconds))")
                            Text("Waiting for you \(Self.clock(time.waitingSeconds))")
                            Text("Failed attempts \(time.failedAttempts)")
                        }
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel("Time in this chat")
                }
                if let usage {
                    Text(Self.tokenSummary(usage))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.bottom, AppTheme.Spacing.sm)
        }
    }

    private static func clock(_ seconds: Double) -> String {
        AgentActivityTiming.clock(Int(seconds.rounded()))
    }

    private static func tokenSummary(_ usage: AgentTokenUsage) -> LocalizedStringKey {
        let share = (usage.cacheReadShare ?? 0).formatted(.percent.precision(.fractionLength(0)))
        return "Tokens \(tokens(usage.inputTokens)) in · \(tokens(usage.outputTokens)) out · \(tokens(usage.cacheCreationInputTokens)) cache write · \(tokens(usage.cacheReadInputTokens)) cache read (\(share))"
    }

    private static func tokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    @ViewBuilder private var activityProgress: some View {
        if surfaceState.statusOwner == .spendRun, let run = service.currentSpendRun {
            AgentActivityProgressView(timing: .init(startedAt: run.startedAt, lastEventAt: nil,
                providerConfirmedAt: run.providerConfirmedAt),
                completed: 0, total: 0,
                events: [AgentActivityEvent(at: run.startedAt, label: "Requested \(run.modelName) via \(run.providerName)")])
        } else if surfaceState.statusOwner == .batchRun,
           let id = editor.generationBatchCoordinator.activeBatchID,
           let batch = editor.generationBatchCoordinator.snapshots.first(where: { $0.batch.id == id }) {
            AgentActivityProgressView(timing: .init(startedAt: batch.journal.approvedAt,
                lastEventAt: editor.generationBatchCoordinator.lastProgressAt[id],
                providerConfirmedAt: editor.generationBatchCoordinator.providerConfirmedAt[id]),
                completed: batch.journal.executions.filter { $0.state == .complete }.count,
                total: batch.journal.executions.count,
                scope: "generations in this batch",
                events: batch.journal.executions.enumerated().map {
                    AgentActivityEvent(at: nil, label: "Generation \($0.offset + 1): \($0.element.state.rawValue)")
                })
        } else if surfaceState.statusOwner == .phaseRun,
           let run = editor.pipelinePhaseExecution.snapshot, run.isRunning {
            AgentActivityProgressView(timing: .init(startedAt: run.startedAt, lastEventAt: run.lastEventAt),
                completed: run.completedUnitCount, total: run.totalUnitCount,
                scope: "stages in this phase",
                events: [AgentActivityEvent(at: run.startedAt, label: "\(PhaseDisplay.label(run.phase)) started")]
                    + run.stageEvents.map { AgentActivityEvent(at: $0.at, label: PipelinePhaseProgressPresentation(stageID: $0.stageID).title) })
        } else if surfaceState.statusOwner == .stream,
                  service.activitySessionID == service.currentSessionId, let start = service.activityStartedAt {
            AgentActivityProgressView(timing: .init(startedAt: start, lastEventAt: service.activityLastEventAt),
                completed: 0, total: 0, events: service.activityEvents)
        }
    }

    private var statusOwnerIsRunning: Bool {
        switch surfaceState.statusOwner {
        case .spendRun, .batchRun, .decisionWorking, .phaseRun, .hostFollowUp, .stream: true
        default: false
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            HStack {
                Text(presentation == .activity ? "AI activity" : "Tasks")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                Spacer(minLength: AppTheme.Spacing.sm)
                utilityButton(iconOnly: onClose != nil)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .interfaceFont(size: AppTheme.Typography.ui)
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .accessibilityLabel("Close AI activity")
                    .help("Close AI activity and return to Inspector")
                    .reviewAcceptanceProbe("production.activity.close")
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .panelHeaderBar()
            WrapLayout(spacing: AppTheme.Spacing.xs) { taskHistoryButtons }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.Spacing.md)
            PhaseSpendApprovalIndicator(editor: editor)
        }
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
            Button("Sessions") { editor.agentConversationHistoryPresented = true }
                .buttonStyle(.capsule(.secondary, size: .small))
                .modifier(GenerationBatchRuntimeProbe(identifier: "agent.sessions", enabled: WorkspaceUIAcceptance.isRequested))
        }
    }

    private var sessionHistory: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            HStack {
                Button("New Session") {
                    service.startNewConversation()
                    editor.agentConversationHistoryPresented = false
                }
                .disabled(!service.canStartNewConversation)
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Done") { editor.agentConversationHistoryPresented = false }
                    .modifier(GenerationBatchRuntimeProbe(identifier: "agent.sessions.done", enabled: WorkspaceUIAcceptance.isRequested))
            }
            .buttonStyle(.inlineAction())
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.top, AppTheme.Spacing.sm)
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
    }

    @State private var showDecisionHistory = false
    @State private var showDiagnostics = false
    @State private var messageScrollPosition = ScrollPosition(idType: String.self)
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
            let groups = AnthropicModelSelection.pickerGroups(service.pickerModels)
            let isEnabled = !groups.current.isEmpty
            Menu {
                ForEach(groups.current) { model in
                    modelMenuItem(model)
                }
                if !groups.older.isEmpty {
                    Divider() // app-theme: native-menu-divider
                    Menu("Older Models") {
                        ForEach(groups.older) { model in
                            modelMenuItem(model)
                        }
                    }
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(modelPickerTitle)
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(isEnabled ? AppTheme.Text.secondaryColor : AppTheme.Text.disabledControlColor)
                    Image(systemName: "chevron.down")
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(isEnabled ? AppTheme.Text.tertiaryColor : AppTheme.Text.disabledControlColor)
                }
                .opacity(isEnabled ? AppTheme.Opacity.opaque : AppTheme.Opacity.disabledControl)
            }
            .menuStyle(.borderlessButton)
            .tint(isEnabled ? AppTheme.Text.secondaryColor : AppTheme.Text.disabledControlColor)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!isEnabled)
            .help(isEnabled
                ? "Model for this conversation · Anthropic API key"
                : "No model list available yet · Anthropic API key")
        }
    }

    private func modelMenuItem(_ model: AnthropicModelInfo) -> some View {
        Button {
            service.selectModel(model)
        } label: {
            if model.id == service.effectiveModel?.id {
                Label(model.displayName, systemImage: "checkmark")
            } else {
                Text(model.displayName)
            }
        }
    }

    private var modelPickerTitle: String {
        if let selected = service.effectiveModel { return selected.displayName }
        return service.isDiscoveringModels ? "Loading Models…" : "No Models"
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

    private var taskItems: [AgentTranscriptItem] {
        AgentTranscriptProjection.taskItems(messages: service.messages, isStreaming: service.isStreaming)
    }

    private var showsTaskChoices: Bool {
        taskItems.isEmpty && !service.isStreaming && !service.isComposerBlocked
            && service.canStream && service.pendingFunction == nil
    }

    private var taskResult: some View {
        let items = taskItems
        let latestMessage = items.compactMap { item -> AgentMessage? in
            guard case .assistantResult(let message) = item else { return nil }
            return message
        }.last
        let lastEarlierResultID = AgentTaskResultMarker.lastEarlierResultID(
            items: items,
            messages: service.messages,
            currentTurnBaseline: service.isStreaming && service.activitySessionID == service.currentSessionId
                ? service.activityBaselineMessageID : nil,
            workIsRunning: statusOwnerIsRunning
        )
        return VStack(spacing: AppTheme.Spacing.sm) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    if !items.isEmpty {
                        Text("Messages")
                            .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                        ForEach(items) { item in
                            Group {
                                switch item {
                                case .assistantResult(let message):
                                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                                        if item.id == lastEarlierResultID {
                                            Text("Last result")
                                                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                                                .accessibilityAddTraits(.isHeader)
                                        }
                                        AgentMessageView(message: message, toolResults: toolResults)
                                            .modifier(GenerationBatchRuntimeProbe(
                                                identifier: "agent.result.\(message.id.uuidString)",
                                                enabled: WorkspaceUIAcceptance.isRequested
                                            ))
                                    }
                                case .notice(let notice):
                                    Text(notice.text).textSelection(.enabled)
                                        .interfaceFont(size: AppTheme.Typography.ui)
                                        .foregroundStyle(AppTheme.Text.secondaryColor)
                                default: EmptyView()
                                }
                            }
                            .id(item.id)
                        }
                    } else if showsTaskChoices {
                        emptyState
                    } else if statusOwnerIsRunning {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text(taskActivity.title)
                                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                            if let result = taskActivity.expectedResult {
                                Text(result).interfaceFont(size: AppTheme.Typography.ui)
                            }
                            Text("The task is running. Its next response will appear here.")
                                .interfaceFont(size: AppTheme.Typography.ui)
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                    }
                    errorBanner
                }
                .padding(AppTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollTargetLayout()
            }
            .scrollPosition($messageScrollPosition)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            if let last = items.last {
                WrapLayout(spacing: AppTheme.Spacing.sm) {
                    Button("Latest message") { messageScrollPosition.scrollTo(id: last.id, anchor: .bottom) }
                        .buttonStyle(.capsule(.secondary, size: .small))
                    if let latestMessage {
                        Button("Reply to Agent") { service.stageReply(to: latestMessage.id) }
                            .buttonStyle(.capsule(.secondary, size: .small))
                            .disabled(service.isStreaming || service.isComposerBlocked)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.sm)
            }
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
            diagnosticReplayTranscript
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.Layout.chatColumnMax, height: AppTheme.ComponentSize.agentAssetPickerHeight)
    }

    var diagnosticReplayTranscript: some View {
        ScrollView {
            AgentTranscriptLayout(spacing: AppTheme.Spacing.xl) {
                ForEach(transcriptTurns) { turn in
                    AgentTranscriptTurnView(turn: turn, toolResults: toolResults)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { HangReplayTranscriptProbe() }
        }
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
                    .reviewAcceptanceProbe("agent.failure.message", text: message)
                if !showsAuthenticationError, let cta = errorCTA(for: service.streamError) {
                    Button(action: cta.action) {
                        Text(cta.title)
                            .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    }
                    .buttonStyle(.capsule(.secondary))
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
            ActionSection(title: "Choose a task") {
                VStack(spacing: AppTheme.Spacing.xs) {
                    if showPackStarters {
                        // A pack is active → its own starters replace the generic chips.
                        if let command = entryCommands.first {
                            let starter = AgentStarterPrompt(
                                title: command.description ?? command.title,
                                systemImage: "puzzlepiece.extension",
                                prompt: command.command
                            )
                            AgentStarterPromptButton(starterPrompt: starter, prominent: true) {
                                editor.runActivePackStarter()
                            }
                            .disabled(editor.productionStarting)
                        }
                    } else {
                        ForEach(Self.starterPrompts) { starterPrompt in
                            AgentStarterPromptButton(starterPrompt: starterPrompt) {
                                runStarter(starterPrompt)
                            }
                        }
                    }
                }
                if showPackStarters {
                    taskMenu(title: "Other tasks")
                } else if let task = editor.selectedObjectRevisionTask {
                    Button("Revise Selected Object") { service.stageTask(task) }
                        .buttonStyle(.capsule(.secondary, size: .regular))
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
            .modifier(GenerationBatchRuntimeProbe(identifier: "agent.backend-recovery", enabled: WorkspaceUIAcceptance.isRequested))
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
            if let phase = service.autoApprovingSpendPhase ?? editor.generationBatchCoordinator.autoApprovingPhase {
                PhaseSpendApprovalStartNotice(phase: phase)
                    .padding(.bottom, AppTheme.Spacing.xs)
            } else if editor.generationBatchCoordinator.pending != nil {
                // The decision is offered height before the task result so its list can show a complete request.
                GenerationBatchCard(editor: editor, runtimeEvidenceEnabled: GenerationBatchReviewSelfTest.isRequested
                    || WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested)
                    .layoutPriority(1)
            } else if let approval = service.pendingSpendApproval {
                SpendApprovalCard(
                    approval: approval,
                    error: service.spendApprovalError,
                    isWorking: service.spendApprovalIsRunning,
                    onApprove: { option in
                        if let phase = service.pendingSpendPhase { editor.revealReviewSurface(for: phase) }
                        Task { await service.approveSpend(option) }
                    },
                    onDecline: { service.declineSpend() },
                    onRefresh: { service.refreshSpendApproval() },
                    onPrepare: { service.prepareSpendOption($0) },
                    approvalPhase: service.pendingSpendPhase,
                    onApproveAll: { option in
                        if let phase = service.pendingSpendPhase { editor.revealReviewSurface(for: phase) }
                        Task { await service.approveSpendForPhase(option) }
                    }
                )
                .padding(.bottom, AppTheme.Spacing.xs)
            }
        case .gateApproval:
            if let gate = service.pendingGateApproval {
                GateApprovalCard(
                    approval: gate,
                    error: service.gateApprovalError,
                    isWorking: service.gateApprovalIsWriting,
                    isBlocked: pendingGateIsBlockedByPhaseRun,
                    onApprove: { approvalID in
                        Task { await service.resolveGate(.approved, approvalID: approvalID) }
                    },
                    onDecline: { approvalID in
                        Task { await service.resolveGate(.declined, approvalID: approvalID) }
                    }
                )
                .id(gate.id)
                .padding(.bottom, AppTheme.Spacing.xs)
            }
        case .dialog:
            if let dialog = service.pendingDialog {
                @Bindable var service = service
                let previousScope = service.previousWorkflowMaterialScope(for: dialog)
                AgentDialogCard(
                    dialog: dialog,
                    externalSelections: $service.dialogChoiceSelections,
                    externalDraft: Binding(
                        get: {
                            service.pendingDialog?.id == dialog.id && service.previousWorkflowMaterialScope(for: dialog) == previousScope
                                ? service.dialogDraft : AgentDialogDraft()
                        },
                        set: {
                            if service.pendingDialog?.id == dialog.id,
                               service.previousWorkflowMaterialScope(for: dialog) == previousScope { service.dialogDraft = $0 }
                        }
                    ),
                    previousWorkflowScope: previousScope,
                    loadPreviousWorkflowMaterials: { try await service.previousWorkflowMaterials(scope: $0) },
                    isPreviousWorkflowScopeCurrent: {
                        service.pendingDialog?.id == dialog.id && service.previousWorkflowMaterialScope(for: dialog) == $0
                    },
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
        case .repairRecovery:
            pipelineRepairRecovery
        case .backendRecovery:
            backendRecoveryDock
        case .composer:
            footer
        }
    }

    private var footer: some View {
        @Bindable var service = editor.agentService
        let sessionID = service.currentSessionId
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if !showsTaskChoices {
                taskMenu(title: service.pendingFunction == nil ? "Choose a task" : "Change task")
            }
            if let fn = service.pendingFunction {
                HStack(spacing: AppTheme.Spacing.xs) {
                    FunctionPill(title: fn.title, systemImage: fn.systemImage) {
                        service.pendingFunction = nil
                    }.reviewAcceptanceProbe("agent.task.staged", text: fn.title)
                    Spacer(minLength: AppTheme.Spacing.none)
                }
            }
            if service.pendingFunction != nil && !service.isStreaming {
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
                if !service.isStreaming && !service.draft.isEmpty {
                    Text("Choose a task to use the saved instructions.")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    modelPicker
                    Spacer(minLength: AppTheme.Spacing.sm)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.bottom, AppTheme.Spacing.mdLg)
        .padding(.top, AppTheme.Spacing.xs)
        .frame(maxWidth: AppTheme.Layout.chatColumnMax)
        .frame(maxWidth: .infinity)
    }

    private func taskMenu(title: String) -> some View {
        Menu {
            ForEach(Self.starterPrompts) { starter in
                Button(starter.title) { runStarter(starter) }
            }
            if let task = editor.selectedObjectRevisionTask {
                Button("Revise Selected Object") { service.stageTask(task) }
            }
        } label: {
            ActionMenuLabel(title: title)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.capsule(.secondary, size: .regular))
        .disabled(service.isStreaming || service.isComposerBlocked)
        .reviewAcceptanceProbe("agent.task.choose", state: !service.isStreaming && !service.isComposerBlocked)
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
            prompt: starter.prompt, requiresDirection: starter.requiresDirection,
            mediaOrganizationScope: starter.mediaOrganization ? .init(folderID: nil) : nil))
    }

}

private struct AgentStarterPrompt: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let prompt: String
    var requiresDirection: Bool = false
    var mediaOrganization = false
}

private struct AgentStarterPromptButton: View {
    let starterPrompt: AgentStarterPrompt
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionLabel(title: starterPrompt.title, systemImage: starterPrompt.systemImage)
        }
        .buttonStyle(.capsule(prominent ? .prominent : .secondary, size: .regular))
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
