import Foundation
import NexGenEngine

enum ModelKind: Sendable {
    case video(VideoModelConfig)
    case image(ImageModelConfig)
    case audio(AudioModelConfig)
    case upscale(UpscaleModelConfig)
}

enum ProviderDiscoveryState: Equatable, Sendable {
    case inactive
    case checking
    case ready(modelCount: Int)
    case stale(modelCount: Int, message: String)
    case actionRequired(String)
    case unavailable(String)
}

/// The "education" a model carries for the LLM: what it is good/bad at, what it is best for, and
/// how it ranks right now. Curated knowledge — hosted remotely and refreshed WITHOUT an app release
/// (the model landscape moves weekly), so the agent recommends from this current truth, never from
/// stale training knowledge. All fields optional so a bare catalog entry still decodes.
struct ModelCard: Codable, Sendable, Hashable {
    let strengths: [String]?
    let weaknesses: [String]?
    let bestFor: String?
    /// Lower is better within a modality (1 = current top pick). Drives the agent's default recommendation.
    let rank: Int?
    let tags: [String]?
}

enum ModelRegistry {
    @MainActor static var byId: [String: ModelKind] { ModelCatalog.shared.byId }

    @MainActor static func exists(id: String) -> Bool { byId[id] != nil }


    @MainActor static func displayName(for id: String) -> String {
        switch byId[id] {
        case .video(let m): m.displayName
        case .image(let m): m.displayName
        case .audio(let m): m.displayName
        case .upscale(let m): m.displayName
        case .none: id
        }
    }
}

@Observable
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()
    static let launchEntries =
        FalModelRegistry.entries + MarbleModelRegistry.entries
    static let bootstrapEntries = launchEntries + RunwayModelRegistry.entries

    private(set) var video: [VideoModelConfig] = []
    private(set) var image: [ImageModelConfig] = []
    private(set) var audio: [AudioModelConfig] = []
    private(set) var upscale: [UpscaleModelConfig] = []
    private(set) var byId: [String: ModelKind] = [:]
    private(set) var cardsById: [String: ModelCard] = [:]
    private(set) var offersById: [String: [ProviderOffer]] = [:]
    /// Provider-neutral LOGICAL id → internal catalog id. The LLM sees/requests logical ids
    /// (`kling`, `gen4.5`); NGV maps back to the internal id for resolution + dispatch. Built at load.
    private(set) var internalByLogical: [String: String] = [:]
    private(set) var providerDiscovery: [GenerationProvider: ProviderDiscoveryState] = [:]
    private(set) var offeringCapabilitiesByModelID:
        [String: [ResolvedOfferingCapabilityProfileV1]] = [:]
    private(set) var isLoaded: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored private var didConfigure = false
    /// The curated base: launch-seed registries, then the hosted remote catalog. Replaced wholesale by
    /// `load(entries:)`.
    @ObservationIgnored private var baseEntries: [CatalogEntry] = []
    /// Runtime MCP-discovered models per provider (#163). Layered ON TOP of the base so a remote
    /// refresh never drops a signed-in provider's models, and a sign-out clears exactly that provider's.
    @ObservationIgnored private var discoveredByProvider: [GenerationProvider: [CatalogEntry]] = [:]
    @ObservationIgnored private var completedDiscoveryProviders = Set<GenerationProvider>()

    init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        // App startup loads the provider registry seed, then refreshes remote and discovered entries.
    }

    func load(entries: [CatalogEntry]) {
        baseEntries = entries
        rebuild()
        // `isLoaded` tracks the BASE catalog sync — not every rebuild. Applying runtime-discovered
        // MCP models (a rebuild) must NOT mark the catalog loaded, or `list_models` can't tell
        // "synced but empty" from "not synced yet".
        isLoaded = true
    }

    /// Replace the runtime-discovered models for one provider (empty clears them), then rebuild the
    /// union. Called when a provider signs in / out or its MCP discovery re-runs.
    func applyDiscovered(_ entries: [CatalogEntry], for provider: GenerationProvider) {
        completedDiscoveryProviders.insert(provider)
        discoveredByProvider[provider] = entries.isEmpty ? nil : entries
        rebuild()
    }

    func beginDirectDiscovery(for provider: GenerationProvider) {
        completedDiscoveryProviders.insert(provider)
        rebuild()
    }

    func discoveredModelCount(for provider: GenerationProvider) -> Int {
        discoveredByProvider[provider]?.count ?? 0
    }

    /// Replace the ENTIRE discovered set in one rebuild — the coordinator's per-refresh result. A
    /// provider absent from `byProvider` has its discovered models cleared (signed out), so this is
    /// self-correcting: what's not rediscovered disappears (usable-only).
    func setDiscovered(_ byProvider: [GenerationProvider: [CatalogEntry]]) {
        completedDiscoveryProviders = Set(byProvider.keys)
        discoveredByProvider = byProvider.filter { !$0.value.isEmpty }
        rebuild()
    }

    func setProviderDiscoveryState(
        _ state: ProviderDiscoveryState,
        for provider: GenerationProvider
    ) {
        providerDiscovery[provider] = state
        NotificationCenter.default.post(name: .modelCatalogChanged, object: nil)
    }

    private func rebuild() {
        apply(mergedEntries())
        NotificationCenter.default.post(name: .modelCatalogChanged, object: nil)
    }

    /// Base ∪ discovered, base first and its curated fields winning; a model offered by both merges the
    /// offers (so #159's "any activated provider that exposes it" resolves to the cheapest binding).
    private func mergedEntries() -> [CatalogEntry] {
        var order: [String] = []
        var byId: [String: CatalogEntry] = [:]
        func add(_ entries: [CatalogEntry]) {
            for entry in entries {
                if var existing = byId[entry.id] {
                    var offers = existing.offers ?? []
                    for offer in entry.offers ?? [] {
                        if let index = offers.firstIndex(where: {
                            Self.sameOffering($0, offer)
                        }) {
                            offers[index] = Self.mergingOfferingMetadata(
                                current: offers[index],
                                refreshed: offer
                            )
                        } else {
                            offers.append(offer)
                        }
                    }
                    existing.offers = offers
                    var capabilities = existing.resolvedOfferingCapabilities ?? []
                    for capability in entry.resolvedOfferingCapabilities ?? []
                    where !capabilities.contains(capability) {
                        capabilities.append(capability)
                    }
                    existing.resolvedOfferingCapabilities = capabilities.isEmpty
                        ? nil
                        : capabilities
                    byId[entry.id] = existing
                } else {
                    byId[entry.id] = entry
                    order.append(entry.id)
                }
            }
        }
        let base = Self.gatingCompletedDirectProviders(
            in: baseEntries,
            completedProviders: completedDiscoveryProviders
        )
        add(base)
        for provider in GenerationProvider.allCases {
            if let entries = discoveredByProvider[provider] { add(entries) }
        }
        return order.map { byId[$0]! }
    }

    private static func sameOffering(_ lhs: ProviderOffer, _ rhs: ProviderOffer) -> Bool {
        lhs.provider == rhs.provider
            && lhs.transport == rhs.transport
            && lhs.providerRef == rhs.providerRef
            && lhs.modelParam == rhs.modelParam
    }

    private static func mergingOfferingMetadata(
        current: ProviderOffer,
        refreshed: ProviderOffer
    ) -> ProviderOffer {
        var merged = current
        if refreshed.costPerCall != nil { merged.costPerCall = refreshed.costPerCall }
        if refreshed.mcpMediaRoles != nil { merged.mcpMediaRoles = refreshed.mcpMediaRoles }
        if refreshed.productionQualityTargetIDs != nil {
            merged.productionQualityTargetIDs = refreshed.productionQualityTargetIDs
        }
        if refreshed.productionInputPolicy != nil {
            merged.productionInputPolicy = refreshed.productionInputPolicy
        }
        if refreshed.resolvedVideoCapabilities != nil {
            merged.resolvedVideoCapabilities = refreshed.resolvedVideoCapabilities
        }
        return merged
    }

    static func gatingCompletedDirectProviders(
        in entries: [CatalogEntry],
        completedProviders: Set<GenerationProvider>
    ) -> [CatalogEntry] {
        let gated = completedProviders.intersection(DirectImageDiscovery.providers)
        guard !gated.isEmpty else { return entries }
        let everyModality = gated.intersection([.runway])
        return entries.compactMap { entry in
            let providers: Set<GenerationProvider>
            if case .image = entry.uiCapabilities {
                providers = gated
            } else {
                providers = everyModality
            }
            guard !providers.isEmpty else { return entry }
            var filtered = entry
            let offers = entry.offers ?? ProviderManifest.defaultOffers(forModelId: entry.id)
            filtered.offers = offers.filter { !providers.contains($0.provider) }
            return filtered.offers?.isEmpty == false ? filtered : nil
        }
    }

    /// The provider-neutral LOGICAL id the LLM sees — a known provider prefix stripped off.
    /// (Internal ids stay as-is for registry lookup + dispatch; this is only the consumer surface.)
    nonisolated static func deriveLogicalId(_ internalId: String) -> String {
        for prefix in ["fal-ai/", "runway/", "higgsfield/", "marble/", "google/"]
        where internalId.hasPrefix(prefix) {
            return String(internalId.dropFirst(prefix.count))
        }
        return internalId
    }

    /// Map an LLM-supplied logical id back to the internal catalog id. Falls back to the input, so a
    /// caller that already passes an internal id still resolves.
    func internalId(forLogical logical: String) -> String { internalByLogical[logical] ?? logical }

    func modelKindForRerun(id: String) -> ModelKind? {
        if let current = byId[id] { return current }
        guard !isLoaded, let entry = Self.bootstrapEntries.first(where: { $0.id == id }) else {
            return nil
        }
        switch entry.uiCapabilities {
        case .video(let caps): return .video(VideoModelConfig(entry: entry, caps: caps))
        case .image(let caps): return .image(ImageModelConfig(entry: entry, caps: caps))
        case .audio(let caps): return .audio(AudioModelConfig(entry: entry, caps: caps))
        case .upscale(let caps): return .upscale(UpscaleModelConfig(entry: entry, caps: caps))
        }
    }

    private func apply(_ entries: [CatalogEntry]) {
        guard let capabilityResolver = CatalogCapabilityRuntime.resolver else {
            clearAppliedCatalog(
                error: CatalogCapabilityRuntime.loadError?.localizedDescription
                    ?? "Model capability knowledge is unavailable."
            )
            return
        }
        var newVideo: [VideoModelConfig] = []
        var newImage: [ImageModelConfig] = []
        var newAudio: [AudioModelConfig] = []
        var newUpscale: [UpscaleModelConfig] = []
        var newById: [String: ModelKind] = [:]
        var newCardsById: [String: ModelCard] = [:]
        var newOffersById: [String: [ProviderOffer]] = [:]
        var newInternalByLogical: [String: String] = [:]
        var newOfferingCapabilitiesByModelID:
            [String: [ResolvedOfferingCapabilityProfileV1]] = [:]
        var capabilityErrors: [String] = []
        newVideo.reserveCapacity(entries.count)
        newImage.reserveCapacity(entries.count)
        newAudio.reserveCapacity(entries.count)
        newUpscale.reserveCapacity(entries.count)
        newById.reserveCapacity(entries.count)

        for entry in entries {
            do {
                let capabilities = try Self.offeringCapabilities(
                    for: entry,
                    resolver: capabilityResolver
                )
                if !capabilities.isEmpty {
                    newOfferingCapabilitiesByModelID[entry.id] = capabilities
                }
            } catch {
                capabilityErrors.append("\(entry.id): \(error.localizedDescription)")
                continue
            }
            if let card = entry.card { newCardsById[entry.id] = card }
            if let offers = entry.offers { newOffersById[entry.id] = offers }
            newInternalByLogical[Self.deriveLogicalId(entry.id)] = entry.id
            switch entry.uiCapabilities {
            case .video(let caps):
                let m = VideoModelConfig(entry: entry, caps: caps)
                newVideo.append(m)
                newById[m.id] = .video(m)
            case .image(let caps):
                let m = ImageModelConfig(entry: entry, caps: caps)
                newImage.append(m)
                newById[m.id] = .image(m)
            case .audio(let caps):
                let m = AudioModelConfig(entry: entry, caps: caps)
                newAudio.append(m)
                newById[m.id] = .audio(m)
            case .upscale(let caps):
                let m = UpscaleModelConfig(entry: entry, caps: caps)
                newUpscale.append(m)
                newById[m.id] = .upscale(m)
            }
        }

        self.video = newVideo
        self.image = newImage
        self.audio = newAudio
        self.upscale = newUpscale
        self.byId = newById
        self.cardsById = newCardsById
        self.offersById = newOffersById
        self.internalByLogical = newInternalByLogical
        self.offeringCapabilitiesByModelID = newOfferingCapabilitiesByModelID
        self.lastError = capabilityErrors.first
    }

    nonisolated static func offeringCapabilities(
        for entry: CatalogEntry,
        resolver: ModelCapabilityResolver
    ) throws -> [ResolvedOfferingCapabilityProfileV1] {
        let modality: CapabilityModalityV1
        switch entry.kind {
        case .video: modality = .video
        case .image: modality = .image
        case .audio: modality = .audio
        case .upscale: return []
        }
        let offers = entry.offers ?? ProviderManifest.defaultOffers(forModelId: entry.id)
        let supplied = entry.resolvedOfferingCapabilities ?? []
        let discovered = Dictionary(
            supplied.map { ($0.offering.offeringID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard discovered.count == supplied.count else {
            throw ModelCapabilityKnowledgeError.invalidOffering(
                "duplicate_catalog_offering"
            )
        }
        let declaredOfferingIDs = Set(offers.map {
            CatalogOfferingIdentity.id(offer: $0, modelID: entry.id)
        })
        guard Set(discovered.keys).isSubset(of: declaredOfferingIDs) else {
            throw ModelCapabilityKnowledgeError.invalidOffering(
                "undeclared_catalog_offering"
            )
        }
        return try offers.map { offer in
            let offering = CatalogOfferingIdentity.make(
                offer: offer,
                modelID: entry.id,
                modality: modality
            )
            try validateVideoOfferingContract(offer, modality: modality)
            if let capability = discovered[offering.offeringID] {
                guard capability.offering == offering else {
                    throw ModelCapabilityKnowledgeError.invalidOffering(
                        "catalog_offering_identity"
                    )
                }
                try validateProductionInputPolicy(
                    offer,
                    in: capability
                )
                return productionRoutingCapability(capability)
            }
            return productionRoutingCapability(try resolver.resolveOffering(
                offering,
                lookup: CapabilityLookupV1(
                    modality: modality,
                    catalogModelID: entry.id
                ),
                overlay: try productionInputPolicyOverlay(
                    offer.productionInputPolicy,
                    offering: offering
                )
            ))
        }
    }

    private nonisolated static func productionRoutingCapability(
        _ capability: ResolvedOfferingCapabilityProfileV1
    ) -> ResolvedOfferingCapabilityProfileV1 {
        guard capability.offering.modality == .video,
              capability.effective.fields.strings[CapabilityFieldIDV1.modes]?.value
                .isEmpty != false,
              let identity = capability.effective.resolvedIdentity
                ?? capability.effective.requestedIdentity else {
            return capability
        }
        var modes: Set<String> = []
        let variant = ProductionIdentifierNormalizerV1.canonical(
            identity.variantID.rawValue
        )
        if variant.hasPrefix("text-to-video") {
            modes.insert("text-to-video")
        } else if variant.hasPrefix("image-to-video") {
            modes.insert("image-to-video")
        } else if variant.hasPrefix("reference-to-video") {
            modes.insert("reference-to-video")
        } else if variant.hasPrefix("video-to-video") {
            modes.insert("video-to-video")
        } else {
            return capability
        }
        if capability.effective.fields.booleans[
            CapabilityFieldIDV1.sourceVideo
        ]?.value == true {
            modes.insert("video-to-video")
        }
        let evidence = CapabilityEvidenceV1(
            sourceTitle: "NexGenVideo provider endpoint mode contract v1",
            observedAt: "2026-09-01T00:00:00Z",
            kind: .providerSchema,
            confidence: 1
        )
        var fields = capability.effective.fields
        fields.strings[CapabilityFieldIDV1.modes] = ResolvedCapabilityValueV1(
            value: modes.sorted(),
            semantics: .supportedSet,
            origin: ResolvedCapabilityOriginV1(
                kind: .endpointOverlay,
                profileID: "provider-endpoint-mode-contract/v1",
                versionID: identity.versionID,
                endpointID: capability.offering.endpointID
            ),
            evidence: [evidence]
        )
        return ResolvedOfferingCapabilityProfileV1(
            offering: capability.offering,
            intrinsic: capability.intrinsic,
            effective: ResolvedCapabilityProfileV1(
                requestedIdentity: capability.effective.requestedIdentity,
                resolvedIdentity: capability.effective.resolvedIdentity,
                defensiveProfileID: capability.effective.defensiveProfileID,
                researchNeeded: capability.effective.researchNeeded,
                fields: fields
            )
        )
    }

    private nonisolated static func productionInputPolicyOverlay(
        _ policy: ProviderProductionInputPolicyV1?,
        offering: CapabilityOfferingIdentityV1
    ) throws -> EndpointCapabilityOverlayV1? {
        guard offering.modality == .video else { return nil }
        guard let policy else {
            throw ModelCapabilityKnowledgeError.invalidOffering(
                "missing_production_input_policy"
            )
        }
        let evidence = CapabilityEvidenceV1(
            sourceTitle: "NexGenVideo provider input adapter contract v1",
            observedAt: "2026-08-31T00:00:00Z",
            kind: .providerSchema,
            confidence: 1
        )
        func restriction(_ value: Bool) -> EndpointBooleanRestrictionV1 {
            EndpointBooleanRestrictionV1(value: value, evidence: [evidence])
        }
        return EndpointCapabilityOverlayV1(
            offering: offering,
            schemaEvidence: [evidence],
            restrictions: EndpointCapabilityRestrictionsV1(booleans: [
                CapabilityFieldIDV1.sourceVideoRequired:
                    restriction(policy.requiresSourceVideo),
                CapabilityFieldIDV1.framesCountTowardImageReferenceLimit:
                    restriction(policy.framesCountTowardImageReferenceLimit),
                CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit:
                    restriction(policy.framesCountTowardTotalReferenceLimit),
            ])
        )
    }

    private nonisolated static func validateProductionInputPolicy(
        _ offer: ProviderOffer,
        in capability: ResolvedOfferingCapabilityProfileV1
    ) throws {
        guard capability.offering.modality == .video else { return }
        guard let policy = offer.productionInputPolicy,
              exactEndpointBoolean(
                CapabilityFieldIDV1.sourceVideoRequired,
                in: capability
              ) == policy.requiresSourceVideo,
              exactEndpointBoolean(
                CapabilityFieldIDV1.framesCountTowardImageReferenceLimit,
                in: capability
              ) == policy.framesCountTowardImageReferenceLimit,
              exactEndpointBoolean(
                CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit,
                in: capability
              ) == policy.framesCountTowardTotalReferenceLimit else {
            throw ModelCapabilityKnowledgeError.invalidOffering(
                "production_input_policy_mismatch"
            )
        }
    }

    private nonisolated static func validateVideoOfferingContract(
        _ offer: ProviderOffer,
        modality: CapabilityModalityV1
    ) throws {
        guard modality == .video else { return }
        guard let policy = offer.productionInputPolicy else {
            throw ModelCapabilityKnowledgeError.invalidOffering(
                "missing_production_input_policy"
            )
        }
        guard let capabilities = offer.resolvedVideoCapabilities,
              capabilities.schemaVersion == 1,
              capabilities.inputPolicy == policy else {
            throw ModelCapabilityKnowledgeError.invalidOffering(
                "missing_resolved_video_offering_capabilities_v1"
            )
        }
        guard capabilities.contractViolation == nil else {
            throw ModelCapabilityKnowledgeError.invalidOffering(
                "invalid_resolved_video_offering_capabilities_v1"
            )
        }
    }

    private func clearAppliedCatalog(error: String) {
        video = []
        image = []
        audio = []
        upscale = []
        byId = [:]
        cardsById = [:]
        offersById = [:]
        internalByLogical = [:]
        offeringCapabilitiesByModelID = [:]
        lastError = error
    }

    func compatibleImageOfferings(
        preferredModelID: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        referenceCount: Int,
        numImages: Int = 1
    ) -> [CatalogImageOfferingCandidate] {
        let discovered = discoveredByProvider
        let discoveryStates = providerDiscovery
        return Self.compatibleImageOfferings(
            models: image,
            offersByModelID: offersById,
            preferredModelID: preferredModelID,
            aspectRatio: aspectRatio,
            resolution: resolution,
            quality: quality,
            referenceCount: referenceCount,
            numImages: numImages,
            activation: .current(),
            isEnabled: ModelPreferences.shared.isEnabled,
            offeringIsVerified: { modelID, binding in
                Self.imageOfferingIsVerified(
                    modelID: modelID,
                    binding: binding,
                    discoveredByProvider: discovered,
                    providerDiscovery: discoveryStates
                )
            }
        )
    }

    nonisolated static func imageOfferingIsVerified(
        modelID: String,
        binding: ProviderBinding,
        discoveredByProvider: [GenerationProvider: [CatalogEntry]],
        providerDiscovery: [GenerationProvider: ProviderDiscoveryState]
    ) -> Bool {
        if binding.transport == .mcp {
            switch providerDiscovery[binding.provider] {
            case .ready?, .stale?:
                break
            default:
                return false
            }
        }
        guard let entries = discoveredByProvider[binding.provider] else {
            return false
        }
        let expected = CatalogImageBindingIdentity(
            modelID: modelID,
            binding: binding
        )
        return entries.contains { entry in
            guard entry.id == modelID else { return false }
            let offers = entry.offers
                ?? ProviderManifest.defaultOffers(forModelId: modelID)
            return ProviderManifest.bindings(
                from: offers,
                modelId: modelID
            ).contains {
                $0.provider == binding.provider
                    && CatalogImageBindingIdentity(
                        modelID: modelID,
                        binding: $0
                    ) == expected
            }
        }
    }

    nonisolated static func compatibleImageOfferings(
        models: [ImageModelConfig],
        offersByModelID: [String: [ProviderOffer]],
        preferredModelID: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        referenceCount: Int,
        numImages: Int = 1,
        activation: ProviderActivation,
        isEnabled: (String) -> Bool,
        offeringIsVerified: (String, ProviderBinding) -> Bool
    ) -> [CatalogImageOfferingCandidate] {
        models
            .filter { isEnabled($0.id) && !MarbleModelRegistry.isMarbleModel($0.id) }
            .compactMap { model -> (ImageAlternativeCandidate, [ProviderBinding])? in
                let adapted: ImageAlternativeCandidate
                if model.id == preferredModelID {
                    guard model.validate(
                        aspectRatio: aspectRatio,
                        resolution: resolution,
                        quality: quality,
                        imageRefCount: referenceCount,
                        numImages: numImages
                    ) == nil else { return nil }
                    adapted = ImageAlternativeCandidate(
                        model: model,
                        aspectRatio: aspectRatio,
                        resolution: resolution,
                        quality: quality
                    )
                } else {
                    guard let candidate = ImageAlternativeResolver.candidates(
                        models: [model],
                        excluding: preferredModelID,
                        aspectRatio: aspectRatio,
                        resolution: resolution,
                        quality: quality,
                        referenceCount: referenceCount,
                        isAvailable: { _ in true }
                    ).first,
                    candidate.model.validate(
                        aspectRatio: candidate.aspectRatio,
                        resolution: candidate.resolution,
                        quality: candidate.quality,
                        imageRefCount: referenceCount,
                        numImages: numImages
                    ) == nil else { return nil }
                    adapted = candidate
                }
                let offers = offersByModelID[model.id]
                    ?? ProviderManifest.defaultOffers(forModelId: model.id)
                let bindings = ProviderResolver.preferredActiveBindingPerProvider(
                    bindings: ProviderManifest.bindings(from: offers, modelId: model.id),
                    activation: activation,
                    effectiveCost: ProviderManifest.effectiveCost,
                    isCompatible: {
                        imageRouteIsImplemented(modelID: model.id, binding: $0)
                            && (!imageRouteRequiresLiveDiscovery($0)
                                || offeringIsVerified(model.id, $0))
                    }
                )
                return bindings.isEmpty ? nil : (adapted, bindings)
            }
            .flatMap { adapted, bindings in
                bindings.map { binding in
                    CatalogImageOfferingCandidate(
                        model: adapted.model,
                        target: ResolvedGenerationTarget(
                            modelId: adapted.model.id,
                            provider: binding.provider,
                            endpoint: binding.providerRef,
                            binding: binding
                        ),
                        aspectRatio: adapted.aspectRatio,
                        resolution: adapted.resolution,
                        quality: adapted.quality
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.model.id == preferredModelID,
                   rhs.model.id != preferredModelID { return true }
                if rhs.model.id == preferredModelID,
                   lhs.model.id != preferredModelID { return false }
                let providerOrder = GenerationProvider.allCases
                let lhsProvider = providerOrder.firstIndex(of: lhs.target.provider) ?? .max
                let rhsProvider = providerOrder.firstIndex(of: rhs.target.provider) ?? .max
                if lhsProvider != rhsProvider { return lhsProvider < rhsProvider }
                let modelOrder = lhs.model.displayName.localizedCaseInsensitiveCompare(
                    rhs.model.displayName
                )
                if modelOrder != .orderedSame { return modelOrder == .orderedAscending }
                return lhs.target.endpoint < rhs.target.endpoint
            }
    }

    func activeImageProviderScope() -> [GenerationProvider] {
        Self.activeImageProviderScope(activation: .current())
    }

    nonisolated static func activeImageProviderScope(
        activation: ProviderActivation
    ) -> [GenerationProvider] {
        GenerationProvider.allCases.filter { provider in
            provider.supportsGenericImageGeneration
                && ProviderTransport.allCases.contains {
                    activation.isActive(provider, $0)
                }
        }
    }

    private nonisolated static func imageRouteIsImplemented(
        modelID: String,
        binding: ProviderBinding
    ) -> Bool {
        guard binding.kind == .generation else { return false }
        if binding.transport == .mcp {
            return !binding.providerRef.isEmpty
        }
        switch binding.provider {
        case .fal:
            return FalModelRegistry.model(for: modelID) != nil
        case .runway:
            return RunwayModelRegistry.model(for: binding.providerRef) != nil
        case .google:
            return GoogleModelRegistry.model(for: binding.providerRef) != nil
        case .marble:
            return MarbleModelRegistry.model(for: binding.providerRef) != nil
        case .higgsfield, .openart, .ace, .elevenlabs:
            return false
        }
    }

    private nonisolated static func imageRouteRequiresLiveDiscovery(
        _ binding: ProviderBinding
    ) -> Bool {
        binding.transport == .mcp
            || binding.provider.requiresLiveImageCatalogDiscovery
    }

    func productionRouteCandidates(
        activation: ProviderActivation = .current()
    ) -> [CatalogProductionRouteCandidate] {
        let discovered = discoveredByProvider
        let discoveryStates = providerDiscovery
        return offeringCapabilitiesByModelID.keys.sorted().flatMap { modelID in
            let offers = offersById[modelID] ?? ProviderManifest.defaultOffers(
                forModelId: modelID
            )
            let capabilities = offeringCapabilitiesByModelID[modelID] ?? []
            return capabilities.map { capability in
                let offer = offers.first {
                    $0.provider.rawValue == capability.offering.providerID
                        && Self.offeringID(
                            offer: $0,
                            modelID: modelID
                        ) == capability.offering.offeringID
                }
                let provider = GenerationProvider(
                    rawValue: capability.offering.providerID
                )
                let providerActivated = provider.flatMap { provider in
                    offer.map { activation.isActive(provider, $0.transport) }
                } ?? false
                let binding = offer.flatMap {
                    ProviderManifest.bindings(from: [$0], modelId: modelID).first
                }
                let target = binding.map {
                    ResolvedGenerationTarget(
                        modelId: modelID,
                        provider: $0.provider,
                        endpoint: $0.providerRef,
                        binding: $0
                    )
                }
                let qualityTargetIDs = productionQualityTargets(for: offer)
                let inputSlots: [ProductionInputSlotCapabilityV1]
                if capability.offering.modality == .video,
                   let exact = binding?.resolvedVideoCapabilities {
                    inputSlots = Self.inputSlots(
                        capabilities: exact,
                        modeIDs: capability.effective.fields.strings[
                            CapabilityFieldIDV1.modes
                        ]?.value ?? []
                    )
                } else {
                    inputSlots = Self.inputSlots(capabilities: capability)
                }
                // Profile requirements remain unsupported without a versioned adapter contract.
                let candidate = ProductionRouteCandidateV1(
                    capabilities: capability,
                    providerActivated: providerActivated,
                    liveAvailable: Self.productionOfferingIsLive(
                        modelID: modelID,
                        modality: capability.offering.modality,
                        binding: binding,
                        modelExists: byId[modelID] != nil,
                        modelEnabled: ModelPreferences.shared.isEnabled(modelID),
                        discoveredByProvider: discovered,
                        providerDiscovery: discoveryStates
                    ),
                    qualityScore: cardsById[modelID]?.rank.map { -Double($0) } ?? 0,
                    qualityTargetIDs: qualityTargetIDs,
                    satisfiedProductionProfileRequirementIDs: [],
                    inputSlots: inputSlots,
                    estimatedCost: binding.map { ProviderManifest.effectiveCost($0) }
                )
                return CatalogProductionRouteCandidate(
                    modelID: modelID,
                    candidate: candidate,
                    target: target
                )
            }
        }
    }

    nonisolated static func productionOfferingIsLive(
        modelID: String,
        modality: CapabilityModalityV1,
        binding: ProviderBinding?,
        modelExists: Bool,
        modelEnabled: Bool,
        discoveredByProvider: [GenerationProvider: [CatalogEntry]],
        providerDiscovery: [GenerationProvider: ProviderDiscoveryState]
    ) -> Bool {
        guard let binding, modelExists, modelEnabled else { return false }
        if modality == .image,
           !imageRouteIsImplemented(modelID: modelID, binding: binding) {
            return false
        }
        let requiresDiscovery = binding.transport == .mcp
            || (modality == .image
                && binding.provider.requiresLiveImageCatalogDiscovery)
        return !requiresDiscovery || imageOfferingIsVerified(
            modelID: modelID,
            binding: binding,
            discoveredByProvider: discoveredByProvider,
            providerDiscovery: providerDiscovery
        )
    }

    private static func offeringID(offer: ProviderOffer, modelID: String) -> String {
        CatalogOfferingIdentity.id(offer: offer, modelID: modelID)
    }

    private func productionQualityTargets(for offer: ProviderOffer?) -> [String] {
        validatedSupportIDs(offer?.productionQualityTargetIDs)
    }

    private func validatedSupportIDs(_ values: [String]?) -> [String] {
        guard let values,
              values.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              Set(values).count == values.count else {
            return []
        }
        return values
    }

    nonisolated static func inputSlots(
        capabilities: ResolvedOfferingCapabilityProfileV1
    ) -> [ProductionInputSlotCapabilityV1] {
        let profile = capabilities.effective
        let modes = profile.fields.strings[CapabilityFieldIDV1.modes]?.value ?? []
        guard !modes.isEmpty else { return [] }
        let integers = profile.fields.integers
        let booleans = profile.fields.booleans
        var slots: [ProductionInputSlotCapabilityV1] = []
        func append(
            _ id: String,
            _ modality: AssetPhysicalModalityV1,
            requestOrder: Int,
            modalityBudget: Bool,
            totalBudget: Bool,
            durationBudget: Bool
        ) {
            slots.append(ProductionInputSlotCapabilityV1(
                id: id,
                modality: modality,
                modeIDs: modes,
                requestOrder: requestOrder,
                countsTowardModalityBudget: modalityBudget,
                countsTowardTotalBudget: totalBudget,
                countsTowardCombinedDuration: durationBudget
            ))
        }
        switch capabilities.offering.modality {
        case .video:
            guard let frameModalityBudget = exactEndpointBoolean(
                    CapabilityFieldIDV1.framesCountTowardImageReferenceLimit,
                    in: capabilities
                  ),
                  let frameTotalBudget = exactEndpointBoolean(
                    CapabilityFieldIDV1.framesCountTowardTotalReferenceLimit,
                    in: capabilities
                  ),
                  let requiresSourceVideo = exactEndpointBoolean(
                    CapabilityFieldIDV1.sourceVideoRequired,
                    in: capabilities
                  ) else {
                return []
            }
            if !requiresSourceVideo,
               booleans[CapabilityFieldIDV1.firstFrame]?.value == true {
                append(
                    CoreReferenceInputSlotIDV1.firstFrame,
                    .image,
                    requestOrder: 0,
                    modalityBudget: frameModalityBudget,
                    totalBudget: frameTotalBudget,
                    durationBudget: false
                )
            }
            if !requiresSourceVideo,
               booleans[CapabilityFieldIDV1.lastFrame]?.value == true {
                append(
                    CoreReferenceInputSlotIDV1.lastFrame,
                    .image,
                    requestOrder: 1,
                    modalityBudget: frameModalityBudget,
                    totalBudget: frameTotalBudget,
                    durationBudget: false
                )
            }
            if requiresSourceVideo {
                append(
                    CoreReferenceInputSlotIDV1.sourceVideo,
                    .video,
                    requestOrder: 0,
                    modalityBudget: false,
                    totalBudget: false,
                    durationBudget: false
                )
            }
            if integers[CapabilityFieldIDV1.referenceImages]?.value ?? 0 > 0 {
                append(
                    CoreReferenceInputSlotIDV1.referenceImage,
                    .image,
                    requestOrder: 2,
                    modalityBudget: true,
                    totalBudget: true,
                    durationBudget: false
                )
            }
            if !requiresSourceVideo,
               integers[CapabilityFieldIDV1.referenceVideos]?.value ?? 0 > 0 {
                append(
                    CoreReferenceInputSlotIDV1.referenceVideo,
                    .video,
                    requestOrder: 3,
                    modalityBudget: true,
                    totalBudget: true,
                    durationBudget: true
                )
            }
            if !requiresSourceVideo,
               integers[CapabilityFieldIDV1.referenceAudios]?.value ?? 0 > 0 {
                append(
                    CoreReferenceInputSlotIDV1.referenceAudio,
                    .audio,
                    requestOrder: 4,
                    modalityBudget: true,
                    totalBudget: true,
                    durationBudget: true
                )
                append(
                    CoreReferenceInputSlotIDV1.audioTiming,
                    .audio,
                    requestOrder: 4,
                    modalityBudget: true,
                    totalBudget: true,
                    durationBudget: true
                )
            }
        case .image:
            if integers[CapabilityFieldIDV1.imageReferences]?.value ?? 0 > 0 {
                append(
                    CoreReferenceInputSlotIDV1.referenceImage,
                    .image,
                    requestOrder: 0,
                    modalityBudget: true,
                    totalBudget: true,
                    durationBudget: false
                )
            }
        case .audio, .music:
            if booleans[CapabilityFieldIDV1.audioReference]?.value == true {
                append(
                    CoreReferenceInputSlotIDV1.referenceAudio,
                    .audio,
                    requestOrder: 0,
                    modalityBudget: true,
                    totalBudget: true,
                    durationBudget: true
                )
            }
        }
        return slots
    }

    nonisolated static func inputSlots(
        capabilities: ResolvedVideoOfferingCapabilitiesV1,
        modeIDs: [String]
    ) -> [ProductionInputSlotCapabilityV1] {
        let modes = Array(Set(modeIDs.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })).sorted()
        guard !modes.isEmpty else { return [] }
        let policy = capabilities.inputPolicy
        var slots: [ProductionInputSlotCapabilityV1] = []
        func append(
            _ id: String,
            _ modality: AssetPhysicalModalityV1,
            requestOrder: Int,
            modalityBudget: Bool,
            totalBudget: Bool,
            durationBudget: Bool
        ) {
            slots.append(ProductionInputSlotCapabilityV1(
                id: id,
                modality: modality,
                modeIDs: modes,
                requestOrder: requestOrder,
                countsTowardModalityBudget: modalityBudget,
                countsTowardTotalBudget: totalBudget,
                countsTowardCombinedDuration: durationBudget
            ))
        }
        if policy.requiresSourceVideo {
            append(
                CoreReferenceInputSlotIDV1.sourceVideo,
                .video,
                requestOrder: 0,
                modalityBudget: false,
                totalBudget: false,
                durationBudget: false
            )
        } else {
            if capabilities.supportsFirstFrame {
                append(
                    CoreReferenceInputSlotIDV1.firstFrame,
                    .image,
                    requestOrder: 0,
                    modalityBudget: policy.framesCountTowardImageReferenceLimit,
                    totalBudget: policy.framesCountTowardTotalReferenceLimit,
                    durationBudget: false
                )
            }
            if capabilities.supportsLastFrame {
                append(
                    CoreReferenceInputSlotIDV1.lastFrame,
                    .image,
                    requestOrder: 1,
                    modalityBudget: policy.framesCountTowardImageReferenceLimit,
                    totalBudget: policy.framesCountTowardTotalReferenceLimit,
                    durationBudget: false
                )
            }
        }
        if capabilities.maxReferenceImages > 0 {
            append(
                CoreReferenceInputSlotIDV1.referenceImage,
                .image,
                requestOrder: 2,
                modalityBudget: true,
                totalBudget: true,
                durationBudget: false
            )
        }
        if !policy.requiresSourceVideo,
           capabilities.maxReferenceVideos > 0 {
            append(
                CoreReferenceInputSlotIDV1.referenceVideo,
                .video,
                requestOrder: 3,
                modalityBudget: true,
                totalBudget: true,
                durationBudget: true
            )
        }
        if !policy.requiresSourceVideo,
           capabilities.maxReferenceAudios > 0 {
            append(
                CoreReferenceInputSlotIDV1.referenceAudio,
                .audio,
                requestOrder: 4,
                modalityBudget: true,
                totalBudget: true,
                durationBudget: true
            )
            append(
                CoreReferenceInputSlotIDV1.audioTiming,
                .audio,
                requestOrder: 4,
                modalityBudget: true,
                totalBudget: true,
                durationBudget: true
            )
        }
        return slots
    }

    private nonisolated static func exactEndpointBoolean(
        _ fieldID: String,
        in capabilities: ResolvedOfferingCapabilityProfileV1
    ) -> Bool? {
        guard let field = capabilities.effective.fields.booleans[fieldID],
              field.origin.kind == .endpointOverlay,
              field.origin.endpointID == capabilities.offering.endpointID else {
            return nil
        }
        return field.value
    }
}

struct CatalogProductionRouteCandidate {
    let modelID: String
    let candidate: ProductionRouteCandidateV1
    let target: ResolvedGenerationTarget?
}

struct CatalogImageOfferingCandidate: Sendable {
    let model: ImageModelConfig
    let target: ResolvedGenerationTarget
    let aspectRatio: String
    let resolution: String?
    let quality: String?
}

private struct CatalogImageBindingIdentity: Hashable {
    let modelID: String
    let provider: GenerationProvider
    let transport: ProviderTransport
    let kind: ProviderCapabilityKind
    let endpoint: String
    let modelParam: String?
    let mediaRoles: [String]?

    init(modelID: String, binding: ProviderBinding) {
        self.modelID = modelID
        provider = binding.provider
        transport = binding.transport
        kind = binding.kind
        endpoint = binding.providerRef
        modelParam = binding.modelParam
        mediaRoles = binding.mcpMediaRoles
    }
}

struct CatalogEntry: Decodable, Sendable {
    let id: String
    let kind: Kind
    let displayName: String
    let allowedEndpoints: [String]
    let responseShape: ResponseShape
    let uiCapabilities: UICapabilities
    let creditsPerSecond: [String: Double]?
    let audioDiscountRate: [String: Double]?
    let creditsPerImage: [String: Double]?
    let qualities: [String]?
    let audioPricing: AudioPricing?
    let creditsPerSecondUpscale: Double?
    let card: ModelCard?
    /// Which providers serve this model, over which transport, at what per-call cost — the DATA the
    /// resolver routes on (replaces id-prefix inference). Registries declare their own; the hosted
    /// catalog may declare several (one logical model, multiple providers). `var` so a registry can
    /// stamp it onto the entry it builds.
    var offers: [ProviderOffer]?
    var resolvedOfferingCapabilities: [ResolvedOfferingCapabilityProfileV1]?

    enum Kind: String, Decodable, Sendable { case video, image, audio, upscale }
    enum ResponseShape: String, Decodable, Sendable {
        case video, images, audio, upscaledImage
    }

    enum UICapabilities: Sendable {
        case video(VideoCaps)
        case image(ImageCaps)
        case audio(AudioCaps)
        case upscale(UpscaleCaps)
    }

    enum AudioPricing: Decodable, Sendable {
        case perThousandChars(rate: Double)
        case perSecond(rate: Double)
        case flat(price: Double)

        private enum K: String, CodingKey { case mode, rate, price }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            switch try c.decode(String.self, forKey: .mode) {
            case "perThousandChars":
                self = .perThousandChars(rate: try c.decode(Double.self, forKey: .rate))
            case "perSecond":
                self = .perSecond(rate: try c.decode(Double.self, forKey: .rate))
            case "flat":
                self = .flat(price: try c.decode(Double.self, forKey: .price))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .mode, in: c,
                    debugDescription: "Unknown audio pricing mode"
                )
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, allowedEndpoints, responseShape, uiCapabilities
        case creditsPerSecond, audioDiscountRate, creditsPerImage, qualities
        case audioPricing, creditsPerSecondUpscale, card, offers
    }

    init(
        id: String,
        kind: Kind,
        displayName: String,
        allowedEndpoints: [String],
        responseShape: ResponseShape,
        uiCapabilities: UICapabilities,
        creditsPerSecond: [String: Double]? = nil,
        audioDiscountRate: [String: Double]? = nil,
        creditsPerImage: [String: Double]? = nil,
        qualities: [String]? = nil,
        audioPricing: AudioPricing? = nil,
        creditsPerSecondUpscale: Double? = nil,
        card: ModelCard? = nil,
        offers: [ProviderOffer]? = nil,
        resolvedOfferingCapabilities: [ResolvedOfferingCapabilityProfileV1]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.allowedEndpoints = allowedEndpoints
        self.responseShape = responseShape
        self.uiCapabilities = uiCapabilities
        self.creditsPerSecond = creditsPerSecond
        self.audioDiscountRate = audioDiscountRate
        self.creditsPerImage = creditsPerImage
        self.qualities = qualities
        self.audioPricing = audioPricing
        self.creditsPerSecondUpscale = creditsPerSecondUpscale
        self.card = card
        self.offers = offers
        self.resolvedOfferingCapabilities = resolvedOfferingCapabilities
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.allowedEndpoints = try c.decode([String].self, forKey: .allowedEndpoints)
        self.responseShape = try c.decode(ResponseShape.self, forKey: .responseShape)
        self.creditsPerSecond = try c.decodeIfPresent([String: Double].self, forKey: .creditsPerSecond)
        self.audioDiscountRate = try c.decodeIfPresent([String: Double].self, forKey: .audioDiscountRate)
        self.creditsPerImage = try c.decodeIfPresent([String: Double].self, forKey: .creditsPerImage)
        self.qualities = try c.decodeIfPresent([String].self, forKey: .qualities)
        self.audioPricing = try c.decodeIfPresent(AudioPricing.self, forKey: .audioPricing)
        self.creditsPerSecondUpscale = try c.decodeIfPresent(Double.self, forKey: .creditsPerSecondUpscale)
        self.card = try c.decodeIfPresent(ModelCard.self, forKey: .card)
        self.offers = try c.decodeIfPresent([ProviderOffer].self, forKey: .offers)
        self.resolvedOfferingCapabilities = nil
        switch self.kind {
        case .video:
            self.uiCapabilities = .video(try c.decode(VideoCaps.self, forKey: .uiCapabilities))
        case .image:
            self.uiCapabilities = .image(try c.decode(ImageCaps.self, forKey: .uiCapabilities))
        case .audio:
            self.uiCapabilities = .audio(try c.decode(AudioCaps.self, forKey: .uiCapabilities))
        case .upscale:
            self.uiCapabilities = .upscale(try c.decode(UpscaleCaps.self, forKey: .uiCapabilities))
        }
    }
}

enum VideoDuration: Codable, Sendable, Hashable {
    case seconds(Int)
    case automatic

    var displayLabel: String {
        switch self {
        case .seconds(let value): "\(value)s"
        case .automatic: "Auto"
        }
    }

    var seconds: Int? {
        guard case .seconds(let value) = self else { return nil }
        return value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .seconds(value)
        } else if try container.decode(String.self).lowercased() == "auto" {
            self = .automatic
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Video duration must be an integer number of seconds or 'auto'."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .seconds(let value): try container.encode(value)
        case .automatic: try container.encode("auto")
        }
    }
}

struct VideoDurationCapabilities: Decodable, Sendable, Equatable {
    struct Range: Decodable, Sendable, Equatable {
        let min: Int
        let max: Int
    }

    let discrete: [Int]
    let range: Range?
    let supportsAuto: Bool

    init(discrete: [Int] = [], range: Range? = nil, supportsAuto: Bool = false) {
        self.discrete = discrete
        self.range = range
        self.supportsAuto = supportsAuto
    }

    var options: [VideoDuration] {
        var values = discrete
        if let range, range.min <= range.max {
            values.append(contentsOf: range.min...range.max)
        }
        var options = Array(Set(values)).sorted().map(VideoDuration.seconds)
        if supportsAuto { options.insert(.automatic, at: 0) }
        return options
    }

    var defaultValue: VideoDuration {
        if supportsAuto { return .automatic }
        if let first = discrete.first { return .seconds(first) }
        if let range { return .seconds(range.min) }
        return .seconds(0)
    }

    var maximumSeconds: Int? {
        [discrete.max(), range?.max].compactMap { $0 }.max()
    }

    func accepts(_ duration: VideoDuration) -> Bool {
        switch duration {
        case .automatic:
            return supportsAuto
        case .seconds(let value):
            if discrete.contains(value) { return true }
            if let range { return (range.min...range.max).contains(value) }
            return discrete.isEmpty && range == nil
        }
    }

    var validationLabels: [String] {
        var labels = discrete.map { "\($0)s" }
        if let range { labels.append("\(range.min)–\(range.max)s") }
        if supportsAuto { labels.append("auto") }
        return labels
    }
}

struct VideoCaps: Decodable, Sendable {
    let duration: VideoDurationCapabilities
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let maxReferenceImages: Int
    let maxReferenceVideos: Int
    let maxReferenceAudios: Int
    let maxTotalReferences: Int?
    let maxCombinedVideoRefSeconds: Double?
    let maxCombinedAudioRefSeconds: Double?
    let framesAndReferencesExclusive: Bool
    let referenceTagNoun: String
    let requiresSourceVideo: Bool
    let requiresReferenceImage: Bool
    let framesCountTowardImageReferenceLimit: Bool
    let framesCountTowardTotalReferenceLimit: Bool
    let maxReferenceImagesWhenVideoPresent: Int?

    var durations: [Int] { duration.discrete }

    private enum CodingKeys: String, CodingKey {
        case duration, durations, resolutions, aspectRatios, supportsFirstFrame, supportsLastFrame
        case maxReferenceImages, maxReferenceVideos, maxReferenceAudios, maxTotalReferences
        case maxCombinedVideoRefSeconds, maxCombinedAudioRefSeconds, framesAndReferencesExclusive
        case referenceTagNoun, requiresSourceVideo, requiresReferenceImage
        case framesCountTowardImageReferenceLimit, framesCountTowardTotalReferenceLimit
        case maxReferenceImagesWhenVideoPresent
    }

    init(
        durations: [Int] = [], durationRange: VideoDurationCapabilities.Range? = nil,
        supportsAutomaticDuration: Bool = false,
        resolutions: [String]?, aspectRatios: [String],
        supportsFirstFrame: Bool, supportsLastFrame: Bool,
        maxReferenceImages: Int, maxReferenceVideos: Int, maxReferenceAudios: Int,
        maxTotalReferences: Int?, maxCombinedVideoRefSeconds: Double?,
        maxCombinedAudioRefSeconds: Double?, framesAndReferencesExclusive: Bool,
        referenceTagNoun: String, requiresSourceVideo: Bool, requiresReferenceImage: Bool,
        framesCountTowardImageReferenceLimit: Bool = false,
        framesCountTowardTotalReferenceLimit: Bool = false,
        maxReferenceImagesWhenVideoPresent: Int? = nil
    ) {
        duration = VideoDurationCapabilities(
            discrete: durations,
            range: durationRange,
            supportsAuto: supportsAutomaticDuration
        )
        self.resolutions = resolutions
        self.aspectRatios = aspectRatios
        self.supportsFirstFrame = supportsFirstFrame
        self.supportsLastFrame = supportsLastFrame
        self.maxReferenceImages = maxReferenceImages
        self.maxReferenceVideos = maxReferenceVideos
        self.maxReferenceAudios = maxReferenceAudios
        self.maxTotalReferences = maxTotalReferences
        self.maxCombinedVideoRefSeconds = maxCombinedVideoRefSeconds
        self.maxCombinedAudioRefSeconds = maxCombinedAudioRefSeconds
        self.framesAndReferencesExclusive = framesAndReferencesExclusive
        self.referenceTagNoun = referenceTagNoun
        self.requiresSourceVideo = requiresSourceVideo
        self.requiresReferenceImage = requiresReferenceImage
        self.framesCountTowardImageReferenceLimit = framesCountTowardImageReferenceLimit
        self.framesCountTowardTotalReferenceLimit = framesCountTowardTotalReferenceLimit
        self.maxReferenceImagesWhenVideoPresent = maxReferenceImagesWhenVideoPresent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decodeIfPresent(VideoDurationCapabilities.self, forKey: .duration)
            ?? VideoDurationCapabilities(discrete: try container.decodeIfPresent([Int].self, forKey: .durations) ?? [])
        resolutions = try container.decodeIfPresent([String].self, forKey: .resolutions)
        aspectRatios = try container.decode([String].self, forKey: .aspectRatios)
        supportsFirstFrame = try container.decode(Bool.self, forKey: .supportsFirstFrame)
        supportsLastFrame = try container.decode(Bool.self, forKey: .supportsLastFrame)
        maxReferenceImages = try container.decode(Int.self, forKey: .maxReferenceImages)
        maxReferenceVideos = try container.decode(Int.self, forKey: .maxReferenceVideos)
        maxReferenceAudios = try container.decode(Int.self, forKey: .maxReferenceAudios)
        maxTotalReferences = try container.decodeIfPresent(Int.self, forKey: .maxTotalReferences)
        maxCombinedVideoRefSeconds = try container.decodeIfPresent(Double.self, forKey: .maxCombinedVideoRefSeconds)
        maxCombinedAudioRefSeconds = try container.decodeIfPresent(Double.self, forKey: .maxCombinedAudioRefSeconds)
        framesAndReferencesExclusive = try container.decode(Bool.self, forKey: .framesAndReferencesExclusive)
        referenceTagNoun = try container.decode(String.self, forKey: .referenceTagNoun)
        requiresSourceVideo = try container.decode(Bool.self, forKey: .requiresSourceVideo)
        requiresReferenceImage = try container.decode(Bool.self, forKey: .requiresReferenceImage)
        framesCountTowardImageReferenceLimit = try container.decodeIfPresent(
            Bool.self,
            forKey: .framesCountTowardImageReferenceLimit
        ) ?? false
        framesCountTowardTotalReferenceLimit = try container.decodeIfPresent(
            Bool.self,
            forKey: .framesCountTowardTotalReferenceLimit
        ) ?? false
        maxReferenceImagesWhenVideoPresent = try container.decodeIfPresent(
            Int.self,
            forKey: .maxReferenceImagesWhenVideoPresent
        )
    }
}

enum ImageReferenceLimit: Sendable, Equatable {
    case bounded(Int)
    case capabilityProfile(Int)
    case unknown

    var effectiveMaximum: Int {
        switch self {
        case .bounded(let maximum), .capabilityProfile(let maximum): max(0, maximum)
        case .unknown: 0
        }
    }

    var declaredMaximum: Int? {
        guard case .bounded(let maximum) = self else { return nil }
        return max(0, maximum)
    }
}

struct ImageCaps: Decodable, Sendable {
    let resolutions: [String]?
    let aspectRatios: [String]
    let qualities: [String]?
    let supportsImageReference: Bool
    let requiresImageReference: Bool
    let minReferenceImages: Int
    let referenceImageLimit: ImageReferenceLimit
    let maxImages: Int

    var maxReferenceImages: Int { referenceImageLimit.effectiveMaximum }

    init(
        resolutions: [String]?,
        aspectRatios: [String],
        qualities: [String]?,
        supportsImageReference: Bool,
        requiresImageReference: Bool = false,
        minReferenceImages: Int? = nil,
        maxReferenceImages: Int? = nil,
        referenceImageLimit: ImageReferenceLimit? = nil,
        maxImages: Int
    ) {
        let minimum = max(0, minReferenceImages ?? (requiresImageReference ? 1 : 0))
        let limit = referenceImageLimit ?? .bounded(
            max(0, maxReferenceImages ?? (supportsImageReference ? max(1, minimum) : 0))
        )
        self.resolutions = resolutions
        self.aspectRatios = aspectRatios
        self.qualities = qualities
        self.supportsImageReference = supportsImageReference && limit.effectiveMaximum > 0
        self.requiresImageReference = requiresImageReference || minimum > 0
        self.minReferenceImages = minimum
        self.referenceImageLimit = limit
        self.maxImages = maxImages
    }

    private enum CodingKeys: String, CodingKey {
        case resolutions, aspectRatios, qualities, supportsImageReference
        case requiresImageReference, minReferenceImages, maxReferenceImages, maxImages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let resolutions = try container.decodeIfPresent([String].self, forKey: .resolutions)
        let aspectRatios = try container.decode([String].self, forKey: .aspectRatios)
        let qualities = try container.decodeIfPresent([String].self, forKey: .qualities)
        let supportsImageReference = try container.decode(Bool.self, forKey: .supportsImageReference)
        let requiresImageReference = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresImageReference
        ) ?? false
        let minReferenceImages = try container.decodeIfPresent(
            Int.self,
            forKey: .minReferenceImages
        )
        let maxReferenceImages = try container.decodeIfPresent(
            Int.self,
            forKey: .maxReferenceImages
        )
        self.init(
            resolutions: resolutions,
            aspectRatios: aspectRatios,
            qualities: qualities,
            supportsImageReference: supportsImageReference,
            requiresImageReference: requiresImageReference,
            minReferenceImages: minReferenceImages,
            maxReferenceImages: maxReferenceImages,
            maxImages: try container.decode(Int.self, forKey: .maxImages)
        )
    }
}

struct AudioCaps: Decodable, Sendable {
    let category: String   // "tts" | "music" | "sfx"
    let voices: [String]?
    let defaultVoice: String?
    let supportsLyrics: Bool
    let supportsInstrumental: Bool
    let supportsStyleInstructions: Bool
    let durations: [Int]?
    let minPromptLength: Int
    let inputs: [String]? // "text" | "video"
    let promptLabel: String?
    let minSeconds: Int?
    let maxSeconds: Int?
}

struct UpscaleCaps: Decodable, Sendable {
    let speed: String   // "Fast" | "Medium" | "Slow"
    let p75DurationSeconds: Int
    let supportedTypes: [String]   // "video" | "image"
}
