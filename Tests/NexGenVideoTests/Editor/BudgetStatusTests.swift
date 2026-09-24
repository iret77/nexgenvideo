import Foundation
import NexGenEngine
import Testing

@testable import NexGenVideo

@MainActor
@Suite("Permanent project budget status")
struct BudgetStatusTests {
    @Test("empty spend and a verified zero charge remain distinct")
    func emptyAndZeroAreDistinct() throws {
        let state = try projectState(budget: 10, stop: 12)
        let empty = ProjectBudgetPresentation.make(
            log: GenerationLog(),
            generatedInputs: [],
            projectState: state,
            hasProductionPipeline: true
        )
        let zero = ProjectBudgetPresentation.make(
            log: log(transaction(id: "zero", money: money(0), final: .charged)),
            generatedInputs: [],
            projectState: state,
            hasProductionPipeline: true
        )

        #expect(empty.compactLabel == "Budget · No spend")
        #expect(zero.compactLabel == "Budget €0.00 / €10.00")
        #expect(empty.acceptanceValue.contains("items=0"))
        #expect(zero.acceptanceValue.contains("items=1"))
    }

    @Test("missing project limits are unavailable while a generic project has no limit")
    func missingAndAbsentLimitsAreDistinct() throws {
        let missingState = try JSONDecoder().decode(ProjectStateData.self, from: Data("""
        {"project":"legacy","mode":"beat","phases":[]}
        """.utf8))
        let unavailable = ProjectBudgetPresentation.make(
            log: GenerationLog(),
            generatedInputs: [],
            projectState: missingState,
            hasProductionPipeline: true
        )
        let notSet = ProjectBudgetPresentation.make(
            log: GenerationLog(),
            generatedInputs: [],
            projectState: nil,
            hasProductionPipeline: false
        )

        #expect(unavailable.planningBudget == .unavailable)
        #expect(unavailable.compactLabel == "Budget · No spend · Limits unavailable")
        #expect(unavailable.acceptanceValue.contains("planning=unknown"))
        #expect(notSet.planningBudget == .notSet)
        #expect(notSet.compactLabel == "Budget · No spend")
        #expect(notSet.acceptanceValue.contains("planning=none"))

        let charged = log(transaction(id: "known", money: money(2), final: .charged))
        #expect(ProjectBudgetPresentation.make(log: charged, generatedInputs: [],
            projectState: missingState, hasProductionPipeline: true).compactLabel
            == "Budget €2.00 · Planning limit unavailable")
        #expect(ProjectBudgetPresentation.make(log: charged, generatedInputs: [],
            projectState: nil, hasProductionPipeline: true).compactLabel
            == "Budget €2.00 · Planning limit unavailable · Stop unavailable")
        #expect(ProjectBudgetPresentation.make(log: charged, generatedInputs: [],
            projectState: nil, hasProductionPipeline: false).compactLabel
            == "Budget €2.00 · No limit")
    }

    @Test("guard snapshot owns charged, reserved, released, route, and billing truth")
    func snapshotPreservesGuardTruthAndRouting() throws {
        var events = transaction(id: "charged", money: money(2), final: .charged)
        events += transaction(
            id: "reserved",
            money: money(3),
            final: .reserved,
            transport: .mcp,
            billing: .subscription
        )
        events += transaction(id: "released", money: money(7), final: .released)
        let snapshot = try GenerationBudgetGuard.spendSnapshot(
            log: log(events),
            generatedInputs: []
        )

        #expect(snapshot.chargedEur == 2)
        #expect(snapshot.openReservationEur == 3)
        #expect(snapshot.verifiedEur == 5)
        #expect(snapshot.activeReservationCount == 1)
        #expect(snapshot.lineItems.count == 3)
        #expect(snapshot.lineItems.first(where: { $0.id == "reserved" })?.transport == .mcp)
        #expect(snapshot.lineItems.first(where: { $0.id == "reserved" })?.billing == .subscription)
        #expect(snapshot.lineItems.first(where: { $0.id == "released" })?.countsTowardGuard == false)
    }

    @Test("low and exceeded limits produce explicit warning states")
    func limitWarningsAreExplicit() throws {
        let state = try projectState(budget: 10, stop: 12)
        let low = ProjectBudgetPresentation.make(
            log: log(transaction(id: "low", money: money(9.25), final: .charged)),
            generatedInputs: [],
            projectState: state,
            hasProductionPipeline: true
        )
        let exceeded = ProjectBudgetPresentation.make(
            log: log(transaction(id: "over", money: money(12.5), final: .charged)),
            generatedInputs: [],
            projectState: state,
            hasProductionPipeline: true
        )

        #expect(low.severity == .warning)
        #expect(low.warnings.contains { $0.hasPrefix("Planning budget has") })
        #expect(exceeded.severity == .error)
        #expect(exceeded.warnings.contains { $0.hasPrefix("Planning budget exceeded") })
        #expect(exceeded.warnings.contains { $0.hasPrefix("Hard stop exceeded") })
    }

    @Test("unavailable price, currency, and subscription credits stay separate and never become zero")
    func unpricedReasonsStaySeparate() throws {
        var events = transaction(
            id: "price",
            money: nil,
            final: .reserved,
            pricingStatus: .priceUnavailable
        )
        events += transaction(
            id: "currency",
            money: nil,
            final: .reserved,
            pricingStatus: .currencyUnavailable
        )
        events += transaction(
            id: "credits",
            money: nil,
            final: .reserved,
            transport: .mcp,
            billing: .subscription,
            pricingStatus: .subscriptionCredits
        )
        let presentation = ProjectBudgetPresentation.make(
            log: log(events),
            generatedInputs: [],
            projectState: try projectState(budget: 10, stop: nil),
            hasProductionPipeline: true
        )

        #expect(presentation.spend?.verifiedEur == 0)
        #expect(presentation.spend?.isComplete == false)
        #expect(presentation.compactLabel == "Budget ≥€0.00 / €10.00")
        #expect(presentation.warnings.contains { $0.contains("provider price") })
        #expect(presentation.warnings.contains { $0.contains("currency conversion") })
        #expect(presentation.warnings.contains { $0.contains("subscription/credit") })
        let statuses = Set(presentation.spend?.lineItems.map(\.pricingStatus) ?? [])
        #expect(statuses == Set([
            .priceUnavailable,
            .currencyUnavailable,
            .subscriptionCredits,
        ]))
    }

    @Test("read-only refresh preserves the exact prepared spend approval and journal bytes")
    func refreshPreservesPreparedApprovalAndJournal() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "budget-refresh-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        try Fixtures.prepareProjectPackage(at: package)
        let editor = EditorViewModel()
        editor.projectURL = package
        defer {
            editor.agentService.declineSpend()
            editor.releaseWorkingCopy()
            try? FileManager.default.removeItem(at: package)
        }
        let workingRoot = try #require(editor.workingRoot)
        let logURL = workingRoot.appendingPathComponent(Project.generationLogFilename)
        let beforeBytes = try Data(contentsOf: logURL)
        let option = SpendOption(
            modelId: "higgsfield/acceptance-video",
            modelName: "Acceptance video",
            target: target(transport: .api, billing: .perCall),
            credits: nil,
            requiresCatalogAvailability: false
        )
        let approval = SpendApproval(
            id: "prepared-request",
            recommendedOptionId: option.id,
            options: [option],
            actionLabel: "Generate video"
        )
        _ = try editor.agentService.requestSpendApproval(
            approval,
            origin: .direct,
            editor: editor,
            execute: { _, _ in .ok("unexpected") }
        )

        try await editor.refreshBudgetStatus()

        #expect(editor.agentService.pendingSpendApproval == approval)
        #expect(try Data(contentsOf: logURL) == beforeBytes)
    }

    @Test("project switch clears the previous journal before asynchronous refresh")
    func projectSwitchClearsPreviousBudget() async throws {
        let first = try package(named: "first")
        let second = try package(named: "second")
        let editor = EditorViewModel()
        editor.projectURL = first
        defer {
            editor.releaseWorkingCopy()
            for url in [first, second] {
                if let key = ProjectIdentity.existingKey(for: url) {
                    ProjectWorkingCopy.discard(key: key)
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
        let firstLog = log(transaction(id: "first-charge", money: money(6), final: .charged))
        let firstRoot = try #require(editor.workingRoot)
        try JSONEncoder().encode(firstLog).write(
            to: firstRoot.appendingPathComponent(Project.generationLogFilename),
            options: .atomic
        )
        editor.generationLog = firstLog

        editor.projectURL = second

        #expect(editor.generationLog == GenerationLog())
        #expect(editor.projectState == nil)
        try await editor.refreshBudgetStatus()
        #expect(editor.generationLog == GenerationLog())
    }

    @Test("a paused refresh cannot replace a reservation written after its read")
    func refreshKeepsConcurrentReservation() async throws {
        let project = try package(named: "race")
        let editor = EditorViewModel()
        editor.projectURL = project
        defer {
            editor.releaseWorkingCopy()
            if let key = ProjectIdentity.existingKey(for: project) {
                ProjectWorkingCopy.discard(key: key)
            }
            try? FileManager.default.removeItem(at: project)
        }
        let gate = PausedBudgetLoad()
        let refresh = Task {
            try await editor.refreshBudgetStatus(loadGenerationLog: { url in
                try await gate.load(url)
            })
        }
        await gate.waitForRead()
        let root = try #require(editor.workingRoot)
        let authorization = GenerationAuthorization(
            transactionId: "concurrent-reservation",
            target: target(transport: .api, billing: .perCall),
            estimate: money(3),
            projectMutationScope: try GenerationProjectMutationScope(
                projectHome: root, editor: editor
            )
        )
        try editor.recordSpendEvent(authorization: authorization, kind: .reserved,
                                    money: money(3), pricingStatus: .priced)
        let expected = editor.generationLog
        await gate.resume()
        try await refresh.value

        #expect(editor.generationLog == expected)
        let persisted = try #require(GenerationLogFile.loadIfPresent(
            from: root.appendingPathComponent(Project.generationLogFilename)
        ))
        #expect(persisted == expected)
        #expect(try GenerationBudgetGuard.spendSnapshot(log: editor.generationLog,
            generatedInputs: []).openReservationEur == 3)

        try editor.recordSpendEvent(authorization: authorization, kind: .submitted,
                                    providerRequestId: "request-concurrent", money: money(3))
        let chargeGate = PausedBudgetLoad()
        let chargeRefresh = Task {
            try await editor.refreshBudgetStatus(loadGenerationLog: { url in
                try await chargeGate.load(url)
            })
        }
        await chargeGate.waitForRead()
        try editor.recordSpendEvent(authorization: authorization, kind: .charged, money: money(2))
        let chargedLog = editor.generationLog
        await chargeGate.resume()
        try await chargeRefresh.value
        #expect(editor.generationLog == chargedLog)
        #expect(try GenerationLogFile.loadIfPresent(from:
            root.appendingPathComponent(Project.generationLogFilename)) == chargedLog)
        #expect(try GenerationBudgetGuard.spendSnapshot(log: editor.generationLog,
            generatedInputs: []).chargedEur == 2)
    }

    @Test("a paused refresh from a prior visit cannot replace the same project's new session")
    func refreshRejectsProjectABA() async throws {
        let first = try package(named: "aba-first")
        let second = try package(named: "aba-second")
        let editor = EditorViewModel()
        editor.projectURL = first
        defer {
            editor.releaseWorkingCopy()
            for project in [first, second] {
                if let key = ProjectIdentity.existingKey(for: project) {
                    ProjectWorkingCopy.discard(key: key)
                }
                try? FileManager.default.removeItem(at: project)
            }
        }
        let gate = PausedBudgetLoad()
        let refresh = Task {
            try await editor.refreshBudgetStatus(loadGenerationLog: { url in
                try await gate.load(url)
            })
        }
        await gate.waitForRead()
        let oldToken = editor.budgetStatusLoadToken
        editor.projectURL = second
        editor.projectURL = first
        #expect(editor.budgetStatusLoadToken > oldToken)
        await gate.resume()
        try await refresh.value
        #expect(editor.generationLog == GenerationLog())
    }

    @Test("known excess remains an error with an additional unpriced reservation")
    func knownExcessSurvivesUnknownCost() throws {
        var events = transaction(id: "known", money: money(12.5), final: .charged)
        events += transaction(id: "unknown", money: nil, final: .reserved,
                              pricingStatus: .priceUnavailable)
        let presentation = ProjectBudgetPresentation.make(log: log(events), generatedInputs: [],
            projectState: try projectState(budget: 10, stop: 12), hasProductionPipeline: true)
        #expect(presentation.severity == .error)
        #expect(presentation.compactLabel == "Budget ≥€12.50 / €10.00")
        #expect(presentation.warnings.contains("Planning budget exceeded by €2.50."))
        #expect(presentation.warnings.contains("Hard stop exceeded by €0.50."))
    }

    private func package(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "budget-\(name)-\(UUID().uuidString).ngv",
            isDirectory: true
        )
        return try Fixtures.prepareProjectPackage(at: url)
    }

    private func projectState(budget: Double, stop: Double?) throws -> ProjectStateData {
        let stopValue = stop.map { String($0) } ?? "null"
        return try JSONDecoder().decode(ProjectStateData.self, from: Data("""
        {
          "project": "demo",
          "mode": "beat",
          "budget_eur": \(budget),
          "budget_stop_eur": \(stopValue),
          "phases": []
        }
        """.utf8))
    }

    private func money(_ eur: Double) -> GenerationMoney {
        GenerationMoney(
            nativeAmount: eur * 1.2,
            nativeCurrency: "USD",
            eurAmount: eur,
            eurPerNativeUnit: 1 / 1.2,
            exchangeRateDate: "2026-09-24",
            pricingSource: "https://provider.example/pricing",
            exchangeRateSource: "https://www.ecb.europa.eu/"
        )
    }

    private func target(
        transport: ProviderTransport,
        billing: BillingMode
    ) -> ResolvedGenerationTarget {
        let endpoint = transport == .mcp ? "generate_video" : "video/generate"
        return ResolvedGenerationTarget(
            modelId: "higgsfield/acceptance-video",
            provider: .higgsfield,
            endpoint: endpoint,
            binding: ProviderBinding(
                provider: .higgsfield,
                transport: transport,
                kind: .generation,
                providerRef: endpoint,
                billing: billing
            )
        )
    }

    private func transaction(
        id: String,
        money: GenerationMoney?,
        final: GenerationSpendEvent.Kind,
        transport: ProviderTransport = .api,
        billing: BillingMode = .perCall,
        pricingStatus: GenerationPricingStatus? = nil
    ) -> [GenerationSpendEvent] {
        let target = target(transport: transport, billing: billing)
        let status = pricingStatus
            ?? (money != nil ? .priced : billing == .subscription ? .subscriptionCredits : .priceUnavailable)
        var events = [event(
            id: "\(id)-reserved",
            transaction: id,
            kind: .reserved,
            target: target,
            money: money,
            pricingStatus: status,
            createdAt: 1
        )]
        if final == .submitted || final == .charged {
            events.append(event(
                id: "\(id)-submitted",
                transaction: id,
                kind: .submitted,
                target: target,
                requestID: "request-\(id)",
                money: money,
                createdAt: 2
            ))
        }
        if final == .charged {
            events.append(event(
                id: "\(id)-charged",
                transaction: id,
                kind: .charged,
                target: target,
                money: money,
                createdAt: 3
            ))
        } else if final == .released {
            events.append(event(
                id: "\(id)-released",
                transaction: id,
                kind: .released,
                target: target,
                createdAt: 2
            ))
        }
        return events
    }

    private func event(
        id: String,
        transaction: String,
        kind: GenerationSpendEvent.Kind,
        target: ResolvedGenerationTarget,
        requestID: String? = nil,
        money: GenerationMoney? = nil,
        pricingStatus: GenerationPricingStatus? = nil,
        createdAt: TimeInterval
    ) -> GenerationSpendEvent {
        GenerationSpendEvent(
            id: id,
            transactionId: transaction,
            kind: kind,
            model: target.modelId,
            provider: target.provider,
            transport: target.transport,
            endpoint: target.endpoint,
            providerRequestId: requestID,
            providerRequestResumable: requestID != nil,
            money: money,
            createdAt: Date(timeIntervalSince1970: createdAt),
            billing: target.binding?.billing,
            pricingStatus: pricingStatus
        )
    }

    private func log(_ events: [GenerationSpendEvent]) -> GenerationLog {
        var log = GenerationLog()
        log.spendEvents = events
        return log
    }
}

private actor PausedBudgetLoad {
    private var read = false
    private var readWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func load(_ url: URL) async throws -> GenerationLog {
        let log = try GenerationLogFile.loadIfPresent(from: url) ?? GenerationLog()
        read = true
        readWaiter?.resume()
        readWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return log
    }

    func waitForRead() async {
        if read { return }
        await withCheckedContinuation { readWaiter = $0 }
    }

    func resume() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
