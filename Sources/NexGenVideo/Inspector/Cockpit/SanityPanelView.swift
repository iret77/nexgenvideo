import SwiftUI

// Read-only Sanity cockpit panel: the consistency-audit findings — a color-coded count-by-level badge
// plus a list of findings (level, code, shot id, message). Loaded via CockpitDataService.sanity, which
// maps the engine's "no shotlist" case to a gentle placeholder. No mutations.

struct SanityPanelView: View {
    @Environment(EditorViewModel.self) private var editor

    private enum LoadState: Equatable {
        case idle
        case loading
        case loaded(SanityData?)
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
            CockpitStateView.error(error, title: "Couldn't run sanity",
                                   subject: "the sanity report",
                                   activePack: InstalledPack.named(editor.activePluginName),
                                   startProduction: { editor.startProduction() },
                                   isStarting: editor.productionStarting) { Task { await load() } }
        case .loaded(nil):
            CockpitStateView.empty(icon: "checklist.unchecked", title: "Nothing to check",
                                   message: "Sanity runs once this project has a shotlist.")
        case .loaded(.some(let data)):
            loadedBody(data)
        }
    }

    @ViewBuilder
    private func loadedBody(_ data: SanityData) -> some View {
        if data.isClean {
            CockpitStateView.empty(icon: "checkmark.seal", title: "All clear",
                                   message: "No consistency issues found.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                    summaryBadge(data)
                    ForEach(data.findings) { finding in
                        findingRow(finding)
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func summaryBadge(_ data: SanityData) -> some View {
        let accent = data.errorCount > 0 ? AppTheme.Status.errorColor
            : (data.warningCount > 0 ? AppTheme.Accent.timecodeColor : AppTheme.Status.successColor)
        return HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: data.errorCount > 0 ? "exclamationmark.octagon.fill"
                  : (data.warningCount > 0 ? "exclamationmark.triangle.fill" : "info.circle.fill"))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(accent)
            Text(data.summary)
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(accent.opacity(AppTheme.Opacity.faint))
        )
    }

    private func findingRow(_ finding: SanityFinding) -> some View {
        let shotID = finding.shotId?.trimmingCharacters(in: .whitespaces)
        let targetShot = (shotID?.isEmpty == false) ? shotID : nil
        let isInspected = targetShot.map { editor.inspectedObject == .shot($0) } ?? false
        return HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
            Image(systemName: icon(for: finding.level))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(color(for: finding.level))
                .frame(width: AppTheme.IconSize.xs)
                .padding(.top, AppTheme.Spacing.xxs)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(finding.code)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold).monospaced())
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .lineLimit(1)
                    if let shot = targetShot {
                        Text(shot)
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .medium).monospaced())
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    Spacer(minLength: 0)
                    if targetShot != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                }
                Text(finding.message)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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
                    isInspected ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium) : AppTheme.Border.subtleColor,
                    lineWidth: isInspected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .onTapGesture {
            // A finding points at a shot — clicking it inspects that shot (docs/UI_UX_CONCEPT.md §4).
            if let shot = targetShot { editor.inspectedObject = .shot(shot) }
        }
    }

    private func icon(for level: SanityLevel) -> String {
        switch level {
        case .error: return "exclamationmark.octagon.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for level: SanityLevel) -> Color {
        switch level {
        case .error: return AppTheme.Status.errorColor
        case .warn: return AppTheme.Accent.timecodeColor
        case .info: return AppTheme.Text.mutedColor
        }
    }

    private func centeredProgress() -> some View {
        VStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard let dir = editor.workingRoot else {
            state = .failed(.noProject)
            return
        }
        loadToken += 1
        let token = loadToken
        state = .loading
        let result = await CockpitDataService.sanity(projectDir: dir)
        guard token == loadToken else { return }
        switch result {
        case .success(let data): state = .loaded(data)
        case .failure(let error): state = .failed(error)
        }
    }
}
