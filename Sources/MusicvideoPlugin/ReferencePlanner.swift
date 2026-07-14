import Foundation
import NexGenEngine

/// Deterministic reference-image planner — port of `render/references/__init__.py`
/// `plan_shot_refs`. Expands a shot's bible refs (+ requested views) into concrete
/// image slots, scores them by view priority, and drops the lowest-priority ones
/// past the image model's `max_reference_images`. Pure and file-existence-filtered:
/// only refs whose files exist under the project dir are counted (matching the
/// Python), so a missing file silently drops out rather than producing a false hit.
enum ReferencePlanner {
    struct RefSource: Equatable {
        let path: String        // relative to the project dir
        let entityId: String
        let entityKind: String  // character | ensemble | location | prop | style
        let view: String
        let purpose: String
        let score: Double
    }
    struct PlannedRefs: Equatable {
        let refs: [RefSource]       // accepted, highest-priority first
        let dropped: [RefSource]    // over budget
        let warnings: [String]
    }

    /// View-priority score (higher is kept first). Port of `_score_view`.
    static func scoreView(_ view: String, requested: String?) -> Double {
        if let r = requested, !r.isEmpty, view == r { return 1.0 }
        switch view {
        case "floorplan": return 0.95
        case "front": return 0.7
        case "wide": return 0.65
        case "lighting_anchor": return 0.55
        case "side", "back": return 0.4
        case "": return 0.45
        default: return view.hasPrefix("expression_") ? 0.35 : 0.5
        }
    }

    private static func exists(_ projectDir: URL, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: projectDir.appendingPathComponent(rel).path)
    }

    /// Expand one bible entity into ref slots. Port of `_entity_refs`. `viewPurpose`
    /// and `floorplan` are location-only in this schema; the other entities pass
    /// `[:]`/`""`.
    private static func entityRefs(
        kind: String, entityId: String, sheets: [String: String], referenceImages: [String],
        viewPurpose: [String: String], floorplan: String, projectDir: URL, requestedView: String?
    ) -> [RefSource] {
        var out: [RefSource] = []
        for (viewKey, rel) in sheets {
            let r = rel.trimmingCharacters(in: .whitespaces)
            guard !r.isEmpty, exists(projectDir, r) else { continue }
            out.append(RefSource(path: r, entityId: entityId, entityKind: kind, view: viewKey,
                                 purpose: viewPurpose[viewKey] ?? "", score: scoreView(viewKey, requested: requestedView)))
        }
        // Upload originals — deprioritized to a 0.15 floor when the entity already
        // has sheets (redundant), else the normal "" score since they're the only anchor.
        let hasSheet = !sheets.isEmpty
        for rel in referenceImages {
            let r = rel.trimmingCharacters(in: .whitespaces)
            guard !r.isEmpty, exists(projectDir, r) else { continue }
            let score = hasSheet ? 0.15 : scoreView("", requested: requestedView)
            out.append(RefSource(path: r, entityId: entityId, entityKind: kind, view: "", purpose: "", score: score))
        }
        let fp = floorplan.trimmingCharacters(in: .whitespaces)
        if !fp.isEmpty, exists(projectDir, fp) {
            out.append(RefSource(path: fp, entityId: entityId, entityKind: kind, view: "floorplan",
                                 purpose: "top-down geometric ground-truth for the location",
                                 score: scoreView("floorplan", requested: requestedView)))
        }
        return out
    }

    private static func entityRefs(_ entity: BibleEntity, projectDir: URL, requestedView: String?) -> [RefSource] {
        switch entity {
        case .character(let c):
            return entityRefs(kind: "character", entityId: c.id, sheets: c.sheets, referenceImages: c.referenceImages,
                              viewPurpose: [:], floorplan: "", projectDir: projectDir, requestedView: requestedView)
        case .ensemble(let e):
            return entityRefs(kind: "ensemble", entityId: e.id, sheets: e.sheets, referenceImages: e.referenceImages,
                              viewPurpose: [:], floorplan: "", projectDir: projectDir, requestedView: requestedView)
        case .prop(let p):
            return entityRefs(kind: "prop", entityId: p.id, sheets: p.sheets, referenceImages: p.referenceImages,
                              viewPurpose: [:], floorplan: "", projectDir: projectDir, requestedView: requestedView)
        case .location(let l):
            return entityRefs(kind: "location", entityId: l.id, sheets: l.sheets, referenceImages: l.referenceImages,
                              viewPurpose: l.viewPurpose, floorplan: l.floorplan, projectDir: projectDir, requestedView: requestedView)
        }
    }

    /// Port of `plan_shot_refs`. `maxRefs <= 0` drops everything (mirrors the Python).
    static func planShotRefs(
        projectDir: URL, bible: Bible,
        characterRefs: [String], locationRef: String?, propRefs: [String],
        characterViews: [String: String], locationView: String?, propViews: [String: String],
        maxRefs: Int, includeLightingAnchor: Bool = true
    ) -> PlannedRefs {
        var pool: [RefSource] = []
        for cid in characterRefs {
            guard let ent = bible.lookupId(cid) else { continue }
            switch ent {
            case .character, .ensemble: pool += entityRefs(ent, projectDir: projectDir, requestedView: characterViews[cid])
            default: continue
            }
        }
        if let locationRef, let ent = bible.lookupId(locationRef), case .location = ent {
            pool += entityRefs(ent, projectDir: projectDir, requestedView: locationView)
        }
        for pid in propRefs {
            guard let ent = bible.lookupId(pid), case .prop = ent else { continue }
            pool += entityRefs(ent, projectDir: projectDir, requestedView: propViews[pid])
        }
        if includeLightingAnchor {
            let anchor = bible.look.lightingAnchor.trimmingCharacters(in: .whitespaces)
            if !anchor.isEmpty, exists(projectDir, anchor) {
                pool.append(RefSource(path: anchor, entityId: "look", entityKind: "style", view: "lighting_anchor",
                                      purpose: "global lighting & color-grade anchor", score: scoreView("lighting_anchor", requested: nil)))
            }
        }
        // Highest score first; ties broken deterministically. The Python key is
        // (-score, kind, id, view) and relies on a stable sort; Swift's sort isn't
        // stable, so `path` is appended as a final unique tiebreak (only same-entity
        // multi-uploads collide on the first four, and they report identically).
        pool.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entityKind != $1.entityKind { return $0.entityKind < $1.entityKind }
            if $0.entityId != $1.entityId { return $0.entityId < $1.entityId }
            if $0.view != $1.view { return $0.view < $1.view }
            return $0.path < $1.path
        }
        let accepted = maxRefs > 0 ? Array(pool.prefix(maxRefs)) : []
        let dropped = maxRefs > 0 ? Array(pool.dropFirst(maxRefs)) : pool
        var warnings: [String] = []
        if !dropped.isEmpty {
            warnings.append("capability limit \(maxRefs): \(dropped.count) ref(s) dropped — \(droppedList(dropped))")
        }
        return PlannedRefs(refs: accepted, dropped: dropped, warnings: warnings)
    }

    /// Like `planShotRefs`, but additionally stacks identity-anchor frames (the frame rendered for the
    /// first (section, character) shot) as TOP refs. Port of `plan_shot_refs_with_identity_anchors`.
    ///
    /// The inherited anchor frames are the most concrete identity source for a follow-up shot, so they
    /// outrank every bible sheet (score 1.05, above any requested-view match). When the frames manifest
    /// is missing or an anchor shot has no rendered frame yet, this falls back to plain `planShotRefs`
    /// (no error) — the anchor simply isn't available to stack.
    /// `framesBase` is the base the frames-manifest paths are relative to (the project home, where the
    /// media library lives) — distinct from `projectDir` (the pipeline data root the bible sheets are
    /// relative to) in NexGenVideo's storage model. Defaults to `projectDir` (they coincide in tests /
    /// flat layouts).
    static func planShotRefsWithIdentityAnchors(
        projectDir: URL, bible: Bible, shot: Shot, shotlist: Shotlist,
        framesManifest: FramesManifest?, maxRefs: Int, includeLightingAnchor: Bool = true,
        framesBase: URL? = nil
    ) -> PlannedRefs {
        let base = planShotRefs(
            projectDir: projectDir, bible: bible,
            characterRefs: shot.characterRefs, locationRef: shot.locationRef, propRefs: shot.propRefs,
            characterViews: shot.characterViews, locationView: shot.locationView, propViews: shot.propViews,
            maxRefs: maxRefs, includeLightingAnchor: includeLightingAnchor)

        let anchorMap = IdentityAnchor.pickIdentityAnchors(shotlist)
        let inherited = IdentityAnchor.inheritedAnchorShots(anchorMap, shotId: shot.id)
        guard !inherited.isEmpty, let manifest = framesManifest else { return base }

        let anchorBase = framesBase ?? projectDir
        var anchorRefs: [RefSource] = []
        for anchorShotId in inherited {
            guard let rel = anchorFramePath(manifest, shotId: anchorShotId), exists(anchorBase, rel) else { continue }
            anchorRefs.append(RefSource(
                path: rel, entityId: "anchor:\(anchorShotId)", entityKind: "identity_anchor",
                view: "anchor_frame", purpose: "identity anchor from earlier shot \(anchorShotId)",
                score: 1.05))  // higher than any requested-match, because identity beats view
        }
        if anchorRefs.isEmpty { return base }

        // Anchor refs in front, everything else behind; re-sort and re-cut at the cap.
        var pool = anchorRefs + base.refs + base.dropped
        pool.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entityKind != $1.entityKind { return $0.entityKind < $1.entityKind }
            if $0.entityId != $1.entityId { return $0.entityId < $1.entityId }
            if $0.view != $1.view { return $0.view < $1.view }
            return $0.path < $1.path
        }
        let accepted = maxRefs > 0 ? Array(pool.prefix(maxRefs)) : []
        let dropped = maxRefs > 0 ? Array(pool.dropFirst(maxRefs)) : pool
        var warnings = base.warnings
        if base.refs.count + anchorRefs.count > maxRefs {
            warnings.append(
                "identity-anchor stack fills refs — \(anchorRefs.count) anchor(s), "
                + "\(dropped.count) originally planned ref(s) dropped.")
        }
        return PlannedRefs(refs: accepted, dropped: dropped, warnings: warnings)
    }

    /// The anchor keyframe path for a shot from the frames manifest — the `start`-role frame (the
    /// identity keyframe), or the first recorded frame. nil when the shot has no frame yet.
    private static func anchorFramePath(_ manifest: FramesManifest, shotId: String) -> String? {
        guard let sf = manifest.shot(shotId) else { return nil }
        let start = sf.frames.first { $0.role == "start" }
        return (start ?? sf.frames.first)?.path
    }

    /// `kind/id/view` per dropped ref (view → "ref" when empty), comma-joined.
    static func droppedList(_ dropped: [RefSource]) -> String {
        dropped.map { "\($0.entityKind)/\($0.entityId)/\($0.view.isEmpty ? "ref" : $0.view)" }.joined(separator: ", ")
    }
}

/// Per-image-model reference caps — port of `render/images/registry.py` `IMG_CAPS`
/// (`ImageModelCapability.max_reference_images` / `supports_reference_images`).
/// Returns nil when the model is unknown or doesn't support reference images; the
/// caller falls back to 9 (matching `references.py`).
enum ImageModelCaps {
    static func maxReferenceImages(_ model: FrameImageModel) -> Int? {
        switch model {
        case .googleGemini3Pro, .googleGemini31Flash, .falNanoBanana: return 6
        case .openaiGptImage2, .openaiGptImage1: return 10
        case .runwayGemini3Pro, .runwayGemini31Flash, .runwayGemini25Flash, .runwayGen4Image, .runwayGen4ImageTurbo: return 3
        case .falGptImage1: return 4
        // supports_reference_images == false → no cap (caller falls back to 9).
        case .googleImagen4Ultra, .falImagen4Ultra, .falFluxPro11: return nil
        case .other: return nil
        }
    }
    static let referenceFallback = 9
}

extension MusicvideoChecks {
    /// REF_BUDGET_EXCEEDED — port of `sanity/checks/references.py`. Runs the reference
    /// planner per keyframe shot and warns when refs get dropped over the image model's
    /// reference cap (so the render silently loses identity anchors). Needs the project
    /// dir (via `ctx.extra["data_root"]`) for the planner's file-existence filter; with
    /// no data root it degrades to no findings rather than guessing.
    public static let referenceBudgetCheck: SanityCheck = { ctx in
        guard let bible = ctx.bible, let brief = ctx.brief, let root = ctx.extra?["data_root"] else { return [] }
        let projectDir = URL(fileURLWithPath: root)
        let maxRefs = ImageModelCaps.maxReferenceImages(brief.frameImageModel) ?? ImageModelCaps.referenceFallback
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            guard shot.keyframeStrategy == .start || shot.keyframeStrategy == .startEnd else { continue }
            guard !shot.characterRefs.isEmpty || shot.locationRef != nil || !shot.propRefs.isEmpty else { continue }
            let plan = ReferencePlanner.planShotRefs(
                projectDir: projectDir, bible: bible,
                characterRefs: shot.characterRefs, locationRef: shot.locationRef, propRefs: shot.propRefs,
                characterViews: shot.characterViews, locationView: shot.locationView, propViews: shot.propViews,
                maxRefs: maxRefs)
            if !plan.dropped.isEmpty {
                out.append(Finding(level: .warn, code: "REF_BUDGET_EXCEEDED", shotId: shot.id,
                    message: "\(plan.dropped.count) ref(s) dropped (limit \(maxRefs)); dropped: "
                        + ReferencePlanner.droppedList(plan.dropped)))
            }
        }
        return out
    }
}
