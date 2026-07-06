import Foundation

/// Ledger → prompt composition. Port of `render/prompt/ledger_directives.py`.
/// Collects the Intent-Ledger directives that apply to one shot — `film` and
/// `look` singletons, the shot's Bible refs (characters/ensembles, location,
/// props), and the shot's own attributes, broad first / most specific last.
/// Dedupe by lowercase; the locked subset feeds the compliance lint.
public enum LedgerDirectives {
    /// Port of `ledger_directives.py::ShotDirectives`.
    public struct ShotDirectives: Sendable, Equatable {
        public var directives: [String]
        public var locked: [String]
        public init(directives: [String] = [], locked: [String] = []) {
            self.directives = directives
            self.locked = locked
        }
    }

    /// The shot fields `directives_for_shot` reads (Python duck-types via
    /// getattr on `id`, `character_refs`, `location_ref`, `prop_refs`).
    public struct ShotRefs: Sendable, Equatable {
        public let id: String?
        public let characterRefs: [String]
        public let locationRef: String?
        public let propRefs: [String]
        public init(id: String?, characterRefs: [String], locationRef: String?, propRefs: [String]) {
            self.id = id
            self.characterRefs = characterRefs
            self.locationRef = locationRef
            self.propRefs = propRefs
        }
    }

    /// Port of `directives_for_shot`. Key composition order:
    /// film → look → character/ensemble refs → location → props → shot.
    ///
    /// Within a single ledger object that carries multiple attributes, Python
    /// iterates dict-insertion order; Swift's `[String: Attribute]` is unordered,
    /// so attribute names are visited in a deterministic sorted order here. Objects
    /// with a single attribute (the common case, and every ledger test/golden case)
    /// are unaffected.
    public static func directivesForShot(ledger: Ledger, shot: ShotRefs) -> ShotDirectives {
        var keys: [String] = ["film", "look"]
        for ref in shot.characterRefs {
            keys.append("character:\(ref)")
            keys.append("ensemble:\(ref)")
        }
        if let location = shot.locationRef, !location.isEmpty {
            keys.append("location:\(location)")
        }
        for ref in shot.propRefs {
            keys.append("prop:\(ref)")
        }
        if let shotID = shot.id, !shotID.isEmpty {
            keys.append("shot:\(shotID)")
        }

        var out = ShotDirectives()
        var seen = Set<String>()
        for key in keys {
            guard let attributes = ledger.objects[key] else { continue }
            for attrName in attributes.keys.sorted() {
                let attribute = attributes[attrName]!
                // Python: (attribute.directive or attribute.tag).strip()
                let raw = attribute.directive.isEmpty ? attribute.tag : attribute.directive
                let directive = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if directive.isEmpty || seen.contains(directive.lowercased()) { continue }
                seen.insert(directive.lowercased())
                out.directives.append(directive)
                if attribute.locked {
                    out.locked.append(directive)
                }
            }
        }
        return out
    }

    /// Convenience overload for a real `Shot`.
    public static func directivesForShot(ledger: Ledger, shot: Shot) -> ShotDirectives {
        directivesForShot(
            ledger: ledger,
            shot: ShotRefs(
                id: shot.id,
                characterRefs: shot.characterRefs,
                locationRef: shot.locationRef,
                propRefs: shot.propRefs
            )
        )
    }
}
