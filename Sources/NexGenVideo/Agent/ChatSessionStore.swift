import Foundation

enum ChatSessionAttention: Equatable {
    case running
    case actionRequired
    case unreadResult
}

struct AgentTask: Codable, Equatable {
    let title: String
    let systemImage: String
    let prompt: String
    var requiresDirection: Bool = false
    var originContext: String? = nil
    var replyToMessageID: UUID? = nil
}

struct ChatSessionDraft: Codable, Equatable {
    var text: String
    var mentions: [AgentMention]
    var task: AgentTask?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mentions.isEmpty && task == nil
    }
}

struct WorkflowIntakeDraftKey: Codable, Equatable {
    let packBinding: ProjectPackBinding?
    let phase: String
    let stepID: String
    let itemNumber: Int?
    let fingerprint: Int
    let isRepeat: Bool
}

struct ChatSessionDecision: Codable, Equatable {
    let dialog: AgentDialog
    let origin: ToolCallOrigin
    var draft: AgentDialogDraft
    var selections: [String: Set<String>]
    var intakeKey: WorkflowIntakeDraftKey? = nil

    func belongs(to sessionID: UUID) -> Bool {
        if dialog.purpose == .workflowIntake {
            return intakeKey != nil && origin == .direct
        }
        guard dialog.purpose == .chatClarification, intakeKey == nil else { return false }
        switch origin {
        case .direct: return true
        case .inAppChat(let id), .embeddedRuntime(let id, _): return id == sessionID
        case .externalMCP: return false
        }
    }
}

struct ChatSession: Codable, Identifiable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var messages: [AgentMessage]
    var isOpen: Bool
    /// `claude`'s own session id for this chat, once known. Persisted so reopening the tab or reloading
    /// the project can `--resume` the exact conversation instead of starting the agent from scratch.
    var claudeSessionId: String?
    var draft: ChatSessionDraft?
    var decision: ChatSessionDecision?

    var hasPersistedContent: Bool { !messages.isEmpty || draft?.isEmpty == false || decision != nil }

    init(id: UUID = UUID(), title: String = "New chat", messages: [AgentMessage] = [], isOpen: Bool = true) {
        self.id = id
        self.title = title
        self.updatedAt = Date()
        self.messages = messages
        self.isOpen = isOpen
        self.claudeSessionId = nil
        self.draft = nil
        self.decision = nil
    }

    private enum CodingKeys: String, CodingKey { case id, title, updatedAt, messages, isOpen, claudeSessionId, draft, decision }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messages = try c.decode([AgentMessage].self, forKey: .messages)
        self.isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
        self.claudeSessionId = try c.decodeIfPresent(String.self, forKey: .claudeSessionId)
        self.draft = try c.decodeIfPresent(ChatSessionDraft.self, forKey: .draft)
        self.decision = try c.decodeIfPresent(ChatSessionDecision.self, forKey: .decision)
    }
}

enum ChatSessionStore {
    static let dirName = "chat"

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func load(from projectURL: URL?) -> [ChatSession] {
        (try? loadThrowing(from: projectURL)) ?? []
    }

    static func loadThrowing(from projectURL: URL?) throws -> [ChatSession] {
        guard let dir = projectURL?.appendingPathComponent(dirName, isDirectory: true),
              FileManager.default.fileExists(atPath: dir.path)
        else {
            return []
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return try decoder.decode(
                    ChatSession.self,
                    from: Data(contentsOf: url)
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func encodeSession(_ session: ChatSession) -> Data? {
        try? encoder.encode(session)
    }
}
