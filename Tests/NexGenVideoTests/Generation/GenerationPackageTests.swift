import Foundation
import Testing
@testable import NexGenVideo

@MainActor
enum GenerationPackageFixture {
    static func money(_ amount: Double = 0.25) -> GenerationMoney {
        .init(nativeAmount: amount, nativeCurrency: "EUR", eurAmount: amount, eurPerNativeUnit: 1,
            exchangeRateDate: "2026-09-09", pricingSource: "fixture://pricing", exchangeRateSource: "fixture://exchange")
    }

    static func prepare(
        editor: EditorViewModel,
        model: String = "fixture-image",
        provider: GenerationProvider = .fal,
        endpoint: String? = nil
    ) async throws
        -> (GenerationController.PreparedGeneration, GenerationPackageV1) {
        let target = ResolvedGenerationTarget(
            modelId: model,
            provider: provider,
            endpoint: endpoint ?? model,
            binding: nil
        )
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
        let package = try await GenerationController.prepareReviewPackage(generation, editor: editor, quoteLoader: { _, _ in money() })
        return (generation, package)
    }
}

@Suite("Generation package approval binding")
@MainActor
struct GenerationPackageTests {
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
        let pricing = GenerationPricingInput(modelId: generation.target.modelId, modality: .image,
            durationSeconds: nil, outputCount: 1, resolution: nil, quality: nil, promptCharacterCount: 0,
            generateAudio: nil, referenceCount: 0)
        await #expect(throws: (any Error).self) {
            try await GenerationBudgetGuard.authorize(input: pricing, target: generation.target, editor: editor,
                approvedPackage: package, quoteLoader: { _, _ in GenerationPackageFixture.money(1) })
        }
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
    }

    @Test func anUnpricedReviewedPackageCannotReachDispatch() async throws {
        let editor = EditorViewModel()
        let (generation, package) = try await GenerationPackageFixture.prepare(editor: editor)
        let unpriced = try package.replacingPricing(
            estimate: nil,
            failure: .init(
                reason: .priceQueryUnavailable,
                provider: .fal,
                endpoint: generation.target.endpoint,
                detail: "fixture outage"
            )
        )
        let pricing = try unpriced.pricingInput()
        var quoteCount = 0
        await #expect(throws: (any Error).self) {
            try await GenerationBudgetGuard.authorize(
                input: pricing,
                target: generation.target,
                editor: editor,
                approvedPackage: unpriced,
                requiresVerifiedCeiling: true,
                quoteLoader: { _, _ in
                    quoteCount += 1
                    return GenerationPackageFixture.money()
                }
            )
        }
        #expect(quoteCount == 0)
        #expect(editor.generationLog.spendEvents.isEmpty)
        #expect(editor.mediaAssets.isEmpty)
    }

    @Test func individualNoStopApprovalKeepsProviderAgnosticUnpricedPolicy() async throws {
        let editor = EditorViewModel()
        let (generation, package) = try await GenerationPackageFixture.prepare(editor: editor)
        let unpriced = try package.replacingPricing(
            estimate: nil,
            failure: .init(
                reason: .unsupportedCombination,
                provider: generation.target.provider,
                endpoint: generation.target.endpoint,
                detail: "fixture provider has no pre-dispatch quote"
            )
        )
        let authorization = try await GenerationBudgetGuard.authorize(
            input: unpriced.pricingInput(),
            target: generation.target,
            editor: editor,
            approvedPackage: unpriced,
            quoteLoader: { _, _ in throw GenerationPricingFailure(
                reason: .unsupportedCombination,
                provider: generation.target.provider,
                endpoint: generation.target.endpoint,
                detail: "fixture provider has no pre-dispatch quote"
            ) }
        )
        #expect(authorization.estimate == nil)
        #expect(editor.generationLog.spendEvents.isEmpty)
    }

    @Test func pricingFailuresRemainTypedInTheReviewBinding() async throws {
        for reason in [GenerationPricingFailure.Reason.unsupportedCombination,
                       .priceQueryUnavailable, .exchangeRateUnavailable] {
            let editor = EditorViewModel()
            let (generation, _) = try await GenerationPackageFixture.prepare(editor: editor)
            let package = try await GenerationController.prepareReviewPackage(
                try await GenerationController.prepare(generation.request, editor: editor).get(),
                editor: editor,
                quoteLoader: { target, _ in
                    throw GenerationPricingFailure(
                        reason: reason,
                        provider: target.provider,
                        endpoint: target.endpoint,
                        detail: "fixture \(reason.rawValue)"
                    )
                }
            )
            #expect(package.payload.estimate == nil)
            #expect(package.payload.pricingFailure?.reason == reason)
            #expect(package.payload.pricingFailure?.isRetryable == (reason != .unsupportedCombination))
        }
    }

    @Test func restoredAutomaticVideoUsesItsBoundBilledDurationForPricing() async throws {
        let editor = EditorViewModel()
        let (_, imagePackage) = try await GenerationPackageFixture.prepare(editor: editor)
        var input = imagePackage.payload.generationInput
        input.duration = 10
        input.videoDuration = .automatic
        let parameters = try PreparedProviderParameters(
            parameters: .video(.init(
                prompt: imagePackage.payload.prompt,
                duration: .automatic,
                aspectRatio: input.aspectRatio,
                resolution: nil,
                sourceVideoURL: nil,
                startFrameURL: nil,
                endFrameURL: nil,
                referenceImageURLs: [],
                referenceVideoURLs: [],
                referenceAudioURLs: [],
                generateAudio: false
            )),
            referenceSlots: []
        )
        let package = try GenerationPackageV1(payload: .init(
            target: imagePackage.payload.target,
            modality: "video",
            operation: "generate_video",
            intent: imagePackage.payload.intent,
            prompt: imagePackage.payload.prompt,
            promptRevisionID: imagePackage.payload.promptRevisionID,
            generationInput: input,
            binding: imagePackage.payload.binding,
            compilerInputsSHA256: imagePackage.payload.compilerInputsSHA256,
            recipe: imagePackage.payload.recipe,
            repairPlanID: imagePackage.payload.repairPlanID,
            destination: imagePackage.payload.destination,
            outputCount: 1,
            references: [],
            referenceRoles: [],
            requestParametersJSON: GenerationPackageV1.requestJSON(
                parameters: parameters,
                references: []
            ),
            routing: imagePackage.payload.routing,
            routeReceipt: imagePackage.payload.routeReceipt,
            estimate: imagePackage.payload.estimate,
            pricingFailure: nil
        ))
        #expect(try package.pricingInput().durationSeconds == 10)
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
