import SwiftUI

struct PluginsPane: View {
    let manager: PluginManager

    var body: some View {
        SettingsSection(
            "Installed Packs",
            subtitle: "NexGenVideo checks for updates when it opens. Applying an update may require a restart."
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                if let error = manager.lastError {
                    SettingsCard {
                        SettingsNotice(text: error, systemImage: "exclamationmark.triangle", tone: .error)
                    }
                } else if manager.catalogState == .offline {
                    SettingsCard {
                        SettingsNotice(
                            text: "Update information is unavailable. Installed packs remain usable.",
                            systemImage: "wifi.slash",
                            tone: .neutral
                        )
                    }
                }
                packsCard
            }
        }
    }

    private var installedRows: [PluginRow] {
        manager.rows(activePluginName: nil).filter { row in
            switch row.status {
            case .installed, .updatePendingRestart, .incompatible: return true
            case .available, .unavailable: return false
            }
        }
    }

    @ViewBuilder
    private var packsCard: some View {
        SettingsCard {
            if installedRows.isEmpty {
                SettingsRow(
                    title: "No format packs installed",
                    subtitle: "Choose a format when creating or opening a project to install its pack."
                ) {
                    EmptyView()
                }
            } else {
                ForEach(Array(installedRows.enumerated()), id: \.element.id) { index, rowData in
                    if index > 0 {
                        SettingsDivider()
                    }
                    HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text(rowData.displayName)
                                .font(.system(size: AppTheme.FontSize.md))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            HStack(spacing: AppTheme.Spacing.sm) {
                                if let version = installedVersion(rowData.id) {
                                    Text("Version \(version)")
                                }
                                if let tagline = rowData.tagline {
                                    Text(tagline)
                                }
                            }
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        Spacer(minLength: AppTheme.Spacing.lg)
                        actions(rowData)
                    }
                    .padding(.horizontal, AppTheme.Spacing.mdLg)
                    .padding(.vertical, AppTheme.Spacing.md)
                }
            }
        }
    }

    private func installedVersion(_ id: String) -> String? {
        manager.installed.first { $0.id == id }?.version
    }

    @ViewBuilder private func actions(_ rowData: PluginRow) -> some View {
        if manager.isBusy(rowData.id) {
            ProgressView().controlSize(.small)
        } else {
            switch rowData.status {
            case .updatePendingRestart:
                let isActiveProjectPack = AppState.shared.activeProject?
                    .editorViewModel.activePluginName == rowData.id
                let canApplyUpdate = PluginUpdateCenter.shared.restartTarget(
                    for: rowData.id
                ) != nil
                Button(
                    isActiveProjectPack
                        ? "Upgrade Project"
                        : "Restart now"
                ) {
                    if isActiveProjectPack {
                        AppState.shared.upgradeActiveProjectPack()
                    } else {
                        PluginUpdateCenter.shared.restartToApplyUpdates()
                    }
                }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.small)
                    .disabled(!canApplyUpdate)
                    .help(
                        isActiveProjectPack
                            ? "Upgrade this project to the installed format-pack update."
                            : "Restart NexGenVideo to activate this update."
                    )
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
}
