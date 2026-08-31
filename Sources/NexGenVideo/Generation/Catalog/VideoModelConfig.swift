import Foundation

func unsupportedValue(model displayName: String, field: String, value: String, allowed: [String]) -> String {
    "\(displayName) does not support \(field) '\(value)'. Valid: \(allowed.joined(separator: ", "))."
}

struct VideoModelConfig: Identifiable, Sendable {
    @MainActor
    static var allModels: [VideoModelConfig] { ModelCatalog.shared.video }

    let entry: CatalogEntry
    let caps: VideoCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }
    var creditsPerSecond: [String: Double] { entry.creditsPerSecond ?? [:] }
    var audioDiscountRate: [String: Double]? { entry.audioDiscountRate }

    var durationCapabilities: VideoDurationCapabilities { caps.duration }
    var durationOptions: [VideoDuration] { caps.duration.options }
    var durations: [Int] { caps.duration.discrete }
    var resolutions: [String]? { caps.resolutions }
    var aspectRatios: [String] { caps.aspectRatios }
    var supportsFirstFrame: Bool { caps.supportsFirstFrame }
    var supportsLastFrame: Bool { caps.supportsLastFrame }
    var maxReferenceImages: Int { caps.maxReferenceImages }
    var maxReferenceVideos: Int { caps.maxReferenceVideos }
    var maxReferenceAudios: Int { caps.maxReferenceAudios }
    var maxTotalReferences: Int? { caps.maxTotalReferences }
    var maxCombinedVideoRefSeconds: Double? { caps.maxCombinedVideoRefSeconds }
    var maxCombinedAudioRefSeconds: Double? { caps.maxCombinedAudioRefSeconds }
    var framesAndReferencesExclusive: Bool { caps.framesAndReferencesExclusive }
    var referenceTagNoun: String { caps.referenceTagNoun }
    var requiresSourceVideo: Bool { caps.requiresSourceVideo }
    var requiresReferenceImage: Bool { caps.requiresReferenceImage }
    var framesCountTowardImageReferenceLimit: Bool {
        caps.framesCountTowardImageReferenceLimit
    }
    var framesCountTowardTotalReferenceLimit: Bool {
        caps.framesCountTowardTotalReferenceLimit
    }
    var maxReferenceImagesWhenVideoPresent: Int? {
        caps.maxReferenceImagesWhenVideoPresent
    }

    func maxReferenceImages(hasVideoReference: Bool) -> Int {
        guard hasVideoReference, let conditional = maxReferenceImagesWhenVideoPresent else {
            return maxReferenceImages
        }
        return min(maxReferenceImages, conditional)
    }

    var supportsReferences: Bool {
        maxReferenceImages > 0 || maxReferenceVideos > 0 || maxReferenceAudios > 0
    }

    /// Total reference count available across types. Used by agent tool info.
    var maxReferences: Int {
        maxTotalReferences ?? (maxReferenceImages + maxReferenceVideos + maxReferenceAudios)
    }

    func audioDiscount(for resolution: String?) -> Double? {
        guard let dict = audioDiscountRate else { return nil }
        if let key = resolution, let v = dict[key] { return v }
        return dict[""]
    }

    func validate(duration: VideoDuration, aspectRatio: String, resolution: String?) -> String? {
        if !durationCapabilities.accepts(duration) {
            return unsupportedValue(
                model: displayName, field: "duration",
                value: duration.displayLabel, allowed: durationCapabilities.validationLabels
            )
        }
        if !aspectRatios.isEmpty, !aspectRatio.isEmpty, !aspectRatios.contains(aspectRatio) {
            return unsupportedValue(model: displayName, field: "aspect ratio", value: aspectRatio, allowed: aspectRatios)
        }
        if let allowed = resolutions, let r = resolution, !r.isEmpty, !allowed.contains(r) {
            return unsupportedValue(model: displayName, field: "resolution", value: r, allowed: allowed)
        }
        return nil
    }

    func validate(duration: Int, aspectRatio: String, resolution: String?) -> String? {
        validate(duration: .seconds(duration), aspectRatio: aspectRatio, resolution: resolution)
    }
}

struct VideoGenerationParams: Encodable, Sendable {
    let prompt: String
    let duration: VideoDuration
    let aspectRatio: String
    let resolution: String?
    let sourceVideoURL: String?
    let startFrameURL: String?
    let endFrameURL: String?
    let referenceImageURLs: [String]
    let referenceVideoURLs: [String]
    let referenceAudioURLs: [String]
    let generateAudio: Bool

    init(
        prompt: String, duration: VideoDuration, aspectRatio: String, resolution: String?,
        sourceVideoURL: String? = nil,
        startFrameURL: String? = nil, endFrameURL: String? = nil,
        referenceImageURLs: [String] = [],
        referenceVideoURLs: [String] = [],
        referenceAudioURLs: [String] = [],
        generateAudio: Bool = true
    ) {
        self.prompt = prompt; self.duration = duration
        self.aspectRatio = aspectRatio; self.resolution = resolution
        self.sourceVideoURL = sourceVideoURL
        self.startFrameURL = startFrameURL; self.endFrameURL = endFrameURL
        self.referenceImageURLs = referenceImageURLs
        self.referenceVideoURLs = referenceVideoURLs
        self.referenceAudioURLs = referenceAudioURLs
        self.generateAudio = generateAudio
    }

    init(
        prompt: String, duration: Int, aspectRatio: String, resolution: String?,
        sourceVideoURL: String? = nil,
        startFrameURL: String? = nil, endFrameURL: String? = nil,
        referenceImageURLs: [String] = [],
        referenceVideoURLs: [String] = [],
        referenceAudioURLs: [String] = [],
        generateAudio: Bool = true
    ) {
        self.init(
            prompt: prompt, duration: .seconds(duration), aspectRatio: aspectRatio,
            resolution: resolution, sourceVideoURL: sourceVideoURL,
            startFrameURL: startFrameURL, endFrameURL: endFrameURL,
            referenceImageURLs: referenceImageURLs,
            referenceVideoURLs: referenceVideoURLs,
            referenceAudioURLs: referenceAudioURLs,
            generateAudio: generateAudio
        )
    }

    var hasAnyReferences: Bool {
        !referenceImageURLs.isEmpty || !referenceVideoURLs.isEmpty || !referenceAudioURLs.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case kind, prompt, duration, aspectRatio, resolution, sourceVideoURL
        case startFrameURL, endFrameURL, referenceImageURLs, referenceVideoURLs
        case referenceAudioURLs, generateAudio
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("video", forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(duration, forKey: .duration)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encodeIfPresent(resolution, forKey: .resolution)
        try c.encodeIfPresent(sourceVideoURL, forKey: .sourceVideoURL)
        try c.encodeIfPresent(startFrameURL, forKey: .startFrameURL)
        try c.encodeIfPresent(endFrameURL, forKey: .endFrameURL)
        if !referenceImageURLs.isEmpty { try c.encode(referenceImageURLs, forKey: .referenceImageURLs) }
        if !referenceVideoURLs.isEmpty { try c.encode(referenceVideoURLs, forKey: .referenceVideoURLs) }
        if !referenceAudioURLs.isEmpty { try c.encode(referenceAudioURLs, forKey: .referenceAudioURLs) }
        try c.encode(generateAudio, forKey: .generateAudio)
    }
}
