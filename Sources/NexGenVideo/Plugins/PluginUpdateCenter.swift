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

    private(set) var attentionByID: [String: Attention] = [:]
    private(set) var targetByID: [String: ProjectPackBinding] = [:]
    private(set) var isChecking = false
    @ObservationIgnored private var checkWaiters: [CheckedContinuation<Void, Never>] = []

    var attention: Attention? {
        if attentionByID.values.contains(.restartRequired) {
            return .restartRequired
        }
        if attentionByID.values.contains(.updateAvailable) {
            return .updateAvailable
        }
        return nil
    }

    func attention(for id: String?) -> Attention? {
        guard let id else { return nil }
        return attentionByID[id]
    }

    func attention(for binding: ProjectPackBinding?) -> Attention? {
        guard let binding,
              let attention = attentionByID[binding.id] else { return nil }
        return Self.projectAttention(
            global: attention,
            target: targetByID[binding.id],
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
            targetByID[live.id] = target
            attentionByID[live.id] = .updateAvailable
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
                    attentionByID[live.id] = .restartRequired
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
                attentionByID[packID] = .restartRequired
                targetByID[packID] = binding
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
        targetByID[packID] = binding
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
            attentionByID.removeValue(forKey: packID)
            targetByID.removeValue(forKey: packID)
            return .ready(binding)
        case .load:
            if let record = PluginLoader.activate(binding) {
                if let reason = record.incompatibility {
                    return .unavailable(reason.reason)
                }
            }
            if PluginLoader.liveBinding(id: packID) == binding {
                attentionByID.removeValue(forKey: packID)
                targetByID.removeValue(forKey: packID)
                return .ready(binding)
            }
        case .restart:
            break
        }
        attentionByID[packID] = .restartRequired
        return .restartRequired(binding)
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
        for record in PluginLoader.installed where record.isUpdatePendingRestart {
            guard let binding = ProjectPackBinding(
                id: record.id,
                version: record.version,
                projectSchema: record.projectSchema
            ) else { continue }
            targetByID[record.id] = binding
            attentionByID[record.id] = .restartRequired
        }
    }

    func restartToApplyUpdates() {
        var targets: [ProjectPackBinding] = []
        for (id, attention) in attentionByID where attention == .restartRequired {
            guard let binding = targetByID[id],
                  PluginLoader.installedInfo(
                      id: id,
                      version: binding.version
                  ) != nil else { continue }
            targets.append(binding)
        }
        guard !targets.isEmpty else { return }
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
            attentionByID.removeValue(forKey: id)
            targetByID.removeValue(forKey: id)
        case .restartRequired:
            targetByID[id] = ProjectPackBinding(
                id: record.id,
                version: record.version,
                projectSchema: record.projectSchema
            )
            attentionByID[id] = .restartRequired
        case .updateAvailable:
            attentionByID[id] = .updateAvailable
        }
    }
}
