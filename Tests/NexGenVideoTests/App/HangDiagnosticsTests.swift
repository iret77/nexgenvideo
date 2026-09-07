import Foundation
import HangDiagnostics
import Testing

@Suite("Bounded hang diagnostics")
struct HangDiagnosticsTests {
    @Test func ringNeverOverwritesUnconsumedEvents() {
        let ring = DiagnosticRing(capacity: 2)
        ring.append(.startup)
        ring.append(.projection)
        ring.append(.markdown)
        #expect(ring.dropped == 1)
        #expect(ring.drain().map(\.operation) == [.startup, .projection])
        #expect(ring.drain().isEmpty)
    }

    @Test func nonFiniteGeometryCannotPoisonJournal() throws {
        let ring = DiagnosticRing()
        ring.append(.scroll, values: [.infinity, .nan, 123])
        let values = ring.drain()
        #expect(values[0].values == [0, 0, 123])
        _ = try JSONEncoder().encode(values)
    }

    @Test func hangHasTwoSamplesAndOneRecovery() {
        var state = DiagnosticHangState()
        #expect(state.tick(now: 0, mainUptime: 0) == nil)
        #expect(state.tick(now: 2, mainUptime: 0) == .pin)
        #expect(state.tick(now: 5, mainUptime: 0) == .sample(1))
        for second in 6..<15 { #expect(state.tick(now: Double(second), mainUptime: 0) == nil) }
        #expect(state.tick(now: 15, mainUptime: 0) == .sample(2))
        #expect(state.tick(now: 16, mainUptime: 16) == .recovered)
        #expect(state.tick(now: 17, mainUptime: 17) == nil)
    }

    @Test func monitorSuspensionResetsBaseline() {
        var state = DiagnosticHangState()
        _ = state.tick(now: 0, mainUptime: 0)
        #expect(state.tick(now: 60, mainUptime: 0) == .suspended)
        #expect(state.tick(now: 61, mainUptime: 0) == nil)
    }

    @Test func replayRequiresExactPredecessor() throws {
        let before = Data("a long transcript with images".utf8)
        let after = Data("a long transcript with two images".utf8)
        let first = DiagnosticReplayDelta(sequence: 1, previous: nil, current: before)
        #expect(try first.apply(to: nil) == before)
        let second = DiagnosticReplayDelta(sequence: 2, previous: before, current: after)
        #expect(try second.apply(to: before) == after)
        #expect(throws: (any Error).self) { try second.apply(to: Data("wrong".utf8)) }
    }

    @Test func privacyFilterRemovesCredentialCanaries() throws {
        let bytes = try JSONEncoder().encode(["text": "sk-ant-abcdefghijklmnop Bearer abcdefghijklmnop"])
        let scrubbed = DiagnosticPrivacy.scrubJSON(bytes)
        #expect(!String(decoding: scrubbed, as: UTF8.self).contains("abcdefghijklmnop"))
        _ = try JSONDecoder().decode([String: String].self, from: scrubbed)
    }
}
