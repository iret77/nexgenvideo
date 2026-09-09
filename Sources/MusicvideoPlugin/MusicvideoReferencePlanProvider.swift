import Foundation
import NexGenEngine

/// The musicvideo pack's `ReferencePlanProviding` implementation — the live wire from the agent's
/// `next_render_shot` tool to the deterministic reference planner (#195). Resolves the project's bible,
/// shotlist, frames manifest, and image-model reference cap from the data root, then runs
/// `planShotRefsWithIdentityAnchors` so a shot renders with its bible sheets AND any inherited
/// identity-anchor frames stacked on top — the CORE multi-shot character-consistency lever
/// (CONCEPT §2/§4.1) that had no consumer before.
public struct MusicvideoReferencePlanProvider: ReferencePlanProviding, FrameReferencePlanProviding {
    public init() {}

    public func planReferences(dataRoot: URL, shotId: String) -> ReferencePlan? {
        let brief = try? YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile)
        let maxRefs = brief.flatMap { ImageModelCaps.maxReferenceImages($0.frameImageModel) }
            ?? ImageModelCaps.referenceFallback
        guard let exact = planFrameReferences(
            dataRoot: dataRoot,
            shotID: shotId,
            maxReferenceImages: maxRefs
        ) else { return nil }

        return ReferencePlan(
            refs: exact.bindings.map {
                ReferencePlan.Ref(
                    path: $0.path,
                    kind: $0.role,
                    view: $0.viewID,
                    score: Double($0.priority) / 1_000,
                    purpose: $0.purpose
                )
            },
            warnings: exact.deficits.map(\.detail)
                + exact.optionalDrops.map { "Optional reference omitted: \($0.role)/\($0.entityID)/\($0.viewID)." }
        )
    }

    public func planFrameReferences(
        dataRoot: URL,
        shotID: String,
        maxReferenceImages: Int
    ) -> FrameReferencePlanV1? {
        guard let shotlist = (try? loadShotlist(dataRoot: dataRoot)) ?? nil,
              let shot = shotlist.shots.first(where: { $0.id == shotID }),
              let bible = (try? loadBible(dataRoot: dataRoot)) ?? nil else { return nil }
        let planned = ReferencePlanner.planShotRefsWithIdentityAnchors(
            projectDir: dataRoot,
            bible: bible,
            shot: shot,
            shotlist: shotlist,
            framesManifest: try? loadFramesManifest(dataRoot: dataRoot),
            maxRefs: maxReferenceImages,
            framesBase: FrameInventory.projectHome(of: dataRoot)
        )
        var hashDeficits: [FrameReferenceDeficitV1] = []
        func binding(_ source: ReferencePlanner.RefSource) -> FrameReferenceBindingV1? {
            do {
                let url = try ProjectLocalFile.resolve(source.path, dataRoot: dataRoot)
                return FrameReferenceBindingV1(
                    path: source.path,
                    sha256: try FileDigest.sha256(of: url),
                    role: source.entityKind,
                    entityID: source.entityId,
                    viewID: source.view,
                    purpose: source.purpose,
                    requirementIDs: source.requirementIDs,
                    isRequired: source.isRequired,
                    priority: Int((source.score * 1_000).rounded())
                )
            } catch {
                if source.isRequired {
                    hashDeficits.append(FrameReferenceDeficitV1(
                        requirementID: source.requirementIDs.joined(separator: ","),
                        detail: "The required reference '\(source.path)' is not a readable project image."
                    ))
                }
                return nil
            }
        }
        let bindings = planned.refs.compactMap(binding)
        let optionalDrops = planned.dropped.compactMap(binding)
        return FrameReferencePlanV1(
            shotID: shotID,
            maxReferenceImages: maxReferenceImages,
            bindings: bindings,
            optionalDrops: optionalDrops,
            deficits: planned.deficits + hashDeficits
        )
    }
}
