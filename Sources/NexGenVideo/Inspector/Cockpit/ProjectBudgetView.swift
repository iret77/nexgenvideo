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

/// The budget is a display, never a limit: billed money, provider credits in their own unit, and
/// counts of runs whose cost is unknown. Nothing here signals an error because a cost is unknown.
private struct ProjectBudgetCard: View {
    let data: ProjectStateData

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.mdLg) {
            Text("BUDGET")
                .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)

            budgetBar(fraction: data.spentFraction)

            if let next = data.nextPhaseName, let remaining = data.budgetRemainingEur {
                Text("Next up: \(PhaseDisplay.label(next)) — \(Self.euro(remaining)) of the planning budget unused")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            VStack(spacing: AppTheme.Spacing.smMd) {
                textRow(label: "Planning budget", value: Self.euro(data.budgetEur))
                textRow(label: "Billed spend",
                        value: data.spendComplete ? Self.euro(data.budgetSpentEur) : "at least \(Self.euro(data.budgetSpentEur))",
                        emphasized: true)
                ForEach(data.providerCredits) { credit in
                    textRow(label: "\(credit.providerName) \(credit.unit)",
                            value: "\(Self.amount(credit.amount)) · \(Self.runs(credit.runs))")
                }
                if data.unknownCostRuns > 0 {
                    textRow(label: "Unknown cost", value: Self.runs(data.unknownCostRuns))
                }
                if data.legacyGenerations > 0 {
                    textRow(label: "Legacy runs", value: Self.runs(data.legacyGenerations))
                }
                if data.inFlightRuns > 0 {
                    textRow(label: "Running", value: Self.runs(data.inFlightRuns))
                }
            }

            if !data.providerCredits.isEmpty || data.unknownCostRuns > 0 || data.legacyGenerations > 0 {
                Text("Credits and characters are each provider's own unit. Unknown costs are not estimated.")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
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
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private func budgetBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.faint))
                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                    .fill(AppTheme.Accent.primary)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: AppTheme.Spacing.smMd)
    }

    private func textRow(label: String, value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .interfaceFont(size: AppTheme.Typography.ui,
                              weight: emphasized ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.regular)
                .foregroundStyle(emphasized ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
            Spacer()
            Text(value)
                .interfaceFont(size: AppTheme.Typography.ui,
                               weight: emphasized ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium)
                .monospacedDigit()
                .foregroundStyle(emphasized ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
        }
    }

    static func euro(_ amount: Double) -> String {
        String(format: "€%.2f", amount)
    }

    static func amount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func runs(_ count: Int) -> String {
        count == 1 ? String(localized: "1 run") : String(localized: "\(count) runs")
    }
}

extension ProviderCreditData: Identifiable {
    var id: String { provider + "|" + unit }
}
