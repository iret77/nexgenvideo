import Foundation
import NexGenEngine

enum MusicvideoProductionGate {
    static func requireCurrent(
        executionPlan: ExecutionPlanV1,
        shotlist: Shotlist,
        dataRoot: URL
    ) throws {
        guard appliesToCurrentProject(dataRoot: dataRoot) else { return }
        guard let version = latestShotlistVersion(dataRoot: dataRoot) else {
            throw GateBlocked("Can't approve \"shotlist\": no current Shot List version exists.")
        }
        let shotlistData = try Data(contentsOf: PipelineLayout.url(
            PipelineLayout.shotlistVersionFile(version),
            in: dataRoot
        ))
        let shotlistSHA256 = FileDigest.sha256(of: shotlistData)
        try requireConditioning(
            executionPlan: executionPlan,
            shotlist: shotlist,
            shotlistSHA256: shotlistSHA256,
            dataRoot: dataRoot
        )
        let setupIDs = try requireSpatialIfPresent(
            executionPlan: executionPlan,
            shotlist: shotlist,
            shotlistSHA256: shotlistSHA256,
            dataRoot: dataRoot
        )
        try requireMusicvideoPlan(
            executionPlan: executionPlan,
            shotlist: shotlist,
            shotlistSHA256: shotlistSHA256,
            setupIDs: setupIDs,
            dataRoot: dataRoot
        )
    }

    static func appliesToCurrentProject(dataRoot: URL) -> Bool {
        let url = FrameInventory.projectHome(of: dataRoot).appendingPathComponent("ngv.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["activePlugin"] as? String == "musicvideo",
              let rawVersion = object["activePluginVersion"] as? String,
              let version = semanticVersion(rawVersion) else {
            return false
        }
        return version.0 > 0
            || version.1 > 5
            || (version.1 == 5 && version.2 >= 8)
    }

    private static func semanticVersion(_ value: String) -> (Int, Int, Int)? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else { return nil }
        return (major, minor, patch)
    }

    private static func requireConditioning(
        executionPlan: ExecutionPlanV1,
        shotlist: Shotlist,
        shotlistSHA256: String,
        dataRoot: URL
    ) throws {
        let data = try extensionData(
            id: "core.conditioning-strategy.v1",
            schema: conditioningStrategyV1Schema,
            path: ConditioningStrategyPlanV1.relativePath,
            executionPlan: executionPlan,
            dataRoot: dataRoot
        )
        let plan = try ConditioningStrategyCanonicalCodecV1.decode(data)
        let expectedShotIDs = Set(executionPlan.shots.compactMap {
            $0.sourceMode == .imported ? nil : $0.id
        })
        guard plan.projectID == shotlist.project,
              plan.shotlistSHA256 == shotlistSHA256,
              Set(plan.strategies.map(\.shotID)) == expectedShotIDs else {
            throw GateBlocked(
                "Can't approve \"shotlist\": the conditioning strategy is stale or incomplete."
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
    }

    private static func requireSpatialIfPresent(
        executionPlan: ExecutionPlanV1,
        shotlist: Shotlist,
        shotlistSHA256: String,
        dataRoot: URL
    ) throws -> Set<String> {
        let ids = Set(executionPlan.extensionReferences.map(\.id))
        let spatialIDs: Set<String> = [
            "core.camera-setup-plan.v1",
            "core.shot-generation-cut-plan.v1",
            "core.state-ladder.v1",
            "core.layout-panels.v1",
            "core.blockout-proof.v1",
        ]
        guard !ids.isDisjoint(with: spatialIDs) else { return [] }
        let cameraData = try extensionData(
            id: "core.camera-setup-plan.v1",
            schema: CameraSetupPlanV1.schemaVersion,
            path: CameraSetupPlanV1.relativePath,
            executionPlan: executionPlan,
            dataRoot: dataRoot
        )
        let cutData = try extensionData(
            id: "core.shot-generation-cut-plan.v1",
            schema: ShotGenerationCutPlanV1.schemaVersion,
            path: ShotGenerationCutPlanV1.relativePath,
            executionPlan: executionPlan,
            dataRoot: dataRoot
        )
        let stateData = try extensionData(
            id: "core.state-ladder.v1",
            schema: StateLadderV1.schemaVersion,
            path: StateLadderV1.relativePath,
            executionPlan: executionPlan,
            dataRoot: dataRoot
        )
        let layoutData = try extensionData(
            id: "core.layout-panels.v1",
            schema: LayoutPanelsV1.schemaVersion,
            path: LayoutPanelsV1.relativePath,
            executionPlan: executionPlan,
            dataRoot: dataRoot
        )
        let camera = try JSONDecoder().decode(CameraSetupPlanV1.self, from: cameraData)
        let cut = try JSONDecoder().decode(ShotGenerationCutPlanV1.self, from: cutData)
        let state = try JSONDecoder().decode(StateLadderV1.self, from: stateData)
        let layout = try JSONDecoder().decode(LayoutPanelsV1.self, from: layoutData)
        let projectMatches = [camera.projectID, cut.projectID, state.projectID, layout.projectID]
            .allSatisfy { $0 == shotlist.project }
        let hashMatches = [
            camera.shotlistSHA256,
            cut.shotlistSHA256,
            state.shotlistSHA256,
            layout.shotlistSHA256,
        ].allSatisfy { $0 == shotlistSHA256 }
        guard projectMatches, hashMatches,
              Set(cut.shots.map(\.shotID)) == Set(shotlist.shots.map(\.id)) else {
            throw GateBlocked(
                "Can't approve \"shotlist\": the spatial production plan is stale or incomplete."
            )
        }
        let proofReference = executionPlan.extensionReferences.first {
            $0.id == "core.blockout-proof.v1"
        }
        let blockout: BlockoutRequestV1
        if let proofReference {
            let proofData = try extensionData(
                id: proofReference.id,
                schema: BlockoutProofV1.schemaVersion,
                path: BlockoutProofV1.relativePath,
                executionPlan: executionPlan,
                dataRoot: dataRoot
            )
            let proof = try JSONDecoder().decode(BlockoutProofV1.self, from: proofData)
            try SpatialProductionValidatorV1.validate(
                proof: proof,
                cameraSetupPlanData: cameraData,
                shotGenerationCutPlanData: cutData,
                stateLadderData: stateData,
                layoutPanelsData: layoutData,
                dataRoot: dataRoot
            )
            guard proof.projectID == shotlist.project,
                  proof.setupIDs == camera.setups.map(\.id),
                  proof.shapeIDs == layout.shapes.map(\.id),
                  proof.entityStateIDs == state.states.map(\.id) else {
                throw GateBlocked(
                    "Can't approve \"shotlist\": the blockout proof does not describe the current spatial plan."
                )
            }
            blockout = BlockoutRequestV1(
                mode: proof.sourceMode,
                importedClipPath: proof.sourceMode == .imported ? proof.clipPath : nil,
                width: proof.width,
                height: proof.height,
                fps: proof.fps,
                durationSeconds: proof.durationSeconds
            )
        } else {
            blockout = BlockoutRequestV1(
                mode: .none,
                width: 64,
                height: 64,
                fps: 1,
                durationSeconds: 1
            )
        }
        let draft = SpatialProductionPlanDraftV1(
            activation: camera.activation,
            setups: camera.setups,
            shots: cut.shots,
            states: state.states,
            layouts: layout.layouts,
            shapes: layout.shapes,
            panels: layout.panels,
            blockout: blockout
        )
        do {
            try SpatialProductionValidatorV1.validate(draft)
            for panel in layout.panels {
                _ = try ProjectLocalFile.requireHash(
                    panel.sha256,
                    at: panel.path,
                    dataRoot: dataRoot
                )
            }
            for item in state.states where item.stateSheetPath != nil {
                _ = try ProjectLocalFile.requireHash(
                    item.stateSheetSHA256!,
                    at: item.stateSheetPath!,
                    dataRoot: dataRoot
                )
            }
        } catch {
            throw GateBlocked(
                "Can't approve \"shotlist\": the spatial production plan is invalid (\(error))."
            )
        }
        return Set(camera.setups.map(\.id))
    }

    private static func requireMusicvideoPlan(
        executionPlan: ExecutionPlanV1,
        shotlist: Shotlist,
        shotlistSHA256: String,
        setupIDs: Set<String>,
        dataRoot: URL
    ) throws {
        let performanceData = try extensionData(
            id: "musicvideo.performance-binding.v1",
            schema: MusicPerformanceBindingV1.schemaVersion,
            path: MusicPerformanceBindingV1.relativePath,
            executionPlan: executionPlan,
            dataRoot: dataRoot
        )
        let arcData = try extensionData(
            id: "musicvideo.visual-arc.v1",
            schema: MusicVisualArcV1.schemaVersion,
            path: MusicVisualArcV1.relativePath,
            executionPlan: executionPlan,
            dataRoot: dataRoot
        )
        let coverageData = try extensionData(
            id: "musicvideo.performance-coverage.v1",
            schema: MusicPerformanceCoverageV1.schemaVersion,
            path: MusicPerformanceCoverageV1.relativePath,
            executionPlan: executionPlan,
            dataRoot: dataRoot
        )
        let performance = try JSONDecoder().decode(
            MusicPerformanceBindingV1.self,
            from: performanceData
        )
        let arc = try JSONDecoder().decode(MusicVisualArcV1.self, from: arcData)
        let coverage = try JSONDecoder().decode(
            MusicPerformanceCoverageV1.self,
            from: coverageData
        )
        let projectMatches = [performance.projectID, arc.projectID, coverage.projectID]
            .allSatisfy { $0 == shotlist.project }
        let hashMatches = [
            performance.shotlistSHA256,
            arc.shotlistSHA256,
            coverage.shotlistSHA256,
        ].allSatisfy { $0 == shotlistSHA256 }
        guard projectMatches, hashMatches,
              performance.trackPath == shotlist.song.audioPath,
              arc.analysisPath == shotlist.song.analysisPath,
              arc.treatmentPath == PipelineLayout.treatmentCurrentFile,
              arc.storyboardPath == PipelineLayout.storyboardCurrentFile else {
            throw GateBlocked(
                "Can't approve \"shotlist\": the Music Video production plan is stale."
            )
        }
        do {
            _ = try ProjectLocalFile.requireHash(
                performance.trackSHA256,
                at: performance.trackPath,
                dataRoot: dataRoot
            )
            _ = try ProjectLocalFile.requireHash(
                arc.analysisSHA256,
                at: arc.analysisPath,
                dataRoot: dataRoot
            )
            _ = try ProjectLocalFile.requireHash(
                arc.treatmentSHA256,
                at: arc.treatmentPath,
                dataRoot: dataRoot
            )
            _ = try ProjectLocalFile.requireHash(
                arc.storyboardSHA256,
                at: arc.storyboardPath,
                dataRoot: dataRoot
            )
            guard arc.trackSHA256 == performance.trackSHA256 else {
                throw MusicvideoProductionValidationErrorV1.sourceMismatch("track")
            }
            let shotIDs = Set(shotlist.shots.map(\.id))
            let sectionIDs = Set(shotlist.shots.compactMap(\.section))
            guard Set(arc.sections.map(\.sectionID)) == sectionIDs,
                  Set(arc.sections.flatMap(\.shotIDs)) == shotIDs,
                  arc.sections.flatMap(\.shotIDs).count == shotIDs.count,
                  arc.motifs.allSatisfy({ Set($0.setupIDs).isSubset(of: setupIDs) }),
                  coverage.items.flatMap(\.sectionIDs).allSatisfy({
                    sectionIDs.contains($0)
                  }) else {
                throw MusicvideoProductionValidationErrorV1.unknownReference("musicvideo")
            }
            let draft = MusicvideoProductionPlanDraftV1(
                performanceSegments: performance.segments.map(\.draft),
                finalMix: performance.finalMix,
                visualArc: MusicVisualArcDraftV1(
                    concept: arc.concept,
                    motifs: arc.motifs,
                    sections: arc.sections
                ),
                coverage: coverage.items
            )
            try MusicvideoProductionValidatorV1.validate(draft)
            let executionByID = Dictionary(uniqueKeysWithValues:
                executionPlan.shots.map { ($0.id, $0) }
            )
            for segment in performance.segments {
                let url = try ProjectLocalFile.requireHash(
                    segment.segmentSHA256,
                    at: segment.segmentPath,
                    dataRoot: dataRoot
                )
                let byteCount = (try FileManager.default.attributesOfItem(
                    atPath: url.path
                )[.size] as? NSNumber)?.int64Value
                guard segment.sourceTrackPath == performance.trackPath,
                      segment.sourceTrackSHA256 == performance.trackSHA256,
                      byteCount == segment.segmentByteCount,
                      segment.exportedSampleCount
                        == segment.draft.sourceEndSample - segment.draft.sourceStartSample else {
                    throw MusicvideoProductionValidationErrorV1.sourceMismatch(segment.draft.id)
                }
                if let path = segment.draft.lyricsAlignmentPath,
                   let hash = segment.draft.lyricsAlignmentSHA256 {
                    _ = try ProjectLocalFile.requireHash(hash, at: path, dataRoot: dataRoot)
                }
                for shotID in segment.draft.shotIDs {
                    guard let shot = executionByID[shotID] else {
                        throw MusicvideoProductionValidationErrorV1.unknownReference(shotID)
                    }
                    if shot.sourceMode != .imported {
                        let demands = try loadDemandSet(shotID: shotID, dataRoot: dataRoot)
                        guard demands.demands.contains(where: {
                            ProductionIdentifierNormalizerV1.matches(
                                $0.semanticJobID,
                                CoreReferenceSemanticJobIDV1.audioTiming
                            ) && ProductionIdentifierNormalizerV1.matches(
                                $0.inputSlotID,
                                segment.draft.routeInputRoleID
                            )
                        }) else {
                            throw MusicvideoProductionValidationErrorV1.sourceMismatch(shotID)
                        }
                    }
                }
            }
        } catch let blocked as GateBlocked {
            throw blocked
        } catch {
            throw GateBlocked(
                "Can't approve \"shotlist\": the Music Video production plan is invalid (\(error))."
            )
        }
    }

    private static func extensionData(
        id: String,
        schema: String,
        path: String,
        executionPlan: ExecutionPlanV1,
        dataRoot: URL
    ) throws -> Data {
        guard let reference = executionPlan.extensionReferences.first(where: { $0.id == id }),
              reference.schema == schema,
              reference.path == path else {
            throw GateBlocked(
                "Can't approve \"shotlist\": required extension \(id) is missing."
            )
        }
        let url = try ProjectLocalFile.requireHash(
            reference.sha256,
            at: reference.path,
            dataRoot: dataRoot
        )
        return try Data(contentsOf: url)
    }

    private static func loadDemandSet(
        shotID: String,
        dataRoot: URL
    ) throws -> ReferenceDemandSetV1 {
        let path = PipelineLayout.referenceDemandSetFile(shotID: shotID)
        let data = try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
        let value = try JSONDecoder().decode(ReferenceDemandSetV1.self, from: data)
        guard value.schema == referenceDemandSetV1Schema,
              value.shotID == shotID else {
            throw MusicvideoProductionValidationErrorV1.sourceMismatch(path)
        }
        return value
    }
}

enum MusicvideoAssemblyGate {
    static func requireCurrent(
        assembly: TimelineAssemblyProofV1,
        dataRoot: URL
    ) throws {
        guard MusicvideoProductionGate.appliesToCurrentProject(dataRoot: dataRoot) else {
            return
        }
        do {
            let performanceData = try read(
                MusicPerformanceBindingV1.relativePath,
                dataRoot: dataRoot
            )
            let coverageData = try read(
                MusicPerformanceCoverageV1.relativePath,
                dataRoot: dataRoot
            )
            let assemblyData = try read("assembly.json", dataRoot: dataRoot)
            let proofData = try read(MusicAssemblyProofV1.relativePath, dataRoot: dataRoot)
            let performance = try JSONDecoder().decode(
                MusicPerformanceBindingV1.self,
                from: performanceData
            )
            let coverage = try JSONDecoder().decode(
                MusicPerformanceCoverageV1.self,
                from: coverageData
            )
            let proof = try JSONDecoder().decode(MusicAssemblyProofV1.self, from: proofData)
            try MusicAssemblyProofValidatorV1.validate(proof)
            guard proof.projectID == assembly.project,
                  performance.projectID == assembly.project,
                  coverage.projectID == assembly.project,
                  proof.performanceBindingSHA256 == FileDigest.sha256(of: performanceData),
                  proof.coveragePlanSHA256 == FileDigest.sha256(of: coverageData),
                  proof.timelineAssemblySHA256 == FileDigest.sha256(of: assemblyData),
                  proof.originalSong.path == performance.trackPath,
                  proof.originalSong.sha256 == performance.trackSHA256,
                  proof.originalSong.startFrame
                    == Int((performance.finalMix.originalSongTimelineStartSeconds
                        * Double(assembly.timelineFPS)).rounded()),
                  proof.providerAudioSuppressed == performance.finalMix.providerSongAudioMuted,
                  assembly.audioTrackID != nil else {
                throw MusicvideoProductionValidationErrorV1.sourceMismatch("assembly")
            }
            _ = try ProjectLocalFile.requireHash(
                proof.originalSong.sha256,
                at: proof.originalSong.path,
                dataRoot: dataRoot
            )
            let additionalIDs = Set(proof.additionalAudioLayers.map(\.mediaID))
            guard additionalIDs.isSubset(
                of: Set(performance.finalMix.approvedAdditionalLayerIDs)
            ) else {
                throw MusicvideoProductionValidationErrorV1.sourceMismatch(
                    "assembly.audio_layers"
                )
            }
            for layer in proof.additionalAudioLayers {
                _ = try ProjectLocalFile.requireHash(
                    layer.sha256,
                    at: layer.path,
                    dataRoot: dataRoot
                )
            }

            let proofByKey = Dictionary(uniqueKeysWithValues: proof.roles.map {
                ($0.coverageID + ":" + $0.roleID, $0)
            })
            var expectedKeys = Set<String>()
            let placementsByShot = Dictionary(uniqueKeysWithValues:
                assembly.placements.map { ($0.shotID, $0) }
            )
            for item in coverage.items {
                let exceptions = Set(item.approvedExceptionRoleIDs)
                for roleID in item.requiredRoleIDs where !exceptions.contains(roleID) {
                    let key = item.id + ":" + roleID
                    expectedKeys.insert(key)
                    guard let evidence = item.evidence.first(where: {
                        $0.roleID == roleID
                    }),
                          let role = proofByKey[key],
                          role.assemblyRoleID == evidence.assemblyRoleID,
                          role.minimumContinuousSeconds
                            == evidence.minimumContinuousSeconds,
                          Set(role.shotIDs).isSubset(of: Set(evidence.shotIDs)),
                          !role.shotIDs.isEmpty else {
                        throw MusicvideoProductionValidationErrorV1.coverageMissing(key)
                    }
                    var longest = 0.0
                    for (shotID, clipID) in zip(role.shotIDs, role.clipIDs) {
                        guard let placement = placementsByShot[shotID],
                              placement.clipID == clipID else {
                            throw MusicvideoProductionValidationErrorV1.sourceMismatch(key)
                        }
                        let duration = Double(placement.durationFrames)
                            / Double(assembly.timelineFPS)
                        guard duration + 0.000_001 >= evidence.minimumContinuousSeconds else {
                            throw MusicvideoProductionValidationErrorV1.coverageMissing(key)
                        }
                        longest = max(longest, duration)
                    }
                    guard abs(longest - role.provedContinuousSeconds) < 0.000_001 else {
                        throw MusicvideoProductionValidationErrorV1.sourceMismatch(key)
                    }
                }
            }
            guard Set(proofByKey.keys) == expectedKeys else {
                throw MusicvideoProductionValidationErrorV1.sourceMismatch("assembly.roles")
            }
        } catch let blocked as GateBlocked {
            throw blocked
        } catch {
            throw GateBlocked(
                "Can't approve \"render\": the Music Video assembly proof is missing, stale, "
                    + "or incomplete (\(error))."
            )
        }
    }

    private static func read(_ path: String, dataRoot: URL) throws -> Data {
        try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
    }
}
