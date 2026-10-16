import Foundation

extension Patterns {
    /// Retired id -> current id; stored projects keep the old value and are never rewritten.
    static let legacyIds: [String: String] = [
        "visual-album-khalil-joseph": "visual-album-kahlil-joseph",
    ]

    static func replacingLegacyId(_ id: String) -> String {
        legacyIds[id.trimmingCharacters(in: .whitespaces)] ?? id
    }

    static func pattern(withId id: String, in library: [Pattern]) -> Pattern? {
        let current = replacingLegacyId(id).trimmingCharacters(in: .whitespaces)
        guard !current.isEmpty else { return nil }
        return library.first { $0.id == current }
    }
}
