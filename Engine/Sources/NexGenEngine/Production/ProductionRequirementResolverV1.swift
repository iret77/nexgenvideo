import Foundation

public let productionRouteV1Schema = "production-route/v1"

public struct ProductionInputSlotCapabilityV1: Codable, Sendable, Equatable {
    public let id: String
    public let modality: AssetPhysicalModalityV1
    public let modeIDs: [String]
    public let requestOrder: Int
    public let countsTowardModalityBudget: Bool
    public let countsTowardTotalBudget: Bool
    public let countsTowardCombinedDuration: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case modality
        case modeIDs = "mode_ids"
        case requestOrder = "request_order"
        case countsTowardModalityBudget = "counts_toward_modality_budget"
        case countsTowardTotalBudget = "counts_toward_total_budget"
        case countsTowardCombinedDuration = "counts_toward_combined_duration"
    }

    public init(
        id: String,
        modality: AssetPhysicalModalityV1,
        modeIDs: [String],
        requestOrder: Int,
        countsTowardModalityBudget: Bool,
        countsTowardTotalBudget: Bool,
        countsTowardCombinedDuration: Bool
    ) {
        self.id = id
        self.modality = modality
        self.modeIDs = modeIDs
        self.requestOrder = requestOrder
        self.countsTowardModalityBudget = countsTowardModalityBudget
        self.countsTowardTotalBudget = countsTowardTotalBudget
        self.countsTowardCombinedDuration = countsTowardCombinedDuration
    }
}

public struct ProductionRouteCapabilitySnapshotV1: Codable, Sendable, Equatable {
    public let capabilities: ResolvedOfferingCapabilityProfileV1
    public let inputSlots: [ProductionInputSlotCapabilityV1]
    public let qualityTargetIDs: [String]
    public let satisfiedProductionProfileRequirementIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case inputSlots = "input_slots"
        case qualityTargetIDs = "quality_target_ids"
        case satisfiedProductionProfileRequirementIDs = "satisfied_profile_requirement_ids"
    }

    public init(candidate: ProductionRouteCandidateV1) {
        capabilities = candidate.capabilities
        inputSlots = candidate.inputSlots.map {
            ProductionInputSlotCapabilityV1(
                id: $0.id,
                modality: $0.modality,
                modeIDs: Array(Set($0.modeIDs)).sorted(),
                requestOrder: $0.requestOrder,
                countsTowardModalityBudget: $0.countsTowardModalityBudget,
                countsTowardTotalBudget: $0.countsTowardTotalBudget,
                countsTowardCombinedDuration: $0.countsTowardCombinedDuration
            )
        }.sorted { $0.id < $1.id }
        qualityTargetIDs = Array(Set(candidate.qualityTargetIDs)).sorted()
        satisfiedProductionProfileRequirementIDs =
            Array(Set(candidate.satisfiedProductionProfileRequirementIDs)).sorted()
    }
}

public struct ProductionRouteFingerprintsV1: Sendable, Equatable {
    public let requirementSHA256: String
    public let capabilitiesSHA256: String
    public let routeSHA256: String

    public init(
        requirementSHA256: String,
        capabilitiesSHA256: String,
        routeSHA256: String
    ) {
        self.requirementSHA256 = requirementSHA256
        self.capabilitiesSHA256 = capabilitiesSHA256
        self.routeSHA256 = routeSHA256
    }
}

public struct ProductionRouteCandidateV1: Codable, Sendable, Equatable {
    public let capabilities: ResolvedOfferingCapabilityProfileV1
    public let providerActivated: Bool
    public let liveAvailable: Bool
    public let qualityScore: Double
    public let preferenceScore: Double
    public let qualityTargetIDs: [String]
    public let satisfiedProductionProfileRequirementIDs: [String]
    public let inputSlots: [ProductionInputSlotCapabilityV1]
    public let estimatedCost: Double?
    public let estimatedLatencySeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case providerActivated = "provider_activated"
        case liveAvailable = "live_available"
        case qualityScore = "quality_score"
        case preferenceScore = "preference_score"
        case qualityTargetIDs = "quality_target_ids"
        case satisfiedProductionProfileRequirementIDs = "satisfied_profile_requirement_ids"
        case inputSlots = "input_slots"
        case estimatedCost = "estimated_cost"
        case estimatedLatencySeconds = "estimated_latency_seconds"
    }

    public init(
        capabilities: ResolvedOfferingCapabilityProfileV1,
        providerActivated: Bool,
        liveAvailable: Bool,
        qualityScore: Double = 0,
        preferenceScore: Double = 0,
        qualityTargetIDs: [String] = [],
        satisfiedProductionProfileRequirementIDs: [String] = [],
        inputSlots: [ProductionInputSlotCapabilityV1] = [],
        estimatedCost: Double? = nil,
        estimatedLatencySeconds: Double? = nil
    ) {
        self.capabilities = capabilities
        self.providerActivated = providerActivated
        self.liveAvailable = liveAvailable
        self.qualityScore = qualityScore
        self.preferenceScore = preferenceScore
        self.qualityTargetIDs = qualityTargetIDs
        self.satisfiedProductionProfileRequirementIDs = satisfiedProductionProfileRequirementIDs
        self.inputSlots = inputSlots
        self.estimatedCost = estimatedCost
        self.estimatedLatencySeconds = estimatedLatencySeconds
    }
}

public enum ProductionRouteDeficitCodeV1: String, Codable, Sendable, Equatable {
    case providerNotActivated = "provider_not_activated"
    case offerUnavailable = "offer_unavailable"
    case modalityUnsupported = "modality_unsupported"
    case modeUnsupported = "mode_unsupported"
    case visibleEntityCapacity = "visible_entity_capacity"
    case referenceCapacity = "reference_capacity"
    case inputSlotUnsupported = "input_slot_unsupported"
    case referenceDuration = "reference_duration"
    case referenceDurationUnknown = "reference_duration_unknown"
    case firstFrameUnsupported = "first_frame_unsupported"
    case lastFrameUnsupported = "last_frame_unsupported"
    case sourceVideoUnsupported = "source_video_unsupported"
    case durationUnsupported = "duration_unsupported"
    case resolutionUnsupported = "resolution_unsupported"
    case aspectRatioUnsupported = "aspect_ratio_unsupported"
    case outputAudioUnsupported = "output_audio_unsupported"
    case qualityUnsupported = "quality_unsupported"
    case productionProfileRequirementUnsupported = "profile_requirement_unsupported"
    case costUnknown = "cost_unknown"
    case costExceeded = "cost_exceeded"
    case latencyUnknown = "latency_unknown"
    case latencyExceeded = "latency_exceeded"
}

public struct ProductionRouteDeficitV1: Codable, Sendable, Equatable {
    public let code: ProductionRouteDeficitCodeV1
    public let capabilityFieldID: String?
    public let requiredValue: String
    public let availableValue: String?
    public let origin: ResolvedCapabilityOriginV1?

    private enum CodingKeys: String, CodingKey {
        case code
        case capabilityFieldID = "capability_field_id"
        case requiredValue = "required_value"
        case availableValue = "available_value"
        case origin
    }

    public init(
        code: ProductionRouteDeficitCodeV1,
        capabilityFieldID: String? = nil,
        requiredValue: String,
        availableValue: String? = nil,
        origin: ResolvedCapabilityOriginV1? = nil
    ) {
        self.code = code
        self.capabilityFieldID = capabilityFieldID
        self.requiredValue = requiredValue
        self.availableValue = availableValue
        self.origin = origin
    }
}

public struct ProductionRouteEvaluationV1: Codable, Sendable, Equatable {
    public let candidate: ProductionRouteCandidateV1
    public let deficits: [ProductionRouteDeficitV1]

    public init(
        candidate: ProductionRouteCandidateV1,
        deficits: [ProductionRouteDeficitV1]
    ) {
        self.candidate = candidate
        self.deficits = deficits
    }
}

public struct ProductionRouteMatchV1: Sendable, Equatable {
    public let route: ProductionRouteV1
    public let candidate: ProductionRouteCandidateV1

    public init(route: ProductionRouteV1, candidate: ProductionRouteCandidateV1) {
        self.route = route
        self.candidate = candidate
    }
}

public struct ProductionRouteV1: Codable, Sendable, Equatable {
    public static let artifactRole = "core.production-route"
    public let schema: String
    public let id: String
    public let projectID: String
    public let shotID: String
    public let offering: CapabilityOfferingIdentityV1
    public let capabilitySnapshot: ProductionRouteCapabilitySnapshotV1
    public let requirementSHA256: String
    public let capabilitiesSHA256: String
    public let routeSHA256: String
    public let researchNeeded: Bool
    public let qualityScore: Double
    public let preferenceScore: Double
    public let estimatedCost: Double?
    public let estimatedLatencySeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case schema
        case id
        case projectID = "project_id"
        case shotID = "shot_id"
        case offering
        case capabilitySnapshot = "capability_snapshot"
        case requirementSHA256 = "requirement_sha256"
        case capabilitiesSHA256 = "capabilities_sha256"
        case routeSHA256 = "route_sha256"
        case researchNeeded = "research_needed"
        case qualityScore = "quality_score"
        case preferenceScore = "preference_score"
        case estimatedCost = "estimated_cost"
        case estimatedLatencySeconds = "estimated_latency_seconds"
    }

    public init(
        schema: String = productionRouteV1Schema,
        id: String,
        projectID: String,
        shotID: String,
        offering: CapabilityOfferingIdentityV1,
        capabilitySnapshot: ProductionRouteCapabilitySnapshotV1,
        requirementSHA256: String,
        capabilitiesSHA256: String,
        routeSHA256: String,
        researchNeeded: Bool,
        qualityScore: Double,
        preferenceScore: Double,
        estimatedCost: Double?,
        estimatedLatencySeconds: Double?
    ) {
        self.schema = schema
        self.id = id
        self.projectID = projectID
        self.shotID = shotID
        self.offering = offering
        self.capabilitySnapshot = capabilitySnapshot
        self.requirementSHA256 = requirementSHA256
        self.capabilitiesSHA256 = capabilitiesSHA256
        self.routeSHA256 = routeSHA256
        self.researchNeeded = researchNeeded
        self.qualityScore = qualityScore
        self.preferenceScore = preferenceScore
        self.estimatedCost = estimatedCost
        self.estimatedLatencySeconds = estimatedLatencySeconds
    }
}

public enum ProductionRouteRecoveryActionV1: String, Codable, Sendable, Equatable {
    case activateProviderOrModel = "activate_provider_or_model"
    case researchCapabilities = "research_capabilities"
    case splitShot = "split_shot"
    case useRescueCut = "use_rescue_cut"
    case reviseReferencePlan = "revise_reference_plan"
    case editRequirements = "edit_requirements"
}

public struct ProductionRouteNoMatchV1: Codable, Sendable, Equatable {
    public let requirementSHA256: String
    public let evaluations: [ProductionRouteEvaluationV1]
    public let recoveryActions: [ProductionRouteRecoveryActionV1]

    private enum CodingKeys: String, CodingKey {
        case requirementSHA256 = "requirement_sha256"
        case evaluations
        case recoveryActions = "recovery_actions"
    }

    public init(
        requirementSHA256: String,
        evaluations: [ProductionRouteEvaluationV1],
        recoveryActions: [ProductionRouteRecoveryActionV1]
    ) {
        self.requirementSHA256 = requirementSHA256
        self.evaluations = evaluations
        self.recoveryActions = recoveryActions
    }
}

public enum ProductionRouteResolutionV1: Sendable, Equatable {
    case matched(route: ProductionRouteV1, candidate: ProductionRouteCandidateV1)
    case noMatch(ProductionRouteNoMatchV1)
}

public enum ProductionRequirementResolverErrorV1: Error, Sendable, Equatable {
    case projectMismatch
    case invalidRequirement(String)
    case invalidCandidate(String)
}

public enum ProductionReferenceDemandSemanticsV1 {
    public static let dedicatedSemanticJobIDs = Set([
        CoreReferenceSemanticJobIDV1.firstFrame,
        CoreReferenceSemanticJobIDV1.lastFrame,
        CoreReferenceSemanticJobIDV1.predecessorLastFrame,
        CoreReferenceSemanticJobIDV1.sourceVideo,
        CoreReferenceSemanticJobIDV1.audioTiming,
    ])

    public static func isDedicated(semanticJobID: String) -> Bool {
        dedicatedSemanticJobIDs.contains(
            ProductionIdentifierNormalizerV1.canonical(semanticJobID)
        )
    }

    public static func genericDemandIDs(
        _ demands: [ReferenceDemandV1]
    ) -> [String] {
        demands.filter {
            !isDedicated(semanticJobID: $0.semanticJobID)
        }.map(\.id)
    }
}

public enum ProductionRequirementResolverV1 {
    public static func fingerprints(
        requirement: ProductionRequirementV1,
        candidate: ProductionRouteCandidateV1
    ) throws -> ProductionRouteFingerprintsV1 {
        let requirementSHA256 = FileDigest.sha256(
            of: try ReferencePlanCanonicalCodecV2.encode(requirement)
        )
        let capabilitiesSHA256 = FileDigest.sha256(
            of: try ReferencePlanCanonicalCodecV2.encode(
                ProductionRouteCapabilitySnapshotV1(candidate: candidate)
            )
        )
        let routeSHA256 = FileDigest.sha256(
            of: try ReferencePlanCanonicalCodecV2.encode(RouteFingerprintSource(
                offering: candidate.capabilities.offering,
                requirementSHA256: requirementSHA256,
                capabilitiesSHA256: capabilitiesSHA256
            ))
        )
        return ProductionRouteFingerprintsV1(
            requirementSHA256: requirementSHA256,
            capabilitiesSHA256: capabilitiesSHA256,
            routeSHA256: routeSHA256
        )
    }

    public static func resolve(
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1,
        assetGraph: AssetGraphV1,
        dataRoot: URL,
        candidates: [ProductionRouteCandidateV1]
    ) throws -> ProductionRouteResolutionV1 {
        try AssetGraphValidatorV1.validate(demandSet, against: assetGraph)
        try AssetGraphValidatorV1.validateProjectFiles(assetGraph, dataRoot: dataRoot)
        try validateBindings(requirement, demandSet: demandSet)
        let routeableCandidates = candidates.filter(isValid)
        let rejectedMalformedCandidate = routeableCandidates.count != candidates.count
        let requirementSHA256 = FileDigest.sha256(
            of: try ReferencePlanCanonicalCodecV2.encode(requirement)
        )
        let evaluations = routeableCandidates.map {
            ProductionRouteEvaluationV1(
                candidate: $0,
                deficits: deficits(
                    requirement: requirement,
                    demandSet: demandSet,
                    assetGraph: assetGraph,
                    candidate: $0
                )
            )
        }
        let matches = evaluations.filter(\.deficits.isEmpty)
            .map(\.candidate)
            .sorted(by: rankedBefore)
        guard let selected = matches.first else {
            return .noMatch(ProductionRouteNoMatchV1(
                requirementSHA256: requirementSHA256,
                evaluations: evaluations,
                recoveryActions: recoveryActions(
                    for: evaluations,
                    rejectedMalformedCandidate: rejectedMalformedCandidate
                )
            ))
        }
        let route = try route(
            requirement: requirement,
            demandSet: demandSet,
            assetGraph: assetGraph,
            candidate: selected
        )
        return .matched(
            route: route,
            candidate: selected
        )
    }

    public static func matchingRoutes(
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1,
        assetGraph: AssetGraphV1,
        dataRoot: URL,
        candidates: [ProductionRouteCandidateV1]
    ) throws -> [ProductionRouteMatchV1] {
        try AssetGraphValidatorV1.validate(demandSet, against: assetGraph)
        try AssetGraphValidatorV1.validateProjectFiles(assetGraph, dataRoot: dataRoot)
        try validateBindings(requirement, demandSet: demandSet)
        return try candidates
            .filter(isValid)
            .filter {
                deficits(
                    requirement: requirement,
                    demandSet: demandSet,
                    assetGraph: assetGraph,
                    candidate: $0
                ).isEmpty
            }
            .sorted(by: rankedBefore)
            .map {
                ProductionRouteMatchV1(
                    route: try route(
                        requirement: requirement,
                        demandSet: demandSet,
                        assetGraph: assetGraph,
                        candidate: $0
                    ),
                    candidate: $0
                )
            }
    }

    public static func revalidate(
        _ route: ProductionRouteV1,
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1,
        assetGraph: AssetGraphV1,
        dataRoot: URL,
        candidate: ProductionRouteCandidateV1
    ) throws -> Bool {
        let resolution = try resolve(
            requirement: requirement,
            demandSet: demandSet,
            assetGraph: assetGraph,
            dataRoot: dataRoot,
            candidates: [candidate]
        )
        guard case .matched(let current, _) = resolution else { return false }
        return current.requirementSHA256 == route.requirementSHA256
            && current.capabilitiesSHA256 == route.capabilitiesSHA256
            && current.routeSHA256 == route.routeSHA256
            && current.offering == route.offering
            && current.schema == route.schema
            && current.id == route.id
            && current.projectID == route.projectID
            && current.shotID == route.shotID
            && current.capabilitySnapshot == route.capabilitySnapshot
    }

    public static func validateBindings(
        _ requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1
    ) throws {
        guard CapabilityModalityV1(rawValue: requirement.modalityID) != nil else {
            throw ProductionRequirementResolverErrorV1.invalidRequirement("modality_id")
        }
        let genericDemandIDs = ProductionReferenceDemandSemanticsV1.genericDemandIDs(
            demandSet.demands
        )
        guard !requirement.modeIDs.isEmpty,
              requirement.modeIDs.allSatisfy(nonEmpty),
              Set(requirement.modeIDs.map(
                  ProductionIdentifierNormalizerV1.canonical
              )).count == requirement.modeIDs.count,
              requirement.visibleEntityCount >= 0,
              Set(requirement.referenceDemandIDs).count
                == requirement.referenceDemandIDs.count,
              Set(requirement.referenceDemandIDs) == Set(genericDemandIDs),
              requirement.maximumCost.map({ $0.isFinite && $0 >= 0 }) ?? true,
              requirement.maximumLatencySeconds.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw ProductionRequirementResolverErrorV1.invalidRequirement("structure")
        }
        let requiredAssetIDs = Set(
            demandSet.demands.filter(\.isRequired).map(\.assetID)
        )
        guard Set(requirement.identityLockAssetIDs).isSubset(of: requiredAssetIDs) else {
            throw ProductionRequirementResolverErrorV1.invalidRequirement("identity_lock_jobs")
        }
        let requiredModes = Set(requirement.modeIDs.map(
            ProductionIdentifierNormalizerV1.canonical
        ))
        guard demandSet.demands.allSatisfy({
            requiredModes.contains(ProductionIdentifierNormalizerV1.canonical($0.modeID))
        }) else {
            throw ProductionRequirementResolverErrorV1.invalidRequirement("demand_mode")
        }
        let firstFrameDemands = demandSet.demands.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.firstFrame
            ) || ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }
        guard firstFrameDemands.count == (requirement.requiresFirstFrame ? 1 : 0),
              firstFrameDemands.allSatisfy(\.isRequired) else {
            throw ProductionRequirementResolverErrorV1.invalidRequirement("first_frame_job")
        }
        let lastFrameDemands = demandSet.demands.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.lastFrame
            )
        }
        guard lastFrameDemands.count == (requirement.requiresLastFrame ? 1 : 0),
              lastFrameDemands.allSatisfy(\.isRequired) else {
            throw ProductionRequirementResolverErrorV1.invalidRequirement("last_frame_job")
        }
        let sourceVideoDemands = demandSet.demands.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.sourceVideo
            )
        }
        guard sourceVideoDemands.count == (requirement.sourceVideoAssetID == nil ? 0 : 1),
              sourceVideoDemands.allSatisfy(\.isRequired) else {
            throw ProductionRequirementResolverErrorV1.invalidRequirement("source_video_job")
        }
        if let sourceVideoAssetID = requirement.sourceVideoAssetID,
           sourceVideoDemands.first?.assetID != sourceVideoAssetID {
            throw ProductionRequirementResolverErrorV1.invalidRequirement("source_video_asset_job")
        }
        if firstFrameDemands.contains(where: {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.predecessorLastFrame
            )
        }),
           !requirement.requiresFirstFrame {
            throw ProductionRequirementResolverErrorV1.invalidRequirement(
                "predecessor_first_frame_requirement"
            )
        }
        let audioTimingDemands = demandSet.demands.filter {
            ProductionIdentifierNormalizerV1.matches(
                $0.semanticJobID,
                CoreReferenceSemanticJobIDV1.audioTiming
            )
        }
        guard audioTimingDemands.allSatisfy(\.isRequired) else {
            throw ProductionRequirementResolverErrorV1.invalidRequirement("audio_timing_job")
        }
    }

    private static func validate(_ candidate: ProductionRouteCandidateV1) throws {
        let inputSlotIDs = candidate.inputSlots.map(\.id)
        guard candidate.qualityScore.isFinite,
              candidate.preferenceScore.isFinite,
              candidate.estimatedCost.map({ $0.isFinite && $0 >= 0 }) ?? true,
              candidate.estimatedLatencySeconds.map({ $0.isFinite && $0 > 0 }) ?? true,
              candidate.qualityTargetIDs.allSatisfy(nonEmpty),
              candidate.satisfiedProductionProfileRequirementIDs.allSatisfy(nonEmpty),
              Set(candidate.qualityTargetIDs).count == candidate.qualityTargetIDs.count,
              Set(candidate.satisfiedProductionProfileRequirementIDs).count
                == candidate.satisfiedProductionProfileRequirementIDs.count,
              Set(inputSlotIDs).count == inputSlotIDs.count,
              candidate.inputSlots.allSatisfy({
                  isNamespaced($0.id)
                      && $0.requestOrder >= 0
                      && !$0.modeIDs.isEmpty
                      && $0.modeIDs.allSatisfy(nonEmpty)
                      && Set($0.modeIDs.map(
                          ProductionIdentifierNormalizerV1.canonical
                      )).count == $0.modeIDs.count
              }) else {
            throw ProductionRequirementResolverErrorV1.invalidCandidate(
                candidate.capabilities.offering.offeringID
            )
        }
    }

    private static func isValid(_ candidate: ProductionRouteCandidateV1) -> Bool {
        do {
            try validate(candidate)
            return true
        } catch {
            return false
        }
    }

    private static func deficits(
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1,
        assetGraph: AssetGraphV1,
        candidate: ProductionRouteCandidateV1
    ) -> [ProductionRouteDeficitV1] {
        var result: [ProductionRouteDeficitV1] = []
        let profile = candidate.capabilities.effective
        let offering = candidate.capabilities.offering
        if !candidate.providerActivated {
            result.append(ProductionRouteDeficitV1(
                code: .providerNotActivated,
                requiredValue: offering.providerID,
                availableValue: "inactive"
            ))
        }
        if !candidate.liveAvailable {
            result.append(ProductionRouteDeficitV1(
                code: .offerUnavailable,
                requiredValue: offering.offeringID,
                availableValue: "unavailable"
            ))
        }
        guard offering.modality.rawValue == requirement.modalityID else {
            result.append(ProductionRouteDeficitV1(
                code: .modalityUnsupported,
                requiredValue: requirement.modalityID,
                availableValue: offering.modality.rawValue
            ))
            return result
        }

        let requiredModes = Set(requirement.modeIDs.map(
            ProductionIdentifierNormalizerV1.canonical
        ))
        let supportedModes = Set(strings(profile, CapabilityFieldIDV1.modes).map(
            ProductionIdentifierNormalizerV1.canonical
        ))
        for mode in requiredModes.subtracting(supportedModes).sorted() {
            result.append(deficit(
                .modeUnsupported,
                field: CapabilityFieldIDV1.modes,
                required: mode,
                available: supportedModes.sorted().joined(separator: ","),
                profile: profile
            ))
        }
        for (mode, field) in requiredModes.compactMap({
            modeCapabilityField($0, modality: offering.modality)
        }) {
            if !boolean(profile, field) {
                result.append(deficit(
                    .modeUnsupported,
                    field: field,
                    required: mode,
                    available: "false",
                    profile: profile
                ))
            }
        }
        let visibleField = offering.modality == .image
            ? CapabilityFieldIDV1.imageVisibleCharacters
            : CapabilityFieldIDV1.visibleCharacters
        if requirement.visibleEntityCount > integer(profile, visibleField) {
            result.append(deficit(
                .visibleEntityCapacity,
                field: visibleField,
                required: String(requirement.visibleEntityCount),
                available: String(integer(profile, visibleField)),
                profile: profile
            ))
        }
        if offering.modality == .image,
           !requirement.identityLockAssetIDs.isEmpty,
           !boolean(profile, CapabilityFieldIDV1.imageIdentity) {
            result.append(deficit(
                .modeUnsupported,
                field: CapabilityFieldIDV1.imageIdentity,
                required: "identity-lock",
                available: "false",
                profile: profile
            ))
        }

        let assets = Dictionary(uniqueKeysWithValues: assetGraph.assets.map { ($0.id, $0) })
        let requiredDemands = demandSet.demands.filter(\.isRequired)
        let inputSlots = Dictionary(
            uniqueKeysWithValues: candidate.inputSlots.map { ($0.id, $0) }
        )
        for demand in requiredDemands {
            guard let slot = inputSlots[demand.inputSlotID],
                  slot.modality == demand.modality,
                  Set(slot.modeIDs.map(ProductionIdentifierNormalizerV1.canonical)).contains(
                      ProductionIdentifierNormalizerV1.canonical(demand.modeID)
                  ) else {
                result.append(ProductionRouteDeficitV1(
                    code: .inputSlotUnsupported,
                    requiredValue: "\(demand.inputSlotID):\(demand.modality.rawValue):\(demand.modeID)",
                    availableValue: candidate.inputSlots.map(\.id).sorted()
                        .joined(separator: ",")
                ))
                continue
            }
        }
        let modalityBudgetedDemands = requiredDemands.filter {
            inputSlots[$0.inputSlotID]?.countsTowardModalityBudget == true
        }
        let totalBudgetedDemands = requiredDemands.filter {
            inputSlots[$0.inputSlotID]?.countsTowardTotalBudget == true
        }
        let durationBudgetedDemands = requiredDemands.filter {
            inputSlots[$0.inputSlotID]?.countsTowardCombinedDuration == true
        }
        validateInputKinds(
            demands: requiredDemands,
            profile: profile,
            into: &result
        )
        let counts = Dictionary(grouping: modalityBudgetedDemands, by: \.modality)
            .mapValues(\.count)
        for modality in AssetPhysicalModalityV1.allCases {
            let count = counts[modality] ?? 0
            let capacity = referenceCapacity(
                modality: modality,
                profile: profile,
                offeringModality: offering.modality
            )
            if count > capacity.value {
                result.append(deficit(
                    .referenceCapacity,
                    field: capacity.field,
                    required: String(count),
                    available: String(capacity.value),
                    profile: profile
                ))
            }
        }
        let totalCapacity = offering.modality == .video
            ? integer(profile, CapabilityFieldIDV1.totalReferences)
            : referenceCapacity(
                modality: .image,
                profile: profile,
                offeringModality: offering.modality
            ).value + referenceCapacity(
                modality: .audio,
                profile: profile,
                offeringModality: offering.modality
            ).value
        if totalBudgetedDemands.count > totalCapacity {
            let field = offering.modality == .video
                ? CapabilityFieldIDV1.totalReferences
                : referenceCapacity(
                    modality: .image,
                    profile: profile,
                    offeringModality: offering.modality
                ).field
            result.append(deficit(
                .referenceCapacity,
                field: field,
                required: String(totalBudgetedDemands.count),
                available: String(totalCapacity),
                profile: profile
            ))
        }
        checkCombinedDuration(
            demands: durationBudgetedDemands.filter { $0.modality == .video },
            assets: assets,
            field: CapabilityFieldIDV1.combinedVideoReferenceSeconds,
            profile: profile,
            into: &result
        )
        checkCombinedDuration(
            demands: durationBudgetedDemands.filter { $0.modality == .audio },
            assets: assets,
            field: CapabilityFieldIDV1.combinedAudioReferenceSeconds,
            profile: profile,
            into: &result
        )

        if requirement.requiresFirstFrame,
           !boolean(profile, CapabilityFieldIDV1.firstFrame) {
            result.append(deficit(
                .firstFrameUnsupported,
                field: CapabilityFieldIDV1.firstFrame,
                required: "true",
                available: "false",
                profile: profile
            ))
        }
        if requirement.requiresLastFrame,
           !boolean(profile, CapabilityFieldIDV1.lastFrame) {
            result.append(deficit(
                .lastFrameUnsupported,
                field: CapabilityFieldIDV1.lastFrame,
                required: "true",
                available: "false",
                profile: profile
            ))
        }
        if requirement.sourceVideoAssetID != nil,
           !boolean(profile, CapabilityFieldIDV1.sourceVideo) {
            result.append(deficit(
                .sourceVideoUnsupported,
                field: CapabilityFieldIDV1.sourceVideo,
                required: "true",
                available: "false",
                profile: profile
            ))
        }
        if let duration = requirement.duration,
           !supports(duration: duration, modality: offering.modality, profile: profile) {
            result.append(ProductionRouteDeficitV1(
                code: .durationUnsupported,
                requiredValue: durationDescription(duration),
                availableValue: durationDescription(profile, modality: offering.modality)
            ))
        }
        if let resolution = requirement.resolution,
           !Set(strings(profile, CapabilityFieldIDV1.resolutions).map(
               ProductionIdentifierNormalizerV1.canonical
           )).contains(ProductionIdentifierNormalizerV1.canonical(resolution)) {
            result.append(deficit(
                .resolutionUnsupported,
                field: CapabilityFieldIDV1.resolutions,
                required: resolution,
                available: strings(profile, CapabilityFieldIDV1.resolutions)
                    .joined(separator: ","),
                profile: profile
            ))
        }
        if let aspectRatio = requirement.aspectRatio,
           !Set(strings(profile, CapabilityFieldIDV1.aspectRatios).map(
               ProductionIdentifierNormalizerV1.canonical
           )).contains(ProductionIdentifierNormalizerV1.canonical(aspectRatio)) {
            result.append(deficit(
                .aspectRatioUnsupported,
                field: CapabilityFieldIDV1.aspectRatios,
                required: aspectRatio,
                available: strings(profile, CapabilityFieldIDV1.aspectRatios)
                    .joined(separator: ","),
                profile: profile
            ))
        }
        if requirement.requiresOutputAudio,
           offering.modality == .video,
           !boolean(profile, CapabilityFieldIDV1.nativeAudio) {
            result.append(deficit(
                .outputAudioUnsupported,
                field: CapabilityFieldIDV1.nativeAudio,
                required: "true",
                available: "false",
                profile: profile
            ))
        }
        if let quality = requirement.qualityTarget,
           !Set(candidate.qualityTargetIDs.map(
               ProductionIdentifierNormalizerV1.canonical
           )).contains(ProductionIdentifierNormalizerV1.canonical(quality)) {
            result.append(ProductionRouteDeficitV1(
                code: .qualityUnsupported,
                requiredValue: quality,
                availableValue: candidate.qualityTargetIDs.joined(separator: ",")
            ))
        }
        let missingProfileRequirements = Set(requirement.productionProfileRequirementIDs)
            .subtracting(candidate.satisfiedProductionProfileRequirementIDs)
        for requirementID in missingProfileRequirements.sorted() {
            result.append(ProductionRouteDeficitV1(
                code: .productionProfileRequirementUnsupported,
                requiredValue: requirementID,
                availableValue: candidate.satisfiedProductionProfileRequirementIDs
                    .sorted().joined(separator: ",")
            ))
        }
        if let maximumCost = requirement.maximumCost {
            if let cost = candidate.estimatedCost {
                if cost > maximumCost {
                    result.append(ProductionRouteDeficitV1(
                        code: .costExceeded,
                        requiredValue: "<=\(maximumCost)",
                        availableValue: String(cost)
                    ))
                }
            } else {
                result.append(ProductionRouteDeficitV1(
                    code: .costUnknown,
                    requiredValue: "<=\(maximumCost)",
                    availableValue: nil
                ))
            }
        }
        if let maximumLatency = requirement.maximumLatencySeconds {
            if let latency = candidate.estimatedLatencySeconds {
                if latency > maximumLatency {
                    result.append(ProductionRouteDeficitV1(
                        code: .latencyExceeded,
                        requiredValue: "<=\(maximumLatency)",
                        availableValue: String(latency)
                    ))
                }
            } else {
                result.append(ProductionRouteDeficitV1(
                    code: .latencyUnknown,
                    requiredValue: "<=\(maximumLatency)",
                    availableValue: nil
                ))
            }
        }
        return result
    }

    private static func referenceCapacity(
        modality: AssetPhysicalModalityV1,
        profile: ResolvedCapabilityProfileV1,
        offeringModality: CapabilityModalityV1
    ) -> (field: String, value: Int) {
        if offeringModality == .video {
            let field: String = switch modality {
            case .image: CapabilityFieldIDV1.referenceImages
            case .video: CapabilityFieldIDV1.referenceVideos
            case .audio: CapabilityFieldIDV1.referenceAudios
            case .geometry: "video.reference_geometry"
            }
            return (field, integer(profile, field))
        }
        if offeringModality == .image, modality == .image {
            return (
                CapabilityFieldIDV1.imageReferences,
                integer(profile, CapabilityFieldIDV1.imageReferences)
            )
        }
        if (offeringModality == .audio || offeringModality == .music), modality == .audio {
            return (
                CapabilityFieldIDV1.audioReference,
                boolean(profile, CapabilityFieldIDV1.audioReference) ? 1 : 0
            )
        }
        return ("common.unsupported_reference_modality", 0)
    }

    private static func supports(
        duration: RequestedDurationV1,
        modality: CapabilityModalityV1,
        profile: ResolvedCapabilityProfileV1
    ) -> Bool {
        guard modality == .video || modality == .audio || modality == .music else {
            return false
        }
        let minimumField = modality == .video
            ? CapabilityFieldIDV1.durationMinimum
            : CapabilityFieldIDV1.audioDurationMinimum
        let maximumField = modality == .video
            ? CapabilityFieldIDV1.durationMaximum
            : CapabilityFieldIDV1.audioDurationMaximum
        let routeMinimum = decimal(profile, minimumField)
        let routeMaximum = decimal(profile, maximumField)
        if duration.allowsAutomatic,
           modality == .video,
           boolean(profile, CapabilityFieldIDV1.durationAutomatic) {
            return true
        }
        let values = modality == .video
            ? profile.fields.integerLists[CapabilityFieldIDV1.durationValues]?.value.map(Double.init)
                ?? []
            : []
        if let preferred = duration.preferredSeconds {
            if !values.isEmpty { return values.contains(preferred) }
            return preferred >= routeMinimum && preferred <= routeMaximum
        }
        let requestedMinimum = duration.minimumSeconds ?? 0
        let requestedMaximum = duration.maximumSeconds ?? Double.greatestFiniteMagnitude
        if !values.isEmpty {
            return values.contains { $0 >= requestedMinimum && $0 <= requestedMaximum }
        }
        return Swift.max(routeMinimum, requestedMinimum)
            <= Swift.min(routeMaximum, requestedMaximum)
    }

    private static func checkCombinedDuration(
        demands: [ReferenceDemandV1],
        assets: [String: AssetGraphNodeV1],
        field: String,
        profile: ResolvedCapabilityProfileV1,
        into result: inout [ProductionRouteDeficitV1]
    ) {
        guard !demands.isEmpty,
              profile.fields.decimals[field] != nil else { return }
        let durations = demands.map { duration($0, assets: assets) }
        guard durations.allSatisfy({ $0 != nil }) else {
            result.append(deficit(
                .referenceDurationUnknown,
                field: field,
                required: "known-duration-per-reference",
                available: "unknown",
                profile: profile
            ))
            return
        }
        let required = durations.compactMap { $0 }.reduce(0, +)
        let available = decimal(profile, field)
        if required > available {
            result.append(deficit(
                .referenceDuration,
                field: field,
                required: String(required),
                available: String(available),
                profile: profile
            ))
        }
    }

    private static func validateInputKinds(
        demands: [ReferenceDemandV1],
        profile: ResolvedCapabilityProfileV1,
        into result: inout [ProductionRouteDeficitV1]
    ) {
        guard let declared = profile.fields.strings[CapabilityFieldIDV1.inputKinds]?.value,
              !declared.isEmpty else { return }
        let supported = Set(declared.map(ProductionIdentifierNormalizerV1.canonical))
        for modality in Set(demands.map(\.modality)).sorted(by: {
            $0.rawValue < $1.rawValue
        }) where !supported.contains(
            ProductionIdentifierNormalizerV1.canonical(modality.rawValue)
        ) {
            result.append(deficit(
                .inputSlotUnsupported,
                field: CapabilityFieldIDV1.inputKinds,
                required: modality.rawValue,
                available: supported.sorted().joined(separator: ","),
                profile: profile
            ))
        }
    }

    private static func rankedBefore(
        _ lhs: ProductionRouteCandidateV1,
        _ rhs: ProductionRouteCandidateV1
    ) -> Bool {
        if lhs.qualityScore != rhs.qualityScore { return lhs.qualityScore > rhs.qualityScore }
        if lhs.preferenceScore != rhs.preferenceScore {
            return lhs.preferenceScore > rhs.preferenceScore
        }
        if ordered(lhs.estimatedCost, before: rhs.estimatedCost) != nil {
            return ordered(lhs.estimatedCost, before: rhs.estimatedCost)!
        }
        if ordered(lhs.estimatedLatencySeconds, before: rhs.estimatedLatencySeconds) != nil {
            return ordered(lhs.estimatedLatencySeconds, before: rhs.estimatedLatencySeconds)!
        }
        let left = lhs.capabilities.offering
        let right = rhs.capabilities.offering
        return [left.providerID, left.offeringID, left.endpointID]
            .lexicographicallyPrecedes([right.providerID, right.offeringID, right.endpointID])
    }

    private static func route(
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1,
        assetGraph: AssetGraphV1,
        candidate: ProductionRouteCandidateV1
    ) throws -> ProductionRouteV1 {
        let fingerprints = try fingerprints(
            requirement: requirement,
            candidate: candidate
        )
        return ProductionRouteV1(
            id: "route-\(demandSet.shotID)",
            projectID: assetGraph.projectID,
            shotID: demandSet.shotID,
            offering: candidate.capabilities.offering,
            capabilitySnapshot: ProductionRouteCapabilitySnapshotV1(
                candidate: candidate
            ),
            requirementSHA256: fingerprints.requirementSHA256,
            capabilitiesSHA256: fingerprints.capabilitiesSHA256,
            routeSHA256: fingerprints.routeSHA256,
            researchNeeded: candidate.capabilities.effective.researchNeeded,
            qualityScore: candidate.qualityScore,
            preferenceScore: candidate.preferenceScore,
            estimatedCost: candidate.estimatedCost,
            estimatedLatencySeconds: candidate.estimatedLatencySeconds
        )
    }

    private static func ordered(_ lhs: Double?, before rhs: Double?) -> Bool? {
        if lhs == rhs { return nil }
        switch (lhs, rhs) {
        case (.some(let left), .some(let right)): return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return nil
        }
    }

    private static func recoveryActions(
        for evaluations: [ProductionRouteEvaluationV1],
        rejectedMalformedCandidate: Bool = false
    ) -> [ProductionRouteRecoveryActionV1] {
        let codes = Set(evaluations.flatMap(\.deficits).map(\.code))
        var actions: [ProductionRouteRecoveryActionV1] = []
        if evaluations.isEmpty
            || codes.contains(.providerNotActivated)
            || codes.contains(.offerUnavailable) {
            actions.append(.activateProviderOrModel)
        }
        if rejectedMalformedCandidate
            || evaluations.contains(where: {
                $0.candidate.capabilities.effective.researchNeeded
            }) {
            actions.append(.researchCapabilities)
        }
        if codes.contains(.visibleEntityCapacity) || codes.contains(.durationUnsupported) {
            actions.append(.splitShot)
            actions.append(.useRescueCut)
        }
        if codes.contains(.referenceCapacity)
            || codes.contains(.referenceDuration)
            || codes.contains(.referenceDurationUnknown)
            || codes.contains(.inputSlotUnsupported) {
            actions.append(.reviseReferencePlan)
        }
        actions.append(.editRequirements)
        return actions
    }

    private static func deficit(
        _ code: ProductionRouteDeficitCodeV1,
        field: String,
        required: String,
        available: String,
        profile: ResolvedCapabilityProfileV1
    ) -> ProductionRouteDeficitV1 {
        ProductionRouteDeficitV1(
            code: code,
            capabilityFieldID: field,
            requiredValue: required,
            availableValue: available,
            origin: origin(profile, field)
        )
    }

    private static func integer(_ profile: ResolvedCapabilityProfileV1, _ field: String) -> Int {
        profile.fields.integers[field]?.value ?? 0
    }

    private static func decimal(_ profile: ResolvedCapabilityProfileV1, _ field: String) -> Double {
        profile.fields.decimals[field]?.value ?? 0
    }

    private static func boolean(_ profile: ResolvedCapabilityProfileV1, _ field: String) -> Bool {
        profile.fields.booleans[field]?.value ?? false
    }

    private static func strings(
        _ profile: ResolvedCapabilityProfileV1,
        _ field: String
    ) -> [String] {
        profile.fields.strings[field]?.value ?? []
    }

    private static func origin(
        _ profile: ResolvedCapabilityProfileV1,
        _ field: String
    ) -> ResolvedCapabilityOriginV1? {
        profile.fields.integers[field]?.origin
            ?? profile.fields.decimals[field]?.origin
            ?? profile.fields.booleans[field]?.origin
            ?? profile.fields.strings[field]?.origin
            ?? profile.fields.integerLists[field]?.origin
    }

    private static func duration(
        _ demand: ReferenceDemandV1,
        assets: [String: AssetGraphNodeV1]
    ) -> Double? {
        assets[demand.assetID]?.durationSeconds
    }

    private static func durationDescription(_ duration: RequestedDurationV1) -> String {
        [
            duration.preferredSeconds.map { "preferred=\($0)" },
            duration.minimumSeconds.map { "min=\($0)" },
            duration.maximumSeconds.map { "max=\($0)" },
            duration.allowsAutomatic ? "automatic=true" : nil,
        ].compactMap { $0 }.joined(separator: ",")
    }

    private static func durationDescription(
        _ profile: ResolvedCapabilityProfileV1,
        modality: CapabilityModalityV1
    ) -> String {
        let minimum = modality == .video
            ? CapabilityFieldIDV1.durationMinimum
            : CapabilityFieldIDV1.audioDurationMinimum
        let maximum = modality == .video
            ? CapabilityFieldIDV1.durationMaximum
            : CapabilityFieldIDV1.audioDurationMaximum
        return "min=\(decimal(profile, minimum)),max=\(decimal(profile, maximum))"
    }

    private static func modeCapabilityField(
        _ mode: String,
        modality: CapabilityModalityV1
    ) -> (String, String)? {
        switch mode {
        case "edit", "video-edit", "image-edit":
            return (
                mode,
                mode == "image-edit" || (mode == "edit" && modality == .image)
                    ? CapabilityFieldIDV1.imageEdit
                    : CapabilityFieldIDV1.edit
            )
        case "extend", "video-extend":
            return (mode, CapabilityFieldIDV1.extend)
        case "inpaint", "image-inpaint":
            return (mode, CapabilityFieldIDV1.imageInpaint)
        case "outpaint", "image-outpaint":
            return (mode, CapabilityFieldIDV1.imageOutpaint)
        default:
            return nil
        }
    }

    private static func nonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isNamespaced(_ value: String) -> Bool {
        let pattern = #"^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private struct RouteFingerprintSource: Codable {
        let offering: CapabilityOfferingIdentityV1
        let requirementSHA256: String
        let capabilitiesSHA256: String

        private enum CodingKeys: String, CodingKey {
            case offering
            case requirementSHA256 = "requirement_sha256"
            case capabilitiesSHA256 = "capabilities_sha256"
        }
    }
}
