import Foundation
import NexGenEngine
import Testing

@testable import NexGenVideo

@Suite("Brief-bound Production Design image model")
struct BriefImageModelBindingTests {
    private enum FixtureError: Error {
        case expectedImageEntry
    }

    private static let sunburstEdit = "fal-ai/gpt-image-2.5/sunburst/edit"
    private static let nanoBananaProEdit = "fal-ai/nano-banana-pro/edit"

    @Test("Every brief image value maps to its exact host model or to none")
    func catalogMappingIsExact() {
        let expected: [FrameImageModel: String?] = [
            .googleGemini3Pro: "google/gemini-3-pro-image",
            .googleGemini31Flash: "google/gemini-3.1-flash-image",
            .googleImagen4Ultra: nil,
            .openaiGptImage2: nil,
            .openaiGptImage1: nil,
            .runwayGemini3Pro: "runway/gemini_image3_pro",
            .runwayGemini31Flash: "runway/gemini_image3.1_flash",
            .runwayGemini25Flash: "runway/gemini_2.5_flash",
            .runwayGen4Image: "runway/gen4_image",
            .runwayGen4ImageTurbo: "runway/gen4_image_turbo",
            .falNanoBanana: "fal-ai/nano-banana",
            .falImagen4Ultra: "fal-ai/imagen4/preview/ultra",
            .falGptImage1: "fal-ai/gpt-image-1",
            .falFluxPro11: "fal-ai/flux-pro/v1.1",
            .other: nil,
            .falGptImage25Flare: "fal-ai/gpt-image-2.5/flare/text-to-image",
            .falGptImage25FlareEdit: "fal-ai/gpt-image-2.5/flare/edit",
            .falGptImage25Sunburst: "fal-ai/gpt-image-2.5/sunburst/text-to-image",
            .falGptImage25SunburstEdit: Self.sunburstEdit,
        ]
        #expect(Set(expected.keys) == Set(FrameImageModel.allCases))
        for model in FrameImageModel.allCases {
            #expect(BriefImageModelBinding.catalogModelID(for: model) == expected[model] ?? nil)
        }
        for id in [
            "fal-ai/nano-banana", "fal-ai/flux-pro/v1.1",
            "fal-ai/gpt-image-2.5/flare/text-to-image", "fal-ai/gpt-image-2.5/flare/edit",
            "fal-ai/gpt-image-2.5/sunburst/text-to-image", Self.sunburstEdit,
        ] {
            #expect(FalModelRegistry.model(for: id) != nil)
        }
        for id in [
            "runway/gemini_image3_pro", "runway/gemini_image3.1_flash", "runway/gemini_2.5_flash",
            "runway/gen4_image", "runway/gen4_image_turbo",
        ] {
            #expect(RunwayModelRegistry.model(for: id) != nil)
        }
        #expect(GoogleModelRegistry.model(for: "google/gemini-3-pro-image") != nil)
        #expect(GoogleModelRegistry.model(for: "google/gemini-3.1-flash-image") != nil)
    }

    @Test("Production Design binds Bible images and falls back to the frame route")
    func productionDesignUsesBibleRoute() throws {
        let bound = BriefImageModelBinding.productionDesign(
            try brief(frame: .falGptImage25Sunburst, bible: .falGptImage25SunburstEdit)
        )
        #expect(bound.briefField == "bible_image_model")
        #expect(bound.catalogModelID == Self.sunburstEdit)
        #expect(bound.source == "Bible images in the brief")

        let fallback = BriefImageModelBinding.productionDesign(
            try brief(frame: .falGptImage25FlareEdit, bible: nil)
        )
        #expect(fallback.briefField == "frame_image_model")
        #expect(fallback.catalogModelID == "fal-ai/gpt-image-2.5/flare/edit")
    }

    @MainActor
    @Test("Reading the binding leaves brief.yaml byte-identical and fails closed without a brief")
    func bindingReadIsReadOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: ToolError.self) {
            try BriefImageModelBinding.productionDesign(dataRoot: root)
        }

        try YAMLArtifactStore(dataRoot: root).save(
            try brief(frame: .falGptImage25Sunburst, bible: .falGptImage25SunburstEdit),
            to: PipelineLayout.briefFile
        )
        let briefURL = PipelineLayout.url(PipelineLayout.briefFile, in: root)
        let before = try Data(contentsOf: briefURL)
        let binding = try BriefImageModelBinding.productionDesign(dataRoot: root)
        #expect(binding.catalogModelID == Self.sunburstEdit)
        #expect(try Data(contentsOf: briefURL) == before)
    }

    @MainActor
    @Test("A divergent agent model is refused; an omitted one resolves to the brief model")
    func agentModelCannotReplaceBriefModel() throws {
        let catalog = try models([Self.sunburstEdit, Self.nanoBananaProEdit])
        let binding = BriefImageModelBinding.productionDesign(
            try brief(frame: .falGptImage25Sunburst, bible: .falGptImage25SunburstEdit)
        )

        #expect(try ToolExecutor.requiredBriefImageModel(
            binding, requestedModelID: nil, catalog: catalog
        )?.id == Self.sunburstEdit)
        #expect(try ToolExecutor.requiredBriefImageModel(
            binding, requestedModelID: Self.sunburstEdit, catalog: catalog
        )?.id == Self.sunburstEdit)
        do {
            _ = try ToolExecutor.requiredBriefImageModel(
                binding, requestedModelID: Self.nanoBananaProEdit, catalog: catalog
            )
            Issue.record("A divergent agent model must be refused.")
        } catch let error as ToolError {
            #expect(error.localizedDescription.contains("brief.bible_image_model"))
            #expect(error.localizedDescription.contains(Self.sunburstEdit))
        }
    }

    @MainActor
    @Test("A brief model missing from the catalog is reported, not silently replaced")
    func missingBriefModelHasReason() throws {
        let catalog = try models([Self.nanoBananaProEdit])
        let binding = BriefImageModelBinding.productionDesign(
            try brief(frame: .falGptImage25Sunburst, bible: .falGptImage25SunburstEdit)
        )
        #expect(try ToolExecutor.requiredBriefImageModel(
            binding, requestedModelID: Self.nanoBananaProEdit, catalog: catalog
        ) == nil)
        #expect(binding.unmappedReason(in: catalog)?.contains("not in the live model catalog") == true)

        let openAI = BriefImageModelBinding.productionDesign(
            try brief(frame: .falGptImage25Sunburst, bible: .openaiGptImage2)
        )
        #expect(openAI.catalogModelID == nil)
        #expect(openAI.unmappedReason(in: catalog) != nil)
    }

    @Test("The brief model is recommended regardless of offering order; absent, nothing is")
    func requiredModelRecommendationIgnoresOrder() {
        let sunburst = option(modelID: Self.sunburstEdit, provider: .fal)
        let nano = option(modelID: Self.nanoBananaProEdit, provider: .fal)
        let unrelatedTarget = option(modelID: "unrelated", provider: .runway).target
        for options in [[sunburst, nano], [nano, sunburst]] {
            #expect(SpendOptionBuilder.recommended(
                from: options, requiredModelId: Self.sunburstEdit, defaultTarget: unrelatedTarget
            ) == sunburst)
        }
        #expect(SpendOptionBuilder.recommended(
            from: [nano], requiredModelId: Self.sunburstEdit, defaultTarget: nano.target
        ) == nil)
        #expect(SpendOptionBuilder.recommended(
            from: [nano], requiredModelId: nil, defaultTarget: nano.target
        ) == nil)
    }

    @Test("An earlier image choice never replaces the brief model on the card")
    func storedSelectionCannotReplaceBriefModel() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sunburst = option(modelID: Self.sunburstEdit, provider: .fal)
        let nano = option(modelID: Self.nanoBananaProEdit, provider: .fal)
        SpendSelectionPreferences.record(
            nano,
            for: SpendApproval(
                id: "earlier",
                recommendedOptionId: nano.id,
                options: [nano],
                actionLabel: "Generate image",
                selectionScope: .image
            ),
            defaults: defaults
        )

        let bound = SpendSelectionPreferences.applyingStoredSelection(
            to: SpendApproval(
                id: "anchor",
                recommendedOptionId: sunburst.id,
                options: [sunburst, nano],
                actionLabel: "Generate image",
                selectionScope: .image,
                modelRequirement: requirement(unavailable: nil)
            ),
            defaults: defaults
        )
        #expect(bound.recommendedOptionId == sunburst.id)
        #expect(bound.options.first == sunburst)

        let unavailable = SpendSelectionPreferences.applyingStoredSelection(
            to: SpendApproval(
                id: "anchor-unavailable",
                recommendedOptionId: "",
                options: [nano],
                actionLabel: "Generate image",
                selectionScope: .image,
                modelRequirement: requirement(unavailable: "Not runnable.")
            ),
            defaults: defaults
        )
        #expect(unavailable.recommendedOptionId == "")
    }

    @Test("The stored provider still applies to the brief model itself")
    func storedProviderAppliesToBriefModel() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let falSunburst = option(modelID: Self.sunburstEdit, provider: .fal)
        let runwaySunburst = option(modelID: Self.sunburstEdit, provider: .runway)
        let runwayOther = option(modelID: "runway/other", provider: .runway)
        SpendSelectionPreferences.record(
            runwayOther,
            for: SpendApproval(
                id: "earlier",
                recommendedOptionId: runwayOther.id,
                options: [runwayOther],
                actionLabel: "Generate image",
                selectionScope: .image
            ),
            defaults: defaults
        )
        let approval = SpendSelectionPreferences.applyingStoredSelection(
            to: SpendApproval(
                id: "anchor",
                recommendedOptionId: falSunburst.id,
                options: [falSunburst, runwaySunburst, runwayOther],
                actionLabel: "Generate image",
                selectionScope: .image,
                modelRequirement: requirement(unavailable: nil)
            ),
            defaults: defaults
        )
        #expect(approval.recommendedOptionId == runwaySunburst.id)
    }

    @Test("A one-time model change is not remembered; the brief model choice is")
    func modelChangeIsNotRecorded() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sunburst = option(modelID: Self.sunburstEdit, provider: .fal)
        let nano = option(modelID: Self.nanoBananaProEdit, provider: .fal)
        let approval = SpendApproval(
            id: "anchor",
            recommendedOptionId: sunburst.id,
            options: [sunburst, nano],
            actionLabel: "Generate image",
            selectionScope: .image,
            modelRequirement: requirement(unavailable: nil)
        )
        let key = SpendSelectionPreferences.defaultsKey(for: .image)

        SpendSelectionPreferences.record(nano, for: approval, defaults: defaults)
        #expect(defaults.dictionary(forKey: key) == nil)

        SpendSelectionPreferences.record(sunburst, for: approval, defaults: defaults)
        #expect(defaults.dictionary(forKey: key)?["model_id"] as? String == Self.sunburstEdit)
    }

    @Test("Catalog evaluation names why the brief model was excluded")
    func exclusionReasonsAreConcrete() throws {
        let entries = FalModelRegistry.discoveredEntries(
            availableModelIds: ["openai/gpt-image-2.5/sunburst/edit", Self.nanoBananaProEdit]
        ).filter { [Self.sunburstEdit, Self.nanoBananaProEdit].contains($0.id) }
        let catalog = try entries.map(imageModel)
        let offers = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.offers ?? []) })
        let fal = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
        func evaluate(
            models: [ImageModelConfig] = catalog,
            references: Int = 4,
            activation: ProviderActivation = fal,
            enabled: @escaping (String) -> Bool = { _ in true },
            verified: Bool = true
        ) -> CatalogImageOfferingEvaluation {
            ModelCatalog.imageOfferingEvaluation(
                models: models,
                offersByModelID: offers,
                preferredModelID: Self.sunburstEdit,
                aspectRatio: "1:1",
                resolution: "1024x1024",
                quality: "high",
                referenceCount: references,
                activation: activation,
                isEnabled: enabled,
                offeringIsVerified: { _, _ in verified }
            )
        }

        let runnable = evaluate()
        #expect(runnable.offerings.first?.model.id == Self.sunburstEdit)
        #expect(runnable.exclusionReason(for: Self.sunburstEdit) == nil)
        #expect(evaluate(models: Array(catalog.reversed())).offerings.first?.model.id == Self.sunburstEdit)

        #expect(evaluate(references: 17).exclusionReason(for: Self.sunburstEdit)?
            .contains("at most 16 reference images") == true)
        #expect(evaluate(enabled: { $0 != Self.sunburstEdit }).exclusionReason(for: Self.sunburstEdit)?
            .contains("turned off") == true)
        #expect(evaluate(activation: ProviderActivation(active: [])).exclusionReason(for: Self.sunburstEdit)?
            .contains("needs a connected provider: fal.ai") == true)
        #expect(evaluate(verified: false).exclusionReason(for: Self.sunburstEdit)?
            .contains("has not confirmed") == true)
    }

    private func brief(frame: FrameImageModel, bible: FrameImageModel?) throws -> Brief {
        try Brief(
            project: "demo", generated: "2026-10-10", mission: .demo,
            targetPlatform: "web", aspectRatio: .landscape16x9, projectMode: "beat",
            frameImageModel: frame, bibleImageModel: bible,
            conceptType: .abstract, visualMedium: .liveActionRealistic,
            figures: .none, lyricsIntegration: .ignored
        )
    }

    private func requirement(unavailable: String?) -> SpendModelRequirement {
        SpendModelRequirement(
            modelId: Self.sunburstEdit,
            modelName: "GPT Image 2.5 Sunburst (edit)",
            source: "Bible images in the brief",
            unavailableReason: unavailable
        )
    }

    private func models(_ ids: [String]) throws -> [ImageModelConfig] {
        let available = Set(ids + ids.map { "openai/" + $0.dropFirst("fal-ai/".count) })
        return try FalModelRegistry.discoveredEntries(availableModelIds: available)
            .filter { ids.contains($0.id) }
            .map(imageModel)
    }

    private func imageModel(_ entry: CatalogEntry) throws -> ImageModelConfig {
        guard case .image(let caps) = entry.uiCapabilities else {
            throw FixtureError.expectedImageEntry
        }
        return ImageModelConfig(entry: entry, caps: caps)
    }

    private func option(modelID: String, provider: GenerationProvider) -> SpendOption {
        let binding = ProviderBinding(
            provider: provider,
            transport: .api,
            kind: .generation,
            providerRef: modelID,
            billing: .perCall
        )
        return SpendOption(
            modelId: modelID,
            modelName: modelID,
            target: ResolvedGenerationTarget(
                modelId: modelID,
                provider: provider,
                endpoint: modelID,
                binding: binding
            ),
            credits: nil,
            requiresCatalogAvailability: false
        )
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "BriefImageModelBindingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }
}
