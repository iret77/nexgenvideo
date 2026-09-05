import SwiftUI

/// Shown once over Home after the app updates to a new version.
struct UpdateOverlay: View {
    let entry: ChangelogEntry
    let changelogURL: URL?
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppTheme.Background.overlayColor.opacity(AppTheme.Opacity.strong)
                    .ignoresSafeArea()
                card
                    .frame(width: AppTheme.ComponentSize.updateOverlayWidth)
                    .frame(maxHeight: max(0, proxy.size.height - AppTheme.Spacing.xxl * 2))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("What's New in v\(entry.version)")
                .interfaceFont(size: AppTheme.Typography.display, weight: AppTheme.FontWeight.light)
                .tracking(AppTheme.Tracking.tight)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .vertical) {
                sectionList
                ScrollView { sectionList }
            }
            HStack {
                if let changelogURL {
                    Link(destination: changelogURL) {
                        HStack(spacing: AppTheme.Spacing.xxs) {
                            Text("Full changelog")
                            Image(systemName: "arrow.up.right")
                        }
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Continue") { onDismiss() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("home.whats-new.continue")
                    .background {
                        if AppRelaunchSelfTest.isRequested {
                            AppRelaunchClickProbe(identifier: "home.whats-new.continue")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(.top, AppTheme.Spacing.lg)
        }
        .padding(AppTheme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
    }

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            ForEach(entry.sections.indices, id: \.self) { i in
                section(entry.sections[i])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ section: ChangelogSection) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let heading = section.heading, !heading.isEmpty {
                Text(heading)
                    .interfaceFont(size: AppTheme.Typography.title, weight: AppTheme.FontWeight.light)
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
            ForEach(section.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                    Text("•")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(item)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
