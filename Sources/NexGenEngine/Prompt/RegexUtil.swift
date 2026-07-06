import Foundation

/// Thin wrappers over `NSRegularExpression` that reproduce Python `re`
/// substitution/search semantics used by the prompt layer. Isolated here so the
/// byte-faithful regex behavior lives in one audited place.
///
/// Python parity notes baked in:
/// - `re.sub(pat, repl, s)` replaces all non-overlapping matches left-to-right;
///   `NSRegularExpression.stringByReplacingMatches` does the same.
/// - `\b`, `\d`, `\s`, case-insensitivity, and greedy `*`/`+` are compatible
///   between Python `re` and ICU (NSRegularExpression) for the patterns used.
/// - Template `$0`/`$1` in ICU maps to Python `\g<0>`/`\1`; literal replacement
///   strings must escape `$` and `\`.
enum Rx {
    /// Compile once. Patterns here are all module constants, so force-compiling
    /// is safe — a bad pattern is a build-time authoring bug we want to surface.
    static func compile(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func fullRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..<s.endIndex, in: s)
    }

    /// `re.sub(pattern, literalReplacement, text)` where the replacement is a
    /// plain string (no group backreferences). Escapes ICU template specials.
    static func sub(
        _ text: String, _ pattern: NSRegularExpression, with replacement: String
    ) -> String {
        let template = NSRegularExpression.escapedTemplate(for: replacement)
        return pattern.stringByReplacingMatches(
            in: text, range: fullRange(text), withTemplate: template
        )
    }

    /// `re.sub(pattern, template, text)` where `template` uses `$1`-style ICU
    /// group references (already in ICU form).
    static func subTemplate(
        _ text: String, _ pattern: NSRegularExpression, template: String
    ) -> String {
        pattern.stringByReplacingMatches(
            in: text, range: fullRange(text), withTemplate: template
        )
    }

    /// `re.sub(pattern, func, text)` — replacement computed per match. Rebuilds
    /// the string left-to-right, same as Python's callable replacement.
    static func subFunc(
        _ text: String, _ pattern: NSRegularExpression,
        _ transform: (_ match: NSTextCheckingResult, _ text: String) -> String
    ) -> String {
        let ns = text as NSString
        var result = ""
        var lastEnd = 0
        for match in pattern.matches(in: text, range: fullRange(text)) {
            let r = match.range
            result += ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd))
            result += transform(match, text)
            lastEnd = r.location + r.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    /// `bool(re.search(pattern, text))`.
    static func search(_ text: String, _ pattern: NSRegularExpression) -> Bool {
        pattern.firstMatch(in: text, range: fullRange(text)) != nil
    }

    /// `re.search(pattern, text)` returning the group-0 substring, or nil.
    static func firstMatchGroup0(_ text: String, _ pattern: NSRegularExpression) -> String? {
        guard let m = pattern.firstMatch(in: text, range: fullRange(text)) else { return nil }
        return (text as NSString).substring(with: m.range)
    }

    /// All group-0 substrings for `re.finditer`.
    static func allGroup0(_ text: String, _ pattern: NSRegularExpression) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, range: fullRange(text)).map { ns.substring(with: $0.range) }
    }

    /// Group-`n` substring of a match, or nil when the group didn't participate.
    static func group(_ match: NSTextCheckingResult, _ n: Int, in text: String) -> String? {
        guard n < match.numberOfRanges else { return nil }
        let r = match.range(at: n)
        guard r.location != NSNotFound else { return nil }
        return (text as NSString).substring(with: r)
    }

    /// Python `re.escape` for a literal fragment to embed in a pattern.
    static func escape(_ literal: String) -> String {
        NSRegularExpression.escapedPattern(for: literal)
    }
}
