import SwiftUI

enum ModelsPaneProjection {
    struct Row: Identifiable, Equatable {
        let id: String
        let displayName: String
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
        query: String,
        canRun: (String) -> Bool
    ) -> [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func filtered(_ rows: [Row]) -> [Row] {
            rows.filter { canRun($0.id) && (q.isEmpty || $0.displayName.lowercased().contains(q)) }
        }
        return [
            Section(id: "image", title: "Image", rows: filtered(image)),
            Section(id: "video", title: "Video", rows: filtered(video)),
            Section(id: "audio", title: "Audio", rows: filtered(audio)),
        ].filter { !$0.rows.isEmpty }
    }
}

struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared

    @State private var query = ""
    /// Bumped when provider keys change so availability (which reads the keychain) re-renders live.
    @State private var keyRevision = 0

    private var sections: [ModelsPaneProjection.Section] {
        _ = keyRevision
        let image = catalog.image.map { ModelsPaneProjection.Row(id: $0.id, displayName: $0.displayName) }
        let video = catalog.video.map { ModelsPaneProjection.Row(id: $0.id, displayName: $0.displayName) }
        let audio = catalog.audio.map { ModelsPaneProjection.Row(id: $0.id, displayName: $0.displayName) }
        let runnable = Set((image + video + audio).filter {
            GenerationProvider.canRun(modelId: $0.id)
        }.map(\.id))
        return ModelsPaneProjection.sections(
            image: image,
            video: video,
            audio: audio,
            query: query,
            canRun: { runnable.contains($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            SettingsSection(
                "Model Visibility",
                subtitle: "Only models available through a connected provider are shown."
            ) {
                searchBar
                if sections.isEmpty {
                    SettingsCard {
                        SettingsRow(title: emptyStateText) {
                            EmptyView()
                        }
                    }
                }
            }

            ForEach(sections) { section in
                sectionView(section)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .providerKeysChanged)) { _ in
            keyRevision += 1
        }
    }

    private var emptyStateText: String {
        guard catalog.isLoaded else { return "Loading models…" }
        let hasRunnableModel = (catalog.image.map(\.id) + catalog.video.map(\.id) + catalog.audio.map(\.id))
            .contains { GenerationProvider.canRun(modelId: $0) }
        guard hasRunnableModel else { return "Activate a provider in Providers to see its models." }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return "No models match \"\(trimmed)\"." }
        return "Activate a provider in Providers to see its models."
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
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
        HStack(spacing: AppTheme.Spacing.md) {
            Text(row.displayName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.lg)
            Toggle("", isOn: Binding(
                get: { prefs.isEnabled(row.id) },
                set: { prefs.setEnabled(row.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
    }
}
