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
| `NGVProjectSchema` | project-data contract written by this pack (`<id>/<semver>`) |
| `NGVMigratesFrom` | project schemas this build can migrate transactionally |
| `NGVMinAppVersion` | minimum NexGenVideo marketing version required |
| `NGVEngineContract` | integer — the host↔pack binary contract the pack was BUILT against |
| `NSPrincipalClass` | the `PackEntry` subclass' ObjC runtime name (entry point) |
| `CFBundleExecutable` | the dylib filename in `Contents/MacOS/` |

`NGVEngineContract` is stamped by `assemble_ngvpack.sh`, which reads
`EngineContract.current` out of the engine SOURCE the pack is built with (a missing or
unreadable constant fails the script — never a silent default). It must be baked into the
bundle, not read from the engine at runtime: the pack links the shared
`libNexGenEngine.dylib`, so at load time it would report the HOST's value and the check
would always pass.

**Bump `EngineContract.current` whenever anything crossing the binary boundary changes
shape** — a `Pack` protocol requirement, a type in its signatures, `PackEntry`. A pack
built against a contract below `minimumCompatible` has no safe ABI guarantee and is
refused. Appending a stored property to a public value type that crosses this boundary
is ABI-incompatible without library evolution and raises the floor. Only verified
additive changes may retain the previous floor.

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
4. **Engine contract** —
   `EngineContract.minimumCompatible ... EngineContract.current` must contain
   `NGVEngineContract`. Absent or not a plist integer reads as `0` (pre-contract) and is
   refused; there is no leniency on this axis, not even for a dev host. Compatibility is
   intentionally asymmetric: a newer host may accept an older pack only while its changes
   were additive and the explicit floor remains old; an older host still rejects a newer
   pack. Any incompatible host change raises both current and the floor. The gate reads
   from the plist alone, so a refused pack is never mapped in or dispatched into.
5. **Code signature — trust-chain, not self-DR.** The pack is validated against a real
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
6. **Load** — `Bundle.load()`, resolve the principal class, instantiate, register.

Incompatible / unsigned packs become a picker row with a calm reason (e.g.
"Requires NexGenVideo 0.5.0 or newer") — never a crash, never a silent skip.

## Catalog, install, activation

- **Catalog** — `catalog.json`, an asset on the dedicated **`plugins` channel release**, lists
  packs `{id, displayName, tagline, headline?, benefit?, version, projectSchema,
  migratesFrom, minAppVersion, url, sha256, badge?}`. The picker (`PluginPickerView`) fetches it; a fetch failure is a
  calm offline state (installed packs keep working). One primary action, `Activate`:
  for a catalog pack it downloads (a hidden step) then binds; there is no separate
  "Install" action.
- **The channel is append-only and release-independent** — a pack id may be listed in
  SEVERAL versions; the app installs the newest whose `minAppVersion ≤` its own version
  (`PluginManager.selectCompatiblePerPack`), so a breaking pack change never strands an
  older app. Assets are version-stamped (`<id>-<version>.ngvpack.zip`), the `plugins`
  release is never deleted, and both the push and the versioned-release path publish to
  it (`scripts/publish_plugin_catalog.py`). Do **not** point the app at `dev-latest`: it
  is delete+recreated per push and carries the app DMG only — serving the catalog from
  there is what let a released pack fix never reach users (the 0.7.7 "Damaged pack"
  incident, #168).
- **Install (staged + atomic, versions coexist)** — the pack `url` (and the catalog URL) **must be
  https**; a non-https or malformed URL is refused with an actionable error and no
  download. The download is checksum-verified (`sha256`), unpacked into a temp dir, and
  run through **every non-executing gate there** (metadata, `NGVMinAppVersion`, code
  signature). Only once all pass is the validated bundle **atomically swapped** into
  `~/Library/Application Support/NexGenVideo/Plugins/<id>/<version>.ngvpack`.
  Installed versions are immutable and coexist; a validated update never overwrites or
  removes the version pinned by an existing project. Legacy flat
  `Plugins/<id>.ngvpack` installs remain readable as their declared version.
- **Update needs a restart.** A dylib already loaded this session can't be safely
  unloaded — its bundle path + principal class keep resolving to the resident (old)
  code. So updating an already-loaded pack installs the new bundle to disk but does
  **not** claim it's live: the record is marked *update-pending-restart* and the picker
  shows "Update installed — restart NexGenVideo to use it" rather than a false "active
  new version". First-time installs of a not-yet-loaded id load live immediately.
- **Startup selection** — only one dylib version per pack id may be resident in a
  process. `PluginLoader` loads the explicitly requested version for the next launch;
  otherwise it loads the newest installed compatible version. A version that failed at
  runtime load is excluded until a verified reinstall replaces it, so a usable older
  version remains available instead of entering a restart loop. Loading a different
  version after one is resident is refused and requires a restart.
- **Activation** — exactly one active pack per project (or none = the generic
  workflow), persisted in `<project>/ngv.json` as `activePlugin`,
  `activePluginVersion`, and `activePluginProjectSchema`. The active pack's
  `name` threads into the engine paths that consume it: `run_sanity` adds its checks,
  `get_ui_contract` overlays its entries, `init_project` creates its extra dirs, and
  the agent context line names it.
- **Opening a project gates on its exact binding.** Before the document is loaded,
  `AppState` reads all three binding fields and checks that exact version/schema is
  installed and live (`ProjectPackGate`).
  If it isn't, the project **does not open**: an alert offers to install it (missing),
  update it (installed but gate-blocked), or relaunch (staged update). Declining leaves
  the project closed. Opening it degraded would come up on the generic phase set with the
  pack's analysis and gates off — and a save would normalize the project to that shape.
  A project arriving from another machine, or a fresh install, is the normal case here.
  A legacy id-only project opens with the currently live legacy version and pins that
  exact binding in its Recovery copy. If no legacy-schema version is available, opening
  requires explicit approval of a target that declares a migration from `<id>/legacy`.
  In both cases the package remains untouched until Save.
- **New-project freshness is a hard gate.** Catalog checking and update staging finish
  before a selected format project is created. If newer code is already on disk while
  an older dylib is resident, the Home window and title bar show restart-required state
  and creation is blocked until restart. The host never creates a project bound to the
  stale resident version merely because its update arrived after startup.
- **Project upgrades are explicit and transactional.** An installed pack version never
  changes an existing project's binding. The user chooses Upgrade; the host verifies
  both the target bundle's `NGVMigratesFrom` declaration and the loaded pack's matching
  `registerProjectSchemaMigration(from:to:)` implementation when the project schema
  changes. A version-only upgrade with the same schema needs no data migration. The host
  restarts into the target version and applies the upgrade to a staged Recovery-copy
  clone. The staged directory replaces the working copy only after migration, binding
  write, and host validation succeed. Failure discards the staging directory. The saved
  `.ngv` package is the rollback source and changes only on the next Save. The pending
  upgrade record remains until that Save, so a crash can reopen the migrated Recovery
  copy; closing without saving cancels the upgrade and restores the source-version pin.
  `musicvideo/legacy → musicvideo/1.0.0` is intentionally data-identical: legacy describes
  the same artifacts before binding metadata existed, so the host changes only `ngv.json`.

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
- `registerProductionProfile(_:)` — activate reusable core filmmaking guidance and checks through a
  generic metadata condition; packs must not copy the profile into their own phase prose.
- `registerProjectDirs(_:)` — extra project-layout subdirs (music: `audio`, `lyrics`, `analysis`).
- `registerUIContract(phase:surface:taskClass:)` — override a phase's default interaction surface / router task class.
- `registerPhase(_ name:runner:)` — workflow phase runners the pack contributes.
- `registerLibrary(_ name:_ library:)` — domain reference data.
- `registerProjectSchemaMigration(from:to:migrate:)` — exact, pack-owned project
  migration executed only through the host's transactional upgrade coordinator.

Production profiles and their planned cross-pack composition are specified in
[`PRODUCTION_PROFILES.md`](PRODUCTION_PROFILES.md). Provider/model capability claims never belong in
a profile because they expire independently of the pack and engine contracts.

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
