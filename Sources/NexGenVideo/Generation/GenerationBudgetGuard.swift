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
        approvedPackage: GenerationPackageV1? = nil,
        requiresVerifiedCeiling: Bool = false,
        batchItem: GenerationBatchAuthorization? = nil,
        quoteLoader: QuoteLoader = LiveGenerationPricing.quote
    ) async throws -> GenerationAuthorization {
        let acceptsUnknownPrice: Bool
        if let batchItem {
            guard let approvedPackage else {
                throw GenerationBudgetError.blocked("Batch approval requires its exact generation package.")
            }
            acceptsUnknownPrice = try batchItem.pricingOverride(package: approvedPackage, editor: editor)
        } else { acceptsUnknownPrice = false }
        if let approvedPackage {
            try approvedPackage.validate()
            guard approvedPackage.payload.target == target, approvedPackage.payload.outputCount == input.outputCount else {
                throw GenerationBudgetError.blocked("The priced request differs from its generation package.")
            }
            guard !requiresVerifiedCeiling || approvedPackage.payload.estimate != nil || acceptsUnknownPrice else {
                throw GenerationBudgetError.blocked(
                    "This request has no verified monetary ceiling. Retry pricing or choose another route before approval."
                )
            }
        }
        guard let workingRoot = editor.workingRoot else {
            if editor.projectURL != nil {
                throw GenerationBudgetError.blocked(
                    "The live project working copy is unavailable. "
                    + "Restore or reopen the project before generating."
                )
            }
            guard let ceiling = approvedPackage?.payload.estimate else {
                return GenerationAuthorization(transactionId: nil, target: target, estimate: nil)
            }
            let current: GenerationMoney?
            do {
                let quoted = try await quoteLoader(target, input)
                try validate(quoted)
                current = quoted
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                current = nil
            }
            if let current, current.eurAmount > ceiling.eurAmount {
                throw GenerationBudgetError.blocked("The current price exceeds the reviewed estimate. Prepare and review the generation again.")
            }
            return GenerationAuthorization(transactionId: nil, target: target, estimate: current)
        }
        let mutationScope = try GenerationProjectMutationScope(
            projectHome: workingRoot,
            editor: editor
        )

        let estimate: GenerationMoney?
        let pricingFailure: GenerationPricingFailure?
        do {
            let quoted = try await quoteLoader(target, input)
            try validate(quoted)
            estimate = quoted
            pricingFailure = nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            estimate = nil
            pricingFailure = .classified(error, provider: target.provider, endpoint: target.endpoint)
        }

        // A known higher price changes what the user approved; a missing price never blocks.
        if let ceiling = approvedPackage?.payload.estimate, let estimate, estimate.eurAmount > ceiling.eurAmount {
            throw GenerationBudgetError.blocked("The current price exceeds the reviewed estimate. Prepare and review the generation again.")
        }

        guard editor.workingRoot?.standardizedFileURL == workingRoot.standardizedFileURL else {
            throw GenerationBudgetError.blocked(
                "The project changed while pricing this request. Retry generation in the active project."
            )
        }
        if let approvedPackage,
           approvedPackage.payload.modality == "image" || approvedPackage.payload.modality == "video" {
            try await GenerationPackageInputs.requireCurrentReferences(package: approvedPackage, editor: editor)
        }
        try mutationScope.requireCurrent(editor: editor)
        let log = try loadGenerationLog(from: workingRoot) ?? editor.generationLog
        try validateLedger(log: log, generatedAssets: editor.mediaAssets)

        try Task.checkCancellation()
        let transactionId = UUID().uuidString
        editor.generationLog = log
        let authorization = GenerationAuthorization(
            transactionId: transactionId,
            target: target,
            estimate: estimate,
            projectMutationScope: mutationScope
        )
        try editor.recordSpendEvent(
            authorization: authorization,
            kind: .reserved,
            money: estimate,
            note: acceptsUnknownPrice
                ? "User explicitly approved this exact batch item without a cost estimate. " + (pricingFailure?.detail ?? "")
                : pricingFailure?.detail
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
                    "The live project working copy is unavailable. "
                    + "Restore or reopen the project before running provider tools."
                )
            }
            return GenerationAuthorization(transactionId: nil, target: target, estimate: nil)
        }
        let mutationScope = try GenerationProjectMutationScope(
            projectHome: workingRoot,
            editor: editor
        )

        let log = try loadGenerationLog(from: workingRoot) ?? editor.generationLog
        try validateLedger(log: log, generatedAssets: editor.mediaAssets)

        let authorization = GenerationAuthorization(
            transactionId: UUID().uuidString,
            target: target,
            estimate: nil,
            projectMutationScope: mutationScope
        )
        editor.generationLog = log
        try editor.recordSpendEvent(
            authorization: authorization,
            kind: .reserved,
            note: "Provider did not expose a monetary estimate."
        )
        return authorization
    }

    static func validateLedger(
        log: GenerationLog,
        generatedAssets: [MediaAsset]
    ) throws {
        _ = try spendSnapshot(
            log: log,
            generatedInputs: generatedAssets.compactMap(\.generationInput)
        )
    }

    nonisolated static func spendSnapshot(
        log: GenerationLog,
        generatedInputs: [GenerationInput],
        completedTransactionIDs: Set<String> = [],
        activeTransactionIDs: Set<String> = []
    ) throws -> ProjectSpendSnapshot {
        try GenerationSpendLedger.snapshot(
            log: log,
            generatedInputs: generatedInputs,
            completedTransactionIDs: completedTransactionIDs,
            activeTransactionIDs: activeTransactionIDs
        )
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

    nonisolated private static func validate(_ money: GenerationMoney?) throws {
        try GenerationSpendLedger.validate(money)
    }

    nonisolated private static func corrupt(_ detail: String) -> GenerationBudgetError {
        GenerationSpendLedger.corrupt(detail)
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
            if target.modelId.contains("gpt-image-2.5") {
                guard let amount = FalModelRegistry.gptImage25VerifiedGenerationPriceUSD(
                    modelID: target.modelId,
                    resolution: input.resolution,
                    quality: input.quality,
                    outputCount: input.outputCount,
                    promptUTF8ByteCount: input.promptUTF8ByteCount
                ) else {
                    throw GenerationPricingFailure(
                        reason: .unsupportedCombination,
                        provider: .fal,
                        endpoint: target.endpoint,
                        detail: "NexGenVideo cannot estimate this GPT Image 2.5 size, quality, or reference-image combination."
                    )
                }
                return try await ProviderMoneyClient.shared.normalize(
                    nativeAmount: amount,
                    currency: "USD",
                    pricingSource: "https://fal.ai/gpt-image-2.5"
                )
            }
            guard let apiKey = ProviderKeychain.load(.fal) else {
                throw GenerationPricingFailure(
                    reason: .priceQueryUnavailable,
                    provider: .fal,
                    endpoint: target.endpoint,
                    detail: "Add a fal.ai API key to retrieve live pricing."
                )
            }
            return try await ProviderMoneyClient.shared.falQuote(
                endpoint: target.endpoint,
                input: input,
                apiKey: apiKey
            )
        case (.runway, .api):
            guard let credits = runwayCredits(endpoint: target.endpoint, input: input) else {
                throw GenerationPricingFailure(
                    reason: .unsupportedCombination,
                    provider: .runway,
                    endpoint: target.endpoint,
                    detail: "Runway pricing is not verified for this exact model and option set."
                )
            }
            return try await ProviderMoneyClient.shared.normalize(
                nativeAmount: Double(credits) * 0.01,
                currency: "USD",
                pricingSource: "https://docs.dev.runwayml.com/guides/pricing/"
            )
        default:
            throw GenerationPricingFailure(
                reason: .unsupportedCombination,
                provider: target.provider,
                endpoint: target.endpoint,
                detail: "\(target.provider.displayName) does not expose a verified pre-dispatch monetary estimate."
            )
        }
    }

    static func runwayCredits(
        endpoint: String,
        input: GenerationPricingInput
    ) -> Int? {
        guard (1...4).contains(input.outputCount), input.referenceCount >= 0 else { return nil }
        let duration = input.durationSeconds.flatMap {
            $0 > 0 ? max(1, Int($0.rounded(.up))) : nil
        }
        let registryModel = RunwayModelRegistry.model(for: endpoint)
        if registryModel?.imageRequest != nil {
            guard input.modality == .image, input.resolution == nil else { return nil }
        }
        let model = registryModel?.apiModel
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
        case "gen4_image_turbo":
            return 2 * max(1, input.outputCount)
        case "gen4_image":
            guard runwayRatios(endpoint: endpoint, satisfy: { dimensions in
                dimensions.min() ?? 0 >= 1_080
            }) else { return nil }
            return 8 * max(1, input.outputCount)
        case "gpt_image_2":
            guard runwayRatios(endpoint: endpoint, satisfy: { dimensions in
                dimensions.max() ?? 0 < 3_840
            }) else { return nil }
            let perImage: Int
            switch input.quality ?? "high" {
            case "low": perImage = 1
            case "medium": perImage = 5
            case "high", "auto": perImage = 20
            default: return nil
            }
            return perImage * max(1, input.outputCount)
        case "seedream5_pro":
            guard runwayRatios(endpoint: endpoint, satisfy: { dimensions in
                dimensions.max() ?? 0 < 1_920
            }) else { return nil }
            return 5 * max(1, input.outputCount)
        case "seedream5_lite":
            return 4 * max(1, input.outputCount)
        case "grok_imagine_image_2":
            guard runwayRatios(endpoint: endpoint, satisfy: { dimensions in
                dimensions.max() ?? 0 < 1_920
            }) else { return nil }
            let perImage: Int
            switch input.quality ?? "medium" {
            case "low": perImage = 4
            case "medium": perImage = 6
            default: return nil
            }
            return max(6, perImage * max(1, input.outputCount) + input.referenceCount)
        case "gemini_image3_pro":
            guard input.modality == .image,
                  input.outputCount == 1,
                  input.resolution == nil,
                  input.quality == nil,
                  runwayRatios(endpoint: endpoint, satisfy: { dimensions in
                      dimensions.max() ?? 0 < 3_840
                  }) else { return nil }
            return 20
        case "gemini_2.5_flash":
            return 5 * max(1, input.outputCount)
        default:
            return nil
        }
    }

    private static func runwayRatios(
        endpoint: String,
        satisfy predicate: ([Int]) -> Bool
    ) -> Bool {
        guard let ratios = RunwayModelRegistry.model(for: endpoint)?.imageRequest?.ratios.values,
              !ratios.isEmpty else { return false }
        return ratios.allSatisfy { ratio in
            let dimensions = ratio.split(separator: ":").compactMap { Int($0) }
            return dimensions.count == 2 && predicate(dimensions)
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
        guard let url = parts.url else { throw pricingFailure(
            .priceQueryUnavailable,
            provider: .fal,
            endpoint: endpoint,
            detail: "fal.ai returned an invalid pricing URL."
        ) }
        var request = URLRequest(url: url)
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await responseData(
            for: request,
            label: "fal.ai pricing",
            reason: .priceQueryUnavailable,
            provider: .fal,
            endpoint: endpoint
        )
        let response: FalPricingResponse
        do { response = try JSONDecoder().decode(FalPricingResponse.self, from: data) }
        catch { throw pricingFailure(
            .priceQueryUnavailable,
            provider: .fal,
            endpoint: endpoint,
            detail: "fal.ai returned unreadable pricing metadata."
        ) }
        guard let price = response.prices.first(where: { $0.endpointId == endpoint }),
              price.unitPrice.isFinite,
              price.unitPrice >= 0 else {
            throw pricingFailure(
                .unsupportedCombination,
                provider: .fal,
                endpoint: endpoint,
                detail: "fal.ai returned no current price for \(endpoint)."
            )
        }
        let quantity = try falQuantity(unit: price.unit, input: input, endpoint: endpoint)
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
        let data = try await responseData(
            for: request,
            label: "fal.ai billing",
            reason: .priceQueryUnavailable,
            provider: .fal,
            endpoint: endpoint
        )
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
            throw pricingFailure(
                .priceQueryUnavailable,
                provider: nil,
                endpoint: pricingSource,
                detail: "Provider pricing returned an invalid amount."
            )
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
                throw pricingFailure(
                    .exchangeRateUnavailable,
                    provider: nil,
                    endpoint: pricingSource,
                    detail: "ECB has no current EUR reference rate for \(code)."
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

    private func falQuantity(
        unit: String,
        input: GenerationPricingInput,
        endpoint: String
    ) throws -> Double {
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
                throw pricingFailure(
                    .unsupportedCombination, provider: .fal, endpoint: endpoint,
                    detail: "fal.ai prices \(unit), but this request has no verified duration."
                )
            }
            return duration * Double(max(1, input.outputCount))
        case "minute", "minutes", "audio_minute", "audio_minutes":
            guard let duration = input.durationSeconds, duration > 0 else {
                throw pricingFailure(
                    .unsupportedCombination, provider: .fal, endpoint: endpoint,
                    detail: "fal.ai prices \(unit), but this request has no verified duration."
                )
            }
            return duration / 60 * Double(max(1, input.outputCount))
        case "character", "characters":
            guard input.promptCharacterCount > 0 else {
                throw pricingFailure(
                    .unsupportedCombination, provider: .fal, endpoint: endpoint,
                    detail: "fal.ai prices characters, but this request has no priced text."
                )
            }
            return Double(input.promptCharacterCount)
        case "thousand_characters", "1000_characters":
            guard input.promptCharacterCount > 0 else {
                throw pricingFailure(
                    .unsupportedCombination, provider: .fal, endpoint: endpoint,
                    detail: "fal.ai prices characters, but this request has no priced text."
                )
            }
            return Double(input.promptCharacterCount) / 1000
        default:
            throw pricingFailure(
                .unsupportedCombination, provider: .fal, endpoint: endpoint,
                detail: "fal.ai billing unit '\(unit)' cannot be derived exactly from this request."
            )
        }
    }

    private func exchangeRates() async throws -> ExchangeRates {
        if let cachedRates, cachedRates.isFresh { return cachedRates }
        let data = try await responseData(
            for: URLRequest(url: Self.ecbURL),
            label: "ECB exchange rates",
            reason: .exchangeRateUnavailable,
            provider: nil,
            endpoint: Self.ecbURL.absoluteString
        )
        guard let xml = String(data: data, encoding: .utf8),
              let date = capture(#"time=['"]([^'"]+)['"]"#, in: xml),
              let parsedDate = ISO8601DateFormatter().date(from: date + "T00:00:00Z") else {
            throw pricingFailure(.exchangeRateUnavailable, provider: nil,
                endpoint: Self.ecbURL.absoluteString, detail: "ECB exchange-rate data is missing or stale.")
        }
        let age = Date().timeIntervalSince(parsedDate)
        guard age >= -24 * 60 * 60, age < 8 * 24 * 60 * 60 else {
            throw pricingFailure(.exchangeRateUnavailable, provider: nil,
                endpoint: Self.ecbURL.absoluteString, detail: "ECB exchange-rate data is missing or stale.")
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
            throw pricingFailure(.exchangeRateUnavailable, provider: nil,
                endpoint: Self.ecbURL.absoluteString, detail: "ECB exchange-rate data contains no rates.")
        }
        let rates = ExchangeRates(date: date, retrievedAt: Date(), unitsPerEuro: unitsPerEuro)
        cachedRates = rates
        return rates
    }

    private func responseData(
        for request: URLRequest,
        label: String,
        reason: GenerationPricingFailure.Reason,
        provider: GenerationProvider?,
        endpoint: String
    ) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw pricingFailure(
            reason,
            provider: provider,
            endpoint: endpoint,
            detail: "\(label) could not be reached: \(error.localizedDescription)"
        ) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw pricingFailure(reason, provider: provider, endpoint: endpoint,
                detail: "\(label) failed with HTTP \(status).")
        }
        return data
    }

    private func pricingFailure(
        _ reason: GenerationPricingFailure.Reason,
        provider: GenerationProvider?,
        endpoint: String,
        detail: String
    ) -> GenerationPricingFailure {
        GenerationPricingFailure(reason: reason, provider: provider, endpoint: endpoint, detail: detail)
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
