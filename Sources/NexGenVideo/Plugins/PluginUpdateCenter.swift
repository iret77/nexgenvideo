import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class PluginUpdateCenter {
    static let shared = PluginUpdateCenter()

    enum Attention: Equatable {
        case updateAvailable
        case restartRequired
    }

    enum Preparation {
        case ready(ProjectPackBinding)
        case restartRequired(ProjectPackBinding)
        case unavailable(String)
    }

    enum ActivationRequirement: Equatable {
        case ready
        case load
        case restart
    }

    enum RestartFailure: LocalizedError, Equatable {
        case noInstalledUpdate
        case targetMissing(ProjectPackBinding)

        var errorDescription: String? {
            switch self {
            case .noInstalledUpdate:
                return "No installed format-pack update is ready to restart."
            case .targetMissing(let binding):
                return "The installed update for \(binding.id) \(binding.version) is no longer available or usable."
            }
        }
    }

    private enum PendingUpdate: Equatable {
        case available(ProjectPackBinding)
        case restartRequired(ProjectPackBinding)

        var attention: Attention {
            switch self {
            case .available: return .updateAvailable
            case .restartRequired: return .restartRequired
            }
        }

        var target: ProjectPackBinding {
            switch self {
            case .available(let binding), .restartRequired(let binding): return binding
            }
        }
    }

    private var pendingByID: [String: PendingUpdate] = [:]
    private(set) var isChecking = false
    @ObservationIgnored private var checkWaiters: [CheckedContinuation<Void, Never>] = []

    var attention: Attention? {
        if pendingByID.keys.contains(where: { restartTarget(for: $0) != nil }) {
            return .restartRequired
        }
        if pendingByID.values.contains(where: { $0.attention == .updateAvailable }) {
            return .updateAvailable
        }
        return nil
    }

    func attention(for id: String?) -> Attention? {
        guard let id, let pending = pendingByID[id] else { return nil }
        if pending.attention == .restartRequired {
            return restartTarget(for: id) == nil ? nil : .restartRequired
        }
        return .updateAvailable
    }

    func restartTarget(for id: String) -> ProjectPackBinding? {
        guard case .restartRequired(let binding) = pendingByID[id] else {
            return nil
        }
        guard PluginLoader.installed.contains(where: {
            $0.id == binding.id
                && $0.version == binding.version
                && $0.projectSchema == binding.projectSchema
                && $0.isUpdatePendingRestart
        }) else { return nil }
        return binding
    }

    func attention(for binding: ProjectPackBinding?) -> Attention? {
        guard let binding,
              let attention = attention(for: binding.id),
              let pending = pendingByID[binding.id] else { return nil }
        return Self.projectAttention(
            global: attention,
            target: pending.target,
            current: binding
        )
    }

    nonisolated static func projectAttention(
        global: Attention,
        target: ProjectPackBinding?,
        current: ProjectPackBinding
    ) -> Attention? {
        global == .restartRequired && target == current
            ? nil
            : global
    }

    func checkAndStageUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        refreshInstalledAttention()
        defer {
            isChecking = false
            let waiters = checkWaiters
            checkWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        guard case .success(let catalog) = await PluginCatalogService.fetch() else {
            refreshInstalledAttention()
            return
        }

        let selected = PluginManager.selectCompatiblePerPack(
            catalog.plugins,
            appVersion: AppVersion.marketing
        )
        for live in PluginLoader.installed {
            guard let candidate = selected.first(where: { $0.id == live.id }),
                  PluginManager.newer(
                      candidate,
                      thanInstalled: PluginLoader.liveBinding(id: live.id)?.version
                          ?? live.version,
                      appVersion: AppVersion.marketing
                  ) != nil else { continue }
            guard let target = ProjectPackBinding(
                id: candidate.id,
                version: candidate.version,
                projectSchema: candidate.projectSchema
            ) else { continue }
            pendingByID[live.id] = .available(target)
            if let existing = PluginLoader.installedInfo(
                id: candidate.id,
                version: candidate.version
            ), existing.info.projectSchema == candidate.projectSchema,
               existing.info.migratesFrom == candidate.migratesFrom,
               PluginGate.evaluate(
                   info: existing.info,
                   appVersion: AppVersion.marketing
               ) == nil,
               PluginSignature.verify(
                   bundleURL: existing.url,
                   host: PluginSignature.hostSigningState()
               ) == nil {
                if PluginLoader.runtimeRejection(
                    id: candidate.id,
                    version: candidate.version
                ) != nil {
                    continue
                }
                guard let binding = ProjectPackBinding(
                    id: candidate.id,
                    version: candidate.version,
                    projectSchema: existing.info.projectSchema
                ) else { continue }
                if PluginLoader.isResident(live.id) {
                    apply(
                        record: PluginLoader.markUpdatePendingRestart(
                            existing.info,
                            bundleURL: existing.url
                        ),
                        id: live.id
                    )
                } else if let record = PluginLoader.activate(binding) {
                    apply(record: record, id: live.id)
                }
                continue
            }
            do {
                let record = try await PluginInstaller.install(candidate)
                apply(record: record, id: live.id)
                NotificationCenter.default.post(
                    name: .pluginInstallationChanged,
                    object: live.id
                )
            } catch {
                Log.plugins.warning(
                    "pack auto-update for \(live.id) failed: \(error.localizedDescription)"
                )
            }
        }
        refreshInstalledAttention()
    }

    func prepareNewProject(packID: String) async -> Preparation {
        if isChecking {
            await withCheckedContinuation { continuation in
                checkWaiters.append(continuation)
            }
        }
        guard case .success(let catalog) = await PluginCatalogService.fetch() else {
            guard let live = PluginLoader.liveBinding(id: packID) else {
                return .unavailable(
                    "The plugin library is unreachable and no live version of this pack is available."
                )
            }
            if let newest = PluginLoader.newestUsableInstalledInfo(id: packID),
               newest.info.version != live.version,
               let binding = ProjectPackBinding(
                   id: packID,
                   version: newest.info.version,
                   projectSchema: newest.info.projectSchema
               ) {
                apply(
                    record: PluginLoader.markUpdatePendingRestart(
                        newest.info,
                        bundleURL: newest.url
                    ),
                    id: packID
                )
                return .restartRequired(binding)
            }
            return .ready(live)
        }

        let candidates = PluginManager.selectCompatiblePerPack(
            catalog.plugins.filter { $0.id == packID },
            appVersion: AppVersion.marketing
        )
        guard let entry = candidates.first else {
            return .unavailable(
                "No compatible version of this format pack is available."
            )
        }
        if PluginPaths.installedBundle(id: packID, version: entry.version) == nil {
            do {
                _ = try await PluginInstaller.install(entry)
            } catch {
                return .unavailable(
                    (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                )
            }
        }
        guard let installed = PluginLoader.installedInfo(
            id: packID,
            version: entry.version
        ), installed.info.projectSchema == entry.projectSchema,
           installed.info.migratesFrom == entry.migratesFrom,
           let binding = ProjectPackBinding(
            id: packID,
            version: entry.version,
            projectSchema: installed.info.projectSchema
        ) else {
            return .unavailable("The installed format pack metadata is invalid.")
        }
        if let reason = PluginGate.evaluate(
            info: installed.info,
            appVersion: AppVersion.marketing
        ) {
            return .unavailable(reason.reason)
        }
        if let reason = PluginSignature.verify(
            bundleURL: installed.url,
            host: PluginSignature.hostSigningState()
        ) {
            return .unavailable(reason.reason)
        }
        if let reason = PluginLoader.runtimeRejection(
            id: packID,
            version: binding.version
        ) {
            return .unavailable(
                "The installed format pack failed to load: \(reason). Reinstall or update it."
            )
        }
        switch Self.activationRequirement(
            live: PluginLoader.liveBinding(id: packID),
            target: binding
        ) {
        case .ready:
            pendingByID.removeValue(forKey: packID)
            return .ready(binding)
        case .load:
            if let record = PluginLoader.activate(binding) {
                if let reason = record.incompatibility {
                    return .unavailable(reason.reason)
                }
            }
            if PluginLoader.liveBinding(id: packID) == binding {
                pendingByID.removeValue(forKey: packID)
                return .ready(binding)
            }
        case .restart:
            apply(
                record: PluginLoader.markUpdatePendingRestart(
                    installed.info,
                    bundleURL: installed.url
                ),
                id: packID
            )
            return .restartRequired(binding)
        }
        return .unavailable("The installed format pack could not be activated.")
    }

    nonisolated static func activationRequirement(
        live: ProjectPackBinding?,
        target: ProjectPackBinding
    ) -> ActivationRequirement {
        guard let live else { return .load }
        return live == target ? .ready : .restart
    }

    nonisolated static func attention(
        after state: InstalledPluginRecord.State
    ) -> Attention? {
        switch state {
        case .loaded:
            return nil
        case .updatePendingRestart:
            return .restartRequired
        case .incompatible:
            return .updateAvailable
        }
    }

    func refreshInstalledAttention() {
        let records = PluginLoader.installed.filter { $0.isUpdatePendingRestart }
        let installedIDs = Set(records.map(\.id))
        var refreshed = pendingByID.filter { entry in
            entry.value.attention != .restartRequired || installedIDs.contains(entry.key)
        }
        for record in records {
            guard let binding = ProjectPackBinding(
                id: record.id,
                version: record.version,
                projectSchema: record.projectSchema
            ) else { continue }
            refreshed[record.id] = .restartRequired(binding)
        }
        if refreshed != pendingByID { pendingByID = refreshed }
    }

    nonisolated static func validatedRestartTargets(
        _ candidates: [ProjectPackBinding],
        isInstalled: (ProjectPackBinding) -> Bool
    ) throws -> [ProjectPackBinding] {
        guard !candidates.isEmpty else { throw RestartFailure.noInstalledUpdate }
        let targets = candidates.sorted { $0.id < $1.id }
        for target in targets where !isInstalled(target) {
            throw RestartFailure.targetMissing(target)
        }
        return targets
    }

    func restartToApplyUpdates() {
        let candidates = pendingByID.values.compactMap { pending -> ProjectPackBinding? in
            guard pending.attention == .restartRequired else { return nil }
            return pending.target
        }
        let targets: [ProjectPackBinding]
        do {
            targets = try Self.validatedRestartTargets(candidates) { binding in
                PluginLoader.usableInstalledInfo(for: binding) != nil
            }
        } catch {
            refreshInstalledAttention()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "NexGenVideo couldn't restart"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        AppRelaunch.now {
            for binding in targets {
                PluginLoader.requestVersionForNextLaunch(
                    id: binding.id,
                    version: binding.version
                )
            }
        }
    }

    private func apply(record: InstalledPluginRecord, id: String) {
        switch Self.attention(after: record.state) {
        case nil:
            pendingByID.removeValue(forKey: id)
        case .restartRequired:
            guard let binding = ProjectPackBinding(
                id: record.id,
                version: record.version,
                projectSchema: record.projectSchema
            ) else {
                pendingByID.removeValue(forKey: id)
                return
            }
            pendingByID[id] = .restartRequired(binding)
        case .updateAvailable:
            guard let binding = ProjectPackBinding(
                id: record.id,
                version: record.version,
                projectSchema: record.projectSchema
            ) else {
                pendingByID.removeValue(forKey: id)
                return
            }
            pendingByID[id] = .available(binding)
        }
    }
}
