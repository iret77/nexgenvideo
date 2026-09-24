import Foundation

struct HiggsfieldModel: Sendable {
    enum Operation: String, CaseIterable, Sendable {
        case image, textToVideo = "text-to-video", imageToVideo = "image-to-video"
        case referenceToVideo = "reference-to-video", edit = "video-edit", extend = "video-extend"
    }
    let operation: Operation
    let endpoint: String
    let entry: CatalogEntry
}

enum HiggsfieldModelRegistry {
    static let idPrefix = "higgsfield/api/"
    static let aspects = ["16:9", "4:3", "1:1", "3:4", "9:16", "21:9"]
    static let imageAspects = ["9:16", "16:9", "4:3", "3:4", "1:1", "2:3", "3:2"]
    static let models = HiggsfieldModel.Operation.allCases.map(makeModel)
    static let entries = models.map(\.entry)

    static func model(for id: String) -> HiggsfieldModel? {
        models.first { $0.entry.id == id || $0.endpoint == id }
    }

    static func discoveredEntries(availableModelIDs: Set<String>) -> [CatalogEntry] {
        models.filter { availableModelIDs.contains($0.endpoint) }.map(\.entry)
    }

    private static func makeModel(_ operation: HiggsfieldModel.Operation) -> HiggsfieldModel {
        let endpoint = operation == .image ? "higgsfield-ai/soul/v2/standard" : "bytedance/seedance-2.5/\(operation.rawValue)"
        let id = idPrefix + endpoint
        if operation == .image {
            return HiggsfieldModel(operation: operation, endpoint: endpoint, entry: CatalogEntry(
                id: id, kind: .image, displayName: "Soul 2 · API", allowedEndpoints: [endpoint], responseShape: .images,
                uiCapabilities: .image(ImageCaps(resolutions: ["720p", "1080p"], aspectRatios: imageAspects,
                    qualities: nil, supportsImageReference: false, maxReferenceImages: 0, maxImages: 1)),
                offers: [ProviderOffer(provider: .higgsfield, providerRef: endpoint)]))
        }
        let source = operation == .edit || operation == .extend
        let references = operation == .referenceToVideo || source
        let frames = operation == .imageToVideo
        let caps = VideoCaps(
            durations: operation == .edit ? [] : Array(4...30),
            resolutions: ["480p", "720p"], aspectRatios: source || frames ? [] : aspects,
            supportsFirstFrame: frames, supportsLastFrame: frames,
            maxReferenceImages: references ? 30 : 0, maxReferenceVideos: references ? 10 : 0,
            maxReferenceAudios: references ? 10 : 0, maxTotalReferences: references ? 50 : nil,
            maxCombinedVideoRefSeconds: nil, maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: true, referenceTagNoun: "image",
            requiresSourceVideo: source, requiresReferenceImage: frames,
            sourceVideoOperation: operation == .extend ? .extendForward : nil)
        let name: String
        switch operation {
        case .textToVideo: name = "Text to Video"
        case .imageToVideo: name = "First / Last Frame"
        case .referenceToVideo: name = "References"
        case .edit: name = "Edit"
        case .extend: name = "Extend"
        case .image: name = "Image"
        }
        return HiggsfieldModel(operation: operation, endpoint: endpoint, entry: CatalogEntry(
            id: id, kind: .video, displayName: "Seedance 2.5 · \(name) · API",
            allowedEndpoints: [endpoint], responseShape: .video, uiCapabilities: .video(caps),
            offers: [ProviderOffer(provider: .higgsfield, providerRef: endpoint,
                productionInputPolicy: ProviderProductionInputPolicyV1(videoCapabilities: caps),
                resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1(videoCapabilities: caps, supportsNativeAudio: true))]))
    }
}

enum HiggsfieldInputBuilder {
    static func body(model: HiggsfieldModel, params: BackendGenerationParams) throws -> Data {
        var body: [String: Any]
        switch params {
        case .image(let image) where model.operation == .image:
            guard case .image(let caps) = model.entry.uiCapabilities else { throw invalid("Invalid image contract.") }
            if let message = ImageModelConfig(entry: model.entry, caps: caps).validate(
                aspectRatio: image.aspectRatio, resolution: image.resolution, quality: image.quality,
                imageRefCount: image.imageURLs.count, numImages: image.numImages) { throw invalid(message) }
            guard image.quality == nil, !image.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("Soul 2 requires a prompt and does not accept a quality option.")
            }
            body = ["prompt": image.prompt, "batch_size": image.numImages,
                    "aspect_ratio": image.aspectRatio, "resolution": image.resolution ?? "720p", "enhance_prompt": false]
        case .video(let video) where model.operation != .image:
            guard case .video(let caps) = model.entry.uiCapabilities,
                  !video.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("Higgsfield video requires a compiled prompt.")
            }
            if let message = VideoModelConfig(entry: model.entry, caps: caps).validate(
                duration: video.duration, aspectRatio: video.aspectRatio, resolution: video.resolution) { throw invalid(message) }
            guard video.referenceImageURLs.count <= caps.maxReferenceImages,
                  video.referenceVideoURLs.count <= caps.maxReferenceVideos,
                  video.referenceAudioURLs.count <= caps.maxReferenceAudios else {
                throw invalid("The reference count exceeds this Higgsfield endpoint's limits.")
            }
            body = ["prompt": video.prompt, "resolution": video.resolution ?? "720p",
                    "generate_audio": video.generateAudio, "bitrate_mode": "high"]
            if model.operation != .edit {
                guard case .seconds(let duration) = video.duration else { throw invalid("Higgsfield requires an explicit duration.") }
                body["duration"] = duration
            }
            switch model.operation {
            case .textToVideo:
                guard video.sourceVideoURL == nil, video.startFrameURL == nil, video.endFrameURL == nil, !video.hasAnyReferences else {
                    throw invalid("Text to Video does not accept media inputs.")
                }
                body["aspect_ratio"] = video.aspectRatio
            case .imageToVideo:
                guard let start = video.startFrameURL, video.sourceVideoURL == nil, !video.hasAnyReferences else {
                    throw invalid("Image to Video requires a start frame and accepts only an optional end frame.")
                }
                body["image_url"] = start
                body["end_image_url"] = video.endFrameURL
            case .referenceToVideo:
                guard video.hasAnyReferences, video.sourceVideoURL == nil, video.startFrameURL == nil, video.endFrameURL == nil else {
                    throw invalid("Reference to Video requires references without explicit frames or source video.")
                }
                body["aspect_ratio"] = video.aspectRatio
            case .edit, .extend:
                guard let source = video.sourceVideoURL, video.startFrameURL == nil, video.endFrameURL == nil else {
                    throw invalid("Higgsfield Edit and Extend require the approved source video without explicit frames.")
                }
                body["video_url"] = source
            case .image: throw invalid("Invalid Higgsfield video route.")
            }
            if !video.referenceImageURLs.isEmpty { body["image_urls"] = video.referenceImageURLs }
            if !video.referenceVideoURLs.isEmpty { body["video_urls"] = video.referenceVideoURLs }
            if !video.referenceAudioURLs.isEmpty { body["audio_urls"] = video.referenceAudioURLs }
        default: throw invalid("Unsupported Higgsfield request type.")
        }
        for key in ["image_url", "end_image_url", "video_url", "image_urls", "video_urls", "audio_urls"] {
            let values = (body[key] as? [String]) ?? (body[key] as? String).map { [$0] } ?? []
            guard values.allSatisfy({ value in
                guard let url = URL(string: value) else { return false }
                return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
            }) else { throw invalid("Upload Higgsfield references before submitting or estimating.") }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func invalid(_ message: String) -> GenerationBackendError { .transport(message) }
}
