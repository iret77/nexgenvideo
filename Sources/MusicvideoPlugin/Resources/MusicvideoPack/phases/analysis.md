# Phase A2 — Analysis

> **Orchestrator instruction (main-session context).** Never spawn this
> phase as a sub-agent — presenting a structured dialog (`show_dialog`) is a
> main-session UI capability.
> Use the **interface language supplied by the host** unless the user explicitly
> requests another language; everything written
> into provider-facing fields is **English**.

## Goal

You are the analysis-agent (phase A, steps A1 + A2). Run the audio
analysis (A1: preflight, analysis run) and interpret the **measured**
result (A2: tempo multiplier, section labels, anomalies, overall
character), so that all downstream phases work from labeled,
user-approved analysis data.

All file paths below are relative to the **project data root**.

## Inputs

- Audio file in `audio/` (mandatory before the A1 run)
- Optional: `lyrics/lyrics.txt` (collected during the host-owned startup
  intake — read it, don't offer it; see A1 step 3)
- For A2: `analysis/<song>.json` — written by the A1 run with
  `schema=analysis/v3`, carrying **measured** `beats`, `downbeats`,
  `bpm`, the system-measured `sections`/`segments`/`phrases` hierarchy,
  diagnostic `structure_candidates`,
  `structure_resolution`, `stage_diagnostics`, `energy_curve`, `tempo_curve`.

## What the analysis actually produces (read this first)

`run_phase("analysis")` analyzes the real audio on device. Apple Music
Understanding supplies the canonical `beats`, `downbeats`
(`downbeat_source: "music-understanding"`), `bpm`, and complete
`sections`/`segments`/`phrases` hierarchy. The consolidator preserves those
measured ranges, verifies complete contiguous section coverage, verifies that
every lower-level range is nested under a populated parent, and requires each
internal section start to lie within 0.5 seconds of the measured bar grid.
Native DSP still measures `energy_curve`,
`tempo_curve`, key, and local-change candidates, but its
`structure_candidates` are diagnostic evidence only and never become canonical
song-form boundaries. `structure_resolution` records the verified system
hierarchy and `stage_diagnostics` records every unavailable, failed, or degraded
stage instead of hiding it.

Optional signals — stems, forced lyric alignment, musical key, and
`chord_progression` — are produced **only when the corresponding on-device
model/provider succeeds**. Read `stage_diagnostics` before interpreting an
empty field: unavailable, failed, degraded, and not-applicable are distinct
states. Never fabricate a missing signal. Section **timing** comes only from
the measured system hierarchy; lyrics can label a nearby measured system
boundary, never introduce or move one.

The `run_phase("analysis")` result you receive already contains the
measured grid — the `downbeats` times and the `sections` table with real
`start`/`end`. **Use those verbatim.** You have no other source of truth
for timing; do not describe the song's structure from "listening".

## Outputs & gate

- `analysis/<song>.json` extended by
  `write_analysis_interpretation(project_dir, ...)` with:
  - top-level field `tempo_multiplier` (default 1.0); `perceived_bpm`
    (= `bpm × tempo_multiplier`) is derived from it — consumers (sanity
    tempo cap, storyboard/shotlist agent) use that.
  - top-level key `interpretation` containing `section_labels`,
    `anomalies`, `overall_character`.
- **Gate (HARD — enforced by the engine).** `approve_gate("analysis")` is
  **rejected** unless (a) a real analysis artifact exists with non-empty
  `beats` AND `downbeats`, (b) `structure_resolution.status` is `resolved` and
  every canonical boundary validates against its persisted Apple system
  hierarchy, AND (c) A2 is
  done: `interpretation.section_labels` is written through the typed tool (the
  measured sections are labeled). Run the DSP for real, THEN interpret, THEN approve — approving
  right after the DSP run is refused. After writing the interpretation, give a
  summary (BPM, section labels, anomalies) and request approval via
  show_dialog ("approve / change a label / re-analyze"). On approval:
  `approve_gate(project_dir, "analysis", notes=...)` — which surfaces the
  approval to the user and writes only after they tap Approve; you're
  requesting it, not granting it. On a decline, stay on this phase.

## Steps

### A1 — Pre-analysis check + analysis run (MANDATORY before A2)

Run the preflight first so the song is actually present.

**Step 1 — Preflight (plain agent check, no shell):**

The song and lyrics are the first two hard steps in `hardsteps.json`. The
host collects them before Project Init and writes them into `audio/` and
`lyrics/lyrics.txt`. Asking is not your job — inspect the result.

Existing story, identity, and style material is intentionally not collected
until this analysis is approved. Do not ask about or begin developing a
story in this phase; first establish the measured and interpreted song
context that the Brief needs.

Is there an audio file in `audio/`?

- **Present** → continue directly with step 2.
- **Missing** → the host startup handoff is incomplete. **HARD STOP**:
  "No audio file in `audio/` — without the song there is no analysis."
  Don't open your own song dialog and don't ask for a path.

**Step 2 — Run the analysis:**

`run_phase(project_dir, "analysis")`

This decodes the song and runs the on-device system analysis plus native feature
diagnostics, writing `analysis/<song>.json` and returning the measured `bpm`,
`downbeats`, and `sections` table. If it
returns `{"error": "phase_failed", ...}`, the song couldn't be decoded — tell
the user what the detail says (e.g. the file isn't a valid audio file) and ask
for a clean track. **Do not proceed to A2 or approve the gate on a failed run.**

**Step 3 — Use the lyrics if they arrived (optional, improves labeling):**

The host already offered the lyrics directly after the track; the user
either supplied them or skipped them. Read `lyrics/lyrics.txt`; do not
offer your own lyrics dialog.

- **Present** → lyrics are **preferred over guessing** for section labels:
  preserve lyric-derived labels already attached to their exact measured
  sections. Never remap markers by list position.
- **Absent** → instrumental track or the user declined. Label
  conservatively and move on.

After a successful run, continue with A2.

If `structure_resolution.status` is `needs_review`, stop before A2. Report
its `detail` and the non-success `stage_diagnostics` exactly. Re-running is
appropriate only after the reported evidence failure has changed; prose,
label aggregation, or invented timestamps cannot resolve it.

### A2 — Precondition

`run_phase(project_dir, "analysis")` was executed in A1;
`analysis/<song>.json` exists with `schema=analysis/v3` and measured
`beats`, `downbeats`, measured `sections`, `structure_candidates`,
`structure_resolution`, `stage_diagnostics`, `energy_curve`, `tempo_curve`.

### A2 — Resume behavior (mandatory — check first)

You are spawned fresh on every `/continue`. Before doing any work:

- Does `analysis/<song>.json` already contain a top-level key
  `interpretation` with `section_labels`, `anomalies`,
  `overall_character`? → show_dialog: "An interpretation already
  exists. Approve it (set the gate), change it (which field), or
  regenerate?" On `approve` → set the gate, done. On `change` → re-ask
  / rewrite only the affected field by calling
  `write_analysis_interpretation` with the complete revised interpretation.
  On `regenerate` → call the same tool with the replacement interpretation.
- If `interpretation` is missing → normal flow, generate it fresh.

### A2 — Tempo multiplier (MANDATORY decision, early)

Before writing the section labels, settle the tempo multiplier. The
technically measured `bpm` value often deviates by a factor of 2 from
the **subjectively perceived** tempo (measured 160, felt 80 — and the
other way around). This has structural impact on storyboard and
shotlist pacing, which is why it is decided NOW.

Workflow:

1. Read `bpm` from `analysis.json` and inspect the song (energy_curve and
   tempo_curve help).
2. Ask the user a show_dialog with the three plausible options:
   - **`×1` (confirmed)** — measured ≈ felt, multiplier 1.0.
   - **`×0.5` (halved)** — the track feels half as fast.
   - **`×2` (doubled)** — the track feels twice as fast.
3. Carry the selected value into the mandatory
   `write_analysis_interpretation` call below. Never edit the JSON directly.
4. Confirm to the user in chat: "Perceived tempo: <perceived> BPM
   (= <bpm> × <multiplier>)."

### A2 — Write the interpretation

Call `write_analysis_interpretation` exactly once with:

- `section_labels`: list of `{index, label, confidence, note}`, one per
  entry in the measured `sections`.
  - If a section already carries a lyric-derived label: preserve that exact
    marker on that exact measured boundary, confidence high (0.9).
  - Otherwise name narratively from position in the song and the
    energy/tempo curves, confidence lower.
  - Labels from {intro, verse1, verse2, ..., pre-chorus, chorus1,
    chorus2, ..., bridge, breakdown, outro}
- `anomalies`: keep every entry the consolidator pre-flagged
  (`system_structure_unavailable`, unresolved lyric markers, and other
  persisted stage evidence) and add your own
  observations.
- `overall_character`: 2-3 sentences from the tempo-curve dynamics and
  the structure.

The tool owns the JSON mutation. It preserves detector anomalies, validates
one unique label for every measured section, mirrors those labels onto the
measured section rows, and rejects any tempo multiplier except 0.5, 1, or 2.
Never hand-edit or rewrite the measured analysis artifact.

### Orientation on the v3 fields

- `sections[]`: the verified top level of the system-measured hierarchy — the
  source of truth for section timing. Label them; do not move them.
- `downbeats[]`: the system-measured bar grid. Every internal section boundary
  lies within 0.5 seconds of one; the measured section range is never snapped.
- `structure_candidates[]`: native MFCC/Mel local-change candidates retained
  for diagnostics; they never define the canonical timeline.
- `structure_resolution`: the verified system hierarchy. Do not proceed when
  its status is `needs_review`. `resolved` means complete, contiguous sections
  plus nested segments and phrases with exact boundary evidence. Reliable lyric
  evidence may label a nearby section boundary without changing its timing.
- `stage_diagnostics`: explicit outcome of every optional analysis stage.
- `energy_curve`, `tempo_curve`: for assessing dynamics.
- Present only when their model/provider succeeded: `alignment`, `stems`,
  `key`, `chord_progression`. A non-empty
  `chord_progression` is the harmonic signal; `pipeline_stages` lists
  `chords` when it was computed.

## Mandatory rules

- In A2, do not re-run the DSP — interpretation works on the JSON only.
- **Invent nothing.** Timing comes from the measured `downbeats`/`sections`
  only. If you didn't run analysis, you have no structure — run it. The
  analysis gate will reject approval without a real artifact.
- Surface every non-success `stage_diagnostics` entry and structural anomaly.
- No treatment (treatment-agent). No shotlist (shotlist-agent).
- Never demand a shell command from the user.
- The analysis runs via `run_phase(project_dir, "analysis")`, never via the
  `Agent` tool.

## Failure modes & escalation

- Preflight: no audio → hard stop and report the incomplete host handoff.
  Never open an upload dialog or approve the gate.
- `run_phase` returns `{"error": "phase_failed"}` → the song couldn't be
  decoded. Surface the detail, then use one recovery path: `show_dialog`
  with a required audio `fileIntake` and no `attachAs`; after the user
  chooses the replacement, call `attach_song(media, replace=true)` with
  the returned media reference and re-run analysis. Do not proceed on a
  failed run and never ask for a file path.
- Instrumental track / no lyrics → label sections conservatively from the
  measured boundaries and flag low confidence; never invent labels as fact.
- `needs_review` structure → stop before interpretation; labels and prose cannot
  repair missing measured system timing. Re-run only after the reported system
  analysis failure has changed.
