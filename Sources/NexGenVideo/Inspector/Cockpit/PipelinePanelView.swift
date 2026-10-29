import SwiftUI
import NexGenEngine

enum PipelineApprovalControl {
    static func isEnabled(
        approvalReady: Bool,
        controlsAvailable: Bool,
        gateWriting: Bool,
        pipelineIsRunning: Bool,
        hostDecisionPending: Bool
    ) -> Bool {
        approvalReady
            && controlsAvailable
            && !gateWriting
            && !pipelineIsRunning
            && !hostDecisionPending
    }
}

enum PipelineSurfaceRouting {
    enum Destination: Equatable {
        case tab(CockpitTab)
        case pack(id: String, title: String)
    }

    struct Route: Equatable {
        let icon: String
        let taskClass: String
        let destination: Destination

        var destinationLabel: String {
            switch destination {
            case .tab(let tab): tab.rawValue
            case .pack(_, let title): title
            }
        }
    }

    /// The one destination name the approval card, the agent and the Pipeline row show for a phase.
    static func reviewDestinationLabel(
        for phase: String,
        contract: ContractData?,
        availablePackSurfaces: [CockpitSurfaceData]
    ) -> String {
        route(for: phase, contract: contract, availablePackSurfaces: availablePackSurfaces)?.destinationLabel
            ?? CockpitTab.pipeline.rawValue
    }

    static func route(
        for phase: String,
        contract: ContractData?,
        availablePackSurfaces: [CockpitSurfaceData]
    ) -> Route? {
        guard let entry = contract?.phases[phase] else { return nil }
        if let surface = availablePackSurfaces.first(where: { $0.phase == phase }) {
            return Route(
                icon: surface.symbol,
                taskClass: entry.taskClass,
                destination: .pack(id: surface.id, title: surface.title)
            )
        }
        if contract?.cockpitSurfaces.contains(where: { $0.phase == phase }) == true { return nil }
        return switch entry.surface {
        case "review": reviewRoute(for: phase, taskClass: entry.taskClass)
        case "prose": Route(icon: "text.cursor", taskClass: entry.taskClass,
            destination: .tab(phase == "script" ? .script : phase == "treatment" ? .treatment : .story))
        case "choice": choiceRoute(for: phase, taskClass: entry.taskClass)
        default: nil
        }
    }

    private static func choiceRoute(for phase: String, taskClass: String) -> Route? {
        switch phase {
        case "project_init": Route(icon: "doc", taskClass: taskClass, destination: .tab(.project))
        case "production_design": Route(icon: "paintpalette", taskClass: taskClass, destination: .tab(.productionDesign))
        case "shot_planning": Route(icon: "list.bullet.rectangle", taskClass: taskClass, destination: .tab(.shotPlanning))
        case "render": Route(icon: "film", taskClass: taskClass, destination: .tab(.review))
        default: nil
        }
    }

    private static func reviewRoute(for phase: String, taskClass: String) -> Route? {
        switch phase {
        case "script":
            Route(icon: "doc.text", taskClass: taskClass, destination: .tab(.script))
        case "storyboard":
            Route(icon: "eye", taskClass: taskClass, destination: .tab(.storyboard))
        case "shot_planning":
            Route(icon: "list.bullet.rectangle", taskClass: taskClass, destination: .tab(.shotPlanning))
        case "bible":
            Route(icon: "eye", taskClass: taskClass, destination: .tab(.bible))
        case "shotlist":
            Route(icon: "eye", taskClass: taskClass, destination: .tab(.shotlist))
        case "render_review":
            Route(icon: "checklist", taskClass: taskClass, destination: .tab(.renderReview))
        case "sanity", "frames", "render":
            Route(icon: "eye", taskClass: taskClass, destination: .tab(.review))
        default:
            choiceRoute(for: phase, taskClass: taskClass)
        }
    }
}

// Pipeline cockpit panel: the project's phase gates as a vertical checklist, with the next open phase
// highlighted and gate mutations routed through NativeGateWriter.

enum PipelinePanelPresentation { case overview, sidebar, dock }

struct PipelinePanelView: View {
    var presentation: PipelinePanelPresentation = .overview
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.interfaceScale) private var interfaceScale

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded(ProjectStateData?)
        case failed(CockpitError)
    }

    @State private var state: LoadState = .idle
    /// Guards against a stale reload result overwriting a newer one when the project changes mid-flight.
    @State private var loadToken = 0
    /// True while a gate mutation (approve / needs-revision / rewind) is being written + reloaded.
    @State private var gateWriting = false
    @State private var dataRoot: URL?
    @State private var readinessToken = 0
    @State private var readinessTask: Task<Void, Never>?
    @State private var readinessRefreshQueued = false
    @State private var approvalPhase: String?
    @State private var approvalReadiness = NativeGateApprovalReadiness.blocked(
        "The pipeline state is unavailable."
    )
    @State private var mutationReadiness = NativeGateApprovalReadiness.blocked(
        "The pipeline state is unavailable."
    )
    @State private var pendingRewind: RewindRequest?
    @State private var showsReadinessDiagnostics = false

    private struct RewindRequest {
        let home: URL
        let revision: Int
        let phase: String
        let affected: [String]
    }

    /// A user-safe error plus an agent-only diagnostic for click-time races or write failures.
    @State private var gateError: GateErrorState?

    private struct GateErrorState: Equatable {
        let message: String
        let diagnostic: String
    }

    private var runningPhase: String? {
        guard let dataRoot else { return nil }
        return editor.pipelinePhaseRunCoordinator.runningPhase(
            projectRoot: dataRoot
        )
    }

    private var activeGenerationPhase: String? {
        let coordinator = editor.generationBatchCoordinator
        return coordinator.snapshots.first { $0.batch.id == coordinator.activeBatchID }?.batch.payload.phase
    }

    private var workIsRunning: Bool {
        runningPhase != nil || editor.agentService.isStreaming
            || editor.agentService.currentSpendRun != nil || editor.generationBatchCoordinator.activeBatchID != nil
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: presentation == .dock ? nil : .infinity, alignment: .top)
        .background { acceptanceProbe("root") }
        .task(id: editor.projectURL) { await load() }
        // Re-read when the engine state changes (e.g. production just started) — projectURL is unchanged
        // then, so without this the panel would keep showing the stale "Start production" state.
        .onChange(of: editor.engineStateRevision) { _, _ in
            Task { await load(showProgress: false) }
        }
        .onChange(of: editor.projectURL) { _, _ in
            pendingRewind = nil
            gateError = nil
        }
        .onChange(of: approvalPhase == "render" ? editor.timeline : nil) { _, _ in refreshApprovalReadiness() }
        .onChange(of: approvalPhase == "render" ? editor.mediaAssets.map(\.url) : nil) { _, _ in refreshApprovalReadiness() }
        .onChange(of: runningPhase) { _, _ in refreshApprovalReadiness() }
        .onChange(of: editor.agentService.isStreaming) { _, _ in refreshApprovalReadiness() }
        .confirmationDialog("Rewind pipeline?", isPresented: Binding(
            get: { pendingRewind != nil }, set: { if !$0 { pendingRewind = nil } }
        ), presenting: pendingRewind) { request in
            Button("Rewind to \(PhaseDisplay.label(request.phase))", role: .destructive) {
                guard editor.workingRoot == request.home, editor.engineStateRevision == request.revision else {
                    gateError = GateErrorState(message: "The pipeline changed. Review the rewind again.", diagnostic: "Rewind confirmation no longer matches the project revision.")
                    return
                }
                apply(failureMessage: "Couldn't rewind the pipeline. Try again.") { home in
                    guard home == request.home else { throw NativeGateWriter.WriteError.notInitialized }
                    try NativeGateWriter.rewind(projectDir: home, targetPhase: request.phase,
                        declaredPack: editor.declaredPluginName, declaredBinding: editor.declaredPluginBinding,
                        declaredProductionContract: editor.declaredProductionContract,
                        executionCoordinator: editor.pipelinePhaseRunCoordinator)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("Reset approvals from \(PhaseDisplay.label(request.phase)) onward: \(request.affected.map(PhaseDisplay.label).joined(separator: ", ")). Existing media, takes and timeline clips remain in the project.")
        }

    }

    private var hasHostDecision: Bool {
        editor.agentService.isComposerBlocked || editor.generationBatchCoordinator.pending != nil
    }

    private var hasLoadedPhases: Bool {
        if case .loaded(let data) = state { return data?.phases.isEmpty == false }
        return false
    }

    @ViewBuilder
    private var content: some View {
        if presentation == .dock && hasHostDecision && !hasLoadedPhases {
            bootstrapDock
        } else {
            switch state {
            case .idle, .loading:
                centeredProgress()
            case .failed(let error):
                if presentation == .dock && error == .notInitialized {
                    bootstrapDock
                } else if presentation == .sidebar {
                    CockpitStateView.empty(icon: "list.bullet.rectangle", title: "Workflow",
                        message: error == .notInitialized && !editor.hasProductionPipeline
                            ? "Start production to prepare this project's workflow." : error.message)
                } else {
                    CockpitStateView.error(error, title: "Couldn't load the pipeline",
                        subject: "the pipeline", activePack: InstalledPack.named(editor.activePluginName),
                        startProduction: { editor.startProduction() }, isStarting: editor.productionStarting,
                        hasProduction: editor.hasProductionPipeline) { Task { await load() } }
                }
            case .loaded(nil):
                if presentation == .dock { bootstrapDock }
                else {
                    CockpitStateView.empty(icon: "list.bullet.rectangle", title: "No pipeline yet",
                        message: "Start production to prepare this project's workflow.")
                }
            case .loaded(.some(let data)):
                switch presentation {
                case .overview: loadedBody(data)
                case .sidebar: workflowSidebar(data)
                case .dock:
                    if data.phases.isEmpty && data.confirmedIdentityRecovery == nil { bootstrapDock }
                    else { phaseDock(data) }
                }
            }
        }
    }

    private var bootstrapDock: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(editor.agentService.pendingDialog?.title ?? String(localized: "Production"))
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
            if hasHostDecision {
                AgentPanelView(presentation: .decision)
            } else if editor.productionStarting {
                HStack(spacing: AppTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Setting up production…")
                }
            } else if editor.projectURL == nil {
                Text("Open a project to start production.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            } else if editor.hasProductionPipeline {
                Text("The existing workflow could not be loaded.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.inlineAction(.neutral))
            } else {
                Text("Prepare this project's production workflow.")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Button("Start production") { editor.startProduction() }
                    .buttonStyle(.inlineAction(.pack))
                    .disabled(workIsRunning || editor.packWiringBroken != nil)
                    .background { acceptanceProbe("dock.start", enabled: !workIsRunning && editor.packWiringBroken == nil) }
            }
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.raisedColor)
    }

    @ViewBuilder
    private func workflowSidebar(_ data: ProjectStateData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                ForEach(data.phases) { phase in
                    let current = phase.phase == data.nextPhaseName
                    let hasSurface = PipelineSurfaceRouting.route(for: phase.phase, contract: editor.uiContract,
                        availablePackSurfaces: editor.availableCockpitPackSurfaces) != nil
                    let running = runningPhase == phase.phase || editor.agentService.currentTaskPhase == phase.phase
                        || activeGenerationPhase == phase.phase
                    let status = PipelinePhasePresentation.resolve(phase: phase, isCurrent: current,
                        isRunning: running, ready: current && approvalReadiness.isReady)
                    Button { selectPhase(phase.phase) } label: {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Image(systemName: status.symbol)
                                .frame(width: AppTheme.IconSize.md)
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                Text(PhaseDisplay.label(phase.phase))
                                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                                Text(status.label)
                                    .interfaceFont(size: AppTheme.Typography.metadata)
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                            }
                            Spacer(minLength: AppTheme.Spacing.none)
                        }
                        .padding(AppTheme.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(editor.productionSelectedPhase == phase.phase
                            ? editor.projectPalette.accent.opacity(AppTheme.Opacity.subtle)
                            : AppTheme.Background.clearColor,
                            in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.inlineAction(.neutral))
                    .disabled(!hasSurface)
                    .accessibilityLabel("\(PhaseDisplay.label(phase.phase)), \(status.label)")
                    .background { acceptanceProbe("select.\(phase.phase)", text: status.label) }
                }
            }
            .padding(AppTheme.Spacing.sm)
        }
    }

    private func selectPhase(_ phase: String) {
        editor.revealReviewSurface(for: phase)
    }

    @ViewBuilder
    private func phaseDock(_ data: ProjectStateData) -> some View {
        let hasDecision = hasHostDecision
        let selected = hasDecision ? data.nextPhaseName : (editor.productionSelectedPhase ?? data.nextPhaseName)
        let phase = data.phases.first { $0.phase == selected }
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let phase {
                let isCurrent = phase.phase == data.nextPhaseName
                let isRunning = runningPhase == phase.phase || editor.agentService.currentTaskPhase == phase.phase
                    || activeGenerationPhase == phase.phase
                let status = PipelinePhasePresentation.resolve(phase: phase, isCurrent: isCurrent,
                    isRunning: isRunning, ready: isCurrent && approvalReadiness.isReady)
                Label("\(PhaseDisplay.label(phase.phase)) · \(status.label)", systemImage: status.symbol)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                    .background { acceptanceProbe("dock.status", text: status.label) }
                if hasDecision {
                    AgentPanelView(presentation: .decision)
                } else if let recovery = data.confirmedIdentityRecovery {
                    ScrollView { confirmedIdentityRecoveryCard(recovery) }
                        .frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
                } else if activeGenerationPhase == phase.phase, let batchID = editor.generationBatchCoordinator.activeBatchID {
                    GenerationBatchProgressView(editor: editor, batchID: batchID)
                } else if isCurrent, let run = editor.agentService.currentSpendRun {
                    Label("\(run.actionLabel) · \(run.modelName)", systemImage: "sparkles")
                        .interfaceFont(size: AppTheme.Typography.ui)
                    Text("The result will appear here for review.")
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                } else if isCurrent {
                    Text(nextActionDescription(for: phase.phase))
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .background { acceptanceProbe("dock.reason", text: nextActionDescription(for: phase.phase)) }
                    if !workIsRunning {
                        if approvalReadiness.isReady {
                            approveButton(phase, enabled: approvalIsEnabled(for: phase.phase, isNext: true, runningPhase: runningPhase))
                        } else {
                            Button("Continue \(PhaseDisplay.label(phase.phase))") {
                                continuePhase(phase.phase)
                            }
                            .buttonStyle(.inlineAction(.pack))
                            .disabled(gateWriting || !mutationReadiness.isReady)
                            .background { acceptanceProbe("dock.continue", enabled: !gateWriting && mutationReadiness.isReady) }
                        }
                    }
                    if !approvalReadiness.isReady, let diagnostic = approvalReadiness.blocker,
                       approvalPhase == phase.phase, !workIsRunning {
                        Button("Diagnostics") { showsReadinessDiagnostics = true }
                            .buttonStyle(.inlineAction(.neutral))
                            .background { acceptanceProbe("dock.diagnostics", enabled: true) }
                            .popover(isPresented: $showsReadinessDiagnostics) {
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                                    Text("\(PhaseDisplay.label(phase.phase)) diagnostics")
                                        .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                                    ScrollView {
                                        Text(diagnostic)
                                            .interfaceFont(size: AppTheme.Typography.metadata, design: .monospaced)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background { acceptanceProbe("dock.diagnostic-text", text: diagnostic) }
                                    }
                                    Button("Done") { showsReadinessDiagnostics = false }
                                        .buttonStyle(.inlineAction(.neutral))
                                        .background { acceptanceProbe("dock.diagnostics-done", enabled: true) }
                                }
                                .padding(AppTheme.Spacing.md)
                                .frame(width: AppTheme.Layout.activityFlyoutWidth, height: AppTheme.Layout.activityFlyoutHeight)
                            }
                    }
                } else if phase.approved {
                    Text("Revising this phase resets its approval and all following approvals.")
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Button("Revise \(PhaseDisplay.label(phase.phase))…") {
                        guard let home = editor.workingRoot,
                              let index = data.phases.firstIndex(where: { $0.phase == phase.phase }) else { return }
                        pendingRewind = RewindRequest(home: home, revision: editor.engineStateRevision,
                            phase: phase.phase, affected: data.phases[index...].map(\.phase))
                    }
                    .buttonStyle(.inlineAction(.neutral))
                    .disabled(gateWriting || workIsRunning || !mutationReadiness.isReady)
                } else if let current = data.nextPhaseName {
                    Text("Complete \(PhaseDisplay.label(current)) before starting this phase.")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    if PipelineSurfaceRouting.route(for: current, contract: editor.uiContract,
                        availablePackSurfaces: editor.availableCockpitPackSurfaces) != nil {
                        Button("Go to \(PhaseDisplay.label(current))") { selectPhase(current) }
                            .buttonStyle(.inlineAction(.neutral))
                    }
                }
            }
            if phase == nil {
                if hasDecision { AgentPanelView(presentation: .decision) }
                else if let recovery = data.confirmedIdentityRecovery {
                    ScrollView { confirmedIdentityRecoveryCard(recovery) }
                        .frame(maxHeight: AppTheme.ComponentSize.agentDecisionMaxHeight)
                } else {
                    Text(data.isComplete ? "All phases are approved." : "Select a phase to review its result.")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            if let gateError { gateErrorBanner(gateError) }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.raisedColor)
    }

    private func continuePhase(_ phase: String) {
        editor.continueProductionPhase(phase, diagnostic: approvalReadiness.blocker)
    }

    @ViewBuilder
    private func loadedBody(_ data: ProjectStateData) -> some View {
        let activeRunningPhase = runningPhase
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                summaryHeader(data)
                if let gateError {
                    gateErrorBanner(gateError)
                }
                if let recovery = data.confirmedIdentityRecovery {
                    confirmedIdentityRecoveryCard(recovery)
                }
                if data.phases.isEmpty {
                    CockpitStateView.empty(icon: "list.bullet.rectangle", title: "No phases",
                                           message: "This project has no defined phases.")
                } else {
                    VStack(spacing: AppTheme.Spacing.none) {
                        ForEach(Array(data.phases.enumerated()), id: \.element.id) { index, phase in
                            phaseRow(phase, isNext: phase.phase == data.nextPhaseName,
                                     isLast: index == data.phases.count - 1,
                                     runningPhase: activeRunningPhase)
                        }
                    }
                    .padding(AppTheme.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .fill(AppTheme.Background.raisedColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                    )
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryHeader(_ data: ProjectStateData) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(data.isComplete ? "All phases complete" : "\(data.currentApprovalCount) of \(data.phases.count) approvals current")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            if let runningPhase {
                Text("Running: \(PhaseDisplay.label(runningPhase)). Approval and rewind are unavailable until it finishes.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            } else if let next = data.nextPhaseName {
                Text("Current step: \(PhaseDisplay.label(next))")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                Text(nextActionDescription(for: next))
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProgressView(value: data.progress)
                .tint(AppTheme.Status.successColor)
                .accessibilityLabel("Current phase approvals")
                .accessibilityValue("\(data.currentApprovalCount) of \(data.phases.count)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func confirmedIdentityRecoveryCard(
        _ recovery: ConfirmedIdentityRecoveryData
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Label(
                "Recover identity references",
                systemImage: "exclamationmark.triangle.fill"
            )
            .interfaceFont(
                size: AppTheme.Typography.ui,
                weight: AppTheme.FontWeight.semibold
            )
            .foregroundStyle(AppTheme.Status.warningColor)
            Text(
                "Legacy staging records changed upstream lineage. Recovery separates valid exact-hash proofs from confirmed intake and audits rejected references."
            )
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                ForEach(recovery.affectedTargets, id: \.self) { path in
                    Text(path)
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .monospaced()
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .textSelection(.enabled)
                }
            }
            if !recovery.discardedTargets.isEmpty {
                Text("Altered or unsupported proofs to discard")
                    .interfaceFont(
                        size: AppTheme.Typography.metadata,
                        weight: AppTheme.FontWeight.semibold
                    )
                    .foregroundStyle(AppTheme.Status.warningColor)
                ForEach(recovery.discardedTargets, id: \.self) { path in
                    Text(path)
                        .interfaceFont(size: AppTheme.Typography.metadata)
                        .monospaced()
                        .foregroundStyle(AppTheme.Status.warningColor)
                        .textSelection(.enabled)
                }
            }
            if let blocker = recovery.blocker {
                Text(blocker)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Recover provenance") {
                apply(
                    failureMessage: "Couldn't recover identity-reference provenance."
                ) { project in
                    _ = try await ConfirmedIdentityProvenanceRecovery.recover(
                        editor: editor,
                        projectDir: project
                    )
                }
            }
            .buttonStyle(.inlineAction(.approval))
            .disabled(
                !recovery.eligible || gateWriting || workIsRunning
            )
            .help(
                recovery.eligible
                    ? "Separate legacy staging proofs without changing gate states"
                    : "Resolve the reported blocker before recovery"
            )
            Text(
                "Recovery does not reapprove phases. Real upstream edits still require Rewind."
            )
            .interfaceFont(size: AppTheme.Typography.metadata)
            .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(
                    AppTheme.Status.warningColor.opacity(
                        AppTheme.Opacity.faint
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(
                    AppTheme.Status.warningColor.opacity(
                        AppTheme.Opacity.muted
                    ),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
    }

    private func nextActionDescription(for phase: String) -> String {
        if gateWriting { return "Saving the phase decision…" }
        if runningPhase == phase { return "AI is working on \(PhaseDisplay.label(phase)). The result will appear here for review." }
        if let failure = editor.agentService.currentPipelineRepairFailure {
            return failure.kind == .unrequestedRevision
                ? "Revision paused. The agent asked to revise approved work without new direction. Continue in the decision below."
                : "Planning paused after repeated attempts without progress. Retry in the decision below."
        }
        if let dialog = editor.agentService.pendingDialog {
            return "Complete ‘\(dialog.title)’ in the decision below."
        }
        if editor.agentService.pendingSpendApproval != nil { return "Choose whether to generate the requested result." }
        if editor.generationBatchCoordinator.pending != nil { return "Choose whether to generate the requested results." }
        if editor.agentService.pendingGateApproval != nil { return "Review the phase decision below." }
        if editor.agentService.isComposerBlocked { return "Your input is needed in the decision below." }
        if editor.agentService.currentTaskPhase == phase { return "AI is working on \(PhaseDisplay.label(phase)). The result will appear here for review." }
        if approvalPhase != phase { return "Checking phase readiness…" }
        if !mutationReadiness.isReady { return "Phase controls are unavailable. Resolve the project or workflow error before continuing." }
        if approvalReadiness.isReady { return "Review this phase’s artifact, then approve it to continue." }
        return approvalReadiness.userMessage
            ?? "This phase is incomplete. Continue the phase before approval."
    }

    private func approvalIsEnabled(for phase: String, isNext: Bool, runningPhase: String?) -> Bool {
        PipelineApprovalControl.isEnabled(
            approvalReady: isNext && approvalPhase == phase && approvalReadiness.isReady,
            controlsAvailable: mutationReadiness.isReady,
            gateWriting: gateWriting,
            pipelineIsRunning: workIsRunning,
            hostDecisionPending: editor.agentService.isComposerBlocked

        )
    }

    @ViewBuilder
    private func phaseRow(
        _ phase: ProjectPhase,
        isNext: Bool,
        isLast: Bool,
        runningPhase: String?
    ) -> some View {
        let isRunning = runningPhase == phase.phase
        let pipelineIsRunning = workIsRunning
        let hostDecisionPending = editor.agentService.isComposerBlocked
        let readiness = isNext && approvalPhase == phase.phase
            ? approvalReadiness
            : .blocked("This phase is not current.")
        let approvalEnabled = approvalIsEnabled(for: phase.phase, isNext: isNext, runningPhase: runningPhase)
        let actionHeight = (AppTheme.Control.compactHeight + AppTheme.Spacing.xs) * interfaceScale
        let actions = Group {
            surfaceIcon(for: phase.phase)
                .frame(minWidth: AppTheme.ComponentSize.pipelineSurfaceMinWidth * interfaceScale,
                       minHeight: actionHeight, alignment: .leading)
            Group {
                if isNext && !isRunning {
                    approveButton(phase, enabled: approvalEnabled)
                } else {
                    AppTheme.Background.clearColor
                        .frame(height: AppTheme.Control.compactHeight * interfaceScale)
                }
            }
            .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
            .frame(minWidth: AppTheme.ComponentSize.pipelineApprovalMinWidth * interfaceScale,
                   minHeight: actionHeight)
            phaseStatus(phase, isCurrent: isNext, isRunning: isRunning || (editor.agentService.currentTaskPhase == phase.phase), awaitingApproval: isNext && readiness.isReady)
                .frame(width: AppTheme.Control.iconTarget * interfaceScale)
                .frame(minHeight: actionHeight)
            gateMenu(
                phase,
                isNext: isNext,
                canApprove: approvalEnabled,
                controlsAvailable: mutationReadiness.isReady && !hostDecisionPending,
                pipelineIsRunning: pipelineIsRunning
            )
            .frame(width: AppTheme.IconSize.md)
            .frame(minHeight: actionHeight)
        }
        VStack(spacing: AppTheme.Spacing.none) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    phaseIdentity(phase, isNext: isNext)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: AppTheme.Spacing.sm) { actions }
                        .fixedSize(horizontal: true, vertical: true)
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    phaseIdentity(phase, isNext: isNext)
                    WrapLayout(spacing: AppTheme.Spacing.sm) { actions }
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .frame(minHeight: AppTheme.ComponentSize.pipelineRowMinHeight)
            .background { acceptanceProbe("row.\(phase.phase)") }
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isNext
                          ? editor.projectPalette.accent.opacity(AppTheme.Opacity.subtle)
                          : AppTheme.Background.clearColor)
            )
            if !isLast {
                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: AppTheme.BorderWidth.hairline)
                    .padding(.horizontal, AppTheme.Spacing.sm)
            }
        }
    }

    private func phaseIdentity(_ phase: ProjectPhase, isNext: Bool) -> some View {
        Text(PhaseDisplay.label(phase.phase))
            .interfaceFont(size: AppTheme.Typography.ui,
                           weight: isNext ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium)
            .foregroundStyle(isNext ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .background { acceptanceProbe("phase.\(phase.phase)", text: PhaseDisplay.label(phase.phase)) }
    }

    @ViewBuilder
    private func acceptanceProbe(_ part: String, enabled: Bool? = nil, text: String? = nil) -> some View {
        if WorkspaceUIAcceptance.isRequested || MusicvideoHostFlowAcceptance.isRequested {
            AppRelaunchClickProbe(identifier: "pipeline.overview.\(part)",
                acceptanceState: enabled, acceptanceText: text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }

    /// Approving a phase is the one action the pipeline cannot advance without — it belongs in the row,
    /// not behind an unlabeled “…”. The menu keeps the rarer siblings (send back, rewind).
    private func approveButton(
        _ phase: ProjectPhase,
        enabled: Bool
    ) -> some View {
        Button {
            apply(
                failureMessage: "\(PhaseDisplay.label(phase.phase)) isn't ready for approval yet."
            ) {
                try await NativeGateWriter.approve(
                    projectDir: $0,
                    phase: phase.phase,
                    declaredPack: editor.declaredPluginName,
                    declaredBinding: editor.declaredPluginBinding,
                        declaredProductionContract: editor.declaredProductionContract,
                    editor: editor, executionCoordinator: editor.pipelinePhaseRunCoordinator
                )
            }
        } label: {
            Text("Approve")
                .fixedSize(horizontal: false, vertical: true)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .frame(minHeight: AppTheme.IconSize.smMd)
        }
        .buttonStyle(.inlineAction(.approval))
        .disabled(!enabled)
        .background { acceptanceProbe("approve.\(phase.phase)", enabled: enabled) }
        .help(
            enabled
                ? "Approve \(PhaseDisplay.label(phase.phase)) and move to the next phase"
                : "Complete \(PhaseDisplay.label(phase.phase)) before approving"
        )
    }

    /// Direct gate controls (docs/UI_UX_CONCEPT.md §4) — approve / send back / rewind, wired to the
    /// in-process engine (NativeGateWriter), no agent round-trip. State-aware so the actions match where
    /// the phase sits: a FUTURE phase (not reached) offers nothing; the ACTIVE (next) phase can be
    /// approved; a COMPLETED phase can be sent back or rewound to. A future phase can't be approved
    /// out of order or "rewound to" — that would be meaningless.
    @ViewBuilder
    private func gateMenu(
        _ phase: ProjectPhase,
        isNext: Bool,
        canApprove: Bool,
        controlsAvailable: Bool,
        pipelineIsRunning: Bool
    ) -> some View {
        // The first not-yet-approved phase is the frontier: everything before it is done, it is active,
        // everything after is in the future.
        let isFuture = !phase.approved && !isNext
        Menu {
            // Only the active (next) phase is approvable — no approving out of order.
            Button("Approve") {
                apply(
                    failureMessage: "\(PhaseDisplay.label(phase.phase)) isn't ready for approval yet."
                ) {
                    try await NativeGateWriter.approve(
                        projectDir: $0,
                        phase: phase.phase,
                        declaredPack: editor.declaredPluginName,
                        declaredBinding: editor.declaredPluginBinding,
                        declaredProductionContract: editor.declaredProductionContract,
                        editor: editor, executionCoordinator: editor.pipelinePhaseRunCoordinator
                    )
                }
            }
            .disabled(!isNext || !canApprove || pipelineIsRunning)
            // Only a completed phase can be sent back for revision.
            Button("Needs revision") {
                apply(
                    failureMessage: "Couldn't update \(PhaseDisplay.label(phase.phase)). Try again."
                ) {
                    try await NativeGateWriter.setState(
                        projectDir: $0,
                        phase: phase.phase,
                        state: .needsRevision,
                        declaredPack: editor.declaredPluginName,
                        declaredBinding: editor.declaredPluginBinding,
                        declaredProductionContract: editor.declaredProductionContract,
                        editor: editor, executionCoordinator: editor.pipelinePhaseRunCoordinator
                    )
                }
            }
            .disabled(!phase.approved || !controlsAvailable)
            Divider() // app-theme: native-menu-divider
            // Rewind to a phase already reached (active or completed) — never to the future.
            Button("Rewind to here…", role: .destructive) {
                guard let home = editor.workingRoot, case .loaded(.some(let data)) = state,
                      let index = data.phases.firstIndex(where: { $0.phase == phase.phase }) else { return }
                pendingRewind = RewindRequest(home: home, revision: editor.engineStateRevision,
                    phase: phase.phase, affected: data.phases[index...].map(\.phase))
            }
            .disabled(isFuture || !controlsAvailable)
        } label: {
            Image(systemName: "ellipsis.circle")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .accessibilityLabel("Actions for \(PhaseDisplay.label(phase.phase))")
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // A borderless Menu overrides its label's foreground style with the control tint.
        .tint(AppTheme.Text.mutedColor)
        .fixedSize()
        .disabled(
            gateWriting || isFuture || pipelineIsRunning || !controlsAvailable
        )
        .help(
            pipelineIsRunning
                ? "A pipeline phase is still running"
                : (!controlsAvailable
                    ? "Pipeline gate controls are unavailable"
                    : (isFuture
                        ? "Not reached yet — approve earlier phases first"
                        : "Gate: approve, send back for revision, or rewind the pipeline to this phase"))
        )
    }

    /// Run a gate mutation against the project dir, then reload this panel and the shared engine state.
    private func apply(
        failureMessage: String,
        _ write: @escaping @MainActor (URL) async throws -> Void
    ) {
        guard !gateWriting else { return }
        guard let mutationID = editor.agentService.beginNativeGateMutation() else {
            gateError = GateErrorState(
                message: "Resolve the open decision first.",
                diagnostic: "A host-owned decision already controls the Agent composer."
            )
            return
        }
        guard let dir = editor.workingRoot else {
            editor.agentService.endNativeGateMutation(mutationID)
            gateError = GateErrorState(
                message: "No project is open.",
                diagnostic: "No open project to update."
            )
            return
        }
        gateWriting = true
        Task { @MainActor in
            defer {
                editor.agentService.endNativeGateMutation(mutationID)
                gateWriting = false
            }
            do {
                try await write(dir)
                gateError = nil
                if editor.workingRoot == dir {
                    editor.onPipelineChanged?()
                }
            } catch {
                gateError = GateErrorState(
                    message: failureMessage,
                    diagnostic: error.localizedDescription
                )
            }
            await editor.refreshEngineState()
            if editor.workingRoot == dir {
                await load(showProgress: false)
            }
        }
    }

    /// Dismissible user-safe feedback for the rare race where a ready control becomes blocked on click.
    private func gateErrorBanner(_ error: GateErrorState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.errorColor)
            Text(error.message)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button {
                editor.agentService.send(
                    text: "Resolve this pipeline gate failure before requesting approval again: \(error.diagnostic)",
                    mentions: [], hidden: true)
                gateError = nil
            } label: {
                Text("Ask the agent")
            }
            .buttonStyle(.inlineAction(.pack))
            .help("Hand this refusal to the agent so it can resolve it")
            Button { gateError = nil } label: {
                Image(systemName: "xmark")
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(ToolbarIconButtonStyle())
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
        .padding(AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Status.errorColor.opacity(AppTheme.Opacity.faint))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Status.errorColor.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    @ViewBuilder
    /// The route to a phase's artifact. It carries a visible LABEL, not just an icon: this is the only
    /// way to read what a gate is about to approve, and a bare glyph made it unfindable in the field.
    /// A tooltip doesn't fix that — it appears on hover, so you must already suspect the control exists.
    private func surfaceIcon(for phase: String) -> some View {
        if let route = PipelineSurfaceRouting.route(
            for: phase,
            contract: editor.uiContract,
            availablePackSurfaces: editor.availableCockpitPackSurfaces
        ) {
            let isEnabled = true
            Button {
                editor.revealReviewSurface(for: phase)
            } label: {
                ActionLabel(title: route.destinationLabel, systemImage: route.icon,
                    acceptanceTextIdentifier: "pipeline.overview.surfaceText.\(phase)")
                    .background {
                        acceptanceProbe("surface.\(phase)", enabled: isEnabled, text: route.destinationLabel)
                    }
            }
            .buttonStyle(.inlineAction(.neutral))
            .disabled(!isEnabled)
            .help(isEnabled
                  ? "Open \(route.destinationLabel)"
                  : "Tasks are available for the current step")
        }
    }

    private func phaseStatus(_ phase: ProjectPhase, isCurrent: Bool, isRunning: Bool, awaitingApproval: Bool) -> some View {
        let status = PipelinePhasePresentation.resolve(phase: phase, isCurrent: isCurrent,
            isRunning: isRunning, ready: awaitingApproval)
        let label = status.label
        let symbol = status.symbol
        let color = isRunning ? editor.projectPalette.accent
            : phase.approvalCurrent ? AppTheme.Status.successColor
            : phase.approved ? AppTheme.Status.warningColor
            : phase.state == "needs_revision" ? AppTheme.Status.errorColor : AppTheme.Text.mutedColor
        let help = phase.approved && !phase.approvalCurrent
            ? "Approval outdated. Recover reported identity provenance or rewind to this phase."
            : phase.notes.map { "\(label): \($0)" } ?? label
        return Image(systemName: symbol)
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(color)
            .accessibilityLabel(label)
            .help(help)
    }

    private func centeredProgress() -> some View {
        VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshApprovalReadiness() {
        readinessToken += 1
        guard case .loaded(let data) = state,
              let data,
              editor.workingRoot != nil
        else {
            approvalPhase = nil
            approvalReadiness = .blocked("The pipeline state is unavailable.")
            mutationReadiness = .blocked("The pipeline state is unavailable.")
            return
        }
        let phase = data.nextPhaseName
        approvalPhase = phase
        approvalReadiness = .blocked("Checking approval readiness.")
        mutationReadiness = .blocked("Checking gate controls.")
        readinessRefreshQueued = true
        guard readinessTask == nil else { return }
        readinessTask = Task { @MainActor in
            repeat {
                readinessRefreshQueued = false
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { break }
                let token = readinessToken
                let currentPhase = approvalPhase
                guard let currentDir = editor.workingRoot else { break }
                let readiness = await NativeGateWriter.controlReadiness(
                    projectDir: currentDir,
                    phase: currentPhase,
                    declaredPack: editor.declaredPluginName,
                    declaredBinding: editor.declaredPluginBinding,
                        declaredProductionContract: editor.declaredProductionContract,
                    editor: editor, executionCoordinator: editor.pipelinePhaseRunCoordinator
                )
                guard token == readinessToken,
                      approvalPhase == currentPhase,
                      editor.workingRoot == currentDir
                else { continue }
                mutationReadiness = readiness.mutations
                approvalReadiness = readiness.approval
            } while readinessRefreshQueued
            readinessTask = nil
        }
    }

    private func load(showProgress: Bool = true) async {
        if ProcessInfo.processInfo.environment["NGV_DIAGNOSTIC_REPLAY"] != nil {
            dataRoot = nil
            state = .loaded(editor.projectState)
            return
        }
        guard let dir = editor.workingRoot else {
            dataRoot = nil
            state = .failed(.noProject)
            return
        }
        dataRoot = DataRootResolver.dataRoot(of: dir)
        loadToken += 1
        let token = loadToken
        if showProgress {
            state = .loading
        }
        let declaration = ProjectPackGate.MutationDeclaration(packName: editor.declaredPluginName,
            binding: editor.declaredPluginBinding, productionContract: editor.declaredProductionContract)
        let result = await CockpitDataService.projectState(projectDir: dir, declaration: declaration)
        guard token == loadToken else { return }
        switch result {
        case .success(let data):
            state = .loaded(data)
            if presentation == .sidebar, editor.productionSelectedPhase == nil, let phase = data?.nextPhaseName {
                selectPhase(phase)
            }
            refreshApprovalReadiness()
        case .failure(let error):
            approvalPhase = nil
            approvalReadiness = .blocked("The pipeline state is unavailable.")
            mutationReadiness = .blocked("The pipeline state is unavailable.")
            state = .failed(error)
        }
    }
}
