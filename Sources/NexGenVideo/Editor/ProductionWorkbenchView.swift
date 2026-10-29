import NexGenEngine
import SwiftUI

struct ProductionWorkspaceSidebar: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var showsSources = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            SegmentedTabBar(titles: [String(localized: "Workflow"), String(localized: "Sources")],
                selected: showsSources ? String(localized: "Sources") : String(localized: "Workflow")) {
                showsSources = $0 == String(localized: "Sources")
            }
            if showsSources {
                MediaTab(workspace: .production)
            } else {
                if editor.hasProductionPipeline, editor.declaredPluginName == nil, editor.declaredProductionContract == nil {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Text("Legacy production workflow").fontWeight(AppTheme.FontWeight.semibold)
                        Text("Review the update to add Script, visual Storyboard and pre-render review to this project.")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Button("Review workflow update…") {
                            AppState.shared.enrollActiveProjectInProduction(expectedEditor: editor)
                        }.buttonStyle(InlineActionButtonStyle())
                            .reviewAcceptanceProbe("production.core.enroll")
                    }
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .padding(AppTheme.Spacing.md)
                    AppDivider()
                }
                PipelinePanelView(presentation: .sidebar)
            }
        }
        .background {
            if WorkspaceUIAcceptance.isRequested || GenerationBatchReviewSelfTest.isRequested || MusicvideoHostFlowAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "production.sidebar", acceptanceState: !showsSources)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct ProductionInspectorView: View {
    @Environment(EditorViewModel.self) private var editor

    private var hasProductionObject: Bool {
        switch editor.inspectedObject {
        case .entity, .look: editor.cockpitTab == .bible
        case .shot, .shotUse: editor.cockpitTab == .shotlist || editor.cockpitTab == .review
        case .mediaAsset: true
        case .clip, nil: false
        }
    }

    var body: some View {
        if editor.showsAgentActivity {
            AgentPanelView(presentation: .activity, onClose: { editor.showsAgentActivity = false })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .reviewAcceptanceProbe("production.activity")
        } else {
            inspectorContents
        }
    }

    private var inspectorContents: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.none) {
            Text("Inspector")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .padding(.horizontal, AppTheme.Spacing.md)
                .panelHeaderBar()
            if editor.cockpitTab == .storyboard, editor.usesProductionPlanningV2,
               let selection = editor.storyboardPlanningSelection, selection.home == editor.workingRoot {
                StoryboardPlanningInspector(selection: selection)
            } else if editor.cockpitTab == .shotlist, editor.usesProductionPlanningV2,
                      let selection = editor.productionPlanSelection, selection.home == editor.workingRoot {
                ProductionPlanInspector(selection: selection)
            } else if editor.cockpitTab == .storyboard, !editor.usesProductionPlanningV2, let selection = editor.storyboardSelection {
                StoryboardShotInspector(selection: selection)
            } else if editor.cockpitTab != .storyboard, !(editor.cockpitTab == .shotlist && editor.usesProductionPlanningV2), hasProductionObject {
                InspectorView()
            } else {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text(editor.productionSelectedPhase.map(PhaseDisplay.label) ?? String(localized: "Production"))
                        .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    Text(editor.cockpitTab == .storyboard
                        ? String(localized: "Select a shot to inspect its timing, camera and image source.")
                        : String(localized: "Review the selected phase in the workspace. Its current state and next action appear below."))
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppTheme.Spacing.md)
                Spacer(minLength: AppTheme.Spacing.none)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct WorkbenchStatusBar: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var showsBudget = false
    @State private var showsExports = false

    private var activeExport: ExportJob? {
        ExportQueue.shared.activeJob(ownerKey: editor.openWorkingCopyKey)
    }

    private var aiActive: Bool {
        editor.agentService.isStreaming || editor.agentService.currentSpendRun != nil
            || editor.generationBatchCoordinator.activeBatchID != nil
            || editor.workingRoot.flatMap { DataRootResolver.dataRoot(of: $0) }.flatMap {
                editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: $0)
            } != nil
    }

    private var budgetLabel: String {
        guard let state = editor.projectState else { return String(localized: "Budget") }
        let spend = String(format: "€%.2f", state.budgetSpentEur)
        if !state.spendComplete { return String(localized: "Budget · at least \(spend)") }
        return String(localized: "Budget · \(spend)")
    }

    var body: some View {
        @Bindable var editor = editor
        HStack(spacing: AppTheme.Spacing.md) {
            Button(budgetLabel) { showsBudget.toggle() }
                .popover(isPresented: $showsBudget, arrowEdge: .top) {
                    ScrollView { ProjectBudgetView().environment(editor).padding(AppTheme.Spacing.md) }
                        .frame(width: AppTheme.Layout.activityFlyoutWidth,
                               height: AppTheme.Layout.activityFlyoutHeight)
                }
            Spacer(minLength: AppTheme.Spacing.md)
            Button { editor.showsAgentActivity.toggle() } label: {
                Label(aiActive ? String(localized: "AI · Working") : String(localized: "AI activity"), systemImage: "sparkles")
            }
            .background {
                if WorkspaceUIAcceptance.isRequested || ChatHangReplay.isRequested {
                    AppRelaunchClickProbe(identifier: "production.ai")
                        .allowsHitTesting(false)
                }
            }
            .popover(isPresented: Binding(
                get: { editor.showsAgentActivity && editor.workspaceFocus != .production },
                set: { if editor.workspaceFocus != .production { editor.showsAgentActivity = $0 } }
            ), arrowEdge: .top) {
                AgentPanelView(presentation: .activity)
                    .environment(editor)
                    .interfaceStyle(palette: editor.projectPalette)
                    .frame(width: AppTheme.Layout.activityFlyoutWidth, height: AppTheme.Layout.activityFlyoutHeight)
            }
            Button { showsExports.toggle() } label: {
                Label(activeExport == nil ? String(localized: "Export") : String(localized: "Export · Working"),
                      systemImage: "square.and.arrow.up")
            }
            .reviewAcceptanceProbe("production.export")
            .popover(isPresented: $showsExports, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    Text("Export activity").interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    if let job = activeExport {
                        Text(job.title)
                        Text(job.detail).foregroundStyle(AppTheme.Text.secondaryColor)
                    } else {
                        Text("No export running").foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    Button("Open Export…") { showsExports = false; editor.setWorkspaceFocus(.export) }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .reviewAcceptanceProbe("production.export.open")
                }
                .interfaceFont(size: AppTheme.Typography.ui)
                .padding(AppTheme.Spacing.md)
                .frame(width: AppTheme.Layout.activityFlyoutWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .interfaceFont(size: AppTheme.Typography.ui)
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(AppTheme.Background.surfaceColor)
        .overlay(alignment: .top) { AppDivider() }
        .background {
            if WorkspaceUIAcceptance.isRequested || GenerationBatchReviewSelfTest.isRequested || MusicvideoHostFlowAcceptance.isRequested {
                AppRelaunchClickProbe(identifier: "production.status", acceptanceText: "Budget · AI activity · Export")
                    .allowsHitTesting(false)
            }
        }
    }
}
