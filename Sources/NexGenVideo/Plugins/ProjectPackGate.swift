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
        /// The project is pinned to a version that isn't installed on this Mac.
        case missingVersion(id: String, version: String)
        /// Installed but the load gate refused it (contract, version, signature, damage).
        case incompatible(id: String, reason: String)
        /// The exact version is installed, but another version's code is resident in this process.
        case needsRestart(ProjectPackBinding)
        /// An id-only project needs explicit adoption of the live pack's schema.
        case legacyMigration(target: ProjectPackBinding)
    }

    /// Pure decision. `isRegistered` = the pack answered `PackCatalog.pack(named:)`; `record` is the
    /// loader's entry for that id (nil = nothing installed under it).
    static func requirement(
        packID: String?, isRegistered: Bool, record: InstalledPluginRecord?
    ) -> Requirement {
        guard let packID, !packID.isEmpty else { return .satisfied }
        guard let record else { return .missing(id: packID) }
        if let reason = record.incompatibility { return .incompatible(id: packID, reason: reason.reason) }
        if record.isUpdatePendingRestart {
            guard let binding = ProjectPackBinding(
                id: packID,
                version: record.version,
                projectSchema: record.projectSchema
            ) else {
                return .incompatible(
                    id: packID,
                    reason: "The installed update has invalid format metadata."
                )
            }
            return .needsRestart(binding)
        }
        if isRegistered { return .satisfied }
        return .missing(id: packID)
    }

    @MainActor
    static func evaluate(
        projectURL: URL,
        declaredPack: String? = nil
    ) -> Requirement {
        switch ProjectPluginSettings.bindingResolution(projectURL: projectURL) {
        case .absent:
            if let declaredPack {
                return .settingsMissing(expected: declaredPack)
            }
            return .satisfied
        case .unreadable:
            return .unreadable
        case .legacy(let packID):
            if let declaredPack, declaredPack != packID {
                return .inconsistent(
                    expected: declaredPack,
                    resolved: packID
                )
            }
            if let pending = ProjectPackMigration.legacyTarget(
                for: projectURL
            ) {
                return require(binding: pending)
            }
            if let live = PluginLoader.liveBinding(id: packID) {
                if live.projectSchema == "\(packID)/legacy" {
                    return .satisfied
                }
                guard let info = PluginLoader.installedInfo(
                    id: live.id,
                    version: live.version
                )?.info,
                      info.migratesFrom.contains("\(packID)/legacy") else {
                    return .incompatible(
                        id: packID,
                        reason: "The installed pack can't migrate this legacy project."
                    )
                }
                return .legacyMigration(target: live)
            }
            if PackCatalog.pack(named: packID) != nil {
                return .satisfied
            }
            return requirement(
                packID: packID,
                isRegistered: PackCatalog.pack(named: packID) != nil,
                record: PluginLoader.installed.first { $0.id == packID }
            )
        case .bound(let binding):
            let required = ProjectPackMigration.effectiveBinding(
                persisted: binding,
                projectURL: projectURL
            )
            if let declaredPack, declaredPack != required.id {
                return .inconsistent(
                    expected: declaredPack,
                    resolved: required.id
                )
            }
            return require(binding: required)
        }
    }

    @MainActor
    private static func require(
        binding: ProjectPackBinding
    ) -> Requirement {
        if PluginLoader.liveBinding(id: binding.id) == binding {
            return .satisfied
        }
        guard let installed = PluginLoader.installedInfo(
            id: binding.id,
            version: binding.version
        ) else {
            return .missingVersion(id: binding.id, version: binding.version)
        }
        guard installed.info.projectSchema == binding.projectSchema else {
            return .incompatible(
                id: binding.id,
                reason: "Installed version \(binding.version) uses project schema "
                    + "\(installed.info.projectSchema), not \(binding.projectSchema)."
            )
        }
        if let reason = PluginGate.evaluate(
            info: installed.info,
            appVersion: AppVersion.marketing
        ) {
            return .incompatible(id: binding.id, reason: reason.reason)
        }
        if let reason = PluginSignature.verify(
            bundleURL: installed.url,
            host: PluginSignature.hostSigningState()
        ) {
            return .incompatible(id: binding.id, reason: reason.reason)
        }
        if let reason = PluginLoader.runtimeRejection(
            id: binding.id,
            version: binding.version
        ) {
            return .incompatible(
                id: binding.id,
                reason: "Installed version \(binding.version) failed to load: \(reason)."
            )
        }
        guard let record = PluginLoader.activate(binding) else {
            return .needsRestart(binding)
        }
        if let reason = record.incompatibility {
            return .incompatible(id: binding.id, reason: reason.reason)
        }
        return record.isLoaded ? .satisfied : .needsRestart(binding)
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
