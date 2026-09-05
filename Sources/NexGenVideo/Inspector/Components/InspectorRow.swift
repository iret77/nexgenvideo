import SwiftUI

/// `[icon] Label                                    trailing`
struct InspectorRow<Trailing: View>: View {
    let icon: String
    let label: String
    var labelHelp: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: icon)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.xxs, alignment: .leading)
            Text(label)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .foregroundStyle(AppTheme.Text.primaryColor)
            if let labelHelp {
                Image(systemName: "info.circle")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                    .contentShape(Rectangle())
                    .help(labelHelp)
            }
            Spacer()
            trailing()
        }
    }
}

extension InspectorRow where Trailing == EmptyView {
    init(icon: String, label: String) {
        self.init(icon: icon, label: label, trailing: { EmptyView() })
    }
}
