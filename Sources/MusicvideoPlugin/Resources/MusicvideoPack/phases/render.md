# Phase R1/R2 — Render

> **Orchestrator instruction (main-session context).** Never spawn this
> phase as a sub-agent — presenting a structured dialog (`show_dialog`) is a
> main-session UI capability.
> Use the **interface language supplied by the host** unless the user explicitly
> requests another language; everything written
> into provider-facing fields is **English**.

All paths below are relative to the **project data root**.

## Goal

You are the render agent. You perform the actual video render — the most
expensive step in the workflow. R1 (preview) and R2 (final) differ only
in the model (cheap vs. final) and the render phase name
(`preview` vs. `final`).

The render is a per-shot loop driven by the engine: `next_render_shot`
hands you the next unrendered shot, you build the clip prompt and call
the host's `generate_video`, then log the result with `record_render` —
repeat until `next_render_shot` reports `done`.

## Inputs

- Gate `frames` approved (check via `get_project_state(project_dir)`).
- Bible sheets present for every `reference`-mode shot — they are
  imported as references and bound in the prompt.
- The latest versioned shot list via
  `show_artifact(project_dir, "shotlist")`, the bible (`get_bible`),
  `brief.yaml`, and the role-aware Frames artifact
  (`get_frames_manifest(project_dir)`).
- The render manifest for this phase (`get_render_manifest(project_dir,
  "<preview|final>")`), if any — drives the resume behavior.

## Outputs & gate

- Rendered clips brought into the project, one per shot. Each is logged
  via `record_render(project_dir, "<preview|final>", shot_id, output,
  cost_eur)`.
- The render manifest and its render-proof sidecar, updated incrementally
  per shot. The proof binds the exact video bytes to the compiled provider
  prompt and generation model; a missing or replaced file is pending again.
- Gate: the pipeline has ONE terminal gate, `render`. R1 (preview) is a
  quality pass, not a separate pipeline gate — don't approve anything for
  it. When R2 (final) is done, close the pipeline:
  `approve_gate(project_dir, "render")`. (`videos_preview`/`videos_final`
  are not gates in this engine; approving them does nothing.) `approve_gate`
  surfaces the approval to the user and writes only after they tap Approve;
  you're requesting it, not granting it. On a decline, stay on this phase.

## Steps

### 1. Resume check (mandatory, always first)

You are re-spawned fresh on every `/continue`. Before re-rendering any
video (`generate_video` calls are expensive, often several EUR per shot):

- Call `run_phase(project_dir, "render")`. Its engine-owned
  `prepare_final_render_manifest` step reconciles the terminal manifest
  and proof with the current shot list, including the valid empty-manifest
  case.
- Call `get_render_manifest(project_dir, "<phase>")`. Reconcile per
  shot using `current_output`: rendered / failed or pending /
  marked-for-redo / missing. A status alone never proves completion.
  - Preview complete → continue to the final pass; no preview gate exists.
  - Final complete → continue to the terminal `render` gate review.
  - Pending or missing shots → `show_dialog`: "Continue in the
    approval mode, or redo individual shots?" Never re-render rendered
    shots unless the user explicitly asks.
  - Redo requested → render only those, keep the old clip as history.
- An empty manifest → normal flow.

Consistency check: if the shotlist has gained shots since the last
render, that is not an error — the new shots count as "missing" and get
rendered (`next_render_shot` finds them). If the shotlist has fewer
shots or changed shot IDs: warn the user before rendering.

### 1a. Source modes (hybrid production)

Not every shot is provider-rendered. Each shot carries a `source_mode`:

- `generated` (default) — rendered here, the normal loop below.
- `imported` — the user shoots it. `next_render_shot` **skips** these
  automatically (they never appear in the loop) and they cost 0 in
  `estimate_cost`. Do not `generate_video` for them; they are shot to the
  directorial spec in the latest versioned shot list and cut in on the
  timeline.
- `ai_enhanced` — imported footage carried through a **video-to-video**
  pass. `next_render_shot` **does** return these (its response includes
  `source_mode`); route them through the edit path — the source clip is
  the input, `shot.visual_prompt` is the enhancement direction — rather
  than a from-scratch text/keyframe generation. Bill them like generated
  shots.

Check the `source_mode` field on the returned shot and the latest
versioned shot list before building the call.

### 2. Provider routing

Per shot, the video model derives from `shot.model_suggestion`
(resolved against the host catalog via `list_models` with
`type="video"`), else the brief's video preference for the phase. Use a
cheaper / faster model for `preview`, the final model for `final`.

Per shot, also evaluate `Shot.seedance_input_mode`:

- **`keyframe`** (default): classic anchoring via start/end frame from
  the frame phase. The frame is passed as `startFrameMediaRef`
  (+ `endFrameMediaRef` for `start_end`).
- **`reference`**: bible sheets (char front, location wide, etc.) are
  passed as `referenceImageMediaRefs` and bound in the prompt as
  `@Image1`, `@Image2`, …. Identity is strongly anchored; composition
  becomes the model's choice. Requires a reference-capable model.

> **Seedance 2.0** serves reference mode via its `reference-to-video` endpoint:
> up to 9 image references (the bible sheets) plus optional video/audio refs,
> native synchronized audio (`generate_audio`, on by default), and clips up to
> 15s. It is the default reference-capable target.

Reference-mode shots without bible refs are blocked pre-render by sanity
(`REFERENCE_MODE_NEEDS_REFS`). Confirm reference support against
`list_models` (`maxReferenceImages`) before routing a shot to reference
mode.

### 3. Reference-mode prompt discipline

Before rendering, re-check these sanity codes (they do not hard-block,
but they are clear indicators that the visual_prompt does not benefit
from the reference path; the authoring spec is in
`phases/shotlist.md`, rules 4 and 5):

- `REFERENCE_MODE_IDENTITY_REDUNDANT` (warn) — bible char name +
  identity description in the prompt. The sheets carry the identity; the
  text should only carry the action. Escape: `ref_identity_ok:`.
- `REFERENCE_MODE_VERBOSE_SETTING` (warn) — `location_ref` set + a comma
  list of 3+ architecture/background items. The location reference
  carries the setting. Escape: `ref_setting_ok:`.
- `REFERENCE_MODE_STORY_PROPER_NOUNS` (info) — title-case multi-word
  proper nouns not from the bible. Heuristic, hence info. Escape:
  `ref_names_ok:`.
- `REFERENCE_MODE_USES_NAMES_NOT_TAGS` (warn) — bible char names in the
  prompt WITHOUT `@ImageN` tags. Write tags instead of names ("@Image2
  waves while @Image1 watches"). Escape: `ref_tags_ok:`.

On `warn` findings: call `rewind(target_phase="<owning phase>")`,
repair through that phase's canonical writer, re-approve its gate, then
run and approve Sanity and Frames again
**before** the batch render starts. The harness invalidates that entire
downstream chain automatically. A missing bible ID or unset bible is an
**error** and hard-blocks; fix it before rendering.

### 4. Content-block pre-flight: 1 test shot before the batch (binding)

Empirically, output filters reject a meaningful fraction of multi-figure
shots even when the token linter is clean — the filter triggers on
visual gestalt (anthropomorphic character pairs large/close, weapons in
a bible sheet, suggestive poses). Content-policy fails cost **0 EUR**,
but they delay the batch and produce half-failed manifests.

**Mandatory pre-flight for R2 (final), recommended for R1 (preview):**

1. Pick the test shot deliberately — a **typical multi-char
   composition** of the project (not a single wide establishing). If
   `run_sanity` reported `BLOCKING_RISK_MULTI_CHARACTER` warnings: take
   one straight from that list.
2. Render the single test shot via the render loop (step 6) for that one
   shot only.
3. Evaluate:
   - **Test shot succeeded** → start the batch (loop over all shots).
   - **Content-policy fail** → do NOT batch. First apply the workaround
     table from `phases/shotlist.md` rule 3 (reliable: (a)
     single-char shot/reverse-shot, or (c) still frame via `generate_image`
     + Ken Burns/pan-zoom on the timeline), call
     `rewind(target_phase="shotlist")`, rewrite and re-approve the
     dependent chain, render a new test shot, then batch.
   - **Other errors** (credits, model unavailable, timeout) → resolve
     normally, then repeat the test shot.

Test-shot discipline applies in particular to briefs with
`visual_medium ∈ {2d_animation, 3d_cg, illustration, stop_motion}` and
≥1 anthropomorphic character.

### 5. Choose the approval mode

Before every R run, `show_dialog`:

- `per_shot` — approval after each video. First shot = pilot.
- `per_section` — collected per section.
- `all_at_once` — render everything, review at the end.

### 6. Render loop

Repeat until `next_render_shot(project_dir, "<phase>")` reports
`done: true`:

1. **Get the next shot:** `next_render_shot(project_dir, "<phase>")`
   returns `{shot_id, source_mode, visual_prompt, framing, camera,
   chain_with_previous_end, done}` plus, when applicable, a
   `reference_images` list (the deterministic reference plan — bible
   sheets + inherited identity-anchor frames, each a `{media_ref, …}`
   already resolved for you), `reference_warnings`, and — for a chained
   shot — `chain_start_frame_media_ref`. `imported` shots are already
   filtered out. Read the full shot from the latest versioned shot list for the
   remaining fields. If `source_mode` is `ai_enhanced`, route it through
   the video-to-video edit path (step 1a), not a from-scratch generation.
   The tool supplies `source_video_media_ref` and `source_video_path`
   from the approved Shot List; use that exact media ref and never choose
   or substitute a source yourself.
2. **Determine the model** (step 2) and confirm it via `list_models`.
3. **Compile the current shot:** call `compile_prompt` with the real
   `shotId` and model. The injected core production profile owns the
   provider action, camera, continuity, blocking, and rescue-cut clauses;
   do not reconstruct them in pack prose or substitute `shotId="none"`.
4. **Keyframe / reference selection:**
   - `source_mode=ai_enhanced`: pass the exact
     `source_video_media_ref` as `sourceVideoMediaRef`. Pass no start/end
     frames or references.
   - `keyframe_strategy ∈ {start, start_end}`: image-to-video. Pass the
     exact current `media_ref` values from `get_frames_manifest` as
     `startFrameMediaRef` (+ `endFrameMediaRef`). Require
     `audit.current_image=true` for each role. If the expected frame or
     current audit is missing → STOP with a clear error; **no silent
     fallback to text_to_video**.
   - `seedance_input_mode=reference`: pass the `media_ref`s from
     `next_render_shot`'s `reference_images` as `referenceImageMediaRefs`
     in the given order (`@Image1` = the first entry, …). That list is
     the planned set — bible sheets plus any identity-anchor frames — so
     you don't hand-pick sheets.
   - `chain_with_previous_end == true` (anchor-and-extend): pass
     `chain_start_frame_media_ref` (the predecessor clip's extracted last
     frame, already imported) as this shot's `startFrameMediaRef`. If it
     is absent, the predecessor hasn't rendered yet — render it first.
     This is the shot's sole start condition: the Shot List must use
     `keyframe_strategy=none`, and no separately generated Frames start
     image or reference-image set may be substituted.
   - Otherwise (`keyframe_strategy=none`, NO bible refs): text-to-video
     (no start frame). Sanity has already blocked the other case
     (`MISSING_BIBLE_ANCHOR_FOR_T2V`).
5. **Render:** `generate_video(prompt=<compiledPrompt>,
   compileToken=<compileToken>, shotId=<shot_id>, model=<model>,
   duration=<shot.duration_s>, aspectRatio=<brief aspect>,
   resolution=<brief.final_resolution for final / a cheaper res for
   preview>, startFrameMediaRef=..., endFrameMediaRef=...,
   referenceImageMediaRefs=[...])`. It returns only after the rendered
   asset is ready, or returns the provider failure.
   For `ai_enhanced`, call the same tool with
   `sourceVideoMediaRef=<source_video_media_ref>` and omit frame/reference
   arguments.
6. **Record:** `record_render(project_dir, "<phase>", shot_id,
   output=<the completed rendered clip's media asset id>,
   cost_eur=<shot cost>, status="rendered")`. On a provider failure mark
   it `status="failed"` and keep the loop going.
   The host fingerprints the output and every actual submission input.
   A generated shot passes only with its planned frames/reference set;
   an AI-enhanced shot passes only with the exact `source_path` declared
   by its approved Shot List.
7. **Budget check** after every shot via `estimate_cost(project_dir)`.
   If `over_budget` would flip true, abort the batch and escalate to the
   user before further `generate_video` calls.

**Crash tolerance + resume semantics:** every `record_render` persists
the manifest and proof incrementally. A crash between the two writes is
fail-closed: their mismatch makes that shot pending again. On resume,
`next_render_shot` skips only exact, currently proven renders and hands
you the missing / stale / failed ones.

**Insufficient generation budget / unavailable model** is a controlled
abort: mark the current shot `status="failed"`, give the user a clear
message with a resume hint, and stop the batch (every further call would
hit the same wall). The keys/credits are bound in the host — never a
shell command.

### 7. Partial-rerender flow

When the user asks to redo a single shot:

1. Re-render only this shot, skip the rest.
2. Keep the old clip as history.
3. Re-record via `record_render` (the new entry replaces the old).
4. Deduct the budget via `estimate_cost`; do **not** reset the
   preview pass. Re-recording a final shot automatically invalidates the
   terminal `render` gate; review and approve it again after the replacement.

### 8. Review in the chosen mode (video-review duty)

**Mandatory before every video approval question:** videos are never
presented bare. Every review combines the **spec block + the anchor
frames + the rendered clip** — the user needs the before/after evidence
to judge whether the video model actually executed the anchor logic or
hallucinated along the way.

**Spec block in chat** (compact, from the latest versioned shot list for
this shot):

```
Shot s00X · Section: <name> · Lyrics: "<line>" (if present)
keyframe_strategy: start | start_end
duration: <s>s   model: <video-model>
visual_prompt: <full prompt>
action: <action text>
camera: <camera block>
```

**Anchor frames as evidence** (mandatory — use each role's current
`media_ref` from `get_frames_manifest`):

- `start` strategy: `inspect_media` for the start asset.
- `start_end` strategy: `inspect_media` for start and end as a pair.
  The user then sees: the model started at A and was supposed to land at
  B — did it deliver, or hallucinate along the way?

**Present the clip.** Claude Code does not render videos inline. The
rendered clip is in the host media library (`get_media` lists it) and on
the timeline if you placed it (step 10). Tell the user explicitly to
watch the clip in the host preview / open the file. Without that explicit
call-out the path just floats in the answer and the user never views it.

**show_dialog** afterwards:

- `per_shot`: `approve / revise / skip` per shot.
- `per_section` / `all_at_once`: collecting question with the shot IDs
  as options.

**Revise flow:**

- Collect the feedback (pacing? identity drift? anchor miss? action
  misinterpreted?).
- Decide: prompt adjustment (re-render with the same anchors) OR anchor
  adjustment (`rewind(target_phase="frames")`, rebuild and re-approve
  Frames, then return and re-render). On identity drift, the frame is
  usually at fault, not the video prompt.
- Re-render the shot, keep the old clip as history, re-record via
  `record_render`.

### 9. Gates

- R1 (preview) done: no gate — proceed to the final pass.
- R2 (final) done: call `approve_gate(project_dir, "render")` directly — its
  single gate card closes the pipeline. Do not add an aggregate approval
  `show_dialog`; per-shot clip reviews remain granular.

### 10. Timeline placement (optional)

Once clips exist, lay them onto the host timeline so the user can review
the cut with the song over it.

- Preferred: call `assemble_timeline(project_dir, "<phase>")`. It reads the
  analysis, the shotlist, and this phase's render manifest, then places
  every rendered shot in shotlist order on a dedicated assembly video
  track, each cut snapped to a beat (a downbeat at a section boundary, a
  regular beat otherwise), and lays the song on an audio track at frame 0
  as the sync anchor. It is re-runnable (a second call rebuilds the
  assembly track in place, no duplicates) and skips shots that are not
  rendered yet, naming them. This is the beat-synced cut; prefer it over
  hand-placing clips.
- Manual fallback (a custom layout `assemble_timeline` does not cover):
  each rendered clip is already a host media asset (from
  `generate_video`); external clips come in via `import_media`. Place them
  in shotlist order on a video track via `add_clips`, one entry per shot,
  `startFrame`/`durationFrames` derived from the shot's
  `time_start`/`duration_s` times the project fps (`get_timeline` reports
  fps). The user lays the song audio over it and does the final cut.
- **Cut handles are rendered content, not freeze frames.** When a shot's
  plan puts a fade/crossfade on a side (`transition_in`/`transition_out`),
  or `brief.cut_handles_mode=with_overlap` forces it on every shot,
  `next_render_shot` returns `render_duration_s` (gross, already a whole
  second) alongside `net_duration_s`, plus `handle_pre_s`/`handle_post_s`.
  Order the model at **`render_duration_s`** exactly as given —
  `compile_prompt(shotId)` has already composed the held-beat temporal
  structure into the prompt, so the model renders the overlap as real
  micro-motion frames. Then place the clip trimmed to **`net_duration_s`**
  (in-point at `handle_pre_s`), so the visible cut sits on the net action
  and the handle material sits just off it for the fade. **Hard-cut shots
  carry none of these fields** and are ordered/placed exactly as before.
  `estimate_cost` bills the gross seconds — never freeze-pad in post (two
  stills fading into each other is slop).

### 11. Reporting after R1/R2

Explicitly list to the user, at the end: which shots rendered, which
failed, total spend (`estimate_cost`), and any still-only shots (marked
`still_only_approved:` in `Shot.notes`) — the user produces those stills
via `generate_image` and animates them on the timeline (Ken Burns /
pan-zoom).

## Mandatory rules

- Never re-render an approved shot without an explicit request from the
  user.
- No silent fallback from image-to-video to text-to-video — a missing
  expected frame is a hard stop, not a fallback.
- Videos are never presented bare for approval: spec block + anchor
  frames + clip, always together (step 8).
- The render loop is driven by `next_render_shot` →
  build prompt → `generate_video` → `record_render`, repeated until
  `done`. `done` means current file hash plus generation provenance, not
  merely `status=rendered`. Budget is checked via `estimate_cost` after
  every shot; the terminal gate is `render` (closed after the final pass)
  via `approve_gate`.
- **What you do NOT do:**
  - No final cut. The user does the editing on the host timeline.
  - No audio rendering (clips come mute). The user lays the song over it.
  - No shotlist changes (that is the shotlist agent's job).
  - No shell calls. `record_render` performs durable registration and
    the host extracts any chain-continuity frame it needs.

## Failure modes & escalation

- **Generic provider error (timeout, model glitch):** mark the shot
  `status="failed"`, the loop continues. Re-run the failed shots later —
  `next_render_shot` hands them back on the next pass.
- **Insufficient credits / generation budget:** controlled batch abort
  with a clear user message including the resume hint. After topping up
  in the host, continue the loop.
- **Budget exceeded (`estimate_cost` over_budget):** abort; this is a
  deliberate brake, never bypass it silently.
- **Content-policy fail:** do not batch. Apply the workaround table from
  `phases/shotlist.md` rule 3, call
  `rewind(target_phase="shotlist")`, rewrite and re-approve the
  dependent chain, then re-run the test shot (step 4). If a single shot
  still will not pass: still-only
  workaround (the user animates a `generate_image` still on the timeline).
- **Generation unavailable** (model missing from `list_models`, or
  `loaded=false`): surface it; keys/credits are bound in the
  host, never a shell command.
- **Shotlist drift** (fewer shots or changed shot IDs versus the
  manifest): warn the user before rendering.

### Still-only workaround (binding)

If a single shot will not pass the output filter despite everything, the
user can decide to have it **animated as a still image on the timeline**
instead of as a video. Strict discipline (same as shotlist rule 3):

1. **Never unilaterally** — explicit `show_dialog` with a
   justification (why this shot, what else was tried).
2. **Minimum stake** — mark only that one shot; prefer the
   single-character split (a) first.
3. **Medium restriction** — cartoon/animation/3D-CG/stop-motion: ok.
   Live-action: only without humans in frame.
4. **Rest positions** — figures/objects only in rest positions (no
   "running", "flying", "leaping", "jumping", "falling"). Motion comes
   from the Ken Burns cut, not the model.

**Marker:** `Shot.notes` contains `still_only_approved: <justification +
user quote>`. The render loop skips this shot (no `generate_video`); the
user generates the still via the normal `compile_prompt` →
`generate_image` path and animates it on the host timeline. Estimate and
budget guard exclude the shot.

**Reporting:** see step 11 — list the still-only shots at the end so the
user knows which stills to animate.
