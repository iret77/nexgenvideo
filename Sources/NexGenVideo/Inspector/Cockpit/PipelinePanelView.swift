import SwiftUI
import NexGenEngine

enum PipelineStoryArtifact: String, Equatable {
    case brief
    case treatment
}

enum PipelineReviewArtifact: String, Equatable {
    case frames
    case render
}

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
        case pack(String)
        case story(PipelineStoryArtifact)
        case review(PipelineReviewArtifact)
        case storyboard
        case productionDesign
        case sanity
        case interaction
    }

    struct Route: Equatable {
        let icon: String
        let label: String
        let taskClass: String
        let destination: Destination

        var legacyTab: CockpitTab? {
            switch destination {
            case .tab(let tab): tab
            case .story: .story
            case .review: .review
            default: nil
            }
        }

        var acceptanceID: String {
            switch destination {
            case .tab(let tab): tab.rawValue.lowercased()
            case .pack(let id): "pack.\(id)"
            case .story(let artifact): artifact.rawValue
            case .review(let artifact): artifact.rawValue
            case .storyboard: "storyboard"
            case .productionDesign: "production-design"
            case .sanity: "sanity"
            case .interaction: "agent"
            }
        }
    }

    static func route(
        for phase: String,
        contract: ContractData?,
        availablePackSurfaces: [CockpitSurfaceData]
    ) -> Route? {
        guard let entry = contract?.phases[phase],
              let selector = entry.artifactSelector else { return nil }
        if let surface = availablePackSurfaces.first(where: { $0.phase == phase }) {
            return Route(
                icon: surface.symbol,
                label: surface.title,
                taskClass: entry.taskClass,
                destination: .pack(surface.id)
            )
        }
        return route(forArtifactSelector: selector, taskClass: entry.taskClass)
    }

    private static func route(forArtifactSelector selector: String, taskClass: String) -> Route {
        switch selector {
        case "host.brief":
            Route(icon: "text.cursor", label: "Brief", taskClass: taskClass, destination: .story(.brief))
        case "host.treatment":
            Route(icon: "text.cursor", label: "Treatment", taskClass: taskClass, destination: .story(.treatment))
        case "host.production_design":
            Route(icon: "paintpalette", label: "Production Design", taskClass: taskClass, destination: .productionDesign)
        case "host.storyboard":
            Route(icon: "rectangle.stack", label: "Storyboard", taskClass: taskClass, destination: .storyboard)
        case "host.bible":
            Route(icon: "person.2", label: "Bible", taskClass: taskClass, destination: .tab(.bible))
        case "host.shotlist":
            Route(icon: "list.number", label: "Shot List", taskClass: taskClass, destination: .tab(.shotlist))
        case "host.sanity_report":
            Route(icon: "checklist", label: "Sanity", taskClass: taskClass, destination: .sanity)
        case "host.frames_manifest":
            Route(icon: "photo.on.rectangle.angled", label: "Frames", taskClass: taskClass, destination: .review(.frames))
        case "host.render_manifest":
            Route(icon: "play.rectangle", label: "Render", taskClass: taskClass, destination: .review(.render))
        default:
            Route(icon: "sparkles", label: "Agent", taskClass: taskClass, destination: .interaction)
        }
    }
}

enum PipelineNextAction {
    static func requirement(for selector: String?, phaseLabel: String) -> String {
        switch selector {
        case "host.project_track":
            "Complete the project setup inputs."
        case "host.analysis":
            "Complete and review the Audio Analysis."
        case "host.brief":
            "Create the Brief."
        case "host.production_design":
            "Create the Production Design."
        case "host.treatment":
            "Create the Treatment."
        case "host.storyboard":
            "Create the Storyboard."
        case "host.bible":
            "Create the current Bible."
        case "host.shotlist":
            "Create the current Shot List."
        case "host.sanity_report":
            "Run Sanity and resolve its blocking findings."
        case "host.frames_manifest":
            "Generate and review the current frame set."
        case "host.render_manifest":
            "Complete the current Render Manifest."
        default:
            "Complete the required \(phaseLabel) artifact."
        }
    }
}

struct PipelineReadinessPresentation: Equatable {
    let message: String
    let diagnostic: String?

    static func current(
        selector: String?,
        phaseLabel: String,
        approval: NativeGateApprovalReadiness,
        mutations: NativeGateApprovalReadiness,
        hostDecisionRequirement: String?
    ) -> Self {
        if let hostDecisionRequirement {
            return Self(
                message: hostDecisionRequirement,
                diagnostic: "A host-owned decision is still waiting for an answer."
            )
        }
        if let blocker = mutations.blocker {
            return Self(
                message: userMessage(
                    for: blocker,
                    selector: selector,
                    phaseLabel: phaseLabel
                ),
                diagnostic: blocker
            )
        }
        if approval.isReady {
            return Self(
                message: "The \(phaseLabel) artifact is structurally complete and ready for approval.",
                diagnostic: nil
            )
        }
        guard let blocker = approval.blocker else {
            return Self(
                message: PipelineNextAction.requirement(
                    for: selector,
                    phaseLabel: phaseLabel
                ),
                diagnostic: nil
            )
        }
        return Self(
            message: userMessage(
                for: blocker,
                selector: selector,
                phaseLabel: phaseLabel
            ),
            diagnostic: blocker
        )
    }

    private static func userMessage(
        for blocker: String,
        selector: String?,
        phaseLabel: String
    ) -> String {
        let lower = blocker.lowercased()
        if lower.contains("checking") {
            return "Checking \(phaseLabel) approval requirements."
        }
        if let card = hostOwnedCard(in: blocker) {
            return "Complete the \(card) card before approving \(phaseLabel)."
        }
        if lower.contains("while ") && lower.contains(" is running") {
            return "Wait for the running phase to finish before changing phase gates."
        }
        if lower.contains("workflow") || lower.contains("pack")
            || lower.contains("plugin") || lower.contains("ngv.json") {
            return "Restore the project's format workflow before changing phase gates."
        }
        if lower.contains("canon alternative") {
            return "Resolve the open Treatment canon choices before approval."
        }
        if lower.contains("story causality") {
            return "Update Treatment's story structure to match the current Brief."
        }
        if lower.contains("storyboard causality") || lower.contains("treatment beat") {
            return "Update the Storyboard to cover the current Treatment beats."
        }
        if lower.contains("frame finding") || lower.contains("style audit")
            || lower.contains("style criterion") || lower.contains("frame observation") {
            return "Resolve or explicitly accept the current frame findings before approval."
        }
        if lower.contains("sequence review") || lower.contains("assembled sequence")
            || lower.contains("reviewed reel") {
            return "Complete the current sequence review before approving Render."
        }
        if selector == "host.render_manifest",
           (lower.contains("take") || lower.contains("selected")) {
            return "Select a reviewed final take for every shot before approving Render."
        }
        if selector == "host.analysis" {
            if lower.contains("structure") || lower.contains("section") {
                return "Review the unresolved Audio Analysis section structure."
            }
            if lower.contains("beat") || lower.contains("analysis artifact") {
                return "Complete Audio Analysis with a verified beat grid and section structure."
            }
        }
        if lower.contains("stale") || lower.contains("changed")
            || lower.contains("does not match") || lower.contains("no longer matches")
            || lower.contains("lineage") {
            return "Update \(phaseLabel) to match its current approved inputs."
        }
        if lower.contains("missing") || lower.contains("unreadable")
            || lower.contains("incomplete") || lower.contains("no ") {
            return "Create or repair the current \(phaseLabel) artifact before approval."
        }
        return PipelineNextAction.requirement(
            for: selector,
            phaseLabel: phaseLabel
        )
    }

    private static func hostOwnedCard(in blocker: String) -> String? {
        let prefix = "Complete the host-owned "
        let suffix = " card before working on "
        guard let start = blocker.range(of: prefix),
              let end = blocker.range(of: suffix, range: start.upperBound..<blocker.endIndex)
        else { return nil }
        let value = blocker[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct PipelinePanelView: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.interfaceScale) private var interfaceScale

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded(ProductionNavigationData)
        case failed(CockpitError)
    }

    @State private var state: LoadState = .idle
    @State private var loadToken = 0
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
    @State private var gateError: GateErrorState?
    @State private var rewindPhase: ProjectPhase?

    private struct GateErrorState: Equatable {
        let message: String
        let diagnostic: String
    }

    private var runningPhase: String? {
        guard let dataRoot else { return nil }
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: dataRoot)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .task(id: editor.projectURL) { await load() }
            .onChange(of: editor.engineStateRevision) { _, _ in
                Task { await load(showProgress: false) }
            }
            .onChange(of: editor.projectURL) { _, _ in
                gateError = nil
                rewindPhase = nil
            }
            .onChange(of: editor.availableCockpitPackSurfaces) { _, _ in normalizeSelection() }
            .onChange(of: runningPhase) { _, _ in refreshApprovalReadiness() }
            .onChange(of: editor.cockpitTab) { _, tab in
                guard tab != .project, tab != .pipeline else { return }
                normalizeSelection(honorRequestedSurface: true)
            }
            .onChange(of: editor.cockpitPackSurfaceID) { _, id in
                guard id != nil else { return }
                normalizeSelection(honorRequestedSurface: true)
            }
            .confirmationDialog(
                rewindPhase.map { "Rewind to \(phaseLabel($0.phase))?" } ?? "Rewind pipeline?",
                isPresented: Binding(
                    get: { rewindPhase != nil },
                    set: { if !$0 { rewindPhase = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let phase = rewindPhase {
                    Button("Rewind to \(phaseLabel(phase.phase))", role: .destructive) {
                        rewindPhase = nil
                        rewind(to: phase)
                    }
                }
                Button("Cancel", role: .cancel) { rewindPhase = nil }
            } message: {
                Text("Approvals for this phase and every later phase will be cleared. Artifacts, takes, media, and timeline clips remain in the project.")
            }
            .overlay(alignment: .topLeading) {
                if let rewindPhase {
                    AppRelaunchClickProbe(
                        identifier: "production.rewind.confirmation",
                        acceptanceValue: rewindPhase.phase
                    )
                    .frame(width: AppTheme.BorderWidth.hairline, height: AppTheme.BorderWidth.hairline)
                    .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            centeredProgress()
        case .failed(let error):
            CockpitStateView.error(
                error,
                title: "Couldn't verify the production workflow",
                subject: "the production workflow",
                activePack: InstalledPack.named(editor.activePluginName),
                startProduction: { editor.startProduction() },
                isStarting: editor.productionStarted
            ) { Task { await load() } }
        case .loaded(let navigation):
            if let data = navigation.state {
                loadedBody(data, contract: navigation.contract)
            } else {
                CockpitStateView.error(
                    .notInitialized,
                    title: "No production workflow yet",
                    subject: "the production workflow",
                    activePack: InstalledPack.named(editor.activePluginName),
                    startProduction: { editor.startProduction() },
                    isStarting: editor.productionStarted
                ) { Task { await load() } }
            }
        }
    }

    private func loadedBody(_ data: ProjectStateData, contract: ContractData) -> some View {
        VStack(spacing: AppTheme.Spacing.none) {
            HStack(spacing: AppTheme.Spacing.none) {
                phaseNavigation(data, contract: contract)
                    .frame(width: AppTheme.ComponentSize.productionNavigationWidth * interfaceScale)
                AppDivider()
                viewedPhaseSurface(data, contract: contract)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if let reason = surfaceReadOnlyReason(data) {
                            Label(reason, systemImage: "lock.fill")
                                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xs)
                                .background(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                        .fill(AppTheme.Background.prominentColor)
                                )
                                .padding(AppTheme.Spacing.sm)
                                .allowsHitTesting(false)
                        }
                    }
            }
            AppDivider()
            phaseDock(data, contract: contract)
        }
    }

    private func phaseNavigation(_ data: ProjectStateData, contract: ContractData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                progressHeader(data)
                ForEach(data.phases) { phase in
                    phaseNavigationRow(phase, data: data, contract: contract)
                }
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.Background.surfaceColor)
    }

    private func progressHeader(_ data: ProjectStateData) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("PRODUCTION")
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(data.isComplete ? "Complete" : "\(data.phases.filter(\.approved).count) of \(data.phases.count) approved")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            ProgressView(value: data.progress)
                .tint(AppTheme.Status.successColor)
                .accessibilityLabel("Approved phases")
                .accessibilityValue("\(data.phases.filter(\.approved).count) of \(data.phases.count)")
        }
        .padding(.bottom, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phaseNavigationRow(
        _ phase: ProjectPhase,
        data: ProjectStateData,
        contract: ContractData
    ) -> some View {
        let isSelected = editor.viewedPipelinePhaseID == phase.phase
        let isCurrent = data.nextPhaseName == phase.phase
        let isRunning = runningPhase == phase.phase
        let isFuture = !phase.approved && !isCurrent
        let controlsAvailable = mutationReadiness.isReady
            && !gateWriting
            && runningPhase == nil
            && !editor.agentService.isComposerBlocked
        return HStack(spacing: AppTheme.Spacing.xs) {
            Button {
                selectPhase(phase.phase)
            } label: {
                HStack(spacing: AppTheme.Spacing.sm) {
                    phaseStatus(phase, isRunning: isRunning)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(phaseLabel(phase.phase, contract: contract))
                            .interfaceFont(
                                size: AppTheme.Typography.ui,
                                weight: isCurrent ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium
                            )
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .lineLimit(2)
                        if isCurrent {
                            Text("Current")
                                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.medium)
                                .foregroundStyle(editor.projectPalette.accent)
                        }
                    }
                    Spacer(minLength: AppTheme.Spacing.none)
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .frame(maxWidth: .infinity, minHeight: AppTheme.ComponentSize.pipelineRowMinHeight, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(isSelected
                              ? editor.projectPalette.accent.opacity(AppTheme.Opacity.subtle)
                              : AppTheme.Background.clearColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(
                            isSelected ? editor.projectPalette.accent.opacity(AppTheme.Opacity.medium) : AppTheme.Background.clearColor,
                            lineWidth: AppTheme.BorderWidth.hairline
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            }
            .buttonStyle(.plain)
            .help("View \(phaseLabel(phase.phase, contract: contract))")
            .background(
                AppRelaunchClickProbe(
                    identifier: "production.phase.\(phase.phase)",
                    acceptanceState: isSelected
                )
            )

            if phase.approved || isCurrent {
                Menu {
                    Button("Needs revision") {
                        markNeedsRevision(phase)
                    }
                    .disabled(!phase.approved || !controlsAvailable)
                    Divider()
                    Button("Rewind to here…", role: .destructive) {
                        rewindPhase = phase
                    }
                    .disabled(isFuture || !controlsAvailable)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(AppTheme.Text.mutedColor)
                .fixedSize()
                .disabled(!controlsAvailable)
                .accessibilityLabel("Gate actions for \(phaseLabel(phase.phase, contract: contract))")
                .help(runningPhase == nil ? "Gate actions" : "Gate actions are unavailable while a phase is running")
                .background(
                    AppRelaunchClickProbe(
                        identifier: "production.phase.\(phase.phase).actions",
                        acceptanceState: controlsAvailable
                    )
                )
            }
        }
    }

    @ViewBuilder
    private func viewedPhaseSurface(_ data: ProjectStateData, contract: ContractData) -> some View {
        if let phase = selectedPhase(in: data),
           let route = PipelineSurfaceRouting.route(
               for: phase.phase,
               contract: contract,
               availablePackSurfaces: editor.availableCockpitPackSurfaces
           ) {
            let allowsMutation = surfaceAllowsMutation(data)
            switch route.destination {
            case .story(let artifact):
                StoryPanelView(artifact: artifact, allowsMutation: allowsMutation)
            case .review(let artifact):
                ReviewPanelView(artifact: artifact, allowsMutation: allowsMutation)
            case .tab(.bible):
                BiblePanelView()
            case .tab(.shotlist):
                ShotlistPanelView()
            case .tab(_):
                interactionSurface(
                    phase: phase.phase,
                    route: route,
                    contract: contract,
                    allowsMutation: allowsMutation
                )
            case .pack(let id):
                if let surface = editor.availableCockpitPackSurfaces.first(where: { $0.id == id }) {
                    DeclarativePackSurfaceView(surface: surface) {
                        editor.availableCockpitPackSurfaces.removeAll { $0.id == id }
                    }
                } else {
                    interactionSurface(
                        phase: phase.phase,
                        route: route,
                        contract: contract,
                        allowsMutation: allowsMutation
                    )
                }
            case .storyboard:
                PipelineStoryboardReviewSheet(embedded: true)
            case .productionDesign:
                productionDesignSurface(
                    phase: phase.phase,
                    route: route,
                    contract: contract,
                    allowsMutation: allowsMutation
                )
            case .sanity:
                SanityPanelView()
            case .interaction:
                interactionSurface(
                    phase: phase.phase,
                    route: route,
                    contract: contract,
                    allowsMutation: allowsMutation
                )
            }
            .overlay(alignment: .topLeading) {
                AppRelaunchClickProbe(
                    identifier: "production.surface.\(route.acceptanceID)",
                    acceptanceState: allowsMutation
                )
                .frame(width: AppTheme.BorderWidth.hairline, height: AppTheme.BorderWidth.hairline)
                .allowsHitTesting(false)
            }
        } else {
            CockpitStateView.empty(
                icon: "rectangle.stack",
                title: "Phase unavailable",
                message: "The production workflow does not expose a surface for this phase."
            )
        }
    }

    private func productionDesignSurface(
        phase: String,
        route: PipelineSurfaceRouting.Route,
        contract: ContractData,
        allowsMutation: Bool
    ) -> some View {
        VStack(spacing: AppTheme.Spacing.none) {
            ProductionStyleReviewView(allowsMutation: false)
            interactionCard(
                phase: phase,
                route: route,
                contract: contract,
                allowsMutation: allowsMutation
            )
                .padding(AppTheme.Spacing.lg)
            Spacer(minLength: AppTheme.Spacing.none)
        }
    }

    private func interactionSurface(
        phase: String,
        route: PipelineSurfaceRouting.Route,
        contract: ContractData,
        allowsMutation: Bool
    ) -> some View {
        VStack {
            Spacer(minLength: AppTheme.Spacing.lg)
            interactionCard(
                phase: phase,
                route: route,
                contract: contract,
                allowsMutation: allowsMutation
            )
                .frame(maxWidth: AppTheme.ComponentSize.productionInteractionMaxWidth)
            Spacer(minLength: AppTheme.Spacing.lg)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func interactionCard(
        phase: String,
        route: PipelineSurfaceRouting.Route,
        contract: ContractData,
        allowsMutation: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            Label(phaseLabel(phase, contract: contract), systemImage: route.icon)
                .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(PipelineNextAction.requirement(
                for: contract.phases[phase]?.artifactSelector,
                phaseLabel: phaseLabel(phase, contract: contract)
            ))
            .interfaceFont(size: AppTheme.Typography.reading)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .fixedSize(horizontal: false, vertical: true)
            if allowsMutation {
                Button("Open Agent") { editor.agentPanelVisible = true }
                    .buttonStyle(.capsule(.prominent, size: .regular))
            } else {
                Text("Rewind this phase before making changes.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private func phaseDock(_ data: ProjectStateData, contract: ContractData) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.mdLg) {
            if let gateError {
                gateErrorBanner(gateError)
            } else if gateWriting {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("UPDATING PHASE GATE")
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(editor.projectPalette.accent)
                    Text("The production state is being revalidated and saved.")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                }
                Spacer(minLength: AppTheme.Spacing.none)
            } else if let runningPhase {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("RUNNING")
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(editor.projectPalette.accent)
                    Text("\(phaseLabel(runningPhase, contract: contract)) is running. Other phases remain available to inspect.")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                Button("Show running phase") { selectPhase(runningPhase) }
                    .buttonStyle(.capsule(.secondary, size: .regular))
            } else if let current = data.nextPhaseName,
                      let phase = data.phases.first(where: { $0.phase == current }) {
                currentPhaseDock(phase, contract: contract)
            } else {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("PRODUCTION COMPLETE")
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(AppTheme.Status.successColor)
                    Text("All production phases are approved. Select a phase to inspect its artifacts.")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                }
                Spacer(minLength: AppTheme.Spacing.none)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: AppTheme.ComponentSize.phaseDockMinHeight, alignment: .leading)
        .background(AppTheme.Background.raisedColor)
    }

    private func currentPhaseDock(_ phase: ProjectPhase, contract: ContractData) -> some View {
        let label = phaseLabel(phase.phase, contract: contract)
        let selector = contract.phases[phase.phase]?.artifactSelector
        let route = PipelineSurfaceRouting.route(
            for: phase.phase,
            contract: contract,
            availablePackSurfaces: editor.availableCockpitPackSurfaces
        )
        let enabled = PipelineApprovalControl.isEnabled(
            approvalReady: approvalPhase == phase.phase && approvalReadiness.isReady,
            controlsAvailable: mutationReadiness.isReady,
            gateWriting: gateWriting,
            pipelineIsRunning: false,
            hostDecisionPending: editor.agentService.isComposerBlocked
        )
        let presentation = PipelineReadinessPresentation.current(
            selector: selector,
            phaseLabel: label,
            approval: approvalReadiness,
            mutations: mutationReadiness,
            hostDecisionRequirement: editor.agentService.composerBlockerDescription
                ?? (editor.agentService.isComposerBlocked
                    ? "Resolve the open Agent decision before approving \(label)."
                    : nil)
        )
        return HStack(alignment: .center, spacing: AppTheme.Spacing.mdLg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("CURRENT PHASE · \(label.uppercased())")
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(editor.projectPalette.accent)
                Text(presentation.message)
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            if let route {
                Button(route.destination == .interaction ? "Open Agent" : "Open \(route.label)") {
                    open(route, phase: phase.phase)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .background(
                    AppRelaunchClickProbe(
                        identifier: "production.dock.open",
                        acceptanceValue: route.acceptanceID
                    )
                )
            }
            if !enabled, let diagnostic = presentation.diagnostic {
                Button("Ask Agent") {
                    askAgentToResolveReadiness(
                        phase: phase.phase,
                        diagnostic: diagnostic
                    )
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
            }
            Button("Approve") { approve(phase) }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(!enabled)
                .help(enabled ? "Approve \(label)" : presentation.message)
                .background(
                    AppRelaunchClickProbe(
                        identifier: "production.dock.approve",
                        acceptanceState: enabled,
                        acceptanceValue: presentation.message
                    )
                )
        }
    }

    private func open(_ route: PipelineSurfaceRouting.Route, phase: String) {
        selectPhase(phase)
        if route.destination == .interaction { editor.agentPanelVisible = true }
    }

    private func askAgentToResolveReadiness(phase: String, diagnostic: String) {
        editor.agentService.send(
            text: "Resolve the \(phase) approval blocker before requesting approval again: \(diagnostic)",
            mentions: [],
            hidden: true
        )
        editor.agentPanelVisible = true
    }

    private func selectPhase(_ phase: String) {
        editor.viewedPipelinePhaseID = phase
        editor.cockpitTab = .pipeline
        editor.cockpitPackSurfaceID = nil
    }

    private func selectedPhase(in data: ProjectStateData) -> ProjectPhase? {
        guard let id = editor.viewedPipelinePhaseID else { return nil }
        return data.phases.first { $0.phase == id }
    }

    private func surfaceAllowsMutation(_ data: ProjectStateData) -> Bool {
        guard selectedPhase(in: data)?.phase == data.nextPhaseName else { return false }
        return runningPhase == nil
            && !gateWriting
            && mutationReadiness.isReady
            && !editor.agentService.isComposerBlocked
    }

    private func surfaceReadOnlyReason(_ data: ProjectStateData) -> String? {
        guard let selected = selectedPhase(in: data) else { return nil }
        if let runningPhase {
            return "Read only while \(phaseLabel(runningPhase)) runs"
        }
        if selected.approved {
            return "Read only — rewind this phase to make changes"
        }
        if selected.phase != data.nextPhaseName {
            return "Read only — complete earlier phases first"
        }
        if editor.agentService.isComposerBlocked {
            return "Read only until the open decision is resolved"
        }
        if gateWriting || !mutationReadiness.isReady {
            return "Checking editing access"
        }
        return nil
    }

    private func normalizeSelection(honorRequestedSurface: Bool = false) {
        guard case .loaded(let navigation) = state,
              let data = navigation.state else { return }
        let requestedPhase = honorRequestedSurface ? nil : editor.viewedPipelinePhaseID
        editor.viewedPipelinePhaseID = PipelineNavigationSelection.normalized(
            requestedPhase: requestedPhase,
            requestedTab: editor.cockpitTab,
            requestedPackSurfaceID: editor.cockpitPackSurfaceID,
            state: data,
            contract: navigation.contract,
            availablePackSurfaces: editor.availableCockpitPackSurfaces
        )
    }

    private func phaseLabel(_ phase: String, contract: ContractData? = nil) -> String {
        contract?.phases[phase]?.displayLabel ?? PhaseDisplay.label(phase)
    }

    private func phaseStatus(_ phase: ProjectPhase, isRunning: Bool) -> some View {
        let label = isRunning ? "In progress"
            : phase.approved ? "Approved"
            : phase.state == "needs_revision" ? "Needs revision" : "Not approved"
        let symbol = isRunning ? "circle.dotted.circle"
            : phase.approved ? "checkmark.circle.fill"
            : phase.state == "needs_revision" ? "exclamationmark.triangle.fill" : "circle"
        let color = isRunning ? editor.projectPalette.accent
            : phase.approved ? AppTheme.Status.successColor
            : phase.state == "needs_revision" ? AppTheme.Status.errorColor : AppTheme.Text.mutedColor
        return Image(systemName: symbol)
            .interfaceFont(size: AppTheme.Typography.ui)
            .foregroundStyle(color)
            .accessibilityLabel(label)
            .help(phase.notes.map { "\(label): \($0)" } ?? label)
    }

    private func approve(_ phase: ProjectPhase) {
        apply(failureMessage: "\(phaseLabel(phase.phase)) isn't ready for approval yet.") {
            try await NativeGateWriter.approve(
                projectDir: $0,
                phase: phase.phase,
                declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding,
                executionCoordinator: editor.pipelinePhaseRunCoordinator
            )
        }
    }

    private func markNeedsRevision(_ phase: ProjectPhase) {
        apply(failureMessage: "Couldn't update \(phaseLabel(phase.phase)). Try again.") {
            try await NativeGateWriter.setState(
                projectDir: $0,
                phase: phase.phase,
                state: .needsRevision,
                declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding,
                executionCoordinator: editor.pipelinePhaseRunCoordinator
            )
        }
    }

    private func rewind(to phase: ProjectPhase) {
        apply(failureMessage: "Couldn't rewind the pipeline. Try again.") {
            try NativeGateWriter.rewind(
                projectDir: $0,
                targetPhase: phase.phase,
                declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding,
                executionCoordinator: editor.pipelinePhaseRunCoordinator
            )
        }
    }

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
            gateError = GateErrorState(message: "No project is open.", diagnostic: "No open project to update.")
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
                if editor.workingRoot == dir { editor.onPipelineChanged?() }
            } catch {
                gateError = GateErrorState(message: failureMessage, diagnostic: error.localizedDescription)
            }
            await editor.refreshEngineState()
            if editor.workingRoot == dir { await load(showProgress: false) }
        }
    }

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
            Button("Ask the agent") {
                editor.agentService.send(
                    text: "Resolve this pipeline gate failure before requesting approval again: \(error.diagnostic)",
                    mentions: [],
                    hidden: true
                )
                editor.agentPanelVisible = true
                gateError = nil
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            Button { gateError = nil } label: {
                Image(systemName: "xmark")
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    private func centeredProgress() -> some View {
        VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshApprovalReadiness() {
        readinessToken += 1
        guard case .loaded(let navigation) = state,
              let data = navigation.state,
              editor.workingRoot != nil else {
            approvalPhase = nil
            approvalReadiness = .blocked("The pipeline state is unavailable.")
            mutationReadiness = .blocked("The pipeline state is unavailable.")
            return
        }
        approvalPhase = data.nextPhaseName
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
                    executionCoordinator: editor.pipelinePhaseRunCoordinator
                )
                guard token == readinessToken,
                      approvalPhase == currentPhase,
                      editor.workingRoot == currentDir else { continue }
                mutationReadiness = readiness.mutations
                approvalReadiness = readiness.approval
            } while readinessRefreshQueued
            readinessTask = nil
        }
    }

    private func load(showProgress: Bool = true) async {
        if ProcessInfo.processInfo.environment["NGV_DIAGNOSTIC_REPLAY"] != nil,
           let contract = editor.uiContract {
            state = .loaded(ProductionNavigationData(contract: contract, state: editor.projectState))
            normalizeSelection()
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
        if showProgress { state = .loading }
        let result = CockpitDataService.productionNavigation(
            projectDir: dir,
            declaredPack: editor.declaredPluginName,
            declaredBinding: editor.declaredPluginBinding
        )
        guard token == loadToken else { return }
        switch result {
        case .success(let navigation):
            state = .loaded(navigation)
            normalizeSelection(
                honorRequestedSurface: editor.cockpitTab != .pipeline
                    || editor.cockpitPackSurfaceID != nil
            )
            refreshApprovalReadiness()
        case .failure(let error):
            approvalPhase = nil
            approvalReadiness = .blocked("The pipeline state is unavailable.")
            mutationReadiness = .blocked("The pipeline state is unavailable.")
            state = .failed(error)
        }
    }
}
