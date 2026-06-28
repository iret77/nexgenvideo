# Plugin Standard (packs)

How a format pack plugs into NexGenVideo. Companion to [CONCEPT.md](CONCEPT.md)
§4.1 and [ENGINE_MIGRATION.md](ENGINE_MIGRATION.md). Status: **v0 contract**
(`engine/nexgen_engine/pack.py`); refined as the engine extraction lands.

## Layering

- **Core** — nexgen-video (Swift: editor, timeline, **generation** via the local fal
  catalog, MCP server, embedded `claude -p` runtime) **+ the Generic Engine** (Python,
  bundled with the app and always loaded): **Bible, consistency/reference, sanity
  framework, render-dispatch + cost-guard, frame-compliance**. The quality motor.
- **Pack** (thin, e.g. `musicvideo`) — only domain specifics: audio DSP/analysis,
  genre/mood/tempo patterns, lyrics/cover, music-specific checks, the workflow phases.

A pack **registers behavior into the engine**. It does **not** re-implement the
Bible/consistency/sanity/render core, and it does **not** call generators itself —
generation and timeline edits go through nexgen's own tools, **driven by Claude**.

## What a pack registers (`Pack.register(EngineRegistry)`)

- `register_phase(name, runner)` — workflow phases it contributes.
- `register_sanity_check(name, check)` — domain checks plugged into the engine's
  sanity framework (e.g. tempo / pacing / pattern-drift).
- `register_duration_policy(policy)` — seam 1: mode → duration band (music makes it
  BPM-aware); the engine's Shot/sanity logic stays generic.
- `register_library(name, data)` — domain reference data (e.g. pattern libraries).

## Standard MCP surface (the "function calls" Claude uses)

Two always-available MCP servers, registered with the embedded claude (the merge is
wired — see `ClaudeCodeLaunch.mcpConfigJSON`):

- **`nexgen`** (Swift, 127.0.0.1) — `import_media`, `add_clips`, `generate_video`/
  `generate_image`/…, `get_timeline`, `export_project`. Generation + timeline.
- **`engine`** (Python core, bundled) — the workflow control surface over the Bible/
  consistency/sanity/render core: `get_project_state`, `list_phases`, `run_phase`,
  `list_checks`, `run_sanity`, … Pack-registered phases/checks appear here; the tool
  surface stays standard so packs are swappable.

## Runtime (decided)

A core feature can't depend on a remote host, so the engine (and packs) run **locally,
bundled with nexgen-video, auto-bootstrapped** — the plugin manager sets up the Python
runtime invisibly (via `uv`); the user never touches Python/venv. fal's GPU compute is
remote in every case (it's a cloud API); only the API call leaves the machine, with the
key staying in the Keychain. Remote-hosted / bundled-binary models are out for the core.
