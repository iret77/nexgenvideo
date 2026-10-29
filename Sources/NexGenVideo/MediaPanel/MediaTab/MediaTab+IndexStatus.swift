import SwiftUI

extension MediaTab {
    @ViewBuilder
    var searchIndexStatus: some View {
        let search = editor.searchIndex
        let model = VisualModelLoader.shared
        switch search.visualAvailability {
        case .notInstalled where hasIndexableAssets:
            statusButton(icon: "sparkle.magnifyingglass", label: "Smart Search") { model.download() }
                .help("Downloads a \(modelSizeLabel) on-device model so you can search media visually.")
                .reviewAcceptanceProbe("media.index.download")
        case .downloading(let fraction):
            statusIndicator("Downloading \(Int(fraction * 100))%",
                            help: "Downloading the on-device model that powers visual search.", progress: fraction)
        case .preparing:
            statusIndicator("Preparing…", help: "Getting the search model ready.")
        case .ready where search.checkingIndex && search.batchTotal == 0:
            statusIndicator("Checking media…", help: "Checking which media needs indexing.")
        case .ready where search.indexingActive:
            statusIndicator("Indexing \(min(search.batchCompleted + 1, search.batchTotal))/\(search.batchTotal)",
                            help: "Analyzing media so you can search it.", progress: search.indexingProgress)
        case .failed(let message):
            statusButton(icon: "exclamationmark.triangle", label: "Retry Smart Search") { model.download() }
                .help(message)
                .reviewAcceptanceProbe("media.index.retry-model")
        default:
            EmptyView()
        }
        if !search.failedAssetIDs.isEmpty {
            Menu {
                ForEach(editor.mediaAssets.filter { search.failedAssetIDs.contains($0.id) }) { asset in
                    Button(asset.libraryDisplayName) {
                        editor.selectMediaAsset(asset)
                        editor.mediaPanelRevealAssetId = asset.id
                    }
                        .help(search.failures[asset.id] ?? "Indexing failed.")
                }
                Divider()
                Button("Retry Failed Items") { search.retryFailed() }
                    .disabled(!search.canRetryFailed)
            } label: {
                Label("\(search.failedAssetIDs.count) indexing failed", systemImage: "exclamationmark.triangle")
            }
            .menuStyle(.borderlessButton)
            .interfaceFont(size: AppTheme.Typography.ui)
            .reviewAcceptanceProbe("media.index.failures", text: String(search.failedAssetIDs.count))
        }
    }

    private var hasIndexableAssets: Bool {
        editor.mediaAssets.contains { $0.type == .video || $0.type == .image }
    }

    private var modelSizeLabel: String {
        let files = SearchIndexConfig.manifest.files
        return ByteCountFormatter.string(fromByteCount: files.imageEncoder.bytes + files.textEncoder.bytes, countStyle: .file)
    }

    private func statusButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: icon, action: action)
            .buttonStyle(.capsule(.secondary))
    }

    private func statusIndicator(_ label: String, help: String, progress: Double? = nil) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let progress {
                progressRing(progress)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(label)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .help(help)
    }

    private func progressRing(_ value: Double) -> some View {
        ZStack {
            Circle()
                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.medium)
            Circle()
                .trim(from: 0, to: max(min(value, 1), 0.03))
                .stroke(AppTheme.Text.secondaryColor,
                        style: StrokeStyle(lineWidth: AppTheme.BorderWidth.medium, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
        .animation(.linear(duration: AppTheme.Anim.transition), value: value)
    }
}
