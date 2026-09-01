import Testing

@testable import NexGenVideo

@Suite("Image offering selection")
struct ImageOfferingSelectionTests {
    private enum FixtureError: Error {
        case expectedImageEntry
    }

    @Test("Every active live provider contributes each request-compatible image offering")
    func allLiveCompatibleProvidersAppear() throws {
        let fal = try #require(FalModelRegistry.discoveredEntries(
            availableModelIds: ["fal-ai/nano-banana-pro/edit"]
        ).first { $0.id == "fal-ai/nano-banana-pro/edit" })
        let runway = try #require(RunwayModelRegistry.discoveredEntries(
            availableModelIds: ["gpt_image_2"]
        ).first { $0.id == "runway/gpt_image_2" })
        let google = try #require(GoogleModelRegistry.entries(
            availableModelIds: ["gemini-3-pro-image"]
        ).first { $0.id == "google/gemini-3-pro-image" })
        let higgsfield = mcpEntry(
            id: "higgsfield/nano-banana-2",
            name: "Nano Banana 2",
            provider: .higgsfield,
            modelParam: "nano-banana-2"
        )
        let openart = mcpEntry(
            id: "openart/image-pro",
            name: "OpenArt Image Pro",
            provider: .openart,
            modelParam: "image-pro"
        )
        let entries = [fal, runway, google, higgsfield, openart]
        let discovered: [GenerationProvider: [CatalogEntry]] = [
            .fal: [fal],
            .runway: [runway],
            .google: [google],
            .higgsfield: [higgsfield],
            .openart: [openart],
        ]
        let discovery: [GenerationProvider: ProviderDiscoveryState] = [
            .fal: .ready(modelCount: 1),
            .runway: .ready(modelCount: 1),
            .google: .ready(modelCount: 1),
            .higgsfield: .ready(modelCount: 1),
            .openart: .ready(modelCount: 1),
        ]
        let candidates = ModelCatalog.compatibleImageOfferings(
            models: try entries.map(imageModel),
            offersByModelID: offersByID(entries),
            preferredModelID: fal.id,
            aspectRatio: "9:16",
            resolution: nil,
            quality: nil,
            referenceCount: 4,
            activation: ProviderActivation(active: [
                .init(provider: .fal, transport: .api),
                .init(provider: .runway, transport: .api),
                .init(provider: .google, transport: .api),
                .init(provider: .higgsfield, transport: .mcp),
                .init(provider: .openart, transport: .mcp),
            ]),
            isEnabled: { _ in true },
            offeringIsVerified: { modelID, binding in
                ModelCatalog.imageOfferingIsVerified(
                    modelID: modelID,
                    binding: binding,
                    discoveredByProvider: discovered,
                    providerDiscovery: discovery
                )
            }
        )

        #expect(Set(candidates.map(\.target.provider)) == [
            .fal, .runway, .google, .higgsfield, .openart,
        ])
        #expect(candidates.allSatisfy {
            $0.model.validate(
                aspectRatio: $0.aspectRatio,
                resolution: $0.resolution,
                quality: $0.quality,
                imageRefCount: 4,
                numImages: 1
            ) == nil
        })
    }

    @Test("Fal live aliases retain the internal model identity and exact dispatch endpoint")
    func falAliasesRemainRunnableOfferings() throws {
        let entries = FalModelRegistry.discoveredEntries(
            availableModelIds: [
                "fal-ai/nano-banana",
                "openai/gpt-image-2",
            ]
        ).filter { entry in
            ["fal-ai/nano-banana", "fal-ai/gpt-image-2"].contains(entry.id)
        }
        let discovered = [GenerationProvider.fal: entries]
        let candidates = ModelCatalog.compatibleImageOfferings(
            models: try entries.map(imageModel),
            offersByModelID: offersByID(entries),
            preferredModelID: "fal-ai/nano-banana",
            aspectRatio: "9:16",
            resolution: nil,
            quality: nil,
            referenceCount: 0,
            activation: ProviderActivation(active: [
                .init(provider: .fal, transport: .api),
            ]),
            isEnabled: { _ in true },
            offeringIsVerified: { modelID, binding in
                ModelCatalog.imageOfferingIsVerified(
                    modelID: modelID,
                    binding: binding,
                    discoveredByProvider: discovered,
                    providerDiscovery: [.fal: .ready(modelCount: entries.count)]
                )
            }
        )

        let gpt = try #require(candidates.first {
            $0.model.id == "fal-ai/gpt-image-2"
        })
        #expect(gpt.target.modelId == "fal-ai/gpt-image-2")
        #expect(gpt.target.endpoint == "openai/gpt-image-2")
        #expect(candidates.contains { $0.model.id == "fal-ai/nano-banana" })
    }

    @Test("Unverified MCP and unimplemented fal routes fail closed before approval")
    func unverifiedRoutesFailClosed() throws {
        let knownFal = try #require(FalModelRegistry.discoveredEntries(
            availableModelIds: ["fal-ai/nano-banana"]
        ).first { $0.id == "fal-ai/nano-banana" })
        let higgsfield = mcpEntry(
            id: "higgsfield/image-model",
            name: "Image Model",
            provider: .higgsfield,
            modelParam: "image-model"
        )
        let unknownFal = CatalogEntry(
            id: "fal-ai/not-implemented",
            kind: .image,
            displayName: "Unknown fal image model",
            allowedEndpoints: ["fal-ai/not-implemented"],
            responseShape: .images,
            uiCapabilities: .image(ImageCaps(
                resolutions: nil,
                aspectRatios: ["9:16"],
                qualities: nil,
                supportsImageReference: false,
                maxReferenceImages: 0,
                maxImages: 1
            )),
            offers: [ProviderOffer(
                provider: .fal,
                providerRef: "fal-ai/not-implemented"
            )]
        )
        let unverifiedEntries = [knownFal, higgsfield]
        let unverified = ModelCatalog.compatibleImageOfferings(
            models: try unverifiedEntries.map(imageModel),
            offersByModelID: offersByID(unverifiedEntries),
            preferredModelID: knownFal.id,
            aspectRatio: "9:16",
            resolution: nil,
            quality: nil,
            referenceCount: 0,
            activation: ProviderActivation(active: [
                .init(provider: .fal, transport: .api),
                .init(provider: .higgsfield, transport: .mcp),
            ]),
            isEnabled: { _ in true },
            offeringIsVerified: { _, _ in false }
        )
        let unimplemented = ModelCatalog.compatibleImageOfferings(
            models: [try imageModel(unknownFal)],
            offersByModelID: offersByID([unknownFal]),
            preferredModelID: unknownFal.id,
            aspectRatio: "9:16",
            resolution: nil,
            quality: nil,
            referenceCount: 0,
            activation: ProviderActivation(active: [
                .init(provider: .fal, transport: .api),
            ]),
            isEnabled: { _ in true },
            offeringIsVerified: { _, _ in true }
        )

        #expect(unverified.isEmpty)
        #expect(unimplemented.isEmpty)
    }

    @Test("An active Higgsfield account with no compatible offering remains in diagnostics")
    func configuredHiggsfieldWithoutMatchIsDiagnosed() {
        let scope = ModelCatalog.activeImageProviderScope(
            activation: ProviderActivation(active: [
                .init(provider: .fal, transport: .api),
                .init(provider: .higgsfield, transport: .mcp),
            ])
        )
        let fal = spendOption(
            modelID: "fal-ai/nano-banana",
            provider: .fal,
            transport: .api,
            endpoint: "fal-ai/nano-banana"
        )
        let messages = SpendApprovalProviderDiagnostics.messages(
            providerScope: scope,
            availableOptions: [fal],
            discovery: [
                .fal: .ready(modelCount: 1),
                .higgsfield: .ready(modelCount: 12),
            ]
        )

        #expect(scope == [.fal, .higgsfield])
        #expect(messages == ["Higgsfield: No model supports this request."])
    }

    @Test("Verified MCP offerings remain usable while stale and fail closed after authentication loss")
    func cachedMCPEntriesRespectProviderAvailability() throws {
        let higgsfield = mcpEntry(
            id: "higgsfield/nano-banana-2",
            name: "Nano Banana 2",
            provider: .higgsfield,
            modelParam: "nano-banana-2"
        )
        let offers = try #require(higgsfield.offers)
        let binding = try #require(ProviderManifest.bindings(
            from: offers,
            modelId: higgsfield.id
        ).first)
        let cached = [GenerationProvider.higgsfield: [higgsfield]]

        #expect(ModelCatalog.imageOfferingIsVerified(
            modelID: higgsfield.id,
            binding: binding,
            discoveredByProvider: cached,
            providerDiscovery: [.higgsfield: .ready(modelCount: 1)]
        ))
        #expect(ModelCatalog.productionOfferingIsLive(
            modelID: higgsfield.id,
            modality: .image,
            binding: binding,
            modelExists: true,
            modelEnabled: true,
            discoveredByProvider: cached,
            providerDiscovery: [.higgsfield: .ready(modelCount: 1)]
        ))
        let stale = ProviderDiscoveryState.stale(
            modelCount: 1,
            message: "Some model details could not be refreshed."
        )
        #expect(ModelCatalog.imageOfferingIsVerified(
            modelID: higgsfield.id,
            binding: binding,
            discoveredByProvider: cached,
            providerDiscovery: [.higgsfield: stale]
        ))
        #expect(ModelCatalog.productionOfferingIsLive(
            modelID: higgsfield.id,
            modality: .image,
            binding: binding,
            modelExists: true,
            modelEnabled: true,
            discoveredByProvider: cached,
            providerDiscovery: [.higgsfield: stale]
        ))
        #expect(!ModelCatalog.imageOfferingIsVerified(
            modelID: higgsfield.id,
            binding: binding,
            discoveredByProvider: [.higgsfield: []],
            providerDiscovery: [.higgsfield: stale]
        ))
        #expect(SpendApprovalProviderDiagnostics.messages(
            providerScope: [.higgsfield],
            availableOptions: [spendOption(
                modelID: higgsfield.id,
                provider: .higgsfield,
                transport: .mcp,
                endpoint: binding.providerRef
            )],
            discovery: [.higgsfield: stale]
        ) == ["Higgsfield: Some model details could not be refreshed."])

        let blockedStates: [ProviderDiscoveryState] = [
            .inactive,
            .checking,
            .actionRequired("Sign in again."),
            .unavailable("Provider unavailable."),
        ]
        for state in blockedStates {
            #expect(!ModelCatalog.imageOfferingIsVerified(
                modelID: higgsfield.id,
                binding: binding,
                discoveredByProvider: cached,
                providerDiscovery: [.higgsfield: state]
            ))
            #expect(!ModelCatalog.productionOfferingIsLive(
                modelID: higgsfield.id,
                modality: .image,
                binding: binding,
                modelExists: true,
                modelEnabled: true,
                discoveredByProvider: cached,
                providerDiscovery: [.higgsfield: state]
            ))
        }
        #expect(!ModelCatalog.imageOfferingIsVerified(
            modelID: higgsfield.id,
            binding: binding,
            discoveredByProvider: cached,
            providerDiscovery: [:]
        ))

        let actionRequired = [
            GenerationProvider.higgsfield: ProviderDiscoveryState.actionRequired(
                "Sign in again."
            ),
        ]
        let candidates = ModelCatalog.compatibleImageOfferings(
            models: [try imageModel(higgsfield)],
            offersByModelID: offersByID([higgsfield]),
            preferredModelID: higgsfield.id,
            aspectRatio: "9:16",
            resolution: nil,
            quality: nil,
            referenceCount: 0,
            activation: ProviderActivation(active: [
                .init(provider: .higgsfield, transport: .mcp),
            ]),
            isEnabled: { _ in true },
            offeringIsVerified: { modelID, candidateBinding in
                ModelCatalog.imageOfferingIsVerified(
                    modelID: modelID,
                    binding: candidateBinding,
                    discoveredByProvider: cached,
                    providerDiscovery: actionRequired
                )
            }
        )
        let scope = ModelCatalog.activeImageProviderScope(
            activation: ProviderActivation(active: [
                .init(provider: .higgsfield, transport: .mcp),
            ])
        )
        let messages = SpendApprovalProviderDiagnostics.messages(
            providerScope: scope,
            availableOptions: [],
            discovery: actionRequired
        )

        #expect(candidates.isEmpty)
        #expect(scope == [.higgsfield])
        #expect(messages == ["Higgsfield: Sign in again."])
    }

    private func mcpEntry(
        id: String,
        name: String,
        provider: GenerationProvider,
        modelParam: String
    ) -> CatalogEntry {
        CatalogEntry(
            id: id,
            kind: .image,
            displayName: name,
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
                provider: provider,
                transport: .mcp,
                providerRef: "generate_image",
                modelParam: modelParam,
                mcpMediaRoles: ["image_references"]
            )]
        )
    }

    private func imageModel(_ entry: CatalogEntry) throws -> ImageModelConfig {
        guard case .image(let caps) = entry.uiCapabilities else {
            throw FixtureError.expectedImageEntry
        }
        return ImageModelConfig(entry: entry, caps: caps)
    }

    private func offersByID(_ entries: [CatalogEntry]) -> [String: [ProviderOffer]] {
        Dictionary(uniqueKeysWithValues: entries.map { entry in
            (entry.id, entry.offers ?? ProviderManifest.defaultOffers(forModelId: entry.id))
        })
    }

    private func spendOption(
        modelID: String,
        provider: GenerationProvider,
        transport: ProviderTransport,
        endpoint: String
    ) -> SpendOption {
        let binding = ProviderBinding(
            provider: provider,
            transport: transport,
            kind: .generation,
            providerRef: endpoint,
            billing: transport == .mcp ? .subscription : .perCall
        )
        return SpendOption(
            modelId: modelID,
            modelName: modelID,
            target: ResolvedGenerationTarget(
                modelId: modelID,
                provider: provider,
                endpoint: endpoint,
                binding: binding
            ),
            credits: nil,
            requiresCatalogAvailability: false
        )
    }
}
