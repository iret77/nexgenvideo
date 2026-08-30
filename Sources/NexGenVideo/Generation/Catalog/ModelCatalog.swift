import Foundation

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

    private init() {}

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
                    for offer in (entry.offers ?? []) where !offers.contains(offer) { offers.append(offer) }
                    existing.offers = offers
                    byId[entry.id] = existing
                } else {
                    byId[entry.id] = entry
                    order.append(entry.id)
                }
            }
        }
        let base = Self.gatingCompletedDirectImageProviders(
            in: baseEntries,
            completedProviders: completedDiscoveryProviders
        )
        add(base)
        for provider in GenerationProvider.allCases {
            if let entries = discoveredByProvider[provider] { add(entries) }
        }
        return order.map { byId[$0]! }
    }

    static func gatingCompletedDirectImageProviders(
        in entries: [CatalogEntry],
        completedProviders: Set<GenerationProvider>
    ) -> [CatalogEntry] {
        let gated = completedProviders.intersection(DirectImageDiscovery.providers)
        guard !gated.isEmpty else { return entries }
        return entries.compactMap { entry in
            guard case .image = entry.uiCapabilities else { return entry }
            var filtered = entry
            let offers = entry.offers ?? ProviderManifest.defaultOffers(forModelId: entry.id)
            filtered.offers = offers.filter { !gated.contains($0.provider) }
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
        var newVideo: [VideoModelConfig] = []
        var newImage: [ImageModelConfig] = []
        var newAudio: [AudioModelConfig] = []
        var newUpscale: [UpscaleModelConfig] = []
        var newById: [String: ModelKind] = [:]
        var newCardsById: [String: ModelCard] = [:]
        var newOffersById: [String: [ProviderOffer]] = [:]
        var newInternalByLogical: [String: String] = [:]
        newVideo.reserveCapacity(entries.count)
        newImage.reserveCapacity(entries.count)
        newAudio.reserveCapacity(entries.count)
        newUpscale.reserveCapacity(entries.count)
        newById.reserveCapacity(entries.count)

        for entry in entries {
            if let card = entry.card { newCardsById[entry.id] = card }
            if let offers = entry.offers, !offers.isEmpty { newOffersById[entry.id] = offers }
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
        self.lastError = nil
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
        offers: [ProviderOffer]? = nil
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
    case providerUnbounded(hostMaximum: Int)
    case unknown

    var hostMaximum: Int {
        switch self {
        case .bounded(let maximum), .providerUnbounded(let maximum): max(0, maximum)
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

    var maxReferenceImages: Int { referenceImageLimit.hostMaximum }

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
        self.supportsImageReference = supportsImageReference && limit.hostMaximum > 0
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
