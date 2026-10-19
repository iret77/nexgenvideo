import Foundation
import NexGenEngine

enum PipelineShotPlanningWriter {
    static func write(shots: [ShotPlanningDraftV1.ShotIntent], origin: PlanningArtifactHeaderV1.Origin,
                      access: PipelinePlanningWriteAccess) throws -> ShotPlanningDraftV1 {
        guard access.phase == "shot_planning" else { throw GateBlocked("Shot planning has a different phase owner.") }
        let root = access.dataRoot
        let storyboard = try PlanningWriterIO.storyboard(dataRoot: root)
        let revision = try PlanningWriterIO.nextRevision(directory: "shot-planning", suffix: ".v1.json", dataRoot: root)
        if origin == .agentProposal || origin == .agentRevision {
            let previous: ShotPlanningDraftV1?
            if revision > 1 { previous = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: storyboard) }
            else { previous = nil }
            for shot in shots {
                let selected = previous?.shots.first { $0.shotID == shot.shotID }
                guard shot.sourceInputRange == selected?.sourceInputRange,
                      shot.camera.spatialState == selected?.camera.spatialState,
                      shot.camera.spatialCameraID == selected?.camera.spatialCameraID,
                      shot.camera.spatialDerivation == selected?.camera.spatialDerivation,
                      shot.camera.blockingReference == selected?.camera.blockingReference else {
                    throw GateBlocked("Only native controls can choose or change source timing and verified spatial camera state. Preserve the current confirmed selections.")
                }
            }
        }
        let inputs = try currentInputs(shots: shots, storyboard: storyboard, dataRoot: root)
        let draft = ShotPlanningDraftV1(header: .init(projectID: storyboard.storyboard.header.projectID,
            revision: revision, origin: origin, inputs: inputs),
            storyboardRevision: storyboard.storyboard.header.revision, shots: shots)
        try ShotPlanningValidatorV1.validate(draft, timing: storyboard.timing)
        for shot in shots {
            for source in [shot.source, shot.camera.sceneReference, shot.camera.spatialState].compactMap({ $0 }) {
                _ = try ProjectLocalFile.requireHash(source.sha256, at: source.path, dataRoot: root)
            }
        }
        let bytes = try PlanningWriterIO.json(draft)
        try access.publish([(ShotPlanningDraftV1.versionPath(revision), bytes), (ShotPlanningDraftV1.currentPath, bytes)]) {
            let saved = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: storyboard)
            try requireSpatialInputs(saved, dataRoot: root)
        }
        return draft
    }

    static func requireSpatialInputs(_ draft: ShotPlanningDraftV1, dataRoot: URL) throws {
        for shot in draft.shots {
            if let blocking = shot.camera.blockingReference {
                let refs = try PipelineNativeBlockoutStore.references(blocking, shot: shot, dataRoot: dataRoot)
                guard refs.allSatisfy({ ref in draft.header.inputs.contains { $0.path == ref.path && $0.sha256 == ref.sha256 } }) else {
                    throw GateBlocked("Shot Planning does not bind its complete native blockout evidence.")
                }
            }
            guard let state = shot.camera.spatialState else { continue }
            guard let cameraID = shot.camera.spatialCameraID, let scene = shot.camera.sceneReference else {
                throw GateBlocked("A spatial shot needs its verified scene, camera and frame state.")
            }
            _ = try PipelineSpatialDerivationWriter.requirePlanningState(reference: state, cameraID: cameraID,
                sceneReference: scene, shotID: shot.shotID, dataRoot: dataRoot)
            var refs = try PipelineSpatialDerivationWriter.planningStateReferences(reference: state, cameraID: cameraID,
                sceneReference: scene, shotID: shot.shotID, dataRoot: dataRoot)
            if let derivation = shot.camera.spatialDerivation {
                refs += [derivation] + (try PipelineSpatialDerivationWriter.planningDerivationReferences(reference: derivation,
                    stateReference: state, cameraID: cameraID, sceneReference: scene, shotID: shot.shotID, dataRoot: dataRoot))
            }
            guard ([scene, state] + refs).allSatisfy({ reference in
                draft.header.inputs.contains(where: { $0.path == reference.path && $0.sha256 == reference.sha256 })
            }) else {
                throw GateBlocked("Shot planning does not bind the complete verified spatial source and camera state.")
            }
        }
    }

    static func currentInputs(shots: [ShotPlanningDraftV1.ShotIntent], storyboard: StoryboardBundleSnapshot,
                                      dataRoot: URL) throws -> [CanonicalArtifactReferenceV1] {
        var refs = storyboard.references
        for shot in shots {
            refs += [shot.source, shot.camera.sceneReference, shot.camera.spatialState, shot.camera.spatialDerivation, shot.camera.blockingReference].compactMap { $0 }
            if let blocking = shot.camera.blockingReference {
                refs += try PipelineNativeBlockoutStore.references(blocking, shot: shot, dataRoot: dataRoot)
            }
            if let state = shot.camera.spatialState {
                guard let cameraID = shot.camera.spatialCameraID, let scene = shot.camera.sceneReference else {
                    throw GateBlocked("A spatial shot needs its verified scene, camera and frame state.")
                }
                _ = try PipelineSpatialDerivationWriter.requirePlanningState(reference: state, cameraID: cameraID,
                    sceneReference: scene, shotID: shot.shotID, dataRoot: dataRoot)
                refs += try PipelineSpatialDerivationWriter.planningStateReferences(reference: state, cameraID: cameraID,
                    sceneReference: scene, shotID: shot.shotID, dataRoot: dataRoot)
                if let derivation = shot.camera.spatialDerivation {
                    refs += try PipelineSpatialDerivationWriter.planningDerivationReferences(reference: derivation,
                        stateReference: state, cameraID: cameraID, sceneReference: scene, shotID: shot.shotID, dataRoot: dataRoot)
                }
            }
        }
        var result: [CanonicalArtifactReferenceV1] = []
        for ref in refs {
            if let existing = result.first(where: { $0.path == ref.path }) {
                guard existing.sha256 == ref.sha256 else { throw GateBlocked("Shot planning has conflicting source bytes.") }
                continue
            }
            result.append(ref)
        }
        return result
    }

}
