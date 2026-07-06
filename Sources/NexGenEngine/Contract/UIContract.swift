import Foundation

/// The minimal plugin UI contract: each phase declares its default interaction
/// surface and its router task class. Core phases carry engine defaults; packs
/// override or extend them. Port of `core/ui_contract.py`.
public enum UIContract {
    public static let surfaces: [String] = ["choice", "prose", "review"]

    /// One phase's contract entry.
    public struct Entry: Sendable, Equatable {
        public let surface: String
        public let taskClass: String

        public init(surface: String, taskClass: String) {
            self.surface = surface
            self.taskClass = taskClass
        }
    }

    /// Engine defaults for the core phases, in declaration order (so
    /// `fullContract` can preserve it). Port of `ui_contract.py::CORE_CONTRACT`.
    public static let coreContract: [(phase: String, entry: Entry)] = [
        ("project_init", Entry(surface: "choice", taskClass: "assembly")),
        ("brief", Entry(surface: "prose", taskClass: "interpretation")),
        ("production_design", Entry(surface: "review", taskClass: "planning")),
        ("treatment", Entry(surface: "prose", taskClass: "interpretation")),
        ("storyboard", Entry(surface: "review", taskClass: "planning")),
        ("bible", Entry(surface: "review", taskClass: "planning")),
        ("shotlist", Entry(surface: "review", taskClass: "planning")),
        ("sanity", Entry(surface: "review", taskClass: "classification")),
        ("frames", Entry(surface: "review", taskClass: "review")),
        ("render", Entry(surface: "choice", taskClass: "assembly")),
    ]

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case badSurface(phase: String, surface: String)
        case badTaskClass(phase: String, taskClass: String)
    }

    /// Validate a `(surface, task_class)` entry for a phase against the allowed
    /// surfaces and the router's task classes. Port of `ui_contract.py::validate_entry`.
    @discardableResult
    public static func validateEntry(phase: String, surface: String, taskClass: String) throws -> Entry {
        guard surfaces.contains(surface) else {
            throw ValidationError.badSurface(phase: phase, surface: surface)
        }
        guard ModelRouter.taskClasses.contains(where: { $0.name == taskClass }) else {
            throw ValidationError.badTaskClass(phase: phase, taskClass: taskClass)
        }
        return Entry(surface: surface, taskClass: taskClass)
    }

    /// The full contract map: core defaults overlaid with the installed packs'
    /// declarations (`packEntries`, keyed by phase). Port of
    /// `ui_contract.py::full_contract` — the Python discovers packs at runtime;
    /// the pure engine takes them as a parameter (the host passes them in).
    public static func fullContract(packEntries: [String: Entry] = [:]) -> [String: Entry] {
        var contract: [String: Entry] = [:]
        for (phase, entry) in coreContract { contract[phase] = entry }
        for (phase, entry) in packEntries { contract[phase] = entry }
        return contract
    }
}
