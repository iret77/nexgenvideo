import Foundation
import NexGenEngine

/// One installed `.ngvpack`'s state after the load gate ran — what the picker
/// shows and what the app registered. The app links only NexGenEngine's
/// `PackEntry`/`PackBox`; the pack's own module is never compiled in.
struct InstalledPluginRecord: Identifiable, Equatable {
    let id: String
    let displayName: String
    let tagline: String
    let headline: String
    let benefit: String
    let version: String
    let projectSchema: String
    let migratesFrom: [String]
    let minAppVersion: String
    let bundleURL: URL
    let state: State

    var isLoaded: Bool { state == .loaded }
    var incompatibility: PluginIncompatibility? {
        if case .incompatible(let reason) = state { return reason }
        return nil
    }
    /// A newer bundle is on disk but the previously-loaded dylib is still resident
    /// this session — the picker shows a restart hint, not a false "live" state.
    var isUpdatePendingRestart: Bool {
        if case .updatePendingRestart = state { return true }
        return false
    }

    enum State: Equatable {
        case loaded
        case incompatible(PluginIncompatibility)
        /// Installed to disk, gates passed, but an older build of this pack id is
        /// already loaded in-process (dylibs can't be safely unloaded). Live code is
        /// still the OLD one; using the new version needs a relaunch.
        case updatePendingRestart
    }
}

/// Loads installed format packs at startup, enforcing the hard gate order:
/// read Info.plist → id/version/entry well-formed → NGVMinAppVersion ≤ app
/// version → NGVEngineContract within the running engine's compatibility range → code signature
/// (same-developer trust chain, or ad-hoc only when the host is itself ad-hoc;
/// indeterminate host fails closed) → `Bundle.load()` → instantiate the principal
/// `PackEntry` → register the pack. Every gate reads the bundle's Info.plist ONLY —
/// a pack that fails one is never mapped in and never dispatched into. An
/// incompatible or unsigned pack yields a record with a reason — never a crash,
/// never a silent skip.
@MainActor
enum PluginLoader {
    /// The most recent scan, for the picker. Empty until `loadInstalled()` runs.
    private(set) static var installed: [InstalledPluginRecord] = []

    /// Pack id → the version that actually went LIVE (registered) this process. A dylib
    /// can't be unloaded, so once an id is resident this mapping is the source of truth for
    /// a rescan: it lets `load()` tell "same pack, still loaded" from "a newer bundle is on
    /// disk but the old code is still resident" WITHOUT re-instantiating the resident dylib.
    /// Process-lifetime (reset on relaunch, which is exactly when a pending update goes live).
    private static var loadedVersions: [String: String] = [:]

    /// Pack id → the version of the dylib actually mapped into this process — recorded even when the
    /// principal-class cast then FAILED. A dylib can't be unloaded, so once it's resident an update can
    /// only go live after a relaunch. Unlike `loadedVersions` (SUCCESSFUL registration only), this also
    /// covers broken loads: it's what tells "a previously-broken pack was just updated → needs restart"
    /// from "same broken version rescanned → still Damaged", so an update no longer re-shows "Damaged".
    private static var residentVersions: [String: String] = [:]
    private static let selectedVersionsKey = "NGVSelectedPackVersions"
    private static let runtimeRejectionsKey = "NGVRejectedPackVersions"
    private static var residentRecords: [String: InstalledPluginRecord] = [:]

    /// Whether this id's code is already mapped into the process (loaded, even if it failed to
    /// register). An update to a resident id needs a relaunch to take effect.
    static func isResident(_ id: String) -> Bool { residentVersions[id] != nil }

    static func residentVersion(id: String) -> String? { residentVersions[id] }

    static func residentRecordsForInventory() -> [InstalledPluginRecord] {
        Array(residentRecords.values)
    }

    static func liveBinding(id: String) -> ProjectPackBinding? {
        guard let version = loadedVersions[id],
              let record = residentRecords[id] else { return nil }
        return ProjectPackBinding(
            id: id,
            version: version,
            projectSchema: record.projectSchema
        )
    }

    static func recordRemoval(id: String, version: String) {
        clearRuntimeRejection(id: id, version: version)
        clearRequestedVersion(id: id, version: version)
        let refreshed = loadInstalled()
        if !refreshed.contains(where: { $0.id == id }),
           let resident = residentRecords[id] {
            installed = refreshed + [resident]
            installed.sort { $0.displayName < $1.displayName }
        }
    }

    static func installedInfo(
        id: String,
        version: String
    ) -> (info: PluginBundleInfo, url: URL)? {
        guard let url = PluginPaths.installedBundle(id: id, version: version),
              let info = PluginBundleInfo(bundleURL: url),
              info.id == id,
              info.version == version else { return nil }
        return (info, url)
    }

    static func usableInstalledInfo(
        for binding: ProjectPackBinding,
        appVersion: String? = AppVersion.marketing
    ) -> (info: PluginBundleInfo, url: URL)? {
        guard let installed = installedInfo(
            id: binding.id,
            version: binding.version
        ), installed.info.projectSchema == binding.projectSchema,
           runtimeRejection(
               id: binding.id,
               version: binding.version
           ) == nil,
           isUsable(
               installed,
               appVersion: appVersion,
               host: PluginSignature.hostSigningState()
           ) else { return nil }
        return installed
    }

    static func newestInstalledInfo(
        id: String
    ) -> (info: PluginBundleInfo, url: URL)? {
        installedBundleInfos()
            .filter { $0.info.id == id }
            .max {
                (SemanticVersion($0.info.version) ?? SemanticVersion("0.0.0")!)
                    < (SemanticVersion($1.info.version) ?? SemanticVersion("0.0.0")!)
            }
    }

    static func newestUsableInstalledInfo(
        id: String,
        appVersion: String? = AppVersion.marketing
    ) -> (info: PluginBundleInfo, url: URL)? {
        let host = PluginSignature.hostSigningState()
        return installedBundleInfos()
            .filter {
                $0.info.id == id
                    && runtimeRejection(
                        id: $0.info.id,
                        version: $0.info.version
                    ) == nil
                    && isUsable(
                        $0,
                        appVersion: appVersion,
                        host: host
                    )
            }
            .max {
                version($0.info.version) < version($1.info.version)
            }
    }

    static func requestVersionForNextLaunch(id: String, version: String) {
        guard PluginPaths.isValidID(id), PluginPaths.isValidVersion(version) else { return }
        var selected = UserDefaults.standard.dictionary(
            forKey: selectedVersionsKey
        ) as? [String: String] ?? [:]
        selected[id] = version
        UserDefaults.standard.set(selected, forKey: selectedVersionsKey)
    }

    static func clearRequestedVersion(id: String, version: String? = nil) {
        var selected = UserDefaults.standard.dictionary(
            forKey: selectedVersionsKey
        ) as? [String: String] ?? [:]
        if let version, selected[id] != version { return }
        selected.removeValue(forKey: id)
        UserDefaults.standard.set(selected, forKey: selectedVersionsKey)
    }

    static func runtimeRejection(id: String, version: String) -> String? {
        let rejected = UserDefaults.standard.dictionary(
            forKey: runtimeRejectionsKey
        ) as? [String: String] ?? [:]
        return rejected[runtimeRejectionKey(id: id, version: version)]
    }

    static func clearRuntimeRejection(id: String, version: String) {
        var rejected = UserDefaults.standard.dictionary(
            forKey: runtimeRejectionsKey
        ) as? [String: String] ?? [:]
        let suffix = "|\(id)@\(version)"
        rejected.keys
            .filter { $0.hasSuffix(suffix) }
            .forEach { rejected.removeValue(forKey: $0) }
        UserDefaults.standard.set(rejected, forKey: runtimeRejectionsKey)
    }

    /// Decision for an id that is already resident this process (pure + testable). `nil` = not
    /// resident (or same broken version — re-report the load failure honestly), proceed to load.
    /// `.loaded` = same version, registered, still live. `.updatePendingRestart` = a different (newer)
    /// version is on disk; using it needs a relaunch — regardless of whether the resident one registered.
    static func residentDecision(
        diskVersion: String, residentVersion: String?, didRegister: Bool
    ) -> InstalledPluginRecord.State? {
        guard let residentVersion else { return nil }
        if residentVersion != diskVersion { return .updatePendingRestart }
        return didRegister ? .loaded : nil
    }

    /// Scan the install directory and load every pack. Idempotent.
    @discardableResult
    static func loadInstalled(appVersion: String? = AppVersion.marketing) -> [InstalledPluginRecord] {
        let host = PluginSignature.hostSigningState()
        let infos = installedBundleInfos()
        let selected = UserDefaults.standard.dictionary(
            forKey: selectedVersionsKey
        ) as? [String: String] ?? [:]
        var records: [InstalledPluginRecord] = []
        for (id, candidates) in Dictionary(grouping: infos, by: \.info.id) {
            let preferred = selected[id]
            let ordered = candidates.sorted {
                version($0.info.version) > version($1.info.version)
            }
            let usable = ordered.filter {
                runtimeRejection(
                    id: $0.info.id,
                    version: $0.info.version
                ) == nil && isUsable(
                    $0,
                    appVersion: appVersion,
                    host: host
                )
            }
            var loadOrder = usable
            if let selectedVersion = startupVersion(
                available: usable.map { $0.info.version },
                requested: preferred
            ), let pinned = usable.first(where: {
                $0.info.version == selectedVersion
            }) {
                loadOrder.removeAll {
                    $0.info.version == selectedVersion
                }
                loadOrder.insert(pinned, at: 0)
            }
            if preferred != nil,
               !usable.contains(where: {
                   $0.info.version == preferred
               }) {
                clearRequestedVersion(id: id)
            }
            if loadOrder.isEmpty, let first = ordered.first {
                loadOrder = [first]
            }
            guard var record = loadOrder.first.map({
                load(at: $0.url, appVersion: appVersion, host: host)
            }) else { continue }
            if record.incompatibility != nil,
               record.version == preferred {
                clearRequestedVersion(id: id)
            }
            if record.incompatibility != nil, !isResident(id) {
                for fallback in loadOrder.dropFirst() {
                    record = load(
                        at: fallback.url,
                        appVersion: appVersion,
                        host: host
                    )
                    if record.incompatibility == nil || isResident(id) {
                        break
                    }
                }
            }
            if let residentVersion = residentVersions[id],
               let newest = usable.first,
               let resident = SemanticVersion(residentVersion),
               let newestVersion = SemanticVersion(newest.info.version),
               newestVersion > resident,
               runtimeRejection(
                   id: newest.info.id,
                   version: newest.info.version
               ) == nil,
               PluginGate.evaluate(
                   info: newest.info,
                   appVersion: appVersion
               ) == nil,
               PluginSignature.verify(
                   bundleURL: newest.url,
                   host: host
               ) == nil {
                record = self.record(
                    newest.info,
                    bundleURL: newest.url,
                    state: .updatePendingRestart
                )
            }
            records.append(record)
        }
        installed = records.sorted { $0.displayName < $1.displayName }
        return installed
    }

    nonisolated static func startupVersion(
        available: [String],
        requested: String?
    ) -> String? {
        let valid = available.compactMap { value in
            SemanticVersion(value).map { (value, $0) }
        }
        if let requested,
           valid.contains(where: { $0.0 == requested }) {
            return requested
        }
        return valid.max { $0.1 < $1.1 }?.0
    }

    @discardableResult
    static func activate(
        _ binding: ProjectPackBinding,
        appVersion: String? = AppVersion.marketing
    ) -> InstalledPluginRecord? {
        if let live = liveBinding(id: binding.id), live == binding {
            return installed.first { $0.id == binding.id && $0.version == binding.version }
        }
        guard residentVersions[binding.id] == nil,
              let installed = installedInfo(id: binding.id, version: binding.version),
              installed.info.projectSchema == binding.projectSchema else {
            return nil
        }
        let record = load(at: installed.url, appVersion: appVersion)
        self.installed = self.installed.filter { $0.id != binding.id } + [record]
        return record
    }

    /// Run the full gate for a single bundle and, on success, register its pack
    /// into `PackCatalog`. Returns the record either way. Also used by the
    /// installer to bring a freshly downloaded pack online without a relaunch.
    @discardableResult
    static func load(
        at bundleURL: URL,
        appVersion: String? = AppVersion.marketing,
        host: PluginSignature.HostSigningState = PluginSignature.hostSigningState()
    ) -> InstalledPluginRecord {
        let fallbackID = bundleURL.deletingPathExtension().lastPathComponent

        guard let info = PluginBundleInfo(bundleURL: bundleURL) else {
            return blocked(id: fallbackID, bundleURL: bundleURL,
                           reason: .malformedMetadata("its Info.plist is missing or unreadable"))
        }

        if let reason = PluginGate.evaluate(info: info, appVersion: appVersion) {
            if case .malformedMetadata = reason {} else if appVersion == nil {
                Log.plugins.notice("app has no marketing version (dev build) — skipping version gate for \(info.id)")
            }
            return record(info, bundleURL: bundleURL, state: .incompatible(reason))
        }

        if let reason = PluginSignature.verify(bundleURL: bundleURL, host: host) {
            return record(info, bundleURL: bundleURL, state: .incompatible(reason))
        }

        // Already resident this process? Never re-instantiate — `bundle.load()` on an
        // already-loaded path resolves the principal class to the OLD code, so reporting
        // `.loaded` from the NEW disk metadata would be a false-live update. Same version →
        // still loaded; a newer on-disk version → the update needs a relaunch.
        if let state = residentDecision(
            diskVersion: info.version,
            residentVersion: residentVersions[info.id],
            didRegister: loadedVersions[info.id] != nil
        ) {
            return record(info, bundleURL: bundleURL, state: state)
        }

        guard let bundle = Bundle(url: bundleURL), bundle.load() else {
            rejectRuntime(
                info,
                reason: "the pack's code failed to load"
            )
            return record(info, bundleURL: bundleURL,
                          state: .incompatible(.malformedMetadata("the pack's code failed to load")))
        }
        // The dylib is now mapped in — resident for the process lifetime whether or not the cast
        // below succeeds. Record its version so a later update to this id knows a relaunch is required.
        residentVersions[info.id] = info.version
        guard let entryClass = bundle.principalClass as? PackEntry.Type else {
            rejectRuntime(
                info,
                reason: "entry point \(info.principalClass) not found"
            )
            let rejected = record(
                info,
                bundleURL: bundleURL,
                state: .incompatible(.malformedMetadata("entry point \(info.principalClass) not found"))
            )
            residentRecords[info.id] = rejected
            return rejected
        }

        let pack = entryClass.init().makePack().pack
        guard pack.name == info.id else {
            let detail = "runtime id \(pack.name) doesn't match \(info.id)"
            rejectRuntime(info, reason: detail)
            let rejected = record(
                info,
                bundleURL: bundleURL,
                state: .incompatible(.malformedMetadata(detail))
            )
            residentRecords[info.id] = rejected
            return rejected
        }
        PackCatalog.register(pack)
        loadedVersions[info.id] = info.version
        clearRuntimeRejection(id: info.id, version: info.version)
        Log.plugins.notice("loaded pack \(pack.name) v\(info.version) from \(bundleURL.lastPathComponent)")
        let loaded = record(info, bundleURL: bundleURL, state: .loaded)
        residentRecords[info.id] = loaded
        return loaded
    }

    /// Record a freshly-installed-but-not-loadable-this-session update: the new
    /// bundle is on disk and passed every non-executing gate, but an older build of
    /// this id is already resident, so we must NOT re-instantiate (that would run the
    /// OLD code under the NEW version's metadata). The live pack in `PackCatalog`
    /// stays untouched; the picker inventory is refreshed to show the restart hint.
    @discardableResult
    static func markUpdatePendingRestart(_ info: PluginBundleInfo, bundleURL: URL) -> InstalledPluginRecord {
        let updated = record(info, bundleURL: bundleURL, state: .updatePendingRestart)
        installed = installed.filter { $0.id != info.id } + [updated]
        Log.plugins.notice("update for \(info.id) v\(info.version) installed to disk — restart required to activate")
        return updated
    }

    private static func record(
        _ info: PluginBundleInfo, bundleURL: URL, state: InstalledPluginRecord.State
    ) -> InstalledPluginRecord {
        if case .incompatible(let reason) = state {
            Log.plugins.warning("pack \(info.id) not loaded: \(reason.reason)")
        }
        return InstalledPluginRecord(
            id: info.id, displayName: info.displayName.isEmpty ? info.id : info.displayName,
            tagline: info.tagline, headline: info.headline, benefit: info.benefit,
            version: info.version, projectSchema: info.projectSchema,
            migratesFrom: info.migratesFrom, minAppVersion: info.minAppVersion,
            bundleURL: bundleURL, state: state)
    }

    private static func blocked(
        id: String, bundleURL: URL, reason: PluginIncompatibility
    ) -> InstalledPluginRecord {
        Log.plugins.warning("pack \(id) not loaded: \(reason.reason)")
        return InstalledPluginRecord(
            id: id, displayName: id, tagline: "", headline: "", benefit: "",
            version: "", projectSchema: "", migratesFrom: [], minAppVersion: "",
            bundleURL: bundleURL, state: .incompatible(reason))
    }

    private static func installedBundleInfos() -> [(info: PluginBundleInfo, url: URL)] {
        var unique: [String: (PluginBundleInfo, URL)] = [:]
        for url in PluginPaths.installedBundles() {
            guard let info = PluginBundleInfo(bundleURL: url),
                  PluginPaths.isValidID(info.id),
                  SemanticVersion(info.version) != nil else { continue }
            let key = "\(info.id)@\(info.version)"
            if unique[key] == nil || !isLegacyInstall(url) {
                unique[key] = (info, url)
            }
        }
        return unique.values.map { (info: $0.0, url: $0.1) }
    }

    private static func isUsable(
        _ candidate: (info: PluginBundleInfo, url: URL),
        appVersion: String?,
        host: PluginSignature.HostSigningState
    ) -> Bool {
        PluginGate.evaluate(
            info: candidate.info,
            appVersion: appVersion
        ) == nil && PluginSignature.verify(
            bundleURL: candidate.url,
            host: host
        ) == nil
    }

    private static func version(_ value: String) -> SemanticVersion {
        SemanticVersion(value) ?? SemanticVersion("0.0.0")!
    }

    private static func rejectRuntime(
        _ info: PluginBundleInfo,
        reason: String
    ) {
        var rejected = UserDefaults.standard.dictionary(
            forKey: runtimeRejectionsKey
        ) as? [String: String] ?? [:]
        rejected[runtimeRejectionKey(
            id: info.id,
            version: info.version
        )] = reason
        UserDefaults.standard.set(rejected, forKey: runtimeRejectionsKey)
    }

    private static func runtimeRejectionKey(
        id: String,
        version: String
    ) -> String {
        "\(AppVersion.marketing ?? "dev")#\(AppVersion.build ?? "dev")"
            + "#\(EngineContract.current)|\(id)@\(version)"
    }

    private static func isLegacyInstall(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL
            == PluginPaths.installDirectory.standardizedFileURL
    }
}
