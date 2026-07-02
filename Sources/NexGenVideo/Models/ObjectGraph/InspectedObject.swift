/// The single app-global object the Inspector reflects. Exactly one of these is inspected at a time
/// (`EditorViewModel.inspectedObject`). Panels keep their own local selection; only an explicit focus
/// promotes a local selection to the inspected object. Multi-selection is deliberately *not*
/// representable here — it is a panel-local state the Inspector summarizes, never a half-inspected
/// object. See docs/UI_UX_CONCEPT.md §3 (selection semantics) and §9 Phase 0.
enum InspectedObject: Sendable, Hashable {
    case clip(String)                                   // Clip.id — a clip instance on a track
    case mediaAsset(String)                             // MediaAsset.id — a library asset
    case entity(BibleEntityRef)                         // a Bible entity (character/ensemble/prop/location)
    case look                                           // the project's single Look
    case shot(String)                                   // ShotSummary.id
    case shotUse(shot: String, entity: BibleEntityRef)  // a Shot's *use* of an entity, distinct from either
}

extension InspectedObject {
    /// The type of thing this is, independent of any resolved name — used as a breadcrumb fallback and
    /// for grouping. `Character: Mara`, `Shot 014 use of Mara`, and `Clip on V2` share nothing but this.
    var kindLabel: String {
        switch self {
        case .clip: "Clip"
        case .mediaAsset: "Media"
        case .entity(let ref): ref.kind.label
        case .look: "Look"
        case .shot: "Shot"
        case .shotUse(_, let entity): "Use of \(entity.kind.label)"
        }
    }

    /// The one-object promotion rule for the timeline/media panels: a *single* selected clip or asset
    /// promotes to the inspected object; a marquee drag or a multi/empty selection promotes nothing.
    static func fromSelection(
        clipIDs: Set<String>,
        mediaAssetIDs: Set<String>,
        isMarquee: Bool
    ) -> InspectedObject? {
        if isMarquee { return nil }
        if clipIDs.count == 1, let id = clipIDs.first { return .clip(id) }
        if clipIDs.isEmpty, mediaAssetIDs.count == 1, let id = mediaAssetIDs.first { return .mediaAsset(id) }
        return nil
    }
}
