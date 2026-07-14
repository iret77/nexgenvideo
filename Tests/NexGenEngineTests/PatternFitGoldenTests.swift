import Foundation
import Testing
@testable import MusicvideoPlugin
@testable import NexGenEngine

/// Cross-language scorer parity: replays every case in the bundled
/// `contracts/pattern-fit-golden-vectors.v1.json` through the exact `FitMath`
/// primitives the scorer runs. If these drift, Swift and the reference
/// implementation no longer agree on the frozen numeric core.
@Suite("Pattern fit golden vectors", .serialized)
struct PatternFitGoldenTests {
    // MARK: Fixtures

    private struct Golden: Decodable {
        struct Categorical: Decodable {
            let bucket: String
            let expectedScore: Double?
            let expectedResolution: String
            enum CodingKeys: String, CodingKey {
                case bucket, expectedScore = "expected_score", expectedResolution = "expected_resolution"
            }
        }
        struct Continuous: Decodable {
            let ranges: [String: [Double]]
            let input: Double
            let expectedScore: Double
            let expectedResolution: String
            enum CodingKeys: String, CodingKey {
                case ranges, input, expectedScore = "expected_score", expectedResolution = "expected_resolution"
            }
        }
        struct Aggregation: Decodable {
            let name: String
            let weights: [Double]?
            let globalWeights: [Double]?
            let scores: [Double?]
            let expectedCoverage: Double
            let expectedRawFit: Double
            enum CodingKeys: String, CodingKey {
                case name, weights, globalWeights = "global_weights", scores
                case expectedCoverage = "expected_coverage", expectedRawFit = "expected_raw_fit"
            }
        }
        struct Confidence: Decodable {
            let coverage: Double
            let normalizedScoredWeights: [Double]
            let inputConfidence: [Double]
            let evidenceConfidence: [Double]
            let expectedConfidence: Double
            enum CodingKeys: String, CodingKey {
                case coverage, normalizedScoredWeights = "normalized_scored_weights"
                case inputConfidence = "input_confidence", evidenceConfidence = "evidence_confidence"
                case expectedConfidence = "expected_confidence"
            }
        }
        struct ConflictMode: Decodable {
            let mode: FitMatchMode
            let rawFitPoints: Double
            let conflictCount: Int
            let expectedFinalScore: Double
            enum CodingKeys: String, CodingKey {
                case mode, rawFitPoints = "raw_fit_points", conflictCount = "conflict_count"
                case expectedFinalScore = "expected_final_score"
            }
        }
        struct Qualification: Decodable {
            let coverage: Double
            let confidence: Double
            let score: Double?
            let expectedBand: String
            enum CodingKeys: String, CodingKey {
                case coverage, confidence, score, expectedBand = "expected_band"
            }
        }
        let categoricalResolution: [Categorical]
        let continuousResolution: [Continuous]
        let aggregation: [Aggregation]
        let confidence: [Confidence]
        let conflictModes: [ConflictMode]
        let qualification: [Qualification]
        enum CodingKeys: String, CodingKey {
            case categoricalResolution = "categorical_resolution"
            case continuousResolution = "continuous_resolution"
            case aggregation, confidence
            case conflictModes = "conflict_modes"
            case qualification
        }
    }

    private func load() throws -> (policy: PatternFitPolicy, golden: Golden) {
        let policy = try PatternFitLibrary.loadPolicy()
        let url = try #require(PackKnowledge.patternFitGoldenVectorsURL(), "golden vectors must be bundled")
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        return (policy, golden)
    }

    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) < tol }

    // MARK: Cases

    @Test("categorical resolution and scores match the policy")
    func categorical() throws {
        let (policy, golden) = try load()
        for c in golden.categoricalResolution {
            guard let bucket = FitBucket(rawValue: c.bucket) else {
                // `missing_input` is the unscored sentinel, not a bucket.
                #expect(c.bucket == "missing_input")
                #expect(c.expectedScore == nil)
                #expect(c.expectedResolution == AxisResolution.unscored.rawValue)
                continue
            }
            #expect(approx(FitMath.score(for: bucket, policy.categoryScores), try #require(c.expectedScore)))
            #expect(FitMath.resolution(for: bucket).rawValue == c.expectedResolution)
        }
    }

    @Test("continuous resolution buckets by nested ranges")
    func continuous() throws {
        let (policy, golden) = try load()
        for c in golden.continuousResolution {
            let fit = ContinuousFit(
                ideal: range(c.ranges["ideal"]!), compatible: range(c.ranges["compatible"]!),
                usable: range(c.ranges["usable"]!), evidenceIds: ["x"])
            let bucket = fit.bucket(for: c.input)
            #expect(approx(FitMath.score(for: bucket, policy.continuousScores), c.expectedScore),
                    "input \(c.input)")
            #expect(FitMath.resolution(for: bucket).rawValue == c.expectedResolution, "input \(c.input)")
        }
    }

    @Test("aggregation renormalizes over scored axes only")
    func aggregation() throws {
        let (_, golden) = try load()
        for a in golden.aggregation {
            let weights = a.weights ?? a.globalWeights ?? []
            var scoredWeights: [Double] = []
            var scoredScores: [Double] = []
            for (w, s) in zip(weights, a.scores) {
                guard let s else { continue }  // unscored axis: excluded from both sums
                scoredWeights.append(w)
                scoredScores.append(s)
            }
            #expect(approx(scoredWeights.reduce(0, +), a.expectedCoverage), a.name)
            #expect(approx(FitMath.rawFit(scoredWeights: scoredWeights, scores: scoredScores), a.expectedRawFit), a.name)
        }
    }

    @Test("evidence-aware confidence folds coverage and quality")
    func confidence() throws {
        let (_, golden) = try load()
        for c in golden.confidence {
            let globalWeights = c.normalizedScoredWeights.map { $0 * c.coverage }
            let value = FitMath.confidence(
                scoredWeights: globalWeights, inputConfidence: c.inputConfidence,
                evidenceConfidence: c.evidenceConfidence)
            #expect(approx(value, c.expectedConfidence, 1e-4))
        }
    }

    @Test("conflict penalties and caps per match mode")
    func conflictModes() throws {
        let (policy, golden) = try load()
        for c in golden.conflictModes {
            let mode = try #require(policy.matchMode(c.mode))
            let value = FitMath.applyConflicts(
                startPoints: c.rawFitPoints, conflictCount: c.conflictCount,
                penaltyPoints: mode.avoidPenaltyPoints, cap: mode.conflictFitCap)
            #expect(approx(value, c.expectedFinalScore), "\(c.mode.rawValue)")
        }
    }

    @Test("qualification floors and banding")
    func qualification() throws {
        let (policy, golden) = try load()
        for q in golden.qualification {
            let provisional = FitMath.isProvisional(coverage: q.coverage, confidence: q.confidence, policy: policy)
            let band = provisional ? "provisional" : policy.band(forScore: q.score ?? 0).rawValue
            #expect(band == q.expectedBand, "coverage \(q.coverage) confidence \(q.confidence)")
        }
    }

    private func range(_ pair: [Double]) -> NumericRange { NumericRange(min: pair[0], max: pair[1]) }
}
