import Foundation

/// Quietly keep installed format packs current, like Sparkle does for the app. Runs once at launch:
/// for every installed pack the catalog offers a NEWER compatible version of, it downloads + stages
/// the update. The pack's old dylib is already resident (loaded at startup) and can't be unloaded, so
/// the staged build goes live on the NEXT launch — no mid-session restart, no prompt. Best-effort:
/// any failure is logged and ignored, and the currently-installed pack keeps working. Offline → no-op.
@MainActor
enum PluginAutoUpdate {
    static func run() async {
        guard case .success(let catalog) = await PluginCatalogService.fetch() else { return }
        let byID = Dictionary(catalog.plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for record in PluginLoader.installed {
            guard record.incompatibility == nil, !record.isUpdatePendingRestart,
                  let entry = byID[record.id],
                  let newer = PluginManager.newer(entry, thanInstalled: record.version, appVersion: AppVersion.marketing)
            else { continue }
            do {
                _ = try await PluginInstaller.install(newer)
                Log.plugins.notice("auto-updated pack \(record.id) → v\(newer.version); active on next launch")
            } catch {
                Log.plugins.warning("pack auto-update for \(record.id) failed: \(error.localizedDescription)")
            }
        }
    }
}
