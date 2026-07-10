import AppKit
import SwiftUI

// Shared loading / empty / error / engine-not-ready state views for the cockpit panels, factored out
// of the Bible panel's idiom so Pipeline / Shotlist / Sanity / Cost render identical states. Read-only.

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
        // Lead with the pack's own identity when one is active and the project isn't set up yet.
        let showPackHero = (error == .notInitialized) && activePack != nil
        return VStack(spacing: AppTheme.Spacing.md) {
            if showPackHero, let pack = activePack {
                packHero(pack)
            } else {
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
            }
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

    /// The active pack's identity for the not-yet-set-up workspace: its badge art, its bold pitch, and
    /// the benefit line. Makes the empty Produce area read as "you're in the <pack> pipeline" rather than
    /// a generic placeholder. Badge falls back to nothing (the pitch text still carries it).
    @ViewBuilder
    private static func packHero(_ pack: InstalledPack) -> some View {
        if let badge = pack.headerImage() {
            Image(nsImage: badge)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 340, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.lg, style: .continuous)
                        .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
                .padding(.bottom, AppTheme.Spacing.xs)
        }
        Text(pack.headline ?? pack.displayName)
            .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if let benefit = pack.benefit {
            Text(benefit)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
