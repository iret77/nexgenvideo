import Foundation
import Observation

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

    /// Reload installed packs and (re)fetch the catalog.
    func refresh() async {
        installed = PluginLoader.loadInstalled()
        if catalogState != .loaded { catalogState = .loading }
        switch await PluginCatalogService.fetch() {
        case .success(let catalog):
            self.catalog = catalog.plugins
            catalogState = .loaded
        case .failure:
            catalogState = .offline
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
        let catalogByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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

        for entry in catalog where !seen.contains(entry.id) {
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

    /// The catalog entry when it's a newer, installable version than `installed`.
    nonisolated static func newer(_ entry: PluginCatalog.Entry, thanInstalled installed: String, appVersion: String?) -> PluginCatalog.Entry? {
        guard let candidate = installableEntry(entry, appVersion: appVersion),
              let new = SemanticVersion(candidate.version),
              let cur = SemanticVersion(installed), new > cur else { return nil }
        return candidate
    }
}
