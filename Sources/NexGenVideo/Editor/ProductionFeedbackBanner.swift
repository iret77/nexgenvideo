import SwiftUI

struct ProductionFeedbackBanner: View {
    let toast: MediaPanelToast
    @State private var contentHeight = AppTheme.ComponentSize.previewErrorMaxHeight
    @Environment(EditorViewModel.self) private var editor

    private var message: some View {
        Text(toast.message)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .reviewAcceptanceProbe("production.feedback", text: toast.message)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            Image(systemName: toast.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.kind == .success ? AppTheme.Status.successColor : AppTheme.Status.warningColor)
                .accessibilityHidden(true)
            ScrollView {
                message.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if height.isFinite, height > 0 { contentHeight = height }
                }
            }
            .id(toast.message)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity)
            .frame(height: min(contentHeight, AppTheme.ComponentSize.previewErrorMaxHeight), alignment: .topLeading)
            .clipped()
            .reviewAcceptanceProbe("production.feedback.viewport")
            Button("Dismiss") { editor.dismissMediaPanelToast() }
                .buttonStyle(InlineActionButtonStyle())
                .accessibilityLabel("Dismiss production message")
                .reviewAcceptanceProbe("production.feedback.dismiss")
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .foregroundStyle(AppTheme.Text.primaryColor)
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Background.raisedColor)
        .accessibilityElement(children: .contain)
    }
}
