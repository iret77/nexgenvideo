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
  `bpm`, canonical `sections`, measured `structure_candidates`,
  `structure_resolution`, `stage_diagnostics`, `energy_curve`, `tempo_curve`.

## What the analysis actually produces (read this first)

`run_phase("analysis")` analyzes the real audio on device. On macOS 26, an
on-device neural model supplies the canonical beat/downbeat grid, two independent
acoustic detectors measure structural candidates, and reliable forced lyric
alignment corroborates and labels nearby measured boundaries. The consolidator
snaps accepted boundaries to that measured bar grid, rejects dense phrase-level
fragments, preserves strong instrumental terminal boundaries, and records the
evidence for every canonical section in `structure_resolution`.

The macOS 27 Apple Music Understanding adapter is preserved behind an availability
gate. Once that OS ships, a complete verified section/segment/phrase hierarchy can
be selected as the stronger runtime strategy. It is not required by the macOS 26
production path. `stage_diagnostics` records every unavailable, failed, or degraded
stage instead of hiding it.

Optional signals — stems, known-text lyric alignment, musical key, and
`chord_progression` — are produced **only when the corresponding on-device
model/provider succeeds**. Read `stage_diagnostics` before interpreting an
empty field: unavailable, failed, degraded, and not-applicable are distinct
states. Never fabricate a missing signal. Section **timing** comes only from
measured audio evidence. Lyrics supply symbolic identity, never timestamps. A reliable attention-DTW
Whisper word anchor may establish its measured bar boundary when the structural
detectors miss the transition; an unaligned lyric marker can never introduce or
move timing.

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
  `beats` AND `downbeats`, (b) `structure_resolution.status` is `resolved` or
  `review_required` and every canonical boundary independently validates against
  its persisted measured evidence, AND (c) A2 is
  done: `interpretation.section_labels` is written through the typed tool (the
  measured sections are labeled). Run the DSP for real, THEN interpret, THEN approve — approving
  right after the DSP run is refused. After writing the interpretation, give a
  summary (BPM, section labels, anomalies). If a review choice is still needed,
  use `show_dialog` with `workflowDecision="analysis_interpretation_review"`
  (`change_label / re_analyze / continue_to_gate`) — never an approval option.
  Once the artifact is ready, call
  `approve_gate(project_dir, "analysis", notes=...)` directly. It surfaces the
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

This decodes the song and runs the complete on-device analysis stack,
writing `analysis/<song>.json` and returning the measured `bpm`,
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

If `structure_resolution.status` is `review_required`, continue to A2 but
keep every `single_detector` section label explicitly provisional. Before
requesting approval, show the user `structure_resolution.detail` and the exact
times of all single-detector boundaries. The approval request is the user's
review decision; never summarize this state as fully resolved consensus.

### A2 — Precondition

`run_phase(project_dir, "analysis")` was executed in A1;
`analysis/<song>.json` exists with `schema=analysis/v3` and measured
`beats`, `downbeats`, measured `sections`, `structure_candidates`,
`structure_resolution`, `stage_diagnostics`, `energy_curve`, `tempo_curve`.

### A2 — Resume behavior (mandatory — check first)

You are spawned fresh on every `/continue`. Before doing any work:

- Does `analysis/<song>.json` already contain a top-level key
  `interpretation` with `section_labels`, `anomalies`,
  `overall_character`? → show_dialog with
  `workflowDecision="analysis_interpretation_review"`: "An interpretation already
  exists. Continue to its gate review, change it (which field), or
  regenerate?" On `continue_to_gate` → call `approve_gate` directly. On `change` → re-ask
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
2. Ask the user a show_dialog with `workflowDecision="analysis_tempo"`
   and the three plausible options:
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
  (unresolved or colliding lyric markers, detector divergence, and other
  persisted stage evidence) and add your own
  observations.
- `overall_character`: 2-3 sentences from the tempo-curve dynamics and
  the structure.

The tool owns the JSON mutation. It preserves detector anomalies, validates
one unique label for every measured section, mirrors those labels onto the
measured section rows, and rejects any tempo multiplier except 0.5, 1, or 2.
Never hand-edit or rewrite the measured analysis artifact.

### Orientation on the v3 fields

- `sections[]`: the canonical, contiguous song sections. On macOS 26 each
  internal boundary is snapped to the measured bar grid and carries acoustic
  detector consensus, reliable known-text alignment evidence, or explicitly
  reviewable single-detector evidence. Label them; do not move them.
- `downbeats[]`: the measured bar grid used by the selected runtime strategy.
  Native evidence boundaries are exact entries on this grid.
- `structure_candidates[]`: the persisted independent librosa and essentia
  measurements from which the macOS 26 resolver selects acoustic boundaries.
- `structure_resolution`: the independently reproducible selection record.
  Do not proceed when its status is `needs_review`. `resolved` and
  `review_required` provide complete contiguous sections plus exact per-boundary
  evidence. A nested section/segment/phrase `hierarchy` exists only when the
  availability-gated Apple Music Understanding strategy resolved on macOS 27.
  Reliable known-text alignment may provide a vocal time anchor; lyric text supplies
  the marker label and never invents timing.
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
  decoded. Surface the detail, then use one recovery path: `show_dialog` with
  `workflowDecision="analysis_track_replacement"`
  with a required audio `fileIntake` and no `attachAs`; after the user
  chooses the replacement, call `attach_song(media, replace=true)` with
  the returned media reference and re-run analysis. Do not proceed on a
  failed run and never ask for a file path.
- Instrumental track / no lyrics → label sections conservatively from the
  measured boundaries and flag low confidence; never invent labels as fact.
- `needs_review` structure → stop before interpretation; labels and prose cannot
  repair a missing bar grid or acoustic evidence. Report the persisted detail
  and stage diagnostics. Re-run only after the relevant input or failed analysis
  stage has changed.
- `review_required` structure → interpret provisionally, surface every
  single-detector boundary and the resolution detail, then let the user's
  explicit approval decide whether to continue or re-analyze.
