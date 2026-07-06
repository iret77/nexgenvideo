import Foundation
import Testing
@testable import NexGenEngine

/// The native pack registry that the app-side wiring (run_sanity, get_ui_contract,
/// init_project) resolves the active pack through.
@Suite("PackCatalog")
struct PackCatalogTests {

    @Test("musicvideo is a listed first-party pack")
    func musicvideoListed() {
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
        let registry = PackCatalog.registry(activePack: "musicvideo")
        #expect(registry.sanityChecks["coverage"] != nil)   // core still present
        #expect(registry.sanityChecks["tempo"] != nil)      // pack check added
        #expect(registry.uiContracts["analysis"] != nil)    // pack UI contract added
        let dirs = PackCatalog.projectDirs(activePack: "musicvideo")
        #expect(dirs.contains("audio"))
        #expect(dirs.contains("analysis"))
    }
}
