import Foundation
import NexGenEngine

enum PipelineShotPlanningWriter {
    static func write(shots: [ShotPlanningDraftV1.ShotIntent], origin: PlanningArtifactHeaderV1.Origin,
                      access: PipelinePlanningWriteAccess) throws -> ShotPlanningDraftV1 {
        guard access.phase == "shot_planning" else { throw GateBlocked("Shot planning has a different phase owner.") }
        let root = access.dataRoot
        let storyboard = try PlanningWriterIO.storyboard(dataRoot: root)
        let revision = try PlanningWriterIO.nextRevision(directory: "shot-planning", suffix: ".v1.json", dataRoot: root)
        let draft = ShotPlanningDraftV1(header: .init(projectID: storyboard.storyboard.header.projectID,
            revision: revision, origin: origin, inputs: storyboard.references),
            storyboardRevision: storyboard.storyboard.header.revision, shots: shots)
        try ShotPlanningValidatorV1.validate(draft, timing: storyboard.timing)
        for shot in shots {
            for source in [shot.source, shot.camera.sceneReference].compactMap({ $0 }) {
                _ = try ProjectLocalFile.requireHash(source.sha256, at: source.path, dataRoot: root)
            }
        }
        let bytes = try PlanningWriterIO.json(draft)
        try access.publish([(ShotPlanningDraftV1.versionPath(revision), bytes), (ShotPlanningDraftV1.currentPath, bytes)]) {
            _ = try ProductionPlanningStoreV1.readShotPlanning(dataRoot: root, storyboard: storyboard)
        }
        return draft
    }
}
