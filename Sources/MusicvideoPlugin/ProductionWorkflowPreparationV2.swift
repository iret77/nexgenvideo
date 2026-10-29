import Foundation
import NexGenEngine

enum MusicvideoProductionPreparationV2 {
    static func frames(dataRoot: URL) throws {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let frames = try loadFramesManifest(dataRoot: dataRoot)
        guard frames == (try frames.reconciled(with: projection, generated: frames.generated)), frames.project == projection.header.projectID else {
            throw GateBlocked("The host must reconcile Frames against the approved production plan first.")
        }
        let renders = try loadRenderManifest(dataRoot: dataRoot, phase: "frames")
        guard renders.project == projection.header.projectID, renders.phase == "frames",
              Set(renders.entries.keys).isSubset(of: Set(frames.shots.map(\.shotId))) else {
            throw GateBlocked("The Frames publication belongs to another production plan.")
        }
    }

    static func render(dataRoot: URL) throws {
        let projection = try ProductionPlanningLineageV2.projection(dataRoot: dataRoot)
        let manifest = try loadRenderManifest(dataRoot: dataRoot, phase: "final")
        let eligible = Set(projection.shots.filter { $0.sourceMode != .imported }.map(\.id))
        guard manifest.project == projection.header.projectID, manifest.phase == "final",
              Set(manifest.entries.keys).isSubset(of: eligible) else {
            throw GateBlocked("The final render manifest must match the exact approved production plan.")
        }
    }
}
