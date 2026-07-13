import Foundation
import Testing
@testable import MusicvideoPlugin

/// BIC-on-MFCC structure detector (A2). Exercised on synthetic MFCC directly —
/// `segment` takes a feature matrix, so it does no FFT and runs fine under the
/// swiftpm runner (unlike the full pipeline, #118).
@Suite("BIC structure detector")
struct BICStructureTests {
    static let d = 13
    static let sr = 22050.0
    static let hop = 512
    static var frameDur: Double { Double(hop) / sr }

    /// One MFCC frame: `base` mean + a deterministic, block-independent jitter
    /// (same wobble in every block, so blocks differ only by their mean → the
    /// boundary is a genuine distribution shift, not a covariance artifact).
    static func frame(_ k: Int, base: Double) -> [Double] {
        (0..<d).map { i in base + 0.5 * sin(Double(k) * 0.3 + Double(i) * 0.7) }
    }

    static func block(count: Int, startK: Int, base: Double) -> [[Double]] {
        (0..<count).map { frame(startK + $0, base: base) }
    }

    @Test("ΔBIC is positive across a real distribution shift, negative within one")
    func deltaBICSign() {
        let different = block(count: 200, startK: 0, base: 5) + block(count: 200, startK: 200, base: -5)
        let same = block(count: 400, startK: 0, base: 5)
        let pd = BICStructure.Prefix(frames: different, d: Self.d)
        let ps = BICStructure.Prefix(frames: same, d: Self.d)
        #expect(BICStructure.deltaBIC(prefix: pd, d: Self.d, left: 0, mid: 200, right: 400, penaltyWeight: 1.5) > 0)
        #expect(BICStructure.deltaBIC(prefix: ps, d: Self.d, left: 0, mid: 200, right: 400, penaltyWeight: 1.5) < 0)
    }

    @Test("segment splits two long, distinct timbres at their join")
    func segmentsAtTimbreChange() {
        let n = 800
        let frames = block(count: 400, startK: 0, base: 5) + block(count: 400, startK: 400, base: -5)
        let duration = Double(n) * Self.frameDur
        let secs = BICStructure.segment(mfcc: frames, hop: Self.hop, sampleRate: Self.sr, duration: duration)
        #expect(secs.count >= 2)
        #expect(secs.allSatisfy { $0.source == "essentia" })
        let joinS = Double(400) * Self.frameDur
        let boundaries = secs.dropFirst().map(\.start)
        #expect(boundaries.contains { abs($0 - joinS) <= 1.0 }, "sections=\(secs.map { ($0.start, $0.end) })")
        // Full coverage, contiguous.
        #expect(secs.first?.start == 0.0)
        #expect(abs((secs.last?.end ?? 0) - duration) < 0.05)
    }

    @Test("homogeneous audio yields a single section")
    func homogeneousOneSection() {
        let n = 800
        let frames = block(count: n, startK: 0, base: 5)
        let duration = Double(n) * Self.frameDur
        let secs = BICStructure.segment(mfcc: frames, hop: Self.hop, sampleRate: Self.sr, duration: duration)
        #expect(secs.count == 1)
        #expect(secs.first?.start == 0.0)
    }

    @Test("too few frames falls back to a single section")
    func tooFewFrames() {
        let frames = block(count: 10, startK: 0, base: 5)
        let secs = BICStructure.segment(mfcc: frames, hop: Self.hop, sampleRate: Self.sr, duration: 5.0)
        #expect(secs.count == 1)
        #expect(secs.first?.start == 0.0 && secs.first?.end == 5.0)
        #expect(secs.first?.source == "essentia")
    }
}
