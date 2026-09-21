import Foundation
import Testing
@testable import NexGenVideo

@Suite("AudioSyncCorrelator")
struct AudioSyncCorrelatorTests {
    private func signal(count: Int, seed: UInt64 = 0x9E3779B97F4A7C15) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return 0.05 + Float((state >> 33) % 10_000) / 10_000
        }
    }

    private func smooth(_ values: [Float], radius: Int = 3) -> [Float] {
        values.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(values.count - 1, index + radius)
            return values[lower...upper].reduce(0, +) / Float(upper - lower + 1)
        }
    }

    @Test func findsOffsetAcrossSeveralAnchors() throws {
        let reference = signal(count: 2_400)
        let target = Array(reference[350..<1_850])
        let assessment = AudioSyncCorrelator.match(
            reference: reference,
            target: target,
            maxLagHops: 600,
            minOverlapHops: 200
        )
        let result = try #require(assessment.result)
        #expect(assessment.failure == nil)
        #expect(abs(result.lagHops - 350) <= 1)
        #expect(result.matchedAnchors >= 3)
        #expect(result.confidence > 0.9)
    }

    @Test func handlesDifferentSourceStartPointsAndGain() throws {
        let source = signal(count: 2_000)
        let reference = Array(source[200..<1_700])
        let target = source[0..<1_500].map { $0 * 0.2 + 0.03 }
        let assessment = AudioSyncCorrelator.match(
            reference: reference,
            target: target,
            maxLagHops: 400,
            minOverlapHops: 200
        )
        let result = try #require(assessment.result)
        #expect(assessment.failure == nil)
        #expect(abs(result.lagHops + 200) <= 1)
        #expect(result.confidence > 0.85)
    }

    @Test func findsShortReferenceInsideMuchLongerRecorderTrack() throws {
        let reference = signal(count: 1_200, seed: 8)
        let target = signal(count: 1_500, seed: 9)
            + reference
            + signal(count: 1_700, seed: 11)
        let assessment = AudioSyncCorrelator.match(
            reference: reference,
            target: target,
            maxLagHops: 1_800,
            minOverlapHops: 200
        )
        let result = try #require(assessment.result)
        #expect(assessment.failure == nil)
        #expect(abs(result.lagHops + 1_500) <= 1)
        #expect(result.matchedAnchors >= 2)
    }

    @Test func ignoresSilentRegionsWhenContentOverlaps() throws {
        let content = signal(count: 1_200)
        let reference = [Float](repeating: 0, count: 300)
            + content
            + [Float](repeating: 0, count: 300)
        let target = [Float](repeating: 0, count: 200)
            + Array(content[200..<1_000])
            + [Float](repeating: 0, count: 200)
        let assessment = AudioSyncCorrelator.match(
            reference: reference,
            target: target,
            maxLagHops: 500,
            minOverlapHops: 160
        )
        let result = try #require(assessment.result)
        #expect(assessment.failure == nil)
        #expect(abs(result.lagHops - 300) <= 2)
        #expect(result.matchedAnchors >= 2)
    }

    @Test func rejectsAllSilence() {
        let silence = [Float](repeating: 0, count: 1_000)
        let assessment = AudioSyncCorrelator.match(
            reference: silence,
            target: silence,
            maxLagHops: 300,
            minOverlapHops: 200
        )
        #expect(assessment.result == nil)
        #expect(assessment.failure == .silence)
    }

    @Test func multipleAnchorsResolveARepeatedOpening() throws {
        let repeated = signal(count: 600, seed: 10)
        let unique = signal(count: 600, seed: 20)
        let target = repeated + unique
        let reference = repeated + repeated + target
        let assessment = AudioSyncCorrelator.match(
            reference: reference,
            target: target,
            maxLagHops: 1_400,
            minOverlapHops: 180
        )
        let result = try #require(assessment.result)
        #expect(assessment.failure == nil)
        #expect(abs(result.lagHops - 1_200) <= 2)
        #expect(result.matchedAnchors >= 3)
    }

    @Test func rejectsEquallyPlausibleFullRepetitions() throws {
        let motif = signal(count: 800, seed: 30)
        let assessment = AudioSyncCorrelator.match(
            reference: motif + motif,
            target: motif,
            maxLagHops: 900,
            minOverlapHops: 180
        )
        let result = try #require(assessment.result)
        #expect(assessment.failure == .ambiguous)
        #expect(result.isAmbiguous)
        #expect(result.confidence < 0.5)
    }

    @Test func estimatesOffsetDespiteRecorderDrift() throws {
        let reference = smooth(signal(count: 6_500, seed: 40))
        let base = 320.0
        let drift = 0.002
        let target: [Float] = (0..<4_500).map { index in
            let position = base + Double(index) * (1 + drift)
            let lower = Int(position.rounded(.down))
            let fraction = Float(position - Double(lower))
            return reference[lower] * (1 - fraction) + reference[lower + 1] * fraction
        }
        let assessment = AudioSyncCorrelator.match(
            reference: reference,
            target: target,
            maxLagHops: 600,
            minOverlapHops: 220,
            maxDriftPPM: 3_000
        )
        let result = try #require(assessment.result)
        #expect(assessment.failure == nil)
        #expect(abs(result.lagHops - 320) <= 4)
        #expect(abs(result.driftPPM - 2_000) < 800)
        #expect(result.matchedAnchors >= 4)
    }

    @Test func reportsDriftThatCannotBeFixedByMovingAlone() throws {
        let reference = smooth(signal(count: 6_500, seed: 41))
        let target: [Float] = (0..<4_500).map { index in
            let position = 320.0 + Double(index) * 1.002
            let lower = Int(position.rounded(.down))
            let fraction = Float(position - Double(lower))
            return reference[lower] * (1 - fraction) + reference[lower + 1] * fraction
        }
        let assessment = AudioSyncCorrelator.match(
            reference: reference,
            target: target,
            maxLagHops: 600,
            minOverlapHops: 220
        )
        let result = try #require(assessment.result)
        #expect(assessment.failure == .excessiveDrift)
        #expect(abs(result.driftPPM) > AudioSyncCorrelator.defaultMaxDriftPPM)
    }

    @Test func captureDateSeedCanFindOffsetOutsideBroadWindow() throws {
        let reference = signal(count: 3_200, seed: 50)
        let target = Array(reference[1_500..<2_500])
        let broad = AudioSyncCorrelator.match(
            reference: reference,
            target: target,
            maxLagHops: 200,
            minOverlapHops: 180
        )
        #expect(broad.failure != nil)

        let seeded = AudioSyncCorrelator.match(
            reference: reference,
            target: target,
            maxLagHops: 100,
            centerLagHops: 1_480,
            minOverlapHops: 180
        )
        let result = try #require(seeded.result)
        #expect(seeded.failure == nil)
        #expect(abs(result.lagHops - 1_500) <= 1)
    }

    @Test func rejectsUnrelatedAudio() {
        let assessment = AudioSyncCorrelator.match(
            reference: signal(count: 2_000, seed: 60),
            target: signal(count: 1_400, seed: 70),
            maxLagHops: 500,
            minOverlapHops: 180
        )
        #expect(assessment.failure == .weakCorrelation || assessment.failure == .noConsensus)
        #expect((assessment.result?.confidence ?? 0) < 0.7)
    }

    @Test func rejectsInsufficientOverlapAndEmptyInput() {
        #expect(AudioSyncCorrelator.match(
            reference: signal(count: 100),
            target: signal(count: 100),
            maxLagHops: 50,
            minOverlapHops: 200
        ).failure == .insufficientOverlap)
        #expect(AudioSyncCorrelator.match(
            reference: [],
            target: [1, 2, 3],
            maxLagHops: 5
        ).failure == .insufficientOverlap)
    }
}
