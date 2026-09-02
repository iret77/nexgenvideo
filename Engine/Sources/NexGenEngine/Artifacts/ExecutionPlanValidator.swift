import Foundation

public enum ExecutionPlanValidationError: Error, Sendable, Equatable {
    case unsupportedSchema(String)
    case emptyField(String)
    case invalidSHA256(path: String)
    case duplicateID(String)
    case emptyCollection(String)
    case planIncomplete([String])
    case invalidSourceBinding(shotID: String)
    case invalidGenerationRequirement(shotID: String)
    case invalidDuration(shotID: String)
    case invalidNumber(shotID: String, field: String)
    case invalidTimedBeat(shotID: String)
    case missingRescue(shotID: String)
    case unknownMediaReference(shotID: String, assetID: String)
    case invalidCreativeContextReference
    case projectMismatch(plan: String, context: String)
    case extensionReferenceMismatch
    case invalidReferencePath(String)
    case forbiddenOutputReference(String)
    case invalidExtensionSchema(String)
    case invalidLegacyProjection
}

public enum ExecutionPlanValidator {
    public static func validate(_ context: ProjectCreativeContextV1) throws {
        guard context.schema == ProjectCreativeContextV1.schemaVersion else {
            throw ExecutionPlanValidationError.unsupportedSchema(context.schema)
        }
        try require(context.projectID, field: "project_id")
        try validateUnique(
            context.artifacts.map(\.id) + context.media.map(\.id) + context.extensions.map(\.id),
            field: "context_reference"
        )
        try validateUnique(
            context.artifacts.map(\.path) + context.media.map(\.path) + context.extensions.map(\.path),
            field: "context_reference_path"
        )
        for artifact in context.artifacts {
            try validate(artifact)
        }
        for media in context.media {
            try validate(media)
        }
        for reference in context.extensions {
            try validate(reference)
        }
    }

    public static func validate(_ plan: ExecutionPlanV1) throws {
        guard plan.schema == executionPlanV1Schema else {
            throw ExecutionPlanValidationError.unsupportedSchema(plan.schema)
        }
        try require(plan.id, field: "id")
        try require(plan.projectID, field: "project_id")
        try validate(plan.creativeContext, allowCreativeContextOutput: true)
        guard plan.creativeContext.id == ExecutionPlanV1.creativeContextArtifactID,
              plan.creativeContext.role == ExecutionPlanV1.creativeContextArtifactRole,
              plan.creativeContext.path == PipelineLayout.creativeContextFile else {
            throw ExecutionPlanValidationError.invalidCreativeContextReference
        }
        try validateUnique(plan.extensionReferences.map(\.id), field: "extension")
        try validateUnique(plan.extensionReferences.map(\.path), field: "extension_path")
        for reference in plan.extensionReferences {
            try validate(reference)
        }
        guard plan.completeness == .complete else {
            throw ExecutionPlanValidationError.planIncomplete(plan.incompleteReasons)
        }
        if !plan.incompleteReasons.isEmpty {
            throw ExecutionPlanValidationError.planIncomplete(plan.incompleteReasons)
        }
        guard !plan.shots.isEmpty else {
            throw ExecutionPlanValidationError.emptyCollection("shots")
        }
        try validateUnique(plan.shots.map(\.id), field: "shot")
        for shot in plan.shots {
            try validate(shot)
        }
    }

    static func validateLegacyProjection(_ plan: ExecutionPlanV1) throws {
        guard plan.schema == executionPlanV1Schema else {
            throw ExecutionPlanValidationError.unsupportedSchema(plan.schema)
        }
        try require(plan.id, field: "id")
        try require(plan.projectID, field: "project_id")
        try validate(plan.creativeContext, allowCreativeContextOutput: true)
        guard plan.creativeContext.id == ExecutionPlanV1.creativeContextArtifactID,
              plan.creativeContext.role == ExecutionPlanV1.creativeContextArtifactRole,
              plan.creativeContext.path == PipelineLayout.creativeContextFile,
              plan.completeness == .legacyIncomplete,
              !plan.incompleteReasons.isEmpty else {
            throw ExecutionPlanValidationError.invalidLegacyProjection
        }
        try validateUniqueNonEmpty(plan.incompleteReasons, field: "incomplete_reasons")
        try validateUnique(plan.extensionReferences.map(\.id), field: "extension")
        try validateUnique(plan.extensionReferences.map(\.path), field: "extension_path")
        for reference in plan.extensionReferences {
            try validate(reference)
        }
        try validateUnique(plan.shots.map(\.id), field: "shot")
    }

    public static func validate(
        _ plan: ExecutionPlanV1,
        against context: ProjectCreativeContextV1
    ) throws {
        try validate(context)
        try validate(plan)
        guard plan.projectID == context.projectID else {
            throw ExecutionPlanValidationError.projectMismatch(
                plan: plan.projectID,
                context: context.projectID
            )
        }
        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        guard plan.creativeContext.sha256 == FileDigest.sha256(of: contextData) else {
            throw ExecutionPlanValidationError.invalidCreativeContextReference
        }
        guard Dictionary(uniqueKeysWithValues: plan.extensionReferences.map { ($0.id, $0) })
                == Dictionary(uniqueKeysWithValues: context.extensions.map { ($0.id, $0) }) else {
            throw ExecutionPlanValidationError.extensionReferenceMismatch
        }
        let mediaIDs = Set(context.media.map(\.id))
        for shot in plan.shots {
            var requiredMediaIDs = shot.blocking.compactMap(\.anchorAssetID)
            if let sourceAssetID = shot.sourceAssetID {
                requiredMediaIDs.append(sourceAssetID)
            }
            for assetID in requiredMediaIDs where !mediaIDs.contains(assetID) {
                throw ExecutionPlanValidationError.unknownMediaReference(
                    shotID: shot.id,
                    assetID: assetID
                )
            }
        }
    }

    public static func validate(
        _ plan: ExecutionPlanV1,
        against context: ProjectCreativeContextV1,
        assetGraph: AssetGraphV1,
        demandSet: ReferenceDemandSetV1,
        forShotID shotID: String
    ) throws {
        try validate(plan, against: context)
        guard plan.projectID == assetGraph.projectID else {
            throw ExecutionPlanValidationError.projectMismatch(
                plan: plan.projectID,
                context: assetGraph.projectID
            )
        }
        try AssetGraphValidatorV1.validate(assetGraph)
        guard let shotIndex = plan.shots.firstIndex(where: { $0.id == shotID }),
              plan.shots[shotIndex].generationRequirement != nil,
              demandSet.shotID == shotID else {
            throw ExecutionPlanValidationError.invalidGenerationRequirement(
                shotID: shotID
            )
        }
        try validateProductionInputs(
            shotIndex: shotIndex,
            plan: plan,
            assetGraph: assetGraph,
            demandSet: demandSet
        )
    }

    public static func validate(
        _ plan: ExecutionPlanV1,
        against context: ProjectCreativeContextV1,
        assetGraph: AssetGraphV1,
        referenceDemandSetsByShotID: [String: ReferenceDemandSetV1]
    ) throws {
        try validate(plan, against: context)
        guard plan.projectID == assetGraph.projectID else {
            throw ExecutionPlanValidationError.projectMismatch(
                plan: plan.projectID,
                context: assetGraph.projectID
            )
        }
        try AssetGraphValidatorV1.validate(assetGraph)
        for (shotIndex, shot) in plan.shots.enumerated() {
            guard shot.generationRequirement != nil else {
                if referenceDemandSetsByShotID[shot.id] != nil {
                    throw ExecutionPlanValidationError.invalidGenerationRequirement(
                        shotID: shot.id
                    )
                }
                continue
            }
            guard let demandSet = referenceDemandSetsByShotID[shot.id] else {
                throw ExecutionPlanValidationError.invalidGenerationRequirement(shotID: shot.id)
            }
            try validateProductionInputs(
                shotIndex: shotIndex,
                plan: plan,
                assetGraph: assetGraph,
                demandSet: demandSet
            )
        }
        let planShotIDs = Set(plan.shots.map(\.id))
        guard Set(referenceDemandSetsByShotID.keys).isSubset(of: planShotIDs) else {
            throw ExecutionPlanValidationError.invalidGenerationRequirement(shotID: "unknown")
        }
    }

    private static func validateProductionInputs(
        shotIndex: Int,
        plan: ExecutionPlanV1,
        assetGraph: AssetGraphV1,
        demandSet: ReferenceDemandSetV1
    ) throws {
        let shot = plan.shots[shotIndex]
        guard let requirement = shot.generationRequirement,
              demandSet.shotID == shot.id else {
            throw ExecutionPlanValidationError.invalidGenerationRequirement(
                shotID: shot.id
            )
        }
        let immediatePredecessorShotID = ChainContinuity.executionPredecessor(
            plan,
            shotID: shot.id
        )
        try AssetGraphValidatorV1.validate(
            demandSet,
            against: assetGraph,
            immediatePredecessorShotID: immediatePredecessorShotID
        )
        do {
            try ProductionRequirementResolverV1.validateBindings(
                requirement,
                demandSet: demandSet
            )
        } catch {
            throw ExecutionPlanValidationError.invalidGenerationRequirement(
                shotID: shot.id
            )
        }
        let assetsByID = Dictionary(
            uniqueKeysWithValues: assetGraph.assets.map { ($0.id, $0) }
        )
        for assetID in requirement.identityLockAssetIDs {
            guard assetsByID[assetID]?.approval == .approved else {
                throw ExecutionPlanValidationError.unknownMediaReference(
                    shotID: shot.id,
                    assetID: assetID
                )
            }
        }
        if let sourceVideoAssetID = requirement.sourceVideoAssetID {
            guard let source = assetsByID[sourceVideoAssetID],
                  source.approval == .approved,
                  source.modality == .video else {
                throw ExecutionPlanValidationError.unknownMediaReference(
                    shotID: shot.id,
                    assetID: sourceVideoAssetID
                )
            }
        }
    }

    private static func validate(_ shot: ExecutionShotV1) throws {
        try require(shot.id, field: "shot.id")
        try require(shot.startState.summary, field: "shot.start_state.summary")
        try require(shot.endState.summary, field: "shot.end_state.summary")
        try requireOptional(shot.startState.spatialState, field: "shot.start_state.spatial_state")
        try requireOptional(shot.endState.spatialState, field: "shot.end_state.spatial_state")
        try validateUniqueNonEmpty(
            shot.startState.entityStateIDs,
            field: "shot.start_state.entity_state_ids"
        )
        try validateUniqueNonEmpty(
            shot.endState.entityStateIDs,
            field: "shot.end_state.entity_state_ids"
        )
        try require(shot.primaryAction, field: "shot.primary_action")
        try require(shot.camera.movementID, field: "shot.camera.movement_id")
        try requireOptional(shot.camera.movementDetail, field: "shot.camera.movement_detail")
        try requireOptional(shot.camera.framingID, field: "shot.camera.framing_id")
        try requireOptional(shot.camera.placement, field: "shot.camera.placement")
        try requireOptional(shot.camera.endpoint, field: "shot.camera.endpoint")
        try validateUniqueNonEmpty(shot.continuityLocks, field: "shot.continuity_locks")
        try validateUniqueNonEmpty(shot.risks, field: "shot.risks")
        try requireOptional(shot.transitionIntent, field: "shot.transition_intent")
        try requireOptional(shot.rescue, field: "shot.rescue")
        try validateUnique(shot.acceptance.map(\.id), field: "shot.acceptance")
        guard !shot.acceptance.isEmpty else {
            throw ExecutionPlanValidationError.emptyCollection("shot.acceptance")
        }
        for criterion in shot.acceptance {
            try require(criterion.requirement, field: "shot.acceptance.requirement")
            try require(criterion.severity, field: "shot.acceptance.severity")
        }
        try validateUniqueCanonical(shot.blocking.map(\.entityID), field: "shot.blocking")
        for blocking in shot.blocking {
            try require(blocking.relation, field: "shot.blocking.relation")
            try requireOptional(blocking.anchorAssetID, field: "shot.blocking.anchor_asset_id")
            try requireOptional(blocking.performance, field: "shot.blocking.performance")
        }

        switch shot.sourceMode {
        case .generated:
            guard shot.sourceAssetID == nil else {
                throw ExecutionPlanValidationError.invalidSourceBinding(shotID: shot.id)
            }
            guard shot.generationRequirement != nil else {
                throw ExecutionPlanValidationError.invalidGenerationRequirement(shotID: shot.id)
            }
        case .aiEnhanced:
            guard nonEmpty(shot.sourceAssetID), shot.generationRequirement != nil else {
                throw ExecutionPlanValidationError.invalidSourceBinding(shotID: shot.id)
            }
        case .imported:
            guard shot.sourceAssetID == nil || nonEmpty(shot.sourceAssetID),
                  shot.generationRequirement == nil else {
                throw ExecutionPlanValidationError.invalidSourceBinding(shotID: shot.id)
            }
        }

        if let requirement = shot.generationRequirement {
            try require(requirement.modalityID, field: "shot.generation_requirement.modality_id")
            guard !requirement.modeIDs.isEmpty else {
                throw ExecutionPlanValidationError.emptyCollection(
                    "shot.generation_requirement.mode_ids"
                )
            }
            try validateUniqueCanonical(
                requirement.modeIDs,
                field: "shot.generation_requirement.mode_ids"
            )
            try validateUniqueNonEmpty(
                requirement.identityLockAssetIDs,
                field: "shot.generation_requirement.identity_lock_asset_ids"
            )
            try validateUniqueNonEmpty(
                requirement.referenceDemandIDs,
                field: "shot.generation_requirement.reference_demand_ids"
            )
            try validateUniqueNonEmpty(
                requirement.productionProfileRequirementIDs,
                field: "shot.generation_requirement.production_profile_requirement_ids"
            )
            try requireOptional(
                requirement.sourceVideoAssetID,
                field: "shot.generation_requirement.source_video_asset_id"
            )
            try requireOptional(
                requirement.resolution,
                field: "shot.generation_requirement.resolution"
            )
            try requireOptional(
                requirement.aspectRatio,
                field: "shot.generation_requirement.aspect_ratio"
            )
            try requireOptional(
                requirement.qualityTarget,
                field: "shot.generation_requirement.quality_target"
            )
            guard requirement.visibleEntityCount >= 0 else {
                throw ExecutionPlanValidationError.invalidGenerationRequirement(shotID: shot.id)
            }
            if let maximumCost = requirement.maximumCost,
               !maximumCost.isFinite || maximumCost < 0 {
                throw ExecutionPlanValidationError.invalidNumber(
                    shotID: shot.id,
                    field: "maximum_cost"
                )
            }
            if let maximumLatency = requirement.maximumLatencySeconds,
               !maximumLatency.isFinite || maximumLatency <= 0 {
                throw ExecutionPlanValidationError.invalidNumber(
                    shotID: shot.id,
                    field: "maximum_latency_seconds"
                )
            }
            if let duration = requirement.duration {
                let values = [duration.preferredSeconds, duration.minimumSeconds, duration.maximumSeconds]
                    .compactMap { $0 }
                guard !values.isEmpty || duration.allowsAutomatic,
                      values.allSatisfy({ $0.isFinite && $0 > 0 }),
                      duration.minimumSeconds == nil || duration.maximumSeconds == nil
                        || duration.minimumSeconds! <= duration.maximumSeconds!,
                      duration.preferredSeconds == nil || duration.minimumSeconds == nil
                        || duration.preferredSeconds! >= duration.minimumSeconds!,
                      duration.preferredSeconds == nil || duration.maximumSeconds == nil
                        || duration.preferredSeconds! <= duration.maximumSeconds! else {
                    throw ExecutionPlanValidationError.invalidDuration(shotID: shot.id)
                }
            }
        }

        let timedBeatMaximum = shot.generationRequirement?.duration.flatMap {
            $0.preferredSeconds ?? $0.maximumSeconds
        }
        var previous = -Double.infinity
        for (index, beat) in shot.timedActionBeats.enumerated() {
            try require(beat.action, field: "shot.timed_action_beats.action")
            guard beat.timeSeconds.isFinite,
                  beat.timeSeconds >= 0,
                  index == 0 || beat.timeSeconds > previous,
                  timedBeatMaximum.map({ beat.timeSeconds <= $0 }) ?? true else {
                throw ExecutionPlanValidationError.invalidTimedBeat(shotID: shot.id)
            }
            previous = beat.timeSeconds
        }

        if shot.renderability == .green {
            guard shot.risks.isEmpty, shot.rescue == nil else {
                throw ExecutionPlanValidationError.invalidGenerationRequirement(shotID: shot.id)
            }
        } else {
            guard !shot.risks.isEmpty else {
                throw ExecutionPlanValidationError.emptyCollection("shot.risks")
            }
            guard nonEmpty(shot.rescue) else {
                throw ExecutionPlanValidationError.missingRescue(shotID: shot.id)
            }
        }
    }

    private static func validate(
        _ reference: CanonicalArtifactReferenceV1,
        allowCreativeContextOutput: Bool = false
    ) throws {
        try require(reference.id, field: "artifact.id")
        try require(reference.role, field: "artifact.role")
        try require(reference.path, field: "artifact.path")
        try validateReferencePath(
            reference.path,
            allowCreativeContextOutput: allowCreativeContextOutput
        )
        try validateSHA256(reference.sha256, path: reference.path)
    }

    private static func validate(_ reference: PackArtifactExtensionReferenceV1) throws {
        try require(reference.id, field: "extension.id")
        try require(reference.schema, field: "extension.schema")
        try require(reference.path, field: "extension.path")
        try validateExtensionSchema(reference.schema)
        try validateExtensionPath(reference.path)
        try validateSHA256(reference.sha256, path: reference.path)
    }

    private static func validate(_ reference: ProjectMediaReferenceV1) throws {
        try require(reference.id, field: "media.id")
        try require(reference.role, field: "media.role")
        try require(reference.path, field: "media.path")
        try validateReferencePath(reference.path)
        try validateSHA256(reference.sha256, path: reference.path)
    }

    private static func validateReferencePath(
        _ path: String,
        allowCreativeContextOutput: Bool = false
    ) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              !NSString(string: path).isAbsolutePath,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ExecutionPlanValidationError.invalidReferencePath(path)
        }
        let writerOutputs = Set([
            PipelineLayout.executionPlanFile,
            PipelineLayout.creativeContextFile,
            ExecutionPlanV1.publicationArtifactPath,
            "\(DataRootResolver.pipelineDirname)/\(PipelineLayout.executionPlanFile)",
            "\(DataRootResolver.pipelineDirname)/\(PipelineLayout.creativeContextFile)",
            "\(DataRootResolver.pipelineDirname)/\(ExecutionPlanV1.publicationArtifactPath)",
            "\(DataRootResolver.legacyPipelineDirname)/\(PipelineLayout.executionPlanFile)",
            "\(DataRootResolver.legacyPipelineDirname)/\(PipelineLayout.creativeContextFile)",
            "\(DataRootResolver.legacyPipelineDirname)/\(ExecutionPlanV1.publicationArtifactPath)",
        ])
        if writerOutputs.contains(path),
           !(allowCreativeContextOutput && path == PipelineLayout.creativeContextFile) {
            throw ExecutionPlanValidationError.forbiddenOutputReference(path)
        }
    }

    private static func validateExtensionPath(_ path: String) throws {
        try validateReferencePath(path)
        let prefix = PipelineLayout.executionExtensionsDir + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else {
            throw ExecutionPlanValidationError.invalidReferencePath(path)
        }
    }

    private static func validateExtensionSchema(_ schema: String) throws {
        let pattern = #"^[a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)*/v[1-9][0-9]*$"#
        guard schema.range(of: pattern, options: .regularExpression) != nil else {
            throw ExecutionPlanValidationError.invalidExtensionSchema(schema)
        }
    }

    private static func validateSHA256(_ value: String, path: String) throws {
        guard value.count == 64,
              value.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw ExecutionPlanValidationError.invalidSHA256(path: path)
        }
    }

    private static func validateUnique(_ ids: [String], field: String) throws {
        var seen = Set<String>()
        for id in ids {
            try require(id, field: "\(field).id")
            guard seen.insert(id).inserted else {
                throw ExecutionPlanValidationError.duplicateID(id)
            }
        }
    }

    private static func validateUniqueCanonical(_ ids: [String], field: String) throws {
        var seen = Set<String>()
        for id in ids {
            try require(id, field: "\(field).id")
            let canonical = ProductionIdentifierNormalizerV1.canonical(id)
            guard seen.insert(canonical).inserted else {
                throw ExecutionPlanValidationError.duplicateID(id)
            }
        }
    }

    private static func validateUniqueNonEmpty(_ ids: [String], field: String) throws {
        guard !ids.isEmpty else { return }
        try validateUnique(ids, field: field)
    }

    private static func require(_ value: String, field: String) throws {
        guard nonEmpty(value) else {
            throw ExecutionPlanValidationError.emptyField(field)
        }
    }

    private static func requireOptional(_ value: String?, field: String) throws {
        if let value {
            try require(value, field: field)
        }
    }

    private static func nonEmpty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
