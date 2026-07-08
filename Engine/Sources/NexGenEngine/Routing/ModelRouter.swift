import Foundation
import Yams

/// Deliberate compute: which model and how much thinking a task gets is assigned
/// by **task class** — a fixed floor per class, with a bounded one-step
/// escalation. Tiers (not model ids) resolve through a manifest naming the
/// latest model of each family; a project's `models.yaml` overrides the shipped
/// defaults. Port of `core/router.py`.
public enum ModelRouter {
    public static let tiers: [String] = ["fast", "medium", "deep"]

    /// Shipped tier→model floors. Port of `router.py::DEFAULT_MANIFEST`.
    public static let defaultManifest: [String: String] = [
        "fast": "claude-haiku-4-5",
        "medium": "claude-sonnet-5",
        "deep": "claude-opus-4-8",
    ]

    /// Per-class `(tier, effort)` floor. Ordered so `describe` can emit it in the
    /// same order the Python dict declares. Port of `router.py::TASK_CLASSES`.
    public static let taskClasses: [(name: String, tier: String, effort: String)] = [
        ("distill", "fast", "low"),
        ("classification", "fast", "low"),
        ("assembly", "medium", "low"),
        ("review", "medium", "low"),
        ("planning", "deep", "high"),
        ("interpretation", "deep", "high"),
    ]

    public static let manifestFilename = "models.yaml"

    /// Floor lookup keyed by class name.
    private static func floor(_ taskClass: String) -> (tier: String, effort: String)? {
        taskClasses.first { $0.name == taskClass }.map { ($0.tier, $0.effort) }
    }

    public struct UnknownTaskClass: Swift.Error, Sendable, Equatable {
        public let taskClass: String
    }

    /// Shipped defaults overlaid with a project's `models.yaml` (known tiers
    /// only). A malformed / non-mapping file is ignored, matching the Python
    /// `try/except` + `isinstance(dict)` tolerance. Port of `router.py::manifest`.
    public static func manifest(dataRoot: URL? = nil) -> [String: String] {
        var resolved = defaultManifest
        guard let dataRoot else { return resolved }
        let path = dataRoot.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: path.path),
              let text = try? String(contentsOf: path, encoding: .utf8),
              let loaded = try? Yams.load(yaml: text),
              let mapping = loaded as? [String: Any]
        else { return resolved }
        for tier in tiers {
            if let value = mapping[tier] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { resolved[tier] = trimmed }
            }
        }
        return resolved
    }

    /// The resolved routing decision for a task class. Port of the dict
    /// `router.resolve` returns.
    public struct Resolution: Sendable, Equatable {
        public let taskClass: String
        public let tier: String
        public let model: String
        public let effort: String
        public let escalated: Bool
    }

    /// Floor for the task class; with `escalate` exactly one tier up (bounded at
    /// `deep`). Throws `UnknownTaskClass` for an unknown class. Port of
    /// `router.py::resolve`.
    public static func resolve(
        _ taskClass: String, escalate: Bool = false, dataRoot: URL? = nil
    ) throws -> Resolution {
        guard let floor = floor(taskClass) else { throw UnknownTaskClass(taskClass: taskClass) }
        var tier = floor.tier
        var escalated = false
        if escalate, let index = tiers.firstIndex(of: tier), index + 1 < tiers.count {
            tier = tiers[index + 1]
            escalated = true
        }
        return Resolution(
            taskClass: taskClass,
            tier: tier,
            model: manifest(dataRoot: dataRoot)[tier] ?? tier,
            effort: floor.effort,
            escalated: escalated
        )
    }
}
