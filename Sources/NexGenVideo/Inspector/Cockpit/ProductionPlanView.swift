import NexGenEngine
import SwiftUI

struct ProductionPlanView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var snapshot: ProductionPlanPresentation.Snapshot?
    @State private var loadedHome: URL?
    @State private var failure: String?
    @State private var loading = false
    @State private var generation = 0
    @State private var filter: ExecutionSourceModeV1?
    @State private var assigningReferences = false
    @State private var technicalEdit: TechnicalEdit?

    private struct TechnicalEdit: Identifiable {
        let id: String
        let number: Int
        let home: URL
    }

    private var editable: Bool {
        guard !loading, failure == nil, loadedHome == editor.workingRoot, editor.projectState?.nextPhaseName == "shotlist",
              !editor.agentService.isStreaming, !editor.agentService.isComposerBlocked,
              let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) else { return false }
        _ = editor.pipelinePhaseExecution.snapshot
        return editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) == nil
    }

    private var editingUnavailableReason: String? {
        guard !editable else { return nil }
        if loading { return "Loading the Shot List before production settings can be edited." }
        if failure != nil { return "Reload the Shot List before editing production settings." }
        guard loadedHome == editor.workingRoot,
              editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) != nil else {
            return "Open this production project and load its Shot List before editing settings."
        }
        if editor.agentService.isStreaming { return "Wait for the agent to finish before editing production settings." }
        if editor.agentService.isComposerBlocked { return "Complete or dismiss the agent decision before editing production settings." }
        if let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
           editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) != nil {
            return "Wait for the current production action to finish before editing settings."
        }
        if let phase = editor.projectState?.phases.first(where: { $0.phase == "shotlist" }), phase.approved && phase.approvalCurrent {
            return "Choose Revise Shot List in the workflow dock to change approved production settings."
        }
        if let phase = editor.projectState?.nextPhaseName, phase != "shotlist" {
            return "Complete \(PhaseDisplay.label(phase)) before editing Shot List production settings."
        }
        return "Load the current Shot List before editing production settings."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Picker("Source", selection: $filter) {
                    Text("All sources").tag(ExecutionSourceModeV1?.none)
                    ForEach(ExecutionSourceModeV1.allCases, id: \.self) { mode in
                        Text(ProductionPlanPresentation.sourceLabel(mode)).tag(Optional(mode))
                    }
                }.pickerStyle(.menu)
                Spacer(minLength: AppTheme.Spacing.sm)
                if loading { ProgressView().controlSize(.small) }
                Button("Open Shot Planning") { editor.revealCockpit(.shotPlanning) }
                    .buttonStyle(InlineActionButtonStyle())
                Button("Inspect references…") { assigningReferences = true }.buttonStyle(InlineActionButtonStyle())
            }.padding(.horizontal, AppTheme.Spacing.lg)
            if let failure {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(failure).foregroundStyle(AppTheme.Status.errorColor)
                    Button("Reload Shot List") { Task { await load() } }.buttonStyle(InlineActionButtonStyle())
                }.padding(.horizontal, AppTheme.Spacing.lg)
            }
            if let reason = editingUnavailableReason {
                Text(reason).foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppTheme.Spacing.lg)
            }
            if let snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        if editor.declaredPluginName == "musicvideo", let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }) {
                            MusicvideoProductionReviewView(snapshot: snapshot, dataRoot: root)
                        }
                        ForEach(snapshot.projection.shots.filter { filter == nil || $0.sourceMode == filter }, id: \.id) { shot in
                            row(shot, in: snapshot)
                        }
                        if !snapshot.projection.shots.contains(where: { filter == nil || $0.sourceMode == filter }) {
                            Text("No shots use this source.").foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                    }.padding(.horizontal, AppTheme.Spacing.lg).padding(.bottom, AppTheme.Spacing.lg)
                }
            } else if !loading, failure == nil {
                CockpitStateView.empty(icon: "list.bullet.rectangle", title: "No Shot List yet",
                    message: "Complete Shot Planning and References to resolve each shot's sources, references and production model.")
            }
        }
        .padding(.top, AppTheme.Spacing.md)
        .interfaceFont(size: AppTheme.Typography.ui)
        .reviewAcceptanceProbe("production.plan.workspace")
        .task(id: "\(editor.workingRoot?.path ?? ""):\(editor.engineStateRevision)") { await load() }
        .sheet(item: $technicalEdit, onDismiss: { Task { await load() } }) { item in
            ProductionPlanTechnicalEditor(shotID: item.id, number: item.number, home: item.home).environment(editor)
        }
        .sheet(isPresented: $assigningReferences) {
            VStack(spacing: AppTheme.Spacing.sm) {
                HStack { Spacer(); Button("Done") { assigningReferences = false }.keyboardShortcut(.cancelAction) }
                    .padding(.horizontal, AppTheme.Spacing.lg).padding(.top, AppTheme.Spacing.md)
                ProductionObligationView().environment(editor)
            }.frame(width: AppTheme.Layout.productionDecisionReviewWidth, height: AppTheme.Layout.productionDecisionReviewHeight)
        }
    }

    private func row(_ shot: ExecutionShotV1, in snapshot: ProductionPlanPresentation.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Button("Shot \(snapshot.number(shot.id) ?? 0)") {
                    guard let home = editor.workingRoot else { return }
                    editor.productionPlanSelection = .init(home: home, snapshot: snapshot, shotID: shot.id)
                }
                .buttonStyle(InlineActionButtonStyle())
                .reviewAcceptanceProbe("production.plan.select." + shot.id)
                .accessibilityAddTraits(editor.productionPlanSelection?.shotID == shot.id ? .isSelected : [])
                Spacer(minLength: AppTheme.Spacing.sm)
                Text(ProductionPlanPresentation.sourceLabel(shot.sourceMode)).foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Text(shot.primaryAction).textSelection(.enabled)
            if let timing = snapshot.projection.timing(for: shot.id) {
                Text("\(seconds(timing.startTicks, snapshot)) · \(seconds(timing.durationTicks, snapshot)) duration")
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Text([shot.camera.framingID, shot.camera.movementID, shot.camera.movementDetail].compactMap { $0 }.joined(separator: " · "))
                .textSelection(.enabled)
            if let source = snapshot.projection.source(for: shot.id) {
                Label((source.path as NSString).lastPathComponent, systemImage: "film")
                    .textSelection(.enabled)
            }
            if let routing = snapshot.inventory.shots.first(where: { $0.shotID == shot.id }) {
                ProductionPlanRoutingView(routing: routing)
            }
            if let chain = snapshot.projection.chains.first(where: { $0.shotID == shot.id }) {
                Label("\(chain.kind == .frameContinuation ? "Continues the last frame of" : "Extends the video from") Shot \(snapshot.number(chain.predecessorShotID) ?? 0)",
                    systemImage: "link")
            }
            if !shot.risks.isEmpty {
                Label(shot.risks.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.Status.warningColor).textSelection(.enabled)
            }
            if shot.sourceMode != .imported {
                Button("Edit production settings…") {
                    if let home = editor.workingRoot {
                        technicalEdit = .init(id: shot.id, number: snapshot.number(shot.id) ?? 0, home: home)
                    }
                }.buttonStyle(InlineActionButtonStyle()).disabled(!editable)
                    .help(editingUnavailableReason ?? "Choose the model, conditioning and output range.")
                    .reviewAcceptanceProbe("production.plan.edit.\(shot.id)", state: editable)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.raisedColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .reviewAcceptanceProbe("production.plan.shot.\(shot.id)", text: shot.primaryAction)
    }

    private func seconds(_ tick: Int64, _ snapshot: ProductionPlanPresentation.Snapshot) -> String {
        String(format: "%.2f s", snapshot.projection.timebase.seconds(for: tick))
    }

    private func load() async {
        generation += 1
        let token = generation
        let home = editor.workingRoot
        let selected = editor.productionPlanSelection?.home == home ? editor.productionPlanSelection?.shotID : nil
        if loadedHome != home {
            snapshot = nil; loadedHome = home; editor.productionPlanSelection = nil
        }
        loading = true; failure = nil
        defer { if token == generation { loading = false } }
        guard let home, let root = DataRootResolver.dataRoot(of: home) else { return }
        do {
            _ = try ProjectPackGate.requireLiveMutation(projectURL: home, declaredPack: editor.declaredPluginName,
                declaredBinding: editor.declaredPluginBinding, declaredProductionContract: editor.declaredProductionContract)
            let value = try await Task.detached(priority: .userInitiated) { try ProductionPlanPresentation.load(dataRoot: root) }.value
            guard token == generation, editor.workingRoot == home, !Task.isCancelled else { return }
            snapshot = value
            if let value, let selected, value.projection.shots.contains(where: { $0.id == selected }) {
                editor.productionPlanSelection = .init(home: home, snapshot: value, shotID: selected)
            } else {
                editor.productionPlanSelection = nil
            }
        } catch {
            guard token == generation, editor.workingRoot == home, !Task.isCancelled else { return }
            failure = error.localizedDescription
            editor.productionPlanSelection = nil
        }
    }
}

struct ProductionPlanInspector: View {
    let selection: ProductionPlanSelection

    var body: some View {
        ScrollView {
            if let shot = selection.shot, let timing = selection.timing {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("Shot \(selection.snapshot.number(shot.id) ?? 0)")
                        .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    field("Action", shot.primaryAction)
                    ProductionObjectLinksView(target: .shot(shot.id))
                    field("Source", ProductionPlanPresentation.sourceLabel(shot.sourceMode))
                    field("Start", seconds(timing.startTicks))
                    field("Duration", seconds(timing.durationTicks))
                    if let native = timing.nativeDurationTicks, native != timing.durationTicks {
                        field("Generated duration", seconds(native))
                        field("Selected range", "\(seconds(timing.sourceInTicks)) – \(seconds(timing.sourceInTicks + timing.durationTicks))")
                    }
                    field("Start state", shot.startState.summary)
                    field("End state", shot.endState.summary)
                    field("Camera", [shot.camera.framingID, shot.camera.movementID, shot.camera.movementDetail,
                        shot.camera.placement, shot.camera.endpoint].compactMap { $0 }.joined(separator: " · "))
                    if let routing = selection.snapshot.inventory.shots.first(where: { $0.shotID == shot.id }) {
                        ProductionPlanRoutingView(routing: routing)
                    }
                    if !shot.blocking.isEmpty {
                        field("Blocking", shot.blocking.map { [$0.entityID, $0.relation, $0.performance].compactMap { $0 }.joined(separator: ": ") }.joined(separator: "\n"))
                    }
                    if !shot.timedActionBeats.isEmpty {
                        field("Action beats", shot.timedActionBeats.map { String(format: "%.2f s · %@", $0.timeSeconds, $0.action) }.joined(separator: "\n"))
                    }
                    if !shot.continuityLocks.isEmpty { field("Continuity", shot.continuityLocks.joined(separator: "\n")) }
                    if let transition = shot.transitionIntent { field("Transition", transition) }
                    if !shot.risks.isEmpty { field("Risks", shot.risks.joined(separator: "\n")) }
                    if let rescue = shot.rescue { field("Rescue", rescue) }
                    if !shot.acceptance.isEmpty { field("Acceptance", shot.acceptance.map(\.requirement).joined(separator: "\n")) }
                    if let draft = selection.snapshot.draft.shots.first(where: { $0.shotID == shot.id }) {
                        ForEach(draft.obligations, id: \.id) { obligation in
                            field(obligation.subject, obligation.requirement)
                        }
                    }
                }.padding(AppTheme.Spacing.md).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.interfaceFont(size: AppTheme.Typography.ui)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            Text(title).foregroundStyle(AppTheme.Text.secondaryColor)
            Text(value).textSelection(.enabled)
        }
    }

    private func seconds(_ tick: Int64) -> String { String(format: "%.2f s", selection.snapshot.projection.timebase.seconds(for: tick)) }
}

private struct ProductionPlanRoutingView: View {
    let routing: PipelineProductionPlanReadStore.Shot

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let route = routing.route {
                Text("\(route.offering.providerID) · \(route.offering.catalogModelID)")
                    .fontWeight(AppTheme.FontWeight.medium).textSelection(.enabled)
            }
            if !routing.plannedInputs.isEmpty {
                Text("Input plan").foregroundStyle(AppTheme.Text.secondaryColor)
                ForEach(routing.plannedInputs) { input in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(input.label)
                        if input.materializationDeferred {
                            Text(input.id == "predecessor-frame" || input.id == "source-video"
                                ? "Uses the selected predecessor Take." : "Uses the approved image from Frames.")
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                    }
                }
            }
            ForEach(routing.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(AppTheme.Status.warningColor).textSelection(.enabled)
            }
        }
    }
}
