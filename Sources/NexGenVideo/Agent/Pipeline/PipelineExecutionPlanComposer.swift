import Foundation
import NexGenEngine

enum PipelineExecutionPlanComposerError: Error, Sendable, Equatable {
    case inputCoverageMismatch
    case sourceModeMismatch(String)
    case missingProductionPlan(String)
    case invalidCoreInputs(String)
    case invalidBlocking(String)
    case invalidReference(String)
    case referenceSetMismatch(String)
    case conflictingReference(String)
    case unsupportedRequirement(String)
}

struct PipelineExecutionPlanDraft {
    let plan: ExecutionPlanV1
    let context: ProjectCreativeContextV1
    let assetGraph: AssetGraphV1
    let demandSets: [ReferenceDemandSetV1]
    let inputTemplates: [ProductionInputTemplateV1]
}

enum PipelineExecutionPlanComposer {
    private struct AssetDraft {
        let path: String
        let sha256: String
        let modality: AssetPhysicalModalityV1
        let entityID: String?
        let canonIDs: [String]
        let stateID: String?
        let viewID: String?
        var allowedUseIDs: Set<String>
    }

    static func compose(
        shotlist: Shotlist,
        executionInputs: [PipelineExecutionShotInput],
        executionInputData: Data,
        shotlistPath: String,
        dataRoot: URL,
        declaredPack: String?
    ) throws -> PipelineExecutionPlanDraft {
        guard shotlist.shots.count == executionInputs.count,
              zip(shotlist.shots, executionInputs).allSatisfy({ pair in
                  pair.0.id == pair.1.id
              }) else {
            throw PipelineExecutionPlanComposerError.inputCoverageMismatch
        }
        for (shot, input) in zip(shotlist.shots, executionInputs) {
            try input.validate(timedBeatMaximumSeconds: shot.durationS)
            try validateReferenceCorrespondence(
                shotID: shot.id,
                referenceImageRefs: shot.referenceImageRefs,
                referenceDemands: input.referenceDemands,
                dataRoot: dataRoot
            )
        }

        let store = YAMLArtifactStore(dataRoot: dataRoot)
        let brief = try store.load(Brief.self, at: PipelineLayout.briefFile)
        let bibleURL = PipelineLayout.url(PipelineLayout.bibleFile, in: dataRoot)
        let bible = FileManager.default.fileExists(atPath: bibleURL.path)
            ? try store.load(Bible.self, at: PipelineLayout.bibleFile)
            : nil

        var assetsByPath: [String: AssetDraft] = [:]
        var demandAssetPathsByShotID: [String: [String: String]] = [:]
        var sourceAssetPathsByShotID: [String: String] = [:]

        for (shot, input) in zip(shotlist.shots, executionInputs) {
            guard matches(sourceMode: shot.sourceMode, executionMode: input.sourceMode) else {
                throw PipelineExecutionPlanComposerError.sourceModeMismatch(shot.id)
            }
            var demandAssetPaths: [String: String] = [:]
            for demand in input.referenceDemands {
                let asset = try makeAssetDraft(
                    path: demand.assetPath,
                    modality: demand.modality,
                    entityID: demand.entityID,
                    canonIDs: demand.canonIDs,
                    stateID: demand.stateID,
                    viewID: demand.viewID,
                    allowedUseID: demand.semanticJobID,
                    dataRoot: dataRoot
                )
                try merge(asset, into: &assetsByPath)
                demandAssetPaths[demand.id] = asset.path
            }
            demandAssetPathsByShotID[shot.id] = demandAssetPaths

            if let sourcePath = shot.sourcePath {
                let asset = try makeAssetDraft(
                    path: sourcePath,
                    modality: .video,
                    entityID: nil,
                    canonIDs: [],
                    stateID: nil,
                    viewID: nil,
                    allowedUseID: shot.sourceMode == .aiEnhanced
                        ? CoreReferenceSemanticJobIDV1.sourceVideo
                        : nil,
                    dataRoot: dataRoot
                )
                try merge(asset, into: &assetsByPath)
                sourceAssetPathsByShotID[shot.id] = asset.path
            }
        }

        let assetNodes = try assetsByPath.values.map {
            try AssetGraphContentAddressV1.reidentified(AssetGraphNodeV1(
                id: "pending",
                version: 1,
                path: $0.path,
                sha256: $0.sha256,
                modality: $0.modality,
                entityID: $0.entityID,
                canonIDs: $0.canonIDs.sorted(),
                stateID: $0.stateID,
                viewID: $0.viewID,
                approval: .approved,
                provenance: AssetProvenanceV1(
                    kindID: "core.project-file",
                    recordedAt: shotlist.generated
                ),
                allowedUseIDs: $0.allowedUseIDs.sorted()
            ))
        }.sorted { $0.id < $1.id }
        let assetIDByPath = Dictionary(uniqueKeysWithValues: assetNodes.map {
            ($0.path, $0.id)
        })
        var demandAssetIDsByShotID: [String: [String: String]] = [:]
        for (shotID, pathsByDemandID) in demandAssetPathsByShotID {
            var idsByDemandID: [String: String] = [:]
            for (demandID, path) in pathsByDemandID {
                guard let assetID = assetIDByPath[path] else {
                    throw PipelineExecutionPlanComposerError.invalidReference(path)
                }
                idsByDemandID[demandID] = assetID
            }
            demandAssetIDsByShotID[shotID] = idsByDemandID
        }
        let sourceAssetIDsByShotID = try assetIDsByShotID(
            sourceAssetPathsByShotID,
            assetIDByPath: assetIDByPath
        )
        let graph = AssetGraphV1(
            id: try AssetGraphContentAddressV1.graphID(
                projectID: shotlist.project,
                assets: assetNodes
            ),
            projectID: shotlist.project,
            assets: assetNodes
        )
        let graphData = try AssetGraphCanonicalCodecV1.encode(graph)
        let graphReference = CanonicalArtifactReferenceV1(
            id: graph.id,
            role: AssetGraphV1.artifactRole,
            path: PipelineLayout.assetGraphFile,
            sha256: FileDigest.sha256(of: graphData)
        )

        var executionShots: [ExecutionShotV1] = []
        var demandSets: [ReferenceDemandSetV1] = []
        var templates: [ProductionInputTemplateV1] = []
        for (index, pair) in zip(shotlist.shots, executionInputs).enumerated() {
            let shot = pair.0
            let input = pair.1
            let demandAssetIDs = demandAssetIDsByShotID[shot.id] ?? [:]
            let sourceAssetID = sourceAssetIDsByShotID[shot.id]
            let generationRequirement = try generationRequirement(
                shot: shot,
                input: input,
                sourceAssetID: sourceAssetID,
                demandAssetIDs: demandAssetIDs,
                brief: brief,
                bible: bible
            )
            executionShots.append(try executionShot(
                shot: shot,
                input: input,
                sourceAssetID: sourceAssetID,
                demandAssetIDs: demandAssetIDs,
                generationRequirement: generationRequirement
            ))

            guard let generationRequirement,
                  let coreInputs = input.coreInputs else {
                continue
            }
            let template = ProductionInputTemplateV1(
                id: "production-input-template-\(shot.id)",
                projectID: shotlist.project,
                shotID: shot.id,
                coreInputs: ProductionCoreInputModesV1(
                    firstFrameModeID: coreInputs.firstFrameModeID,
                    lastFrameModeID: coreInputs.lastFrameModeID,
                    predecessorLastFrameModeID: coreInputs.predecessorLastFrameModeID,
                    sourceVideoModeID: coreInputs.sourceVideoModeID,
                    audioTimingModeID: coreInputs.audioTimingModeID
                )
            )
            try ProductionInputTemplateValidatorV1.validate(
                template,
                requirement: generationRequirement,
                chainedFromPredecessor: shot.chainWithPreviousEnd
            )
            templates.append(template)

            var demands = try input.referenceDemands.map { demand in
                guard let assetID = demandAssetIDs[demand.id] else {
                    throw PipelineExecutionPlanComposerError.invalidReference(demand.id)
                }
                return ReferenceDemandV1(
                    id: demand.id,
                    assetID: assetID,
                    modality: demand.modality,
                    semanticJobID: demand.semanticJobID,
                    isRequired: demand.isRequired,
                    priority: demand.priority,
                    preservationScopeIDs: demand.preservationScopeIDs,
                    exclusionDemandIDs: demand.exclusionDemandIDs,
                    inputSlotID: demand.inputSlotID,
                    modeID: demand.modeID
                )
            }
            if input.sourceMode == .aiEnhanced,
               let sourceAssetID,
               let modeID = coreInputs.sourceVideoModeID {
                demands.append(ReferenceDemandV1(
                    id: "core-source-video-\(shot.id)",
                    assetID: sourceAssetID,
                    modality: .video,
                    semanticJobID: CoreReferenceSemanticJobIDV1.sourceVideo,
                    isRequired: true,
                    priority: 0,
                    inputSlotID: CoreReferenceInputSlotIDV1.sourceVideo,
                    modeID: modeID
                ))
            }
            demandSets.append(ReferenceDemandSetV1(
                id: "reference-demand-set-\(shot.id)",
                projectID: shotlist.project,
                shotID: shot.id,
                assetGraph: graphReference,
                demands: demands
            ))

            if shot.chainWithPreviousEnd, index == 0 {
                throw PipelineExecutionPlanComposerError.invalidCoreInputs(shot.id)
            }
        }

        var media = assetNodes.map {
            ProjectMediaReferenceV1(
                id: $0.id,
                role: "core.project-media",
                path: $0.path,
                sha256: $0.sha256
            )
        }
        try appendProjectMedia(
            path: shotlist.song.audioPath,
            id: "song-audio",
            role: "core.song-audio",
            dataRoot: dataRoot,
            to: &media
        )
        if let lyricsPath = shotlist.song.lyricsPath {
            try appendProjectMedia(
                path: lyricsPath,
                id: "song-lyrics",
                role: "core.song-lyrics",
                dataRoot: dataRoot,
                to: &media
            )
        }
        let extensions = try canonicalExtensions(
            declaredPack: declaredPack,
            dataRoot: dataRoot
        )
        let artifacts = try canonicalArtifacts(
            shotlistPath: shotlistPath,
            templates: templates,
            executionInputData: executionInputData,
            declaredPack: declaredPack,
            excludingPaths: Set(media.map(\.path) + extensions.map(\.path)),
            dataRoot: dataRoot
        )
        let context = ProjectCreativeContextV1(
            projectID: shotlist.project,
            artifacts: artifacts,
            media: media,
            extensions: extensions
        )
        let contextData = try ExecutionPlanCanonicalCodec.encode(context)
        let planEncoder = JSONEncoder()
        planEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var planIdentityData = contextData
        planIdentityData.append(0)
        planIdentityData.append(try planEncoder.encode(executionShots))
        planIdentityData.append(0)
        planIdentityData.append(graphData)
        let plan = ExecutionPlanV1(
            id: "execution-plan-\(FileDigest.sha256(of: planIdentityData))",
            projectID: shotlist.project,
            creativeContext: CanonicalArtifactReferenceV1(
                id: ExecutionPlanV1.creativeContextArtifactID,
                role: ExecutionPlanV1.creativeContextArtifactRole,
                path: PipelineLayout.creativeContextFile,
                sha256: FileDigest.sha256(of: contextData)
            ),
            extensionReferences: extensions,
            shots: executionShots
        )
        try ExecutionPlanValidator.validate(plan, against: context)
        return PipelineExecutionPlanDraft(
            plan: plan,
            context: context,
            assetGraph: graph,
            demandSets: demandSets,
            inputTemplates: templates
        )
    }

    private static func generationRequirement(
        shot: Shot,
        input: PipelineExecutionShotInput,
        sourceAssetID: String?,
        demandAssetIDs: [String: String],
        brief: Brief,
        bible: Bible?
    ) throws -> GenerationRequirementV1? {
        guard input.sourceMode != .imported else { return nil }
        guard let supplied = input.generationRequirement,
              let coreInputs = input.coreInputs,
              supplied.modalityID == .video else {
            throw PipelineExecutionPlanComposerError.unsupportedRequirement(shot.id)
        }
        let requiresFirstFrame = shot.chainWithPreviousEnd
            || shot.keyframeStrategy == .start
            || shot.keyframeStrategy == .startEnd
        let requiresLastFrame = shot.keyframeStrategy == .startEnd
        let expectedFirst = shot.chainWithPreviousEnd
            ? coreInputs.predecessorLastFrameModeID != nil
                && coreInputs.firstFrameModeID == nil
            : (coreInputs.firstFrameModeID != nil) == requiresFirstFrame
                && coreInputs.predecessorLastFrameModeID == nil
        guard expectedFirst,
              (coreInputs.lastFrameModeID != nil) == requiresLastFrame,
              (input.sourceMode == .aiEnhanced) == (coreInputs.sourceVideoModeID != nil),
              (input.sourceMode == .aiEnhanced) == (sourceAssetID != nil),
              !shot.chainWithPreviousEnd || !requiresLastFrame else {
            throw PipelineExecutionPlanComposerError.invalidCoreInputs(shot.id)
        }
        let identityAssetIDs = try identityAssetIDs(
            referenceDemands: input.referenceDemands,
            demandAssetIDs: demandAssetIDs
        )
        let aspectRatio = brief.aspectRatio == .other
            ? brief.aspectRatioOther
            : brief.aspectRatio.rawValue
        guard let aspectRatio,
              !aspectRatio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineExecutionPlanComposerError.unsupportedRequirement(shot.id)
        }
        return GenerationRequirementV1(
            modalityID: supplied.modalityID.rawValue,
            modeIDs: supplied.modeIDs,
            visibleEntityCount: ProductionDiscipline.visibleCharacterCount(
                shot,
                bible: bible
            ),
            identityLockAssetIDs: identityAssetIDs,
            referenceDemandIDs: genericReferenceDemandIDs(input.referenceDemands),
            requiresFirstFrame: requiresFirstFrame,
            requiresLastFrame: requiresLastFrame,
            sourceVideoAssetID: sourceAssetID,
            duration: RequestedDurationV1(
                preferredSeconds: shot.durationS,
                minimumSeconds: supplied.duration.minimumSeconds,
                maximumSeconds: supplied.duration.maximumSeconds,
                allowsAutomatic: supplied.duration.allowsAutomatic
            ),
            resolution: brief.finalResolution.rawValue,
            aspectRatio: aspectRatio,
            requiresOutputAudio: supplied.requiresOutputAudio,
            qualityTarget: supplied.qualityTarget,
            maximumCost: supplied.maximumCost,
            maximumLatencySeconds: supplied.maximumLatencySeconds
        )
    }

    private static func executionShot(
        shot: Shot,
        input: PipelineExecutionShotInput,
        sourceAssetID: String?,
        demandAssetIDs: [String: String],
        generationRequirement: GenerationRequirementV1?
    ) throws -> ExecutionShotV1 {
        let blocking = try executionBlocking(
            shotID: shot.id,
            shotBlocking: shot.characterBlocking,
            inputBlocking: input.blocking,
            demandAssetIDs: demandAssetIDs
        )
        let camera: ExecutionCameraPlanV1
        let primaryAction: String
        let continuityLocks: [String]
        let transitionIntent: String?
        let renderability: ExecutionRenderabilityV1
        let risks: [String]
        let rescue: String?
        if input.sourceMode == .imported {
            guard let suppliedCamera = input.camera,
                  let suppliedAction = input.primaryAction,
                  let suppliedRenderability = input.renderability else {
                throw PipelineExecutionPlanComposerError.unsupportedRequirement(shot.id)
            }
            camera = ExecutionCameraPlanV1(
                movementID: suppliedCamera.movementID,
                movementDetail: suppliedCamera.movementDetail,
                framingID: suppliedCamera.framingID,
                placement: suppliedCamera.placement,
                endpoint: suppliedCamera.endpoint
            )
            primaryAction = suppliedAction
            continuityLocks = input.continuityLocks
            transitionIntent = input.transitionIntent
            renderability = suppliedRenderability
            risks = input.risks
            rescue = input.rescue
        } else {
            guard let productionPlan = shot.productionPlan else {
                throw PipelineExecutionPlanComposerError.missingProductionPlan(shot.id)
            }
            camera = ExecutionCameraPlanV1(
                movementID: productionPlan.cameraMovement.rawValue,
                movementDetail: productionPlan.cameraMovementDetail,
                framingID: shot.framing?.rawValue,
                placement: input.cameraPlacement,
                endpoint: input.cameraEndpoint
            )
            primaryAction = productionPlan.primaryAction
            continuityLocks = productionPlan.continuityLocks
            transitionIntent = productionPlan.matchActionCue
            renderability = switch productionPlan.renderability {
            case .green: .green
            case .yellow: .yellow
            case .red: .red
            }
            risks = productionPlan.risks.map(\.rawValue)
            rescue = productionPlan.rescueCut
        }
        return ExecutionShotV1(
            id: shot.id,
            sourceMode: input.sourceMode,
            sourceAssetID: sourceAssetID,
            startState: ExecutionStateV1(
                summary: input.startState.summary,
                entityStateIDs: input.startState.entityStateIDs,
                spatialState: input.startState.spatialState
            ),
            endState: ExecutionStateV1(
                summary: input.endState.summary,
                entityStateIDs: input.endState.entityStateIDs,
                spatialState: input.endState.spatialState
            ),
            primaryAction: primaryAction,
            camera: camera,
            blocking: blocking,
            timedActionBeats: input.timedActionBeats.map {
                TimedActionBeatV1(timeSeconds: $0.timeSeconds, action: $0.action)
            },
            continuityLocks: continuityLocks,
            transitionIntent: transitionIntent,
            renderability: renderability,
            risks: risks,
            rescue: rescue,
            acceptance: input.acceptance.map {
                ExecutionAcceptanceCriterionV1(
                    id: $0.id,
                    requirement: $0.requirement,
                    severity: $0.severity
                )
            },
            generationRequirement: generationRequirement
        )
    }

    static func executionBlocking(
        shotID: String,
        shotBlocking: [CharacterBlocking],
        inputBlocking: [PipelineExecutionBlockingInput],
        demandAssetIDs: [String: String]
    ) throws -> [ExecutionBlockingV1] {
        var blockingByEntity: [String: CharacterBlocking] = [:]
        for item in shotBlocking {
            let key = ProductionIdentifierNormalizerV1.canonical(item.characterRef)
            guard blockingByEntity.updateValue(item, forKey: key) == nil else {
                throw PipelineExecutionPlanComposerError.invalidBlocking(shotID)
            }
        }
        let inputBlockingIDs = Set(inputBlocking.map {
            ProductionIdentifierNormalizerV1.canonical($0.entityID)
        })
        guard inputBlockingIDs.count == inputBlocking.count,
              inputBlockingIDs == Set(blockingByEntity.keys) else {
            throw PipelineExecutionPlanComposerError.invalidBlocking(shotID)
        }
        return try inputBlocking.map { item -> ExecutionBlockingV1 in
            let key = ProductionIdentifierNormalizerV1.canonical(item.entityID)
            guard let source = blockingByEntity[key] else {
                throw PipelineExecutionPlanComposerError.invalidBlocking(shotID)
            }
            guard !source.relationToSet.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                throw PipelineExecutionPlanComposerError.invalidBlocking(shotID)
            }
            let anchorAssetID: String?
            if let anchorDemandID = item.anchorDemandID {
                guard let resolved = demandAssetIDs[anchorDemandID] else {
                    throw PipelineExecutionPlanComposerError.invalidBlocking(shotID)
                }
                anchorAssetID = resolved
            } else {
                anchorAssetID = nil
            }
            return ExecutionBlockingV1(
                entityID: source.characterRef,
                anchorAssetID: anchorAssetID,
                relation: source.relationToSet,
                performance: item.performance
            )
        }
    }

    private static func canonicalArtifacts(
        shotlistPath: String,
        templates: [ProductionInputTemplateV1],
        executionInputData: Data,
        declaredPack: String?,
        excludingPaths: Set<String>,
        dataRoot: URL
    ) throws -> [CanonicalArtifactReferenceV1] {
        let contract = try PhaseContractRuntime.contract(activePack: declaredPack)
        if declaredPack != nil, contract == nil {
            throw PipelineExecutionPlanComposerError.invalidReference(
                "pipeline phase contract"
            )
        }
        var declarations: [(String, String, String)] = [
            ("project", "core.project", PipelineLayout.projectFile),
        ]
        var lineageSnapshots: [(
            phaseID: String,
            provider: EngineRegistry.PhaseLineageProvider,
            snapshot: PhaseLineageSnapshot
        )] = []
        var selectedPaths = Set(declarations.map { $0.2 })
        if let contract {
            guard let shotlistIndex = contract.order.firstIndex(of: "shotlist") else {
                throw PipelineExecutionPlanComposerError.invalidReference(
                    "pipeline phase contract"
                )
            }
            for phaseID in contract.order[..<shotlistIndex] {
                guard let phase = contract.phase(phaseID) else {
                    throw PipelineExecutionPlanComposerError.invalidReference(phaseID)
                }
                if let lineageProvider = phase.nativeLineageProvider,
                   phase.nativeLineageRequiresRecord {
                    let snapshot = try lineageProvider(dataRoot)
                    try PipelineLineageStore.requireCurrent(
                        phase: phaseID,
                        snapshot: snapshot,
                        dataRoot: dataRoot
                    )
                    lineageSnapshots.append((phaseID, lineageProvider, snapshot))
                }
                let paths: [String]
                if let artifactProvider = phase.nativeArtifactProvider {
                    paths = try artifactProvider(dataRoot)
                } else if contract.historicalCompatibility {
                    paths = try historicalPhaseArtifactPaths(
                        phaseID: phaseID,
                        dataRoot: dataRoot
                    )
                } else {
                    if phaseID == "project_init"
                        || phase.declaration.extensionArtifact != nil {
                        continue
                    }
                    throw PipelineExecutionPlanComposerError.invalidReference(
                        "phase artifact provider: \(phaseID)"
                    )
                }
                for path in paths where
                    !excludingPaths.contains(path) && selectedPaths.insert(path).inserted {
                    let digest = FileDigest.sha256(of: Data(path.utf8))
                    declarations.append((
                        "phase.\(phaseID).\(digest.prefix(16))",
                        "phase.\(phaseID)",
                        path
                    ))
                }
            }
        } else {
            for path in try packlessCoreArtifactPaths(dataRoot: dataRoot) where
                !excludingPaths.contains(path) && selectedPaths.insert(path).inserted {
                let digest = FileDigest.sha256(of: Data(path.utf8))
                declarations.append((
                    "core.artifact.\(digest.prefix(16))",
                    "core.pipeline-artifact",
                    path
                ))
            }
        }
        if selectedPaths.insert(shotlistPath).inserted {
            declarations.append((
                "shotlist",
                PipelineExecutionPlanWriter.shotlistArtifactRole,
                shotlistPath
            ))
        }
        var artifacts = try declarations.map { id, role, path in
            let projectURL = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
            return CanonicalArtifactReferenceV1(
                id: id,
                role: role,
                path: path,
                sha256: try FileDigest.sha256(of: projectURL)
            )
        }
        let inputURL = PipelineLayout.url(
            PipelineLayout.executionShotInputsFile,
            in: dataRoot
        )
        guard try Data(contentsOf: inputURL) == executionInputData else {
            throw PipelineExecutionPlanComposerError.invalidReference(
                PipelineLayout.executionShotInputsFile
            )
        }
        artifacts.append(CanonicalArtifactReferenceV1(
            id: PipelineExecutionShotInputStore.artifactID,
            role: PipelineExecutionShotInputStore.artifactRole,
            path: PipelineLayout.executionShotInputsFile,
            sha256: FileDigest.sha256(of: executionInputData)
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        artifacts.append(contentsOf: try templates.map { template in
            CanonicalArtifactReferenceV1(
                id: "production-input-template-\(template.shotID)",
                role: ProductionInputTemplateV1.artifactRole,
                path: PipelineLayout.productionInputTemplateFile(
                    shotID: template.shotID
                ),
                sha256: FileDigest.sha256(of: try encoder.encode(template))
            )
        })
        for entry in lineageSnapshots {
            let current = try entry.provider(dataRoot)
            guard current == entry.snapshot else {
                throw PipelineExecutionPlanComposerError.invalidReference(
                    "phase lineage changed while reading: \(entry.phaseID)"
                )
            }
            try PipelineLineageStore.requireCurrent(
                phase: entry.phaseID,
                snapshot: current,
                dataRoot: dataRoot
            )
        }
        return artifacts
    }

    private static func packlessCoreArtifactPaths(dataRoot: URL) throws -> [String] {
        var candidates = [
            PipelineLayout.briefFile,
            PipelineLayout.productionDesignFile,
            PipelineLayout.assetProofFile(scope: "production_design"),
            PipelineLayout.treatmentCurrentFile,
            PipelineLayout.storyboardCurrentFile,
            PipelineLayout.bibleFile,
            PipelineLayout.assetProofFile(scope: "bible"),
        ]
        if let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(
            dataRoot: dataRoot
        ) {
            candidates.append(try canonicalRelativePath(analysisURL, dataRoot: dataRoot))
            candidates.append(try canonicalRelativePath(
                analysisURL.deletingPathExtension()
                    .appendingPathExtension("measurement-proof.json"),
                dataRoot: dataRoot
            ))
        }
        if let version = TreatmentStore.versions(dataRoot: dataRoot).last {
            candidates.append(PipelineLayout.treatmentVersionFile(version))
        }
        let storyboardVersion = StoryboardStore.nextVersion(dataRoot: dataRoot) - 1
        if storyboardVersion > 0 {
            candidates.append(PipelineLayout.storyboardVersionFile(storyboardVersion))
        }
        var paths: [String] = []
        for path in candidates {
            do {
                _ = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
                paths.append(path)
            } catch ProjectLocalFileError.missingOrNonRegularFile(_) {
                continue
            }
        }
        return Array(Set(paths)).sorted()
    }

    private static func historicalPhaseArtifactPaths(
        phaseID: String,
        dataRoot: URL
    ) throws -> [String] {
        var paths: [String]
        switch phaseID {
        case "project_init":
            paths = [PipelineLayout.projectFile]
        case "analysis":
            paths = []
            if let analysisURL = AudioProjectLayout.expectedAnalysisArtifactURL(
                dataRoot: dataRoot
            ) {
                paths.append(try canonicalRelativePath(analysisURL, dataRoot: dataRoot))
                let proofURL = analysisURL.deletingPathExtension()
                    .appendingPathExtension("measurement-proof.json")
                let proofPath = try canonicalRelativePath(proofURL, dataRoot: dataRoot)
                do {
                    let safeProofURL = try ProjectLocalFile.resolve(
                        proofPath,
                        dataRoot: dataRoot
                    )
                    paths.append(proofPath)
                    let data = try Data(contentsOf: safeProofURL)
                    guard let object = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any],
                          let schema = object["schema"] as? String,
                          !schema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          object["project"] is String,
                          object["song_sha256"] is String else {
                        throw PipelineExecutionPlanComposerError.invalidReference(proofPath)
                    }
                    if let rawAlignment = object["lyrics_alignment"],
                       !(rawAlignment is NSNull) {
                        guard let alignment = rawAlignment as? [String: Any],
                              let sourcePath = alignment["source_path"] as? String,
                              !sourcePath.isEmpty else {
                            throw PipelineExecutionPlanComposerError.invalidReference(proofPath)
                        }
                        let sourceURL = try ProjectLocalFile.resolve(
                            sourcePath,
                            dataRoot: dataRoot
                        )
                        paths.append(try canonicalRelativePath(
                            sourceURL,
                            dataRoot: dataRoot
                        ))
                    }
                } catch ProjectLocalFileError.missingOrNonRegularFile(_) {
                    break
                }
            }
        case "brief":
            paths = [PipelineLayout.briefFile]
            let affectPath = "analysis/affect.json"
            do {
                _ = try ProjectLocalFile.resolve(affectPath, dataRoot: dataRoot)
                paths.append(affectPath)
            } catch ProjectLocalFileError.missingOrNonRegularFile(_) {
                break
            }
        case "production_design":
            paths = [
                PipelineLayout.productionDesignFile,
                PipelineLayout.assetProofFile(scope: "production_design"),
            ]
            let design = try YAMLArtifactStore(dataRoot: dataRoot).load(
                ProductionDesign.self,
                at: PipelineLayout.productionDesignFile
            )
            let references = design.refs.map(\.path) + [design.lightingAnchor].filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            paths += try references.map {
                try canonicalRelativePath(
                    ProjectLocalFile.resolve($0, dataRoot: dataRoot),
                    dataRoot: dataRoot
                )
            }
        case "treatment":
            paths = [PipelineLayout.treatmentCurrentFile]
            if let version = TreatmentStore.versions(dataRoot: dataRoot).last {
                paths.append(PipelineLayout.treatmentVersionFile(version))
            }
        case "storyboard":
            paths = [PipelineLayout.storyboardCurrentFile]
            let version = StoryboardStore.nextVersion(dataRoot: dataRoot) - 1
            if version > 0 {
                paths.append(PipelineLayout.storyboardVersionFile(version))
            }
        case "bible":
            paths = [
                PipelineLayout.bibleFile,
                PipelineLayout.assetProofFile(scope: "bible"),
            ]
            let bible = try YAMLArtifactStore(dataRoot: dataRoot).load(
                Bible.self,
                at: PipelineLayout.bibleFile
            )
            var references: [String] = []
            for entity in bible.characters {
                references += entity.referenceImages + Array(entity.sheets.values)
            }
            for entity in bible.ensembles {
                references += entity.referenceImages + Array(entity.sheets.values)
            }
            for entity in bible.props {
                references += entity.referenceImages + Array(entity.sheets.values)
            }
            for entity in bible.locations {
                references += entity.referenceImages + Array(entity.sheets.values)
                references += entity.zones.flatMap(\.bibleAssets)
                references += [entity.floorplan, entity.scene3d.panorama].filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            if !bible.look.lightingAnchor.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                references.append(bible.look.lightingAnchor)
            }
            paths += try references.map {
                try canonicalRelativePath(
                    ProjectLocalFile.resolve($0, dataRoot: dataRoot),
                    dataRoot: dataRoot
                )
            }
        default:
            paths = []
        }
        return Array(Set(paths)).sorted()
    }

    private static func canonicalExtensions(
        declaredPack: String?,
        dataRoot: URL
    ) throws -> [PackArtifactExtensionReferenceV1] {
        guard let contract = try PhaseContractRuntime.contract(activePack: declaredPack),
              let shotlistIndex = contract.order.firstIndex(of: "shotlist") else {
            return []
        }
        return try contract.order[..<shotlistIndex].compactMap { phaseID in
            guard let extensionArtifact = contract.phase(phaseID)?
                .declaration.extensionArtifact else {
                return nil
            }
            try GenericPhaseExtensionWriter.requireCurrent(
                contract: contract,
                phase: phaseID,
                dataRoot: dataRoot
            )
            let before = try GenericPhaseExtensionWriter.lineageSnapshot(
                contract: contract,
                phase: phaseID,
                dataRoot: dataRoot
            )
            let path = extensionArtifact.relativePath
            let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data)
            let fields = object as? [String: Any]
            guard let schema = (fields?["schema"] ?? fields?["schemaVersion"]) as? String,
                  !schema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PipelineExecutionPlanComposerError.invalidReference(path)
            }
            let reference = PackArtifactExtensionReferenceV1(
                id: "extension.\(phaseID)",
                schema: schema,
                path: path,
                sha256: FileDigest.sha256(of: data)
            )
            let after = try GenericPhaseExtensionWriter.lineageSnapshot(
                contract: contract,
                phase: phaseID,
                dataRoot: dataRoot
            )
            guard before == after else {
                throw PipelineExecutionPlanComposerError.invalidReference(
                    "phase lineage changed while reading: \(phaseID)"
                )
            }
            try GenericPhaseExtensionWriter.requireCurrent(
                contract: contract,
                phase: phaseID,
                dataRoot: dataRoot
            )
            return reference
        }
    }

    private static func appendProjectMedia(
        path: String,
        id: String,
        role: String,
        dataRoot: URL,
        to media: inout [ProjectMediaReferenceV1]
    ) throws {
        let url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        let canonicalPath = try canonicalRelativePath(url, dataRoot: dataRoot)
        guard !media.contains(where: { $0.path == canonicalPath }) else { return }
        media.append(ProjectMediaReferenceV1(
            id: id,
            role: role,
            path: canonicalPath,
            sha256: try FileDigest.sha256(of: url)
        ))
    }

    private static func makeAssetDraft(
        path: String,
        modality: AssetPhysicalModalityV1,
        entityID: String?,
        canonIDs: [String],
        stateID: String?,
        viewID: String?,
        allowedUseID: String?,
        dataRoot: URL
    ) throws -> AssetDraft {
        let url: URL
        do {
            url = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        } catch {
            throw PipelineExecutionPlanComposerError.invalidReference(path)
        }
        let canonicalPath = try canonicalRelativePath(url, dataRoot: dataRoot)
        let sha256 = try FileDigest.sha256(of: url)
        return AssetDraft(
            path: canonicalPath,
            sha256: sha256,
            modality: modality,
            entityID: entityID,
            canonIDs: canonIDs.sorted(),
            stateID: stateID,
            viewID: viewID,
            allowedUseIDs: Set([allowedUseID].compactMap { $0 })
        )
    }

    private static func merge(
        _ asset: AssetDraft,
        into assetsByPath: inout [String: AssetDraft]
    ) throws {
        guard var existing = assetsByPath[asset.path] else {
            assetsByPath[asset.path] = asset
            return
        }
        guard existing.sha256 == asset.sha256,
              existing.modality == asset.modality,
              existing.entityID == asset.entityID,
              existing.canonIDs.sorted() == asset.canonIDs.sorted(),
              existing.stateID == asset.stateID,
              existing.viewID == asset.viewID else {
            throw PipelineExecutionPlanComposerError.conflictingReference(asset.path)
        }
        existing.allowedUseIDs.formUnion(asset.allowedUseIDs)
        assetsByPath[asset.path] = existing
    }

    private static func assetIDsByShotID(
        _ pathsByShotID: [String: String],
        assetIDByPath: [String: String]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for (shotID, path) in pathsByShotID {
            guard let assetID = assetIDByPath[path] else {
                throw PipelineExecutionPlanComposerError.invalidReference(path)
            }
            result[shotID] = assetID
        }
        return result
    }

    private static func canonicalRelativePath(_ url: URL, dataRoot: URL) throws -> String {
        let file = url.standardizedFileURL
        let data = dataRoot.standardizedFileURL
        if file.path.hasPrefix(data.path + "/") {
            return String(file.path.dropFirst(data.path.count + 1))
        }
        let project = FrameInventory.projectHome(of: dataRoot).standardizedFileURL
        guard file.path.hasPrefix(project.path + "/") else {
            throw PipelineExecutionPlanComposerError.invalidReference(url.path)
        }
        return String(file.path.dropFirst(project.path.count + 1))
    }

    static func validateReferenceCorrespondence(
        shotID: String,
        referenceImageRefs: [String],
        referenceDemands: [PipelineReferenceDemandInput],
        dataRoot: URL
    ) throws {
        let shotPaths = try Set(referenceImageRefs.map {
            try canonicalReferencePath($0, dataRoot: dataRoot)
        })
        let demandPaths = try Set(referenceDemands.filter {
            $0.modality == .image
        }.map {
            try canonicalReferencePath($0.assetPath, dataRoot: dataRoot)
        })
        guard shotPaths == demandPaths else {
            throw PipelineExecutionPlanComposerError.referenceSetMismatch(shotID)
        }
    }

    static func identityAssetIDs(
        referenceDemands: [PipelineReferenceDemandInput],
        demandAssetIDs: [String: String]
    ) throws -> [String] {
        var identifiers = Set<String>()
        for demand in referenceDemands where demand.identityLock {
            guard let assetID = demandAssetIDs[demand.id] else {
                throw PipelineExecutionPlanComposerError.invalidReference(demand.id)
            }
            identifiers.insert(assetID)
        }
        return identifiers.sorted()
    }

    static func genericReferenceDemandIDs(
        _ referenceDemands: [PipelineReferenceDemandInput]
    ) -> [String] {
        referenceDemands.compactMap { demand in
            ProductionReferenceDemandSemanticsV1.isDedicated(
                semanticJobID: demand.semanticJobID
            ) ? nil : demand.id
        }
    }

    private static func canonicalReferencePath(
        _ path: String,
        dataRoot: URL
    ) throws -> String {
        do {
            return try canonicalRelativePath(
                ProjectLocalFile.resolve(path, dataRoot: dataRoot),
                dataRoot: dataRoot
            )
        } catch {
            throw PipelineExecutionPlanComposerError.invalidReference(path)
        }
    }

    private static func matches(
        sourceMode: SourceMode,
        executionMode: ExecutionSourceModeV1
    ) -> Bool {
        switch (sourceMode, executionMode) {
        case (.generated, .generated), (.imported, .imported),
             (.aiEnhanced, .aiEnhanced):
            return true
        default:
            return false
        }
    }
}
