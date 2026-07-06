# Format Pack Standard

How a format pack plugs into NexGenVideo. Companion to [CONCEPT.md](CONCEPT.md) §4.1.
Status: **native Swift** (`Sources/NexGenEngine/Packs/`). The former Python plugin
contract (`ngv-plugin.json` + `pyproject.toml` + `--plugin-dir`) was removed in M9
(issue #119) — packs are now Swift modules, not on-disk plugins.

## Layering

- **Core** — NexGenVideo (Swift: editor, timeline, **generation** via the fal/Marble
  catalogs, MCP server, embedded `claude -p` runtime) **+ `NexGenEngine`** (Swift
  library, always linked): Bible, consistency/reference, sanity framework, prompt
  compile, render manifest + cost-guard, frame-compliance. The quality motor.
- **Pack** (thin, e.g. `musicvideo`) — only domain specifics: genre/mood/tempo
  patterns, music-specific checks, duration policy, the pack's phase docs. No Python,
  no venv, no separate process — a Swift type conforming to `Pack`.

A pack **registers behavior into the engine**. It does **not** re-implement the
Bible/consistency/sanity/render core, and it does **not** call generators itself —
generation and timeline edits go through NexGen's own `nexgen` MCP tools, driven by Claude.

## The `Pack` protocol

A pack is a Swift value conforming to `Pack` (`Sources/NexGenEngine/Packs/EngineRegistry.swift`):

```swift
public protocol Pack: Sendable {
    var name: String { get }           // activation id, persisted per project in ngv.json
    var version: String { get }
    var manifest: PackManifest { get }  // gallery/chip identity (displayName, tagline, header image)
    var starters: [PackStarter] { get } // agent-panel one-tap starters (plain-language prompts)
    func register(_ registry: EngineRegistry)
}
```

`register(_:)` folds the pack's contributions into the engine via `EngineRegistry`:

- `registerSanityCheck(_ name:_ check:)` — domain checks in the engine's sanity
  framework (e.g. music tempo / pacing). Last-write-wins by name.
- `registerDurationPolicy(_:)` — seam 1: mode → duration band (music makes it
  BPM-aware); the engine's Shot/sanity logic stays format-neutral.
- `registerProjectDirs(_:)` — extra project-layout subdirs (music: `audio`,
  `lyrics`, `analysis`), added on `init_project`.
- `registerUIContract(phase:surface:taskClass:)` — override a phase's default
  interaction surface / router task class.
- `registerPhase(_ name:runner:)` — workflow phase runners the pack contributes.
- `registerLibrary(_ name:_ library:)` — domain reference data.

## Registration + activation

- **Catalog** — `PackCatalog.all` (NexGenEngine) lists the first-party packs; there is
  no dynamic on-disk discovery. The app's gallery/chip/launcher read packs via
  `InstalledPack` / `PluginCommandCatalog`, which wrap `PackCatalog`.
- **Activation** — exactly one active pack per project (or none = the generic
  workflow), persisted as `activePlugin` in `<project>/ngv.json` (unchanged from the
  plugin era). The active pack's `name` is threaded into the engine paths that consume
  it: `run_sanity` adds its checks, `get_ui_contract` overlays its entries,
  `init_project` creates its extra dirs, and the agent context line names it.

## Knowledge resources

A pack's knowledge (pattern libraries, phase docs) ships as bundled `NexGenEngine`
resources under `Sources/NexGenEngine/Resources/<Pack>Pack/` and is read via
`Bundle.module` (see `PackKnowledge` for the musicvideo accessors). No files are read
from disk at runtime beyond the app bundle.

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
`--plugin-dir`'s `.mcp.json` (the dev "extra plugin folder"); first-party format packs
are native and need none.
