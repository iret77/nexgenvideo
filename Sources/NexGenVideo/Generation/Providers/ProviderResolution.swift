import Foundation

/// LLM → NGV → Provider → Model.
///
/// The LLM never picks or calls a provider. It asks NGV for a *capability* — a logical
/// model to generate, OR a workflow tool-call — and NGV resolves the concrete
/// (provider, transport) here. Providers expose BOTH kinds over API and/or MCP (fal,
/// Runway, Higgsfield, OpenArt, … all offer both transports). The prompt-engine gate
/// fires only for `.generation` (a creative prompt to a content model); `.tool` calls are
/// NGV-mediated but ungated unless they themselves send such a prompt. This is the pure,
/// testable spine of that resolution — it replaces the hardcoded 1:1 model-id-prefix
/// ladder in `GenerationProvider.servicing` / `GenerationService.runJob`.

/// How NGV reaches a provider. Never a raw LLM tool: for `.mcp`, NGV is the MCP *client*
/// (behind the prompt-engine gate), on the user's subscription/OAuth.
enum ProviderTransport: String, Sendable, Codable, CaseIterable, Hashable {
    case api   // direct REST on the user's own API key
    case mcp   // NGV-as-MCP-client to the provider's server
}

/// Billing reality of a transport — decisive for "cheapest": a flat subscription (`.mcp`)
/// can beat pay-per-use (`.api`) at the same raw rate, and often the reverse. NGV weighs
/// this, not just the sticker price.
enum BillingMode: String, Sendable, Codable, Hashable {
    case perCall        // separate account, charged per generation (typical API)
    case subscription   // flat / already paid (typical MCP)
}

/// What a binding fulfills. Both go LLM → NGV → Provider; only `.generation` (a creative
/// prompt to a content model) passes the prompt-engine gate. `.tool` is a workflow
/// operation — upscale/relight/inpaint, background-removal, roto, reference upload,
/// character lookup, project ops, any provider-specific tool — NGV-mediated but ungated
/// unless it itself sends a creative prompt to a content model.
enum ProviderCapabilityKind: String, Sendable, Codable, Hashable {
    case generation
    case tool
}

struct ProviderProductionInputPolicyV1: Codable, Sendable, Hashable {
    let requiresSourceVideo: Bool
    let framesCountTowardImageReferenceLimit: Bool
    let framesCountTowardTotalReferenceLimit: Bool

    init(
        requiresSourceVideo: Bool,
        framesCountTowardImageReferenceLimit: Bool,
        framesCountTowardTotalReferenceLimit: Bool
    ) {
        self.requiresSourceVideo = requiresSourceVideo
        self.framesCountTowardImageReferenceLimit =
            framesCountTowardImageReferenceLimit
        self.framesCountTowardTotalReferenceLimit =
            framesCountTowardTotalReferenceLimit
    }

    init(videoCapabilities: VideoCaps) {
        self.init(
            requiresSourceVideo: videoCapabilities.requiresSourceVideo,
            framesCountTowardImageReferenceLimit:
                videoCapabilities.framesCountTowardImageReferenceLimit,
            framesCountTowardTotalReferenceLimit:
                videoCapabilities.framesCountTowardTotalReferenceLimit
        )
    }
}

struct ResolvedVideoOfferingCapabilitiesV1: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let inputPolicy: ProviderProductionInputPolicyV1
    let durationValues: [Int]
    let durationMinimum: Int?
    let durationMaximum: Int?
    let supportsAutomaticDuration: Bool
    let supportsNativeAudio: Bool
    let resolutions: [String]?
    let aspectRatios: [String]
    let supportsFirstFrame: Bool
    let supportsLastFrame: Bool
    let maxReferenceImages: Int
    let maxReferenceVideos: Int
    let maxReferenceAudios: Int
    let maxTotalReferences: Int?
    let maxCombinedVideoReferenceSeconds: Double?
    let maxCombinedAudioReferenceSeconds: Double?
    let framesAndReferencesExclusive: Bool
    let requiresReferenceImage: Bool
    let maxReferenceImagesWhenVideoPresent: Int?

    var durationCapabilities: VideoDurationCapabilities {
        VideoDurationCapabilities(
            discrete: durationValues,
            range: durationRange,
            supportsAuto: supportsAutomaticDuration
        )
    }

    var durationRange: VideoDurationCapabilities.Range? {
        guard let durationMinimum,
              let durationMaximum,
              durationMinimum > 0,
              durationMinimum <= durationMaximum else { return nil }
        return VideoDurationCapabilities.Range(
            min: durationMinimum,
            max: durationMaximum
        )
    }

    var contractViolation: String? {
        guard schemaVersion == 1 else { return "schema_version" }
        guard durationValues.allSatisfy({ $0 > 0 }) else {
            return "duration_values"
        }
        guard (durationMinimum == nil) == (durationMaximum == nil) else {
            return "duration_range_pair"
        }
        if let durationMinimum, let durationMaximum,
           durationMinimum <= 0 || durationMaximum < durationMinimum {
            return "duration_range"
        }
        guard maxReferenceImages >= 0,
              maxReferenceVideos >= 0,
              maxReferenceAudios >= 0,
              maxTotalReferences.map({ $0 >= 0 }) ?? true,
              maxCombinedVideoReferenceSeconds.map({ $0 >= 0 }) ?? true,
              maxCombinedAudioReferenceSeconds.map({ $0 >= 0 }) ?? true,
              maxReferenceImagesWhenVideoPresent.map({ $0 >= 0 }) ?? true else {
            return "reference_limits"
        }
        guard !supportsLastFrame || supportsFirstFrame else {
            return "last_frame_without_first_frame"
        }
        if requiresReferenceImage {
            let totalAllowsOne = maxTotalReferences.map { $0 >= 1 } ?? true
            let ordinaryImageAllowed = maxReferenceImages >= 1
                && totalAllowsOne
            let firstFrameAllowed = !inputPolicy.requiresSourceVideo
                && supportsFirstFrame
                && (!inputPolicy.framesCountTowardImageReferenceLimit
                    || maxReferenceImages >= 1)
                && (!inputPolicy.framesCountTowardTotalReferenceLimit
                    || totalAllowsOne)
            guard ordinaryImageAllowed || firstFrameAllowed else {
                return "required_reference_image_unfulfillable"
            }
        }
        return nil
    }

    var supportsReferences: Bool {
        maxReferenceImages > 0 || maxReferenceVideos > 0 || maxReferenceAudios > 0
    }

    func maxReferenceImages(hasVideoReference: Bool) -> Int {
        guard hasVideoReference, let conditional = maxReferenceImagesWhenVideoPresent else {
            return maxReferenceImages
        }
        return min(maxReferenceImages, conditional)
    }

    func validate(
        duration: VideoDuration,
        aspectRatio: String,
        resolution: String?,
        generateAudio: Bool,
        displayName: String
    ) -> String? {
        if let contractViolation {
            return "\(displayName) has an invalid provider capability contract (\(contractViolation))"
        }
        if !durationCapabilities.accepts(duration) {
            return unsupportedValue(
                model: displayName,
                field: "duration",
                value: duration.displayLabel,
                allowed: durationCapabilities.validationLabels
            )
        }
        if !aspectRatios.isEmpty,
           !aspectRatio.isEmpty,
           !aspectRatios.contains(aspectRatio) {
            return unsupportedValue(
                model: displayName,
                field: "aspect ratio",
                value: aspectRatio,
                allowed: aspectRatios
            )
        }
        if let resolutions,
           let resolution,
           !resolution.isEmpty,
           !resolutions.contains(resolution) {
            return unsupportedValue(
                model: displayName,
                field: "resolution",
                value: resolution,
                allowed: resolutions
            )
        }
        if generateAudio && !supportsNativeAudio {
            return "\(displayName) does not support native audio generation"
        }
        return nil
    }
}

extension ResolvedVideoOfferingCapabilitiesV1 {
    init(
        videoCapabilities: VideoCaps,
        inputPolicy: ProviderProductionInputPolicyV1? = nil,
        supportsNativeAudio: Bool
    ) {
        self.init(
            schemaVersion: 1,
            inputPolicy: inputPolicy ?? ProviderProductionInputPolicyV1(
                videoCapabilities: videoCapabilities
            ),
            durationValues: videoCapabilities.duration.discrete,
            durationMinimum: videoCapabilities.duration.range?.min,
            durationMaximum: videoCapabilities.duration.range?.max,
            supportsAutomaticDuration: videoCapabilities.duration.supportsAuto,
            supportsNativeAudio: supportsNativeAudio,
            resolutions: videoCapabilities.resolutions,
            aspectRatios: videoCapabilities.aspectRatios,
            supportsFirstFrame: videoCapabilities.supportsFirstFrame,
            supportsLastFrame: videoCapabilities.supportsLastFrame,
            maxReferenceImages: videoCapabilities.maxReferenceImages,
            maxReferenceVideos: videoCapabilities.maxReferenceVideos,
            maxReferenceAudios: videoCapabilities.maxReferenceAudios,
            maxTotalReferences: videoCapabilities.maxTotalReferences,
            maxCombinedVideoReferenceSeconds:
                videoCapabilities.maxCombinedVideoRefSeconds,
            maxCombinedAudioReferenceSeconds:
                videoCapabilities.maxCombinedAudioRefSeconds,
            framesAndReferencesExclusive:
                videoCapabilities.framesAndReferencesExclusive,
            requiresReferenceImage: videoCapabilities.requiresReferenceImage,
            maxReferenceImagesWhenVideoPresent:
                videoCapabilities.maxReferenceImagesWhenVideoPresent
        )
    }
}

/// One concrete way to fulfil a capability: a (provider, transport) with the provider's
/// own reference and its billing mode. A provider may offer the same capability over both
/// transports (API pay-per-call and MCP subscription) — the resolver weighs both.
struct ProviderBinding: Sendable, Hashable {
    let provider: GenerationProvider
    let transport: ProviderTransport
    let kind: ProviderCapabilityKind
    /// The provider's own reference: a model/endpoint id for `.generation`, a tool name for `.tool`.
    let providerRef: String
    let billing: BillingMode
    /// Declared per-call cost from the catalog offer, when known; nil → resolver uses the
    /// billing-aware heuristic.
    var costPerCall: Double? = nil
    /// For an `.mcp` `.generation` binding whose provider selects the concrete model through a tool
    /// argument (the discovered generate tool takes a free-form `model` id — Higgsfield): the model id
    /// to send. `providerRef` then names the generate TOOL, and this names the MODEL within it. nil for
    /// API bindings and single-model MCP tools.
    var modelParam: String? = nil
    /// Media roles declared by this exact MCP model (`image`, `start_image`, …). The request mapper
    /// uses these instead of guessing one provider-wide role vocabulary.
    var mcpMediaRoles: [String]? = nil
    /// Versioned input semantics for this exact provider endpoint.
    var productionInputPolicy: ProviderProductionInputPolicyV1? = nil
    /// Versioned runtime capabilities for this exact video endpoint.
    var resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1? = nil
}

/// One provider's declared way to serve a model — the DATA that replaces id-prefix inference.
/// A model's `CatalogEntry` carries a list of these (registries declare their own; the hosted
/// catalog can declare several so one logical model is served by multiple providers). The manifest
/// turns each into one exact `ProviderBinding`. `providerRef` is the provider's own endpoint/model
/// id; `costPerCall` (when known) drives the resolver's cheapest pick.
struct ProviderOffer: Codable, Sendable, Hashable {
    let provider: GenerationProvider
    var transport: ProviderTransport = .api
    var providerRef: String? = nil
    var costPerCall: Double? = nil
    /// The provider's own model id for an MCP generate tool that selects the model through a free-form
    /// `model` argument (Higgsfield). `providerRef` names the generate tool; this names the model.
    var modelParam: String? = nil
    /// Per-model roles returned by MCP catalog discovery. Nil for direct API offers and tool-only
    /// MCP providers whose generate schema carries no separate model catalog.
    var mcpMediaRoles: [String]? = nil
    /// Values proven by this exact endpoint and adapter.
    var productionQualityTargetIDs: [String]? = nil
    /// Input accounting proven by this exact endpoint and adapter.
    var productionInputPolicy: ProviderProductionInputPolicyV1? = nil
    /// Output and input limits proven by this exact video endpoint and adapter.
    var resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1? = nil

    private enum CodingKeys: String, CodingKey {
        case provider, transport, providerRef, costPerCall, modelParam, mcpMediaRoles
        case productionQualityTargetIDs
        case productionInputPolicy = "productionInputPolicyV1"
        case resolvedVideoCapabilities = "resolvedVideoOfferingCapabilitiesV1"
    }

    init(provider: GenerationProvider, transport: ProviderTransport = .api,
         providerRef: String? = nil, costPerCall: Double? = nil, modelParam: String? = nil,
         mcpMediaRoles: [String]? = nil,
         productionQualityTargetIDs: [String]? = nil,
         productionInputPolicy: ProviderProductionInputPolicyV1? = nil,
         resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1? = nil) {
        self.provider = provider
        self.transport = transport
        self.providerRef = providerRef
        self.costPerCall = costPerCall
        self.modelParam = modelParam
        self.mcpMediaRoles = mcpMediaRoles
        self.productionQualityTargetIDs = productionQualityTargetIDs
        self.productionInputPolicy = productionInputPolicy
        self.resolvedVideoCapabilities = resolvedVideoCapabilities
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(GenerationProvider.self, forKey: .provider)
        transport = try c.decodeIfPresent(ProviderTransport.self, forKey: .transport) ?? .api
        providerRef = try c.decodeIfPresent(String.self, forKey: .providerRef)
        costPerCall = try c.decodeIfPresent(Double.self, forKey: .costPerCall)
        modelParam = try c.decodeIfPresent(String.self, forKey: .modelParam)
        mcpMediaRoles = try c.decodeIfPresent([String].self, forKey: .mcpMediaRoles)
        productionQualityTargetIDs = try c.decodeIfPresent(
            [String].self,
            forKey: .productionQualityTargetIDs
        )
        productionInputPolicy = try c.decodeIfPresent(
            ProviderProductionInputPolicyV1.self,
            forKey: .productionInputPolicy
        )
        resolvedVideoCapabilities = try c.decodeIfPresent(
            ResolvedVideoOfferingCapabilitiesV1.self,
            forKey: .resolvedVideoCapabilities
        )
    }
}

/// What the user has actually turned on — per (provider, transport). A provider can be
/// active over one transport but not the other (API key present, MCP not connected, …).
struct ProviderActivation: Sendable {
    struct Key: Hashable, Sendable {
        let provider: GenerationProvider
        let transport: ProviderTransport
    }
    let active: Set<Key>

    init(active: Set<Key> = []) { self.active = active }

    func isActive(_ provider: GenerationProvider, _ transport: ProviderTransport) -> Bool {
        active.contains(Key(provider: provider, transport: transport))
    }
}

enum ProviderResolver {
    /// Pick the cheapest ACTIVATED way to fulfil a capability (a logical model to generate,
    /// or a workflow tool-call).
    ///
    /// `bindings` are all the ways it can be fulfilled; `activation` is what the user turned
    /// on; `effectiveCost` returns the billing-aware cost of THIS call for a binding (a
    /// subscription transport typically reports a low/flat marginal cost). Returns `nil`
    /// when no activated provider offers it — in which case the catalog must not have
    /// offered it to the LLM in the first place (usable-only rule).
    static func resolve(
        bindings: [ProviderBinding],
        activation: ProviderActivation,
        effectiveCost: (ProviderBinding) -> Double
    ) -> ProviderBinding? {
        bindings
            .filter { activation.isActive($0.provider, $0.transport) }
            .min { effectiveCost($0) < effectiveCost($1) }
    }

    /// Return one exact active binding per provider for the user-facing provider picker.
    static func preferredActiveBindingPerProvider(
        bindings: [ProviderBinding],
        activation: ProviderActivation,
        effectiveCost: (ProviderBinding) -> Double,
        isCompatible: (ProviderBinding) -> Bool = { _ in true }
    ) -> [ProviderBinding] {
        var best: [GenerationProvider: ProviderBinding] = [:]
        for binding in bindings where activation.isActive(binding.provider, binding.transport)
            && isCompatible(binding) {
            if let current = best[binding.provider],
               effectiveCost(current) <= effectiveCost(binding) {
                continue
            }
            best[binding.provider] = binding
        }
        return GenerationProvider.allCases.compactMap { best[$0] }
    }
}
