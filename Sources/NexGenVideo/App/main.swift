import AppKit

Log.bootstrap()

// CI-only pack load self-test. No-op unless NGV_SELFTEST_PACK is set; when set, loads that pack with
// the real binary + Frameworks and exits before any UI — reproduces + guards the load-time cast.
PackSelfTest.runIfRequested()

Telemetry.start()
BundledFonts.register()
ModelCatalog.shared.configure()
ModelCatalog.shared.load(entries: FalModelRegistry.entries + MarbleModelRegistry.entries + RunwayModelRegistry.entries)
// Then refresh from the hosted catalog (models + ranking cards without an app release); the
// registries above are the offline fallback and first-run seed.
Task { @MainActor in await RemoteCatalog.refresh() }

// Higgsfield/OpenArt and other MCP providers have no static registry — their models are discovered at
// runtime once the user signs in (#163). Layered onto the catalog; re-runs on every activation change.
MCPCatalogDiscovery.start()

// Load installed format packs before any UI reads the catalog. Packs ship as
// signed `.ngvpack` bundles outside the DMG; incompatible/unsigned ones surface
// in the picker with a reason instead of loading (never a crash).
PluginLoader.loadInstalled()

// Keep installed packs current in the background (like Sparkle for the app): newer versions stage to
// disk and go live on the next launch, so users rarely meet the "restart to update" path at all.
Task { @MainActor in await PluginAutoUpdate.run() }

// Shorten the default tooltip delay from 2s to 0.01s.
UserDefaults.standard.set(10, forKey: "NSInitialToolTipDelay")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenuBuilder.buildMenu()
app.run()
