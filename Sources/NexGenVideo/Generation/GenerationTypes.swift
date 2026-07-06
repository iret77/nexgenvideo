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
