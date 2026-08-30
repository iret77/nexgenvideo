import Foundation
import Testing
@testable import NexGenVideo
import NexGenEngine

/// #223 — Aleph 2 on the source-video edit path, and the profile selecting itself from the model.
@Suite("restyle model wiring (#223)")
@MainActor
struct RestyleModelTests {

    @Test("Aleph is registered as a source-video edit model")
    func alephRequiresSourceVideo() throws {
        let model = try #require(RunwayModelRegistry.model(for: "runway/aleph2"))
        // aleph2, not gen4_aleph: the predecessor is sunset 2026-07-30. Verified against the live
        // account model list, which is also what now gates the entry.
        #expect(model.apiModel == "aleph2")
        // requiresSourceVideo is what routes it to the edit path AND selects the restyle prompt profile.
        #expect(RunwayModelRegistry.requiresSourceVideo(model))
        // The i2v models must NOT be treated as restyles.
        let gen45 = try #require(RunwayModelRegistry.model(for: "runway/gen4.5"))
        #expect(!RunwayModelRegistry.requiresSourceVideo(gen45))
    }

    @Test("Aleph advertises no durations — the output follows the source clip")
    func alephHasNoDurationKnob() throws {
        let model = try #require(RunwayModelRegistry.model(for: "runway/aleph2"))
        guard case .video(let caps) = model.entry.uiCapabilities else {
            Issue.record("expected video capabilities"); return
        }
        // A duration here would be a knob that does nothing.
        #expect(caps.durations.isEmpty)
        // The source clip is the input; it takes no reference images.
        #expect(caps.maxTotalReferences == 0)
        #expect(!caps.requiresReferenceImage)
    }

    @Test("Aleph is a Runway model and resolves to the Runway provider")
    func alephRoutesToRunway() {
        #expect(RunwayModelRegistry.isRunwayModel("runway/aleph2"))
        #expect(ProviderManifest.nominalProvider(forModelId: "runway/aleph2") == .runway)
    }

    // MARK: - Discovery gate (the owner's #223 decision, honoured)

    @Test("No Runway model is launch-seeded without account entitlement")
    func runwayIsNotLaunchSeeded() {
        #expect(!ModelCatalog.launchEntries.contains { $0.id.hasPrefix("runway/") })
        #expect(RunwayModelRegistry.entries.contains { $0.id == "runway/gen4.5" })
        #expect(RunwayModelRegistry.entries.contains { $0.id == "runway/aleph2" })
    }

    @Test("an account carrying aleph2 gets the entry; one without it gets nothing")
    func alephAppearsOnlyWhenTheAccountHasIt() throws {
        let entries = RunwayModelRegistry.discoveredEntries(availableModelIds: ["aleph2", "gen4.5"])
        let entry = try #require(entries.first { $0.id == "runway/aleph2" })
        #expect(entry.offers?.first?.provider == .runway)

        // An account still on the sunset model gets no restyle entry rather than a dying one.
        #expect(RunwayModelRegistry.discoveredEntries(availableModelIds: ["gen4_aleph"]).isEmpty)
        #expect(RunwayModelRegistry.discoveredEntries(availableModelIds: []).isEmpty)
    }

    @Test("Runway account discovery exposes every supported entitled image model")
    func runwayImageCatalogUsesTheAccountInventory() {
        let entitled: Set<String> = [
            "gen4_image_turbo", "gen4_image", "gpt_image_2", "gemini_image3_pro",
            "gemini_image3.1_flash", "seedream5_pro", "seedream5_lite",
            "grok_imagine_image_2", "gemini_2.5_flash", "unimplemented_model",
        ]
        let entries = RunwayModelRegistry.discoveredEntries(availableModelIds: entitled)
        let imageModels = Set(entries.filter { $0.kind == .image }.map(\.id))

        #expect(imageModels == [
            "runway/gen4_image_turbo", "runway/gen4_image", "runway/gpt_image_2",
            "runway/gemini_image3_pro", "runway/gemini_image3.1_flash",
            "runway/seedream5_pro", "runway/seedream5_lite",
            "runway/grok_imagine_image_2", "runway/gemini_2.5_flash",
        ])
        #expect(entries.allSatisfy { $0.id != "runway/unimplemented_model" })
    }

    @Test("Four-reference requests keep only Runway models that accept all four")
    func runwayFourReferenceCompatibilityIsExact() {
        let compatible = Set(RunwayModelRegistry.models.compactMap { model -> String? in
            guard case .image(let caps) = model.entry.uiCapabilities else { return nil }
            let config = ImageModelConfig(entry: model.entry, caps: caps)
            return config.validate(
                aspectRatio: "9:16",
                resolution: nil,
                quality: nil,
                imageRefCount: 4,
                numImages: 1
            ) == nil ? model.apiModel : nil
        })

        #expect(compatible == [
            "gpt_image_2", "gemini_image3_pro", "gemini_image3.1_flash",
            "seedream5_pro", "seedream5_lite",
        ])
    }

    @Test("Runway text-to-image body preserves every reference and the selected model")
    func runwayRequestBodyPreservesReferences() throws {
        let model = try #require(RunwayModelRegistry.model(for: "runway/gpt_image_2"))
        let references = (1...4).map { "runway://reference-\($0)" }
        let body = try RunwayClient.textToImageBody(
            model: model,
            params: ImageGenerationParams(
                prompt: "compiled lighting anchor",
                aspectRatio: "9:16",
                resolution: nil,
                quality: "high",
                imageURLs: references,
                numImages: 1
            )
        )

        #expect(body["model"] as? String == "gpt_image_2")
        #expect(body["ratio"] as? String == "1088:1920")
        #expect(body["quality"] as? String == "high")
        #expect((body["referenceImages"] as? [[String: String]])?.map { $0["uri"] } == references)
    }

    @Test("Runway request encoding rejects reference overflow before submission")
    func runwayRequestBodyRejectsReferenceOverflow() throws {
        let model = try #require(RunwayModelRegistry.model(for: "runway/gen4_image"))
        let params = ImageGenerationParams(
            prompt: "compiled lighting anchor",
            aspectRatio: "16:9",
            resolution: nil,
            quality: nil,
            imageURLs: (1...4).map { "runway://reference-\($0)" },
            numImages: 1
        )

        #expect(throws: (any Error).self) {
            try RunwayClient.textToImageBody(model: model, params: params)
        }
    }

    @Test("Four-reference spend choices span every compatible active provider")
    func fourReferenceSpendChoicesUseTheCompatibleCatalog() throws {
        let entitledRunway: Set<String> = [
            "gen4_image_turbo", "gen4_image", "gpt_image_2", "gemini_image3_pro",
            "gemini_image3.1_flash", "seedream5_pro", "seedream5_lite",
            "grok_imagine_image_2", "gemini_2.5_flash",
        ]
        let higgsfield = CatalogEntry(
            id: "higgsfield/nano-banana-2",
            kind: .image,
            displayName: "Nano Banana 2",
            allowedEndpoints: ["generate_image"],
            responseShape: .images,
            uiCapabilities: .image(ImageCaps(
                resolutions: nil,
                aspectRatios: ["16:9", "9:16", "1:1"],
                qualities: nil,
                supportsImageReference: true,
                maxReferenceImages: 14,
                maxImages: 1
            )),
            offers: [ProviderOffer(
                provider: .higgsfield,
                transport: .mcp,
                providerRef: "generate_image",
                modelParam: "nano-banana-2",
                mcpMediaRoles: ["image_references"]
            )]
        )
        let entries = FalModelRegistry.entries
            + RunwayModelRegistry.discoveredEntries(availableModelIds: entitledRunway)
            + [higgsfield]
        let models = entries.compactMap { entry -> ImageModelConfig? in
            guard case .image(let caps) = entry.uiCapabilities else { return nil }
            return ImageModelConfig(entry: entry, caps: caps)
        }
        let candidates = ImageAlternativeResolver.candidates(
            models: models,
            excluding: "fal-ai/gemini-25-flash-image/edit",
            aspectRatio: "9:16",
            resolution: nil,
            quality: nil,
            referenceCount: 4,
            isAvailable: { _ in true }
        )
        let entriesById = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let activation = ProviderActivation(active: [
            .init(provider: .fal, transport: .api),
            .init(provider: .runway, transport: .api),
            .init(provider: .higgsfield, transport: .mcp),
        ])
        let options = SpendOptionBuilder.options(
            candidates: candidates.map {
                SpendModelCandidate(
                    modelId: $0.model.id,
                    modelName: $0.model.displayName,
                    credits: nil
                )
            },
            isModelAvailable: { _ in true },
            runnableBindings: { modelId in
                guard let entry = entriesById[modelId], let offers = entry.offers else { return [] }
                return ProviderResolver.preferredActiveBindingPerProvider(
                    bindings: ProviderManifest.bindings(from: offers, modelId: modelId),
                    activation: activation,
                    effectiveCost: ProviderManifest.effectiveCost
                )
            }
        )

        #expect(Set(options.map(\.providerLabel)) == ["fal.ai", "Runway", "Higgsfield"])
        #expect(options.filter { $0.target.provider == .fal }.count == 3)
        #expect(options.filter { $0.target.provider == .runway }.count == 5)
        #expect(options.filter { $0.target.provider == .higgsfield }.count == 1)
        let originalBinding = ProviderBinding(
            provider: .fal,
            transport: .api,
            kind: .generation,
            providerRef: "fal-ai/gemini-25-flash-image/edit",
            billing: .perCall
        )
        let originalTarget = ResolvedGenerationTarget(
            modelId: "fal-ai/gemini-25-flash-image/edit",
            provider: .fal,
            endpoint: originalBinding.providerRef,
            binding: originalBinding
        )
        let recommended = try #require(SpendOptionBuilder.recommended(
            from: options,
            currentModelId: originalTarget.modelId,
            defaultTarget: originalTarget
        ))
        #expect(recommended.target.provider != .fal)
    }

    @Test("discovery covers Runway alongside the image providers")
    func discoveryIncludesRunway() {
        #expect(DirectImageDiscovery.providers.contains(.runway))
    }

    @Test("Production Design derives every staged image reference")
    func productionDesignReferenceSetIsHostOwned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let refs = root.appendingPathComponent(
            "production_design/refs/nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: refs,
            withIntermediateDirectories: true
        )
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        ))
        try png.write(to: refs.appendingPathComponent("character.png"))
        try png.write(to: refs.deletingLastPathComponent()
            .appendingPathComponent("palette.png"))
        try Data([0]).write(to: refs.appendingPathComponent("broken.jpg"))
        try Data([0]).write(to: refs.appendingPathComponent("notes.txt"))

        let paths = try ToolExecutor.productionDesignReferencePaths(dataRoot: root)

        #expect(paths == [
            "production_design/refs/nested/character.png",
            "production_design/refs/palette.png",
        ])
    }

    @Test("it was the first model on the edit path — which is no longer a facade")
    func editPathNowHasAModel() {
        // generateVideoEdit and the submission's requiresSourceVideo branch existed with nothing
        // routing to them. If this ever returns empty again, the edit path is dead code once more.
        let editModels = RunwayModelRegistry.models.filter { RunwayModelRegistry.requiresSourceVideo($0) }
        #expect(!editModels.isEmpty)
    }
}
