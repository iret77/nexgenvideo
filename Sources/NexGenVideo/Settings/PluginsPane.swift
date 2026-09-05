import AppKit
import SwiftUI

struct PluginsPane: View {
    let manager: PluginManager
    @State private var pendingRemoval: InstalledPluginVersion?
    @State private var removalError: String?
    @State private var isRemoving = false
    @State private var usageRevision = 0
    @State private var usageModel = PluginUsageSnapshotModel()

    var body: some View {
        SettingsSection(
            "Installed Packs",
            subtitle: "NexGenVideo checks for updates when it opens. Applying an update may require a restart."
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                if let error = removalError ?? manager.lastError {
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
        .sheet(item: $pendingRemoval) { installedVersion in
            PluginRemovalSheet(
                installedVersion: installedVersion,
                presentation: removalPresentation(for: installedVersion),
                isRemoving: isRemoving,
                error: removalError,
                onCancel: { pendingRemoval = nil },
                onRemove: { Task { await remove(installedVersion) } }
            )
        }
        .task { refreshUsageSnapshot() }
        .onChange(of: manager.installedVersions) { _, _ in
            refreshUsageSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pluginInstallationChanged)) { _ in
            refreshUsageSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectRegistryChanged)) { _ in
            refreshUsageSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectDocumentSetChanged)) { _ in
            refreshUsageSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectPackBindingChanged)) { _ in
            refreshUsageSnapshot()
        }
        .onDisappear { usageModel.cancel() }
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
                                .interfaceFont(size: AppTheme.Typography.ui)
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            HStack(spacing: AppTheme.Spacing.sm) {
                                if let tagline = rowData.tagline {
                                    Text(tagline)
                                }
                            }
                            .interfaceFont(size: AppTheme.Typography.ui)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        Spacer(minLength: AppTheme.Spacing.lg)
                        actions(rowData)
                    }
                    .padding(.horizontal, AppTheme.Spacing.mdLg)
                    .padding(.vertical, AppTheme.Spacing.md)
                    ForEach(manager.versions(for: rowData.id)) { installedVersion in
                        SettingsDivider()
                        versionRow(installedVersion)
                    }
                }
            }
        }
    }

    private func versionRow(_ installedVersion: InstalledPluginVersion) -> some View {
        let presentation = removalPresentation(for: installedVersion)
        return SettingsRow(
            title: "Version \(installedVersion.version)",
            subtitle: presentation.subtitle
        ) {
            versionAction(installedVersion, presentation: presentation)
        }
    }

    @ViewBuilder
    private func versionAction(
        _ installedVersion: InstalledPluginVersion,
        presentation: PluginRemovalPresentation
    ) -> some View {
        if !installedVersion.isPresentOnDisk {
            Button("Restart now") { AppRelaunch.now() }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.small)
        } else {
            Button("Remove", role: .destructive) {
                removalError = nil
                pendingRemoval = installedVersion
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.small)
            .disabled(!presentation.canRemove)
            .help(presentation.help)
        }
    }

    private func removalPresentation(
        for installedVersion: InstalledPluginVersion
    ) -> PluginRemovalPresentation {
        PluginRemovalPresentation.resolve(
            installedVersion: installedVersion,
            usage: usageModel.snapshot?.state(for: installedVersion)
        )
    }

    private func refreshUsageSnapshot() {
        usageRevision += 1
        let openProjectRoots = NSDocumentController.shared.documents
            .compactMap { $0 as? VideoProject }
            .map { project in
                [project.editorViewModel.workingRoot, project.fileURL].compactMap { $0 }
            }
        usageModel.refresh(
            installedVersions: manager.installedVersions,
            registryEntries: ProjectRegistry.shared.entries,
            openProjectRoots: openProjectRoots
        )
    }

    private func remove(_ installedVersion: InstalledPluginVersion) async {
        guard !isRemoving else { return }
        isRemoving = true
        removalError = nil
        defer { isRemoving = false }
        let openRoots = NSDocumentController.shared.documents
            .compactMap { $0 as? VideoProject }
            .map { [$0.editorViewModel.workingRoot, $0.fileURL].compactMap { $0 } }
        let revision = usageRevision
        let entries = ProjectRegistry.shared.entries
        let usage = await PluginRemovalPolicy.loadSnapshot(
            installedVersions: manager.installedVersions,
            registryEntries: entries,
            openProjectRoots: openRoots
        )
        let currentRoots = NSDocumentController.shared.documents
            .compactMap { $0 as? VideoProject }
            .map { [$0.editorViewModel.workingRoot, $0.fileURL].compactMap { $0 } }
        guard currentRoots == openRoots, usageRevision == revision else {
            removalError = "Project use changed. Review the installed version and try again."
            refreshUsageSnapshot()
            return
        }
        guard let current = manager.installedVersions.first(where: { $0.id == installedVersion.id }),
              current.bundleURL == installedVersion.bundleURL else {
            removalError = "The installed version changed. Close this dialog and select it again."
            refreshUsageSnapshot()
            return
        }
        let result = PluginRemovalAttempt.perform(
            installedVersion: current,
            usage: usage.state(for: current)
        ) {
            manager.uninstall(current) ? nil : (manager.lastError ?? "Couldn't remove this version. Try again.")
        }
        switch result {
        case .removed(let restartRequired):
            pendingRemoval = nil
            if restartRequired { AppRelaunch.now() }
        case .blocked(let message): removalError = message
        }
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
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
            case .incompatible(let reason, let reinstall):
                if let reinstall {
                    Button("Update") { Task { _ = await manager.install(reinstall); await manager.refresh() } }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .controlSize(.small)
                } else {
                    Text(reason)
                        .interfaceFont(size: AppTheme.Typography.ui)
                        .foregroundStyle(AppTheme.Status.warningColor)
                        .lineLimit(2)
                }
            case .available, .unavailable:
                EmptyView()
            }
        }
    }
}
