import Foundation
import NexGenEngine

/// Deterministic semantic reference-image planner.
enum ReferencePlanner {
    struct RefSource: Equatable {
        let path: String        // relative to the project dir
        let entityId: String
        let entityKind: String  // character | ensemble | location | prop | style
        let view: String
        let purpose: String
        let score: Double
        let requirementIDs: [String]
        let isRequired: Bool
    }
    struct PlannedRefs: Equatable {
        let refs: [RefSource]       // accepted, highest-priority first
        let dropped: [RefSource]    // over budget
        let warnings: [String]
        let deficits: [FrameReferenceDeficitV1]
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
                                 purpose: viewPurpose[viewKey] ?? "", score: scoreView(viewKey, requested: requestedView),
                                 requirementIDs: ["\(kind):\(entityId)"], isRequired: false))
        }
        // Upload originals — deprioritized to a 0.15 floor when the entity already
        // has sheets (redundant), else the normal "" score since they're the only anchor.
        let hasSheet = !sheets.isEmpty
        for rel in referenceImages {
            let r = rel.trimmingCharacters(in: .whitespaces)
            guard !r.isEmpty, exists(projectDir, r) else { continue }
            let score = hasSheet ? 0.15 : scoreView("", requested: requestedView)
            out.append(RefSource(path: r, entityId: entityId, entityKind: kind, view: "", purpose: "", score: score,
                                 requirementIDs: ["\(kind):\(entityId)"], isRequired: false))
        }
        let fp = floorplan.trimmingCharacters(in: .whitespaces)
        if !fp.isEmpty, exists(projectDir, fp) {
            out.append(RefSource(path: fp, entityId: entityId, entityKind: kind, view: "floorplan",
                                 purpose: "top-down geometric ground-truth for the location",
                                 score: scoreView("floorplan", requested: requestedView),
                                 requirementIDs: ["\(kind):\(entityId)"], isRequired: false))
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

    static func planShotRefs(
        projectDir: URL, bible: Bible,
        characterRefs: [String], locationRef: String?, propRefs: [String],
        characterViews: [String: String], locationView: String?, propViews: [String: String],
        referenceImageRefs: [String] = [],
        maxRefs: Int, includeLightingAnchor: Bool = true
    ) -> PlannedRefs {
        var required: [RefSource] = []
        var optional: [RefSource] = []
        var deficits: [FrameReferenceDeficitV1] = []

        func requireOne(_ candidates: [RefSource], id: String, detail: String) {
            let ranked = sorted(candidates)
            guard let first = ranked.first else {
                deficits.append(FrameReferenceDeficitV1(requirementID: id, detail: detail))
                return
            }
            required.append(mark(first, required: true, requirementIDs: [id]))
            optional.append(contentsOf: ranked.dropFirst().map {
                mark($0, required: false, requirementIDs: [id])
            })
        }

        for path in referenceImageRefs {
            let ref = path.trimmingCharacters(in: .whitespaces)
            let requirement = "explicit:\(ref)"
            guard !ref.isEmpty, exists(projectDir, ref) else {
                deficits.append(FrameReferenceDeficitV1(
                    requirementID: requirement,
                    detail: "The shot-specific reference '\(ref)' is missing."
                ))
                continue
            }
            required.append(RefSource(
                path: ref,
                entityId: "explicit",
                entityKind: "explicit",
                view: "",
                purpose: "shot-specific reference",
                score: 1.1,
                requirementIDs: [requirement],
                isRequired: true
            ))
        }
        for cid in characterRefs {
            let requirement = "character:\(cid)"
            guard let ent = bible.lookupId(cid) else {
                deficits.append(FrameReferenceDeficitV1(
                    requirementID: requirement,
                    detail: "Character '\(cid)' is not present in the approved Bible."
                ))
                continue
            }
            switch ent {
            case .character, .ensemble:
                requireOne(
                    entityRefs(ent, projectDir: projectDir, requestedView: characterViews[cid]),
                    id: requirement,
                    detail: "Character '\(cid)' has no available canonical image for the required view."
                )
            default:
                deficits.append(FrameReferenceDeficitV1(
                    requirementID: requirement,
                    detail: "Bible entity '\(cid)' is not a character or ensemble."
                ))
            }
        }
        if let locationRef {
            let requirement = "location:\(locationRef)"
            if let ent = bible.lookupId(locationRef), case .location = ent {
                requireOne(
                    entityRefs(ent, projectDir: projectDir, requestedView: locationView),
                    id: requirement,
                    detail: "Location '\(locationRef)' has no available canonical image for the required view."
                )
            } else {
                deficits.append(FrameReferenceDeficitV1(
                    requirementID: requirement,
                    detail: "Location '\(locationRef)' is not present in the approved Bible."
                ))
            }
        }
        for pid in propRefs {
            let requirement = "prop:\(pid)"
            if let ent = bible.lookupId(pid), case .prop = ent {
                requireOne(
                    entityRefs(ent, projectDir: projectDir, requestedView: propViews[pid]),
                    id: requirement,
                    detail: "Prop '\(pid)' has no available canonical image for the required view."
                )
            } else {
                deficits.append(FrameReferenceDeficitV1(
                    requirementID: requirement,
                    detail: "Prop '\(pid)' is not present in the approved Bible."
                ))
            }
        }
        if includeLightingAnchor {
            let anchor = bible.look.lightingAnchor.trimmingCharacters(in: .whitespaces)
            if !anchor.isEmpty {
                if exists(projectDir, anchor) {
                    required.append(RefSource(
                        path: anchor,
                        entityId: "look",
                        entityKind: "style",
                        view: "lighting_anchor",
                        purpose: "global lighting & color-grade anchor",
                        score: scoreView("lighting_anchor", requested: nil),
                        requirementIDs: ["lighting:look"],
                        isRequired: true
                    ))
                } else {
                    deficits.append(FrameReferenceDeficitV1(
                        requirementID: "lighting:look",
                        detail: "The approved lighting anchor '\(anchor)' is missing."
                    ))
                }
            }
        }
        return finalize(
            required: required,
            optional: optional,
            maxRefs: maxRefs,
            deficits: deficits
        )
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
            referenceImageRefs: shot.referenceImageRefs,
            maxRefs: maxRefs, includeLightingAnchor: includeLightingAnchor)

        let anchorMap = IdentityAnchor.pickIdentityAnchors(shotlist)
        let inherited = anchorMap.forShot(shot.id).filter { $0.anchorShotId != shot.id }
        guard !inherited.isEmpty, let manifest = framesManifest else { return base }

        let anchorBase = framesBase ?? projectDir
        var anchorRefs: [RefSource] = []
        for inheritedRef in inherited {
            let anchorShotId = inheritedRef.anchorShotId
            guard let rel = anchorFramePath(manifest, shotId: anchorShotId), exists(anchorBase, rel) else { continue }
            anchorRefs.append(RefSource(
                path: rel, entityId: inheritedRef.characterId, entityKind: "identity_anchor",
                view: "anchor_frame", purpose: "identity anchor from earlier shot \(anchorShotId)",
                score: 1.05, requirementIDs: ["character:\(inheritedRef.characterId)"],
                isRequired: true))
        }
        if anchorRefs.isEmpty { return base }

        let replaced = Set(anchorRefs.flatMap(\.requirementIDs))
        let baseRequired = base.refs.filter { $0.isRequired }
        let demoted = baseRequired.filter {
            $0.requirementIDs.contains(where: replaced.contains)
        }.map {
            mark($0, required: false, requirementIDs: $0.requirementIDs)
        }
        return finalize(
            required: anchorRefs + baseRequired.filter {
                !$0.requirementIDs.contains(where: replaced.contains)
            },
            optional: demoted + base.refs.filter { !$0.isRequired } + base.dropped,
            maxRefs: maxRefs,
            deficits: base.deficits.filter {
                !replaced.contains($0.requirementID)
            }
        )
    }

    private static func finalize(
        required: [RefSource],
        optional: [RefSource],
        maxRefs: Int,
        deficits: [FrameReferenceDeficitV1]
    ) -> PlannedRefs {
        let required = mergeRequired(required)
        let optional = unique(sorted(optional)).filter { candidate in
            !required.contains(where: { $0.path == candidate.path })
        }
        var deficits = deficits
        if required.count > maxRefs {
            deficits.append(FrameReferenceDeficitV1(
                requirementID: "offering:image-reference-capacity",
                detail: "The shot needs \(required.count) required image references, but the selected offering accepts \(maxRefs)."
            ))
        }
        let remaining = max(0, maxRefs - required.count)
        let accepted = required + Array(optional.prefix(remaining))
        let dropped = Array(optional.dropFirst(remaining))
        var warnings: [String] = []
        if !dropped.isEmpty {
            warnings.append("capability limit \(maxRefs): \(dropped.count) optional ref(s) omitted — \(droppedList(dropped))")
        }
        if let capacity = deficits.first(where: { $0.requirementID == "offering:image-reference-capacity" }) {
            warnings.append(capacity.detail)
        }
        return PlannedRefs(
            refs: accepted,
            dropped: dropped,
            warnings: warnings,
            deficits: deficits
        )
    }

    private static func sorted(_ refs: [RefSource]) -> [RefSource] {
        refs.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entityKind != $1.entityKind { return $0.entityKind < $1.entityKind }
            if $0.entityId != $1.entityId { return $0.entityId < $1.entityId }
            if $0.view != $1.view { return $0.view < $1.view }
            return $0.path < $1.path
        }
    }

    private static func unique(_ refs: [RefSource]) -> [RefSource] {
        var seen: Set<String> = []
        return refs.filter { seen.insert($0.path).inserted }
    }

    private static func mergeRequired(_ refs: [RefSource]) -> [RefSource] {
        var ordered: [RefSource] = []
        for ref in refs {
            if let index = ordered.firstIndex(where: { $0.path == ref.path }) {
                let current = ordered[index]
                ordered[index] = RefSource(
                    path: current.path,
                    entityId: current.entityId,
                    entityKind: current.entityKind,
                    view: current.view,
                    purpose: current.purpose,
                    score: max(current.score, ref.score),
                    requirementIDs: Array(
                        Set(current.requirementIDs + ref.requirementIDs)
                    ).sorted(),
                    isRequired: true
                )
            } else {
                ordered.append(ref)
            }
        }
        return ordered
    }

    private static func mark(
        _ ref: RefSource,
        required: Bool,
        requirementIDs: [String]
    ) -> RefSource {
        RefSource(
            path: ref.path,
            entityId: ref.entityId,
            entityKind: ref.entityKind,
            view: ref.view,
            purpose: ref.purpose,
            score: ref.score,
            requirementIDs: requirementIDs,
            isRequired: required
        )
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
    public static let referenceBudgetCheck: SanityCheck = { ctx in
        guard let bible = ctx.bible, let brief = ctx.brief, let root = ctx.extra?["data_root"] else { return [] }
        let projectDir = URL(fileURLWithPath: root)
        let maxRefs = ImageModelCaps.maxReferenceImages(brief.frameImageModel) ?? ImageModelCaps.referenceFallback
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            guard shot.keyframeStrategy == .start || shot.keyframeStrategy == .startEnd else { continue }
            guard !shot.characterRefs.isEmpty
                    || shot.locationRef != nil
                    || !shot.propRefs.isEmpty
                    || !shot.referenceImageRefs.isEmpty
                    || !bible.look.lightingAnchor.isEmpty else { continue }
            let plan = ReferencePlanner.planShotRefs(
                projectDir: projectDir, bible: bible,
                characterRefs: shot.characterRefs, locationRef: shot.locationRef, propRefs: shot.propRefs,
                characterViews: shot.characterViews, locationView: shot.locationView, propViews: shot.propViews,
                referenceImageRefs: shot.referenceImageRefs,
                maxRefs: maxRefs)
            for deficit in plan.deficits {
                out.append(Finding(
                    level: .error,
                    code: deficit.requirementID == "offering:image-reference-capacity"
                        ? "REF_BUDGET_EXCEEDED"
                        : "REQUIRED_REFERENCE_MISSING",
                    shotId: shot.id,
                    message: deficit.detail
                ))
            }
        }
        return out
    }
}
