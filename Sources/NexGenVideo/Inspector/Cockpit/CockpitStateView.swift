import SwiftUI

// Shared loading / empty / error / engine-not-ready state views for the cockpit panels, factored out
// of the Bible panel's idiom so Pipeline / Shotlist / Sanity / Cost render identical states. Read-only.

enum CockpitStateView {

    /// Error / not-initialized state. `subject` is retained for call-site symmetry across the panels;
    /// the copy is driven by `title` and the error case.
    static func error(
        _ error: CockpitError,
        title: String,
        subject: String,
        startProduction: (() -> Void)? = nil,
        isStarting: Bool = false,
        retry: @escaping () -> Void
    ) -> some View {
        // `.notInitialized` is a normal guidance state, not a failure — calm copy, neutral icon. Only
        // genuinely transient errors get "Retry"; retrying a not-initialized project just re-reads the
        // same absent `project.yaml`, so it offers no Retry.
        let icon: String
        let headline: String
        let detail: String
        switch error {
        case .notInitialized:
            icon = "wand.and.stars"
            headline = isStarting ? "Setting up production…" : "No production pipeline"
            detail = isStarting
                ? "The agent is scaffolding the pipeline and will ask about your video's direction. Watch the Agent panel."
                : "This project isn't set up for AI production yet."
        default:
            icon = "exclamationmark.triangle"
            headline = title
            detail = error.message
        }
        return VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.title1))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(headline)
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(detail)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if error == .notInitialized {
                // The generic workflow is never plugin-gated: production is one action away.
                if let startProduction {
                    if isStarting {
                        // Visible in-flight state instead of an inert button the user taps repeatedly.
                        HStack(spacing: AppTheme.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Starting…")
                                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .padding(.top, AppTheme.Spacing.xs)
                    } else {
                        Button("Start production", action: startProduction)
                            .buttonStyle(.capsule(.prominent, size: .regular))
                            .padding(.top, AppTheme.Spacing.xs)
                    }
                }
            } else {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .padding(.top, AppTheme.Spacing.xs)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Empty / placeholder state.
    static func empty(icon: String, title: String, message: String) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.title1))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(title)
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(message)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
