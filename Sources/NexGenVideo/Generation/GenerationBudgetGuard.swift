import Foundation
import NexGenEngine

enum GenerationBudgetError: LocalizedError {
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let message): message
        }
    }
}

@MainActor
enum GenerationBudgetGuard {
    typealias QuoteLoader = @MainActor (
        _ target: ResolvedGenerationTarget,
        _ input: GenerationPricingInput
    ) async throws -> GenerationMoney

    static func authorize(
        input: GenerationPricingInput,
        target: ResolvedGenerationTarget,
        editor: EditorViewModel,
        quoteLoader: QuoteLoader = LiveGenerationPricing.quote
    ) async throws -> GenerationAuthorization {
        guard let workingRoot = editor.workingRoot else {
            if editor.projectURL != nil {
                throw GenerationBudgetError.blocked(
                    "Budget stop could not access the live project working copy. "
                    + "Restore or reopen the project before generating."
                )
            }
            return GenerationAuthorization(transactionId: nil, target: target, estimate: nil)
        }

        let estimate: GenerationMoney?
        let pricingFailure: String?
        do {
            let quoted = try await quoteLoader(target, input)
            try validate(quoted)
            estimate = quoted
            pricingFailure = nil
        } catch {
            estimate = nil
            pricingFailure = error.localizedDescription
        }

        guard editor.workingRoot?.standardizedFileURL == workingRoot.standardizedFileURL else {
            throw GenerationBudgetError.blocked(
                "The project changed while pricing this request. Retry generation in the active project."
            )
        }
        let stop = try budgetStop(in: workingRoot)
        var log = try loadGenerationLog(from: workingRoot) ?? editor.generationLog
        let existingSpend = try verifiedSpend(
            log: log,
            generatedAssets: editor.mediaAssets,
            requireCompleteMoney: stop != nil
        )

        if let stop {
            guard let estimate else {
                throw GenerationBudgetError.blocked(
                    "Budget stop: \(target.provider.displayName) did not provide a verified monetary "
                    + "estimate for \(target.endpoint). No provider request was sent. "
                    + (pricingFailure ?? "Pricing is unavailable.")
                )
            }
            let projected = existingSpend + estimate.eurAmount
            guard projected <= stop else {
                throw GenerationBudgetError.blocked(
                    "Budget stop reached. This request is estimated at "
                    + euro(estimate.eurAmount) + "; verified project spend plus reservations would be "
                    + euro(projected) + ", above the limit of " + euro(stop) + "."
                )
            }
        }

        let transactionId = UUID().uuidString
        editor.generationLog = log
        let authorization = GenerationAuthorization(
            transactionId: transactionId,
            target: target,
            estimate: estimate
        )
        try editor.recordSpendEvent(
            authorization: authorization,
            kind: .reserved,
            money: estimate,
            note: pricingFailure
        )
        return authorization
    }

    static func authorizeUnknownPaidOperation(
        modelId: String,
        provider: GenerationProvider,
        transport: ProviderTransport,
        endpoint: String,
        editor: EditorViewModel
    ) throws -> GenerationAuthorization {
        let target = ResolvedGenerationTarget(
            modelId: modelId,
            provider: provider,
            endpoint: endpoint,
            binding: ProviderBinding(
                provider: provider,
                transport: transport,
                kind: .tool,
                providerRef: endpoint,
                billing: transport == .mcp ? .subscription : .perCall
            )
        )
        guard let workingRoot = editor.workingRoot else {
            if editor.projectURL != nil {
                throw GenerationBudgetError.blocked(
                    "Budget stop could not access the live project working copy. "
                    + "Restore or reopen the project before running provider tools."
                )
            }
            return GenerationAuthorization(transactionId: nil, target: target, estimate: nil)
        }

        let stop = try budgetStop(in: workingRoot)
        var log = try loadGenerationLog(from: workingRoot) ?? editor.generationLog
        _ = try verifiedSpend(
            log: log,
            generatedAssets: editor.mediaAssets,
            requireCompleteMoney: stop != nil
        )
        if stop != nil {
            throw GenerationBudgetError.blocked(
                "Budget stop: \(provider.displayName) does not expose a verified monetary estimate "
                + "for \(endpoint). No provider request was sent."
            )
        }

        let authorization = GenerationAuthorization(
            transactionId: UUID().uuidString,
            target: target,
            estimate: nil
        )
        editor.generationLog = log
        try editor.recordSpendEvent(
            authorization: authorization,
            kind: .reserved,
            note: "Provider did not expose a monetary estimate."
        )
        return authorization
    }

    static func verifiedSpend(
        log: GenerationLog,
        generatedAssets: [MediaAsset],
        requireCompleteMoney: Bool
    ) throws -> Double {
        guard (1...2).contains(log.version) else {
            throw corrupt("generation-log.json uses unsupported version \(log.version)")
        }
        var states: [String: SpendState] = [:]
        var eventIds: Set<String> = []
        for event in log.spendEvents {
            guard eventIds.insert(event.id).inserted else {
                throw corrupt("generation-log.json contains duplicate event \(event.id)")
            }
            guard !event.transactionId.isEmpty,
                  !event.model.isEmpty,
                  !event.endpoint.isEmpty else {
                throw corrupt("generation-log.json contains an incomplete spend event")
            }
            try validate(event.money)
            if var state = states[event.transactionId] {
                guard state.model == event.model,
                      state.provider == event.provider,
                      state.transport == event.transport,
                      state.endpoint == event.endpoint else {
                    throw corrupt("transaction \(event.transactionId) changes provider or model")
                }
                try state.apply(event)
                states[event.transactionId] = state
            } else {
                guard event.kind == .reserved else {
                    throw corrupt("transaction \(event.transactionId) does not start with a reservation")
                }
                states[event.transactionId] = SpendState(event)
            }
        }

        if requireCompleteMoney {
            if log.entries.contains(where: { $0.spendTransactionId == nil }) {
                throw GenerationBudgetError.blocked(
                    "Budget stop: existing generation history has no verified monetary ledger. "
                    + "No provider request was sent."
                )
            }
            if generatedAssets.contains(where: {
                $0.generationInput != nil && $0.generationInput?.spendTransactionId == nil
            }) {
                throw GenerationBudgetError.blocked(
                    "Budget stop: generated project media predates the verified monetary ledger. "
                    + "No provider request was sent."
                )
            }
        }

        for entry in log.entries {
            guard let transactionId = entry.spendTransactionId else { continue }
            guard let state = states[transactionId], state.kind != .released else {
                throw corrupt("activity entry \(entry.id) has no active spend transaction")
            }
        }

        var total = 0.0
        for state in states.values where state.kind != .released {
            guard let money = state.effectiveMoney else {
                if requireCompleteMoney {
                    throw GenerationBudgetError.blocked(
                        "Budget stop: project spend contains an unpriced provider request. "
                        + "No provider request was sent."
                    )
                }
                continue
            }
            total += money.eurAmount
        }
        guard total.isFinite, total >= 0 else {
            throw corrupt("project spend total is invalid")
        }
        return total
    }

    private static func budgetStop(in workingRoot: URL) throws -> Double? {
        let dataRoot: URL?
        if let resolved = DataRootResolver.dataRoot(of: workingRoot) {
            dataRoot = resolved
        } else {
            let pipeline = workingRoot.appendingPathComponent(DataRootResolver.pipelineDirname)
            let nestedBrief = PipelineLayout.url(PipelineLayout.briefFile, in: pipeline)
            let flatBrief = PipelineLayout.url(PipelineLayout.briefFile, in: workingRoot)
            if FileManager.default.fileExists(atPath: nestedBrief.path) {
                dataRoot = pipeline
            } else if FileManager.default.fileExists(atPath: flatBrief.path) {
                dataRoot = workingRoot
            } else {
                dataRoot = nil
            }
        }
        guard let dataRoot else { return nil }
        let url = PipelineLayout.url(PipelineLayout.briefFile, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let brief = try YAMLArtifactStore(dataRoot: dataRoot).load(
                Brief.self,
                at: PipelineLayout.briefFile
            )
            try brief.validate()
            return brief.budgetStopEur
        } catch {
            throw GenerationBudgetError.blocked(
                "Budget stop could not validate brief.yaml. Repair or restore it before generating."
            )
        }
    }

    private static func loadGenerationLog(from workingRoot: URL) throws -> GenerationLog? {
        let url = workingRoot.appendingPathComponent(Project.generationLogFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(GenerationLog.self, from: Data(contentsOf: url))
        } catch {
            throw corrupt("generation-log.json is unreadable")
        }
    }

    private static func validate(_ money: GenerationMoney?) throws {
        guard let money else { return }
        guard money.nativeAmount.isFinite, money.nativeAmount >= 0,
              money.eurAmount.isFinite, money.eurAmount >= 0,
              money.eurPerNativeUnit.isFinite, money.eurPerNativeUnit > 0,
              money.nativeCurrency.count == 3,
              !money.exchangeRateDate.isEmpty,
              !money.pricingSource.isEmpty,
              !money.exchangeRateSource.isEmpty else {
            throw corrupt("generation-log.json contains invalid monetary data")
        }
    }

    nonisolated private static func corrupt(_ detail: String) -> GenerationBudgetError {
        .blocked("Budget stop could not verify project spend: \(detail). No provider request was sent.")
    }

    private static func euro(_ amount: Double) -> String {
        String(format: "€%.2f", amount)
    }

    private struct SpendState {
        let model: String
        let provider: GenerationProvider
        let transport: ProviderTransport
        let endpoint: String
        var kind: GenerationSpendEvent.Kind
        var reservedMoney: GenerationMoney?
        var chargedMoney: GenerationMoney?

        init(_ event: GenerationSpendEvent) {
            model = event.model
            provider = event.provider
            transport = event.transport
            endpoint = event.endpoint
            kind = event.kind
            reservedMoney = event.money
            chargedMoney = nil
        }

        var effectiveMoney: GenerationMoney? { chargedMoney ?? reservedMoney }

        mutating func apply(_ event: GenerationSpendEvent) throws {
            switch (kind, event.kind) {
            case (_, .reserved):
                throw GenerationBudgetGuard.corrupt(
                    "transaction \(event.transactionId) has multiple reservations"
                )
            case (.reserved, .submitted):
                guard event.providerRequestId?.isEmpty == false else {
                    throw GenerationBudgetGuard.corrupt(
                        "transaction \(event.transactionId) has no provider request id"
                    )
                }
                guard event.money == reservedMoney else {
                    throw GenerationBudgetGuard.corrupt(
                        "transaction \(event.transactionId) changes its submitted amount"
                    )
                }
                kind = .submitted
            case (.submitted, .charged):
                guard let money = event.money else {
                    throw GenerationBudgetGuard.corrupt(
                        "transaction \(event.transactionId) has an unpriced charge"
                    )
                }
                chargedMoney = money
                kind = .charged
            case (.reserved, .released):
                kind = .released
            default:
                throw GenerationBudgetGuard.corrupt(
                    "transaction \(event.transactionId) has invalid \(kind.rawValue) → "
                    + event.kind.rawValue + " transition"
                )
            }
        }
    }
}

@MainActor
enum LiveGenerationPricing {
    static func quote(
        target: ResolvedGenerationTarget,
        input: GenerationPricingInput
    ) async throws -> GenerationMoney {
        switch (target.provider, target.transport) {
        case (.fal, .api):
            guard let apiKey = ProviderKeychain.load(.fal) else {
                throw GenerationBudgetError.blocked("Add a fal.ai API key to retrieve live pricing.")
            }
            return try await ProviderMoneyClient.shared.falQuote(
                endpoint: target.endpoint,
                input: input,
                apiKey: apiKey
            )
        case (.runway, .api):
            guard let credits = runwayCredits(endpoint: target.endpoint, input: input) else {
                throw GenerationBudgetError.blocked(
                    "Runway pricing is not verified for this exact model and option set."
                )
            }
            return try await ProviderMoneyClient.shared.normalize(
                nativeAmount: Double(credits) * 0.01,
                currency: "USD",
                pricingSource: "https://docs.dev.runwayml.com/guides/pricing/"
            )
        default:
            throw GenerationBudgetError.blocked(
                "\(target.provider.displayName) does not expose a verified pre-dispatch monetary estimate."
            )
        }
    }

    private static func runwayCredits(
        endpoint: String,
        input: GenerationPricingInput
    ) -> Int? {
        let duration = input.durationSeconds.flatMap {
            $0 > 0 ? max(1, Int($0.rounded(.up))) : nil
        }
        let model = RunwayModelRegistry.model(for: endpoint)?.apiModel
        switch model {
        case "gen4.5":
            guard let duration else { return nil }
            return 12 * duration
        case "gen4_turbo":
            guard let duration else { return nil }
            return 5 * duration
        case "aleph2":
            guard let duration else { return nil }
            return max(56, 28 * duration)
        case "gen4_image":
            return 8 * max(1, input.outputCount)
        default:
            return nil
        }
    }
}

actor ProviderMoneyClient {
    static let shared = ProviderMoneyClient()

    private static let ecbURL = URL(
        string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
    )!
    private var cachedRates: ExchangeRates?

    func falQuote(
        endpoint: String,
        input: GenerationPricingInput,
        apiKey: String
    ) async throws -> GenerationMoney {
        var parts = URLComponents(string: "https://api.fal.ai/v1/models/pricing")!
        parts.queryItems = [URLQueryItem(name: "endpoint_id", value: endpoint)]
        guard let url = parts.url else {
            throw GenerationBudgetError.blocked("fal.ai returned an invalid pricing URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await responseData(for: request, label: "fal.ai pricing")
        let response = try JSONDecoder().decode(FalPricingResponse.self, from: data)
        guard let price = response.prices.first(where: { $0.endpointId == endpoint }),
              price.unitPrice.isFinite,
              price.unitPrice >= 0 else {
            throw GenerationBudgetError.blocked(
                "fal.ai returned no current price for \(endpoint)."
            )
        }
        let quantity = try falQuantity(unit: price.unit, input: input)
        return try await normalize(
            nativeAmount: price.unitPrice * quantity,
            currency: price.currency,
            pricingSource: url.absoluteString
        )
    }

    func falCharge(
        requestId: String,
        endpoint: String,
        apiKey: String
    ) async throws -> GenerationMoney? {
        var parts = URLComponents(string: "https://api.fal.ai/v1/models/billing-events")!
        parts.queryItems = [
            URLQueryItem(name: "request_id", value: requestId),
            URLQueryItem(name: "endpoint_id", value: endpoint),
        ]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await responseData(for: request, label: "fal.ai billing")
        let response = try JSONDecoder().decode(FalBillingResponse.self, from: data)
        guard let event = response.billingEvents.first(where: {
            $0.requestId == requestId && $0.endpointId == endpoint
        }) else { return nil }
        return try await normalize(
            nativeAmount: Double(event.costEstimateNanoUSD) / 1_000_000_000,
            currency: "USD",
            pricingSource: url.absoluteString
        )
    }

    func normalize(
        nativeAmount: Double,
        currency: String,
        pricingSource: String
    ) async throws -> GenerationMoney {
        guard nativeAmount.isFinite, nativeAmount >= 0 else {
            throw GenerationBudgetError.blocked("Provider pricing returned an invalid amount.")
        }
        let code = currency.uppercased()
        let rates = try await exchangeRates()
        let eurPerUnit: Double
        if code == "EUR" {
            eurPerUnit = 1
        } else {
            guard let unitsPerEuro = rates.unitsPerEuro[code],
                  unitsPerEuro.isFinite,
                  unitsPerEuro > 0 else {
                throw GenerationBudgetError.blocked(
                    "ECB has no current EUR reference rate for \(code)."
                )
            }
            eurPerUnit = 1 / unitsPerEuro
        }
        return GenerationMoney(
            nativeAmount: nativeAmount,
            nativeCurrency: code,
            eurAmount: nativeAmount * eurPerUnit,
            eurPerNativeUnit: eurPerUnit,
            exchangeRateDate: rates.date,
            pricingSource: pricingSource,
            exchangeRateSource: Self.ecbURL.absoluteString
        )
    }

    private func falQuantity(unit: String, input: GenerationPricingInput) throws -> Double {
        let normalized = unit.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "request", "requests", "call", "calls":
            return 1
        case "image", "images", "video", "videos", "output":
            return Double(max(1, input.outputCount))
        case "second", "seconds", "video_second", "video_seconds",
             "output_second", "output_seconds", "audio_second", "audio_seconds":
            guard let duration = input.durationSeconds, duration > 0 else {
                throw GenerationBudgetError.blocked(
                    "fal.ai prices \(unit), but this request has no verified duration."
                )
            }
            return duration * Double(max(1, input.outputCount))
        case "minute", "minutes", "audio_minute", "audio_minutes":
            guard let duration = input.durationSeconds, duration > 0 else {
                throw GenerationBudgetError.blocked(
                    "fal.ai prices \(unit), but this request has no verified duration."
                )
            }
            return duration / 60 * Double(max(1, input.outputCount))
        case "character", "characters":
            guard input.promptCharacterCount > 0 else {
                throw GenerationBudgetError.blocked(
                    "fal.ai prices characters, but this request has no priced text."
                )
            }
            return Double(input.promptCharacterCount)
        case "thousand_characters", "1000_characters":
            guard input.promptCharacterCount > 0 else {
                throw GenerationBudgetError.blocked(
                    "fal.ai prices characters, but this request has no priced text."
                )
            }
            return Double(input.promptCharacterCount) / 1000
        default:
            throw GenerationBudgetError.blocked(
                "fal.ai billing unit '\(unit)' cannot be derived exactly from this request."
            )
        }
    }

    private func exchangeRates() async throws -> ExchangeRates {
        if let cachedRates, cachedRates.isFresh { return cachedRates }
        let data = try await responseData(
            for: URLRequest(url: Self.ecbURL),
            label: "ECB exchange rates"
        )
        guard let xml = String(data: data, encoding: .utf8),
              let date = capture(#"time=['"]([^'"]+)['"]"#, in: xml),
              let parsedDate = ISO8601DateFormatter().date(from: date + "T00:00:00Z") else {
            throw GenerationBudgetError.blocked("ECB exchange-rate data is missing or stale.")
        }
        let age = Date().timeIntervalSince(parsedDate)
        guard age >= -24 * 60 * 60, age < 8 * 24 * 60 * 60 else {
            throw GenerationBudgetError.blocked("ECB exchange-rate data is missing or stale.")
        }
        var unitsPerEuro: [String: Double] = [:]
        let pattern = #"currency=['"]([A-Z]{3})['"]\s+rate=['"]([0-9.]+)['"]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        for match in regex.matches(in: xml, range: range) {
            guard let currencyRange = Range(match.range(at: 1), in: xml),
                  let rateRange = Range(match.range(at: 2), in: xml),
                  let rate = Double(xml[rateRange]) else { continue }
            unitsPerEuro[String(xml[currencyRange])] = rate
        }
        guard !unitsPerEuro.isEmpty else {
            throw GenerationBudgetError.blocked("ECB exchange-rate data contains no rates.")
        }
        let rates = ExchangeRates(date: date, retrievedAt: Date(), unitsPerEuro: unitsPerEuro)
        cachedRates = rates
        return rates
    }

    private func responseData(for request: URLRequest, label: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GenerationBudgetError.blocked("\(label) failed with HTTP \(status).")
        }
        return data
    }

    private func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private struct FalPricingResponse: Decodable {
        let prices: [FalPrice]
    }

    private struct FalPrice: Decodable {
        let endpointId: String
        let unitPrice: Double
        let unit: String
        let currency: String

        enum CodingKeys: String, CodingKey {
            case endpointId = "endpoint_id"
            case unitPrice = "unit_price"
            case unit
            case currency
        }
    }

    private struct FalBillingResponse: Decodable {
        let billingEvents: [FalBillingEvent]

        enum CodingKeys: String, CodingKey {
            case billingEvents = "billing_events"
        }
    }

    private struct FalBillingEvent: Decodable {
        let requestId: String
        let endpointId: String
        let costEstimateNanoUSD: Int64

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case endpointId = "endpoint_id"
            case costEstimateNanoUSD = "cost_estimate_nano_usd"
        }
    }

    private struct ExchangeRates {
        let date: String
        let retrievedAt: Date
        let unitsPerEuro: [String: Double]

        var isFresh: Bool {
            Date().timeIntervalSince(retrievedAt) < 6 * 60 * 60
        }
    }
}
