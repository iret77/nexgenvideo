import AppKit
import SwiftUI

struct StoragePane: View {
    @State private var cacheBytes: Int64 = 0
    @State private var isClearing = false
    @State private var indexBytes: Int64 = 0
    @State private var modelBytes: Int64 = 0
    @State private var searchEnabled = SearchIndexConfig.enabled
    @AppStorage(Project.projectsFolderKey) private var projectsFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            projectsFolderSection
            cacheSection
            searchIndexSection
        }
        .task { await refresh() }
    }

    private var projectsFolderSection: some View {
        SettingsSection("Projects") {
            SettingsCard {
                SettingsRow(
                    title: "Projects folder",
                    subtitle: "New projects are created here. Existing projects stay in their current locations."
                ) {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        if !projectsFolder.isEmpty {
                            Button("Reset") {
                                projectsFolder = ""
                            }
                            .controlSize(.small)
                        }
                        Button("Choose…") { chooseProjectsFolder() }
                            .controlSize(.small)
                    }
                }
                SettingsDivider()
                storageDetailRow(label: "Location", value: Project.storageDirectory.path)
            }
        }
    }

    private var cacheSection: some View {
        SettingsSection("Temporary Files") {
            SettingsCard {
                SettingsRow(
                    title: "Playback cache",
                    subtitle: "Previews, waveforms, and filmstrip thumbnails rebuild automatically."
                ) {
                    Button("Clear cache") { clear() }
                        .controlSize(.small)
                        .disabled(isClearing || cacheBytes == 0)
                }
                SettingsDivider()
                storageDetailRow(label: "Location", value: displayPath, trailing: formattedSize)
            }
        }
    }

    private var searchIndexSection: some View {
        SettingsSection("Media Search") {
            SettingsCard {
                SettingsToggleRow(
                    title: "Index imported media",
                    subtitle: "Builds an on-device visual index so media can be searched by content.",
                    isOn: $searchEnabled
                )
                .onChange(of: searchEnabled) { _, newValue in
                    VisualModelLoader.shared.setEnabled(newValue)
                }
                SettingsDivider()
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("Search index")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer(minLength: AppTheme.Spacing.lg)
                    Text(ByteCountFormatter.string(fromByteCount: indexBytes, countStyle: .file))
                        .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Button("Clear index") { clearIndex() }
                        .controlSize(.small)
                        .disabled(indexBytes == 0)
                }
                .padding(.horizontal, AppTheme.Spacing.mdLg)
                .padding(.vertical, AppTheme.Spacing.smMd)

                if modelBytes > 0 {
                    SettingsDivider()
                    HStack(spacing: AppTheme.Spacing.sm) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                            Text("Search model")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                            Text(SearchIndexConfig.manifest.model)
                                .font(.system(size: AppTheme.FontSize.xs).monospaced())
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        Spacer(minLength: AppTheme.Spacing.lg)
                        Text(ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file))
                            .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Button("Remove model") { removeModel() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, AppTheme.Spacing.mdLg)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                }
            }
        }
    }

    private func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = Project.storageDirectory
        if panel.runModal() == .OK, let url = panel.url {
            // Only changes where NEW projects are created; the known-projects list is app-global
            // (Application Support), independent of the projects folder.
            projectsFolder = url.path
        }
    }

    private func storageDetailRow(label: String, value: String, trailing: String? = nil) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs).monospaced())
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.lg)
            if let trailing {
                Text(trailing)
                    .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private nonisolated static let caches = [ImageVideoGenerator.cache, MediaVisualCache.diskCache]

    private var displayPath: String {
        DiskCache.rootDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var formattedSize: String {
        if isClearing { return "Clearing…" }
        return ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private func clear() {
        isClearing = true
        Task.detached {
            for cache in Self.caches { cache.clear() }
            await MainActor.run { isClearing = false }
            await refresh()
        }
    }

    private func clearIndex() {
        Task {
            await SearchIndexCoordinator.clearIndexGlobally()
            await refresh()
        }
    }

    private func removeModel() {
        Task {
            await VisualModelLoader.shared.remove()
            await refresh()
        }
    }

    private func refresh() async {
        let sizes = await Task.detached {
            (
                cache: Self.caches.reduce(0) { $0 + $1.size() },
                index: DiskCache.bytes(at: EmbeddingStore.directory),
                model: DiskCache.bytes(at: ModelDownloader.modelsDir)
            )
        }.value
        cacheBytes = sizes.cache
        indexBytes = sizes.index
        modelBytes = sizes.model
    }
}
