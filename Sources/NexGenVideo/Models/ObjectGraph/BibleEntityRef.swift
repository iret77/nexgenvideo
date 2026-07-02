// The object-graph vocabulary shared by every panel, breadcrumb, selection, and (later) the Intent
// Ledger. See docs/UI_UX_CONCEPT.md §2.7 and §9 Phase 0.

/// The four addressable Bible entity kinds. `Look` is a per-project singleton with no id, so it is not
/// an entity kind — it is inspected as `InspectedObject.look`.
enum BibleEntityKind: String, Codable, Sendable, Hashable, CaseIterable {
    case character
    case ensemble
    case prop
    case location

    var label: String {
        switch self {
        case .character: "Character"
        case .ensemble: "Ensemble"
        case .prop: "Prop"
        case .location: "Location"
        }
    }
}

/// A stable reference to one Bible entity: its kind plus the engine-assigned id. Engine ids are unique
/// only *within* a kind, so `compositeID` is the cross-kind unique key.
struct BibleEntityRef: Codable, Sendable, Hashable {
    let kind: BibleEntityKind
    let id: String

    var compositeID: String { "\(kind.rawValue):\(id)" }
}
