import Foundation

/// Identity-anchor selection for multi-shot character consistency. Port of
/// `render/identity_anchor.py`.
///
/// Pattern: the first character-shot per section carrying a given character is marked its identity
/// anchor. That shot's rendered frame is stacked on top of the reference set for every following shot
/// in the same section that carries the same character — stabilizing face proportions, wardrobe, and
/// distinctive features across the section. A section change resets the map (cross-section drift is
/// usually a deliberate cut).
public enum IdentityAnchor {
    /// One inherited/self anchor entry for a shot: which earlier (or same) shot anchors which character.
    /// Port of the `(anchor_shot_id, character_id)` tuple Python stores per shot.
    public struct AnchorRef: Sendable, Equatable {
        public let anchorShotId: String
        public let characterId: String
        public init(anchorShotId: String, characterId: String) {
            self.anchorShotId = anchorShotId
            self.characterId = characterId
        }
    }

    /// Mapping shot_id → the anchor entries it carries. A shot that is ITSELF an anchor appears with
    /// `anchorShotId == shot.id`; follow-up shots reference an earlier anchor. Port of `AnchorMap`.
    public struct AnchorMap: Sendable, Equatable {
        public var anchorsPerShot: [String: [AnchorRef]]
        public init(anchorsPerShot: [String: [AnchorRef]] = [:]) {
            self.anchorsPerShot = anchorsPerShot
        }
        /// Port of `AnchorMap.for_shot`.
        public func forShot(_ shotId: String) -> [AnchorRef] { anchorsPerShot[shotId] ?? [] }
    }

    /// Mark the first shot per (section, character) as the anchor; later shots of the same section with
    /// the same character reference it. Section changes reset the map. Port of `pick_identity_anchors`.
    public static func pickIdentityAnchors(_ shotlist: Shotlist) -> AnchorMap {
        let sortedShots = shotlist.shots.sorted { $0.timeStart < $1.timeStart }
        // Per section: character id → anchor shot id.
        var anchorsInSection: [String?: [String: String]] = [:]
        var result = AnchorMap()

        for shot in sortedShots {
            let sec = shot.section
            var charMap = anchorsInSection[sec] ?? [:]
            var entries: [AnchorRef] = []
            for cid in shot.characterRefs {
                if let existing = charMap[cid] {
                    entries.append(AnchorRef(anchorShotId: existing, characterId: cid))
                } else {
                    charMap[cid] = shot.id
                    entries.append(AnchorRef(anchorShotId: shot.id, characterId: cid))
                }
            }
            anchorsInSection[sec] = charMap
            if !entries.isEmpty { result.anchorsPerShot[shot.id] = entries }
        }
        return result
    }

    /// True when `shotId` is itself the anchor for `characterId` (no earlier anchor referenced). Port of
    /// `is_anchor_for`.
    public static func isAnchorFor(_ map: AnchorMap, shotId: String, characterId: String) -> Bool {
        map.forShot(shotId).contains { $0.characterId == characterId && $0.anchorShotId == shotId }
    }

    /// The anchor-shot ids `shotId` inherits as implicit refs — the ones anchored by an EARLIER shot,
    /// not this one. Port of `inherited_anchor_shots`.
    public static func inheritedAnchorShots(_ map: AnchorMap, shotId: String) -> [String] {
        map.forShot(shotId).filter { $0.anchorShotId != shotId }.map(\.anchorShotId)
    }
}
