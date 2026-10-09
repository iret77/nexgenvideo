import AppKit
import SwiftUI

// Shared loading / empty / error / engine-not-ready state views for the cockpit panels, factored out
// of the Bible panel's idiom so Pipeline / Shotlist / Sanity / Cost render identical states. Read-only.

@MainActor
enum CockpitStateView {

    /// Error / not-initialized state. `subject` is retained for call-site symmetry across the panels;
    /// the copy is driven by `title` and the error case. When a format pack is active and the project
    /// isn't set up yet, `activePack` turns the placeholder into the pack's own hero (badge + pitch) —
    /// so the workspace shows you're in that pipeline, not a generic empty state.
    static func error(
        _ error: CockpitError,
        title: String,
        subject: String,
        activePack: InstalledPack? = nil,
        startProduction: (() -> Void)? = nil,
        isStarting: Bool = false,
        hasProduction: Bool = false,
        retry: @escaping () -> Void
    ) -> some View {
        // Retry an existing pipeline; offer setup only when production has not been initialized.
        let icon: String
        let headline: String
        let detail: String
        switch error {
        case .notInitialized:
            icon = hasProduction ? "exclamationmark.triangle" : "wand.and.stars"
            headline = hasProduction ? title : (isStarting ? "Setting up production…" : "No production pipeline")
            detail = hasProduction ? "Production could not be loaded. Try again." : isStarting
                ? "Complete the required setup in the Tasks panel."
                : "This project isn't set up for AI production yet."
        default:
            icon = "exclamationmark.triangle"
            headline = title
            detail = error.message
        }
        // Lead with the pack's own identity when one is active and the project isn't set up yet.
        let showPackHero = (error == .notInitialized) && !hasProduction && activePack != nil
        return WorkspaceStateView(
            title: showPackHero ? (activePack?.headline ?? activePack?.displayName) : headline,
            message: showPackHero ? activePack?.benefit : detail,
            systemImage: icon,
            banner: showPackHero ? activePack?.headerImage() : nil
        ) {
            if error == .notInitialized && !hasProduction {
                // The generic workflow is never plugin-gated: production is one action away.
                if let startProduction {
                    if isStarting {
                        // Visible in-flight state instead of an inert button the user taps repeatedly.
                        HStack(spacing: AppTheme.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Starting…")
                                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
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
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .padding(.top, AppTheme.Spacing.xs)
            }
        }
    }

    static func empty(icon: String, title: String, message: String) -> some View {
        WorkspaceStateView(title: title, message: message, systemImage: icon) {}
    }
}
