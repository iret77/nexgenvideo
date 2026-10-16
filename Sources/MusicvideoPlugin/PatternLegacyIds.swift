import Foundation

extension Patterns {
    /// Retired pattern id -> current id. Stored projects keep the old value in `brief.director_pattern`
    /// and `section.pattern_override`; lookups resolve it here and project files are never rewritten.
    static let legacyIds: [String: String] = [
        "visual-album-khalil-joseph": "visual-album-kahlil-joseph",
    ]

    /// `id` with a retired value replaced by its current id; any other value is returned as given.
    static func replacingLegacyId(_ id: String) -> String {
        legacyIds[id.trimmingCharacters(in: .whitespaces)] ?? id
    }

    /// The pattern `id` names in `library` (current or retired id); nil when blank or unknown.
    static func pattern(withId id: String, in library: [Pattern]) -> Pattern? {
        let current = replacingLegacyId(id).trimmingCharacters(in: .whitespaces)
        guard !current.isEmpty else { return nil }
        return library.first { $0.id == current }
    }
}
