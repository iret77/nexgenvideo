import Foundation

/// A read-model over the project's objects: the one place that resolves an `InspectedObject` to a
/// human breadcrumb and answers relationship queries. It holds *resolved* lookup maps rather than the
/// raw engine documents, so it stays a plain `Sendable` value (usable off-main and trivially testable)
/// and never re-runs the Bible/shotlist decode. Rebuild it (see `from(...)`) when its sources change.
///
/// The entity↔shot↔clip *edges*: `usage(of:)`/`entities(usedBy:)` derive from the shotlist's Bible
/// refs, `clips(realizing:)` from the render-path convention — provenance is read, never invented
/// (docs/UI_UX_CONCEPT.md §9 Phase C).
struct ObjectGraph: Sendable, Equatable {
    var entityNames: [BibleEntityRef: String]   // entity ref → display name
    var shotLabels: [String: String]            // ShotSummary.id → "Shot N"
    var assetNames: [String: String]            // MediaAsset.id → display name
    var clipMediaRefs: [String: String]         // Clip.id → MediaAsset.id
    var clipTrackLabels: [String: String]       // Clip.id → "V2" / "A1"
    var hasLook: Bool
    var shotEntities: [String: [BibleEntityRef]] // Shot id → entities the shot uses (shotlist refs)
    var orderedShotIDs: [String]                 // Shotlist order, for stable usage listings
    var assetPaths: [String: String]             // MediaAsset.id → absolute/relative source path

    init(
        entityNames: [BibleEntityRef: String] = [:],
        shotLabels: [String: String] = [:],
        assetNames: [String: String] = [:],
        clipMediaRefs: [String: String] = [:],
        clipTrackLabels: [String: String] = [:],
        hasLook: Bool = false,
        shotEntities: [String: [BibleEntityRef]] = [:],
        orderedShotIDs: [String] = [],
        assetPaths: [String: String] = [:]
    ) {
        self.entityNames = entityNames
        self.shotLabels = shotLabels
        self.assetNames = assetNames
        self.clipMediaRefs = clipMediaRefs
        self.clipTrackLabels = clipTrackLabels
        self.hasLook = hasLook
        self.shotEntities = shotEntities
        self.orderedShotIDs = orderedShotIDs
        self.assetPaths = assetPaths
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
        assetNames: [String: String],
        assetPaths: [String: String] = [:]
    ) -> ObjectGraph {
        var entityNames: [BibleEntityRef: String] = [:]
        if let bible {
            for c in bible.characters { entityNames[BibleEntityRef(kind: .character, id: c.id)] = c.name }
            for e in bible.ensembles { entityNames[BibleEntityRef(kind: .ensemble, id: e.id)] = e.name }
            for p in bible.props { entityNames[BibleEntityRef(kind: .prop, id: p.id)] = p.name }
            for l in bible.locations { entityNames[BibleEntityRef(kind: .location, id: l.id)] = l.name }
        }

        var shotLabels: [String: String] = [:]
        var shotEntities: [String: [BibleEntityRef]] = [:]
        var orderedShotIDs: [String] = []
        if let shotlist {
            for (index, shot) in shotlist.shots.enumerated() {
                shotLabels[shot.id] = "Shot \(index + 1)"
                orderedShotIDs.append(shot.id)
                var refs: [BibleEntityRef] = []
                for id in shot.characterRefs {
                    // A character_ref may name a character or an ensemble; resolve against both.
                    let character = BibleEntityRef(kind: .character, id: id)
                    let ensemble = BibleEntityRef(kind: .ensemble, id: id)
                    if entityNames[character] != nil { refs.append(character) }
                    else if entityNames[ensemble] != nil { refs.append(ensemble) }
                }
                if let loc = shot.locationRef {
                    let ref = BibleEntityRef(kind: .location, id: loc)
                    if entityNames[ref] != nil { refs.append(ref) }
                }
                for id in shot.propRefs {
                    let ref = BibleEntityRef(kind: .prop, id: id)
                    if entityNames[ref] != nil { refs.append(ref) }
                }
                if !refs.isEmpty { shotEntities[shot.id] = refs }
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
            hasLook: bible != nil,
            shotEntities: shotEntities,
            orderedShotIDs: orderedShotIDs,
            assetPaths: assetPaths
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
            var segments: [ObjectBreadcrumb.Segment] = [
                .init(label: "Timeline Clip", object: nil),
            ]
            if let track = clipTrackLabels[id] {
                segments.append(.init(label: track, object: nil))
            }
            segments.append(.init(label: clipName(id) ?? "Clip", object: object))
            return ObjectBreadcrumb(segments: segments)

        case .mediaAsset(let id):
            return ObjectBreadcrumb(segments: [
                .init(label: "Original Media", object: nil),
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
    /// Shots that use the given entity (shotlist `character_refs`/`location_ref`/`prop_refs`), in
    /// shotlist order — the Bible usage-map.
    func usage(of entity: BibleEntityRef) -> [String] {
        orderedShotIDs.filter { shotEntities[$0]?.contains(entity) == true }
    }

    /// Entities a shot uses, in shotlist declaration order.
    func entities(usedBy shotID: String) -> [BibleEntityRef] {
        shotEntities[shotID] ?? []
    }

    /// Timeline clips whose source asset realizes the given shot. Provenance is derived from the
    /// render path convention (`renders/<shot_id>…`) or an asset named after the shot — nothing is
    /// invented beyond what the file system shows.
    func clips(realizing shotID: String) -> [String] {
        guard !shotID.isEmpty else { return [] }
        return clipMediaRefs.compactMap { clipID, assetID in
            assetRealizes(assetID: assetID, shotID: shotID) ? clipID : nil
        }
        .sorted { (clipTrackLabels[$0] ?? "") < (clipTrackLabels[$1] ?? "") }
    }

    private func assetRealizes(assetID: String, shotID: String) -> Bool {
        if let path = assetPaths[assetID] {
            let url = URL(fileURLWithPath: path)
            let stem = url.deletingPathExtension().lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent
            if path.contains("renders/") && (stem == shotID || parent == shotID) { return true }
        }
        if let name = assetNames[assetID] {
            let stem = (name as NSString).deletingPathExtension
            if stem == shotID { return true }
        }
        return false
    }
}
