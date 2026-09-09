import Foundation

public let conditioningStrategyV1Schema = "conditioning-strategy/v1"

public enum ConditioningStrategyKindV1: String, Codable, Sendable, Equatable, CaseIterable {
    case referenceAnchor = "reference_anchor"
    case twoStateInterpolation = "two_state_interpolation"
    case frameContinuation = "frame_continuation"
    case nativeExtension = "native_extension"
    case firstFrame = "first_frame"
}

public enum NativeExtensionDirectionV1: String, Codable, Sendable, Equatable, CaseIterable {
    case forward
    case backward
}

public struct ConditioningAssetBindingV1: Codable, Sendable, Equatable {
    public let demandID: String?
    public let path: String
    public let sha256: String
    public let modality: AssetPhysicalModalityV1
    public let semanticJobID: String
    public let inputSlotID: String

    private enum CodingKeys: String, CodingKey {
        case demandID = "demand_id"
        case path
        case sha256
        case modality
        case semanticJobID = "semantic_job_id"
        case inputSlotID = "input_slot_id"
    }

    public init(
        demandID: String? = nil,
        path: String,
        sha256: String,
        modality: AssetPhysicalModalityV1,
        semanticJobID: String,
        inputSlotID: String
    ) {
        self.demandID = demandID
        self.path = path
        self.sha256 = sha256
        self.modality = modality
        self.semanticJobID = semanticJobID
        self.inputSlotID = inputSlotID
    }
}

public struct ShotConditioningStrategyV1: Codable, Sendable, Equatable {
    public let shotID: String
    public let strategy: ConditioningStrategyKindV1
    public let rationale: String
    public let modeIDs: [String]
    public let referenceAnchors: [ConditioningAssetBindingV1]
    public let sourceVideo: ConditioningAssetBindingV1?
    public let predecessorShotID: String?
    public let sourceShotID: String?
    public let direction: NativeExtensionDirectionV1?
    public let boundaryStateID: String?
    public let originalReferenceDemandIDs: [String]
    public let legacyBehavior: Bool

    private enum CodingKeys: String, CodingKey {
        case shotID = "shot_id"
        case strategy
        case rationale
        case modeIDs = "mode_ids"
        case referenceAnchors = "reference_anchors"
        case sourceVideo = "source_video"
        case predecessorShotID = "predecessor_shot_id"
        case sourceShotID = "source_shot_id"
        case direction
        case boundaryStateID = "boundary_state_id"
        case originalReferenceDemandIDs = "original_reference_demand_ids"
        case legacyBehavior = "legacy_behavior"
    }

    public init(
        shotID: String,
        strategy: ConditioningStrategyKindV1,
        rationale: String,
        modeIDs: [String],
        referenceAnchors: [ConditioningAssetBindingV1] = [],
        sourceVideo: ConditioningAssetBindingV1? = nil,
        predecessorShotID: String? = nil,
        sourceShotID: String? = nil,
        direction: NativeExtensionDirectionV1? = nil,
        boundaryStateID: String? = nil,
        originalReferenceDemandIDs: [String] = [],
        legacyBehavior: Bool = false
    ) {
        self.shotID = shotID
        self.strategy = strategy
        self.rationale = rationale
        self.modeIDs = modeIDs
        self.referenceAnchors = referenceAnchors
        self.sourceVideo = sourceVideo
        self.predecessorShotID = predecessorShotID
        self.sourceShotID = sourceShotID
        self.direction = direction
        self.boundaryStateID = boundaryStateID
        self.originalReferenceDemandIDs = originalReferenceDemandIDs
        self.legacyBehavior = legacyBehavior
    }
}

public struct ConditioningStrategyPlanV1: Codable, Sendable, Equatable {
    public static let relativePath = PipelineLayout.conditioningStrategyFile
    public static let artifactRole = "core.conditioning-strategy"

    public let schema: String
    public let id: String
    public let projectID: String
    public let shotlistSHA256: String
    public let strategies: [ShotConditioningStrategyV1]

    private enum CodingKeys: String, CodingKey {
        case schema
        case id
        case projectID = "project_id"
        case shotlistSHA256 = "shotlist_sha256"
        case strategies
    }

    public init(
        schema: String = conditioningStrategyV1Schema,
        id: String,
        projectID: String,
        shotlistSHA256: String,
        strategies: [ShotConditioningStrategyV1]
    ) {
        self.schema = schema
        self.id = id
        self.projectID = projectID
        self.shotlistSHA256 = shotlistSHA256
        self.strategies = strategies
    }
}

public enum ConditioningStrategyValidationErrorV1: Error, Sendable, Equatable {
    case unsupportedSchema(String)
    case invalidField(String)
    case duplicateShot(String)
    case invalidIdentity
    case strategyMismatch(String)
    case referencePlanMismatch(String)
}

public enum ConditioningStrategyCanonicalCodecV1 {
    public static func encode(_ value: ConditioningStrategyPlanV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode(_ data: Data) throws -> ConditioningStrategyPlanV1 {
        let value = try JSONDecoder().decode(ConditioningStrategyPlanV1.self, from: data)
        try ConditioningStrategyValidatorV1.validate(value)
        return value
    }

    public static func identified(
        projectID: String,
        shotlistSHA256: String,
        strategies: [ShotConditioningStrategyV1]
    ) throws -> ConditioningStrategyPlanV1 {
        let pending = ConditioningStrategyPlanV1(
            id: "pending",
            projectID: projectID,
            shotlistSHA256: shotlistSHA256,
            strategies: strategies
        )
        let identity = try encode(pending)
        return ConditioningStrategyPlanV1(
            id: "conditioning-\(FileDigest.sha256(of: identity))",
            projectID: projectID,
            shotlistSHA256: shotlistSHA256,
            strategies: strategies
        )
    }
}

public enum ConditioningStrategyValidatorV1 {
    public static func validate(_ plan: ConditioningStrategyPlanV1) throws {
        guard plan.schema == conditioningStrategyV1Schema else {
            throw ConditioningStrategyValidationErrorV1.unsupportedSchema(plan.schema)
        }
        try require(plan.projectID, "project_id")
        try hash(plan.shotlistSHA256, "shotlist_sha256")
        let shotIDs = plan.strategies.map(\.shotID)
        guard Set(shotIDs).count == shotIDs.count else {
            throw ConditioningStrategyValidationErrorV1.duplicateShot(
                shotIDs.first { id in shotIDs.filter { $0 == id }.count > 1 } ?? "unknown"
            )
        }
        for item in plan.strategies { try validate(item) }
        let expected = try ConditioningStrategyCanonicalCodecV1.identified(
            projectID: plan.projectID,
            shotlistSHA256: plan.shotlistSHA256,
            strategies: plan.strategies
        )
        guard plan.id == expected.id else {
            throw ConditioningStrategyValidationErrorV1.invalidIdentity
        }
    }

    public static func validate(
        _ strategy: ShotConditioningStrategyV1,
        referencePlan: ReferencePlanV2
    ) throws {
        try validate(strategy)
        guard strategy.shotID == referencePlan.shotID else {
            throw ConditioningStrategyValidationErrorV1.referencePlanMismatch(strategy.shotID)
        }
        let bindings = referencePlan.bindings
        let firstFrames = bindings.filter { matches($0.semanticJobID, CoreReferenceSemanticJobIDV1.firstFrame) }
        let lastFrames = bindings.filter { matches($0.semanticJobID, CoreReferenceSemanticJobIDV1.lastFrame) }
        let predecessorFrames = bindings.filter { matches($0.semanticJobID, CoreReferenceSemanticJobIDV1.predecessorLastFrame) }
        let sourceVideos = bindings.filter { matches($0.semanticJobID, CoreReferenceSemanticJobIDV1.sourceVideo) }
        let anchorIDs = Set(strategy.referenceAnchors.compactMap(\.demandID))
        let actualAnchorIDs = Set(bindings.filter {
            matches($0.semanticJobID, CoreReferenceSemanticJobIDV1.referenceAnchor)
        }.map(\.demandID))

        let valid: Bool = switch strategy.strategy {
        case .referenceAnchor:
            firstFrames.isEmpty && lastFrames.isEmpty && predecessorFrames.isEmpty
                && sourceVideos.isEmpty && actualAnchorIDs == anchorIDs
        case .twoStateInterpolation:
            firstFrames.count == 1 && lastFrames.count == 1
                && predecessorFrames.isEmpty && sourceVideos.isEmpty
        case .frameContinuation:
            firstFrames.isEmpty && lastFrames.isEmpty && predecessorFrames.count == 1
                && sourceVideos.isEmpty
                && predecessorFrames[0].expectedSourceShotID == strategy.predecessorShotID
        case .nativeExtension:
            firstFrames.isEmpty && lastFrames.isEmpty && predecessorFrames.isEmpty
                && sourceVideos.count == 1
                && Set(strategy.originalReferenceDemandIDs).isSubset(of: Set(bindings.map(\.demandID)))
        case .firstFrame:
            firstFrames.count == 1 && lastFrames.isEmpty && predecessorFrames.isEmpty
                && sourceVideos.isEmpty
        }
        let relevantBindings: [ReferenceBindingV2] = switch strategy.strategy {
        case .referenceAnchor:
            bindings.filter { anchorIDs.contains($0.demandID) }
        case .twoStateInterpolation:
            firstFrames + lastFrames
        case .frameContinuation:
            predecessorFrames
        case .nativeExtension:
            sourceVideos + bindings.filter {
                strategy.originalReferenceDemandIDs.contains($0.demandID)
            }
        case .firstFrame:
            firstFrames
        }
        let declaredModes = Set(strategy.modeIDs.map(
            ProductionIdentifierNormalizerV1.canonical
        ))
        let boundModes = Set(relevantBindings.map(\.modeID).map(
            ProductionIdentifierNormalizerV1.canonical
        ))
        let exactAssets = strategy.referenceAnchors.allSatisfy { asset in
            relevantBindings.contains { bindingMatches(asset, $0) }
        } && (strategy.sourceVideo.map { asset in
            relevantBindings.contains { bindingMatches(asset, $0) }
        } ?? true)
        guard valid, declaredModes == boundModes, exactAssets else {
            throw ConditioningStrategyValidationErrorV1.referencePlanMismatch(strategy.shotID)
        }
    }

    private static func validate(_ item: ShotConditioningStrategyV1) throws {
        try require(item.shotID, "shot_id")
        try require(item.rationale, "rationale")
        guard !item.modeIDs.isEmpty,
              Set(item.modeIDs.map(ProductionIdentifierNormalizerV1.canonical)).count
                == item.modeIDs.count else {
            throw ConditioningStrategyValidationErrorV1.invalidField("mode_ids")
        }
        for modeID in item.modeIDs { try require(modeID, "mode_ids") }
        guard Set(item.originalReferenceDemandIDs).count
                == item.originalReferenceDemandIDs.count else {
            throw ConditioningStrategyValidationErrorV1.invalidField(
                "original_reference_demand_ids"
            )
        }
        for binding in item.referenceAnchors + [item.sourceVideo].compactMap({ $0 }) {
            try validate(binding)
        }
        guard Set(item.referenceAnchors.compactMap(\.demandID)).count
                == item.referenceAnchors.count else {
            throw ConditioningStrategyValidationErrorV1.invalidField("reference_anchors")
        }

        let valid: Bool = switch item.strategy {
        case .referenceAnchor:
            !item.referenceAnchors.isEmpty && item.referenceAnchors.allSatisfy {
                $0.modality == .image
                    && matches($0.semanticJobID, CoreReferenceSemanticJobIDV1.referenceAnchor)
            } && item.sourceVideo == nil && item.predecessorShotID == nil
                && item.sourceShotID == nil && item.direction == nil
                && item.boundaryStateID == nil
        case .twoStateInterpolation:
            item.referenceAnchors.isEmpty && item.sourceVideo == nil
                && item.predecessorShotID == nil && item.sourceShotID == nil
                && item.direction == nil
                && item.boundaryStateID == nil
                && item.originalReferenceDemandIDs.isEmpty
        case .frameContinuation:
            item.referenceAnchors.isEmpty && item.sourceVideo == nil
                && nonEmpty(item.predecessorShotID) && item.direction == nil
                && item.sourceShotID == nil && item.boundaryStateID == nil
                && item.originalReferenceDemandIDs.isEmpty
        case .nativeExtension:
            item.referenceAnchors.isEmpty && item.sourceVideo?.modality == .video
                && matches(
                    item.sourceVideo?.semanticJobID ?? "",
                    CoreReferenceSemanticJobIDV1.sourceVideo
                ) && item.predecessorShotID == nil && nonEmpty(item.sourceShotID)
                && item.direction != nil
                && nonEmpty(item.boundaryStateID)
        case .firstFrame:
            item.referenceAnchors.isEmpty && item.sourceVideo == nil
                && item.predecessorShotID == nil && item.sourceShotID == nil
                && item.direction == nil
                && item.boundaryStateID == nil
        }
        guard valid else {
            throw ConditioningStrategyValidationErrorV1.strategyMismatch(item.shotID)
        }
        if item.legacyBehavior,
           item.strategy != .firstFrame && item.strategy != .frameContinuation {
            throw ConditioningStrategyValidationErrorV1.strategyMismatch(item.shotID)
        }
    }

    private static func validate(_ binding: ConditioningAssetBindingV1) throws {
        try requireOptional(binding.demandID, "demand_id")
        guard !binding.path.isEmpty, !binding.path.hasPrefix("/"), !binding.path.contains("..") else {
            throw ConditioningStrategyValidationErrorV1.invalidField("path")
        }
        try hash(binding.sha256, "sha256")
        try require(binding.semanticJobID, "semantic_job_id")
        try require(binding.inputSlotID, "input_slot_id")
    }

    private static func require(_ value: String, _ field: String) throws {
        guard nonEmpty(value) else {
            throw ConditioningStrategyValidationErrorV1.invalidField(field)
        }
    }

    private static func requireOptional(_ value: String?, _ field: String) throws {
        if let value { try require(value, field) }
    }

    private static func hash(_ value: String, _ field: String) throws {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit }) else {
            throw ConditioningStrategyValidationErrorV1.invalidField(field)
        }
    }

    private static func nonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        ProductionIdentifierNormalizerV1.matches(lhs, rhs)
    }

    private static func bindingMatches(
        _ asset: ConditioningAssetBindingV1,
        _ binding: ReferenceBindingV2
    ) -> Bool {
        (asset.demandID == nil || asset.demandID == binding.demandID)
            && asset.path == binding.path
            && asset.sha256 == binding.sha256
            && asset.modality == binding.modality
            && matches(asset.semanticJobID, binding.semanticJobID)
            && matches(asset.inputSlotID, binding.inputSlotID)
    }
}
