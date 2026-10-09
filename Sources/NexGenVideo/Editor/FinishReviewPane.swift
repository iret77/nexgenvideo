import SwiftUI

/// The Finish stage's lower pane: a deliver header (reachable Export) over the canonical Review
/// gallery. The large player above is the QC surface; this is where the cut is reviewed and handed
/// off. Review and Export are reused wholesale — Finish adds no generation of its own.
struct FinishReviewPane: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(spacing: AppTheme.Spacing.none) {
            header
            // SEAM — the AI-enhance ops (issues #153-157: reframe, background removal, inpaint, LUT,
            // upscale) will slot in here as a per-shot/per-clip action row over the reviewed frames.
            // Not built yet: Finish reuses Review + Export only, and adds no generation.
            ReviewPanelView(offersProductionSetup: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Review")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, AppTheme.Spacing.lg)
                .panelHeaderBar()
            Text("Check the cut, then export the deliverable.")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppTheme.Spacing.lg)
            WrapLayout(spacing: AppTheme.Spacing.sm) { reviewActions }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.bottom, AppTheme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Background.raisedColor)
    }

    @ViewBuilder
    private var reviewActions: some View {
        LibraryAssetPickerButton(
            purpose: .workspace(.postproduction),
            acceptedTypes: Set(ClipType.allCases.filter { $0 != .text }),
            title: "Preview Media"
        ) { editor.selectMediaAsset($0) }
        .help("Preview original media")
        Button("Export", systemImage: "square.and.arrow.up") { editor.showExportDialog = true }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .help("Export the deliverable")
    }
}
