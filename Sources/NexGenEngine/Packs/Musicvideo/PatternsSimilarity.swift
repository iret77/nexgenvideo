import Foundation

/// Pattern-similarity matrix (v0.13.0). Port of
/// `nexgen_pack_musicvideo/patterns_similarity.py`.
///
/// A user request like "similar to Shinkai but with more action" is served
/// by returning the nearest 3-5 neighbors of a pattern.
///
/// Similarity = weighted average of:
/// - cosine similarity of the `framingMix` vectors (weight 0.5)
/// - Jaccard similarity of the `cameraVocabulary` token sets (weight 0.3)
/// - distance of `aslRange.typicalS` (weight 0.2, normalized on a log scale,
///   since ASL varies exponentially)
///
/// No ML, no training — pure vector math over structured pattern fields.
public enum PatternsSimilarity {
    private static let framingsOrder: [Framing] = [
        .wide, .full, .ms, .mcu, .cu, .ecu, .ots, .pov, .insert, .aerial,
    ]

    private static func framingVector(_ p: Pattern) -> [Double] {
        let mix = p.framingMix.byFraming()
        return framingsOrder.map { Double(mix[$0] ?? 0) }
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0.0 }
        let dot = zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
        let na = (a.reduce(0.0) { $0 + $1 * $1 }).squareRoot()
        let nb = (b.reduce(0.0) { $0 + $1 * $1 }).squareRoot()
        guard na != 0, nb != 0 else { return 0.0 }
        return dot / (na * nb)
    }

    private static let wordPattern = try! NSRegularExpression(pattern: "[a-zA-Z]+")

    /// Token set from `cameraVocabulary`, for Jaccard.
    private static func cameraTokenSet(_ p: Pattern) -> Set<String> {
        var tokens: Set<String> = []
        for entry in p.cameraVocabulary {
            let lower = entry.lowercased()
            let ns = lower as NSString
            for match in wordPattern.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
                let word = ns.substring(with: match.range)
                if word.count >= 3 { tokens.insert(word) }
            }
        }
        return tokens
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 0.0 }
        return Double(a.intersection(b).count) / Double(max(a.union(b).count, 1))
    }

    /// Distance on a log scale, normalized to [0, 1]. Closer = better.
    private static func aslLogDistance(_ a: Double, _ b: Double) -> Double {
        guard a > 0, b > 0 else { return 0.0 }
        let diff = abs(log10(a) - log10(b))
        // A log10 difference of 1 = factor 10 = very far apart.
        return max(0.0, 1.0 - min(1.0, diff))
    }

    /// Weighted similarity score between two patterns in [0, 1]. Port of
    /// `patterns_similarity.py::similarity`.
    public static func similarity(_ a: Pattern, _ b: Pattern) -> Double {
        let cos = cosine(framingVector(a), framingVector(b))
        let jac = jaccard(cameraTokenSet(a), cameraTokenSet(b))
        let asl = aslLogDistance(a.aslRange.typicalS, b.aslRange.typicalS)
        return 0.5 * cos + 0.3 * jac + 0.2 * asl
    }

    /// Returns the top-N most similar patterns to an anchor pattern.
    ///
    /// A user request like "similar to Shinkai" uses this function and shows
    /// 3-5 neighbors with score display. Port of
    /// `patterns_similarity.py::suggest_similar`.
    public static func suggestSimilar(patternId: String, top: Int = 5) throws -> [(pattern: Pattern, score: Double)] {
        let library = try Patterns.loadAllPatterns()
        guard let anchor = library.first(where: { $0.id == patternId }) else { return [] }
        var scored: [(Pattern, Double)] = []
        for p in library where p.id != anchor.id {
            scored.append((p, similarity(anchor, p)))
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(top))
    }
}
