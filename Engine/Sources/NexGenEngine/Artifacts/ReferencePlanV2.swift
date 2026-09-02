import Foundation

public let referencePlanV2Schema = "reference-plan/v2"

public struct ReferencePlanRouteBindingV2: Codable, Sendable, Equatable {
    public let offering: CapabilityOfferingIdentityV1
    public let requirementSHA256: String
    public let capabilitiesSHA256: String
    public let routeSHA256: String

    private enum CodingKeys: String, CodingKey {
        case offering
        case requirementSHA256 = "requirement_sha256"
        case capabilitiesSHA256 = "capabilities_sha256"
        case routeSHA256 = "route_sha256"
    }

    public init(
        offering: CapabilityOfferingIdentityV1,
        requirementSHA256: String,
        capabilitiesSHA256: String,
        routeSHA256: String
    ) {
        self.offering = offering
        self.requirementSHA256 = requirementSHA256
        self.capabilitiesSHA256 = capabilitiesSHA256
        self.routeSHA256 = routeSHA256
    }
}

public struct ReferencePlanBudgetV2: Codable, Sendable, Equatable {
    public let imageCount: Int
    public let videoCount: Int
    public let audioCount: Int
    public let geometryCount: Int
    public let totalCount: Int
    public let combinedVideoSeconds: Double?
    public let combinedAudioSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case imageCount = "image_count"
        case videoCount = "video_count"
        case audioCount = "audio_count"
        case geometryCount = "geometry_count"
        case totalCount = "total_count"
        case combinedVideoSeconds = "combined_video_seconds"
        case combinedAudioSeconds = "combined_audio_seconds"
    }

    public init(
        imageCount: Int,
        videoCount: Int,
        audioCount: Int,
        geometryCount: Int,
        totalCount: Int,
        combinedVideoSeconds: Double? = nil,
        combinedAudioSeconds: Double? = nil
    ) {
        self.imageCount = imageCount
        self.videoCount = videoCount
        self.audioCount = audioCount
        self.geometryCount = geometryCount
        self.totalCount = totalCount
        self.combinedVideoSeconds = combinedVideoSeconds
        self.combinedAudioSeconds = combinedAudioSeconds
    }
}

public struct ReferenceBindingV2: Codable, Sendable, Equatable {
    public let demandID: String
    public let assetID: String
    public let assetVersion: Int
    public let path: String
    public let sha256: String
    public let modality: AssetPhysicalModalityV1
    public let semanticJobID: String
    public let isRequired: Bool
    public let priority: Int
    public let preservationScopeIDs: [String]
    public let exclusionDemandIDs: [String]
    public let inputSlotID: String
    public let modeID: String
    public let durationSeconds: Double?
    public let expectedSourceShotID: String?

    private enum CodingKeys: String, CodingKey {
        case demandID = "demand_id"
        case assetID = "asset_id"
        case assetVersion = "asset_version"
        case path
        case sha256
        case modality
        case semanticJobID = "semantic_job_id"
        case isRequired = "is_required"
        case priority
        case preservationScopeIDs = "preservation_scope_ids"
        case exclusionDemandIDs = "exclusion_demand_ids"
        case inputSlotID = "input_slot_id"
        case modeID = "mode_id"
        case durationSeconds = "duration_seconds"
        case expectedSourceShotID = "expected_source_shot_id"
    }

    public init(demand: ReferenceDemandV1, asset: AssetGraphNodeV1) {
        demandID = demand.id
        assetID = asset.id
        assetVersion = asset.version
        path = asset.path
        sha256 = asset.sha256
        modality = demand.modality
        semanticJobID = demand.semanticJobID
        isRequired = demand.isRequired
        priority = demand.priority
        preservationScopeIDs = demand.preservationScopeIDs
        exclusionDemandIDs = demand.exclusionDemandIDs
        inputSlotID = demand.inputSlotID
        modeID = demand.modeID
        durationSeconds = asset.durationSeconds
        expectedSourceShotID = demand.expectedSourceShotID
    }
}

public enum ReferencePlanDropReasonV2: String, Codable, Sendable, Equatable {
    case inputSlotUnsupported = "input_slot_unsupported"
    case modalityBudget = "modality_budget"
    case totalBudget = "total_budget"
    case combinedDuration = "combined_duration"
    case mutuallyExclusive = "mutually_exclusive"
}

public struct ReferencePlanDropV2: Codable, Sendable, Equatable {
    public let demandID: String
    public let reason: ReferencePlanDropReasonV2
    public let detail: String

    private enum CodingKeys: String, CodingKey {
        case demandID = "demand_id"
        case reason
        case detail
    }

    public init(demandID: String, reason: ReferencePlanDropReasonV2, detail: String) {
        self.demandID = demandID
        self.reason = reason
        self.detail = detail
    }
}

public struct ReferencePlanV2: Codable, Sendable, Equatable {
    public static let artifactRole = "core.reference-plan"

    public let schema: String
    public let id: String
    public let projectID: String
    public let shotID: String
    public let demandSet: CanonicalArtifactReferenceV1
    public let route: ReferencePlanRouteBindingV2
    public let budget: ReferencePlanBudgetV2
    public let bindings: [ReferenceBindingV2]
    public let optionalDrops: [ReferencePlanDropV2]

    private enum CodingKeys: String, CodingKey {
        case schema
        case id
        case projectID = "project_id"
        case shotID = "shot_id"
        case demandSet = "demand_set"
        case route
        case budget
        case bindings
        case optionalDrops = "optional_drops"
    }

    public init(
        schema: String = referencePlanV2Schema,
        id: String,
        projectID: String,
        shotID: String,
        demandSet: CanonicalArtifactReferenceV1,
        route: ReferencePlanRouteBindingV2,
        budget: ReferencePlanBudgetV2,
        bindings: [ReferenceBindingV2],
        optionalDrops: [ReferencePlanDropV2]
    ) {
        self.schema = schema
        self.id = id
        self.projectID = projectID
        self.shotID = shotID
        self.demandSet = demandSet
        self.route = route
        self.budget = budget
        self.bindings = bindings
        self.optionalDrops = optionalDrops
    }
}

public enum ReferencePlanDeficitCodeV2: String, Codable, Sendable, Equatable {
    case unknownDemand = "unknown_demand"
    case missingDemand = "missing_demand"
    case modalityBudget = "modality_budget"
    case totalBudget = "total_budget"
    case combinedDuration = "combined_duration"
    case unknownDuration = "unknown_duration"
    case inputSlotUnsupported = "input_slot_unsupported"
    case mutuallyExclusive = "mutually_exclusive"
}

public struct ReferencePlanDeficitV2: Codable, Sendable, Equatable {
    public let demandID: String?
    public let code: ReferencePlanDeficitCodeV2
    public let scopeID: String
    public let requiredValue: Double?
    public let availableValue: Double?

    private enum CodingKeys: String, CodingKey {
        case demandID = "demand_id"
        case code
        case scopeID = "scope_id"
        case requiredValue = "required_value"
        case availableValue = "available_value"
    }

    public init(
        demandID: String?,
        code: ReferencePlanDeficitCodeV2,
        scopeID: String,
        requiredValue: Double? = nil,
        availableValue: Double? = nil
    ) {
        self.demandID = demandID
        self.code = code
        self.scopeID = scopeID
        self.requiredValue = requiredValue
        self.availableValue = availableValue
    }
}

public struct ReferencePlanFailureV2: Codable, Sendable, Equatable {
    public let offering: CapabilityOfferingIdentityV1
    public let requirementSHA256: String
    public let capabilitiesSHA256: String
    public let deficits: [ReferencePlanDeficitV2]

    public init(
        offering: CapabilityOfferingIdentityV1,
        requirementSHA256: String,
        capabilitiesSHA256: String,
        deficits: [ReferencePlanDeficitV2]
    ) {
        self.offering = offering
        self.requirementSHA256 = requirementSHA256
        self.capabilitiesSHA256 = capabilitiesSHA256
        self.deficits = deficits
    }
}

public enum ReferencePlanBuildResultV2: Sendable, Equatable {
    case plan(ReferencePlanV2)
    case requiredInputsUnsupported(ReferencePlanFailureV2)
}

public enum ReferencePlanValidationErrorV2: Error, Sendable, Equatable {
    case unsupportedSchema(String)
    case emptyField(String)
    case invalidSHA256(String)
    case projectMismatch
    case demandBindingMismatch
    case routeBindingMismatch
    case duplicateDemand(String)
    case incompleteDemandAccounting
    case requiredDemandDropped(String)
    case nonDeterministicPlan
}

public enum ReferencePlanCanonicalCodecV2 {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode(
        _ data: Data,
        dataRoot: URL,
        route: ProductionRouteV1,
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1,
        graph: AssetGraphV1,
        candidate: ProductionRouteCandidateV1
    ) throws -> ReferencePlanV2 {
        let plan = try JSONDecoder().decode(ReferencePlanV2.self, from: data)
        try ReferencePlannerV2.validate(
            plan,
            dataRoot: dataRoot,
            route: route,
            requirement: requirement,
            demandSet: demandSet,
            graph: graph,
            candidate: candidate
        )
        return plan
    }
}

public enum ReferencePlannerV2 {
    public static func plan(
        id: String,
        dataRoot: URL,
        route: ProductionRouteV1,
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1,
        graph: AssetGraphV1,
        candidate: ProductionRouteCandidateV1
    ) throws -> ReferencePlanBuildResultV2 {
        try require(id, field: "reference_plan.id")
        try AssetGraphValidatorV1.validate(demandSet, against: graph)
        try AssetGraphValidatorV1.validateProjectFiles(graph, dataRoot: dataRoot)
        try ProductionRequirementResolverV1.validateBindings(
            requirement,
            demandSet: demandSet
        )
        let capabilities = candidate.capabilities
        let fingerprints = try ProductionRequirementResolverV1.fingerprints(
            requirement: requirement,
            candidate: candidate
        )
        guard route.offering == capabilities.offering,
              route.schema == productionRouteV1Schema,
              route.projectID == graph.projectID,
              route.shotID == demandSet.shotID,
              route.capabilitySnapshot
                == ProductionRouteCapabilitySnapshotV1(candidate: candidate),
              route.requirementSHA256 == fingerprints.requirementSHA256,
              route.capabilitiesSHA256 == fingerprints.capabilitiesSHA256,
              route.routeSHA256 == fingerprints.routeSHA256 else {
            throw ReferencePlanValidationErrorV2.routeBindingMismatch
        }
        let bindingDeficits = bindingDeficits(
            requirement: requirement,
            demandSet: demandSet
        )
        if !bindingDeficits.isEmpty {
            return .requiredInputsUnsupported(ReferencePlanFailureV2(
                offering: capabilities.offering,
                requirementSHA256: fingerprints.requirementSHA256,
                capabilitiesSHA256: fingerprints.capabilitiesSHA256,
                deficits: bindingDeficits
            ))
        }

        let budget = budget(
            for: capabilities.effective,
            modality: capabilities.offering.modality
        )
        let assets = Dictionary(uniqueKeysWithValues: graph.assets.map { ($0.id, $0) })
        let inputSlots = Dictionary(
            uniqueKeysWithValues: candidate.inputSlots.map { ($0.id, $0) }
        )
        var state = CapacityState()
        var requiredDeficits: [ReferencePlanDeficitV2] = []
        var selected: [ReferenceDemandV1] = []

        for demand in demandSet.demands where demand.isRequired {
            let deficits = placementDeficits(
                demand,
                assets: assets,
                selected: selected,
                state: state,
                budget: budget,
                inputSlots: inputSlots
            )
            if deficits.isEmpty {
                guard let asset = assets[demand.assetID],
                      let inputSlot = inputSlots[demand.inputSlotID] else {
                    throw ReferencePlanValidationErrorV2.demandBindingMismatch
                }
                selected.append(demand)
                state.place(
                    demand,
                    asset: asset,
                    inputSlot: inputSlot
                )
            } else {
                requiredDeficits.append(contentsOf: deficits)
            }
        }
        if !requiredDeficits.isEmpty {
            return .requiredInputsUnsupported(ReferencePlanFailureV2(
                offering: capabilities.offering,
                requirementSHA256: fingerprints.requirementSHA256,
                capabilitiesSHA256: fingerprints.capabilitiesSHA256,
                deficits: requiredDeficits
            ))
        }
        guard try ProductionRequirementResolverV1.revalidate(
            route,
            requirement: requirement,
            demandSet: demandSet,
            assetGraph: graph,
            dataRoot: dataRoot,
            candidate: candidate
        ) else {
            throw ReferencePlanValidationErrorV2.routeBindingMismatch
        }

        var optional = demandSet.demands.enumerated()
            .filter { !$0.element.isRequired }
            .map { RankedDemand(index: $0.offset, demand: $0.element) }
        var coveredScopes = Set(selected.flatMap(\.preservationScopeIDs))
        var drops: [ReferencePlanDropV2] = []
        while !optional.isEmpty {
            optional.sort {
                let leftCoverage = Set($0.demand.preservationScopeIDs)
                    .subtracting(coveredScopes).count
                let rightCoverage = Set($1.demand.preservationScopeIDs)
                    .subtracting(coveredScopes).count
                if leftCoverage != rightCoverage { return leftCoverage > rightCoverage }
                if $0.demand.priority != $1.demand.priority {
                    return $0.demand.priority > $1.demand.priority
                }
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.demand.id < $1.demand.id
            }
            let candidate = optional.removeFirst().demand
            let deficits = placementDeficits(
                candidate,
                assets: assets,
                selected: selected,
                state: state,
                budget: budget,
                inputSlots: inputSlots
            )
            if deficits.isEmpty {
                guard let asset = assets[candidate.assetID],
                      let inputSlot = inputSlots[candidate.inputSlotID] else {
                    throw ReferencePlanValidationErrorV2.demandBindingMismatch
                }
                selected.append(candidate)
                state.place(
                    candidate,
                    asset: asset,
                    inputSlot: inputSlot
                )
                coveredScopes.formUnion(candidate.preservationScopeIDs)
            } else {
                let first = deficits[0]
                drops.append(ReferencePlanDropV2(
                    demandID: candidate.id,
                    reason: dropReason(first.code),
                    detail: first.scopeID
                ))
            }
        }

        let demandData = try AssetGraphCanonicalCodecV1.encode(demandSet)
        let selectionOrder = Dictionary(
            uniqueKeysWithValues: selected.enumerated().map { ($0.element.id, $0.offset) }
        )
        let orderedSelected = selected.sorted {
            let leftOrder = inputSlots[$0.inputSlotID]?.requestOrder ?? Int.max
            let rightOrder = inputSlots[$1.inputSlotID]?.requestOrder ?? Int.max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            let leftSelection = selectionOrder[$0.id] ?? Int.max
            let rightSelection = selectionOrder[$1.id] ?? Int.max
            if leftSelection != rightSelection { return leftSelection < rightSelection }
            return $0.id < $1.id
        }
        let plan = ReferencePlanV2(
            id: id,
            projectID: graph.projectID,
            shotID: demandSet.shotID,
            demandSet: CanonicalArtifactReferenceV1(
                id: demandSet.id,
                role: ReferenceDemandSetV1.artifactRole,
                path: PipelineLayout.referenceDemandSetFile(shotID: demandSet.shotID),
                sha256: FileDigest.sha256(of: demandData)
            ),
            route: ReferencePlanRouteBindingV2(
                offering: route.offering,
                requirementSHA256: route.requirementSHA256,
                capabilitiesSHA256: route.capabilitiesSHA256,
                routeSHA256: route.routeSHA256
            ),
            budget: budget,
            bindings: try orderedSelected.map { demand in
                guard let asset = assets[demand.assetID] else {
                    throw ReferencePlanValidationErrorV2.demandBindingMismatch
                }
                return ReferenceBindingV2(demand: demand, asset: asset)
            },
            optionalDrops: drops
        )
        try validateStructure(plan, demandSet: demandSet, graph: graph)
        try validateProjectFiles(plan, dataRoot: dataRoot)
        return .plan(plan)
    }

    static func bindingDeficits(
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1
    ) -> [ReferencePlanDeficitV2] {
        let requiredDemandIDs = Set(requirement.referenceDemandIDs)
        let genericDemandIDs = Set(
            ProductionReferenceDemandSemanticsV1.genericDemandIDs(
                demandSet.demands
            )
        )
        var deficits: [ReferencePlanDeficitV2] = []
        for id in requiredDemandIDs.subtracting(genericDemandIDs).sorted() {
            deficits.append(ReferencePlanDeficitV2(
                demandID: id,
                code: .unknownDemand,
                scopeID: "reference_demand_set"
            ))
        }
        for id in genericDemandIDs.subtracting(requiredDemandIDs).sorted() {
            deficits.append(ReferencePlanDeficitV2(
                demandID: id,
                code: .missingDemand,
                scopeID: "production_requirement"
            ))
        }
        return deficits
    }

    public static func validate(
        _ plan: ReferencePlanV2,
        dataRoot: URL,
        route: ProductionRouteV1,
        requirement: ProductionRequirementV1,
        demandSet: ReferenceDemandSetV1,
        graph: AssetGraphV1,
        candidate: ProductionRouteCandidateV1
    ) throws {
        try validateStructure(plan, demandSet: demandSet, graph: graph)
        let result = try self.plan(
            id: plan.id,
            dataRoot: dataRoot,
            route: route,
            requirement: requirement,
            demandSet: demandSet,
            graph: graph,
            candidate: candidate
        )
        guard case .plan(let expected) = result, expected == plan else {
            throw ReferencePlanValidationErrorV2.nonDeterministicPlan
        }
    }

    public static func validateProjectFiles(_ plan: ReferencePlanV2, dataRoot: URL) throws {
        for binding in plan.bindings {
            _ = try ProjectLocalFile.requireHash(
                binding.sha256,
                at: binding.path,
                dataRoot: dataRoot
            )
        }
    }

    private static func validateStructure(
        _ plan: ReferencePlanV2,
        demandSet: ReferenceDemandSetV1,
        graph: AssetGraphV1
    ) throws {
        guard plan.schema == referencePlanV2Schema else {
            throw ReferencePlanValidationErrorV2.unsupportedSchema(plan.schema)
        }
        try require(plan.id, field: "reference_plan.id")
        guard plan.projectID == graph.projectID,
              demandSet.projectID == graph.projectID,
              plan.shotID == demandSet.shotID else {
            throw ReferencePlanValidationErrorV2.projectMismatch
        }
        let demandData = try AssetGraphCanonicalCodecV1.encode(demandSet)
        guard plan.demandSet.id == demandSet.id,
              plan.demandSet.role == ReferenceDemandSetV1.artifactRole,
              plan.demandSet.path == PipelineLayout.referenceDemandSetFile(
                shotID: demandSet.shotID
              ),
              plan.demandSet.sha256 == FileDigest.sha256(of: demandData) else {
            throw ReferencePlanValidationErrorV2.demandBindingMismatch
        }
        try validateHash(plan.route.requirementSHA256)
        try validateHash(plan.route.capabilitiesSHA256)
        try validateHash(plan.route.routeSHA256)
        var accounted = Set<String>()
        for binding in plan.bindings {
            guard accounted.insert(binding.demandID).inserted else {
                throw ReferencePlanValidationErrorV2.duplicateDemand(binding.demandID)
            }
        }
        for drop in plan.optionalDrops {
            guard accounted.insert(drop.demandID).inserted else {
                throw ReferencePlanValidationErrorV2.duplicateDemand(drop.demandID)
            }
            if demandSet.demands.first(where: { $0.id == drop.demandID })?.isRequired == true {
                throw ReferencePlanValidationErrorV2.requiredDemandDropped(drop.demandID)
            }
        }
        guard accounted == Set(demandSet.demands.map(\.id)) else {
            throw ReferencePlanValidationErrorV2.incompleteDemandAccounting
        }
    }

    private static func budget(
        for profile: ResolvedCapabilityProfileV1,
        modality: CapabilityModalityV1
    ) -> ReferencePlanBudgetV2 {
        let integers = profile.fields.integers
        let decimals = profile.fields.decimals
        switch modality {
        case .video:
            return ReferencePlanBudgetV2(
                imageCount: integers[CapabilityFieldIDV1.referenceImages]?.value ?? 0,
                videoCount: integers[CapabilityFieldIDV1.referenceVideos]?.value ?? 0,
                audioCount: integers[CapabilityFieldIDV1.referenceAudios]?.value ?? 0,
                geometryCount: 0,
                totalCount: integers[CapabilityFieldIDV1.totalReferences]?.value ?? 0,
                combinedVideoSeconds: decimals[
                    CapabilityFieldIDV1.combinedVideoReferenceSeconds
                ]?.value,
                combinedAudioSeconds: decimals[
                    CapabilityFieldIDV1.combinedAudioReferenceSeconds
                ]?.value
            )
        case .image:
            let count = integers[CapabilityFieldIDV1.imageReferences]?.value ?? 0
            return ReferencePlanBudgetV2(
                imageCount: count,
                videoCount: 0,
                audioCount: 0,
                geometryCount: 0,
                totalCount: count
            )
        case .audio, .music:
            let count = profile.fields.booleans[CapabilityFieldIDV1.audioReference]?.value == true
                ? 1 : 0
            return ReferencePlanBudgetV2(
                imageCount: 0,
                videoCount: 0,
                audioCount: count,
                geometryCount: 0,
                totalCount: count
            )
        }
    }

    private static func placementDeficits(
        _ demand: ReferenceDemandV1,
        assets: [String: AssetGraphNodeV1],
        selected: [ReferenceDemandV1],
        state: CapacityState,
        budget: ReferencePlanBudgetV2,
        inputSlots: [String: ProductionInputSlotCapabilityV1]
    ) -> [ReferencePlanDeficitV2] {
        var deficits: [ReferencePlanDeficitV2] = []
        let selectedIDs = Set(selected.map(\.id))
        let excludedBySelected = selected.contains {
            $0.exclusionDemandIDs.contains(demand.id)
        }
        if !selectedIDs.isDisjoint(with: Set(demand.exclusionDemandIDs)) || excludedBySelected {
            deficits.append(ReferencePlanDeficitV2(
                demandID: demand.id,
                code: .mutuallyExclusive,
                scopeID: "reference.exclusions"
            ))
        }
        guard let inputSlot = inputSlots[demand.inputSlotID],
              inputSlot.modality == demand.modality,
              Set(inputSlot.modeIDs.map(ProductionIdentifierNormalizerV1.canonical)).contains(
                  ProductionIdentifierNormalizerV1.canonical(demand.modeID)
              ) else {
            deficits.append(ReferencePlanDeficitV2(
                demandID: demand.id,
                code: .inputSlotUnsupported,
                scopeID: demand.inputSlotID
            ))
            return deficits
        }
        if inputSlot.countsTowardModalityBudget {
            let modalityAvailable = budget.count(for: demand.modality)
            let modalityRequired = state.count(for: demand.modality) + 1
            if modalityRequired > modalityAvailable {
                deficits.append(ReferencePlanDeficitV2(
                    demandID: demand.id,
                    code: .modalityBudget,
                    scopeID: "reference.\(demand.modality.rawValue)_count",
                    requiredValue: Double(modalityRequired),
                    availableValue: Double(modalityAvailable)
                ))
            }
        }
        if inputSlot.countsTowardTotalBudget,
           state.totalCount + 1 > budget.totalCount {
            deficits.append(ReferencePlanDeficitV2(
                demandID: demand.id,
                code: .totalBudget,
                scopeID: "reference.total_count",
                requiredValue: Double(state.totalCount + 1),
                availableValue: Double(budget.totalCount)
            ))
        }
        if inputSlot.countsTowardCombinedDuration {
            let duration = assets[demand.assetID]?.durationSeconds
            if demand.modality == .video,
               let limit = budget.combinedVideoSeconds {
                if let duration, state.videoSeconds + duration > limit {
                    deficits.append(ReferencePlanDeficitV2(
                        demandID: demand.id,
                        code: .combinedDuration,
                        scopeID: "reference.combined_video_seconds",
                        requiredValue: state.videoSeconds + duration,
                        availableValue: limit
                    ))
                } else if duration == nil {
                    deficits.append(ReferencePlanDeficitV2(
                        demandID: demand.id,
                        code: .unknownDuration,
                        scopeID: "reference.combined_video_seconds",
                        availableValue: limit
                    ))
                }
            }
            if demand.modality == .audio,
               let limit = budget.combinedAudioSeconds {
                if let duration, state.audioSeconds + duration > limit {
                    deficits.append(ReferencePlanDeficitV2(
                        demandID: demand.id,
                        code: .combinedDuration,
                        scopeID: "reference.combined_audio_seconds",
                        requiredValue: state.audioSeconds + duration,
                        availableValue: limit
                    ))
                } else if duration == nil {
                    deficits.append(ReferencePlanDeficitV2(
                        demandID: demand.id,
                        code: .unknownDuration,
                        scopeID: "reference.combined_audio_seconds",
                        availableValue: limit
                    ))
                }
            }
        }
        return deficits
    }

    private static func dropReason(
        _ deficit: ReferencePlanDeficitCodeV2
    ) -> ReferencePlanDropReasonV2 {
        switch deficit {
        case .inputSlotUnsupported: .inputSlotUnsupported
        case .modalityBudget, .unknownDemand, .missingDemand: .modalityBudget
        case .totalBudget: .totalBudget
        case .combinedDuration, .unknownDuration: .combinedDuration
        case .mutuallyExclusive: .mutuallyExclusive
        }
    }

    private static func validateHash(_ value: String) throws {
        guard value.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ReferencePlanValidationErrorV2.invalidSHA256(value)
        }
    }

    private static func require(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReferencePlanValidationErrorV2.emptyField(field)
        }
    }

    private struct RankedDemand {
        let index: Int
        let demand: ReferenceDemandV1
    }

    private struct CapacityState {
        var imageCount = 0
        var videoCount = 0
        var audioCount = 0
        var geometryCount = 0
        var totalCount = 0
        var videoSeconds = 0.0
        var audioSeconds = 0.0

        func count(for modality: AssetPhysicalModalityV1) -> Int {
            switch modality {
            case .image: imageCount
            case .video: videoCount
            case .audio: audioCount
            case .geometry: geometryCount
            }
        }

        mutating func place(
            _ demand: ReferenceDemandV1,
            asset: AssetGraphNodeV1,
            inputSlot: ProductionInputSlotCapabilityV1
        ) {
            if inputSlot.countsTowardModalityBudget {
                switch demand.modality {
                case .image: imageCount += 1
                case .video: videoCount += 1
                case .audio: audioCount += 1
                case .geometry: geometryCount += 1
                }
            }
            if inputSlot.countsTowardCombinedDuration {
                switch demand.modality {
                case .video: videoSeconds += asset.durationSeconds ?? 0
                case .audio: audioSeconds += asset.durationSeconds ?? 0
                case .image, .geometry: break
                }
            }
            if inputSlot.countsTowardTotalBudget {
                totalCount += 1
            }
        }
    }
}

private extension ReferencePlanBudgetV2 {
    func count(for modality: AssetPhysicalModalityV1) -> Int {
        switch modality {
        case .image: imageCount
        case .video: videoCount
        case .audio: audioCount
        case .geometry: geometryCount
        }
    }
}
