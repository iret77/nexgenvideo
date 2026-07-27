import Foundation

// MARK: - Generation parameter / job types
//
// Provider-agnostic generation types, submitted through the BYO-provider-key layer
// (fal.ai / Runway / …) in Generation/Providers.

enum BackendGenerationParams: Encodable, Sendable {
    case video(VideoGenerationParams)
    case image(ImageGenerationParams)
    case audio(AudioGenerationParams)
    case upscale(UpscaleGenerationParams)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .video(let p): try c.encode(p)
        case .image(let p): try c.encode(p)
        case .audio(let p): try c.encode(p)
        case .upscale(let p): try c.encode(p)
        }
    }
}

struct ResolvedGenerationTarget: Sendable, Hashable {
    let modelId: String
    let provider: GenerationProvider
    let endpoint: String
    let binding: ProviderBinding?

    var transport: ProviderTransport { binding?.transport ?? .api }
}

struct GenerationPricingInput: Sendable, Equatable {
    let modelId: String
    let modality: GenerationRequest.Modality
    let durationSeconds: Double?
    let outputCount: Int
    let resolution: String?
    let quality: String?
    let promptCharacterCount: Int
    let generateAudio: Bool?
}

struct GenerationMoney: Codable, Sendable, Equatable {
    let nativeAmount: Double
    let nativeCurrency: String
    let eurAmount: Double
    let eurPerNativeUnit: Double
    let exchangeRateDate: String
    let pricingSource: String
    let exchangeRateSource: String
}

struct GenerationSpendEvent: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case reserved
        case submitted
        case charged
        case released
    }

    var id: String = UUID().uuidString
    let transactionId: String
    let kind: Kind
    let model: String
    let provider: GenerationProvider
    let transport: ProviderTransport
    let endpoint: String
    let providerRequestId: String?
    let money: GenerationMoney?
    let note: String?
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        transactionId: String,
        kind: Kind,
        model: String,
        provider: GenerationProvider,
        transport: ProviderTransport,
        endpoint: String,
        providerRequestId: String? = nil,
        money: GenerationMoney? = nil,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.transactionId = transactionId
        self.kind = kind
        self.model = model
        self.provider = provider
        self.transport = transport
        self.endpoint = endpoint
        self.providerRequestId = providerRequestId
        self.money = money
        self.note = note
        self.createdAt = createdAt
    }
}

struct GenerationAuthorization: Sendable {
    let transactionId: String?
    let target: ResolvedGenerationTarget
    let estimate: GenerationMoney?
}

enum BackendGenerationStatus: String, Decodable, Sendable {
    case queued, running, succeeded, failed
}

struct BackendGenerationJob: Decodable, Sendable {
    let _id: String
    let status: BackendGenerationStatus
    let resultUrls: [String]?
    let errorMessage: String?
    let costCredits: Int?
    let completedAt: Double?

    init(
        _id: String,
        status: BackendGenerationStatus,
        resultUrls: [String]?,
        errorMessage: String?,
        costCredits: Int?,
        completedAt: Double?
    ) {
        self._id = _id
        self.status = status
        self.resultUrls = resultUrls
        self.errorMessage = errorMessage
        self.costCredits = costCredits
        self.completedAt = completedAt
    }
}

enum GenerationBackendError: LocalizedError {
    case notConfigured
    case transport(String)
    case api(status: Int, code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Generation isn't available yet."
        case .transport(let s): return s
        case .api(_, _, let message): return message
        }
    }
}
