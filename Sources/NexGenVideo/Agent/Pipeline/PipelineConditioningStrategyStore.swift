import Foundation
import NexGenEngine

enum PipelineConditioningStrategyStore {
    static let extensionID = "core.conditioning-strategy.v1"

    struct Snapshot {
        let data: Data?
    }

    static func makePlan(
        shotlist: Shotlist,
        shotlistData: Data,
        executionInputs: [PipelineExecutionShotInput],
        dataRoot: URL
    ) throws -> ConditioningStrategyPlanV1 {
        guard shotlist.shots.count == executionInputs.count else {
            throw PipelineExecutionPlanComposerError.inputCoverageMismatch
        }
        var strategies: [ShotConditioningStrategyV1] = []
        for (index, pair) in zip(shotlist.shots, executionInputs).enumerated() {
            let shot = pair.0
            let input = pair.1
            guard shot.id == input.id else {
                throw PipelineExecutionPlanComposerError.inputCoverageMismatch
            }
            if let explicit = input.conditioning {
                strategies.append(try resolved(
                    explicit,
                    shot: shot,
                    input: input,
                    index: index,
                    allShots: shotlist.shots,
                    dataRoot: dataRoot
                ))
            } else if let legacy = try legacyStrategy(
                shot: shot,
                input: input,
                index: index,
                allShots: shotlist.shots
            ) {
                strategies.append(legacy)
            }
        }
        let plan = try ConditioningStrategyCanonicalCodecV1.identified(
            projectID: shotlist.project,
            shotlistSHA256: FileDigest.sha256(of: shotlistData),
            strategies: strategies
        )
        try ConditioningStrategyValidatorV1.validate(plan)
        return plan
    }

    static func write(_ plan: ConditioningStrategyPlanV1, dataRoot: URL) throws {
        try ConditioningStrategyValidatorV1.validate(plan)
        let data = try ConditioningStrategyCanonicalCodecV1.encode(plan)
        let url = PipelineLayout.url(ConditioningStrategyPlanV1.relativePath, in: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func loadCurrent(dataRoot: URL) throws -> ConditioningStrategyPlanV1? {
        let url = PipelineLayout.url(ConditioningStrategyPlanV1.relativePath, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let before = try Data(contentsOf: url)
        let plan = try ConditioningStrategyCanonicalCodecV1.decode(before)
        guard let shotlist = try loadShotlist(dataRoot: dataRoot),
              let version = latestShotlistVersion(dataRoot: dataRoot) else {
            throw PipelineExecutionPlanError.referencedFileInvalid(
                ConditioningStrategyPlanV1.relativePath
            )
        }
        let shotlistURL = PipelineLayout.url(
            PipelineLayout.shotlistVersionFile(version),
            in: dataRoot
        )
        let shotlistData = try Data(contentsOf: shotlistURL)
        let after = try Data(contentsOf: url)
        guard before == after,
              plan.projectID == shotlist.project,
              plan.shotlistSHA256 == FileDigest.sha256(of: shotlistData),
              Set(plan.strategies.map(\.shotID)).isSubset(of: Set(shotlist.shots.map(\.id))) else {
            throw PipelineExecutionPlanError.referencedFileInvalid(
                ConditioningStrategyPlanV1.relativePath
            )
        }
        for binding in plan.strategies.flatMap(\.referenceAnchors)
            + plan.strategies.compactMap(\.sourceVideo) {
            _ = try ProjectLocalFile.requireHash(
                binding.sha256,
                at: binding.path,
                dataRoot: dataRoot
            )
        }
        return plan
    }

    static func strategy(shotID: String, dataRoot: URL) throws -> ShotConditioningStrategyV1? {
        try loadCurrent(dataRoot: dataRoot)?.strategies.first { $0.shotID == shotID }
    }

    static func snapshot(dataRoot: URL) throws -> Snapshot {
        let url = PipelineLayout.url(ConditioningStrategyPlanV1.relativePath, in: dataRoot)
        return Snapshot(data: FileManager.default.fileExists(atPath: url.path)
            ? try Data(contentsOf: url)
            : nil)
    }

    static func restore(_ snapshot: Snapshot, dataRoot: URL) throws {
        let url = PipelineLayout.url(ConditioningStrategyPlanV1.relativePath, in: dataRoot)
        if let data = snapshot.data {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func validate(
        shotID: String,
        referencePlan: ReferencePlanV2,
        dataRoot: URL
    ) throws {
        guard let strategy = try strategy(shotID: shotID, dataRoot: dataRoot) else { return }
        try ConditioningStrategyValidatorV1.validate(strategy, referencePlan: referencePlan)
        for binding in strategy.referenceAnchors + [strategy.sourceVideo].compactMap({ $0 }) {
            guard referencePlan.bindings.contains(where: {
                $0.path == binding.path
                    && $0.sha256 == binding.sha256
                    && $0.modality == binding.modality
                    && ProductionIdentifierNormalizerV1.matches(
                        $0.semanticJobID,
                        binding.semanticJobID
                    )
                    && ProductionIdentifierNormalizerV1.matches(
                        $0.inputSlotID,
                        binding.inputSlotID
                    )
            }) else {
                throw ConditioningStrategyValidationErrorV1.referencePlanMismatch(shotID)
            }
        }
    }

    private static func resolved(
        _ explicit: PipelineConditioningInput,
        shot: Shot,
        input: PipelineExecutionShotInput,
        index: Int,
        allShots: [Shot],
        dataRoot: URL
    ) throws -> ShotConditioningStrategyV1 {
        guard let coreInputs = input.coreInputs else {
            throw PipelineExecutionShotInputValidationError.invalid(
                "execution_shot[\(shot.id)].conditioning"
            )
        }
        let anchors = try explicit.anchorDemandIDs.map { demandID -> ConditioningAssetBindingV1 in
            guard let demand = input.referenceDemands.first(where: { $0.id == demandID }) else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "execution_shot[\(shot.id)].conditioning.anchor_demand_ids"
                )
            }
            return try assetBinding(demand: demand, dataRoot: dataRoot)
        }
        let sourceVideo: ConditioningAssetBindingV1?
        if explicit.strategy == .nativeExtension {
            guard let sourcePath = shot.sourcePath else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "execution_shot[\(shot.id)].conditioning.source_shot_id"
                )
            }
            sourceVideo = try assetBinding(
                path: sourcePath,
                modality: .video,
                semanticJobID: CoreReferenceSemanticJobIDV1.sourceVideo,
                inputSlotID: CoreReferenceInputSlotIDV1.sourceVideo,
                dataRoot: dataRoot
            )
        } else {
            sourceVideo = nil
        }
        if explicit.strategy == .frameContinuation {
            guard index > 0,
                  explicit.predecessorShotID == allShots[index - 1].id,
                  shot.chainWithPreviousEnd,
                  shot.keyframeStrategy == .none else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "execution_shot[\(shot.id)].conditioning.predecessor_shot_id"
                )
            }
        }
        if explicit.strategy == .referenceAnchor {
            guard shot.keyframeStrategy == .none, !shot.chainWithPreviousEnd else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "execution_shot[\(shot.id)].conditioning.strategy"
                )
            }
        }
        if explicit.strategy == .twoStateInterpolation {
            guard shot.keyframeStrategy == .startEnd, !shot.chainWithPreviousEnd else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "execution_shot[\(shot.id)].conditioning.strategy"
                )
            }
        }
        if explicit.strategy == .firstFrame {
            guard shot.keyframeStrategy == .start, !shot.chainWithPreviousEnd else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "execution_shot[\(shot.id)].conditioning.strategy"
                )
            }
        }
        if explicit.strategy == .nativeExtension {
            guard shot.sourceMode == .aiEnhanced,
                  shot.keyframeStrategy == .none,
                  !shot.chainWithPreviousEnd,
                  coreInputs.sourceVideoModeID != nil else {
                throw PipelineExecutionShotInputValidationError.invalid(
                    "execution_shot[\(shot.id)].conditioning.strategy"
                )
            }
        }
        return ShotConditioningStrategyV1(
            shotID: shot.id,
            strategy: explicit.strategy,
            rationale: explicit.rationale,
            modeIDs: explicit.modeIDs,
            referenceAnchors: anchors,
            sourceVideo: sourceVideo,
            predecessorShotID: explicit.predecessorShotID,
            sourceShotID: explicit.sourceShotID,
            direction: explicit.direction,
            boundaryStateID: explicit.boundaryStateID,
            originalReferenceDemandIDs: explicit.originalReferenceDemandIDs
        )
    }

    private static func legacyStrategy(
        shot: Shot,
        input: PipelineExecutionShotInput,
        index: Int,
        allShots: [Shot]
    ) throws -> ShotConditioningStrategyV1? {
        guard input.sourceMode == .generated, let core = input.coreInputs else { return nil }
        if shot.chainWithPreviousEnd {
            guard index > 0, let modeID = core.predecessorLastFrameModeID else {
                throw PipelineExecutionPlanComposerError.invalidCoreInputs(shot.id)
            }
            return ShotConditioningStrategyV1(
                shotID: shot.id,
                strategy: .frameContinuation,
                rationale: "Preserve the exact predecessor-frame behavior of the existing plan.",
                modeIDs: [modeID],
                predecessorShotID: allShots[index - 1].id,
                legacyBehavior: true
            )
        }
        if shot.keyframeStrategy == .startEnd,
           let first = core.firstFrameModeID,
           let last = core.lastFrameModeID {
            return ShotConditioningStrategyV1(
                shotID: shot.id,
                strategy: .twoStateInterpolation,
                rationale: "Preserve the approved two-state interpolation of the existing plan.",
                modeIDs: [first, last]
            )
        }
        if shot.keyframeStrategy == .start, let modeID = core.firstFrameModeID {
            return ShotConditioningStrategyV1(
                shotID: shot.id,
                strategy: .firstFrame,
                rationale: "Preserve the explicitly planned first-frame behavior.",
                modeIDs: [modeID],
                legacyBehavior: true
            )
        }
        return nil
    }

    private static func assetBinding(
        demand: PipelineReferenceDemandInput,
        dataRoot: URL
    ) throws -> ConditioningAssetBindingV1 {
        try assetBinding(
            demandID: demand.id,
            path: demand.assetPath,
            modality: demand.modality,
            semanticJobID: demand.semanticJobID,
            inputSlotID: demand.inputSlotID,
            dataRoot: dataRoot
        )
    }

    private static func assetBinding(
        demandID: String? = nil,
        path: String,
        modality: AssetPhysicalModalityV1,
        semanticJobID: String,
        inputSlotID: String,
        dataRoot: URL
    ) throws -> ConditioningAssetBindingV1 {
        let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        let relative = try relativePath(url, dataRoot: dataRoot)
        return ConditioningAssetBindingV1(
            demandID: demandID,
            path: relative,
            sha256: try FileDigest.sha256(of: url),
            modality: modality,
            semanticJobID: semanticJobID,
            inputSlotID: inputSlotID
        )
    }

    private static func relativePath(_ url: URL, dataRoot: URL) throws -> String {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else {
            throw PipelineExecutionPlanComposerError.invalidReference(url.path)
        }
        return String(file.path.dropFirst(root.path.count + 1))
    }
}
