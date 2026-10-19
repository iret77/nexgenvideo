import SwiftUI

enum ModelsPaneProjection {
    struct Row: Identifiable, Equatable {
        let id: String
        let displayName: String
        var providers: String = ""
    }

    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let rows: [Row]
    }

    static func sections(
        image: [Row],
        video: [Row],
        audio: [Row],
        upscale: [Row] = [],
        query: String,
        canRun: (String) -> Bool
    ) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func filtered(_ rows: [Row]) -> [Row] {
            rows.filter {
                canRun($0.id) && (q.isEmpty || $0.displayName.lowercased().contains(q)
                    || $0.providers.lowercased().contains(q))
            }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }
        return [
            Section(id: "image", title: "Image", rows: filtered(image)),
            Section(id: "video", title: "Video", rows: filtered(video)),
            Section(id: "audio", title: "Audio", rows: filtered(audio)),
            Section(id: "upscale", title: "Upscaling", rows: filtered(upscale)),
        ].filter { !$0.rows.isEmpty }
    }
}

struct ModelsPane: View {
    private let prefs: ModelPreferences
    private let catalog: ModelCatalog
    private let research: ModelCapabilityResearchController
    private let activation: @MainActor () -> ProviderActivation
    private let openProviders: @MainActor () -> Void
    private let discovery: ModelDiscoveryActions

    init(catalog: ModelCatalog = .shared, preferences: ModelPreferences = .shared,
         research: ModelCapabilityResearchController = .shared,
         activation: @escaping @MainActor () -> ProviderActivation = { .current() },
         openProviders: @escaping @MainActor () -> Void = { SettingsWindowController.shared.show(tab: .providers) },
         discovery: ModelDiscoveryActions = .live) {
        self.catalog = catalog; self.prefs = preferences; self.research = research
        self.activation = activation; self.openProviders = openProviders; self.discovery = discovery
    }

    @State private var query = ""
    @State private var keyRevision = 0

    private var sections: [ModelsPaneProjection.Section] {
        _ = keyRevision
        let activation = activation()
        let image = catalog.image.map { row(id: $0.id, name: $0.displayName, activation: activation) }
        let video = catalog.video.map { row(id: $0.id, name: $0.displayName, activation: activation) }
        let audio = catalog.audio.map { row(id: $0.id, name: $0.displayName, activation: activation) }
        let upscale = catalog.upscale.map { row(id: $0.id, name: $0.displayName, activation: activation) }
        let runnable = Set((image + video + audio + upscale).filter {
            !$0.providers.isEmpty
        }.map(\.id))
        return ModelsPaneProjection.sections(
            image: image,
            video: video,
            audio: audio,
            upscale: upscale,
            query: query,
            canRun: { runnable.contains($0) }
        )
    }

    private func row(id: String, name: String, activation: ProviderActivation) -> ModelsPaneProjection.Row {
        let providers = Set(catalog.settingsBindings(forModelID: id, activation: activation)
            .map { $0.provider.displayName })
        return .init(id: id, displayName: name, providers: providers.sorted().joined(separator: " · "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            ModelCatalogRefreshControl(hasConnection: !activation().active.isEmpty, actions: discovery)
            SettingsSection(
                "Show in generation tools",
                subtitle: "Models from your connected providers are enabled by default."
            ) {
                searchBar
                if sections.isEmpty {
                    SettingsCard {
                        SettingsRow(title: emptyStateText) {
                            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button("Open Providers", action: openProviders)
                            }
                        }
                    }
                }
            }

            ForEach(sections) { section in
                sectionView(section)
            }
            ModelCapabilityResearchPane(catalog: catalog, research: research, activation: activation)
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerKeysChanged)) { _ in
            keyRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelCatalogChanged)) { _ in
            keyRevision += 1
        }
    }

    private var emptyStateText: String {
        guard catalog.isLoaded else { return "Loading models…" }
        if discovery.isRefreshing() { return "Refreshing models…" }
        let hasRunnableModel = (catalog.image.map(\.id) + catalog.video.map(\.id) + catalog.audio.map(\.id) + catalog.upscale.map(\.id))
            .contains { !catalog.settingsBindings(forModelID: $0, activation: activation()).isEmpty }
        guard hasRunnableModel else {
            return activation().active.isEmpty ? "Connect a provider to see its models."
                : "No models are currently available. Refresh models, or review the connection in Providers."
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return "No models match \"\(trimmed)\"." }
        return "Connect a provider to see its models."
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search models or providers", text: $query)
                .reviewAcceptanceProbe("settings.models.search", text: query)
                .textFieldStyle(.plain)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func sectionView(_ section: ModelsPaneProjection.Section) -> some View {
        SettingsSection(section.title) {
            SettingsCard {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    modelRow(row)
                    if index < section.rows.count - 1 {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    private func modelRow(_ row: ModelsPaneProjection.Row) -> some View {
        SettingsRow(title: row.displayName, subtitle: row.providers) {
            Toggle("Show \(row.displayName) in generation tools", isOn: Binding(
                get: { prefs.isEnabled(row.id) },
                set: { prefs.setEnabled(row.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .reviewAcceptanceProbe("settings.models.enabled." + row.id, text: String(prefs.isEnabled(row.id)))
        }
    }
}

struct ModelCatalogRefreshControl: View {
    let hasConnection: Bool
    let actions: ModelDiscoveryActions

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Model list", subtitle: hasConnection
                ? "Refresh models from the providers you've set up. No content is generated."
                : "Connect a provider before refreshing its models.") {
                if actions.isRefreshing() { ProgressView().controlSize(.small) }
                Button(actions.isRefreshing() ? "Refreshing…" : "Refresh models") {
                    guard hasConnection, !actions.isRefreshing() else { return }
                    actions.refresh()
                }
                .disabled(!hasConnection || actions.isRefreshing())
                .reviewAcceptanceProbe("settings.catalog.refresh", state: hasConnection && !actions.isRefreshing())
            }
        }
    }
}
