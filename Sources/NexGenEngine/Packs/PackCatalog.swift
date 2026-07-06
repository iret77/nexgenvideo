import Foundation

/// The engine's registry of first-party format packs — the native successor to
/// the Python `discover_packs()` entry-point walk. Packs are constructed
/// explicitly (no dynamic on-disk discovery); a host lists them for its gallery
/// and resolves an active pack by name to fold its contributions into the
/// engine's core surfaces (sanity checks, project dirs, UI contract).
public enum PackCatalog {
    /// Every first-party pack, gallery order.
    public static let all: [Pack] = [MusicvideoPack()]

    /// The pack whose `name` matches, or nil (the generic workflow).
    public static func pack(named name: String?) -> Pack? {
        guard let name else { return nil }
        return all.first { $0.name == name }
    }

    /// An `EngineRegistry` with core sanity checks installed plus the active
    /// pack's contributions folded in (checks/dirs/uiContract/duration policy).
    /// With no active pack it carries the core checks alone — the generic path.
    /// Mirrors `mcp_server.py`'s core-checks + `discover_packs()` gather.
    public static func registry(activePack name: String?) -> EngineRegistry {
        let registry = EngineRegistry()
        registerCoreChecks(registry.checkRegistry)
        pack(named: name)?.register(registry)
        return registry
    }

    /// The active pack's extra project-layout subdirs (music: audio/lyrics/
    /// analysis), for `ProjectScaffold.initProject(extraDirs:)`. Empty when none.
    public static func projectDirs(activePack name: String?) -> [String] {
        guard let pack = pack(named: name) else { return [] }
        let registry = EngineRegistry()
        pack.register(registry)
        return registry.projectDirs
    }
}
