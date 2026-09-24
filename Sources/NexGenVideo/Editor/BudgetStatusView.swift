import SwiftUI
import NexGenEngine

enum ProjectBudgetLimit: Equatable {
    case notSet
    case unavailable
    case amount(Double)
}

struct ProjectBudgetPresentation: Equatable {
    enum Severity: Equatable {
        case normal
        case warning
        case error
    }

    let spend: ProjectSpendSnapshot?
    let planningBudget: ProjectBudgetLimit
    let hardStop: ProjectBudgetLimit
    let nextPhaseName: String?

    static func make(
        log: GenerationLog,
        generatedInputs: [GenerationInput],
        projectState: ProjectStateData?,
        hasProductionPipeline: Bool
    ) -> Self {
        let planningBudget: ProjectBudgetLimit
        let hardStop: ProjectBudgetLimit
        if let projectState {
            planningBudget = projectState.budgetEur > 0
                ? .amount(projectState.budgetEur)
                : .unavailable
            hardStop = projectState.budgetStopEur.map(ProjectBudgetLimit.amount) ?? .notSet
        } else if hasProductionPipeline {
            planningBudget = .unavailable
            hardStop = .unavailable
        } else {
            planningBudget = .notSet
            hardStop = .notSet
        }

        do {
            return Self(
                spend: try GenerationBudgetGuard.spendSnapshot(
                    log: log,
                    generatedInputs: generatedInputs
                ),
                planningBudget: planningBudget,
                hardStop: hardStop,
                nextPhaseName: projectState?.nextPhaseName
            )
        } catch {
            return Self(
                spend: nil,
                planningBudget: planningBudget,
                hardStop: hardStop,
                nextPhaseName: projectState?.nextPhaseName
            )
        }
    }

    var compactLabel: String {
        guard let spend else { return "Budget unavailable" }
        if !hasRecords {
            return limitsAreUnavailable ? "Budget · No spend · Limits unavailable" : "Budget · No spend"
        }
        let amount = Self.euro(spend.verifiedEur)
        let prefix = spend.isComplete ? "" : "≥"
        var label = "Budget \(prefix)\(amount)"
        switch planningBudget {
        case .amount(let budget):
            label += " / \(Self.euro(budget))"
        case .unavailable:
            label += " · Planning limit unavailable"
        case .notSet:
            break
        }
        switch hardStop {
        case .amount(let stop):
            if spend.verifiedEur >= stop {
                label += " · Stop reached"
            } else if case .amount = planningBudget {
                break
            } else {
                label += " · Stop \(Self.euro(stop))"
            }
        case .unavailable:
            label += " · Stop unavailable"
        default:
            break
        }
        if planningBudget == .notSet && hardStop == .notSet {
            label += " · No limit"
        }
        return label
    }

    var severity: Severity {
        guard let spend else { return .error }
        if limitIsExceeded(planningBudget, spend: spend.verifiedEur)
            || limitIsExceeded(hardStop, spend: spend.verifiedEur) {
            return .error
        }
        if limitsAreUnavailable { return .warning }
        guard spend.isComplete else { return .warning }
        if limitIsLow(planningBudget, spend: spend.verifiedEur)
            || limitIsLow(hardStop, spend: spend.verifiedEur) {
            return .warning
        }
        return .normal
    }

    var warnings: [String] {
        guard let spend else {
            return ["The cost journal cannot be verified. Repair it before relying on budget totals."]
        }
        var result: [String] = []
        if spend.unpricedTransactionCount > 0 {
            appendPricingWarning(.priceUnavailable, label: "provider price", spend: spend, to: &result)
            appendPricingWarning(.currencyUnavailable, label: "currency conversion", spend: spend, to: &result)
            appendPricingWarning(.subscriptionCredits, label: "monetary cost for subscription credits", spend: spend, to: &result)
        }
        if spend.legacyGenerationCount > 0 {
            result.append(
                "\(spend.legacyGenerationCount) legacy generation\(spend.legacyGenerationCount == 1 ? " has" : "s have") no verified monetary record."
            )
        }
        appendLimitWarning("Planning budget", limit: planningBudget, spend: spend.verifiedEur, to: &result)
        appendLimitWarning("Hard stop", limit: hardStop, spend: spend.verifiedEur, to: &result)
        if planningBudget == .unavailable || hardStop == .unavailable {
            result.append("Project limits are still loading or unavailable.")
        }
        return result
    }

    var hasRecords: Bool {
        guard let spend else { return false }
        return !spend.lineItems.isEmpty || spend.legacyGenerationCount > 0
    }

    private var limitsAreUnavailable: Bool {
        planningBudget == .unavailable || hardStop == .unavailable
    }

    var acceptanceValue: String {
        guard let spend else { return "unavailable" }
        return [
            "committed=\(Self.decimal(spend.verifiedEur))",
            "charged=\(Self.decimal(spend.chargedEur))",
            "reserved=\(Self.decimal(spend.openReservationEur))",
            "complete=\(spend.isComplete)",
            "active=\(spend.activeReservationCount)",
            "unpriced=\(spend.unpricedTransactionCount)",
            "legacy=\(spend.legacyGenerationCount)",
            "planning=\(limitToken(planningBudget))",
            "stop=\(limitToken(hardStop))",
            "items=\(spend.lineItems.count)",
        ].joined(separator: ";")
    }

    static func euro(_ amount: Double) -> String {
        String(format: "€%.2f", amount)
    }

    static func decimal(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }

    private func appendLimitWarning(
        _ label: String,
        limit: ProjectBudgetLimit,
        spend: Double,
        to result: inout [String]
    ) {
        guard case .amount(let amount) = limit else { return }
        let remaining = amount - spend
        if remaining < 0 {
            result.append("\(label) exceeded by \(Self.euro(-remaining)).")
        } else if remaining == 0 {
            result.append("\(label) reached.")
        } else if remaining < amount * 0.1 {
            result.append("\(label) has \(Self.euro(remaining)) remaining.")
        }
    }

    private func appendPricingWarning(
        _ status: GenerationPricingStatus,
        label: String,
        spend: ProjectSpendSnapshot,
        to result: inout [String]
    ) {
        let count = spend.lineItems.filter {
            $0.countsTowardGuard && $0.money == nil && $0.pricingStatus == status
        }.count
        guard count > 0 else { return }
        result.append(
            "\(count) open transaction\(count == 1 ? " has" : "s have") no verified \(label)."
        )
    }

    private func limitIsExceeded(_ limit: ProjectBudgetLimit, spend: Double) -> Bool {
        guard case .amount(let amount) = limit else { return false }
        return spend >= amount
    }

    private func limitIsLow(_ limit: ProjectBudgetLimit, spend: Double) -> Bool {
        guard case .amount(let amount) = limit, spend < amount else { return false }
        return amount - spend < amount * 0.1
    }

    private func limitToken(_ limit: ProjectBudgetLimit) -> String {
        switch limit {
        case .notSet: "none"
        case .unavailable: "unknown"
        case .amount(let value): Self.decimal(value)
        }
    }
}

struct EditorStatusBar: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(statusContext)
                .interfaceFont(size: AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Text.mutedColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: AppTheme.Spacing.none, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)

            BudgetStatusButton()
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            AIJobStatusButton()
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            ExportJobStatusButton()
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(maxWidth: .infinity)
        .frame(minHeight: AppTheme.Layout.statusBarHeight)
        .background(AppTheme.Background.raisedColor)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(height: AppTheme.BorderWidth.hairline)
        }
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(
                    identifier: "editor.statusBar",
                    acceptanceValue: statusContext
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
    }

    private var statusContext: String {
        let project = editor.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return "\(project) · \(editor.workspaceFocus.label)"
    }
}

private struct BudgetStatusButton: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var isPresented = false
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var refreshRequest = UUID()

    var body: some View {
        let presentation = presentation
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: budgetSymbol(presentation.severity))
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                Text(presentation.compactLabel)
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.medium)
                    .monospacedDigit()
                    .lineLimit(1)
                    .background {
                        if WorkspaceUIAcceptance.isRequested {
                            AppRelaunchClickProbe(
                                identifier: "editor.status.budget.label",
                                acceptanceValue: presentation.compactLabel
                            )
                            .allowsHitTesting(false)
                        }
                    }
            }
            .foregroundStyle(budgetColor(presentation.severity))
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(minHeight: AppTheme.Control.compactHeight)
            .hoverHighlight(cornerRadius: AppTheme.Radius.xs, isActive: isPresented)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Project budget")
        .accessibilityValue(presentation.compactLabel)
        .help("Show project costs and budget details")
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(
                    identifier: "editor.status.budget",
                    acceptanceState: isPresented,
                    acceptanceValue: presentation.acceptanceValue
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            BudgetDetailPopover(
                presentation: presentation,
                legacyEntries: editor.generationLogEntries.filter { $0.spendTransactionId == nil },
                isRefreshing: isRefreshing,
                refreshError: refreshError,
                refresh: refresh,
                close: { isPresented = false }
            )
        }
        .onChange(of: editor.projectURL) { _, _ in
            refreshRequest = UUID()
            isRefreshing = false
            isPresented = false
            refreshError = nil
        }
    }

    private var presentation: ProjectBudgetPresentation {
        ProjectBudgetPresentation.make(
            log: editor.generationLog,
            generatedInputs: editor.mediaAssets.compactMap(\.generationInput),
            projectState: editor.projectState,
            hasProductionPipeline: editor.hasProductionPipeline
        )
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshError = nil
        let request = UUID()
        let projectURL = editor.projectURL
        refreshRequest = request
        Task { @MainActor in
            do {
                try await editor.refreshBudgetStatus()
            } catch {
                if refreshRequest == request, editor.projectURL == projectURL {
                    refreshError = "Budget details could not be refreshed."
                }
            }
            if refreshRequest == request, editor.projectURL == projectURL {
                isRefreshing = false
            }
        }
    }

    private func budgetSymbol(_ severity: ProjectBudgetPresentation.Severity) -> String {
        switch severity {
        case .normal: "creditcard"
        case .warning, .error: "exclamationmark.triangle.fill"
        }
    }

    private func budgetColor(_ severity: ProjectBudgetPresentation.Severity) -> Color {
        switch severity {
        case .normal: AppTheme.Text.secondaryColor
        case .warning: AppTheme.Status.warningColor
        case .error: AppTheme.Status.errorColor
        }
    }
}

private struct BudgetDetailPopover: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let presentation: ProjectBudgetPresentation
    let legacyEntries: [GenerationLogEntry]
    let isRefreshing: Bool
    let refreshError: String?
    let refresh: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            header
            AppDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    if let spend = presentation.spend {
                        summary(spend)
                        warnings
                        transactions(spend.lineItems)
                        legacyActivity
                    } else {
                        budgetUnavailable
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: AppTheme.ComponentSize.budgetPopoverMaxHeight * interfaceScale)
        }
        .padding(AppTheme.Spacing.mdLg)
        .frame(width: AppTheme.ComponentSize.budgetPopoverWidth * interfaceScale)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Project Budget")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: refresh) {
                Label(isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.inlineAction())
            .disabled(isRefreshing)
            .background {
                if WorkspaceUIAcceptance.isRequested {
                    AppRelaunchClickProbe(
                        identifier: "editor.status.budget.refresh",
                        acceptanceState: isRefreshing
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .accessibilityLabel("Close budget details")
            }
            .buttonStyle(.inlineAction())
            .background {
                if WorkspaceUIAcceptance.isRequested {
                    AppRelaunchClickProbe(identifier: "editor.status.budget.close")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func summary(_ spend: ProjectSpendSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            sectionTitle("Summary")
            amountRow("Charged", amount: spend.chargedEur)
            amountRow(
                spend.unpricedTransactionCount > 0
                    ? "Verified open reservations at least"
                    : "Open reservations",
                amount: spend.openReservationEur,
                suffix: reservationSuffix(spend)
            )
            amountRow(
                spend.isComplete
                    ? "Reserved + charged total"
                    : "Verified reserved + charged total at least",
                amount: spend.verifiedEur,
                emphasized: true,
                acceptanceIdentifier: "editor.status.budget.total"
            )
            budgetProgress(spend)
            limitRow(
                "Planning budget",
                limit: presentation.planningBudget,
                spend: spend,
                acceptanceIdentifier: "editor.status.budget.planning"
            )
            limitRow(
                "Hard stop",
                limit: presentation.hardStop,
                spend: spend,
                acceptanceIdentifier: "editor.status.budget.hardStop"
            )
            if let nextPhaseName = presentation.nextPhaseName {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text("Next phase")
                    Spacer(minLength: AppTheme.Spacing.sm)
                    Text(PhaseDisplay.label(nextPhaseName))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    private func reservationSuffix(_ spend: ProjectSpendSnapshot) -> String? {
        var parts: [String] = []
        if spend.activeReservationCount > 0 {
            parts.append("\(spend.activeReservationCount) open")
        }
        if spend.unpricedTransactionCount > 0 {
            parts.append("\(spend.unpricedTransactionCount) unpriced")
        }
        return parts.isEmpty ? nil : " · " + parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func budgetProgress(_ spend: ProjectSpendSnapshot) -> some View {
        if case .amount(let amount) = presentation.planningBudget,
           amount > 0,
           spend.isComplete {
            ProgressView(value: min(1, max(0, spend.verifiedEur / amount)))
                .tint(spend.verifiedEur >= amount
                    ? AppTheme.Status.errorColor
                    : AppTheme.Status.successColor)
                .accessibilityLabel("Planning budget used")
                .accessibilityValue(
                    "\(ProjectBudgetPresentation.euro(spend.verifiedEur)) of \(ProjectBudgetPresentation.euro(amount))"
                )
        }
    }

    @ViewBuilder
    private var warnings: some View {
        let displayedWarnings = presentation.warnings + (refreshError.map { [$0] } ?? [])
        if !displayedWarnings.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                sectionTitle("Attention")
                ForEach(displayedWarnings, id: \.self) { warning in
                    warningRow(warning)
                }
            }
            .background {
                if WorkspaceUIAcceptance.isRequested {
                    AppRelaunchClickProbe(
                        identifier: "editor.status.budget.warnings",
                        acceptanceValue: displayedWarnings.joined(separator: "\n")
                    )
                    .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func transactions(_ items: [ProjectSpendLineItem]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            sectionTitle("Transactions")
            if items.isEmpty {
                Text("No cost records")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.mutedColor)
            } else {
                ForEach(items) { item in
                    transactionRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private var legacyActivity: some View {
        if !legacyEntries.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                sectionTitle("Legacy activity")
                ForEach(legacyEntries) { entry in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: entry.sfSymbolName)
                            .frame(width: AppTheme.IconSize.xs)
                        Text(entry.modelDisplayName)
                            .lineLimit(1)
                        Spacer(minLength: AppTheme.Spacing.xs)
                        Text("Credits \(CostEstimator.format(entry.costCredits))")
                            .monospacedDigit()
                    }
                    .interfaceFont(size: AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Text("Legacy credits are not treated as money or included in the reserved and charged total.")
                    .interfaceFont(size: AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var budgetUnavailable: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("Budget unavailable", systemImage: "exclamationmark.triangle.fill")
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Status.errorColor)
            Text("The cost journal cannot be verified. No amount is being treated as zero.")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func transactionRow(_ item: ProjectSpendLineItem) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(ModelRegistry.displayName(for: item.model))
                    .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.medium)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                Spacer(minLength: AppTheme.Spacing.xs)
                Text(stateLabel(item))
                    .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
                    .foregroundStyle(stateColor(item))
                    .background {
                        if WorkspaceUIAcceptance.isRequested {
                            AppRelaunchClickProbe(
                                identifier: "editor.status.budget.transactionState",
                                acceptanceValue: stateLabel(item)
                            )
                            .allowsHitTesting(false)
                        }
                    }
            }
            Text("\(item.provider.displayName) · \(billingLabel(item.billing))")
                .interfaceFont(size: AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
            DisclosureGroup("Request details") {
                Text("\(routeLabel(item.transport)) · \(item.endpoint)")
                    .interfaceFont(size: AppTheme.Typography.metadata, design: .monospaced)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .textSelection(.enabled)
            }
            moneyLabel(item)
        }
        .padding(AppTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    @ViewBuilder
    private func moneyLabel(_ item: ProjectSpendLineItem) -> some View {
        if item.state == .released {
            Text("Released · not counted")
                .foregroundStyle(AppTheme.Text.mutedColor)
        } else if let money = item.money {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(ProjectBudgetPresentation.euro(money.eurAmount))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .monospacedDigit()
                Text("\(money.nativeCurrency) \(ProjectBudgetPresentation.decimal(money.nativeAmount)) · converted on \(money.exchangeRateDate)")
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(1)
            }
        } else {
            Text(unpricedLabel(item.pricingStatus))
                .foregroundStyle(AppTheme.Status.warningColor)
        }
    }

    private func unpricedLabel(_ status: GenerationPricingStatus) -> String {
        switch status {
        case .priced: "Monetary record unavailable"
        case .priceUnavailable: "Provider price unavailable"
        case .currencyUnavailable: "Currency conversion unavailable"
        case .subscriptionCredits: "Subscription credits · price in euros unavailable"
        }
    }

    private func amountRow(
        _ label: String,
        amount: Double,
        suffix: String? = nil,
        emphasized: Bool = false,
        acceptanceIdentifier: String? = nil
    ) -> some View {
        let amountText = ProjectBudgetPresentation.euro(amount) + (suffix ?? "")
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
            Spacer(minLength: AppTheme.Spacing.sm)
            Text(amountText)
                .monospacedDigit()
                .foregroundStyle(emphasized ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
        }
        .interfaceFont(
            size: AppTheme.Typography.ui,
            weight: emphasized ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.regular
        )
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .background {
            if WorkspaceUIAcceptance.isRequested, let acceptanceIdentifier {
                AppRelaunchClickProbe(
                    identifier: acceptanceIdentifier,
                    acceptanceValue: "\(label)|\(amountText)"
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func limitRow(
        _ label: String,
        limit: ProjectBudgetLimit,
        spend: ProjectSpendSnapshot,
        acceptanceIdentifier: String
    ) -> some View {
        let description = limitDescription(limit, spend: spend)
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
            Spacer(minLength: AppTheme.Spacing.sm)
            Text(description)
                .monospacedDigit()
                .foregroundStyle(limitColor(limit, spend: spend))
        }
        .interfaceFont(size: AppTheme.Typography.ui)
        .foregroundStyle(AppTheme.Text.tertiaryColor)
        .background {
            if WorkspaceUIAcceptance.isRequested {
                AppRelaunchClickProbe(
                    identifier: acceptanceIdentifier,
                    acceptanceValue: "\(label)|\(description)"
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func limitDescription(_ limit: ProjectBudgetLimit, spend: ProjectSpendSnapshot) -> String {
        switch limit {
        case .notSet:
            "Not set"
        case .unavailable:
            "Unavailable"
        case .amount(let amount):
            let remaining = amount - spend.verifiedEur
            if remaining < 0 {
                let qualifier = spend.isComplete ? "" : "at least "
                return "\(ProjectBudgetPresentation.euro(amount)) · \(qualifier)\(ProjectBudgetPresentation.euro(-remaining)) over"
            }
            guard spend.isComplete else { return "\(ProjectBudgetPresentation.euro(amount)) · remaining unavailable" }
            return "\(ProjectBudgetPresentation.euro(amount)) · \(ProjectBudgetPresentation.euro(remaining)) remaining"
        }
    }

    private func limitColor(_ limit: ProjectBudgetLimit, spend: ProjectSpendSnapshot) -> Color {
        guard case .amount(let amount) = limit else {
            return limit == .unavailable ? AppTheme.Status.warningColor : AppTheme.Text.secondaryColor
        }
        return spend.verifiedEur >= amount ? AppTheme.Status.errorColor : AppTheme.Text.secondaryColor
    }

    private func warningRow(_ warning: String) -> some View {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
            .interfaceFont(size: AppTheme.Typography.metadata)
            .foregroundStyle(AppTheme.Status.warningColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.semibold)
            .tracking(AppTheme.Tracking.wide)
            .foregroundStyle(AppTheme.Text.mutedColor)
    }

    private func stateLabel(_ item: ProjectSpendLineItem) -> String {
        switch item.state {
        case .reserved: "Reserved"
        case .submitted: item.needsAttention ? "Submitted · Check charge" : "Submitted"
        case .charged: "Charged"
        case .released: "Released"
        }
    }

    private func stateColor(_ item: ProjectSpendLineItem) -> Color {
        if item.needsAttention && item.state != .released { return AppTheme.Status.warningColor }
        switch item.state {
        case .reserved, .submitted: AppTheme.Status.warningColor
        case .charged: AppTheme.Status.successColor
        case .released: AppTheme.Text.mutedColor
        }
    }

    private func routeLabel(_ transport: ProviderTransport) -> String {
        switch transport {
        case .api: "Direct API"
        case .mcp: "MCP"
        }
    }

    private func billingLabel(_ billing: BillingMode?) -> String {
        switch billing {
        case .perCall: "Provider account · per request"
        case .subscription: "Provider account · subscription/credits"
        case nil: "Account billing not recorded"
        }
    }
}

private struct AIJobStatusButton: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var isPresented = false

    var body: some View {
        let jobs = currentJobs
        let needsAttention = editor.generationBatchCoordinator.error != nil
        let label = needsAttention
            ? (jobs.isEmpty ? "AI needs attention" : "AI \(jobs.count) running · Check batch")
            : (jobs.isEmpty ? "AI idle" : "AI \(jobs.count) running")
        statusButton(
            identifier: "editor.status.aiJobs",
            label: label,
            systemName: needsAttention ? "exclamationmark.triangle.fill"
                : (jobs.isEmpty ? "sparkles" : "sparkles.rectangle.stack.fill"),
            active: !jobs.isEmpty,
            attention: needsAttention,
            presented: isPresented
        ) { isPresented.toggle() }
        .accessibilityLabel("AI background jobs")
        .accessibilityValue(label)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            jobPopover(
                title: "AI Jobs",
                jobs: jobs,
                attention: needsAttention ? "Generation batch needs attention" : nil,
                empty: "No active AI jobs",
                scale: interfaceScale,
                closeIdentifier: "editor.status.aiJobs.close",
                close: { isPresented = false }
            )
        }
    }

    private var currentJobs: [String] {
        var jobs: [String] = []
        if editor.agentService.isStreaming { jobs.append("Agent is working") }
        if let root = editor.workingRoot.flatMap({ DataRootResolver.dataRoot(of: $0) }),
           let phase = editor.pipelinePhaseRunCoordinator.runningPhase(projectRoot: root) {
            jobs.append("Production · \(PhaseDisplay.label(phase))")
        }
        jobs.append(contentsOf: editor.mediaAssets.filter(\.isGenerating).map(\.generatingLabel))
        return jobs
    }
}

private struct ExportJobStatusButton: View {
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var isPresented = false
    @State private var activityRevision = 0

    var body: some View {
        let _ = activityRevision
        let status = ExportCoordinator.status(for: editor.openWorkingCopyKey)
        let jobs = (status.running ? ["Export is running"] : [])
            + Array(repeating: "Export is waiting", count: status.waiting)
            + (status.otherProjectRunning ? ["Another project is exporting"] : [])
        let label: String = status.running ? "1 export running"
            : status.waiting > 0 ? "\(status.waiting) export\(status.waiting == 1 ? "" : "s") waiting"
            : status.otherProjectRunning ? "Export in other project" : "No exports"
        statusButton(
            identifier: "editor.status.exportJobs",
            label: label,
            systemName: status.running || status.waiting > 0 ? "arrow.up.circle.fill" : "arrow.up.circle",
            active: status.running || status.waiting > 0,
            presented: isPresented
        ) { isPresented.toggle() }
        .accessibilityLabel("Export background jobs")
        .accessibilityValue(label)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            jobPopover(
                title: "Export Jobs",
                jobs: jobs,
                empty: "No active exports",
                scale: interfaceScale,
                closeIdentifier: "editor.status.exportJobs.close",
                close: { isPresented = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportActivityChanged)) { _ in
            activityRevision &+= 1
        }
    }
}

private func statusButton(
    identifier: String,
    label: String,
    systemName: String,
    active: Bool,
    attention: Bool = false,
    presented: Bool,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Label(label, systemImage: systemName)
            .interfaceFont(size: AppTheme.Typography.metadata, weight: AppTheme.FontWeight.medium)
            .foregroundStyle(attention ? AppTheme.Status.warningColor
                : (active ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor))
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(minHeight: AppTheme.Control.compactHeight)
            .hoverHighlight(cornerRadius: AppTheme.Radius.xs)
    }
    .buttonStyle(.plain)
    .background {
        if WorkspaceUIAcceptance.isRequested {
            AppRelaunchClickProbe(
                identifier: identifier,
                acceptanceState: presented,
                acceptanceValue: attention ? "attention" : (active ? "active" : "idle")
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
    }
}

private func jobPopover(
    title: String,
    jobs: [String],
    attention: String? = nil,
    empty: String,
    scale: Double,
    closeIdentifier: String,
    close: @escaping () -> Void
) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(title)
                .interfaceFont(size: AppTheme.Typography.ui, weight: AppTheme.FontWeight.semibold)
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            Button(action: close) {
                Image(systemName: "xmark")
                    .accessibilityLabel("Close \(title.lowercased())")
            }
            .buttonStyle(.inlineAction())
            .background {
                if WorkspaceUIAcceptance.isRequested {
                    AppRelaunchClickProbe(identifier: closeIdentifier)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
        }
        if let attention {
            Label(attention, systemImage: "exclamationmark.triangle.fill")
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Status.warningColor)
        }
        if jobs.isEmpty && attention == nil {
            Text(empty)
                .interfaceFont(size: AppTheme.Typography.ui)
                .foregroundStyle(AppTheme.Text.mutedColor)
        } else {
            ForEach(Array(jobs.enumerated()), id: \.offset) { _, job in
                Label(job, systemImage: "circle.fill")
                    .interfaceFont(size: AppTheme.Typography.ui)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
        }
    }
    .padding(AppTheme.Spacing.mdLg)
    .frame(width: AppTheme.ComponentSize.backgroundJobsPopoverWidth * scale, alignment: .leading)
}
