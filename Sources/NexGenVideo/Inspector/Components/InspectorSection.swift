import SwiftUI

struct InspectorSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.Text.mutedColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct InspectorSectionHeading<Accessory: View>: View {
    let title: String
    var expanded: Bool? = nil
    var onToggle: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
            if let expanded, let onToggle {
                Button(action: onToggle) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .interfaceFont(size: AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.Text.mutedColor)
                            .frame(width: AppTheme.IconSize.xxs)
                        InspectorSectionLabel(title: title)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            } else {
                InspectorSectionLabel(title: title)
            }
            Spacer(minLength: AppTheme.Spacing.xs)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension InspectorSectionHeading where Accessory == EmptyView {
    init(title: String, expanded: Bool? = nil, onToggle: (() -> Void)? = nil) {
        self.init(title: title, expanded: expanded, onToggle: onToggle, accessory: { EmptyView() })
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            InspectorSectionHeading(title: title)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                content()
            }
        }
    }
}
