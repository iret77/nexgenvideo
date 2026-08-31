import Foundation

struct ImageGenerationParams: Encodable, Sendable {
    let prompt: String
    let aspectRatio: String
    let resolution: String?
    let quality: String?
    let imageURLs: [String]
    let numImages: Int

    enum CodingKeys: String, CodingKey {
        case kind, prompt, aspectRatio, resolution, quality, imageURLs, numImages
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

    func validate(aspectRatio: String, resolution: String?, quality: String?, imageRefCount: Int, numImages: Int) -> String? {
        if !aspectRatios.isEmpty, !aspectRatio.isEmpty, !aspectRatios.contains(aspectRatio) {
            return unsupportedValue(model: displayName, field: "aspect ratio", value: aspectRatio, allowed: aspectRatios)
        }
        if let allowed = resolutions, let r = resolution, !r.isEmpty, !allowed.contains(r) {
            return unsupportedValue(model: displayName, field: "resolution", value: r, allowed: allowed)
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
        return nil
    }

    /// Parse a "WxH" resolution label (e.g. "1920x1080") into pixel dims.
    static func parseWxH(_ s: String) -> (Int, Int)? {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }

    /// Human-readable label for a resolution ID.
    static func resolutionDisplayLabel(_ id: String) -> String {
        guard let (w, h) = parseWxH(id) else { return id }
        if w == h { return "Square" }
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
        return tier.isEmpty ? orientation : "\(orientation) \(tier)"
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
        isAvailable: (ImageModelConfig) -> Bool
    ) -> [ImageAlternativeCandidate] {
        models
            .filter { $0.id != modelId && isAvailable($0) }
            .compactMap { model in
                let adaptedAspect = model.aspectRatios.contains(aspectRatio)
                    ? aspectRatio
                    : (model.aspectRatios.first ?? aspectRatio)
                let adaptedResolution = model.resolutions.map { allowed in
                    resolution.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed.first
                } ?? resolution
                let adaptedQuality = model.qualities.map { allowed in
                    quality.flatMap { allowed.contains($0) ? $0 : nil } ?? allowed.last
                } ?? quality
                guard model.validate(
                    aspectRatio: adaptedAspect,
                    resolution: adaptedResolution,
                    quality: adaptedQuality,
                    imageRefCount: referenceCount,
                    numImages: 1
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
