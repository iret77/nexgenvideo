import Foundation

struct ImageGenerationParams: Encodable, Sendable {
    let prompt: String
    let aspectRatio: String
    let resolution: String?
    let quality: String?
    let imageURLs: [String]
    let numImages: Int
    let maskURL: String?
    let background: String?
    let outputFormat: String?
    let outputCompression: Int?

    init(
        prompt: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        imageURLs: [String],
        numImages: Int,
        maskURL: String? = nil,
        background: String? = nil,
        outputFormat: String? = nil,
        outputCompression: Int? = nil
    ) {
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.quality = quality
        self.imageURLs = imageURLs
        self.numImages = numImages
        self.maskURL = maskURL
        self.background = background
        self.outputFormat = outputFormat
        self.outputCompression = outputCompression
    }

    enum CodingKeys: String, CodingKey {
        case kind, prompt, aspectRatio, resolution, quality, imageURLs, numImages
        case maskURL, background, outputFormat, outputCompression
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("image", forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encodeIfPresent(resolution, forKey: .resolution)
        try c.encodeIfPresent(quality, forKey: .quality)
        if !imageURLs.isEmpty { try c.encode(imageURLs, forKey: .imageURLs) }
        try c.encode(numImages, forKey: .numImages)
        try c.encodeIfPresent(maskURL, forKey: .maskURL)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(outputFormat, forKey: .outputFormat)
        try c.encodeIfPresent(outputCompression, forKey: .outputCompression)
    }
}

struct ImageModelConfig: Identifiable, Sendable {
    @MainActor
    static var allModels: [ImageModelConfig] { ModelCatalog.shared.image }

    /// Default model for the "Edit on image" seed: the Gemini (nano-banana) edit
    /// model, falling back to any reference-capable image model.
    @MainActor
    static var nanoBananaPro: ImageModelConfig? {
        allModels.first(where: { $0.id == "fal-ai/gemini-25-flash-image/edit" })
            ?? allModels.first(where: { $0.supportsImageReference })
    }

    let entry: CatalogEntry
    let caps: ImageCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }
    var creditsPerImage: [String: Double] { entry.creditsPerImage ?? [:] }

    var resolutions: [String]? { caps.resolutions }
    var aspectRatios: [String] { caps.aspectRatios }
    var qualities: [String]? { caps.qualities }
    var supportsImageReference: Bool { caps.supportsImageReference }
    var requiresImageReference: Bool { caps.requiresImageReference }
    var minReferenceImages: Int { caps.minReferenceImages }
    var maxReferenceImages: Int { caps.maxReferenceImages }
    var referenceImageLimit: ImageReferenceLimit { caps.referenceImageLimit }
    var declaredMaxReferenceImages: Int? { referenceImageLimit.declaredMaximum }
    var maxImages: Int { max(1, caps.maxImages) }
    var backgrounds: [String]? { caps.backgrounds }
    var outputFormats: [String]? { caps.outputFormats }
    var defaultOutputFormat: String? { caps.defaultOutputFormat }
    var supportsOutputCompression: Bool { caps.supportsOutputCompression }
    var supportsMask: Bool { caps.supportsMask }
    var customSize: ImageCustomSizeCaps? { caps.customSize }

    func validate(
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        imageRefCount: Int,
        numImages: Int,
        background: String? = nil,
        outputFormat: String? = nil,
        outputCompression: Int? = nil,
        hasMask: Bool = false
    ) -> String? {
        if !aspectRatios.isEmpty, !aspectRatio.isEmpty, !aspectRatios.contains(aspectRatio) {
            guard let customSize,
                  let ratio = Self.parseAspectRatio(aspectRatio),
                  (customSize.minAspectRatio...customSize.maxAspectRatio).contains(ratio) else {
                return unsupportedValue(model: displayName, field: "aspect ratio", value: aspectRatio, allowed: aspectRatios)
            }
        }
        if let allowed = resolutions, let r = resolution, !r.isEmpty, !allowed.contains(r) {
            guard let customSize, let dimensions = Self.parseWxH(r) else {
                return unsupportedValue(model: displayName, field: "resolution", value: r, allowed: allowed)
            }
            if let error = Self.validateCustomSize(dimensions, constraints: customSize) {
                return "\(displayName) \(error)"
            }
        }
        if customSize != nil {
            guard let resolution, !resolution.isEmpty else {
                return "\(displayName) requires an explicit resolution or auto size."
            }
            if (resolution == "auto") != (aspectRatio == "auto") {
                return "\(displayName) requires auto size and auto aspect ratio to be selected together."
            }
        }
        if let resolution, let dimensions = Self.parseWxH(resolution),
           let requestedRatio = Self.parseAspectRatio(aspectRatio),
           abs(Double(dimensions.0) / Double(dimensions.1) - requestedRatio) > 0.02 {
            return "\(displayName) resolution \(resolution) does not match aspect ratio \(aspectRatio)."
        }
        if let allowed = qualities, let q = quality, !q.isEmpty, !allowed.contains(q) {
            return unsupportedValue(model: displayName, field: "quality", value: q, allowed: allowed)
        }
        if imageRefCount > 0, !supportsImageReference {
            return "\(displayName) does not accept reference images."
        }
        if imageRefCount < minReferenceImages {
            if minReferenceImages == 1 {
                return "\(displayName) requires a reference image."
            }
            return "\(displayName) requires at least \(minReferenceImages) reference images."
        }
        switch referenceImageLimit {
        case .bounded(let maximum) where imageRefCount > maximum:
            return "\(displayName) accepts at most \(maximum) reference image\(maximum == 1 ? "" : "s") (got \(imageRefCount))."
        case .capabilityProfile(let maximum) where imageRefCount > maximum:
            return "\(displayName) reliably accepts at most \(maximum) reference image\(maximum == 1 ? "" : "s") (got \(imageRefCount))."
        default:
            break
        }
        if numImages < 1 || numImages > maxImages {
            return "\(displayName) supports 1…\(maxImages) image\(maxImages == 1 ? "" : "s") per request (got \(numImages))."
        }
        if let background {
            guard let allowed = backgrounds else {
                return "\(displayName) does not support background selection."
            }
            if !allowed.contains(background) {
                return unsupportedValue(model: displayName, field: "background", value: background, allowed: allowed)
            }
        }
        if let outputFormat {
            guard let allowed = outputFormats else {
                return "\(displayName) does not support output format selection."
            }
            if !allowed.contains(outputFormat) {
                return unsupportedValue(model: displayName, field: "output format", value: outputFormat, allowed: allowed)
            }
        }
        if let outputCompression {
            guard supportsOutputCompression else {
                return "\(displayName) does not support output compression."
            }
            guard (0...100).contains(outputCompression) else {
                return "Output compression must be between 0 and 100."
            }
            let format = outputFormat ?? defaultOutputFormat
            if format != "jpeg" && format != "webp" {
                return "Output compression requires JPEG or WebP output."
            }
        }
        if background == "transparent" {
            let format = outputFormat ?? defaultOutputFormat
            if format != "png" && format != "webp" {
                return "Transparent backgrounds require PNG or WebP output."
            }
        }
        if hasMask && !supportsMask {
            return "\(displayName) does not accept an edit mask."
        }
        return nil
    }

    func defaultResolution(for aspectRatio: String) -> String? {
        guard let resolutions else { return nil }
        guard let requestedRatio = Self.parseAspectRatio(aspectRatio) else {
            return resolutions.first
        }
        return resolutions.first { resolution in
            guard let dimensions = Self.parseWxH(resolution) else { return false }
            return abs(Double(dimensions.0) / Double(dimensions.1) - requestedRatio) <= 0.02
        } ?? resolutions.first
    }

    /// Parse a "WxH" resolution label (e.g. "1920x1080") into pixel dims.
    static func parseWxH(_ s: String) -> (Int, Int)? {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    private static func parseAspectRatio(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0 else { return nil }
        return width / height
    }

    private static func validateCustomSize(
        _ dimensions: (Int, Int),
        constraints: ImageCustomSizeCaps
    ) -> String? {
        let (width, height) = dimensions
        guard constraints.dimensionMultiple > 0,
              constraints.maxEdge > 0,
              constraints.minPixels > 0,
              constraints.maxPixels >= constraints.minPixels,
              constraints.minAspectRatio > 0,
              constraints.maxAspectRatio >= constraints.minAspectRatio else {
            return "has an invalid custom-size capability contract."
        }
        guard width > 0, height > 0 else {
            return "custom dimensions must be positive."
        }
        guard width.isMultiple(of: constraints.dimensionMultiple),
              height.isMultiple(of: constraints.dimensionMultiple) else {
            return "custom dimensions must be multiples of \(constraints.dimensionMultiple)."
        }
        guard max(width, height) <= constraints.maxEdge else {
            return "custom dimensions have a maximum edge of \(constraints.maxEdge) px."
        }
        let pixels = width * height
        guard (constraints.minPixels...constraints.maxPixels).contains(pixels) else {
            return "custom dimensions must contain \(constraints.minPixels)…\(constraints.maxPixels) pixels."
        }
        let ratio = Double(width) / Double(height)
        guard (constraints.minAspectRatio...constraints.maxAspectRatio).contains(ratio) else {
            return "custom aspect ratio must be between 1:3 and 3:1."
        }
        return nil
    }

    /// Human-readable label for a resolution ID.
    static func resolutionDisplayLabel(_ id: String) -> String {
        guard let (w, h) = parseWxH(id) else { return id }
        let dimensions = "\(w)×\(h)"
        if w == h { return "Square \(dimensions)" }
        let orientation = w > h ? "Landscape" : "Portrait"
        let longEdge = max(w, h)
        let tier: String
        switch longEdge {
        case 3840:        tier = "4K"
        case 2560:        tier = "2K"
        case 1920:        tier = "1080p"
        case 1024, 1536:  tier = ""
        default:          tier = "\(longEdge)p"
        }
        return tier.isEmpty
            ? "\(orientation) \(dimensions)"
            : "\(orientation) \(tier) (\(dimensions))"
    }
}

struct ImageAlternativeCandidate: Sendable {
    let model: ImageModelConfig
    let aspectRatio: String
    let resolution: String?
    let quality: String?
}

enum ImageAlternativeResolver {
    static func candidates(
        models: [ImageModelConfig],
        excluding modelId: String,
        aspectRatio: String,
        resolution: String?,
        quality: String?,
        referenceCount: Int,
        background: String? = nil,
        outputFormat: String? = nil,
        outputCompression: Int? = nil,
        hasMask: Bool = false,
        isAvailable: (ImageModelConfig) -> Bool
    ) -> [ImageAlternativeCandidate] {
        models
            .filter { $0.id != modelId && isAvailable($0) }
            .compactMap { model in
                let adaptedAspect = model.aspectRatios.contains(aspectRatio)
                    ? aspectRatio
                    : (model.aspectRatios.first ?? aspectRatio)
                let adaptedResolution = model.resolutions.map { allowed in
                    resolution.flatMap { allowed.contains($0) ? $0 : nil }
                        ?? model.defaultResolution(for: adaptedAspect)
                } ?? resolution
                let adaptedQuality = model.qualities.map { allowed in
                    quality.flatMap { allowed.contains($0) ? $0 : nil }
                        ?? (allowed.contains("high") ? "high" : allowed.last)
                } ?? quality
                guard model.validate(
                    aspectRatio: adaptedAspect,
                    resolution: adaptedResolution,
                    quality: adaptedQuality,
                    imageRefCount: referenceCount,
                    numImages: 1,
                    background: background,
                    outputFormat: outputFormat,
                    outputCompression: outputCompression,
                    hasMask: hasMask
                ) == nil else { return nil }
                return ImageAlternativeCandidate(
                    model: model,
                    aspectRatio: adaptedAspect,
                    resolution: adaptedResolution,
                    quality: adaptedQuality
                )
            }
            .sorted {
                $0.model.displayName.localizedCaseInsensitiveCompare($1.model.displayName)
                    == .orderedAscending
            }
    }
}
