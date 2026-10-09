import AppKit
import SwiftUI

struct WorkspaceStateView<Actions: View>: View {
    var title: String? = nil
    let message: String?
    var systemImage: String? = nil
    var banner: NSImage? = nil
    var fillsSpace = true
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            if let banner {
                Image(nsImage: banner)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                    .accessibilityHidden(true)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .interfaceFont(size: AppTheme.Typography.title)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .accessibilityHidden(true)
            }
            if let title {
                Text(title)
                    .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
            if let message {
                Text(message)
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            actions()
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: AppTheme.ComponentSize.cockpitMessageMaxWidth)
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: fillsSpace ? .infinity : nil)
    }
}

struct ActionSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(title)
                .interfaceFont(size: AppTheme.Typography.section, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.raisedColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }
}

struct ActionLabel: View {
    let title: String
    let systemImage: String
    var acceptanceTextIdentifier: String? = nil

    var body: some View {
        Label {
            Text(title)
                .background {
                    if WorkspaceUIAcceptance.isRequested, let acceptanceTextIdentifier {
                        AppRelaunchClickProbe(identifier: acceptanceTextIdentifier)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                }
        } icon: {
            Image(systemName: systemImage)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActionMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(title)
            Image(systemName: "chevron.down")
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
