import Foundation
import Observation

/// One picker row — a pack merged from its installed record (if any) and its
/// catalog entry (if any), reduced to a single actionable status.
struct PluginRow: Identifiable {
    let id: String
    let displayName: String
    let tagline: String?
    /// Badge art, only for a loaded pack (from its own resource bundle).
    let badgeURL: URL?
    let status: Status

    enum Status {
        /// Not installed but offered by the catalog and compatible → Install.
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

    /// Install (or reinstall/update) a catalog entry, then refresh installed.
    func install(_ entry: PluginCatalog.Entry) async {
        guard !busyIDs.contains(entry.id) else { return }
        busyIDs.insert(entry.id)
        lastError = nil
        defer { busyIDs.remove(entry.id) }
        do {
            _ = try await PluginInstaller.install(entry, appVersion: appVersion)
            installed = PluginLoader.installed
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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

    /// The merged, sorted rows the picker renders.
    func rows(activePluginName: String?) -> [PluginRow] {
        let catalogByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [PluginRow] = []
        var seen = Set<String>()

        for record in installed {
            seen.insert(record.id)
            let entry = catalogByID[record.id]
            // Loaded packs carry their local badge; fall back to the catalog badge (https-only)
            // so a not-yet-loaded (incompatible) row still shows real art.
            let badge = InstalledPack.named(record.id)?.badgeURL ?? Self.catalogBadge(entry?.badge)
            if let reason = record.incompatibility {
                let reinstall = entry.flatMap { installableEntry($0) }
                rows.append(PluginRow(
                    id: record.id, displayName: record.displayName,
                    tagline: record.tagline.isEmpty ? nil : record.tagline, badgeURL: badge,
                    status: .incompatible(reason: reason.reason, reinstall: reinstall)))
            } else if record.isUpdatePendingRestart {
                rows.append(PluginRow(
                    id: record.id, displayName: record.displayName,
                    tagline: record.tagline.isEmpty ? nil : record.tagline, badgeURL: badge,
                    status: .updatePendingRestart))
            } else {
                let update = entry.flatMap { newer($0, thanInstalled: record.version) }
                rows.append(PluginRow(
                    id: record.id, displayName: record.displayName,
                    tagline: record.tagline.isEmpty ? nil : record.tagline, badgeURL: badge,
                    status: .installed(active: record.id == activePluginName, update: update)))
            }
        }

        for entry in catalog where !seen.contains(entry.id) {
            if let blocked = PluginGate.versionCheck(minAppVersion: entry.minAppVersion, appVersion: appVersion) {
                rows.append(PluginRow(
                    id: entry.id, displayName: entry.displayName,
                    tagline: entry.tagline.isEmpty ? nil : entry.tagline, badgeURL: Self.catalogBadge(entry.badge),
                    status: .unavailable(reason: blocked.reason)))
            } else {
                rows.append(PluginRow(
                    id: entry.id, displayName: entry.displayName,
                    tagline: entry.tagline.isEmpty ? nil : entry.tagline, badgeURL: Self.catalogBadge(entry.badge),
                    status: .available(entry)))
            }
        }

        return rows.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The catalog entry, but only when it's installable on this app version.
    private func installableEntry(_ entry: PluginCatalog.Entry) -> PluginCatalog.Entry? {
        PluginGate.versionCheck(minAppVersion: entry.minAppVersion, appVersion: appVersion) == nil ? entry : nil
    }

    /// The catalog entry when it's a newer, installable version than `installed`.
    private func newer(_ entry: PluginCatalog.Entry, thanInstalled installed: String) -> PluginCatalog.Entry? {
        guard let candidate = installableEntry(entry),
              let new = SemanticVersion(candidate.version),
              let cur = SemanticVersion(installed), new > cur else { return nil }
        return candidate
    }
}
