import SwiftUI

/// The collapsed Pipeline — a slim, always-visible strip showing phase · gate · budget. It reads the
/// *same* project state the Pipeline panel renders, in a compact density; clicking it reveals
/// Project → Pipeline (docs/UI_UX_CONCEPT.md §3). It is not a second pipeline widget.
struct StatusStripView: View {
    @Environment(EditorViewModel.self) private var editor

    @State private var data: ProjectStateData?
    @State private var loadToken = 0

    var body: some View {
        Button {
            editor.revealCockpit(.pipeline)
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                if let data {
                    phaseLabel(data)
                    Spacer(minLength: AppTheme.Spacing.sm)
                    budgetLabel(data)
                } else {
                    Text("No project state")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Spacer(minLength: 0)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity)
            .frame(height: Layout.statusStripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AppTheme.Background.raisedColor)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(height: AppTheme.BorderWidth.hairline)
        }
        .task(id: editor.projectURL) { await load() }
    }

    @ViewBuilder
    private func phaseLabel(_ data: ProjectStateData) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: data.isComplete ? "checkmark.seal.fill" : "circle.dotted")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(data.isComplete ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
            Text(statusText(data))
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
        }
    }

    private func statusText(_ data: ProjectStateData) -> String {
        let approved = data.phases.filter(\.approved).count
        let total = data.phases.count
        if data.isComplete { return "Complete · \(total)/\(total)" }
        if let next = data.nextPhaseName { return "\(next.capitalized) · \(approved)/\(total)" }
        return "\(approved)/\(total)"
    }

    @ViewBuilder
    private func budgetLabel(_ data: ProjectStateData) -> some View {
        if data.budgetEur > 0 {
            Text(String(format: "€%.0f / €%.0f", data.budgetSpentEur, data.budgetEur))
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(data.budgetWarning ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
        }
    }

    private func load() async {
        loadToken += 1
        let token = loadToken
        guard let dir = editor.studioProjectDir else {
            data = nil
            return
        }
        let result = await CockpitDataService.projectState(projectDir: dir)
        guard token == loadToken else { return }
        if case .success(let state) = result {
            data = state
        } else {
            data = nil
        }
    }
}
