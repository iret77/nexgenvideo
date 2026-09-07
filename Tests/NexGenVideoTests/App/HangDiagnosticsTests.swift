import Foundation
import HangDiagnostics
import Testing
@testable import NexGenVideo

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

    @Test func nestedToolJSONRemainsDecodableAfterRedaction() throws {
        let nested = #"{"api_key":"arbitrary-canary","url":"https://example.com/image?signature=private-canary"}"#
        let bytes = try JSONEncoder().encode(["input": nested])
        let scrubbed = DiagnosticPrivacy.scrubJSON(bytes)
        let decoded = try JSONDecoder().decode([String: String].self, from: scrubbed)
        let input = try JSONDecoder().decode([String: String].self, from: Data(decoded["input"]!.utf8))
        #expect(input["api_key"] == "[redacted]")
        #expect(!String(decoding: scrubbed, as: UTF8.self).contains("private-canary"))
    }

    @Test func exportIncludesOnlyCompletedKnownFiles() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("export")
        try DiagnosticFiles.directory(source)
        try DiagnosticFiles.write(Data("[]".utf8), to: source.appendingPathComponent("events-000000000001.json"))
        try DiagnosticFiles.write(Data("private".utf8), to: source.appendingPathComponent("unrelated.json"))
        try DiagnosticFiles.write(Data("partial".utf8), to: source.appendingPathComponent("capture.stacks.partial"))
        try DiagnosticFiles.copyRecording(from: source, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("events-000000000001.json").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("unrelated.json").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("capture.stacks.partial").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("checksums.json").path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func replayFrameDoesNotRepeatUnchangedImages() throws {
        let image = AgentMessage(role: .assistant, blocks: [.toolResult(toolUseId: "synthetic",
            content: [.image(base64: String(repeating: "A", count: 1_000_000), mediaType: "image/png")], isError: false)])
        let before = HangDiagnosticTranscript(messages: [image], streaming: true, sessionID: nil,
                                             dialog: nil, spend: nil, project: nil)
        let text = AgentMessage(role: .assistant, blocks: [.text("New text")])
        let after = HangDiagnosticTranscript(messages: [image, text], streaming: true, sessionID: nil,
                                            dialog: nil, spend: nil, project: nil)
        let frame = HangDiagnosticReplayFrame(sequence: 2, predecessor: "previous-frame", previous: before, current: after)
        #expect(frame.updates == [text])
        #expect(try JSONEncoder().encode(frame).count < 2048)
        #expect(try frame.apply(to: before).messages == after.messages)
        #expect(throws: (any Error).self) { try frame.apply(to: nil) }
    }
}
