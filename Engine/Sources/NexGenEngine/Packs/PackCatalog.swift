import Foundation

/// The runtime registry of loaded format packs.
///
/// Packs are no longer compiled into the app: each ships as a signed `.ngvpack`
/// bundle, is loaded from disk by the host at startup (see the app's
/// `PluginLoader`), and registers itself here via `register(_:)`. The compiled-in
/// list is therefore EMPTY — every pack comes from the plugin library. The read
/// surface (`all`, `pack(named:)`, `registry(activePack:)`, `projectDirs`) is
/// unchanged, so the app-side wiring (run_sanity, get_ui_contract, init_project)
/// keeps resolving the active pack the same way; it just sees whatever is loaded.
public enum PackCatalog {
    /// Thread-safe backing store — the app registers packs on the main thread at
    /// launch, but `registry(activePack:)` is read from background tasks too.
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var byName: [String: Pack] = [:]
        private var order: [String] = []

        func register(_ pack: Pack) {
            lock.lock(); defer { lock.unlock() }
            if byName[pack.name] == nil { order.append(pack.name) }
            byName[pack.name] = pack  // last-write-wins (a reload/update replaces in place)
        }

        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            byName.removeAll(); order.removeAll()
        }

        var all: [Pack] {
            lock.lock(); defer { lock.unlock() }
            return order.compactMap { byName[$0] }
        }

        func pack(named name: String) -> Pack? {
            lock.lock(); defer { lock.unlock() }
            return byName[name]
        }
    }

    private static let store = Store()

    /// Register a pack loaded from a `.ngvpack`. Idempotent by `name`
    /// (last-write-wins) so re-registering an updated build replaces it in place.
    public static func register(_ pack: Pack) { store.register(pack) }

    /// Drop every registered pack — for tests that need a clean slate.
    public static func removeAll() { store.removeAll() }

    /// Every loaded pack, registration order.
    public static var all: [Pack] { store.all }

    /// The loaded pack whose `name` matches, or nil (the generic workflow).
    public static func pack(named name: String?) -> Pack? {
        guard let name else { return nil }
        return store.pack(named: name)
    }

    /// An `EngineRegistry` with core sanity checks installed plus the active
    /// pack's contributions folded in (checks/dirs/uiContract/duration policy).
    /// With no active (or no loaded) pack it carries the core checks alone.
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
