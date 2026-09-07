import Foundation

struct HangDiagnosticTranscript: Codable, Sendable {
    let messages: [AgentMessage]
    let streaming: Bool
    let sessionID: UUID?

    static func capture(messages: [AgentMessage], streaming: Bool, sessionID: UUID? = nil) {
        let recorder = HangDiagnosticRecorder.shared
        guard recorder.isEnabled else { return }
        let id = recorder.record(.replaySnapshot, values: [Double(messages.count), streaming ? 1 : 0])
        recorder.snapshot(Self(messages: messages.map { message in
            var safe = message
            safe.contextHint = nil
            safe.mentions = []
            return safe
        }, streaming: streaming, sessionID: sessionID), correlation: id)
    }
}
