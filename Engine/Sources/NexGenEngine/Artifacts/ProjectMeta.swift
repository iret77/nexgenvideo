import Foundation

/// Generic workflow mode. A pack may use a subset (music uses phrase/section);
/// duration semantics per mode live in a pack's `DurationPolicy`, not here.
/// Port of `core/modes.py::Mode`.
public enum Mode: String, Codable, Sendable, CaseIterable {
    case beat
    case phrase
    case section
    case multicam
    case generic  // Swift-side follow-up (issue #99); Python modes.py has no such case yet.
}

/// Project metadata (`project.yaml`): mode + budget per project.
/// Port of `core/project.py::ProjectMeta`.
public struct ProjectMeta: Codable, Sendable, Equatable {
    public var project: String
    public var mode: Mode
    /// Python: `Annotated[float, Field(gt=0)] = 50.0`. The `gt=0` constraint is
    /// enforced in `validate()` below — Codable itself has no range checks.
    public var budgetEur: Double
    public var created: String?

    private enum CodingKeys: String, CodingKey {
        case project
        case mode
        case budgetEur = "budget_eur"
        case created
    }

    public init(project: String, mode: Mode, budgetEur: Double = 50.0, created: String? = nil) {
        self.project = project
        self.mode = mode
        self.budgetEur = budgetEur
        self.created = created
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(String.self, forKey: .project)
        mode = try container.decode(Mode.self, forKey: .mode)
        budgetEur = try container.decodeIfPresent(Double.self, forKey: .budgetEur) ?? 50.0
        created = try container.decodeIfPresent(String.self, forKey: .created)
        try validate()
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case budgetNotPositive(Double)
    }

    /// Mirrors pydantic's `Field(gt=0)` on `budget_eur`, checked explicitly
    /// since Codable has no field-level constraints of its own.
    public func validate() throws {
        guard budgetEur > 0 else { throw ValidationError.budgetNotPositive(budgetEur) }
    }
}
