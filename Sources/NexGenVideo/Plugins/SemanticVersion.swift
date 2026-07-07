import Foundation

/// A strict semantic version (`major.minor.patch`) for the loadable-pack gate —
/// enough to compare a pack's `NGVMinAppVersion` against the app's
/// `CFBundleShortVersionString`. These are our own controlled values, so parsing
/// is deliberately strict: exactly three components, each a run of ASCII digits,
/// nothing more. Trailing garbage (`"1.2.3garbage"`), wrong arity (`"1"`, `"1.2"`,
/// `"1.2.3.4"`), a leading non-digit (`"v1.2.3"`), and pre-release / build metadata
/// (`"1.2.3-rc1"`, `"1.2.3+build"`) are all rejected (`nil`). A malformed gate
/// field must read as *incompatible*, never silently as `1.2.3`.
public struct SemanticVersion: Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Self.numericComponent(parts[0]),
              let minor = Self.numericComponent(parts[1]),
              let patch = Self.numericComponent(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    /// One version component: a non-empty run of ASCII digits only. Rejects empty,
    /// signs, whitespace, non-ASCII digits, and any suffix (`"3-rc1"`, `"3 "`).
    /// Overflow (an absurdly long run) also fails via `Int`.
    private static func numericComponent(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(s)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
