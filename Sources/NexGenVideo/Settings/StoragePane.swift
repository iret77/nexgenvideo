import AppKit
import SwiftUI

@MainActor
struct StorageSettingsServices {
    struct Sizes: Sendable { let cache: Int64; let index: Int64; let model: Int64 }
    let cacheDirectory: URL
    let projectsDirectory: () -> URL
    let searchEnabled: () -> Bool
    let setSearchEnabled: (Bool) -> Void
    let modelName: String
    let sizes: () async -> Sizes
    let clearCache: () async throws -> Void
    let clearIndex: () async throws -> Void
    let removeModel: () async throws -> Void

    static var live: Self {
        .init(cacheDirectory: DiskCache.rootDirectory, projectsDirectory: { Project.storageDirectory },
            searchEnabled: { SearchIndexConfig.enabled }, setSearchEnabled: { VisualModelLoader.shared.setEnabled($0) },
            modelName: SearchIndexConfig.manifest.model,
            sizes: { await Task.detached {
                Sizes(cache: [ImageVideoGenerator.cache, MediaVisualCache.diskCache].reduce(0) { $0 + $1.size() },
                    index: DiskCache.bytes(at: EmbeddingStore.directory), model: DiskCache.bytes(at: ModelDownloader.modelsDir))
            }.value }, clearCache: { try await Task.detached {
                for cache in [ImageVideoGenerator.cache, MediaVisualCache.diskCache] {
                    do {
                        for entry in try FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) {
                            do { try FileManager.default.removeItem(at: entry) }
                            catch let error as CocoaError where error.code == .fileNoSuchFile { }
                        }
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
                }
            }.value }, clearIndex: { try await SearchIndexCoordinator.clearIndexGloballyChecked() },
            removeModel: { try await VisualModelLoader.shared.removeChecked() })
    }
}

struct StoragePane: View {
    private let services: StorageSettingsServices
    @State private var cacheBytes: Int64 = 0
    @State private var isClearing = false
    @State private var failure: String?
    @State private var indexBytes: Int64 = 0
    @State private var modelBytes: Int64 = 0
    @State private var searchEnabled: Bool
    @AppStorage(Project.projectsFolderKey) private var projectsFolder = ""

    init(services: StorageSettingsServices = .live, defaults: UserDefaults = .standard) {
        self.services = services
        _searchEnabled = State(initialValue: services.searchEnabled())
        _projectsFolder = AppStorage(wrappedValue: "", Project.projectsFolderKey, store: defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            projectsFolderSection
            if let failure {
                SettingsNotice(text: failure, systemImage: "exclamationmark.triangle", tone: .error)
                    .reviewAcceptanceProbe("settings.storage.error", text: failure)
            }
            cacheSection
            searchIndexSection
        }
        .task { await refresh() }
        .disabled(isClearing)
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
                            .reviewAcceptanceProbe("settings.storage.folder.reset")
                            .controlSize(.small)
                        }
                        Button("Choose…") { chooseProjectsFolder() }
                            .reviewAcceptanceProbe("settings.storage.folder.choose")
                            .controlSize(.small)
                    }
                }
                SettingsDivider()
                storageDetailRow(label: "Location", value: services.projectsDirectory().path)
                    .reviewAcceptanceProbe("settings.storage.folder", text: services.projectsDirectory().path)
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
                        .reviewAcceptanceProbe("settings.storage.cache.clear")
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
                    services.setSearchEnabled(newValue)
                }
                .reviewAcceptanceProbe("settings.storage.search", text: String(searchEnabled))
                SettingsDivider()
                SettingsRow(title: "Search index") {
                    Text(ByteCountFormatter.string(fromByteCount: indexBytes, countStyle: .file))
                        .interfaceFont(size: AppTheme.Typography.ui).monospacedDigit()
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Button("Clear index") { clearIndex() }
                        .reviewAcceptanceProbe("settings.storage.index.clear")
                        .disabled(indexBytes == 0)
                }

                if modelBytes > 0 {
                    SettingsDivider()
                    SettingsRow(title: "Search model", subtitle: services.modelName) {
                        Text(ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file))
                            .interfaceFont(size: AppTheme.Typography.ui).monospacedDigit()
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Button("Remove model") { removeModel() }
                            .reviewAcceptanceProbe("settings.storage.model.remove")
                    }
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
        panel.directoryURL = services.projectsDirectory()
        if panel.runModal() == .OK, let url = panel.url {
            projectsFolder = url.path
        }
    }

    private func storageDetailRow(label: String, value: String, trailing: String? = nil) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Text(value)
                .interfaceFont(size: AppTheme.Typography.ui, design: .monospaced)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.lg)
            if let trailing {
                Text(trailing)
                    .interfaceFont(size: AppTheme.Typography.ui).monospacedDigit()
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    private var displayPath: String {
        services.cacheDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var formattedSize: String {
        if isClearing { return "Updating…" }
        return ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private func clear() { perform { try await services.clearCache() } }

    private func clearIndex() { perform { try await services.clearIndex() } }

    private func removeModel() { perform { try await services.removeModel() } }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isClearing else { return }
        isClearing = true
        failure = nil
        Task {
            do { try await action() }
            catch { failure = error.localizedDescription }
            await refresh()
            isClearing = false
        }
    }

    private func refresh() async {
        let sizes = await services.sizes()
        cacheBytes = sizes.cache
        indexBytes = sizes.index
        modelBytes = sizes.model
    }
}
