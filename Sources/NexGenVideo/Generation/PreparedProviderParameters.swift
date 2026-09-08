import Foundation

struct PreparedProviderParameters: Sendable {
    let parameters: BackendGenerationParams
    private let slots: [String]

    init(referenceCount: Int, build: ([String]) -> BackendGenerationParams) throws {
        guard referenceCount >= 0 else { throw GenerationRequestError.optionsInvalid("The reference count is invalid.") }
        let namespace = UUID().uuidString
        slots = (0..<referenceCount).map { "ngv-reference-slot://\(namespace)/\($0)" }
        parameters = build(slots)
        switch parameters {
        case .video, .image: break
        default: throw GenerationRequestError.optionsInvalid("The prepared request has the wrong media type.")
        }
    }

    func bind(_ uploaded: [String]) throws -> BackendGenerationParams {
        guard uploaded.count == slots.count, uploaded.allSatisfy({ !$0.isEmpty }) else {
            throw GenerationRequestError.optionsInvalid("The uploaded references do not match the prepared request. Prepare the generation again.")
        }
        let replacements = Dictionary(uniqueKeysWithValues: zip(slots, uploaded))
        func resolve(_ value: String) -> String { replacements[value] ?? value }
        switch parameters {
        case .video(let value):
            return .video(VideoGenerationParams(prompt: value.prompt, duration: value.duration,
                aspectRatio: value.aspectRatio, resolution: value.resolution,
                sourceVideoURL: value.sourceVideoURL.map(resolve), startFrameURL: value.startFrameURL.map(resolve),
                endFrameURL: value.endFrameURL.map(resolve), referenceImageURLs: value.referenceImageURLs.map(resolve),
                referenceVideoURLs: value.referenceVideoURLs.map(resolve), referenceAudioURLs: value.referenceAudioURLs.map(resolve),
                generateAudio: value.generateAudio))
        case .image(let value):
            return .image(ImageGenerationParams(prompt: value.prompt, aspectRatio: value.aspectRatio,
                resolution: value.resolution, quality: value.quality, imageURLs: value.imageURLs.map(resolve), numImages: value.numImages))
        default:
            throw GenerationRequestError.optionsInvalid("The prepared request has the wrong media type.")
        }
    }
}
