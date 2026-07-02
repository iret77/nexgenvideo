/// The disambiguating path shown in the Inspector header, e.g. `Character › Mara` or
/// `Shot 3 › use of Mara`. A segment whose `object` is non-nil is itself navigable (clicking it
/// inspects that object); a nil `object` is a plain category label. See docs/UI_UX_CONCEPT.md §3.
struct ObjectBreadcrumb: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let label: String
        let object: InspectedObject?
    }

    var segments: [Segment]

    var flatText: String { segments.map(\.label).joined(separator: " › ") }
}
