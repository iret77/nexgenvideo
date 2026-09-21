import Foundation

struct UpscaleGenerationParams: Encodable, Sendable {
    let sourceURL: String
    let durationSeconds: Int
    let targetResolution: String?
    let scaleFactor: Int?

    enum CodingKeys: String, CodingKey {
        case kind, sourceURL, durationSeconds, targetResolution, scaleFactor
    }

    init(
        sourceURL: String,
        durationSeconds: Int,
        targetResolution: String? = nil,
        scaleFactor: Int? = nil
    ) {
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
        self.targetResolution = targetResolution
        self.scaleFactor = scaleFactor
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("upscale", forKey: .kind)
        try c.encode(sourceURL, forKey: .sourceURL)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(targetResolution, forKey: .targetResolution)
        try c.encodeIfPresent(scaleFactor, forKey: .scaleFactor)
    }
}

struct UpscaleSelection: Identifiable, Sendable {
    let model: UpscaleModelConfig
    let targetResolution: String?
    let scaleFactor: Int?

    var id: String { "\(model.id)|\(targetResolution ?? "default")" }

    var displayName: String {
        guard let targetResolution else { return model.displayName }
        return "\(model.displayName) · \(targetResolution)"
    }

    func label(durationSeconds: Double) -> String {
        let cost = CostEstimator.upscaleCost(model: model, durationSeconds: durationSeconds)
        return "\(displayName) · \(model.speed) · \(CostEstimator.format(cost))"
    }
}

struct UpscaleModelConfig: Identifiable, Sendable {
    @MainActor
    static var allModels: [UpscaleModelConfig] { ModelCatalog.shared.upscale }

    @MainActor
    static var allIds: Set<String> { Set(allModels.map(\.id)) }

    @MainActor
    static func models(for type: ClipType) -> [UpscaleModelConfig] {
        availableModels(in: allModels, for: type,
                        isEnabled: ModelPreferences.shared.isEnabled,
                        canRun: { GenerationProvider.canRun(modelId: $0) })
    }

    static func availableModels(
        in models: [UpscaleModelConfig], for type: ClipType,
        isEnabled: (String) -> Bool, canRun: (String) -> Bool
    ) -> [UpscaleModelConfig] {
        models.filter { $0.supportedTypes.contains(type) && isEnabled($0.id) && canRun($0.id) }
    }

    @MainActor
    static func selections(
        for asset: MediaAsset,
        effectiveDuration: Double? = nil
    ) -> [UpscaleSelection] {
        models(for: asset.type).flatMap {
            $0.selections(
                sourceType: asset.type,
                sourceWidth: asset.sourceWidth,
                sourceHeight: asset.sourceHeight,
                durationSeconds: effectiveDuration ?? asset.duration
            )
        }
    }

    let entry: CatalogEntry
    let caps: UpscaleCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }
    var creditsPerSecond: Double? { entry.creditsPerSecondUpscale }

    var speed: String { caps.speed }
    var p75DurationSeconds: Int { caps.p75DurationSeconds }
    var supportedTypes: Set<ClipType> {
        Set(caps.supportedTypes.compactMap(ClipType.init(rawValue:)))
    }

    var targetResolutions: [String] { caps.targets.map(\.resolution) }

    func selection(
        sourceType: ClipType,
        sourceWidth: Int?,
        sourceHeight: Int?,
        durationSeconds: Double,
        targetResolution: String?
    ) -> UpscaleSelection? {
        let available = selections(
            sourceType: sourceType,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            durationSeconds: durationSeconds
        )
        if let targetResolution {
            return available.first {
                $0.targetResolution?.caseInsensitiveCompare(targetResolution) == .orderedSame
            }
        }
        return available.count == 1 ? available[0] : available.first {
            $0.targetResolution == nil
        }
    }

    func selections(
        sourceType: ClipType,
        sourceWidth: Int?,
        sourceHeight: Int?,
        durationSeconds: Double
    ) -> [UpscaleSelection] {
        guard supportedTypes.contains(sourceType) else { return [] }
        if let maximum = caps.maxDurationSecondsExclusive,
           durationSeconds >= Double(maximum) {
            return []
        }
        let needsDimensions = !caps.targets.isEmpty
            || caps.maxInputLongEdgeExclusive != nil
            || caps.maxInputShortEdgeExclusive != nil
        guard needsDimensions else {
            return [UpscaleSelection(model: self, targetResolution: nil, scaleFactor: nil)]
        }
        guard let sourceWidth, let sourceHeight,
              sourceWidth > 0, sourceHeight > 0 else { return [] }
        let sourceLongEdge = max(sourceWidth, sourceHeight)
        let sourceShortEdge = min(sourceWidth, sourceHeight)
        if let maximum = caps.maxInputLongEdgeExclusive,
           sourceLongEdge >= maximum {
            return []
        }
        if let maximum = caps.maxInputShortEdgeExclusive,
           sourceShortEdge >= maximum {
            return []
        }
        guard !caps.targets.isEmpty else {
            return [UpscaleSelection(model: self, targetResolution: nil, scaleFactor: nil)]
        }
        return caps.targets.compactMap { target in
            guard target.longEdge % sourceLongEdge == 0,
                  target.shortEdge % sourceShortEdge == 0 else { return nil }
            let longScale = target.longEdge / sourceLongEdge
            let shortScale = target.shortEdge / sourceShortEdge
            guard longScale == shortScale,
                  target.scaleFactors.contains(longScale) else { return nil }
            return UpscaleSelection(
                model: self,
                targetResolution: target.resolution,
                scaleFactor: longScale
            )
        }
    }
}
