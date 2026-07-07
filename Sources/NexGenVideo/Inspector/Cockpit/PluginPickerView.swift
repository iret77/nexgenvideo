import SwiftUI

/// The format-plugin gallery — the browse/install/activate surface. Packs ship
/// as signed `.ngvpack` bundles OUTSIDE the app: this view fetches the catalog,
/// offers Install/Update, and activates installed packs. Three states per pack —
/// available (Install), installed (Activate/Active, Update when newer), and
/// incompatible (a calm reason line). A catalog fetch failure is offline, not an
/// error: installed packs still show and stay usable.
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
             ? "Offline — showing installed packs. One plugin per project; activating binds the workflow and can be undone any time."
             : "One plugin per project — it drives the production workflow. Installing downloads the pack; activating binds it and can be undone any time.")
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
                VStack(spacing: AppTheme.Spacing.lg) {
                    ForEach(rows) { row in packRow(row) }
                }
                .padding(.bottom, AppTheme.Spacing.md)
            }
        }
    }

    private func packRow(_ row: PluginRow) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            PluginBadgeView(displayName: row.displayName, badgeURL: row.badgeURL)
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    if let tagline = row.tagline {
                        Text(tagline)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    reasonLine(row.status)
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                actions(row)
            }
        }
    }

    @ViewBuilder private func reasonLine(_ status: PluginRow.Status) -> some View {
        switch status {
        case .incompatible(let reason, _), .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Status.warningColor)
                .fixedSize(horizontal: false, vertical: true)
        case .updatePendingRestart:
            Label("Update installed — restart NexGenVideo to use it.", systemImage: "arrow.clockwise.circle")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Status.warningColor)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func actions(_ row: PluginRow) -> some View {
        if manager.isBusy(row.id) {
            ProgressView().controlSize(.small)
        } else {
            switch row.status {
            case .available(let entry):
                Button("Install") { Task { await manager.install(entry) } }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.small)

            case .installed(let active, let update):
                VStack(alignment: .trailing, spacing: AppTheme.Spacing.xs) {
                    if active {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                            .foregroundStyle(AppTheme.Accent.primary)
                    } else {
                        Button("Activate") {
                            withAnimation { editor.setActivePlugin(row.id) }
                            dismiss()
                        }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .controlSize(.small)
                    }
                    if let update {
                        Button("Update") { Task { await manager.install(update) } }
                            .buttonStyle(.capsule(.secondary, size: .regular))
                            .controlSize(.small)
                    }
                }

            case .updatePendingRestart:
                Label("Restart to update", systemImage: "arrow.clockwise")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)

            case .incompatible(_, let reinstall):
                if let reinstall {
                    Button("Update") { Task { await manager.install(reinstall) } }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.small)
                }

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
struct PluginBadgeView: View {
    let displayName: String
    let badgeURL: URL?
    @State private var image: NSImage?

    /// Convenience for an installed/loaded pack.
    init(plugin: InstalledPack) {
        self.displayName = plugin.displayName
        self.badgeURL = plugin.badgeURL
    }

    init(displayName: String, badgeURL: URL?) {
        self.displayName = displayName
        self.badgeURL = badgeURL
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
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
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
