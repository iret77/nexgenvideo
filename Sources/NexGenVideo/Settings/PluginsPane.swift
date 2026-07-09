import SwiftUI

/// Settings home for format-pack management — reachable regardless of project state (the title-bar
/// Format chip is format selection/status, not pack updates). Packs auto-update at launch
/// (PluginAutoUpdate); this is where you see installed packs, apply an available update immediately,
/// and finish an update that's staged and waiting for a relaunch.
struct PluginsPane: View {
    @State private var manager = PluginManager()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            packsSection
        }
        .task { await manager.refresh() }
    }

    /// Installed packs only (catalog-only "available"/"unavailable" rows belong to a project's Format
    /// picker, not this management list).
    private var installedRows: [PluginRow] {
        manager.rows(activePluginName: nil).filter { row in
            switch row.status {
            case .installed, .updatePendingRestart, .incompatible: return true
            case .available, .unavailable: return false
            }
        }
    }

    private var packsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Format Packs")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Installed format packs. They update automatically on the next launch; use Update to apply one now. Pick a project's format in its window before starting production.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if installedRows.isEmpty {
                row {
                    Text("No format packs installed yet")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Spacer()
                }
            } else {
                ForEach(installedRows) { rowData in
                    row {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text(rowData.displayName)
                                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                            if let tagline = rowData.tagline {
                                Text(tagline)
                                    .font(.system(size: AppTheme.FontSize.xs))
                                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        actions(rowData)
                    }
                }
            }
        }
    }

    @ViewBuilder private func actions(_ rowData: PluginRow) -> some View {
        if manager.isBusy(rowData.id) {
            ProgressView().controlSize(.small)
        } else {
            switch rowData.status {
            case .updatePendingRestart:
                Button("Restart now") { AppRelaunch.now() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.small)
                    .help("Relaunch NexGenVideo to activate the updated plugin.")
            case .installed(_, let update):
                if let update {
                    Button("Update") { Task { _ = await manager.install(update); await manager.refresh() } }
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .controlSize(.small)
                } else {
                    Text("Up to date")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            case .incompatible(let reason, let reinstall):
                if let reinstall {
                    Button("Update") { Task { _ = await manager.install(reinstall); await manager.refresh() } }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.small)
                } else {
                    Text(reason)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.warningColor)
                        .lineLimit(2)
                }
            case .available, .unavailable:
                EmptyView()
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
