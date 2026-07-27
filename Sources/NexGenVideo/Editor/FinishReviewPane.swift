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
            ReviewPanelView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Review and deliver")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Check the cut, then export the deliverable.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.md)
            Button { editor.showExportDialog = true } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: AppTheme.FontSize.xs))
                    Text("Export")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                }
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
            .controlSize(.small)
            .help("Export the deliverable")
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .frame(height: AppTheme.Layout.toolbarHeight)
        .background(AppTheme.Background.raisedColor)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.thin)
        }
    }
}
