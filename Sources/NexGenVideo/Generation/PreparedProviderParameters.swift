import Foundation

struct PreparedProviderParameters: Sendable {
    let parameters: BackendGenerationParams
    private let slots: [String]
    var referenceSlots: [String] { slots }

    init(referenceCount: Int, build: ([String]) -> BackendGenerationParams) throws {
        guard referenceCount >= 0 else { throw GenerationRequestError.optionsInvalid("The reference count is invalid.") }
        let namespace = UUID().uuidString
        let slots = (0..<referenceCount).map { "ngv-reference-slot://\(namespace)/\($0)" }
        try self.init(parameters: build(slots), referenceSlots: slots)
    }

    init(parameters: BackendGenerationParams, referenceSlots: [String]) throws {
        self.parameters = parameters
        slots = referenceSlots
        let used: [String]
        switch parameters {
        case .video(let video):
            used = [video.sourceVideoURL, video.startFrameURL, video.endFrameURL].compactMap { $0 }
                + video.referenceImageURLs + video.referenceVideoURLs + video.referenceAudioURLs
        case .image(let image): used = image.imageURLs
        default: throw GenerationRequestError.optionsInvalid("The prepared request has the wrong media type.")
        }
        guard used.count == slots.count, Set(used) == Set(slots), Set(slots).count == slots.count,
              slots.allSatisfy({ !$0.isEmpty }) else {
            throw GenerationRequestError.optionsInvalid("The request must use each prepared reference exactly once; embedded or omitted references require a new request.")
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
