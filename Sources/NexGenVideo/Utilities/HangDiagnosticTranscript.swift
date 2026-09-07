import Foundation

struct HangDiagnosticTranscript: Codable, Sendable {
    let messages: [AgentMessage]
    let streaming: Bool
    let sessionID: UUID?
    let dialog: AgentDialog?
    let spend: SpendApproval?
    let project: ProjectContext?

    struct ProjectContext: Codable, Sendable {
        let timeline: Timeline
        let manifest: MediaManifest
        let pipeline: ProjectStateData?
        let binding: ProjectPackBinding?
        let revision: Int
    }

    static func capture(messages: [AgentMessage], streaming: Bool, sessionID: UUID? = nil,
                        dialog: AgentDialog? = nil, spend: SpendApproval? = nil,
                        project: ProjectContext? = nil) {
        let recorder = HangDiagnosticRecorder.shared
        guard recorder.recordsContent else { return }
        let id = recorder.record(.replaySnapshot, values: [Double(messages.count), streaming ? 1 : 0])
        recorder.snapshot(Self(messages: messages.map { message in
            var safe = message
            safe.contextHint = nil
            safe.mentions = []
            return safe
        }, streaming: streaming, sessionID: sessionID, dialog: dialog, spend: spend, project: project), correlation: id)
    }
}
