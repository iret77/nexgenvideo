import Foundation
import NexGenEngine

enum PatternRecommendationsModel {
    struct Envelope: Decodable, Sendable, Equatable {
        let available: Bool
        let reason: String?
        let recommendations: Recommendations?
        let libraryCoverage: Coverage?
        let invalidProfiles: [String: [String]]?
    }

    struct Coverage: Decodable, Sendable, Equatable {
        let scored: [String]
        let unscored: [String]
        let invalid: [String]
        let total: Int
    }

    struct Recommendations: Decodable, Sendable, Equatable {
        let schemaVersion: String
        let projectProfileSha256: String
        let policySha256: String
        let scorerVersion: String
        let scoreSemantics: String
        let results: [Recommendation]
        let slots: Slots
        let missingHighImpactInputs: [Question]
        let questionsRequiredBeforeRanking: Bool
    }

    struct Slots: Decodable, Sendable, Equatable {
        let bestOverallPatternId: String?
        let productionEfficientPatternId: String?
        let creativeStretchPatternId: String?
    }

    struct Recommendation: Decodable, Sendable, Equatable, Identifiable {
        let patternId: String
        let patternName: String
        let rank: Int?
        let fitScore: Double?
        let fitBand: String
        let confidence: Double
        let inputCoverage: Double
        let excluded: Bool
        let exclusionReasons: [String]
        let dimensions: [Dimension]
        let strengths: [String]
        let conflicts: [String]
        let adaptations: [Adaptation]
        let why: String
        var id: String { patternId }
        var requiresDeliberateChoice: Bool { fitBand == "provisional" || fitBand == "weak" || !conflicts.isEmpty }
        var warnings: [String] { exclusionReasons + conflicts + (fitBand == "provisional" ? ["Not ranked: inputs or confidence are incomplete."] : []) }
    }

    struct Dimension: Decodable, Sendable, Equatable {
        let dimension: String
        let score: Double?
        let axes: [Axis]
    }

    struct Axis: Decodable, Sendable, Equatable {
        let axis: String
        let score: Double?
        let inputConfidence: Double?
        let evidenceConfidence: Double?
        let resolution: String
        let explanation: String
    }

    struct Adaptation: Decodable, Sendable, Equatable {
        struct Action: Decodable, Sendable, Equatable { let lever: String; let directive: String }
        let adaptationId: String
        let actions: [Action]
        let fitCap: Double
    }

    struct Question: Decodable, Sendable, Equatable { let axis: String; let globalWeight: Double; let question: String }

    struct Detail: Sendable, Equatable {
        struct Evidence: Sendable, Equatable, Identifiable {
            let id: String
            let title: String
            let value: String
            let basis: String
            let sources: [String]
            let referenceTitle: String?
            let referenceURL: String?
        }
        let id: String
        let name: String
        let description: String
        let evidence: [Evidence]
    }

    static func decode(_ bytes: Data) throws -> Envelope {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(Envelope.self, from: bytes)
        if value.available {
            guard let set = value.recommendations, let coverage = value.libraryCoverage,
                  set.schemaVersion == "pattern-recommendations/1.0",
                  set.scorerVersion == "pattern-fit-scorer/1.0",
                  set.scoreSemantics == "compatibility_index_not_probability",
                  set.missingHighImpactInputs.count <= 3,
                  Set(set.results.map(\.id)).count == set.results.count,
                  Set(coverage.scored + coverage.unscored + coverage.invalid).count == coverage.total,
                  coverage.total == coverage.scored.count + coverage.unscored.count + coverage.invalid.count,
                  Set(set.results.map(\.id)).isSubset(of: Set(coverage.scored)),
                  set.results.allSatisfy({ result in
                      ["exceptional", "strong", "good", "stretch", "weak", "excluded", "provisional"].contains(result.fitBand)
                          && result.confidence.isFinite && (0...1).contains(result.confidence)
                          && result.inputCoverage.isFinite && (0...1).contains(result.inputCoverage)
                          && (result.fitScore.map { $0.isFinite && (0...100).contains($0) } ?? true)
                          && (!result.excluded || (result.fitScore == nil && result.rank == nil))
                          && (result.excluded || result.fitScore != nil)
                          && (result.excluded == (result.fitBand == "excluded"))
                          && (result.fitBand != "provisional" || result.rank == nil)
                          && (result.rank.map { $0 > 0 && result.confidence >= 0.45 && result.inputCoverage >= 0.6 } ?? true)
                  }) else { throw malformed() }
            let qualified = Set(set.results.filter { !$0.excluded && $0.fitBand != "provisional" && $0.rank != nil }.map(\.id))
            guard [set.slots.bestOverallPatternId, set.slots.productionEfficientPatternId,
                   set.slots.creativeStretchPatternId].compactMap({ $0 }).allSatisfy(qualified.contains) else { throw malformed() }
        }
        return value
    }

    static func detail(_ bytes: Data, expectedID: String) throws -> Detail {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["id"] as? String == expectedID, let name = object["name"] as? String,
              let description = object["description"] as? String else { throw malformed() }
        var evidence: [Detail.Evidence] = []
        func add(_ id: String, _ title: String, _ value: String, _ raw: [String: Any]) throws {
            guard let basis = raw["basis"] as? String, ["measured", "documented", "inferred"].contains(basis),
                  let sources = raw["sources"] as? [String] else { throw malformed() }
            let video = raw["reference_video"] as? [String: Any]
            evidence.append(.init(id: id, title: title, value: value, basis: basis, sources: sources,
                referenceTitle: video?["title"] as? String, referenceURL: video?["url"] as? String))
        }
        if let range = object["asl_range"] as? [String: Any], let low = range["min_s"] as? Double,
           let high = range["max_s"] as? Double, let typical = range["typical_s"] as? Double {
            try add("asl", "Shot length", String(format: "%.1f–%.1f s · typical %.1f s", low, high, typical), range)
        }
        if let mix = object["framing_mix"] as? [String: Any] {
            let values = mix.keys.filter { $0.hasSuffix("_pct") }.sorted().compactMap { key -> String? in
                guard let value = mix[key] as? Int else { return nil }
                return "\(label(key.replacingOccurrences(of: "_pct", with: ""))): \(value)%"
            }
            try add("framing", "Framing", values.joined(separator: " · "), mix)
        }
        for (key, title) in [("camera", "Camera"), ("lighting", "Lighting"), ("color", "Color")] {
            if let raw = object[key] as? [String: Any] {
                let value = (raw["vocabulary"] as? [String])?.joined(separator: ", ") ?? raw["description"] as? String ?? ""
                try add(key, title, value, raw)
            }
        }
        for (index, raw) in (object["craft_signature"] as? [[String: Any]] ?? []).enumerated() {
            try add("craft-\(index)", raw["technique"] as? String ?? "Technique", raw["directive"] as? String ?? "", raw)
        }
        return .init(id: expectedID, name: name, description: description, evidence: evidence)
    }

    static func label(_ value: String) -> String { value.replacingOccurrences(of: "_", with: " ").capitalized }
    private static func malformed() -> GateBlocked { GateBlocked("The pack returned invalid Pattern-fit data. Update the pack before using its recommendations.") }
}
