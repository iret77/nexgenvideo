import SwiftUI

/// The format-plugin gallery — the browse/activate surface. Packs ship as signed
/// `.ngvpack` bundles OUTSIDE the app: this view fetches the catalog and binds a
/// pack to the project. One primary action, `Activate`: for a catalog pack it
/// downloads (a hidden "Installing…" step) then binds; for an installed pack it
/// binds instantly. The active pack shows a checkmark plus `Remove`; a newer catalog
/// build offers `Update`. A catalog fetch failure is offline, not an error: installed
/// packs still show and stay usable.
struct PluginPickerView: View {
    let editor: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var manager = PluginManager()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            header
            subtitle
            if let error = manager.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: AppTheme.ComponentSize.pluginPickerWidth,
               height: AppTheme.ComponentSize.pluginPickerHeight)
        .task { await manager.refresh() }
    }

    private var header: some View {
        HStack {
            Text("Format Plugins")
                .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            if manager.catalogState == .loading {
                ProgressView().controlSize(.small).padding(.leading, AppTheme.Spacing.xs)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private var subtitle: some View {
        let offline = manager.catalogState == .offline
        Text(offline
             ? "Offline. Showing the workflows already installed for this project."
             : "Choose the workflow for this project.")
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        let rows = manager.rows(activePluginName: editor.activePluginName)
        if rows.isEmpty {
            VStack(spacing: AppTheme.Spacing.sm) {
                Spacer()
                Text(manager.catalogState == .loading ? "Loading the plugin library…" : "No plugins available yet.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns(count: rows.count),
                          alignment: .leading, spacing: AppTheme.Spacing.md) {
                    ForEach(rows) { row in packCard(row) }
                }
                .padding(.bottom, AppTheme.Spacing.md)
            }
        }
    }

    /// Responsive grid: ~2 auto-fit columns at the picker width, but a lone pack fills
    /// the width comfortably instead of sitting half-width in a two-column grid.
    private func gridColumns(count: Int) -> [GridItem] {
        if count == 1 {
            return [GridItem(.flexible(), alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: AppTheme.ComponentSize.pluginCardMinWidth, maximum: .infinity),
                         spacing: AppTheme.Spacing.md, alignment: .top)]
    }

    /// A pack card: the badge as a full-bleed header, then a compact body with a bold
    /// pitch, a short benefit line, and the state control pinned to the bottom so cards
    /// in a row stay aligned.
    private func packCard(_ row: PluginRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PluginBadgeView(displayName: row.displayName, badgeURL: row.badgeURL, chrome: false)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    if let pitch = row.pitch {
                        Text(pitch)
                            .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let benefit = row.benefitLine {
                        Text(benefit)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                reasonLine(row.status)
                Spacer(minLength: 0)
                actions(row)
            }
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    @ViewBuilder private func reasonLine(_ status: PluginRow.Status) -> some View {
        switch status {
        case .incompatible(let reason, _), .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Status.warningColor)
                .fixedSize(horizontal: false, vertical: true)
        case .updatePendingRestart:
            Label("Update ready — restart to finish. A plugin's code can't be swapped while the app runs.", systemImage: "arrow.clockwise.circle")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Accent.primary)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func actions(_ row: PluginRow) -> some View {
        if manager.isBusy(row.id) {
            HStack(spacing: AppTheme.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Installing…")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        } else {
            switch row.status {
            case .available(let entry):
                // The single primary action: install (a hidden progress step) then bind.
                Button("Activate") {
                    Task {
                        if await manager.install(entry) {
                            withAnimation { editor.setActivePlugin(entry.id) }
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.small)

            case .installed(let active, let update):
                if active {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                            .foregroundStyle(AppTheme.Accent.primary)
                        if let update {
                            Button("Update") { Task { await manager.install(update) } }
                                .buttonStyle(.capsule(.secondary, size: .regular))
                                .controlSize(.small)
                        }
                        Button("Remove") { withAnimation { editor.setActivePlugin(nil) } }
                            .buttonStyle(.capsule(.secondary, size: .regular))
                            .controlSize(.small)
                            .help("Back to the generic workflow. Pipeline data stays in the project.")
                    }
                } else {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Button("Activate") {
                            withAnimation { editor.setActivePlugin(row.id) }
                            dismiss()
                        }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .controlSize(.small)
                        if let update {
                            Button("Update") { Task { await manager.install(update) } }
                                .buttonStyle(.capsule(.secondary, size: .regular))
                                .controlSize(.small)
                        }
                    }
                }

            case .incompatible(_, let reinstall):
                if let reinstall {
                    Button("Update") { Task { await manager.install(reinstall) } }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.small)
                }

            case .updatePendingRestart:
                Button("Restart now") { AppRelaunch.now() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.small)
                    .help("Relaunch NexGenVideo to activate the updated plugin.")

            case .unavailable:
                EmptyView()
            }
        }
    }
}

/// A pack's badge at its native aspect — the owner's uniform badge art when
/// available (local for installed packs, a remote catalog badge before install),
/// otherwise a gradient carrying the display name. Art loads asynchronously off the
/// main thread through `BadgeImageStore`; the gradient is the placeholder meanwhile.
/// `chrome` draws the badge's own rounded border; pass `false` when a card supplies
/// the rounding (the full-bleed header).
struct PluginBadgeView: View {
    let displayName: String
    let badgeURL: URL?
    var chrome: Bool = true
    @State private var image: NSImage?

    /// Convenience for an installed/loaded pack.
    init(plugin: InstalledPack, chrome: Bool = true) {
        self.displayName = plugin.displayName
        self.badgeURL = plugin.badgeURL
        self.chrome = chrome
    }

    init(displayName: String, badgeURL: URL?, chrome: Bool = true) {
        self.displayName = displayName
        self.badgeURL = badgeURL
        self.chrome = chrome
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                AppTheme.aiGradient
                    .aspectRatio(AppTheme.ComponentSize.pluginBadgeAspect, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        Text(displayName)
                            .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(AppTheme.Spacing.md)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: chrome ? AppTheme.Radius.md : 0, style: .continuous))
        .overlay {
            if chrome {
                RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            }
        }
        .task(id: badgeURL) {
            guard let badgeURL else { image = nil; return }
            if let hit = BadgeImageStore.shared.cached(badgeURL) {
                image = hit
                return
            }
            image = nil  // gradient placeholder while the art loads
            image = await BadgeImageStore.shared.image(for: badgeURL)
        }
    }
}
