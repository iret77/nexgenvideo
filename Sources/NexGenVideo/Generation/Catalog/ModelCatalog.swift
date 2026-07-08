import Foundation

enum ModelKind: Sendable {
    case video(VideoModelConfig)
    case image(ImageModelConfig)
    case audio(AudioModelConfig)
    case upscale(UpscaleModelConfig)
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

    private(set) var video: [VideoModelConfig] = []
    private(set) var image: [ImageModelConfig] = []
    private(set) var audio: [AudioModelConfig] = []
    private(set) var upscale: [UpscaleModelConfig] = []
    private(set) var byId: [String: ModelKind] = [:]
    private(set) var cardsById: [String: ModelCard] = [:]
    private(set) var offersById: [String: [ProviderOffer]] = [:]
    private(set) var isLoaded: Bool = false
    private(set) var lastError: String?

    @ObservationIgnored private var didConfigure = false

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        // Convex model-list subscription removed; the BYO-provider layer will
        // populate the catalog via `apply(_:)`. Until then it stays empty.
    }

    func load(entries: [CatalogEntry]) {
        apply(entries)
    }

    private func apply(_ entries: [CatalogEntry]) {
        var newVideo: [VideoModelConfig] = []
        var newImage: [ImageModelConfig] = []
        var newAudio: [AudioModelConfig] = []
        var newUpscale: [UpscaleModelConfig] = []
        var newById: [String: ModelKind] = [:]
        var newCardsById: [String: ModelCard] = [:]
        var newOffersById: [String: [ProviderOffer]] = [:]
        newVideo.reserveCapacity(entries.count)
        newImage.reserveCapacity(entries.count)
        newAudio.reserveCapacity(entries.count)
        newUpscale.reserveCapacity(entries.count)
        newById.reserveCapacity(entries.count)

        for entry in entries {
            if let card = entry.card { newCardsById[entry.id] = card }
            if let offers = entry.offers, !offers.isEmpty { newOffersById[entry.id] = offers }
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
        self.isLoaded = true
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

struct VideoCaps: Decodable, Sendable {
    let durations: [Int]
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
}

struct ImageCaps: Decodable, Sendable {
    let resolutions: [String]?
    let aspectRatios: [String]
    let qualities: [String]?
    let supportsImageReference: Bool
    let maxImages: Int
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
