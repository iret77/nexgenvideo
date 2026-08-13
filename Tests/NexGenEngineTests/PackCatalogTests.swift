import Foundation
import Testing
@testable import NexGenEngine
@testable import MusicvideoPlugin

/// The runtime pack registry that the app-side wiring (run_sanity, get_ui_contract,
/// init_project) resolves the active pack through. Packs are no longer compiled in,
/// so each test registers the loadable pack first — the same thing the host's
/// `PluginLoader` does at launch. Registration is idempotent by name.
@Suite("PackCatalog")
struct PackCatalogTests {

    @Test("a registered pack is listed and resolvable")
    func musicvideoListed() {
        PackCatalog.register(MusicvideoPack())
        #expect(PackCatalog.all.contains { $0.name == "musicvideo" })
        #expect(PackCatalog.pack(named: "musicvideo") != nil)
        #expect(PackCatalog.pack(named: nil) == nil)
        #expect(PackCatalog.pack(named: "nope") == nil)
    }

    @Test("no active pack yields core checks only")
    func noPackIsCoreOnly() {
        let checks = PackCatalog.registry(activePack: nil).sanityChecks
        #expect(checks["coverage"] != nil)          // a core check
        #expect(checks["tempo"] == nil)             // a pack check — absent
        #expect(PackCatalog.projectDirs(activePack: nil).isEmpty)
    }

    @Test("active musicvideo folds in its checks, contract, and project dirs")
    func musicvideoActiveFoldsIn() {
        PackCatalog.register(MusicvideoPack())
        let registry = PackCatalog.registry(activePack: "musicvideo")
        #expect(registry.sanityChecks["coverage"] != nil)   // core still present
        #expect(registry.sanityChecks["tempo"] != nil)      // pack check added
        #expect(registry.uiContracts["analysis"] != nil)    // pack UI contract added
        #expect(registry.declarativeCockpitSurface?.id == "analysis")
        #expect(registry.declarativeCockpitSurface?.phase == "analysis")
        #expect(registry.declarativeCockpitSurface?.dataFile == "analysis/{songStem}.json")
        #expect(registry.declarativeCockpitSurface?.layout.count == 3)
        #expect(registry.cockpitSurfaces.isEmpty)
        let dirs = PackCatalog.projectDirs(activePack: "musicvideo")
        #expect(dirs.contains("audio"))
        #expect(dirs.contains("analysis"))
    }

    @Test("registry structurally exposes at most one declarative cockpit surface")
    func singleDeclarativeCockpitSurface() {
        let registry = EngineRegistry()
        let first = DeclarativeCockpitSurface(
            id: "first",
            title: "First",
            symbol: "1.circle",
            phase: "brief",
            dataFile: "brief.json",
            layout: [.keyValue(title: nil, items: [])]
        )
        let second = DeclarativeCockpitSurface(
            id: "second",
            title: "Second",
            symbol: "2.circle",
            phase: "analysis",
            dataFile: "analysis/{songStem}.json",
            layout: [.keyValue(title: nil, items: [])]
        )
        registry.registerDeclarativeCockpitSurface(first)
        registry.registerDeclarativeCockpitSurface(second)
        #expect(registry.declarativeCockpitSurface == second)
    }
}
