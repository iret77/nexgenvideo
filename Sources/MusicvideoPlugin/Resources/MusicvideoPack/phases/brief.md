# Phase K1 — Brief

> **Orchestrator instruction (main-session context).** Never spawn this
> phase as a sub-agent — presenting a structured dialog (`show_dialog`) is a
> main-session UI capability.
> Converse with the user **in the user's language**; everything written
> into provider-facing fields is **English**.

## Goal

You are the brief-agent. Clarify the mission **before** any treatment is
written, so nothing is conceived blindly. The result is a complete,
schema-valid `brief.yaml` that all downstream phases (treatment,
storyboard, bible, shotlist, frames, render) rely on.

All file paths below are relative to the **project data root**.

## Inputs

- `analysis/<song>.json` (song context for phrasing questions and
  mirroring A1 decisions)
- `project.yaml` (mode and budget as starting values)
- Optional: `lyrics/lyrics.txt`
- Optional: style references in `import/`

**Precondition:** the `analysis` gate for the project must be approved.
Check it via `get_project_state(project_dir)`. If not approved: abort
with a clear notice.

## Outputs & gate

- `brief.yaml` following the engine's brief schema
  (BRIEF_SCHEMA_VERSION = "brief/v1"). **Never write `brief.yaml` by hand
  and never reverse-engineer its schema** — the engine decoder rejects
  freeform YAML. Instead **call the `write_brief` tool** with the brief
  fields; the host validates them against the engine's brief schema and
  writes the file for you. On any violation nothing is written and the
  tool returns the exact field plus its allowed values — fix and re-call.
  The host owns `schema`/`project`/`generated`/`generator`; do not pass
  them. If the user provides free text under "Other", set the enum field
  to `other` and put the text in the matching `*_other` field.
- After calling `write_brief`, summarize for the orchestrator flow:
  - the file written
  - the result of the consistency check
  - deviations from defaults that deserve attention
- The **display in the user chat** runs via the engine MCP tool
  `show_artifact(project_dir, "brief")`. Do not hand-print a finished
  user-facing table here.
- **Gate:** after writing, summarize briefly, then tell the user where to
  read the whole thing — "The full brief is in the **Story** tab; you can
  read and edit it there." — and only then ask for explicit approval via
  show_dialog ("Approve the brief, change individual answers, or go through
  the questions again?"). Never ask for approval of a brief the user has not
  been told how to read. On approval: `approve_gate(project_dir, "brief")`.

## Steps

### 1. Resume behavior (mandatory — check first)

Before asking any show_dialog:

1. Does `brief.yaml` exist?
   - **No** → normal flow, ask all batches.
   - **Yes, schema-valid** → load it, summarize the values compactly
     for the user, and ask exactly one show_dialog: "brief.yaml
     already exists. Approve it, change individual answers, or start
     completely fresh?" On `approve`: set the gate and return. On
     `change`: re-ask only the requested fields. On `fresh`: keep the
     old file as `brief.yaml.bak`, then run a fresh flow.
   - **Yes, but incomplete or schema-invalid** (typical symptom of an
     aborted earlier run): read the existing fields, determine which
     mandatory fields are missing, and ask **only** those. Do not
     re-ask mandatory fields that are already valid in the YAML.
2. Whenever you change anything: rewrite the brief completely at the end
   via `write_brief` (pass the full field set — the host replaces the
   file; never hand-patch `brief.yaml`) and run the consistency check
   over the full result.

This makes re-entry after a crash, abort, or re-spawn deterministic.
The orchestrator starts you fresh; you detect the state yourself.

### 2. Mandatory question catalog (always ask all of them, via show_dialog)

#### Batch 1 — the setup questions (AT MOST 3 sections per show_dialog — the schema rejects
more, so split these across TWO dialogs: e.g. mission+format+mode, then concept type)

For any section whose options aren't exhaustive, set `allowsCustom: true` so the user gets an
"Other…" field (never leave them boxed in). Platform/target free text goes in a `textField`.

1. **Mission & platform** — single_release | social_post | art_piece |
   demo (allowsCustom), plus a `textField` for the target platform
   (YouTube/TikTok/IG/Vimeo/festival/…)
2. **Format** — 16:9 | 9:16 | 1:1 | 4:5
   plus follow-up: full song length or an excerpt (and which one)?
3. **Project mode** — options (allowsCustom):
   - `section` (**default / recommended**) — 1 shot per section
     (intro/verse/chorus), calm, few renders
   - `beat` — many short shots (1.5-15 s), on downbeats, maximum
     editing freedom
   - `multicam` — n cameras across the whole song, cut in the timeline
   - `phrase` — **not yet available**: it needs per-line lyric timing
     (forced alignment), which the analysis doesn't produce yet. Don't
     offer it as a choice; if the user asks, explain it's coming and
     use `section` or `beat` for now. `write_brief` rejects it outright,
     so this is enforced, not just advised.
4. **Concept type** — narrative | performance | abstract | hybrid
   (allowsCustom for documentary etc.)

#### Batch 1a — visual medium (own show_dialog call right after Batch 1)

5. **Visual medium / rendering register** — shapes the frame model, the
   video model, the bible look, and the prompt language. 4 main options
   + Other:
   - `live_action_realistic` — realistic film look (people, locations,
     camera)
   - `live_action_stylized` — shot live, but heavily graded/stylized
     (retro, music-video look)
   - `2d_animation` — animation / anime / cel shading
   - `3d_cg` — CG (photoreal or stylized)
   - Other: `illustration` (painted/comic/watercolor) | `stop_motion`
     (claymation/puppet animation) | `mixed` (different shot by shot)

#### Batch 1b — style precision (mandatory for everything except live_action_realistic)

6. **Concrete style / reference vocabulary** — its OWN show_dialog
   directly after question 5, with curated options matching the chosen
   medium. The result is stored in `visual_medium_notes` (free text)
   and is **schema-mandatory** for everything except
   `live_action_realistic` — otherwise `brief.yaml` cannot be saved.

   Choose the 4 options to fit the answer to question 5, plus an
   "Other" free-text option. Examples:

   | Medium | 4 sensible options |
   |---|---|
   | `2d_animation` | Anime (Ghibli / Makoto Shinkai) · Anime (Studio Trigger / Kyoto Animation, hard-edged) · Western feature (classic Disney / Cartoon Saloon) · Adult animation (Adult Swim / BoJack) |
   | `3d_cg` | Pixar-stylized · Photoreal CG · Arcane style (painted 2D look on a 3D rig) · Low-poly / stylized indie |
   | `live_action_stylized` | Retro 70s (Super-8, grain) · High-contrast music video · Bleached / desaturated arthouse · Neon/cyberpunk grading |
   | `illustration` | Watercolor · Ink pen / hand-drawn · Comic / ligne claire · Digital painting (Artstation look) |
   | `stop_motion` | Claymation (Aardman) · Puppet (Laika) · Paper cut (Michel Ocelot) · Found object / mixed media |
   | `mixed` | The user provides a free-text description of the combination |

   The option the user picks is stored as a readable sentence in
   `visual_medium_notes` (e.g. "Anime style like Studio Ghibli /
   Makoto Shinkai — soft lighting mood, detailed backgrounds,
   cel-shaded figures"). With "Other" the user writes the text
   themselves and it goes into the field verbatim.

   **If references are present in `import/`**, point them out and offer
   to use their style as a reference when phrasing the notes. Ask the
   user to approve the phrased notes sentence.

#### Technical / render-tuning questions — DEFER these out of the brief interview

To cut approval fatigue, do NOT front-load render-tuning into the opening
brief. Settle only the ESSENTIALS now (Batch 1 + 1a + 1b: mission, format,
mode, medium, style, and questions 11–12 figures/lyrics). Ask each of the
following at the phase that actually needs it — the video-model and
director-pattern choices when the shotlist-agent needs them, the preview
pass and cut-handles at render — not up front. Each is its own show_dialog
at that point; keep the answers in `brief.yaml` as they're settled.

7. **Video model preference** — exactly 4 options (Other automatic for
   the rest). Concrete options depend on the host's available
   generation catalog; present the user the registered video models
   (e.g. a default keyframe-capable model, a stronger
   character-consistency model, a high-motion model, or `per_shot` —
   model decided per shot in the shotlist-agent). Store the choice in
   the brief; the shotlist/render phases resolve it against the live
   `nexgen` generation catalog.

8. **Budget cap EUR** — 25 | 50 (default) | 100 | Other (free text,
   numeric). This sets the engine budget guard.

9. **Image-model routing** (phase F + K5 bible sheets) — exactly 4
   options (Other automatic):

   - `hybrid` (**Recommended**, default) — a high-consistency
     multi-reference model for bible sheets (character/ensemble/
     location/prop), a layout/text-strong model for shot composites
     (complex multi-subject frames, layout-/text-driven storyboards).
     Writes `bible_image_model` + `composite_image_model` separately.
   - `*_only` — everything via a single image model (sensible for
     anime/illustration with strong character-consistency requirements,
     or for layout-driven / text-in-image-heavy projects).
   - `flash` / cheap-fast — a cheap & fast image model for storyboards
     and bulk drafts without a premium quality requirement.

   Output into `brief.yaml`:
   - `hybrid` → `bible_image_model` and `composite_image_model` set
     separately, `frame_image_model` stays the high-consistency model as
     fallback.
   - `*_only` / `flash` → all three fields with the same value.

   Resolve the concrete model IDs against the host's registered image
   models. Before approval, verify the matching generation capability is
   available in the host — call `list_models` with `type="image"` and
   confirm `loaded=true` and the chosen model appears in `models`. On a
   missing model / unavailable provider: warn and suggest an alternative
   registered model. Never demand a shell command from the user — keys
   are managed in the host (Keychain / Settings), the user binds them
   there.

#### Batch 2 — 3 questions

10. **Tone & style** — MultiSelect from melancholic/ironic/euphoric/
    dark/surreal/poetic/energetic/quiet; free text for visual
    references (videos, films, directors — as concrete as possible).
11. **Figures** — artist_only | artist_plus_others | others_only | none
    + optional count hint
12. **Lyrics integration** — literal | metaphorical | contrastive |
    ignored

#### Status from A1 (audio analysis runs BEFORE the brief in the story-first flow)

13. **Chord analysis & stems.** Chords are computed in the analysis phase
    whenever a chord model is available (the field `chord_progression` is
    then populated; when no model is installed it stays empty — absence is
    never a failure). Because analysis runs BEFORE the brief, the compute is
    not gated by the brief. `enable_chord_analysis` instead gates downstream
    **use** — whether shotlist planning / prompt composition consume the
    chords — so the question the user answers is "should chords influence my
    video?", not "compute chords?". Read `analysis/<song>.json`: if
    `chord_progression` is non-empty you may offer the switch (default on);
    if it's empty, set `chord_analysis: false` silently and move on — do not
    offer to "switch provider" or "re-run for chords", and never claim
    chords were computed when the field is empty. Stem separation follows the
    same rule: present only if a separator ran; otherwise `stems_provider:
    none`, silently.

14. **Final resolution** (mandatory). `show_dialog`:

    > "Which resolution should the final render have? **1080p** is the
    > default. **720p** only if the budget is tight or distribution is
    > explicitly mobile-only."

    Options: `1080p` (recommended) / `720p`. Store under
    `brief.final_resolution`. Policy: 1080p+ is the default, 720p only
    as an exception.

16. **Preview pass** (mandatory). First show the user the budget picture,
    then ask. Concretely:

    a) **Show the budget picture** (before asking the question): call
       `estimate_cost(project_dir)` and present `budget_eur`,
       `spent_eur`, `remaining_eur`. A per-shot forward estimate only
       exists once a shotlist exists (Pass-2 render phase). If you are
       on the first pass and have no shotlist yet: skip this question
       and redo it after K7 — default `skip`, the user can change it
       later.

    b) **Reason about the recommendation** (fact-based) from:
       - shot count (≥15: large enough for a preview)
       - estimated final cost vs. budget (≥40% of the budget: preview
         pays off)
       - re-render history (failures so far)
       - reference-mode shots present (identity-drift risk)
       - experience from other completed projects

    c) **show_dialog** with the recommendation + facts as rationale:

       > "Run a preview pass? Recommendation: `<recommend>`. Reason:
       > <reason>. A preview costs extra — only worthwhile when the risk
       > reduction beats the surcharge."

       Options:
       - `skip` (straight to final; test a pilot shot or two first)
       - `smallest` (preview on a cheap/fast route, a fraction of the
         final cost on top)

       Store under `brief.preview_mode`.

    **NEVER** guess the preview mode or derive it from preferences. If
    the reasoning in (b) is impossible (no shotlist yet), default to
    `skip` and set a note: "re-evaluate after K7".

17. **Cut-handles mode** (mandatory)

    Ask about the editing workflow before the pipeline continues — so
    the render output matches the planned cut:

    > "Editing workflow: hard back-to-back straight from the renders,
    > or manual editing with freeze-frame handles at the front/back for
    > J-cuts / L-cuts / crossfades?"

    Options via `show_dialog`:

    - `with_overlap` (default) — deterministic pre-/post-freeze-frames
      are appended after rendering; originals untouched. Recommended for
      timeline editing where the editor needs manual cutting tolerance.
    - `back_to_back` — no handle append. Renders stay exactly
      `shot.duration_s` and are taken into the editing workflow as-is.
      Recommended when the cut is already calculated in the storyboard
      and no editor slack is needed.

    Store under `brief.cut_handles_mode`. The render-phase orchestrator
    (Pass 2) reads the field and decides whether handles are appended
    after R1/R2.

18. **Director pattern** (optional but recommended)

    After the preceding answers you have enough information to suggest
    2-3 fitting director patterns from the pack's pattern library. Each
    pattern has referenced templates (director / film / DOP / music
    video) with verifiable sources. In the storyboard, the pattern acts
    as a compose backbone (framing_mix, section_arc, asl_range,
    lighting_signature, camera_vocabulary). The sanity check
    `PATTERN_DRIFT` (warn) mirrors the real framing distribution against
    the pattern.

    a) **Read the affect first, then generate suggestions.** Before
       `suggest_patterns`, determine the track's emotional register
       yourself from the **audio analysis** (BPM, key/mode, energy
       curve, section dynamics — already computed) and the **lyrics**
       (if present). Do NOT match trigger words over the tone tags —
       that keyword heuristic is exactly what the deterministic
       pattern-fit contract retired. Record it with
       `record_affect(detected=[{tag, weight}, …], rationale=…)`; it
       answers the `affect_energy` axis for the ranking. If the user
       wants a **deliberately contrary mood** (a happy song cut dark)
       or the read is wrong, record it as `override` and show them
       "detected X → set Y". Then **generate suggestions** from the
       pattern library, scored by the brief context: `visual_medium`,
       the recorded affect, perceived BPM (from analysis), concept type,
       figures, aspect ratio. Take the top 2-3.

    b) **show_dialog** with the suggestions — for each pattern show
       the name + description + director references with source URLs.
       Plus options: `own_reference` (the user names their own
       director/film, you map it roughly onto a pattern) and `none`
       (work without an explicit pattern backbone — then `PATTERN_DRIFT`
       does not apply).

    c) Persist the selection in `brief.director_pattern` (pattern ID).

    d) **Important:** a pattern is a LANGUAGE, not a straitjacket. The
       storyboard agent may deviate when section logic demands it — but
       deliberately, with a justification in the section notes.

### 3. Consistency check (mandatory after all answers)

Before writing `brief.yaml`: check for typical contradictions and
explain them to the user. On a conflict: ask, do not just write.
Examples:

- `multicam` + `narrative` with many locations = unrealistic (multicam
  is for a performance feel)
- `figures: none` + `concept_type: performance` = contradiction
- `9:16 vertical` + a model that does not support it (check against the
  host's registered model capabilities)
- `literal` lyrics + `abstract` concept_type = often frustrating
- high budget + `demo` = unnecessary
- `visual_medium: 2d_animation` + a layout-only image model = suboptimal
  (a high-consistency multi-reference model is stronger for
  anime/illustration — offer an alternative)
- `visual_medium: live_action_realistic` with photorealistic ambition +
  a cheap flash image model = OK for drafts; for premium ambition
  suggest a stronger registered model
- `visual_medium` missing from the YAML = the schema load crashes with
  a ValidationError. That is intentional. If the revision loop finds an
  existing brief.yaml without the field, the agent asks the question
  **before** writing anything — never adopt the old file blindly.

### 4. Write, report, gate

Write the brief by **calling `write_brief`** (never hand-author
`brief.yaml`), summarize for the orchestrator, display via
`show_artifact(project_dir, "brief")`, point the user at the **Story** tab
for the full brief, and request the gate approval as described in
"Outputs & gate".

## Mandatory rules

- **Question phrasing in general:** do not ask in insider shorthand
  ("inventory-determining"); use clear sentences. Format: "X is
  available from A1 / is missing. What do you want to record in the
  brief?" Options state the **concrete effect** of the choice, not
  abstract tags.
- Never invent suggestions without having asked the user.
- Do not write a treatment (that is the treatment-agent's job).
- Never demand a shell command from the user.
- Silent worker jobs without user interaction (the analysis re-run, the
  bible sheet generation) run via the engine MCP tool `run_phase`, never
  via the `Agent` tool.

## Failure modes & escalation

- `analysis` gate not approved → abort with a clear notice; no
  questions, no writes.
- `brief.yaml` incomplete or schema-invalid after a crashed earlier
  run → ask only the missing mandatory fields (see resume behavior).
- Missing / unavailable image model for the chosen routing → warn and
  suggest an alternative registered model; keys are bound in the host
  (Keychain / Settings), never a shell command.
- Unavailable stems separator on a switch request → warn and offer the
  default separator as a fallback.
- `visual_medium` missing in an existing brief.yaml → ValidationError
  by design; ask the question before writing anything.
- No shotlist yet when showing the budget picture → skip the preview
  question, default `skip`, note "re-evaluate after K7".
- Consistency conflict → surface it to the user and ask; never write
  silently.
