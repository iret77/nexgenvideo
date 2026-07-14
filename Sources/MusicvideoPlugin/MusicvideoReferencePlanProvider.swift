import Foundation
import NexGenEngine

/// The musicvideo pack's `ReferencePlanProviding` implementation — the live wire from the agent's
/// `next_render_shot` tool to the deterministic reference planner (#195). Resolves the project's bible,
/// shotlist, frames manifest, and image-model reference cap from the data root, then runs
/// `planShotRefsWithIdentityAnchors` so a shot renders with its bible sheets AND any inherited
/// identity-anchor frames stacked on top — the CORE multi-shot character-consistency lever
/// (CONCEPT §2/§4.1) that had no consumer before.
public struct MusicvideoReferencePlanProvider: ReferencePlanProviding {
    public init() {}

    public func planReferences(dataRoot: URL, shotId: String) -> ReferencePlan? {
        guard let shotlist = (try? loadShotlist(dataRoot: dataRoot)) ?? nil,
              let shot = shotlist.shots.first(where: { $0.id == shotId }),
              let bible = (try? loadBible(dataRoot: dataRoot)) ?? nil else { return nil }

        let brief = try? YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
        let maxRefs = brief.flatMap { ImageModelCaps.maxReferenceImages($0.frameImageModel) }
            ?? ImageModelCaps.referenceFallback
        let framesManifest = try? loadFramesManifest(dataRoot: dataRoot)

        let planned = ReferencePlanner.planShotRefsWithIdentityAnchors(
            projectDir: dataRoot, bible: bible, shot: shot, shotlist: shotlist,
            framesManifest: framesManifest, maxRefs: maxRefs,
            framesBase: FrameInventory.projectHome(of: dataRoot))

        return ReferencePlan(
            refs: planned.refs.map {
                ReferencePlan.Ref(path: $0.path, kind: $0.entityKind, view: $0.view,
                                  score: $0.score, purpose: $0.purpose)
            },
            warnings: planned.warnings)
    }
}
