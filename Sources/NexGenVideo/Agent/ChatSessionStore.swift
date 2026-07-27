import Foundation

struct ChatSession: Codable, Identifiable {
    let id: UUID
    var title: String
    var updatedAt: Date
    var messages: [AgentMessage]
    var isOpen: Bool
    /// `claude`'s own session id for this chat, once known. Persisted so reopening the tab or reloading
    /// the project can `--resume` the exact conversation instead of starting the agent from scratch.
    var claudeSessionId: String?

    init(id: UUID = UUID(), title: String = "New chat", messages: [AgentMessage] = [], isOpen: Bool = true) {
        self.id = id
        self.title = title
        self.updatedAt = Date()
        self.messages = messages
        self.isOpen = isOpen
        self.claudeSessionId = nil
    }

    private enum CodingKeys: String, CodingKey { case id, title, updatedAt, messages, isOpen, claudeSessionId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        self.messages = try c.decode([AgentMessage].self, forKey: .messages)
        self.isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
        self.claudeSessionId = try c.decodeIfPresent(String.self, forKey: .claudeSessionId)
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
