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
/// version → code signature (same-developer trust chain, or ad-hoc only when the
/// host is itself ad-hoc; indeterminate host fails closed) → `Bundle.load()` →
/// instantiate the principal `PackEntry` → register the pack. An incompatible or
/// unsigned pack yields a record with a reason — never a crash, never a silent skip.
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

    /// Ids whose dylib was `Bundle.load()`-ed this process — recorded even when the principal-class
    /// cast then FAILED. A dylib can't be unloaded, so once it's resident an update can only go live
    /// after a relaunch. This is a superset of `loadedVersions` (which only records SUCCESSFUL
    /// registration): it's what tells "a previously-broken pack was just updated → needs restart"
    /// from "fresh install → loads live", so the broken case no longer re-shows "Damaged".
    private static var residentBundleIDs: Set<String> = []

    /// Whether this id's code is already mapped into the process (loaded, even if it failed to
    /// register). An update to a resident id needs a relaunch to take effect.
    static func isResident(_ id: String) -> Bool { residentBundleIDs.contains(id) }

    /// Decision for an id that is already resident this process (pure + testable). `nil` = not
    /// resident, proceed to load. `.loaded` = same version still live. `.updatePendingRestart` =
    /// a different (newer) version is on disk; using it needs a relaunch.
    static func residentDecision(
        diskVersion: String, loadedVersion: String?
    ) -> InstalledPluginRecord.State? {
        guard let loadedVersion else { return nil }
        return loadedVersion == diskVersion ? .loaded : .updatePendingRestart
    }

    /// Scan the install directory and load every pack. Idempotent.
    @discardableResult
    static func loadInstalled(appVersion: String? = AppVersion.marketing) -> [InstalledPluginRecord] {
        let host = PluginSignature.hostSigningState()
        let records = PluginPaths.installedBundles().map {
            load(at: $0, appVersion: appVersion, host: host)
        }
        installed = records
        return records
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
        if let state = residentDecision(diskVersion: info.version, loadedVersion: loadedVersions[info.id]) {
            return record(info, bundleURL: bundleURL, state: state)
        }

        guard let bundle = Bundle(url: bundleURL), bundle.load() else {
            return record(info, bundleURL: bundleURL,
                          state: .incompatible(.malformedMetadata("the pack's code failed to load")))
        }
        // The dylib is now mapped in — resident for the process lifetime whether or not the cast
        // below succeeds. Record it so a later update to this id knows a relaunch is required.
        residentBundleIDs.insert(info.id)
        guard let entryClass = bundle.principalClass as? PackEntry.Type else {
            return record(info, bundleURL: bundleURL,
                          state: .incompatible(.malformedMetadata("entry point \(info.principalClass) not found")))
        }

        let pack = entryClass.init().makePack().pack
        if pack.name != info.id {
            Log.plugins.warning("pack id \"\(info.id)\" ≠ loaded pack name \"\(pack.name)\" — activating by \"\(pack.name)\"")
        }
        PackCatalog.register(pack)
        loadedVersions[info.id] = info.version
        Log.plugins.notice("loaded pack \(pack.name) v\(info.version) from \(bundleURL.lastPathComponent)")
        return record(info, bundleURL: bundleURL, state: .loaded)
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
            version: info.version, minAppVersion: info.minAppVersion,
            bundleURL: bundleURL, state: state)
    }

    private static func blocked(
        id: String, bundleURL: URL, reason: PluginIncompatibility
    ) -> InstalledPluginRecord {
        Log.plugins.warning("pack \(id) not loaded: \(reason.reason)")
        return InstalledPluginRecord(
            id: id, displayName: id, tagline: "", headline: "", benefit: "",
            version: "", minAppVersion: "", bundleURL: bundleURL, state: .incompatible(reason))
    }
}
