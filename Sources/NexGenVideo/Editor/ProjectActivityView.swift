import SwiftUI

/// Scrollable list of AI generations for the current project. A row shows what the provider billed or
/// reported for the run; the catalog's credit figure is only ever shown as an estimate.
struct ProjectActivityView: View {
    let entries: [GenerationLogEntry]
    var outcomes: [String: GenerationSpendOutcome] = [:]

    private var estimatedTotal: Int {
        entries.reduce(0) { $0 + ($1.costCredits ?? 0) }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Text("Project Activity")
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                if !entries.isEmpty {
                    Text("Estimated \(CostEstimator.format(estimatedTotal))")
                        .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }

            if entries.isEmpty {
                Text("No generations yet")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
                .frame(maxHeight: AppTheme.ComponentSize.projectActivityMaxHeight)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(width: AppTheme.ComponentSize.projectActivityWidth)
    }

    private func row(_ entry: GenerationLogEntry) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: entry.sfSymbolName)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.xs)
            Text(costLabel(entry))
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                .monospacedDigit()
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .frame(width: AppTheme.ComponentSize.projectActivityCostWidth, alignment: .leading)
                .help(costHelp(entry))
            Text(entry.modelDisplayName)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AppTheme.Spacing.xs)
            Text(relativeTime(entry.createdAt))
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
        .padding(.horizontal, AppTheme.Spacing.xxs)
    }

    static func costLabel(entry: GenerationLogEntry, outcome: GenerationSpendOutcome?) -> String {
        if let money = outcome?.billedMoney {
            return "€" + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), money.eurAmount)
        }
        if let cost = outcome?.providerCost {
            return "\(cost.amount.formatted(.number.precision(.fractionLength(0...2)))) \(cost.unit)"
        }
        if let credits = entry.costCredits {
            return "est. \(CostEstimator.format(credits))"
        }
        return String(localized: "Cost unknown")
    }

    private func costLabel(_ entry: GenerationLogEntry) -> String {
        Self.costLabel(entry: entry, outcome: entry.spendTransactionId.flatMap { outcomes[$0] })
    }

    private func costHelp(_ entry: GenerationLogEntry) -> String {
        let outcome = entry.spendTransactionId.flatMap { outcomes[$0] }
        if outcome?.billedMoney != nil { return String(localized: "Billed by the provider") }
        if let cost = outcome?.providerCost { return String(localized: "Reported by the provider: \(cost.source)") }
        if entry.costCredits != nil { return String(localized: "Catalog estimate, not a provider charge") }
        return String(localized: "The provider reported no cost for this run")
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

struct ProjectActivityButton: View {
    @Environment(EditorViewModel.self) var editor
    @State private var isPresented = false

    var body: some View {
        Button(action: { isPresented.toggle() }) {
            Image(systemName: "clock.arrow.circlepath")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help("Project Activity · estimated \(CostEstimator.format(editor.totalGenerationCost))")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ProjectActivityView(entries: editor.generationLogEntries, outcomes: editor.generationSpendOutcomes)
        }
    }
}
