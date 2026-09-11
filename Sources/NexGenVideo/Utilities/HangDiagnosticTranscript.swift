import Foundation

struct HangDiagnosticTranscript: Codable, Sendable {
    let messages: [AgentMessage]
    let streaming: Bool
    let sessionID: UUID?
    let dialog: AgentDialog?
    let spend: SpendApproval?
    let project: ProjectContext?

    struct ProjectContext: Codable, Sendable, Equatable {
        let timeline: Timeline
        let manifest: MediaManifest
        let pipeline: ProjectStateData?
        let binding: ProjectPackBinding?
        let revision: Int
        let workspaceFocus: String?
        let cockpitTab: String?

        init(timeline: Timeline, manifest: MediaManifest, pipeline: ProjectStateData?,
             binding: ProjectPackBinding?, revision: Int, workspaceFocus: String? = nil,
             cockpitTab: String? = nil) {
            self.timeline = timeline
            self.manifest = manifest
            self.pipeline = pipeline
            self.binding = binding
            self.revision = revision
            self.workspaceFocus = workspaceFocus
            self.cockpitTab = cockpitTab
        }
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

struct HangDiagnosticReplayFrame: Codable, Sendable {
    let sequence: UInt64
    let uptime: Double
    let predecessor: String?
    let order: [UUID]
    let updates: [AgentMessage]
    let streaming: Bool
    let sessionID: UUID?
    let dialog: AgentDialog?
    let spend: SpendApproval?
    let projectChanged: Bool
    let project: HangDiagnosticTranscript.ProjectContext?

    init(sequence: UInt64, uptime: Double = ProcessInfo.processInfo.systemUptime,
         predecessor: String?, previous: HangDiagnosticTranscript?,
         current: HangDiagnosticTranscript) {
        self.sequence = sequence
        self.uptime = uptime
        self.predecessor = predecessor
        let old = Dictionary((previous?.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        order = current.messages.map(\.id)
        updates = current.messages.filter { old[$0.id] != $0 }
        streaming = current.streaming
        sessionID = current.sessionID
        dialog = current.dialog
        spend = current.spend
        projectChanged = previous?.project != current.project
        project = projectChanged ? current.project : nil
    }

    func apply(to previous: HangDiagnosticTranscript?) throws -> HangDiagnosticTranscript {
        var messages = Dictionary((previous?.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in updates { messages[message.id] = message }
        guard Set(order).count == order.count, order.allSatisfy({ messages[$0] != nil }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return HangDiagnosticTranscript(messages: order.compactMap { messages[$0] }, streaming: streaming,
            sessionID: sessionID, dialog: dialog, spend: spend,
            project: projectChanged ? project : previous?.project)
    }
}
