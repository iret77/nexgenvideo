import Foundation
import NexGenEngine

/// #231 — the consistency levers of #195/#196 end in JSON handed to the LLM, and nothing compared the
/// plan with the render. `next_render_shot` *offers* the reference plan and the chain start frame;
/// `render.md` *asks* the agent to pass them on. This audits the result instead of trusting the request.
///
/// Same seam and same shape as `builderBypassCheck`: re-run the deterministic machinery at audit time
/// and compare it against what the manifests recorded. Every planner involved is pure, so the plan a
/// check reconstructs is the plan `next_render_shot` handed out. Degrades to no findings whenever the
/// data root, a manifest, or the recorded conditioning is absent — an un-rendered project is not a
/// violation, and entries written before the audit fields existed carry nil, not a false accusation.
///
/// The third silent degradation (#197, `compile_prompt` without a `shotId`) is NOT audited here: it is
/// prevented at the tool contract instead — `shotId` is required and `"none"` is an explicit choice, so
/// the mistake can no longer be made by omission. Inferring it from prompt text was tried and dropped:
/// an agent that omits `shotId` but happens to phrase the camera the same way would pass the audit, so
/// the check could be satisfied by accident — the same "please" it set out to replace.
extension MusicvideoChecks {
    /// PLAN_REFS_IGNORED / CHAIN_START_FRAME_IGNORED.
    public static let planAdherenceCheck: SanityCheck = { ctx in
        guard let root = ctx.extra?["data_root"] else { return [] }
        let dataRoot = URL(fileURLWithPath: root)
        let planner = MusicvideoReferencePlanProvider()
        // One shot renders in at most one phase per project state, but several phase manifests coexist
        // on disk (a `videos_preview` and a `videos_final` both linger). Dedupe by finding identity so a
        // single underlying violation is reported once, not once per manifest.
        var seen = Set<String>()
        var out: [Finding] = []
        for phase in renderPhases(dataRoot: dataRoot) {
            guard let manifest = try? loadRenderManifest(dataRoot: dataRoot, phase: phase) else { continue }
            for finding in adherence(ctx, dataRoot: dataRoot, manifest: manifest, planner: planner) {
                let key = "\(finding.code)|\(finding.shotId ?? "")|\(finding.message)"
                if seen.insert(key).inserted { out.append(finding) }
            }
        }
        return out
    }

    /// Every render-manifest phase present on disk. The phase is a free string the agent passes to
    /// `next_render_shot` (`videos_preview`, `videos_final`, …) — never a fixed set — and
    /// `loadRenderManifest` answers a missing file with an EMPTY manifest rather than an error, so
    /// naming a phase that doesn't exist would audit nothing and report success. Discover them instead.
    private static func renderPhases(dataRoot: URL) -> [String] {
        let dir = PipelineLayout.url(PipelineLayout.rendersDir, in: dataRoot)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix("manifest-"), name.hasSuffix(".json") else { return nil }
            return String(name.dropFirst("manifest-".count).dropLast(".json".count))
        }.sorted()
    }

    /// Do two recorded/planned paths name the same file? They arrive in different coordinate systems —
    /// planned paths are project-relative, recorded ones are project-home-relative — so one may carry a
    /// prefix the other doesn't. Match on whole path COMPONENTS: a bare `hasSuffix` is byte-level, and
    /// would call `banana.png` a match for `a.png`, hiding a genuinely missing reference.
    private static func samePath(_ a: String, _ b: String) -> Bool {
        let x = (a as NSString).pathComponents, y = (b as NSString).pathComponents
        guard !x.isEmpty, !y.isEmpty else { return false }
        let depth = Swift.min(x.count, y.count)
        return Array(x.suffix(depth)) == Array(y.suffix(depth))
    }

    private static func adherence(
        _ ctx: AuditContext, dataRoot: URL, manifest: RenderManifest,
        planner: MusicvideoReferencePlanProvider
    ) -> [Finding] {
        var out: [Finding] = []

        for shot in ctx.shotlist.shots {
            guard let entry = manifest.entries[shot.id], entry.status == .rendered else { continue }

            // A render recorded before the conditioning fields existed (or one whose output asset
            // couldn't be resolved) carries no actuals — unknown, not violated.
            if let recorded = entry.referencePaths,
               let plan = planner.planReferences(dataRoot: dataRoot, shotId: shot.id), !plan.refs.isEmpty {
                let planned = plan.refs.map(\.path)
                let missing = planned.filter { p in !recorded.contains { samePath($0, p) } }
                if !missing.isEmpty {
                    out.append(Finding(
                        level: .warn, code: "PLAN_REFS_IGNORED", shotId: shot.id,
                        message: "shot \(shot.id) rendered with \(recorded.count) image reference(s), but the "
                            + "reference planner had offered \(planned.count) — \(missing.count) planned ref(s) "
                            + "never reached the render: \(missing.joined(separator: ", ")). The shot lost the "
                            + "identity anchors and bible sheets that keep it on-model. Re-render it with "
                            + "next_render_shot's reference_images passed as referenceImageMediaRefs."))
                }
            }

            // #196: a chained shot must start on its predecessor's extracted last frame. Only auditable
            // once that frame exists — before then the successor legitimately couldn't have used it.
            guard shot.chainWithPreviousEnd,
                  let predId = ChainContinuity.chainPredecessor(ctx.shotlist, shotId: shot.id),
                  let expected = manifest.entries[predId]?.lastFramePath,
                  let actual = entry.startFramePath else { continue }
            if !samePath(actual, expected) {
                out.append(Finding(
                    level: .warn, code: "CHAIN_START_FRAME_IGNORED", shotId: shot.id,
                    message: "shot \(shot.id) declares chain_with_previous_end but started on '\(actual)' "
                        + "instead of \(predId)'s extracted last frame '\(expected)'. The cut between them "
                        + "will jump — anchor-and-extend only holds when the successor starts on the exact "
                        + "frame the predecessor ended on. Re-render it with next_render_shot's "
                        + "chain_start_frame_media_ref as startFrameMediaRef."))
            }
        }
        return out
    }
}
