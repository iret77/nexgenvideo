import Foundation
import NexGenEngine

enum PipelineSpatialProductionWriter {
    static let extensionIDs: [(String, String, String)] = [
        ("core.camera-setup-plan.v1", CameraSetupPlanV1.schemaVersion, CameraSetupPlanV1.relativePath),
        ("core.shot-generation-cut-plan.v1", ShotGenerationCutPlanV1.schemaVersion, ShotGenerationCutPlanV1.relativePath),
        ("core.state-ladder.v1", StateLadderV1.schemaVersion, StateLadderV1.relativePath),
        ("core.layout-panels.v1", LayoutPanelsV1.schemaVersion, LayoutPanelsV1.relativePath),
        ("core.blockout-proof.v1", BlockoutProofV1.schemaVersion, BlockoutProofV1.relativePath),
    ]

    struct Snapshot {
        let files: [String: Data]
        let existingPaths: Set<String>
    }

    static func write(
        _ draft: SpatialProductionPlanDraftV1?,
        shotlist: Shotlist,
        shotlistData: Data,
        executionInputs: [PipelineExecutionShotInput],
        dataRoot: URL
    ) throws {
        guard let draft else {
            try clear(dataRoot: dataRoot)
            return
        }
        try SpatialProductionValidatorV1.validate(draft)
        let shotIDs = Set(shotlist.shots.map(\.id))
        guard Set(draft.shots.map(\.shotID)) == shotIDs else {
            throw SpatialProductionValidationErrorV1.invalidField("shots.shot_id")
        }
        guard let storyboard = try StoryboardStore.load(
            dataRoot: dataRoot,
            version: .current
        ) else {
            throw SpatialProductionValidationErrorV1.invalidField("storyboard")
        }
        let visibleBeatIDs = Set(storyboard.sections.flatMap(\.steps).map(\.id))
        guard draft.states.allSatisfy({ visibleBeatIDs.contains($0.causeBeatID) }) else {
            throw SpatialProductionValidationErrorV1.invalidField("states.cause_beat_id")
        }
        let inputs = Dictionary(uniqueKeysWithValues: executionInputs.map { ($0.id, $0) })
        for planned in draft.shots {
            guard let input = inputs[planned.shotID],
                  input.startState.entityStateIDs.contains(planned.startStateID),
                  input.endState.entityStateIDs.contains(planned.endStateID),
                  Set(planned.timedReferences.map(\.demandID))
                    .isSubset(of: Set(input.referenceDemands.map(\.id))) else {
                throw SpatialProductionValidationErrorV1.invalidField(
                    "shots[\(planned.shotID)]"
                )
            }
        }
        for panel in draft.panels {
            _ = try ProjectLocalFile.requireHash(panel.sha256, at: panel.path, dataRoot: dataRoot)
        }
        for state in draft.states where state.stateSheetPath != nil {
            _ = try ProjectLocalFile.requireHash(
                state.stateSheetSHA256!,
                at: state.stateSheetPath!,
                dataRoot: dataRoot
            )
        }
        if draft.activation.requiresBlockout, draft.panels.isEmpty {
            throw SpatialProductionValidationErrorV1.invalidField("panels")
        }

        let shotlistSHA256 = FileDigest.sha256(of: shotlistData)
        let cameraPlan = CameraSetupPlanV1(
            projectID: shotlist.project,
            shotlistSHA256: shotlistSHA256,
            activation: draft.activation,
            setups: draft.setups
        )
        let cutPlan = ShotGenerationCutPlanV1(
            projectID: shotlist.project,
            shotlistSHA256: shotlistSHA256,
            shots: draft.shots
        )
        let stateLadder = StateLadderV1(
            projectID: shotlist.project,
            shotlistSHA256: shotlistSHA256,
            states: draft.states
        )
        let layoutPanels = LayoutPanelsV1(
            projectID: shotlist.project,
            shotlistSHA256: shotlistSHA256,
            layouts: draft.layouts,
            panels: draft.panels
        )
        let cameraData = try canonicalData(cameraPlan)
        let cutData = try canonicalData(cutPlan)
        let stateData = try canonicalData(stateLadder)
        let layoutData = try canonicalData(layoutPanels)
        try write(cameraData, path: CameraSetupPlanV1.relativePath, dataRoot: dataRoot)
        try write(cutData, path: ShotGenerationCutPlanV1.relativePath, dataRoot: dataRoot)
        try write(stateData, path: StateLadderV1.relativePath, dataRoot: dataRoot)
        try write(layoutData, path: LayoutPanelsV1.relativePath, dataRoot: dataRoot)

        guard draft.blockout.mode != .none else {
            try remove(path: BlockoutProofV1.relativePath, dataRoot: dataRoot)
            return
        }
        var identityData = cameraData
        identityData.append(cutData)
        identityData.append(stateData)
        identityData.append(layoutData)
        let clipPath: String
        let clipURL: URL
        switch draft.blockout.mode {
        case .native:
            clipPath = "\(PipelineLayout.blockoutDir)/blockout-\(FileDigest.sha256(of: identityData).prefix(20)).mov"
            clipURL = PipelineLayout.url(clipPath, in: dataRoot)
            try NativeBlockoutExporter.export(
                setups: draft.setups,
                request: draft.blockout,
                to: clipURL
            )
        case .imported:
            guard let path = draft.blockout.importedClipPath,
                  path.lowercased().hasSuffix(".mov") else {
                throw SpatialProductionValidationErrorV1.invalidField(
                    "blockout.imported_clip_path"
                )
            }
            clipPath = path
            clipURL = try ProjectLocalFile.resolve(path, dataRoot: dataRoot)
        case .none:
            fatalError("handled above")
        }
        let proof = BlockoutProofV1(
            projectID: shotlist.project,
            sourceMode: draft.blockout.mode,
            cameraSetupPlanSHA256: FileDigest.sha256(of: cameraData),
            shotGenerationCutPlanSHA256: FileDigest.sha256(of: cutData),
            stateLadderSHA256: FileDigest.sha256(of: stateData),
            layoutPanelsSHA256: FileDigest.sha256(of: layoutData),
            clipPath: clipPath,
            clipSHA256: try FileDigest.sha256(of: clipURL),
            container: "quicktime",
            width: draft.blockout.width,
            height: draft.blockout.height,
            fps: draft.blockout.fps,
            durationSeconds: draft.blockout.durationSeconds,
            setupIDs: draft.setups.map(\.id),
            entityStateIDs: draft.states.map(\.id)
        )
        let proofData = try canonicalData(proof)
        try write(proofData, path: BlockoutProofV1.relativePath, dataRoot: dataRoot)
        try SpatialProductionValidatorV1.validate(
            proof: proof,
            cameraSetupPlanData: cameraData,
            shotGenerationCutPlanData: cutData,
            stateLadderData: stateData,
            layoutPanelsData: layoutData,
            dataRoot: dataRoot
        )
    }

    static func requireCurrent(dataRoot: URL) throws -> [PackArtifactExtensionReferenceV1] {
        let cameraData = try read(CameraSetupPlanV1.relativePath, dataRoot: dataRoot)
        let cutData = try read(ShotGenerationCutPlanV1.relativePath, dataRoot: dataRoot)
        let stateData = try read(StateLadderV1.relativePath, dataRoot: dataRoot)
        let layoutData = try read(LayoutPanelsV1.relativePath, dataRoot: dataRoot)
        let camera = try JSONDecoder().decode(CameraSetupPlanV1.self, from: cameraData)
        let cut = try JSONDecoder().decode(ShotGenerationCutPlanV1.self, from: cutData)
        let state = try JSONDecoder().decode(StateLadderV1.self, from: stateData)
        let layout = try JSONDecoder().decode(LayoutPanelsV1.self, from: layoutData)
        guard let shotlist = try loadShotlist(dataRoot: dataRoot),
              let version = latestShotlistVersion(dataRoot: dataRoot) else {
            throw SpatialProductionValidationErrorV1.staleProof("shotlist")
        }
        let shotlistData = try Data(contentsOf: PipelineLayout.url(
            PipelineLayout.shotlistVersionFile(version),
            in: dataRoot
        ))
        let expected = FileDigest.sha256(of: shotlistData)
        guard camera.schema == CameraSetupPlanV1.schemaVersion,
              cut.schema == ShotGenerationCutPlanV1.schemaVersion,
              state.schema == StateLadderV1.schemaVersion,
              layout.schema == LayoutPanelsV1.schemaVersion,
              camera.projectID == shotlist.project,
              cut.projectID == shotlist.project,
              state.projectID == shotlist.project,
              layout.projectID == shotlist.project,
              camera.shotlistSHA256 == expected,
              cut.shotlistSHA256 == expected,
              state.shotlistSHA256 == expected,
              layout.shotlistSHA256 == expected else {
            throw SpatialProductionValidationErrorV1.staleProof("shotlist")
        }
        let draft = SpatialProductionPlanDraftV1(
            activation: camera.activation,
            setups: camera.setups,
            shots: cut.shots,
            states: state.states,
            layouts: layout.layouts,
            panels: layout.panels,
            blockout: BlockoutRequestV1(
                mode: .native,
                width: 64,
                height: 64,
                fps: 1,
                durationSeconds: 1
            )
        )
        try SpatialProductionValidatorV1.validate(draft)
        var refs = try extensionIDs.prefix(4).map { entry in
            let data = try read(entry.2, dataRoot: dataRoot)
            return PackArtifactExtensionReferenceV1(
                id: entry.0,
                schema: entry.1,
                path: entry.2,
                sha256: FileDigest.sha256(of: data)
            )
        }
        let proofURL = PipelineLayout.url(BlockoutProofV1.relativePath, in: dataRoot)
        if FileManager.default.fileExists(atPath: proofURL.path) {
            let proofData = try Data(contentsOf: proofURL)
            let proof = try JSONDecoder().decode(BlockoutProofV1.self, from: proofData)
            try SpatialProductionValidatorV1.validate(
                proof: proof,
                cameraSetupPlanData: cameraData,
                shotGenerationCutPlanData: cutData,
                stateLadderData: stateData,
                layoutPanelsData: layoutData,
                dataRoot: dataRoot
            )
            let entry = extensionIDs[4]
            refs.append(PackArtifactExtensionReferenceV1(
                id: entry.0,
                schema: entry.1,
                path: entry.2,
                sha256: FileDigest.sha256(of: proofData)
            ))
        } else if camera.activation.requiresBlockout {
            throw SpatialProductionValidationErrorV1.blockoutRequired
        }
        return refs
    }

    static func snapshot(dataRoot: URL) throws -> Snapshot {
        var files: [String: Data] = [:]
        for (_, _, path) in extensionIDs {
            let url = PipelineLayout.url(path, in: dataRoot)
            if FileManager.default.fileExists(atPath: url.path) {
                files[path] = try Data(contentsOf: url)
            }
        }
        let directory = PipelineLayout.url(PipelineLayout.blockoutDir, in: dataRoot)
        let existing = Set((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).map(\.path)) ?? [])
        return Snapshot(files: files, existingPaths: existing)
    }

    static func loadDraftIfPresent(
        dataRoot: URL
    ) throws -> SpatialProductionPlanDraftV1? {
        let url = PipelineLayout.url(CameraSetupPlanV1.relativePath, in: dataRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        _ = try requireCurrent(dataRoot: dataRoot)
        let camera = try JSONDecoder().decode(
            CameraSetupPlanV1.self,
            from: read(CameraSetupPlanV1.relativePath, dataRoot: dataRoot)
        )
        let cut = try JSONDecoder().decode(
            ShotGenerationCutPlanV1.self,
            from: read(ShotGenerationCutPlanV1.relativePath, dataRoot: dataRoot)
        )
        let state = try JSONDecoder().decode(
            StateLadderV1.self,
            from: read(StateLadderV1.relativePath, dataRoot: dataRoot)
        )
        let layout = try JSONDecoder().decode(
            LayoutPanelsV1.self,
            from: read(LayoutPanelsV1.relativePath, dataRoot: dataRoot)
        )
        let proofURL = PipelineLayout.url(BlockoutProofV1.relativePath, in: dataRoot)
        let blockout: BlockoutRequestV1
        if FileManager.default.fileExists(atPath: proofURL.path) {
            let proof = try JSONDecoder().decode(
                BlockoutProofV1.self,
                from: Data(contentsOf: proofURL)
            )
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
        return SpatialProductionPlanDraftV1(
            activation: camera.activation,
            setups: camera.setups,
            shots: cut.shots,
            states: state.states,
            layouts: layout.layouts,
            panels: layout.panels,
            blockout: blockout
        )
    }

    static func restore(_ snapshot: Snapshot, dataRoot: URL) throws {
        for (_, _, path) in extensionIDs {
            if let data = snapshot.files[path] {
                try write(data, path: path, dataRoot: dataRoot)
            } else {
                try remove(path: path, dataRoot: dataRoot)
            }
        }
        let directory = PipelineLayout.url(PipelineLayout.blockoutDir, in: dataRoot)
        for url in (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [] where !snapshot.existingPaths.contains(url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func clear(dataRoot: URL) throws {
        for (_, _, path) in extensionIDs { try remove(path: path, dataRoot: dataRoot) }
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func read(_ path: String, dataRoot: URL) throws -> Data {
        try Data(contentsOf: ProjectLocalFile.resolve(path, dataRoot: dataRoot))
    }

    private static func write(_ data: Data, path: String, dataRoot: URL) throws {
        let url = PipelineLayout.url(path, in: dataRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func remove(path: String, dataRoot: URL) throws {
        let url = PipelineLayout.url(path, in: dataRoot)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
