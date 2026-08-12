import SwiftUI
import NexGenEngine

enum PipelineApprovalControl {
    static func isEnabled(
        approvalReady: Bool,
        controlsAvailable: Bool,
        gateWriting: Bool,
        pipelineIsRunning: Bool
    ) -> Bool {
        approvalReady
            && controlsAvailable
            && !gateWriting
            && !pipelineIsRunning
    }
}

enum PipelineSurfaceRouting {
    enum Destination: Equatable {
        case tab(CockpitTab)
        case pack(String)
        case chat
    }

    struct Route: Equatable {
        let icon: String
        let label: String
        let taskClass: String
        let destination: Destination
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
                label: surface.title,
                taskClass: entry.taskClass,
                destination: .pack(surface.id)
            )
        }
        return switch entry.surface {
        case "review": Route(icon: "eye", label: "Review", taskClass: entry.taskClass, destination: .tab(.review))
        case "prose": Route(icon: "text.cursor", label: "Story", taskClass: entry.taskClass, destination: .tab(.story))
        case "choice": Route(icon: "slider.horizontal.3", label: "In chat", taskClass: entry.taskClass, destination: .chat)
        default: Route(icon: "questionmark", label: entry.surface, taskClass: entry.taskClass, destination: .chat)
        }
    }
}

// Pipeline cockpit panel: the project's phase gates as a vertical checklist, with the next open phase
// highlighted and gate mutations routed through NativeGateWriter.

struct PipelinePanelView: View {
    @Environment(EditorViewModel.self) private var editor

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

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: editor.projectURL) { await load() }
        // Re-read when the engine state changes (e.g. production just started) — projectURL is unchanged
        // then, so without this the panel would keep showing the stale "Start production" state.
        .onChange(of: editor.engineStateRevision) { _, _ in
            Task { await load(showProgress: false) }
        }
        .onChange(of: editor.projectURL) { _, _ in
            gateError = nil
        }
        .onChange(of: runningPhase) { _, _ in
            refreshApprovalReadiness()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            centeredProgress()
        case .failed(let error):
            CockpitStateView.error(error, title: "Couldn't load the pipeline",
                                   subject: "the pipeline",
                                   activePack: InstalledPack.named(editor.activePluginName),
                                   startProduction: { editor.startProduction() },
                                   isStarting: editor.productionStarted) { Task { await load() } }
        case .loaded(nil):
            CockpitStateView.empty(icon: "list.bullet.rectangle", title: "No pipeline yet",
                                   message: "This project has no phase state.")
        case .loaded(.some(let data)):
            loadedBody(data)
        }
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
                    .padding(AppTheme.Spacing.mdLg)
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
                if data.budgetEur > 0 || data.budgetSpentEur > 0 {
                    budgetCard(data)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Budget (merged Cost panel — same snapshot, one pipeline-health surface)

    private func budgetCard(_ data: ProjectStateData) -> some View {
        let warn = data.budgetWarning
        let barColor = warn ? AppTheme.Status.errorColor : AppTheme.Status.successColor
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("BUDGET")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Spacer(minLength: 0)
                if warn {
                    Label(data.budgetRemainingEur <= 0 ? "Over budget" : "Low budget",
                          systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }

            budgetBar(fraction: data.spentFraction, color: barColor)

            if let next = data.nextPhaseName {
                Text("Next up: \(PhaseDisplay.label(next)) — \(String(format: "€%.2f", data.budgetRemainingEur)) available")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            VStack(spacing: AppTheme.Spacing.smMd) {
                amountRow(label: "Budget", amount: data.budgetEur, color: AppTheme.Text.secondaryColor)
                amountRow(label: "Spent", amount: data.budgetSpentEur, color: AppTheme.Text.secondaryColor)
                AppDivider()
                amountRow(label: "Remaining", amount: data.budgetRemainingEur,
                          color: warn ? AppTheme.Status.errorColor : AppTheme.Text.primaryColor,
                          emphasized: true)
            }
        }
        .padding(AppTheme.Spacing.mdLg)
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

    private func budgetBar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint))
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: AppTheme.Spacing.smMd)
    }

    private func amountRow(label: String, amount: Double, color: Color, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm,
                              weight: emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
            Spacer()
            Text(String(format: "€%.2f", amount))
                .font(.system(size: emphasized ? AppTheme.FontSize.md : AppTheme.FontSize.sm,
                              weight: emphasized ? .semibold : .medium).monospacedDigit())
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    private func summaryHeader(_ data: ProjectStateData) -> some View {
        // Just the progress count — the next phase is already marked with a NEXT badge on its row below,
        // so a separate "Next: …" line here is redundant.
        Text(data.isComplete ? "All phases complete" : "\(data.phases.filter(\.approved).count) of \(data.phases.count) phases approved")
            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func phaseRow(
        _ phase: ProjectPhase,
        isNext: Bool,
        isLast: Bool,
        runningPhase: String?
    ) -> some View {
        let isRunning = runningPhase == phase.phase
        let pipelineIsRunning = runningPhase != nil
        let readiness = isNext && approvalPhase == phase.phase
            ? approvalReadiness
            : .blocked("This phase is not current.")
        let approvalEnabled = PipelineApprovalControl.isEnabled(
            approvalReady: readiness.isReady,
            controlsAvailable: mutationReadiness.isReady,
            gateWriting: gateWriting,
            pipelineIsRunning: pipelineIsRunning
        )
        VStack(spacing: AppTheme.Spacing.none) {
            HStack(spacing: AppTheme.Spacing.smMd) {
                statusDot(approved: phase.approved, isNext: isNext, state: phase.state)
                Text(PhaseDisplay.label(phase.phase))
                    .font(.system(size: AppTheme.FontSize.sm,
                                  weight: isNext ? .semibold : (phase.approved ? .regular : .medium)))
                    .foregroundStyle(phase.approved ? AppTheme.Text.tertiaryColor
                                     : (isNext ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if phase.state == "needs_revision" {
                    Text("NEEDS REVISION")
                        .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.bold))
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(AppTheme.Status.errorColor)
                        .help(phase.notes ?? "Sent back for revision")
                } else if phase.state == "approved_with_notes" {
                    Image(systemName: "text.bubble")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Status.successColor)
                        .help(phase.notes ?? "Approved with notes")
                }
                surfaceIcon(for: phase.phase)
                if isRunning {
                    Text("Running")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Accent.timecodeColor)
                } else if isNext {
                    approveButton(
                        phase,
                        enabled: approvalEnabled
                    )
                } else if phase.approved {
                    Text("Approved")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Status.successColor)
                }
                gateMenu(
                    phase,
                    isNext: isNext,
                    canApprove: approvalEnabled,
                    controlsAvailable: mutationReadiness.isReady,
                    pipelineIsRunning: pipelineIsRunning
                )
            }
            .frame(height: AppTheme.IconSize.md)
            if !isLast {
                AppDivider()
            }
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
                    executionCoordinator: editor.pipelinePhaseRunCoordinator
                )
            }
        } label: {
            Text("Approve")
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(
                    enabled ? AppTheme.Accent.timecodeColor : AppTheme.Text.mutedColor
                )
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(
                            enabled
                                ? AppTheme.Accent.timecodeColor.opacity(AppTheme.Opacity.faint)
                                : AppTheme.Background.raisedColor
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
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
                        executionCoordinator: editor.pipelinePhaseRunCoordinator
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
                        executionCoordinator: editor.pipelinePhaseRunCoordinator
                    )
                }
            }
            .disabled(!phase.approved || !controlsAvailable)
            Divider() // app-theme: native-menu-divider
            // Rewind to a phase already reached (active or completed) — never to the future.
            Button("Rewind to here", role: .destructive) {
                apply(failureMessage: "Couldn't rewind the pipeline. Try again.") {
                    try NativeGateWriter.rewind(
                        projectDir: $0,
                        targetPhase: phase.phase,
                        declaredPack: editor.declaredPluginName,
                        executionCoordinator: editor.pipelinePhaseRunCoordinator
                    )
                }
            }
            .disabled(isFuture || !controlsAvailable)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
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
        guard let dir = editor.workingRoot else {
            gateError = GateErrorState(
                message: "No project is open.",
                diagnostic: "No open project to update."
            )
            return
        }
        gateWriting = true
        Task { @MainActor in
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
            gateWriting = false
        }
    }

    /// Dismissible user-safe feedback for the rare race where a ready control becomes blocked on click.
    private func gateErrorBanner(_ error: GateErrorState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.errorColor)
            Text(error.message)
                .font(.system(size: AppTheme.FontSize.xs))
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
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Accent.timecodeColor)
            }
            .buttonStyle(.plain)
            .help("Hand this refusal to the agent so it can resolve it")
            Button { gateError = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .buttonStyle(.plain)
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

    /// Contract-driven routing (docs/UI_UX_CONCEPT.md §7): the phase's declared surface, clickable —
    /// review phases open Review, prose phases open Story.
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
            let isPackRoute = switch route.destination {
            case .pack: true
            default: false
            }
            let isEnabled = route.destination != .chat
            Button {
                switch route.destination {
                case .tab(let target):
                    editor.cockpitTab = target
                    editor.cockpitPackSurfaceID = nil
                case .pack(let id):
                    editor.cockpitPackSurfaceID = id
                case .chat:
                    break
                }
            } label: {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Image(systemName: route.icon)
                    Text(route.label)
                }
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(
                    isPackRoute ? AppTheme.Accent.pack
                        : (isEnabled ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                )
                .padding(.horizontal, isPackRoute ? AppTheme.Spacing.xs : AppTheme.Spacing.none)
                .padding(.vertical, isPackRoute ? AppTheme.Spacing.xxs : AppTheme.Spacing.none)
                .background(
                    isPackRoute
                        ? AppTheme.Accent.pack.opacity(AppTheme.Opacity.faint)
                        : AppTheme.Background.clearColor
                )
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(isEnabled
                  ? "Open \(route.label) to read this phase's work · compute: \(route.taskClass)"
                  : "Answered in the chat · compute: \(route.taskClass)")
        }
    }

    private func statusDot(approved: Bool, isNext: Bool, state: String = "pending") -> some View {
        Group {
            if approved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Status.successColor)
            } else if state == "needs_revision" {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(AppTheme.Status.errorColor)
            } else if isNext {
                Image(systemName: "circle.dashed.inset.filled")
                    .foregroundStyle(AppTheme.Accent.timecodeColor)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .font(.system(size: AppTheme.FontSize.md))
        .frame(width: AppTheme.IconSize.xs)
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
                    executionCoordinator: editor.pipelinePhaseRunCoordinator
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
        let result = await CockpitDataService.projectState(projectDir: dir)
        guard token == loadToken else { return }
        switch result {
        case .success(let data):
            state = .loaded(data)
            refreshApprovalReadiness()
        case .failure(let error):
            approvalPhase = nil
            approvalReadiness = .blocked("The pipeline state is unavailable.")
            mutationReadiness = .blocked("The pipeline state is unavailable.")
            state = .failed(error)
        }
    }
}
