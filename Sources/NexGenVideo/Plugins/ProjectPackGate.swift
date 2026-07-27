import Foundation
import NexGenEngine

/// Whether the format pack a project declares is actually LIVE in this session, checked before the
/// document is opened. Without it the project would open on the generic phase set (fewer phases, the
/// pack's analysis and gates off) and could be saved back in that shape — so the open is refused and
/// the pack offered instead. A project arriving from another machine, or a fresh install, is the
/// normal case here, not a defect.
enum ProjectPackGate {
    enum Requirement: Equatable {
        case satisfied
        /// The project contains format settings, but they cannot be decoded safely.
        case unreadable
        /// The trusted session declaration and live project settings disagree.
        case inconsistent(expected: String, resolved: String)
        /// A live session still declares a pack, but its settings file disappeared.
        case settingsMissing(expected: String)
        /// Declared pack isn't installed at all.
        case missing(id: String)
        /// Installed but the load gate refused it (contract, version, signature, damage).
        case incompatible(id: String, reason: String)
        /// A newer build is on disk but its code only goes live in a fresh process.
        case needsRestart(id: String)
    }

    /// Pure decision. `isRegistered` = the pack answered `PackCatalog.pack(named:)`; `record` is the
    /// loader's entry for that id (nil = nothing installed under it).
    static func requirement(
        packID: String?, isRegistered: Bool, record: InstalledPluginRecord?
    ) -> Requirement {
        guard let packID, !packID.isEmpty else { return .satisfied }
        if isRegistered { return .satisfied }
        guard let record else { return .missing(id: packID) }
        if let reason = record.incompatibility { return .incompatible(id: packID, reason: reason.reason) }
        if record.isUpdatePendingRestart { return .needsRestart(id: packID) }
        return .missing(id: packID)
    }

    @MainActor
    static func evaluate(
        projectURL: URL,
        declaredPack: String? = nil
    ) -> Requirement {
        switch ProjectPluginSettings.resolution(projectURL: projectURL) {
        case .absent:
            if let declaredPack {
                return .settingsMissing(expected: declaredPack)
            }
            return .satisfied
        case .unreadable:
            return .unreadable
        case .active(let packID):
            if let declaredPack, declaredPack != packID {
                return .inconsistent(
                    expected: declaredPack,
                    resolved: packID
                )
            }
            return requirement(
                packID: packID,
                isRegistered: PackCatalog.pack(named: packID) != nil,
                record: PluginLoader.installed.first { $0.id == packID }
            )
        }
    }
}

/// Refusal shown when a save is attempted while the project's format pack isn't active. Phrased as a
/// state of the world with a way out — not as a failure the user caused.
struct PackUnavailableError: LocalizedError {
    let packID: String
    /// The load gate's reason, when the pack is installed but unusable.
    let detail: String?

    var errorDescription: String? {
        "This project's “\(packID)” format pack isn't active, so it can't be saved."
    }

    var recoverySuggestion: String? {
        if let detail {
            return "\(detail) Update the pack, then reopen the project — nothing has been written, "
                + "so the last saved version is untouched."
        }
        return "Install the “\(packID)” pack from Settings → Plugins, then reopen the project. "
            + "Nothing has been written, so the last saved version is untouched."
    }
}

struct ProjectFormatSettingsUnavailableError: LocalizedError {
    let problem: String

    init(problem: String = "are unreadable") {
        self.problem = problem
    }

    var errorDescription: String? {
        "This project's format settings \(problem), so it can't be saved."
    }

    var recoverySuggestion: String? {
        "Restore ngv.json from a known-good project version, then reopen the project. "
            + "Nothing has been written, so the last saved version is untouched."
    }
}

struct ProjectSaveContextError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Save couldn't start in the app's main context."
    }

    var recoverySuggestion: String? {
        "Return to NexGenVideo and choose File → Save again. "
            + "Nothing has been written, so the last saved version is untouched."
    }
}
