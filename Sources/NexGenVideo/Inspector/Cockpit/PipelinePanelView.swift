import SwiftUI
import NexGenEngine

// Read-only Pipeline cockpit panel: the project's phase gates as a vertical checklist, with the next
// open phase highlighted — "where does the project stand". Loaded via CockpitDataService.projectState.
// Explicit loading / empty / error / engine-not-ready states. No mutations.

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

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: editor.projectURL) { await load() }
        // Re-read when the engine state changes (e.g. production just started) — projectURL is unchanged
        // then, so without this the panel would keep showing the stale "Start production" state.
        .onChange(of: editor.engineStateRevision) { _, _ in Task { await load() } }
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
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                summaryHeader(data)
                if data.phases.isEmpty {
                    CockpitStateView.empty(icon: "list.bullet.rectangle", title: "No phases",
                                           message: "This project has no defined phases.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(data.phases.enumerated()), id: \.element.id) { index, phase in
                            phaseRow(phase, isNext: phase.phase == data.nextPhaseName,
                                     isLast: index == data.phases.count - 1)
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
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Spacer(minLength: 0)
                if warn {
                    Label(data.budgetRemainingEur <= 0 ? "Over budget" : "Low budget",
                          systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
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
                Divider().overlay(AppTheme.Border.subtleColor)
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
                    .fill(Color.white.opacity(AppTheme.Opacity.faint))
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            let approved = data.phases.filter(\.approved).count
            Text(data.isComplete ? "All phases complete" : "\(approved) of \(data.phases.count) phases approved")
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if let next = data.nextPhaseName, !data.isComplete {
                Text("Next: \(PhaseDisplay.label(next))")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.timecodeColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phaseRow(_ phase: ProjectPhase, isNext: Bool, isLast: Bool) -> some View {
        VStack(spacing: 0) {
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
                        .font(.system(size: AppTheme.FontSize.micro, weight: .bold))
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
                if isNext {
                    Text("NEXT")
                        .font(.system(size: AppTheme.FontSize.micro, weight: .bold))
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(AppTheme.Accent.timecodeColor)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                .fill(AppTheme.Accent.timecodeColor.opacity(AppTheme.Opacity.faint))
                        )
                } else if phase.approved {
                    Text("Approved")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                        .foregroundStyle(AppTheme.Status.successColor)
                }
                gateMenu(phase, isNext: isNext)
            }
            .frame(height: AppTheme.IconSize.md)
            if !isLast {
                Divider().overlay(AppTheme.Border.subtleColor)
            }
        }
    }

    /// Direct gate controls (docs/UI_UX_CONCEPT.md §4) — approve / send back / rewind, wired to the
    /// in-process engine (NativeGateWriter), no agent round-trip. State-aware so the actions match where
    /// the phase sits: a FUTURE phase (not reached) offers nothing; the ACTIVE (next) phase can be
    /// approved; a COMPLETED phase can be sent back or rewound to. A future phase can't be approved
    /// out of order or "rewound to" — that would be meaningless.
    @ViewBuilder
    private func gateMenu(_ phase: ProjectPhase, isNext: Bool) -> some View {
        // The first not-yet-approved phase is the frontier: everything before it is done, it is active,
        // everything after is in the future.
        let isFuture = !phase.approved && !isNext
        Menu {
            // Only the active (next) phase is approvable — no approving out of order.
            Button("Approve") { apply { try NativeGateWriter.approve(projectDir: $0, phase: phase.phase) } }
                .disabled(!isNext)
            // Only a completed phase can be sent back for revision.
            Button("Needs revision") {
                apply { try NativeGateWriter.setState(projectDir: $0, phase: phase.phase, state: .needsRevision) }
            }
            .disabled(!phase.approved)
            Divider()
            // Rewind to a phase already reached (active or completed) — never to the future.
            Button("Rewind to here", role: .destructive) {
                apply { try NativeGateWriter.rewind(projectDir: $0, targetPhase: phase.phase) }
            }
            .disabled(isFuture)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(gateWriting || isFuture)
        .help(isFuture ? "Not reached yet — approve earlier phases first"
                       : "Gate: approve, send back for revision, or rewind the pipeline to this phase")
    }

    /// Run a gate mutation against the project dir, then reload both this panel and the shared engine
    /// snapshot (title-bar capsule + other panels) so every surface reflects the new gate state. The
    /// write is fast local YAML I/O — kept inline (the reloads are the async part).
    private func apply(_ write: (URL) throws -> Void) {
        guard let dir = editor.workingRoot, !gateWriting else { return }
        gateWriting = true
        do {
            try write(dir)
            // The gate write landed in the working copy — mark the document edited so a save persists it.
            editor.onPipelineChanged?()
        } catch {
            editor.mediaPanelToast = MediaPanelToast(message: "Gate update failed: \(error.localizedDescription)")
        }
        Task {
            await editor.refreshEngineState()
            await load()
            gateWriting = false
        }
    }

    /// Contract-driven routing (docs/UI_UX_CONCEPT.md §7): the phase's declared surface, clickable —
    /// review phases open Review, prose phases open Story.
    @ViewBuilder
    private func surfaceIcon(for phase: String) -> some View {
        if let entry = editor.uiContract?.phases[phase] {
            let (icon, target): (String, CockpitTab?) = switch entry.surface {
            case "review": ("eye", .review)
            case "prose": ("text.cursor", .story)
            case "choice": ("slider.horizontal.3", nil)
            default: ("questionmark", nil)
            }
            Button {
                if let target { editor.cockpitTab = target }
            } label: {
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .buttonStyle(.plain)
            .disabled(target == nil)
            .help("Surface: \(entry.surface) · compute: \(entry.taskClass)")
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

    private func load() async {
        guard let dir = editor.workingRoot else {
            state = .failed(.noProject)
            return
        }
        loadToken += 1
        let token = loadToken
        state = .loading
        let result = await CockpitDataService.projectState(projectDir: dir)
        guard token == loadToken else { return }
        switch result {
        case .success(let data): state = .loaded(data)
        case .failure(let error): state = .failed(error)
        }
    }
}
