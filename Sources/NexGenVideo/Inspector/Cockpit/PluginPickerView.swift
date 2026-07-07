import SwiftUI

/// The format-plugin gallery, presented as its own sheet — the ONLY browse/activate surface.
/// The Project pane shows just the project's state (active pack or "choose"); this window shows
/// what's installed. Only packs that actually exist appear here — planned packs stay invisible
/// until they ship (their badge masters wait in `docs/design/plugin-badges/`).
struct PluginPickerView: View {
    let editor: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    private let packs = InstalledPack.all

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("Format Plugins")
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            Text("One plugin per project — it drives the production workflow. Activating installs nothing and can be undone any time.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: AppTheme.Spacing.lg) {
                    ForEach(packs) { pack in
                        packRow(pack)
                    }
                }
                .padding(.bottom, AppTheme.Spacing.md)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.ComponentSize.pluginPickerWidth,
               height: AppTheme.ComponentSize.pluginPickerHeight)
    }

    private func packRow(_ pack: InstalledPack) -> some View {
        let isActive = editor.activePluginName == pack.name
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            PluginBadgeView(plugin: pack)
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                if let tagline = pack.tagline {
                    Text(tagline)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Accent.primary)
                } else {
                    Button("Activate") {
                        withAnimation { editor.setActivePlugin(pack.name) }
                        dismiss()
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.small)
                }
            }
        }
    }
}

/// A pack's badge at its native aspect — the owner's uniform badge art when bundled, otherwise a
/// gradient carrying the display name so packs without art still render a proper card.
struct PluginBadgeView: View {
    let plugin: InstalledPack

    var body: some View {
        Group {
            if let image = plugin.headerImage() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                AppTheme.aiGradient
                    .aspectRatio(AppTheme.ComponentSize.pluginBadgeAspect, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(plugin.displayName)
                            .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(AppTheme.Spacing.md)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }
}
