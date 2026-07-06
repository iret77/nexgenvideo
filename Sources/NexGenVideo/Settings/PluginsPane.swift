import SwiftUI

struct PluginsPane: View {
    private let packs: [InstalledPack] = InstalledPack.all

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            packsSection
        }
    }

    private var packsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Format Packs")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Built-in format packs. Activate one per project in Project settings.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if packs.isEmpty {
                row {
                    Text("No format packs available")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Spacer()
                }
            } else {
                ForEach(packs) { pack in
                    row {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text(pack.displayName)
                                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                            if let tagline = pack.tagline {
                                Text(tagline)
                                    .font(.system(size: AppTheme.FontSize.xs))
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            content()
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }
}
