# Engine Migration — `musicvideo` → `engine/` + `packs/`

Staged extraction of the **Generic Production Engine** out of the `musicvideo`
Python repo into this monorepo (`engine/` + `packs/`), leaving `musicvideo` as a
thin format-pack. Realizes [CONCEPT.md](CONCEPT.md) §2 (consistency is core),
§4/§4.1 (core↔plugin boundary), §9 (monorepo). Baseline: musicvideo v0.15.1.

This is a **multi-step migration**, not one PR. The map below is validated
against the current code (2026-06-28).

## Decisions

- **Package name:** `nexgen_engine` (dir `engine/`). Imports: `from nexgen_engine.core import …`.
- **Packs:** `packs/<name>/` (first: `packs/musicvideo/`).
- **Verification:** a fast Ubuntu **Engine CI** (`pytest engine/tests`) — separate from the slow macOS Swift build.
- **Approach:** additive vertical slices. Generic modules are **copied** into `engine/` and proven there before `musicvideo` is rewired to depend on the engine. Tier 1A touches **only** `engine/` — zero changes to the working musicvideo repo.
- **Open (decide at the MIXED tier):** whether the whole musicvideo repo ultimately relocates into `packs/musicvideo/` (and the standalone repo is archived) vs. stays separate and depends on a published engine; and the dual-import compat strategy during cutover.

## Target structure

```
engine/nexgen_engine/
  core/        paths, schema_versions, aspect, models, gates, project, layout, tempo_framework
  bible/       schema, sheet, scene3d/*        (asset graph + 3D-to-anchor pipeline)
  render/      dispatcher, costs, identity_anchor, prompt/*, images/*, references/*
  frames/      generate (framework), schema, audit, crop, pan
  sanity/      audit, blocking_validator, checks/<generic>
  shotlist/ storyboard/ brief/ treatment/   (schemas; music semantics via pack hooks)
  state/ show/ mcp_server/
packs/musicvideo/
  analysis/* patterns/* cover/* brainstorm/*  (audio DSP, mood/tempo/genre, art)
  sanity_checks/{tempo,pacing,pattern_drift}  (registered into the engine framework)
  tempo_policy, duration_policy               (mode→duration/cost bands)
  .claude/phases/{analysis,cover,…}
```

## Module verdict (current code)

| Module | → | Notes |
|---|---|---|
| `common/{paths,schema_versions,aspect,models}` | **engine** | Tier 1A — pure leaves, zero music coupling. **Landed.** |
| `treatment/schema` | **engine** | Tier 1A — generic narrative structure. **Landed.** |
| `common/{gates,project,layout}`, `gates/*`, `state/*`, `show/formatters`, `mcp_server/*` | engine | Tier 1B — small cross-coupling (gates→paths, state→project). |
| `brief/schema`, `shotlist/schema`, `storyboard/schema`, `bible/{schema,sheet}`, `bible/scene3d/*` | engine | Schemas generic; music enum values kept but interpreted by pack. |
| `frames/{generate,schema,audit,crop,pan}` | engine | Framework generic; builder/provider registration → pack. |
| `render/{dispatcher,costs,identity_anchor,prompt/*,images/*,references/*}` | engine | Heaviest coupling; `dispatcher` needs the Shot/duration interface first. |
| `sanity/{audit,blocking_validator,models}` + `checks/<generic>` | engine | Audit framework + ~23 generic checks. |
| `common/tempo` | engine (framework) | `classify()`/`asl_violation()` generic; `TEMPO_BANDS` come from the pack. |
| `analysis/*`, `patterns/*`, `cover/*`, `brainstorm/*` | **pack** | Audio DSP, mood/tempo/genre, album art, music brainstorming. |
| `sanity/checks/{tempo,pacing,pattern_drift}` | **pack** | Registered into the engine sanity framework. |
| `.claude/phases/{analysis,cover}`, `skills/doctor` | **pack** | Music-only workflows. |

## Riskiest seams (music assumptions leaking into generic code)

1. **`Shot.duration_s` ↔ `Mode` + `perceived_bpm`** — `shotlist/schema.py` `MODE_DURATION_RANGES`, `sanity/checks/tempo.py` (reads `song.perceived_bpm`), `render/costs.py` (mode-aware multipliers). → Engine `DurationPolicy` interface; the music pack registers BPM-aware bands. Tempo/pacing checks move to the pack.
2. **`StepFunction.REFRAIN_ANCHOR` / lyrics anchoring** — `storyboard/schema.py`, `brief/schema.py` `LyricsIntegration`. → Generalize to `STRUCTURAL_ANCHOR` + a generic `anchor_point_type/ref` on `Shot`; pack maps refrain/chorus aliases.
3. **`common/tempo.classify(mode)` ASL scaling** — phrase/section 2.5×/4.0× scaling is music-only. → `TempoClassifier` base in engine, `MusicTempoPolicy` override in the pack.

## Coupling facts

- `shotlist.schema.{Mode,Shot}` is the most-imported type (common/layout, common/tempo, render/dispatcher, render/costs, frames/generate, 9 sanity checks, show/formatters, analysis/schema). Decouple via the interfaces above before moving `render/dispatcher`.
- Entry points: `pyproject [project.scripts]` (`mv-*`), the MCP server (`mv-mcp` → `FastMCP("musicvideo")`), the `.claude-plugin` manifest. Generic CLIs/MCP move to the engine; music CLIs stay in the pack.

## Sequence

- **Tier 1A** (landed): pure-leaf generic modules → `engine/core` + `engine/treatment`, smoke-tested.
- **Tier 1B**: gates/project/layout, state, show, mcp_server (resolve the small dependency closures: gates→paths, state→project).
- **Tier 2 (MIXED)**: schemas (brief/shotlist/storyboard/bible) → engine; then the decoupling interfaces (seams 1–3); then render/frames/sanity framework with pack registration.
- **Cutover**: rewire `musicvideo` to import from `nexgen_engine` (dual-import compat), split tests (engine regression vs pack), create `packs/musicvideo/`, then resolve the standalone-repo question.
