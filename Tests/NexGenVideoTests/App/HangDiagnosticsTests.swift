import Foundation
import HangDiagnostics
import Testing
@testable import NexGenVideo

@Suite("Bounded hang diagnostics")
struct HangDiagnosticsTests {
    @Test func acknowledgedNoticeSurvivesRestartAndNewHangStillNotifies() throws {
        let suite = "hang-notice-tests-\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: suite))
        defer { first.removePersistentDomain(forName: suite) }
        #expect(DiagnosticNotifications.acknowledge(["session/first"], defaults: first) == ["session/first"])
        let restarted = try #require(UserDefaults(suiteName: suite))
        #expect(DiagnosticNotifications.acknowledge(["session/first"], defaults: restarted).isEmpty)
        #expect(DiagnosticNotifications.acknowledge(["session/second"], defaults: restarted) == ["session/second"])
        #expect(DiagnosticNotifications.acknowledge(["session/second"], defaults: restarted).isEmpty)
    }

    @Test(arguments: ["pinned.json", "sample-request.json", "incident-example", "self-example.stacks",
                      "replay-000000000001.enc", "exported.json"])
    func evidenceSurvivesRepeatedStartsAndExpiry(marker: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = root.appendingPathComponent(UUID().uuidString)
        try DiagnosticFiles.directory(evidence)
        try DiagnosticFiles.write(Data("preserved".utf8), to: evidence.appendingPathComponent(marker))
        for _ in 0..<12 {
            try DiagnosticFiles.directory(root.appendingPathComponent(UUID().uuidString))
            let sessions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let deletions = try DiagnosticRetention.removableRecordings(sessions, now: Date().addingTimeInterval(30 * 86400))
            #expect(!deletions.contains(evidence))
            for folder in deletions { try FileManager.default.removeItem(at: folder) }
        }
        #expect(try Data(contentsOf: evidence.appendingPathComponent(marker)) == Data("preserved".utf8))
    }

    @Test func emptySessionsRemainBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try DiagnosticFiles.directory(root)
        for _ in 0..<8 { try DiagnosticFiles.directory(root.appendingPathComponent(UUID().uuidString)) }
        let sessions = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(try DiagnosticRetention.removableRecordings(sessions).count == 6)
    }

    @Test func storageLimitRefusesNewRecordingWithoutRemovingEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try DiagnosticFiles.directory(root)
        let file = root.appendingPathComponent("replay-000000000001.enc")
        try DiagnosticFiles.write(Data(), to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 1024 * 1024 * 1024)
        #expect(throws: CocoaError.self) { try DiagnosticRetention.checkStorageBudget(at: root) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

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

    @Test(arguments: [false, true]) func exportIncludesOnlyCompletedKnownFiles(directoryURL: Bool) throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source", isDirectory: directoryURL)
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

    @Test func exportRejectsSymlinkedRecording() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        try DiagnosticFiles.directory(source)
        let link = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) {
            try DiagnosticFiles.copyRecording(from: link, to: base.appendingPathComponent("export"))
        }
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

    @Test func legacyProjectContextDecodesWithoutWorkspaceFields() throws {
        let context = HangDiagnosticTranscript.ProjectContext(
            timeline: Timeline(), manifest: MediaManifest(), pipeline: nil,
            binding: nil, revision: 3, workspaceFocus: "produce", cockpitTab: "Pipeline"
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        object.removeValue(forKey: "workspaceFocus")
        object.removeValue(forKey: "cockpitTab")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(HangDiagnosticTranscript.ProjectContext.self, from: legacy)
        #expect(decoded.workspaceFocus == nil)
        #expect(decoded.cockpitTab == nil)
    }

    @Test @MainActor func replayUsesInjectedBackendWithoutChangingPreferences() {
        let service = AgentService(
            backend: .claudeCode,
            refreshBackendStatusOnInit: false
        )
        let editor = EditorViewModel(agentService: service)
        #expect(editor.agentService === service)
        #expect(editor.agentService.backend == .claudeCode)
    }

    @Test @MainActor func replayActivationCombinesWindowsFromTheSameHeartbeat() {
        let records = [
            DiagnosticRecord(sequence: 1, uptime: 1, operation: .window,
                             values: [1, 1463, 1040, 2, 0, 1]),
            DiagnosticRecord(sequence: 2, uptime: 2, operation: .window,
                             values: [1, 1463, 1040, 2, 0, 0]),
            DiagnosticRecord(sequence: 3, uptime: 3, operation: .window,
                             values: [1, 1463, 1040, 2, 1, 0]),
            DiagnosticRecord(sequence: 4, uptime: 3.001, operation: .window,
                             values: [2, 881, 448, 2, 1, 1]),
        ]
        #expect(HangDiagnosticReplay.recordedActivationTimeline(in: records) == [
            .init(uptime: 1, active: true),
            .init(uptime: 2, active: false),
            .init(uptime: 3, active: true),
        ])
        let editorWindow = HangDiagnosticReplay.recordedEditorWindow(in: records)
        #expect(editorWindow?.values[0] == 1)
        #expect(editorWindow?.values[1] == 1463)
        #expect(editorWindow?.values[2] == 1040)
    }
}
