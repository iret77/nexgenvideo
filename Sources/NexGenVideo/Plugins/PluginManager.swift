import Foundation
import Observation

extension Notification.Name {
    static let pluginInstallationChanged = Notification.Name("pluginInstallationChanged")
}

enum PluginSettingsAttention: Equatable {
    case updateAvailable
    case restartRequired

    static func resolve(_ rows: [PluginRow]) -> Self? {
        if rows.contains(where: {
            if case .updatePendingRestart = $0.status { return true }
            return false
        }) {
            return .restartRequired
        }
        if rows.contains(where: {
            switch $0.status {
            case .installed(_, let update): return update != nil
            case .incompatible(_, let reinstall): return reinstall != nil
            case .available, .updatePendingRestart, .unavailable: return false
            }
        }) {
            return .updateAvailable
        }
        return nil
    }
}

/// One picker row — a pack merged from its installed record (if any) and its
/// catalog entry (if any), reduced to a single actionable status.
struct PluginRow: Identifiable {
    let id: String
    let displayName: String
    let tagline: String?
    /// A bold one-line pitch for the card (nil → fall back to `tagline`).
    let headline: String?
    /// A short benefit line under the headline (nil → omitted).
    let benefit: String?
    /// Badge art, only for a loaded pack (from its own resource bundle).
    let badgeURL: URL?
    let status: Status

    /// What the card shows as its bold pitch: the headline, or the tagline when no
    /// headline exists (back-compat with a pack that predates the field).
    var pitch: String? {
        if let headline, !headline.isEmpty { return headline }
        return tagline
    }

    /// The short benefit line, only when a real headline drives the pitch (a
    /// tagline-only pack has no separate benefit line).
    var benefitLine: String? {
        guard let headline, !headline.isEmpty else { return nil }
        guard let benefit, !benefit.isEmpty else { return nil }
        return benefit
    }

    enum Status {
        /// Not installed but offered by the catalog and compatible. The single
        /// primary action `Activate` installs it (a hidden progress step) then binds.
        case available(PluginCatalog.Entry)
        /// Installed and loaded → Activate/Active; `update` set when the catalog
        /// offers a newer, installable version.
        case installed(active: Bool, update: PluginCatalog.Entry?)
        /// A newer build was installed to disk, but the previously-loaded code is
        /// still live this session → the pack needs a relaunch to take effect.
        case updatePendingRestart
        /// Installed but blocked by the gate → show `reason`; `reinstall` set when
        /// the catalog offers a build that would clear the gate.
        case incompatible(reason: String, reinstall: PluginCatalog.Entry?)
        /// In the catalog but this app is too old to run it → show `reason`.
        case unavailable(reason: String)
    }
}

struct InstalledPluginVersion: Identifiable, Equatable, Sendable {
    let packID: String
    let version: String
    let displayName: String
    let projectSchema: String
    let bundleURL: URL
    let isLegacy: Bool
    let isPresentOnDisk: Bool
    let isResident: Bool

    var id: String { "\(packID)@\(version)" }
}

/// Backs `PluginPickerView`: reloads installed packs, fetches the catalog, and
/// merges them into rows. A catalog fetch failure is a calm offline state —
/// installed packs still show and stay usable.
@MainActor
@Observable
final class PluginManager {
    private(set) var installed: [InstalledPluginRecord] = PluginLoader.installed
    private(set) var catalog: [PluginCatalog.Entry] = []
    private(set) var catalogState: CatalogState = .idle
    private(set) var busyIDs: Set<String> = []
    private(set) var lastError: String?

    enum CatalogState: Equatable { case idle, loading, loaded, offline }

    private let appVersion = AppVersion.marketing
    private(set) var installedVersions: [InstalledPluginVersion] = []

    /// Reload installed packs and (re)fetch the catalog.
    func refresh() async {
        installed = PluginLoader.loadInstalled()
        installedVersions = Self.scanInstalledVersions()
        PluginUpdateCenter.shared.refreshInstalledAttention()
        if catalogState != .loaded { catalogState = .loading }
        switch await PluginCatalogService.fetch() {
        case .success(let catalog):
            self.catalog = catalog.plugins
            catalogState = .loaded
        case .failure:
            catalogState = .offline
        }
    }

    func reloadInstalled() {
        installed = PluginLoader.loadInstalled()
        installedVersions = Self.scanInstalledVersions()
        PluginUpdateCenter.shared.refreshInstalledAttention()
    }

    func versions(for id: String) -> [InstalledPluginVersion] {
        installedVersions
            .filter { $0.packID == id }
            .sorted {
                (SemanticVersion($0.version) ?? SemanticVersion("0.0.0")!)
                    > (SemanticVersion($1.version) ?? SemanticVersion("0.0.0")!)
            }
    }

    @discardableResult
    func uninstall(_ installedVersion: InstalledPluginVersion) -> Bool {
        guard installedVersion.isPresentOnDisk else { return true }
        lastError = nil
        do {
            try PluginInstaller.uninstall(
                id: installedVersion.packID,
                version: installedVersion.version,
                bundleURL: installedVersion.bundleURL
            )
            PluginLoader.recordRemoval(
                id: installedVersion.packID,
                version: installedVersion.version
            )
            installed = PluginLoader.installed
            installedVersions = Self.scanInstalledVersions()
            PluginUpdateCenter.shared.refreshInstalledAttention()
            NotificationCenter.default.post(
                name: .pluginInstallationChanged,
                object: installedVersion.packID
            )
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return false
        }
    }

    func isBusy(_ id: String) -> Bool { busyIDs.contains(id) }

    /// Install (or reinstall/update) a catalog entry, then refresh installed. Returns
    /// whether the install succeeded so the caller can chain activation (the picker's
    /// `Activate` on an uninstalled pack installs-then-binds — download is a hidden step).
    @discardableResult
    func install(_ entry: PluginCatalog.Entry) async -> Bool {
        guard !busyIDs.contains(entry.id) else { return false }
        busyIDs.insert(entry.id)
        lastError = nil
        defer { busyIDs.remove(entry.id) }
        do {
            _ = try await PluginInstaller.install(entry, appVersion: appVersion)
            installed = PluginLoader.installed
            installedVersions = Self.scanInstalledVersions()
            PluginUpdateCenter.shared.refreshInstalledAttention()
            NotificationCenter.default.post(name: .pluginInstallationChanged, object: entry.id)
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// A catalog-supplied badge is REMOTE data — only honor it over https, never a `file://`
    /// (which would turn a compromised catalog into a local file read in the picker). An
    /// installed pack's OWN badge art is a separate, trusted local file and is not routed here.
    /// Pure + testable.
    nonisolated static func catalogBadge(_ url: URL?) -> URL? {
        guard let url, PluginInstaller.isHTTPS(url) else { return nil }
        return url
    }

    /// The merged, sorted rows the picker renders. Badge resolution (which touches
    /// the loaded-pack catalog) stays here; the status/copy mapping is the pure,
    /// testable `Self.buildRows`.
    func rows(activePluginName: String?) -> [PluginRow] {
        Self.buildRows(
            installed: installed, catalog: catalog,
            activePluginName: activePluginName, appVersion: appVersion,
            // Loaded packs carry their local badge; fall back to the catalog badge (https-only)
            // so a not-yet-loaded (incompatible) row still shows real art.
            localBadge: { InstalledPack.named($0)?.badgeURL })
    }

    /// Pure merge of installed records + catalog entries into sorted rows — the
    /// state-machine core, with badge lookup injected so it needs no MainActor state.
    nonisolated static func buildRows(
        installed: [InstalledPluginRecord],
        catalog: [PluginCatalog.Entry],
        activePluginName: String?,
        appVersion: String?,
        localBadge: (String) -> URL? = { _ in nil }
    ) -> [PluginRow] {
        // #168: a version-aware catalog lists MULTIPLE versions per pack. Collapse to the newest
        // COMPATIBLE version per pack id (highest `version` whose `minAppVersion ≤ appVersion`) so a
        // new app gets the newest pack and an old app the last pack that still supports it.
        let selected = selectCompatiblePerPack(catalog, appVersion: appVersion)
        let catalogByID = Dictionary(selected.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [PluginRow] = []
        var seen = Set<String>()

        for record in installed {
            seen.insert(record.id)
            let entry = catalogByID[record.id]
            let badge = localBadge(record.id) ?? catalogBadge(entry?.badge)
            rows.append(PluginRow(
                id: record.id, displayName: record.displayName,
                tagline: record.tagline.isEmpty ? nil : record.tagline,
                headline: record.headline.isEmpty ? nil : record.headline,
                benefit: record.benefit.isEmpty ? nil : record.benefit,
                badgeURL: badge,
                status: installedStatus(record: record, catalogEntry: entry,
                                        activePluginName: activePluginName, appVersion: appVersion)))
        }

        for entry in selected where !seen.contains(entry.id) {
            rows.append(PluginRow(
                id: entry.id, displayName: entry.displayName,
                tagline: entry.tagline.isEmpty ? nil : entry.tagline,
                headline: entry.headline.flatMap { $0.isEmpty ? nil : $0 },
                benefit: entry.benefit.flatMap { $0.isEmpty ? nil : $0 },
                badgeURL: catalogBadge(entry.badge),
                status: catalogStatus(entry: entry, appVersion: appVersion)))
        }

        return rows.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// State for an installed record: gate-blocked → incompatible, a newer resident
    /// build → restart-pending, else installed (active when it's this project's pack).
    nonisolated static func installedStatus(
        record: InstalledPluginRecord, catalogEntry: PluginCatalog.Entry?,
        activePluginName: String?, appVersion: String?
    ) -> PluginRow.Status {
        if let reason = record.incompatibility {
            return .incompatible(reason: reason.reason,
                                 reinstall: catalogEntry.flatMap { installableEntry($0, appVersion: appVersion) })
        }
        if record.isUpdatePendingRestart { return .updatePendingRestart }
        let update = catalogEntry.flatMap { newer($0, thanInstalled: record.version, appVersion: appVersion) }
        return .installed(active: record.id == activePluginName, update: update)
    }

    /// State for a catalog-only entry: blocked by the version gate → unavailable,
    /// else available (its primary action `Activate` installs-then-binds).
    nonisolated static func catalogStatus(entry: PluginCatalog.Entry, appVersion: String?) -> PluginRow.Status {
        if let blocked = PluginGate.versionCheck(minAppVersion: entry.minAppVersion, appVersion: appVersion) {
            return .unavailable(reason: blocked.reason)
        }
        return .available(entry)
    }

    /// The catalog entry, but only when it's installable on this app version.
    nonisolated static func installableEntry(_ entry: PluginCatalog.Entry, appVersion: String?) -> PluginCatalog.Entry? {
        PluginGate.versionCheck(minAppVersion: entry.minAppVersion, appVersion: appVersion) == nil ? entry : nil
    }

    /// #168: collapse a multi-version catalog to ONE entry per pack id — the highest `version` whose
    /// `minAppVersion ≤ appVersion`. When no version is compatible with this app, keep the highest
    /// version overall so the pack still appears (rendered `unavailable`), rather than vanishing.
    /// Older versions stay published in the catalog so an older app finds its last compatible pack.
    /// Pure + testable.
    nonisolated static func selectCompatiblePerPack(
        _ catalog: [PluginCatalog.Entry], appVersion: String?
    ) -> [PluginCatalog.Entry] {
        func version(_ e: PluginCatalog.Entry) -> SemanticVersion { SemanticVersion(e.version) ?? SemanticVersion("0.0.0")! }
        func newest(_ entries: [PluginCatalog.Entry]) -> PluginCatalog.Entry? {
            entries.max { version($0) < version($1) }
        }
        return Dictionary(grouping: catalog, by: \.id).compactMap { _, entries in
            let compatible = entries.filter {
                PluginGate.versionCheck(minAppVersion: $0.minAppVersion, appVersion: appVersion) == nil
            }
            return newest(compatible.isEmpty ? entries : compatible)
        }
    }

    /// The catalog entry when it's a newer, installable version than `installed`.
    nonisolated static func newer(_ entry: PluginCatalog.Entry, thanInstalled installed: String, appVersion: String?) -> PluginCatalog.Entry? {
        guard let candidate = installableEntry(entry, appVersion: appVersion),
              let new = SemanticVersion(candidate.version),
              let cur = SemanticVersion(installed), new > cur else { return nil }
        return candidate
    }

    private static func scanInstalledVersions() -> [InstalledPluginVersion] {
        let root = PluginPaths.installDirectory.standardizedFileURL
        var byID: [String: InstalledPluginVersion] = [:]
        for bundleURL in PluginPaths.installedBundles() {
            guard let info = PluginBundleInfo(bundleURL: bundleURL),
                  PluginPaths.isValidID(info.id),
                  PluginPaths.isValidVersion(info.version) else { continue }
            let legacy = bundleURL.deletingLastPathComponent().standardizedFileURL == root
            let item = InstalledPluginVersion(
                packID: info.id,
                version: info.version,
                displayName: info.displayName.isEmpty ? info.id : info.displayName,
                projectSchema: info.projectSchema,
                bundleURL: bundleURL,
                isLegacy: legacy,
                isPresentOnDisk: true,
                isResident: PluginLoader.residentVersion(id: info.id) == info.version
            )
            if byID[item.id] == nil || !legacy {
                byID[item.id] = item
            }
        }
        for record in PluginLoader.residentRecordsForInventory() {
            guard byID["\(record.id)@\(record.version)"] == nil else { continue }
            let item = InstalledPluginVersion(
                packID: record.id,
                version: record.version,
                displayName: record.displayName,
                projectSchema: record.projectSchema,
                bundleURL: record.bundleURL,
                isLegacy: false,
                isPresentOnDisk: false,
                isResident: true
            )
            byID[item.id] = item
        }
        return byID.values.sorted {
            if $0.displayName != $1.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
            return (SemanticVersion($0.version) ?? SemanticVersion("0.0.0")!)
                > (SemanticVersion($1.version) ?? SemanticVersion("0.0.0")!)
        }
    }
}
