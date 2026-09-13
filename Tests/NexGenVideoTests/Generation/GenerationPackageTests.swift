import Foundation
import Testing
@testable import NexGenVideo

@MainActor
enum GenerationPackageFixture {
    static func money(_ amount: Double = 0.25) -> GenerationMoney {
        .init(nativeAmount: amount, nativeCurrency: "EUR", eurAmount: amount, eurPerNativeUnit: 1,
            exchangeRateDate: "2026-09-09", pricingSource: "fixture://pricing", exchangeRateSource: "fixture://exchange")
    }

    static func prepare(editor: EditorViewModel, model: String = "fixture-image",
                        quoteLoader: GenerationBudgetGuard.QuoteLoader = { _, _ in money() }) async throws
        -> (GenerationController.PreparedGeneration, GenerationPackageV1) {
        let target = ResolvedGenerationTarget(modelId: model, provider: .fal, endpoint: model, binding: nil)
        let request = GenerationRequest(modality: .image, modelId: model, intent: "", aspectRatio: "1:1",
            placement: .mediaLibrary(folderId: nil), origin: .panel, target: target, submission: .image { prompt in
                ImageGenerationSubmission(genInput: .init(prompt: prompt, model: model, duration: 0, aspectRatio: "1:1"),
                    references: [], name: "Fixture", numImages: 1, folderId: nil,
                    buildParams: { slots in
                        .image(.init(
                            prompt: prompt,
                            aspectRatio: "1:1",
                            resolution: nil,
                            quality: nil,
                            imageURLs: slots,
                            numImages: 1
                        ))
                    })
            })
        let generation = try await GenerationController.prepare(request, editor: editor).get()
        let package = try await GenerationController.prepareReviewPackage(generation, editor: editor, quoteLoader: quoteLoader)
        return (generation, package)
    }
}

@Suite("Generation package approval binding")
@MainActor
struct GenerationPackageTests {
    @Test func preparationRetainsTypedPricingFailureWithoutSpending() async throws {
        for failure in [GenerationPricingFailure.unsupportedOption, .providerPricingUnavailable, .exchangeRateUnavailable] {
            let editor = EditorViewModel()
            let (_, package) = try await GenerationPackageFixture.prepare(editor: editor,
                quoteLoader: { _, _ in throw failure })
            #expect(package.payload.estimate == nil)
            #expect(editor.generationBatchCoordinator.pricingFailure(for: package) == failure)
            #expect(editor.generationLog.spendEvents.isEmpty)
            #expect(editor.mediaAssets.isEmpty)
        }
    }

    @Test func cancellationDoesNotBecomeAnUnpricedReview() async throws {
        let editor = EditorViewModel()
        await #expect(throws: CancellationError.self) {
            _ = try await GenerationPackageFixture.prepare(editor: editor,
                quoteLoader: { _, _ in throw CancellationError() })
        }
    }

    @Test func invalidMoneyCannotEnableApproval() async throws {
        let editor = EditorViewModel()
        let (_, package) = try await GenerationPackageFixture.prepare(editor: editor,
            quoteLoader: { _, _ in .init(nativeAmount: 1, nativeCurrency: "USD", eurAmount: 0,
                eurPerNativeUnit: 0.9, exchangeRateDate: "2026-09-13", pricingSource: "fixture://price",
                exchangeRateSource: "fixture://fx") })
        #expect(package.payload.estimate == nil)
        #expect(editor.generationBatchCoordinator.pricingFailure(for: package) == .providerPricingUnavailable)
    }

    @Test func unpricedIndividualPackageCannotAcquireSpendAuthority() async throws {
        let editor = EditorViewModel()
        let (_, package) = try await GenerationPackageFixture.prepare(editor: editor,
            quoteLoader: { _, _ in throw GenerationPricingFailure.unsupportedOption })
        var quotes = 0
        await #expect(throws: (any Error).self) {
            try await GenerationBudgetGuard.authorize(input: package.pricingInput(), target: package.payload.target,
                editor: editor, approvedPackage: package, quoteLoader: { _, _ in
                    quotes += 1
                    return GenerationPackageFixture.money()
                })
        }
        #expect(quotes == 0)
        let option = SpendOption(modelId: package.payload.target.modelId, modelName: "Fixture", target: package.payload.target,
            credits: 10, requiresCatalogAvailability: false)
        let approval = SpendApproval(id: UUID().uuidString, recommendedOptionId: option.id, options: [option],
            actionLabel: "Generate image", requiresGenerationPackage: true)
        var runs = 0
        _ = try editor.agentService.requestSpendApproval(approval, origin: .direct, editor: editor,
            prepare: { _, _ in package }, execute: { _, _ in runs += 1; return .ok("unexpected submission") })
        editor.agentService.prepareSpendOption(option)
        for _ in 0..<1_000 {
            if editor.agentService.pendingSpendApproval?.options.first?.generationPackage != nil { break }
            await Task.yield()
        }
        let prepared = try #require(editor.agentService.pendingSpendApproval?.options.first)
        #expect(prepared.generationPackage == package)
        await editor.agentService.approveSpend(prepared)
        #expect(runs == 0)
        #expect(editor.agentService.pendingSpendApproval != nil)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func directVisualRequestsCannotBypassPricingWithoutAReviewOrProject() async throws {
        let editor = EditorViewModel()
        let target = ResolvedGenerationTarget(modelId: "fixture", provider: .fal, endpoint: "fixture", binding: nil)
        for modality in [GenerationRequest.Modality.image, .video] {
            let input = GenerationPricingInput(modelId: target.modelId, modality: modality, durationSeconds: 5,
                outputCount: 1, resolution: nil, quality: nil, promptCharacterCount: 0, generateAudio: nil)
            await #expect(throws: GenerationPricingFailure.providerPricingUnavailable) {
                try await GenerationBudgetGuard.authorize(input: input, target: target, editor: editor,
                    quoteLoader: { _, _ in throw GenerationPricingFailure.providerPricingUnavailable })
            }
        }
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
    }

    @Test func referenceDataDoesNotInventALiveCheckAndChecksStayBoundToTheirExactRoute() {
        let target = ResolvedGenerationTarget(modelId: "fixture", provider: .fal, endpoint: "endpoint", binding: nil)
        let reference = GenerationRouteReceipt(target: target, checks: [], capabilitySnapshot: nil)
        #expect(reference.state == .fromReference)
        #expect(reference.checks.isEmpty)
        let recorded = GenerationRouteReceipt.Check(modelID: "fixture", provider: .fal, transport: .api,
            endpoint: "endpoint", modelParam: nil, scope: .modelCatalog, source: "fixture://catalog",
            observedAt: "2026-04-02T12:00:00Z", evidenceSHA256: String(repeating: "a", count: 64))
        let checked = GenerationRouteReceipt(target: target, checks: [recorded], capabilitySnapshot: nil)
        #expect(checked.state == .liveChecked)
        #expect(checked.checks.first?.observedAt == "2026-04-02T12:00:00Z")
        let other = ResolvedGenerationTarget(modelId: "fixture", provider: .fal, endpoint: "other-endpoint", binding: nil)
        #expect(GenerationRouteReceipt(target: other, checks: [recorded], capabilitySnapshot: nil).state == .fromReference)
    }
    @Test func preparationCreatesNoSpendOrPlaceholderAndPackageChangesAreRejected() async throws {
        let editor = EditorViewModel()
        let (generation, package) = try await GenerationPackageFixture.prepare(editor: editor)
        #expect(editor.mediaAssets.isEmpty)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(package.payload.outputCount == 1)
        #expect(package.payload.prompt == generation.compiledPrompt)
        guard case .image(let submission, let parameters) = generation.submission else { Issue.record("Expected image"); return }
        var input = submission.genInput
        input.referenceReceipts = []; input.compileRecipe = generation.recipe
        try package.requireRequest(input: input, target: generation.target, parameters: parameters, references: [])
        let restored = try package.restoreParameters()
        try package.requireRequest(input: input, target: generation.target, parameters: restored, references: [])
        input.prompt = "A silently replaced prompt."
        #expect(throws: (any Error).self) { try package.requireRequest(input: input, target: generation.target, parameters: parameters, references: []) }
        var json = try #require(JSONSerialization.jsonObject(with: GenerationPackageV1.canonicalData(package)) as? [String: Any])
        var payload = try #require(json["payload"] as? [String: Any])
        payload["outputCount"] = 4
        json["payload"] = payload
        let tampered = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(GenerationPackageV1.self, from: tampered) }
        #expect(try JSONDecoder().decode(GenerationPackageV1.self, from: GenerationPackageV1.canonicalData(package)) == package)
    }

    @Test func aHigherPriceCannotConsumeTheReviewedRequest() async throws {
        let editor = EditorViewModel()
        let (generation, package) = try await GenerationPackageFixture.prepare(editor: editor)
        let pricing = try package.pricingInput()
        await #expect(throws: (any Error).self) {
            try await GenerationBudgetGuard.authorize(input: pricing, target: generation.target, editor: editor,
                approvedPackage: package, quoteLoader: { _, _ in GenerationPackageFixture.money(1) })
        }
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
    }

    @Test func concurrentRetriesJoinTheSamePreparedExecution() async throws {
        let editor = EditorViewModel()
        let (_, package) = try await GenerationPackageFixture.prepare(editor: editor)
        var runs = 0
        let prepared = AgentPreparedGeneration(package: package) {
            runs += 1
            await Task.yield()
            return .ok("one provider job")
        }
        async let first = prepared.execute()
        async let second = prepared.execute()
        _ = try await (first, second)
        #expect(runs == 1)
    }

    @Test func spendCardRequiresTheExactPreparedOption() async throws {
        let editor = EditorViewModel()
        let (_, package) = try await GenerationPackageFixture.prepare(editor: editor)
        let option = SpendOption(modelId: package.payload.target.modelId, modelName: "Fixture", target: package.payload.target,
            credits: 10, requiresCatalogAvailability: false)
        let approval = SpendApproval(id: UUID().uuidString, recommendedOptionId: option.id, options: [option],
            actionLabel: "Generate image", requiresGenerationPackage: true)
        var runs = 0
        _ = try editor.agentService.requestSpendApproval(approval, origin: .direct, editor: editor,
            prepare: { _, _ in package }, execute: { _, selected in
                #expect(selected.generationPackage == package)
                runs += 1
                return .ok("completed")
            })
        await editor.agentService.approveSpend(option)
        #expect(runs == 0)
        editor.agentService.prepareSpendOption(option)
        for _ in 0..<1_000 {
            if editor.agentService.pendingSpendApproval?.options.first?.generationPackage != nil { break }
            await Task.yield()
        }
        let prepared = try #require(editor.agentService.pendingSpendApproval?.options.first)
        #expect(prepared.generationPackage == package)
        await editor.agentService.approveSpend(option)
        #expect(runs == 0)
        await editor.agentService.approveSpend(prepared)
        for _ in 0..<1_000 {
            if !editor.agentService.spendApprovalIsRunning { break }
            await Task.yield()
        }
        #expect(runs == 1)
    }
}
