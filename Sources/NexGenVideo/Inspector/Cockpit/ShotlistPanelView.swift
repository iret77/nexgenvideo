import SwiftUI

// Read-only Shotlist cockpit panel: the latest shotlist as a summary list — one card per shot with its
// id, a short description, and type/framing/duration chips. Loaded via CockpitDataService.shotlist.
// Explicit loading / empty / error / engine-not-ready states. No mutations.

struct ShotlistPanelView: View {
    @Environment(EditorViewModel.self) private var editor

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded(ShotlistData?)
        case failed(CockpitError)
    }

    @State private var state: LoadState = .idle
    @State private var loadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: editor.projectURL) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            centeredProgress()
        case .failed(let error):
            CockpitStateView.error(error, title: "Couldn't load the shotlist",
                                   subject: "the shotlist") { Task { await load() } }
        case .loaded(nil):
            CockpitStateView.empty(icon: "film.stack", title: "No shotlist yet",
                                   message: "This project doesn't have a shotlist.")
        case .loaded(.some(let data)):
            loadedBody(data)
        }
    }

    @ViewBuilder
    private func loadedBody(_ data: ShotlistData) -> some View {
        if data.shots.isEmpty {
            CockpitStateView.empty(icon: "film.stack", title: "No shots",
                                   message: "This shotlist has no shots yet.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    Text("\(data.shots.count) \(data.shots.count == 1 ? "shot" : "shots")")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .tracking(AppTheme.Tracking.wide)
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    ForEach(data.shots) { shot in
                        shotCard(shot)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func shotCard(_ shot: ShotSummary) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(shot.id)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold).monospaced())
                    .foregroundStyle(AppTheme.Text.primaryColor)
                if let section = shot.section?.trimmingCharacters(in: .whitespaces), !section.isEmpty {
                    Text(section)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            let summary = shot.summaryText
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !shot.chips.isEmpty {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(shot.chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .padding(.horizontal, AppTheme.Spacing.sm)
                            .padding(.vertical, AppTheme.Spacing.xxs)
                            .background(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
                            )
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(
                    editor.inspectedObject == .shot(shot.id)
                        ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium)
                        : AppTheme.Border.subtleColor,
                    lineWidth: editor.inspectedObject == .shot(shot.id)
                        ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .onTapGesture { editor.inspectedObject = .shot(shot.id) }
    }

    private func centeredProgress() -> some View {
        VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let dir = editor.studioProjectDir else {
            state = .failed(.noProject)
            return
        }
        loadToken += 1
        let token = loadToken
        state = .loading
        let result = await CockpitDataService.shotlist(projectDir: dir)
        guard token == loadToken else { return }
        switch result {
        case .success(let data): state = .loaded(data)
        case .failure(let error): state = .failed(error)
        }
    }
}
