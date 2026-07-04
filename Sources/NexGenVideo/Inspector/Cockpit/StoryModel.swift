import Foundation

// Mirrors the engine's `brief` / `treatment` / `contract` read kinds. Defensive decoding: the app
// shows what exists and never invents fields; enums arrive as raw strings.

struct BriefData: Decodable, Sendable, Equatable {
    var project: String
    var mission: String
    var targetPlatform: String
    var targetAudience: String?
    var aspectRatio: String
    var lengthMode: String
    var projectMode: String
    var budgetEur: Double
    var visualMedium: String
    var visualMediumNotes: String?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case project, mission, notes
        case targetPlatform = "target_platform"
        case targetAudience = "target_audience"
        case aspectRatio = "aspect_ratio"
        case lengthMode = "length_mode"
        case projectMode = "project_mode"
        case budgetEur = "budget_eur"
        case visualMedium = "visual_medium"
        case visualMediumNotes = "visual_medium_notes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        mission = try c.decodeIfPresent(String.self, forKey: .mission) ?? ""
        targetPlatform = try c.decodeIfPresent(String.self, forKey: .targetPlatform) ?? ""
        targetAudience = try c.decodeIfPresent(String.self, forKey: .targetAudience)
        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio) ?? ""
        lengthMode = try c.decodeIfPresent(String.self, forKey: .lengthMode) ?? ""
        projectMode = try c.decodeIfPresent(String.self, forKey: .projectMode) ?? ""
        budgetEur = try c.decodeIfPresent(Double.self, forKey: .budgetEur) ?? 0
        visualMedium = try c.decodeIfPresent(String.self, forKey: .visualMedium) ?? ""
        visualMediumNotes = try c.decodeIfPresent(String.self, forKey: .visualMediumNotes)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

struct TreatmentData: Decodable, Sendable, Equatable {
    var version: Int
    var bodyMarkdown: String

    enum CodingKeys: String, CodingKey {
        case meta
        case bodyMarkdown = "body_markdown"
    }

    private struct Meta: Decodable {
        var version: Int?
        enum CodingKeys: String, CodingKey { case version }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try? c.decodeIfPresent(Int.self, forKey: .version)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = ((try? c.decodeIfPresent(Meta.self, forKey: .meta)) ?? nil)?.version ?? 1
        bodyMarkdown = try c.decodeIfPresent(String.self, forKey: .bodyMarkdown) ?? ""
    }
}

/// The per-phase UI contract (surface + task class) — drives phase routing in the Pipeline panel.
struct ContractData: Decodable, Sendable, Equatable {
    var phases: [String: ContractEntry]

    enum CodingKeys: String, CodingKey { case phases }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phases = try c.decodeIfPresent([String: ContractEntry].self, forKey: .phases) ?? [:]
    }
}

struct ContractEntry: Decodable, Sendable, Equatable {
    var surface: String
    var taskClass: String

    enum CodingKeys: String, CodingKey {
        case surface
        case taskClass = "task_class"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decodeIfPresent(String.self, forKey: .surface) ?? ""
        taskClass = try c.decodeIfPresent(String.self, forKey: .taskClass) ?? ""
    }
}
