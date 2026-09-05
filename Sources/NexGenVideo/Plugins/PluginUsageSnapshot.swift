import Foundation
import Observation

extension Notification.Name {
    static let projectRegistryChanged = Notification.Name("projectRegistryChanged")
    static let projectDocumentSetChanged = Notification.Name("projectDocumentSetChanged")
    static let projectPackBindingChanged = Notification.Name("projectPackBindingChanged")
}

struct ProjectPackUsage: Identifiable, Equatable, Sendable {
    let projectID: UUID
    let name: String
    let url: URL
    let isLegacyBinding: Bool

    var id: UUID { projectID }
}

struct PluginPackUsageEvidence: Equatable, Sendable {
    let packID: String
    let version: String?
    let knownProject: ProjectPackUsage?
    let isOpen: Bool

    static func exact(
        _ binding: ProjectPackBinding,
        knownProject: ProjectPackUsage? = nil,
        isOpen: Bool = false
    ) -> Self {
        Self(
            packID: binding.id,
            version: binding.version,
            knownProject: knownProject,
            isOpen: isOpen
        )
    }

    static func legacy(
        packID: String,
        knownProject: ProjectPackUsage? = nil,
        isOpen: Bool = false
    ) -> Self {
        Self(
            packID: packID,
            version: nil,
            knownProject: knownProject,
            isOpen: isOpen
        )
    }

    func applies(to installedVersion: InstalledPluginVersion) -> Bool {
        packID == installedVersion.packID
            && (version == nil || version == installedVersion.version)
    }
}

struct PluginVersionUsageState: Equatable, Sendable {
    let knownProjectUsages: [ProjectPackUsage]
    let isRequiredByOpenProject: Bool
    let isUsageVerified: Bool

    init(
        knownProjectUsages: [ProjectPackUsage],
        isRequiredByOpenProject: Bool,
        isUsageVerified: Bool = true
    ) {
        self.knownProjectUsages = knownProjectUsages
        self.isRequiredByOpenProject = isRequiredByOpenProject
        self.isUsageVerified = isUsageVerified
    }
}

struct PluginUsageSnapshot: Equatable, Sendable {
    private let statesByVersionID: [String: PluginVersionUsageState]

    static let empty = Self(statesByVersionID: [:])

    init(statesByVersionID: [String: PluginVersionUsageState]) {
        self.statesByVersionID = statesByVersionID
    }

    func state(for installedVersion: InstalledPluginVersion) -> PluginVersionUsageState? {
        statesByVersionID[installedVersion.id]
    }
}

struct PluginRemovalPresentation: Equatable, Sendable {
    let canRemove: Bool
    let subtitle: String
    let help: String
    let removalMessage: String

    static func resolve(
        installedVersion: InstalledPluginVersion,
        usage: PluginVersionUsageState?
    ) -> Self {
        guard installedVersion.isPresentOnDisk else {
            return Self(
                canRemove: false,
                subtitle: "Removed from disk. Restart NexGenVideo to unload it.",
                help: "Restart NexGenVideo to unload this version.",
                removalMessage: ""
            )
        }
        guard let usage else {
            return Self(
                canRemove: false,
                subtitle: "Checking project use…",
                help: "Checking whether a project requires this version.",
                removalMessage: "Wait until project use has been checked."
            )
        }
        guard usage.isUsageVerified else {
            return Self(
                canRemove: false,
                subtitle: "Project use could not be verified.",
                help: "Repair unreadable project format settings before removing this version.",
                removalMessage: "Project use could not be verified. "
                    + "Repair unreadable project format settings first."
            )
        }
        if usage.isRequiredByOpenProject {
            return Self(
                canRemove: false,
                subtitle: "Required by an open project.",
                help: "This version is required by an open project.",
                removalMessage: "Close the project before removing this version."
            )
        }

        let usageSubtitle: String?
        if usage.knownProjectUsages.count == 1 {
            usageSubtitle = "Required by \(usage.knownProjectUsages[0].name)."
        } else if usage.knownProjectUsages.count > 1 {
            usageSubtitle = "Required by \(usage.knownProjectUsages.count) known projects."
        } else {
            usageSubtitle = nil
        }

        var messageParts: [String] = []
        if !usage.knownProjectUsages.isEmpty {
            let names = usage.knownProjectUsages.map(\.name).joined(separator: ", ")
            messageParts.append(
                "The following projects require this exact version: \(names). "
                    + "They won't open until it is installed again."
            )
        }
        if installedVersion.isResident {
            messageParts.append("NexGenVideo must restart to unload this version.")
        } else {
            messageParts.append(
                "This removes only the selected version. "
                    + "Any other installed versions remain available."
            )
        }

        return Self(
            canRemove: true,
            subtitle: usageSubtitle
                ?? (installedVersion.isResident
                    ? "In use until NexGenVideo restarts."
                    : installedVersion.isLegacy
                        ? "Legacy installation."
                        : "Installed."),
            help: "Remove this installed format-pack version.",
            removalMessage: messageParts.joined(separator: " ")
        )
    }
}

enum PluginRemovalPolicy {
    nonisolated static func snapshot(
        installedVersions: [InstalledPluginVersion],
        evidence: [PluginPackUsageEvidence],
        isUsageVerified: Bool = true
    ) -> PluginUsageSnapshot {
        var states: [String: PluginVersionUsageState] = [:]
        for installedVersion in installedVersions {
            let matching = evidence.filter { $0.applies(to: installedVersion) }
            var projectsByID: [UUID: ProjectPackUsage] = [:]
            for project in matching.compactMap(\.knownProject) {
                projectsByID[project.projectID] = project
            }
            let projects = projectsByID.values.sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.url.path < $1.url.path
            }
            states[installedVersion.id] = PluginVersionUsageState(
                knownProjectUsages: projects,
                isRequiredByOpenProject: matching.contains(where: \.isOpen),
                isUsageVerified: isUsageVerified
            )
        }
        return PluginUsageSnapshot(statesByVersionID: states)
    }

    nonisolated static func loadSnapshot(
        installedVersions: [InstalledPluginVersion],
        registryEntries: [ProjectEntry],
        openProjectRoots: [[URL]]
    ) async -> PluginUsageSnapshot {
        await Task.detached(priority: .utility) {
            var observations: [PluginPackUsageEvidence] = []
            var isUsageVerified = true
            for entry in registryEntries {
                guard FileManager.default.fileExists(atPath: entry.url.path),
                      FileManager.default.isReadableFile(atPath: entry.url.path) else {
                    isUsageVerified = false
                    continue
                }
                let resolution = ProjectPluginSettings.bindingResolution(projectURL: entry.url)
                if case .unreadable = resolution {
                    isUsageVerified = false
                }
                guard let reference = evidence(
                    for: resolution,
                    knownProject: ProjectPackUsage(
                        projectID: entry.id,
                        name: entry.name,
                        url: entry.url,
                        isLegacyBinding: false
                    ),
                    isOpen: false
                ) else { continue }
                observations.append(reference)
            }
            for roots in openProjectRoots {
                for root in Set(roots.map(\.standardizedFileURL)) {
                    let resolution = ProjectPluginSettings.bindingResolution(projectURL: root)
                    if case .unreadable = resolution {
                        isUsageVerified = false
                    }
                    guard let reference = evidence(
                        for: resolution,
                        knownProject: nil,
                        isOpen: true
                    ) else { continue }
                    observations.append(reference)
                }
            }
            return snapshot(
                installedVersions: installedVersions,
                evidence: observations,
                isUsageVerified: isUsageVerified
            )
        }.value
    }

    private nonisolated static func evidence(
        for resolution: ProjectPluginSettings.BindingResolution,
        knownProject: ProjectPackUsage?,
        isOpen: Bool
    ) -> PluginPackUsageEvidence? {
        switch resolution {
        case .bound(let binding):
            return .exact(
                binding,
                knownProject: knownProject,
                isOpen: isOpen
            )
        case .legacy(let id):
            let usage = knownProject.map {
                ProjectPackUsage(
                    projectID: $0.projectID,
                    name: $0.name,
                    url: $0.url,
                    isLegacyBinding: true
                )
            }
            return .legacy(
                packID: id,
                knownProject: usage,
                isOpen: isOpen
            )
        case .absent, .unreadable:
            return nil
        }
    }
}

@MainActor
@Observable
final class PluginUsageSnapshotModel {
    private(set) var snapshot: PluginUsageSnapshot?
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    func refresh(
        installedVersions: [InstalledPluginVersion],
        registryEntries: [ProjectEntry],
        openProjectRoots: [[URL]]
    ) {
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        snapshot = nil
        refreshTask = Task { [weak self] in
            let loaded = await PluginRemovalPolicy.loadSnapshot(
                installedVersions: installedVersions,
                registryEntries: registryEntries,
                openProjectRoots: openProjectRoots
            )
            guard let self,
                  !Task.isCancelled,
                  refreshGeneration == generation else { return }
            snapshot = loaded
        }
    }

    func cancel() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }
}

@MainActor
enum PluginRemovalAttempt: Equatable {
    case removed(restartRequired: Bool)
    case blocked(String)

    static func perform(
        installedVersion: InstalledPluginVersion,
        usage: PluginVersionUsageState?,
        uninstall: () -> String?
    ) -> Self {
        let presentation = PluginRemovalPresentation.resolve(installedVersion: installedVersion, usage: usage)
        guard presentation.canRemove else { return .blocked(presentation.removalMessage) }
        if let error = uninstall() { return .blocked(error) }
        return .removed(restartRequired: installedVersion.isResident)
    }
}
