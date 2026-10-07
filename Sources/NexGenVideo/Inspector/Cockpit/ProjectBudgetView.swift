import SwiftUI

struct ProjectBudgetView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var data: ProjectStateData?
    @State private var unavailable = false

    private struct Identity: Equatable {
        let home: URL?
        let revision: Int
    }

    var body: some View {
        Group {
            if let data {
                ProjectBudgetCard(data: data)
            } else if unavailable {
                Text("Budget information is unavailable. Reopen the project or resolve its pipeline error.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
        .task(id: Identity(home: editor.workingRoot, revision: editor.engineStateRevision)) {
            data = nil
            unavailable = false
            guard let home = editor.workingRoot else { return }
            let result = await CockpitDataService.projectState(projectDir: home)
            guard !Task.isCancelled, editor.workingRoot == home else { return }
            switch result {
            case .success(let value): data = value
            case .failure: unavailable = true
            }
        }
    }
}

private struct ProjectBudgetCard: View {
    let data: ProjectStateData

    var body: some View {
        let warn = data.budgetWarning
        let barColor = warn ? AppTheme.Status.errorColor : AppTheme.Status.successColor
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("BUDGET")
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                    .tracking(AppTheme.Tracking.wide)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Spacer(minLength: AppTheme.Spacing.none)
                if !data.spendComplete {
                    Label("Spend incomplete", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Status.errorColor)
                } else if warn {
                    Label((data.budgetRemainingEur ?? 0) <= 0 ? "Over budget" : "Low budget",
                          systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }

            budgetBar(fraction: data.spentFraction, color: barColor)

            if let next = data.nextPhaseName, let remaining = data.budgetRemainingEur {
                Text("Next up: \(PhaseDisplay.label(next)) — \(String(format: "€%.2f", remaining)) planning budget available")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else if !data.spendComplete {
                Text("Project spend includes unpriced or legacy generation. Remaining amounts are unavailable.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            VStack(spacing: AppTheme.Spacing.smMd) {
                amountRow(label: "Planning budget", amount: data.budgetEur, color: AppTheme.Text.secondaryColor)
                if let stop = data.budgetStopEur {
                    amountRow(label: "Hard stop", amount: stop, color: AppTheme.Text.secondaryColor)
                }
                amountRow(label: data.spendComplete ? "Spend" : "Verified spend at least",
                          amount: data.budgetSpentEur, color: AppTheme.Text.secondaryColor)
                if data.activeReservations > 0 {
                    textRow(label: "Active reservations", value: String(data.activeReservations),
                            color: AppTheme.Text.secondaryColor)
                }
                AppDivider()
                if let remaining = data.budgetRemainingEur {
                    amountRow(label: "Planning remaining", amount: remaining,
                              color: warn ? AppTheme.Status.errorColor : AppTheme.Text.primaryColor,
                              emphasized: true)
                } else {
                    textRow(label: "Planning remaining", value: "Unavailable",
                            color: AppTheme.Status.errorColor, emphasized: true)
                }
                if let remaining = data.hardStopRemainingEur {
                    amountRow(label: "Hard stop remaining", amount: remaining,
                              color: remaining <= 0 ? AppTheme.Status.errorColor : AppTheme.Text.primaryColor,
                              emphasized: true)
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
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private func budgetBar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint))
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: AppTheme.Spacing.smMd)
    }

    private func amountRow(label: String, amount: Double, color: Color, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .interfaceFont(size: AppTheme.Typography.ui,
                              weight: emphasized ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.regular)
                .foregroundStyle(emphasized ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
            Spacer()
            Text(String(format: "€%.2f", amount))
                .interfaceFont(size: emphasized ? AppTheme.FontSize.md : AppTheme.FontSize.sm,
                               weight: emphasized ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium)
                .monospacedDigit()
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

    private func textRow(label: String, value: String, color: Color, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .interfaceFont(size: AppTheme.Typography.ui,
                              weight: emphasized ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.regular)
                .foregroundStyle(emphasized ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
            Spacer()
            Text(value)
                .interfaceFont(size: emphasized ? AppTheme.FontSize.md : AppTheme.FontSize.sm,
                              weight: emphasized ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
    }

}
