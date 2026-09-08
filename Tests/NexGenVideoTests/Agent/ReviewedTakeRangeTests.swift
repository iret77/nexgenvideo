import Foundation
import Testing
@testable import NexGenEngine
@testable import NexGenVideo

@Suite("Independently reviewed take ranges")
struct ReviewedTakeRangeTests {
    private func record(findings: [TakeReview.Finding]) -> ReviewedTakeRange {
        .init(schema: "reviewed-take-range/v1", takeID: String(repeating: "a", count: 64),
            source: .init(path: "media/take.mp4", sha256: String(repeating: "b", count: 64)),
            range: .init(startFrame: 48, endFrame: 96, fps: 24), sourceDurationValue: 240,
            sourceDurationTimescale: 24, reviewer: "native-user", findings: findings, reviewedAt: "2026-09-08T22:00:00Z")
    }

    @Test func aRangeNeedsAllSixOwnPassesInsideItsDuration() throws {
        let findings = TakeReview.Pass.allCases.map {
            TakeReview.Finding(pass: $0, verdict: .conforms, observation: "Observed \($0.rawValue) throughout the selected source range.",
                startSeconds: 0, endSeconds: 2)
        }
        try record(findings: findings).validate()
        #expect(throws: (any Error).self) { try record(findings: Array(findings.prefix(1))).validate() }
        var rejected = findings
        rejected[0] = .init(pass: .identity, verdict: .rejected, observation: "Identity drifts inside this range.", startSeconds: 0, endSeconds: 2)
        #expect(throws: (any Error).self) { try record(findings: rejected).validate() }
        let wholeTakeFindings = TakeReview.Pass.allCases.map {
            TakeReview.Finding(pass: $0, verdict: .conforms, observation: "Reviewed the ten-second original.", startSeconds: 0, endSeconds: 10)
        }
        #expect(throws: (any Error).self) { try record(findings: wholeTakeFindings).validate() }
    }

    @Test func frameRangesAreHalfOpenAndCannotEscapeTheOriginal() throws {
        let range = ReviewedTakeRange.Range(startFrame: 24, endFrame: 48, fps: 24)
        try range.validate(sourceDuration: 2)
        #expect(range.durationSeconds == 1)
        #expect(throws: (any Error).self) { try range.validate(sourceDuration: 1.99) }
        #expect(throws: (any Error).self) { try ReviewedTakeRange.Range(startFrame: -1, endFrame: 24, fps: 24).validate(sourceDuration: 2) }
        #expect(throws: (any Error).self) { try ReviewedTakeRange.Range(startFrame: 24, endFrame: 24, fps: 24).validate(sourceDuration: 2) }
        #expect(throws: (any Error).self) { try ReviewedTakeRange.Range(startFrame: 0, endFrame: 24, fps: 0).validate(sourceDuration: 2) }
        #expect(throws: (any Error).self) { try range.validate(sourceDuration: .infinity) }
    }
}
