# Phase R1/R2 — Render

> **Orchestrator instruction (main-session context).** Never spawn this
> phase as a sub-agent — presenting a structured dialog (`show_dialog`) is a
> main-session UI capability.
> Converse with the user **in the user's language**; everything written
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

- Gate `frames` approved (for `keyframe`-mode shots; check via
  `get_project_state(project_dir)`).
- Bible sheets present for every `reference`-mode shot — they are
  imported as references and bound in the prompt.
- `shotlist/current.yaml`, the bible (`get_bible`), `brief.yaml`, and
  the frames manifest (`get_render_manifest(project_dir, "frames")`).
- The render manifest for this phase (`get_render_manifest(project_dir,
  "<preview|final>")`), if any — drives the resume behavior.

## Outputs & gate

- Rendered clips brought into the project, one per shot. Each is logged
  via `record_render(project_dir, "<preview|final>", shot_id, output,
  cost_eur)`.
- The render manifest, updated incrementally per shot (the engine
  persists it on every `record_render`).
- Gate: R1 done → `approve_gate(project_dir, "videos_preview")`; R2 done
  → `approve_gate(project_dir, "videos_final")`.

## Steps

### 1. Resume check (mandatory, always first)

You are re-spawned fresh on every `/continue`. Before re-rendering any
video (`generate_video` calls are expensive, often several EUR per shot):

- Call `get_render_manifest(project_dir, "<phase>")`. Reconcile per
  shot: rendered + approved / rendered + pending / marked-for-redo /
  missing.
  - All rendered + approved → set gate `videos_<phase>`, done.
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
  directorial spec in `shotlist/current.yaml` and cut in on the timeline.
- `ai_enhanced` — imported footage carried through a **video-to-video**
  pass. `next_render_shot` **does** return these (its response includes
  `source_mode`); route them through the edit path — the source clip is
  the input, `shot.visual_prompt` is the enhancement direction — rather
  than a from-scratch text/keyframe generation. Bill them like generated
  shots.

Check the `source_mode` field on the returned shot (and in
`shotlist/current.yaml`) before building the call.

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

On `warn` findings: patch the shotlist and re-run `run_sanity` **before**
the batch render starts — these findings are the most common quality
gain per render euro. A missing bible ID or unset bible is an **error**
and hard-blocks; fix it before rendering.

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
     + Ken Burns/pan-zoom on the timeline), patch the shotlist, render a
     new test shot, then batch.
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
   returns `{shot_id, source_mode, visual_prompt, framing, done}`
   (`imported` shots are already filtered out). Read the full shot
   from `shotlist/current.yaml` for the remaining fields. If
   `source_mode` is `ai_enhanced`, route it through the video-to-video
   edit path (step 1a), not a from-scratch generation.
2. **Determine the model** (step 2) and confirm it via `list_models`.
3. **Build the clip prompt** from `shot.visual_prompt` + `shot.motion`
   (Subject → Action → Environment → Camera → Style → Constraints, kept
   tight, ~60–100 words). The style already sits in `shot.visual_prompt`
   from the bible look — **never** append freehand extra style tags
   ("cinematic, ARRI ALEXA") and never quality killers ("epic /
   stunning / amazing").
4. **Keyframe / reference selection:**
   - `keyframe_strategy ∈ {start, start_end}`: image-to-video. Import
     the approved frame(s) (`frames/<shot>-start.png`, and `-end.png`
     for `start_end`) via `import_media(source={path:...})`, then pass
     the mediaRefs as `startFrameMediaRef` (+ `endFrameMediaRef`). If
     the expected frame is missing → STOP with a clear error; **no
     silent fallback to text_to_video** (that ruins pilots).
   - `seedance_input_mode=reference`: import the bible sheets and pass
     them as `referenceImageMediaRefs` in the deterministic order
     (`@Image1` = character_refs[0], …; see shotlist rule 5).
   - `chain_with_previous_end == true` (anchor-and-extend): use the
     **last frame of the previous shot's clip** as this shot's start
     frame — extract it from the predecessor's rendered clip (e.g.
     `Bash` ffmpeg on the in-project file) and import it as the
     `startFrameMediaRef`. Continuity is cleaner this way than with
     frames generated in parallel.
   - Otherwise (`keyframe_strategy=none`, NO bible refs): text-to-video
     (no start frame). Sanity has already blocked the other case
     (`MISSING_BIBLE_ANCHOR_FOR_T2V`).
5. **Render:** `generate_video(prompt=<built>, model=<model>,
   duration=<shot.duration_s>, aspectRatio=<brief aspect>,
   resolution=<brief.final_resolution for final / a cheaper res for
   preview>, startFrameMediaRef=..., endFrameMediaRef=...,
   referenceImageMediaRefs=[...])`. It returns an async placeholder
   asset; wait until `get_media` shows the asset ready (or failed).
6. **Record:** `record_render(project_dir, "<phase>", shot_id,
   output=<the rendered clip's in-project ref / path>,
   cost_eur=<shot cost>, status="rendered")`. On a provider failure mark
   it `status="failed"` and keep the loop going.
7. **Budget check** after every shot via `estimate_cost(project_dir)`.
   If `over_budget` would flip true, abort the batch and escalate to the
   user before further `generate_video` calls.

**Crash tolerance + resume semantics:** every `record_render` persists
the manifest incrementally, so a crash mid-batch leaves a consistent
manifest. On resume, `next_render_shot` skips already-rendered shots and
hands you only the missing / failed ones.

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
   `videos_preview` / `videos_final` gate (one shot, not the whole
   project).

### 8. Review in the chosen mode (video-review duty)

**Mandatory before every video approval question:** videos are never
presented bare. Every review combines the **spec block + the anchor
frames + the rendered clip** — the user needs the before/after evidence
to judge whether the video model actually executed the anchor logic or
hallucinated along the way.

**Spec block in chat** (compact, from `shotlist/current.yaml` for this
shot):

```
Shot s00X · Section: <name> · Lyrics: "<line>" (if present)
keyframe_strategy: start | start_end
duration: <s>s   model: <video-model>
visual_prompt: <full prompt>
action: <action text>
camera: <camera block>
```

**Anchor frames as evidence** (mandatory — the user compares the
before/after state against the rendered clip):

- `start` strategy: `Read frames/<shot>-start.png` (the approved source).
- `start_end` strategy: `Read frames/<shot>-start.png` AND directly
  below `Read frames/<shot>-end.png` as a pair. The user then sees: the
  model started at A and was supposed to land at B — did it deliver, or
  hallucinate along the way?

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
  adjustment (back to the frame phase F — new frame, then re-render). On
  identity drift, the frame is usually at fault, not the video prompt.
- Re-render the shot, keep the old clip as history, re-record via
  `record_render`.

### 9. Gates

- R1 done: `approve_gate(project_dir, "videos_preview")`.
- R2 done: `approve_gate(project_dir, "videos_final")`.

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
- Cut handles (freeze-frame head/tail for J-cuts / L-cuts / crossfades,
  per `brief.cut_handles_mode`) are a post-processing follow-up — there
  is no MCP tool for them on this surface yet. With
  `cut_handles_mode=back_to_back`, no handles are wanted anyway; with
  `with_overlap`, note to the user that handle generation is a manual
  follow-up in the editor.

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
  `done`. Budget is checked via `estimate_cost` after every shot; gates
  are `videos_preview` / `videos_final` via `approve_gate`.
- **What you do NOT do:**
  - No final cut. The user does the editing on the host timeline.
  - No audio rendering (clips come mute). The user lays the song over it.
  - No shotlist changes (that is the shotlist agent's job).
  - No shell calls by the user — every interaction runs through the
    agent. (The agent may use `Bash` ffmpeg internally for last-frame
    extraction.)

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
  `phases/shotlist.md` rule 3, patch the shotlist, re-run the
  test shot (step 4). If a single shot still will not pass: still-only
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
user generates the still via `generate_image` and animates it on the host
timeline. Estimate and budget guard exclude the shot.

**Reporting:** see step 11 — list the still-only shots at the end so the
user knows which stills to animate.
