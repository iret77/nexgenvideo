/// A read-model over the project's objects: the one place that resolves an `InspectedObject` to a
/// human breadcrumb and answers relationship queries. It holds *resolved* lookup maps rather than the
/// raw engine documents, so it stays a plain `Sendable` value (usable off-main and trivially testable)
/// and never re-runs the Bible/shotlist decode. Rebuild it (see `from(...)`) when its sources change.
///
/// The entity↔shot↔clip *edges* (`usage(of:)`, `clips(realizing:)`) are the seams the Bible usage-map
/// and sanity→timeline navigation will consume. They return empty today: the engine read model does
/// not yet record which entities a shot uses, nor which clip realized a shot. Filling them is Phase C
/// (see docs/UI_UX_CONCEPT.md §9). They are exposed now so callers can be written against the final
/// shape, not so they can pretend the edges exist.
struct ObjectGraph: Sendable, Equatable {
    var entityNames: [BibleEntityRef: String]   // entity ref → display name
    var shotLabels: [String: String]            // ShotSummary.id → "Shot N"
    var assetNames: [String: String]            // MediaAsset.id → display name
    var clipMediaRefs: [String: String]         // Clip.id → MediaAsset.id
    var clipTrackLabels: [String: String]       // Clip.id → "V2" / "A1"
    var hasLook: Bool

    init(
        entityNames: [BibleEntityRef: String] = [:],
        shotLabels: [String: String] = [:],
        assetNames: [String: String] = [:],
        clipMediaRefs: [String: String] = [:],
        clipTrackLabels: [String: String] = [:],
        hasLook: Bool = false
    ) {
        self.entityNames = entityNames
        self.shotLabels = shotLabels
        self.assetNames = assetNames
        self.clipMediaRefs = clipMediaRefs
        self.clipTrackLabels = clipTrackLabels
        self.hasLook = hasLook
    }
}

// MARK: - Building from loaded project data

extension ObjectGraph {
    /// Assemble the graph from the engine reads plus the app-owned timeline. `assetNames` is passed in
    /// (built by the caller from the `@MainActor` media library) so this stays off the main actor.
    static func from(
        bible: BibleData?,
        shotlist: ShotlistData?,
        timeline: Timeline,
        assetNames: [String: String]
    ) -> ObjectGraph {
        var entityNames: [BibleEntityRef: String] = [:]
        if let bible {
            for c in bible.characters { entityNames[BibleEntityRef(kind: .character, id: c.id)] = c.name }
            for e in bible.ensembles { entityNames[BibleEntityRef(kind: .ensemble, id: e.id)] = e.name }
            for p in bible.props { entityNames[BibleEntityRef(kind: .prop, id: p.id)] = p.name }
            for l in bible.locations { entityNames[BibleEntityRef(kind: .location, id: l.id)] = l.name }
        }

        var shotLabels: [String: String] = [:]
        if let shotlist {
            for (index, shot) in shotlist.shots.enumerated() {
                shotLabels[shot.id] = "Shot \(index + 1)"
            }
        }

        var clipMediaRefs: [String: String] = [:]
        var clipTrackLabels: [String: String] = [:]
        var perPrefixCount: [String: Int] = [:]
        for track in timeline.tracks {
            let prefix = track.type.trackLabelPrefix
            let ordinal = (perPrefixCount[prefix] ?? 0) + 1
            perPrefixCount[prefix] = ordinal
            let label = "\(prefix)\(ordinal)"
            for clip in track.clips {
                clipMediaRefs[clip.id] = clip.mediaRef
                clipTrackLabels[clip.id] = label
            }
        }

        return ObjectGraph(
            entityNames: entityNames,
            shotLabels: shotLabels,
            assetNames: assetNames,
            clipMediaRefs: clipMediaRefs,
            clipTrackLabels: clipTrackLabels,
            hasLook: bible != nil
        )
    }
}

// MARK: - Name resolution

extension ObjectGraph {
    func entityName(_ ref: BibleEntityRef) -> String? { entityNames[ref] }
    func shotLabel(_ id: String) -> String? { shotLabels[id] }
    func assetName(_ id: String) -> String? { assetNames[id] }
    func clipName(_ id: String) -> String? { clipMediaRefs[id].flatMap { assetNames[$0] } }
}

// MARK: - ObjectBreadcrumb

extension ObjectGraph {
    /// The disambiguating path for the Inspector header. Falls back to the object's `kindLabel` when a
    /// name is not resolvable (data not loaded yet), never to an empty or misleading crumb.
    func breadcrumb(for object: InspectedObject) -> ObjectBreadcrumb {
        switch object {
        case .clip(let id):
            var segments: [ObjectBreadcrumb.Segment] = []
            if let track = clipTrackLabels[id] {
                segments.append(.init(label: track, object: nil))
            }
            segments.append(.init(label: clipName(id) ?? "Clip", object: object))
            return ObjectBreadcrumb(segments: segments)

        case .mediaAsset(let id):
            return ObjectBreadcrumb(segments: [
                .init(label: "Media", object: nil),
                .init(label: assetName(id) ?? "Asset", object: object),
            ])

        case .entity(let ref):
            return ObjectBreadcrumb(segments: [
                .init(label: ref.kind.label, object: nil),
                .init(label: entityName(ref) ?? ref.id, object: object),
            ])

        case .look:
            return ObjectBreadcrumb(segments: [.init(label: "Look", object: object)])

        case .shot(let id):
            return ObjectBreadcrumb(segments: [.init(label: shotLabel(id) ?? "Shot", object: object)])

        case .shotUse(let shotID, let ref):
            return ObjectBreadcrumb(segments: [
                .init(label: shotLabel(shotID) ?? "Shot", object: .shot(shotID)),
                .init(label: "use of \(entityName(ref) ?? ref.kind.label)", object: object),
            ])
        }
    }
}

// MARK: - Relationship queries (Phase C seams)

extension ObjectGraph {
    /// Shots that use the given entity — the Bible usage-map. Empty until the engine read model exposes
    /// shot↔entity edges (Phase C).
    func usage(of entity: BibleEntityRef) -> [String] { [] }

    /// Timeline clips that realize the given shot — the seam for sanity→timeline navigation. Empty until
    /// shot↔clip provenance is recorded (Phase C).
    func clips(realizing shotID: String) -> [String] { [] }
}
