import SwiftUI

struct PluginsPane: View {
    @State private var engineStatus: EngineRuntime.Status = .unavailable
    @State private var plugins: [PluginManager.Plugin] = []
    @State private var audioPlugins: [PluginManager.Plugin] = []
    @State private var audioState: AudioState = .unknown
    @State private var isInstallingAudio: Bool = false

    private enum AudioState: Equatable {
        case unknown        // not yet probed
        case notInstalled
        case installed
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            pluginsSection
        }
        .onAppear(perform: refresh)
    }

    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Plugins")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Installed format packs and their optional capabilities.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plugins.isEmpty {
                runtimeRow {
                    Text("No plugins installed")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Spacer()
                }
            } else {
                ForEach(plugins, id: \.name) { plugin in
                    runtimeRow {
                        Text(plugin.name)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Spacer()
                    }
                }
            }

            audioRow
        }
    }

    private var engineReady: Bool {
        if case .ready = engineStatus { return true }
        return false
    }

    @ViewBuilder
    private var audioRow: some View {
        if engineReady, !audioPlugins.isEmpty {
            runtimeRow {
                Text("Audio analysis")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)

                switch audioState {
                case .installed:
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Audio analysis ready")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer()

                case .failed(let msg):
                    Circle()
                        .fill(AppTheme.Status.errorColor)
                        .frame(width: 8, height: 8)
                    Text(msg)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Try again", action: installAudio)
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .controlSize(.small)

                case .unknown, .notInstalled:
                    if isInstallingAudio {
                        Text("Installing audio analysis…")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Enables beat-accurate analysis (downloads several minutes)")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Enable audio analysis", action: installAudio)
                            .buttonStyle(.capsule(.prominent, size: .regular))
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func refresh() {
        engineStatus = EngineRuntime.status()
        plugins = PluginManager.discoverPlugins()
        audioPlugins = engineReady ? PluginManager.audioExtraPlugins() : []
        refreshAudioState()
    }

    /// Probe whether the audio extra is already present, off the main actor. Cheap-ish (one subprocess)
    /// so it runs on appear / after an install — not on every view refresh.
    private func refreshAudioState() {
        guard engineReady, !audioPlugins.isEmpty else { return }
        Task {
            let present = await EngineRuntime.audioExtraInstalled()
            if !isInstallingAudio {
                audioState = present ? .installed : .notInstalled
            }
        }
    }

    private func installAudio() {
        guard !isInstallingAudio else { return }
        let plugins = audioPlugins
        guard !plugins.isEmpty else { return }
        isInstallingAudio = true
        Task {
            var failure: String? = nil
            for plugin in plugins {
                let result = await EngineRuntime.installExtra(pluginInstallRoot: plugin.installRoot, extra: "audio")
                if case .failed(let msg) = result {
                    failure = msg
                    break
                }
            }
            isInstallingAudio = false
            if let failure {
                audioState = .failed(failure)
            } else {
                let present = await EngineRuntime.audioExtraInstalled()
                audioState = present ? .installed : .failed("Install finished but audio analysis isn't importable.")
            }
        }
    }

    private func runtimeRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
