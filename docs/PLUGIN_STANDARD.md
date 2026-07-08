# Format Pack Standard

How a format pack plugs into NexGenVideo. Companion to [CONCEPT.md](CONCEPT.md) §4.1.

Status: **loadable `.ngvpack` bundles**. A pack is a signed macOS bundle carrying a
compiled Swift dynamic library plus its resources, shipped OUTSIDE the app and
fetched on demand. It is no longer compiled into the app binary (the earlier
compiled-in `PackCatalog.all` list is now empty — every pack comes from the
plugin library). The still-earlier Python plugin contract (`ngv-plugin.json` +
`pyproject.toml` + `--plugin-dir`) was removed in M9.

## Layering

- **Core** — NexGenVideo (Swift: editor, timeline, generation via the fal/Marble
  catalogs, MCP server, embedded `claude -p` runtime) **+ `NexGenEngine`**: Bible,
  consistency/reference, sanity framework, prompt compile, render manifest +
  cost-guard, frame-compliance. The quality motor. `NexGenEngine` is built as a
  **shared dynamic library** (`libNexGenEngine.dylib`, embedded in the app's
  `Contents/Frameworks`).
- **Pack** (thin, e.g. `musicvideo`) — only domain specifics: genre/mood/tempo
  patterns, music-specific checks, duration policy, the pack's phase docs. A Swift
  type conforming to `Pack`, built as its own dynamic library that **links the
  shared `NexGenEngine`** — so host and pack share one copy of the `Pack`/
  `PackEntry` protocol metadata and casts across the bundle boundary are sound.

A pack **registers behavior into the engine**. It does **not** re-implement the
Bible/consistency/sanity/render core, and it does **not** call generators itself —
generation and timeline edits go through NexGen's own `nexgen` MCP tools, driven by Claude.

A pack **MUST support all three shot source modes** — `generated`, `imported`, and
`aiEnhanced` (`SourceMode`) — and never assume every shot is AI-generated: its phase
docs must direct the assistant to emit directorial shooting specs for imported (live)
shots and route enhanced shots through the video-to-video edit path.

## The `.ngvpack` bundle format

A pack ships as a macOS bundle named `<id>.ngvpack`:

```
musicvideo.ngvpack/
  Contents/
    Info.plist                                  ← gate metadata (below)
    MacOS/
      musicvideo                                ← the plugin dynamic library (dylib)
    Resources/
      NexGenVideo_MusicvideoPlugin.bundle       ← SwiftPM resource bundle
        MusicvideoPack/{library/*.yaml, phases/*.md, badge.png}
```

`Info.plist` keys the load gate reads BEFORE any code is loaded:

| Key | Meaning |
|---|---|
| `NGVPackID` | activation id (also the filename stem, persisted per project in `ngv.json`) |
| `NGVPackDisplayName` | gallery title |
| `NGVPackTagline` | gallery subtitle (back-compat; the card prefers headline + benefit) |
| `NGVPackHeadline` | bold one-line card pitch (optional; card falls back to tagline) |
| `NGVPackBenefit` | short benefit line under the headline (optional) |
| `CFBundleShortVersionString` | the pack's own version |
| `NGVMinAppVersion` | minimum NexGenVideo marketing version required |
| `NSPrincipalClass` | the `PackEntry` subclass' ObjC runtime name (entry point) |
| `CFBundleExecutable` | the dylib filename in `Contents/MacOS/` |

The bundle is assembled and signed by `scripts/assemble_ngvpack.sh` from
`plugins/<id>.json` (the pack's shipping metadata) and the SwiftPM build products
(`lib<Target>.dylib` + `NexGenVideo_<Target>.bundle`).

## Entry point — boxed factory via `NSPrincipalClass`

No Swift-existential-over-ObjC bridging. `NexGenEngine` defines:

```swift
@objc(NGVPackEntry) open class PackEntry: NSObject {
    public required override init() { super.init() }
    open func makePack() -> PackBox   // subclasses override
}
public final class PackBox: NSObject { public let pack: any Pack }
```

The pack ships an `@objc` subclass and names it in `NSPrincipalClass`:

```swift
@objc(MusicvideoPackEntry)
public final class MusicvideoPackEntry: PackEntry {
    public override func makePack() -> PackBox { PackBox(MusicvideoPack()) }
}
```

The host, after the gate passes: `Bundle(url:).load()` → `bundle.principalClass as?
PackEntry.Type` → `.init().makePack().pack` → `PackCatalog.register(pack)`. Because
host and pack link the SAME `libNexGenEngine.dylib` (dyld dedups it by the shared
install name `@rpath/libNexGenEngine.dylib`), `PackEntry`'s metadata is identical on
both sides and the cross-bundle cast is sound. `NSPrincipalClass` is per-bundle, so
multiple packs never collide on a global symbol (as a `@_cdecl`/`dlsym` factory would).

## Load gate (hard order)

`PluginLoader` enforces, in order, refusing to load past any failure:

1. **Read `Info.plist`** — missing/unreadable → damaged.
2. **Metadata well-formed** — `NGVPackID` valid, `CFBundleShortVersionString` and
   `NGVMinAppVersion` parse as semver, `NSPrincipalClass` present.
3. **Version** — `NGVMinAppVersion ≤` the app's `CFBundleShortVersionString`.
   Version fields are parsed **strictly**: exactly `MAJOR.MINOR.PATCH`, each an ASCII
   digit run — trailing garbage (`1.2.3xyz`), wrong arity (`1.2`), and pre-release /
   build metadata (`1.2.3-rc1`, `1.2.3+build`) are all rejected. A malformed
   `NGVMinAppVersion` reads as **incompatible**, never silently as compatible. Only a
   dev/CI *host* with no marketing version at all is treated as always-compatible
   (logged) — that leniency never extends to a malformed pack version.
4. **Code signature — trust-chain, not self-DR.** The pack is validated against a real
   `SecRequirement`, not merely `SecStaticCodeCheckValidity(code, [], nil)` (a
   self-signed bundle satisfies its OWN designated requirement, so a bare validity
   check plus a Team-ID string compare is **not** a trust check). The host's own signing
   state is read once and modelled explicitly:
   - **Developer ID host** → the pack must satisfy the **same-developer requirement**
     `anchor apple generic and certificate leaf[subject.OU] = "<hostTeamID>"`, passed
     to `SecStaticCodeCheckValidity`. This requires the pack to chain to an Apple root
     **and** carry the host's leaf Team ID — a self-signed pack fails `anchor apple
     generic`.
   - **Ad-hoc / unsigned host** (dev, CI) → a bundle whose own seal validates is
     accepted (ad-hoc counts), logged. Ad-hoc packs are permitted **only** here.
   - **Indeterminate** (any Security.framework error reading the host's state) → the
     pack is **rejected (fail closed)**. A transient failure in a signed production
     build can never fall through to the ad-hoc path. Every branch is logged.
5. **Load** — `Bundle.load()`, resolve the principal class, instantiate, register.

Incompatible / unsigned packs become a picker row with a calm reason (e.g.
"Requires NexGenVideo 0.5.0 or newer") — never a crash, never a silent skip.

## Catalog, install, activation

- **Catalog** — `plugins.json`, an asset on the rolling `dev-latest` release, lists
  packs `{id, displayName, tagline, headline?, benefit?, version, minAppVersion, url,
  sha256, badge?}`. The picker (`PluginPickerView`) fetches it; a fetch failure is a
  calm offline state (installed packs keep working). One primary action, `Activate`:
  for a catalog pack it downloads (a hidden step) then binds; there is no separate
  "Install" action.
- **Install (staged + atomic)** — the pack `url` (and the catalog URL) **must be
  https**; a non-https or malformed URL is refused with an actionable error and no
  download. The download is checksum-verified (`sha256`), unpacked into a temp dir, and
  run through **every non-executing gate there** (metadata, `NGVMinAppVersion`, code
  signature). Only once all pass is the validated bundle **atomically swapped** into
  `~/Library/Application Support/NexGenVideo/Plugins/<id>.ngvpack`; the prior install is
  kept until then, so a bad bundle can never overwrite a working one. Any failure leaves
  the previous install intact.
- **Update needs a restart.** A dylib already loaded this session can't be safely
  unloaded — its bundle path + principal class keep resolving to the resident (old)
  code. So updating an already-loaded pack installs the new bundle to disk but does
  **not** claim it's live: the record is marked *update-pending-restart* and the picker
  shows "Update installed — restart NexGenVideo to use it" rather than a false "active
  new version". First-time installs of a not-yet-loaded id load live immediately.
- **Startup** — `PluginLoader.loadInstalled()` (in `main.swift`, before the UI) loads
  every installed pack from disk.
- **Activation** — exactly one active pack per project (or none = the generic
  workflow), persisted as `activePlugin` in `<project>/ngv.json`. The active pack's
  `name` threads into the engine paths that consume it: `run_sanity` adds its checks,
  `get_ui_contract` overlays its entries, `init_project` creates its extra dirs, and
  the agent context line names it. A project whose active pack isn't installed shows
  an install hint instead of pretending.

## The `Pack` protocol

A pack is a Swift value conforming to `Pack` (`Sources/NexGenEngine/Packs/EngineRegistry.swift`):

```swift
public protocol Pack: Sendable {
    var name: String { get }           // activation id, persisted per project in ngv.json
    var version: String { get }
    var manifest: PackManifest { get }  // gallery/chip identity + minAppVersion + badge
    var starters: [PackStarter] { get } // agent-panel one-tap starters (plain-language prompts)
    func register(_ registry: EngineRegistry)
}
```

`register(_:)` folds the pack's contributions into the engine via `EngineRegistry`:

- `registerSanityCheck(_ name:_ check:)` — domain checks (e.g. music tempo/pacing). Last-write-wins by name.
- `registerDurationPolicy(_:)` — mode → duration band (music makes it BPM-aware); the engine's Shot/sanity logic stays format-neutral.
- `registerProjectDirs(_:)` — extra project-layout subdirs (music: `audio`, `lyrics`, `analysis`).
- `registerUIContract(phase:surface:taskClass:)` — override a phase's default interaction surface / router task class.
- `registerPhase(_ name:runner:)` — workflow phase runners the pack contributes.
- `registerLibrary(_ name:_ library:)` — domain reference data.

## Knowledge resources

A pack's knowledge (pattern libraries, phase docs, badge) ships as `MusicvideoPlugin`
target resources under `Sources/MusicvideoPlugin/Resources/<Pack>Pack/`, assembled into
the `.ngvpack`. `PackKnowledge` resolves them either from the SwiftPM-generated resource
bundle (dev/test/CI) or from the installed `.ngvpack` this dylib was loaded out of —
never from an absolute disk path.

## MCP surface

One always-available MCP server, registered with the embedded claude (see
`ClaudeCodeLaunch.mcpConfigJSON`):

- **`nexgen`** (Swift, `127.0.0.1`) — the whole surface: generation + timeline
  (`import_media`, `add_clips`, `generate_video`/`generate_image`/…, `get_timeline`,
  `export_project`) **and** the production-pipeline tools backed by `NexGenEngine`
  (`get_project_state`, `list_phases`, `run_sanity`, `get_ui_contract`, `init_project`,
  gates, ledger, render manifest, …). Pack-registered checks/contract entries surface
  through these; the tool surface stays standard so packs are swappable.

External Claude-Code plugins can still contribute their own MCP servers via a
`--plugin-dir`'s `.mcp.json` (the dev "extra plugin folder"); format packs are native
`.ngvpack`s and need none.
