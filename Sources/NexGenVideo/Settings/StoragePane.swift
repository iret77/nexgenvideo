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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            projectsFolderSection

            Divider()
                .overlay(AppTheme.Border.subtleColor)

            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Cache")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Saved playback previews, waveforms, and filmstrip thumbnails. Safe to clear; they'll rebuild as needed.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(displayPath)
                            .font(.system(size: AppTheme.FontSize.xs).monospaced())
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(formattedSize)
                            .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    .padding(.top, AppTheme.Spacing.xs)
                }

                Spacer(minLength: AppTheme.Spacing.lg)

                Button("Clear cache") {
                    clear()
                }
                .controlSize(.small)
                .disabled(isClearing || cacheBytes == 0)
            }

            Divider()
                .overlay(AppTheme.Border.subtleColor)

            searchIndexSection
        }
        .task { await refresh() }
    }

    private var projectsFolderSection: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Projects folder")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Where new projects are created. Existing projects stay wherever they already live.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Project.storageDirectory.path)
                    .font(.system(size: AppTheme.FontSize.xs).monospaced())
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, AppTheme.Spacing.xs)
            }

            Spacer(minLength: AppTheme.Spacing.lg)

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

    private var searchIndexSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Media search")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Indexes media on import so you can search it. Runs on-device.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Toggle("", isOn: $searchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .onChange(of: searchEnabled) { _, newValue in
                        VisualModelLoader.shared.setEnabled(newValue)
                    }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Index")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(ByteCountFormatter.string(fromByteCount: indexBytes, countStyle: .file))
                    .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Button("Clear index") { clearIndex() }
                    .controlSize(.small)
                    .disabled(indexBytes == 0)
            }
            .padding(.top, AppTheme.Spacing.xs)

            if modelBytes > 0 {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("Model")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text("\(SearchIndexConfig.manifest.model) · \(ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file))")
                        .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Button("Remove model") { removeModel() }
                        .controlSize(.small)
                }
            }
        }
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
