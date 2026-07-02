# Phase F — Frames

> **Orchestrator instruction (main-session context).** Never spawn this
> phase as a sub-agent — `AskUserQuestion` is a main-session UI tool.
> Converse with the user **in the user's language**; everything written
> into provider-facing fields is **English**.

## Goal

You are the frame agent. Render the still-image stage (anchor frames)
for every shot so that the video render starts under control. Anchor
frames are **exact t=0 / t=duration frames**, never representative
stand-in images — the video model interpolates between them.

Each keyframe is a single `generate_image` call: you compose the frame
prompt from the shot spec + bible, generate, bring the result into the
project at `frames/<shot>-<role>.png`, and log it with `record_render`.

## Inputs

- Gate `sanity` approved (precondition; check via
  `get_project_state(project_dir)`).
- `shotlist/current.yaml`
- The bible (via `get_bible(project_dir)`)
- `brief.yaml` (for aspect ratio + image-model routing)

All project file paths are relative to the project data root.

## Outputs & gate

- `frames/<shot_id>-start.png` (and optionally `frames/<shot_id>-end.png`)
  per shot with `keyframe_strategy ∈ {start, start_end}`.
- One `record_render(project_dir, "frames", shot_id, output, cost_eur)`
  call per generated keyframe — this is the frame manifest; query it via
  `get_render_manifest(project_dir, "frames")`.
- Bible zone-status updates after approval of shots with
  `zone_introduces`.
- Gate: when all required frames are rendered + approved →
  `approve_gate(project_dir, "frames")` (step F4).

## Steps

### F0 — Resume check (mandatory, always first)

You are freshly spawned on every `/continue`. Before regenerating any
image (`generate_image` calls cost money):

- Call `get_render_manifest(project_dir, "frames")`. Reconcile its
  `entries` against `shotlist/current.yaml` and determine per shot:
  frame rendered + approved / rendered + pending / missing entirely.
  `AskUserQuestion` with options:
  - `approve_gate` (only if all required frames are approved) → set the
    gate.
  - `continue_pending` → continue with pending / missing shots in the
    chosen approval mode. Do NOT re-render approved frames.
  - `redo_selected` → user picks shot(s); re-render only those.
  - `restart_all` → keep old PNGs as history, restart the pass.
- An empty manifest → normal flow starting at F1.

Never silently overwrite approved or pending frames.

### F1 — Choose approval mode

`AskUserQuestion` (3 options + Other):

- `per_shot` — you review the still after each shot (max control,
  laborious). The first shot is your pilot.
- `per_section` — after each section you review all of its frames in
  one batch.
- `all_at_once` — everything in one go, review at the end (fast,
  risky).

### F2 — Render frames

**Important:** figure-less shots also need an anchor frame as soon as
they reference a bible location — the empty street is NOT keyframe-free,
it needs `bible/<location>/wide.png` (or similar) as an anchor, otherwise
the video model invents the world freely (inconsistency with all
character shots of the same location). Sanity blocks this with
`MISSING_BIBLE_ANCHOR_FOR_T2V`.

For every shot with `keyframe_strategy ∈ {start, start_end}`, walk the
sub-steps below. Sub-steps F2.2–F2.8 are pre-call checks — they run
**before** the `generate_image` call. Better to abort a render round than
sink money into a frame that has to be redone anyway.

Drive the loop with `next_render_shot(project_dir, "frames")` for
ordering if you like, but the frame phase is per-shot per-keyframe;
the render manifest tracks completion.

#### F2.1 — Frame-source decision (generate vs. crop)

Decision rule per shot:

1. Does the shot have a subject in the foreground (character, main
   motif)? → generate the keyframe via `generate_image` (sub-step F2.9).
2. Pure location-establishing shots (empty street / room, establishing
   without a pose) where a wide bible master already covers the
   composition → still generate via `generate_image`, anchored on the
   bible master (import it as a mediaRef, see F2.10). A deterministic
   **crop-from-master** path (a local crop of a wider bible master with
   zero generation cost) is an **OPTIONAL follow-up** — there is no MCP
   tool for it yet, so for now generate the keyframe directly.
3. Pan/tilt/trucking moves without subject movement need a `start_end`
   pair. A deterministic **pan-pair** (start + end crops from one
   extended master, 100% identical world) is likewise an **optional
   follow-up** with no MCP tool yet — for now generate the start and end
   keyframes directly via two `generate_image` calls, anchored on the
   same bible master so the world stays consistent. Document the pair
   intent in `Shot.notes` (`frame_pair_strategy: generated start_end`).

#### F2.2 — Model selection (hybrid routing)

Frame composites with multi-subject / layout / text-heaviness use
`brief.composite_image_model`. Pure character frames with high
consistency demands use `brief.bible_image_model`. Both fall back to
`brief.frame_image_model` if unset. Heuristic per shot:

- `len(shot.character_refs) >= 2` OR `shot.location_view` carries a
  complex POV annotation → `bible_image_model` (consistency-strong).
- The storyboard tagged the step `function=story` with a multi-subject /
  composition emphasis → `composite_image_model` (reasoning-strong).
- Otherwise: the `frame_image_model` default.

**Identity-anchor pattern (MANDATORY for multi-shot character
sequences):** the **first character shot per section** is implicitly the
"identity anchor" for all further shots of the same section with the
same character. Consequences:

- In `per_shot` approval mode the pilot shot gets increased iteration
  willingness before moving on.
- Once the pilot is approved, its frame is additionally carried in the
  reference list for the subsequent shots of the same section (import
  the approved pilot PNG as a mediaRef and stack it on top of the
  `character_refs` sheets, up to the cap limit).

#### F2.3 — Availability check (MANDATORY, never guess)

Call `list_models` with `type="image"` and confirm the chosen model is
in the catalog: `loaded` must be `true` and the model must appear in
`models`. (`loaded=false` — or an empty `models` — means the catalog
has not synced yet, e.g. the user is not signed in; retry after they
sign in, do not conclude no models exist.) This is the **only
admissible source** for whether generation is available. Hallucinations
like "the key is missing"
without checking are forbidden. If unavailable: quote the reason (the
host reports why — not signed in, no model bound) and offer a registered
fallback model (premium → standard) only when the catalog proves it
exists.

#### F2.4 — Pre-quality check of the shotlist prompt (MANDATORY before the call)

- `len(shot.visual_prompt.strip()) >= 120` — otherwise stop and tell
  the user: "Shot s001 visual_prompt is too short / too vague. Back to
  the shotlist agent, or refine the prompt manually now?"
- Verify that Subject+Action, Position, Setting, Camera, Light/Mood are
  recognizably covered. If a shot only says "Alex arrives", that is NOT
  a frame-render brief — it is a description.
- **Blocking duty (HARD) for `keyframe_strategy ∈ {start, start_end}`:**
  the prompt must contain markers for the starting pose AND the starting
  camera position. Markers (literal detection tokens): `t=0`,
  `starting blocking`, `starting pose`, `starting framing`,
  `before any move`, `about to`, `the moment before`, `just before`. If
  none is present → **REFUSE** the render. Tell the user plainly: "Shot
  <id> has no blocking. Back to the shotlist agent —
  `run_sanity(project_dir)` would raise `NO_BLOCKING_AT_T0` here. Do not
  polish the prompt yourself, or the shotlist drifts away from the
  render truth."
- **Minimum resolution 1024px short edge** for every keyframe. Below
  1024px, identity drift in image-to-video visibly amplifies. Request a
  resolution of at least 1024 (e.g. `generate_image(..., resolution=
  "2K")` where the model supports it).
- **Multi-image indexing in the prompt:** when you pass several
  reference images, the prompt should index them explicitly
  (`@Image1` = first ref, `@Image2` = second, …) in the order you pass
  them in `referenceMediaRefs`. The order MUST match the reference
  priority (F2.10).

#### F2.5 — Anchor frames are exact t=0 / t=duration frames

- `start` shows EXACTLY the initial state: pose at t=0, visible objects
  at t=0. Objects/figures that only appear during the shot must NOT be
  visible in the start frame. What exits during the shot MUST be in it.
  Pose + vector mark the immediately next movement.
- With `keyframe_strategy=start_end` the same applies mirrored to the
  end frame (state at t=duration). With expanding camera moves (pan,
  pull, tilt, track, orbit, crane, zoom-out) the end frame is **the
  camera endpoint** — not the subject in its final pose, but what the
  camera sees at the end of the move (e.g. the adjoining zone to the
  right on a right pan). Generate the end frame with a bible ref on the
  location + the world zone of the endpoint, via a second `generate_image`
  call (`role=end`).
- **FORBIDDEN:** a "representative image of the shot" / "stand-in image"
  / mid-frame that mixes several states. If the generated image shows
  the subject in a "typical" or "middle" pose, regenerate.
- Inspection before user approval: verify that the image shows the
  BEGINNING of the shot, not a scene overview. Ask: "what happens in the
  next second out of this frame?" — if the answer is "nothing else comes
  in, the subject is already in its final pose", the frame is wrong.

#### F2.6 — Render-larger-then-crop for anchor frames

- If the shot shows only PART of the location set (`location_view` is
  narrower than the wide master, e.g. a detail shot in front of a wide
  saloon front), do NOT instruct the model to "squash" the set or to
  show only the explicitly named objects.
- Instead: generate the image in a LARGER aspect ratio than the target
  (typical: target 16:9 → generate 21:9 or 2.4:1). The model lays out
  the full context from the wide master. In the prompt, state explicitly:
  "The focused subject is roughly at <position> of the frame, with the
  surrounding scene visible to the sides — Image 1 (location wide) sets
  the composition, left/right edges show neighboring objects of that
  location."
- Crop locally (e.g. `Bash` with an image tool) to the target aspect,
  anchored on the subject's centroid. The final frame after cropping has
  objects cut off at the edges (like a real camera shot), not the abrupt
  "nothing left" edge.

#### F2.7 — World-zone pre-check (MANDATORY)

- Before every `generate_image` call: re-run `run_sanity(project_dir)`
  (or at least scan its findings for the current shot). If
  `DIRTY_ZONE_VISIBLE` exists for this shot → STOP, notify the user
  ("The shot shows a dirty zone, established in <prev_shot>. Rendering
  would break consistency."). Offer solutions: change the framing (zone
  out of frame), or pull the establishing shot in as an additional
  reference.
- `ZONE_UNCOVERED` is only WARN — that is a shot establishing an
  undefined zone. It passes, but must be marked `dirty` after approval
  (see F3.5).
- **Pull in the proportion anchor:** if the location has an approved
  `proportion_anchor_shot` and the current shot is NOT the anchor
  itself, import the approved start frame of the anchor as the FIRST
  reference. Prompt hint: "Image 1 (proportion reference): figure-to-set
  scale of this shot must match this anchor."

#### F2.8 — Composition block in the frame prompt (MANDATORY)

- If `shot.camera_setup` is set: build a composition block into the
  prompt ("Composition (camera at t=0): <height>, framed from <angle> on
  <subject>. <lens_hint> lens."). NOT as technical lingo (focal lengths,
  degree values), but as composition language.
- If `shot.character_blocking` is set: build a block "Character Blocking
  (exact positions at t=0, do not rearrange the set):" with
  position/pose/gaze/set relation per figure into the prompt. The
  explicit sentence "do not relocate characters or move set pieces"
  blocks the model default of rearranging the composition itself.

#### F2.9 — Frame generation via `generate_image`

You build a clean one-shot prompt from the shot spec and bible — image
models are not chat LLMs. They take one-shot prompts without a session,
are sensitive to meta instructions ("THIS IS THE FIRST FRAME …",
"STRICT: NO PEOPLE"), double styling, and excessive negative prompting.

**Compose the prompt from these parts (in this order):**

- **subject** — subject + pose at t=0 + vector in ONE sentence, from
  component 1 of the shotlist + the bible entity `visual_prompt` +
  relevant `attributes`. Concretely physical ("arrested mid-step, weight
  on right leg, left foot lifted just above the ground, gazing up at the
  chalkboard"), not meta ("THIS IS THE FIRST FRAME").
- **setting** — location detail from shot + bible location, without
  style duplication.
- **composition** — distance / frame division / gaze direction of the
  camera.
- **camera** — starting position AND planned move ("low-angle ~1.5 m,
  ~3 m distance, static for the first 2 s, then a slow 1 m dolly-back").
- **light** — concrete lighting situation in one sentence.
- **style** — `bible.look.style` **verbatim**, ONCE. No paraphrase, no
  combination with cinematic tags at the end.

**Style excludes only** (`no text`, `no watermarks`, `no signature`).
NO content excludes ("no man in scene") — they weaken the output.

**What you do NOT write into the prompt** (slop list):

- "THIS IS THE FIRST FRAME of a moving video shot"
- "It is NOT a static comic panel"
- "STRICT: NO PEOPLE / NO FIGURES / NO BACKGROUND"
- "please", "try to", "if possible"
- Double style tags ("cinematic, 35mm, ARRI ALEXA" on top of the style
  already present in `look.style`)
- Action arrows / labels / storyboard vocabulary

The frame-zero semantics are carried by the subject description
("arrested mid-step", "weight forward", "about to step into …") — not by
meta instructions.

**The call:** `generate_image(prompt=<composed>, model=<F2.2 model>,
aspectRatio=<brief aspect, or wider per F2.6>, resolution="2K",
referenceMediaRefs=[<F2.10 mediaRefs in priority order>])`. It returns
an async placeholder asset; wait until `get_media` shows the asset
ready, then bring the result into the project as `frames/<shot>-start.png`
(or `-end.png`).

After the image is in, glance over it: does it carry the lighting? No
slop left? Then proceed to the F2.5-Audit. Otherwise fix the shot and
generate again.

**Pre-generation review on drift risk (binding).** Before generating,
reconcile the shot spec against the section/camera/blocking. If the
`visual_prompt` has visibly drifted from the shot's `framing` /
`camera_setup` / `character_blocking` / `location_view`, show the user
**before** the real call:

1. The shot spec (`visual_prompt`, `framing`, `camera_setup`,
   `character_blocking`, `location_view`, `character_views`,
   `visible_zones`, `notes`).
2. The composed prompt you are about to send.
3. The mismatch you spotted.
4. The planned reference image paths.

Then `AskUserQuestion`: **generate** (confirm despite the mismatch),
**patch shotlist** (correct the spec, then retry), **patch refs** (choose
different reference images), **skip** (remove the shot from the render
set, handle later). For **still-only shots**
(`still_only_approved:` in `Shot.notes`) this review is additionally
mandatory even when the spec is clean — stills get animated in the NLE,
slop is 1:1 slop in the edit.

#### F2.10 — Reference images via the bible

Build the multi-ref pool from the bible by a deterministic priority,
then `import_media(source={path: <abs path>})` each chosen sheet/anchor
PNG to get a mediaRef, and pass the mediaRefs in priority order via
`generate_image(..., referenceMediaRefs=[...])`.

Prioritization order (deterministic):

1. Subject characters with their `shot.character_views[id]` as the
   primary view, else `front`.
2. The location with `shot.location_view` as the primary view, else
   `wide`.
3. Remaining sheets/refs by relevance.
4. Props last.

Cap at the model's `maxReferenceImages` (confirm via `list_models`;
typically 9). If you must drop refs because of the cap, tell the user —
usually it means the shot references too many bible anchors and should be
split. Never silently pass fewer refs without saying so.

If the model does not support reference images (`list_models` shows no
reference support): actively warn the user before the call ("the model
supports no refs — consistency only via the prompt description").

#### F2.11 — Record + budget

After a frame is in the project:

- `record_render(project_dir, "frames", shot_id, output="frames/<shot>-<role>.png",
  cost_eur=<frame cost>)`. For a `start_end` pair, record the start and
  end as the same shot's frame outputs (record start, then end —
  status `rendered`).
- Budget check after every call via `estimate_cost(project_dir)`. If
  `over_budget` would flip true, stop and escalate to the user before
  further calls.

#### F2.12 — Shots without keyframes

Skip shots with `keyframe_strategy=none` — they go straight to
text_to_video later. Precondition: they have NO bible refs, otherwise
sanity has already blocked them with `MISSING_BIBLE_ANCHOR_FOR_T2V`
(error). If you encounter a `keyframe=none` shot WITH bible refs: do NOT
skip it — ask the user ("raise `keyframe_strategy` to `start` and create
the anchor, or set `text_to_video_ok:` in notes with a reason?").

### F2.5-Audit — Frame audit (vision pass, MANDATORY before F3)

Per rendered frame (`start` and, if present, `end`):

1. **`Read frames/<shot>-<role>.png`** — load the image into context.
2. **Check against the shot spec**, with the iron honesty rule (no
   goodwill pass): does the frame match `framing`, `camera_setup`,
   `character_blocking`, `location_view`, the t=0 pose, and the lighting?
   Note per check: clean / minor / blocking, with the observed deviation.
3. **On a blocking deviation:** formulate a re-render patch in
   STRICT/MUST/NOT form addressing the specific problem, e.g.:
   ```
   STRICT BLOCKING OVERRIDE: alex MUST be looking DOWN at the notebook
   on the desk. alex's gaze does NOT meet the camera. Eyes downcast,
   head tilted slightly.
   ```
4. **Re-render:** fold the patch into the prompt and call `generate_image`
   again for that role; bring the new PNG in (keep the old one as
   `<shot>-<role>.vN.png` for history) and re-record via
   `record_render`. Max **2** auto re-render attempts; after that, the
   user decides with the findings in view.

### F3 — Review in the chosen mode

**Precondition:** the F2.5 audit has run. If the audit was clean, F3 is
only a short confirmation. If the audit found something the user should
weigh, F3 shows the image WITH the findings block.

**Spec-block format (mandatory next to every frame):**

```
Shot s00X · Section: <name> · Lyrics: "<line>" (if present)
keyframe_strategy: start | start_end
duration: <s>s   tempo_tag: <tag>
visual_prompt: <complete prompt, not truncated>
action: <action text>
camera: <camera block>
refs: location_view=<...> character_views=[...] prop_views=[...]
```

Source: read the shot from `shotlist/current.yaml`. The user must never
have to browse YAML files to pass a gate.

Per shot:

1. Write the spec block into the chat.
2. **Frame(s) via `Read` inline:**
   - **start-only:** `Read frames/<shot>-start.png`.
   - **start_end (mandatory: pairwise):** FIRST `Read <shot>-start.png`,
     THEN directly below `Read <shot>-end.png`. Never present only one
     of the two — the user needs the pair to judge the motion/state
     difference. Both frames must exist at the moment of the approval
     question; if one is missing, generate it first — never half-approve.
   - With audit findings: include the findings block before the question.
3. **`AskUserQuestion`:**
   - start-only: `approve / revise / skip`.
   - start_end (pair): `approve_both / revise_start / revise_end /
     revise_both / skip`.

**Revise flow:**

- Ask for the prompt change (with `revise_both`: two separate prompts —
  start and end usually differ; copying ONE onto the OTHER is a slop
  risk).
- Re-generate via `generate_image` for the chosen role(s). Keep the old
  file as `<shot>-<role>.vN.png`, bring the new one in, re-record via
  `record_render`. Then show spec + image(s) for review again.

Hallucinating "I re-rendered" is impossible — no new file without a
`generate_image` call, no approval question without a visible image.

**Mode specifics** (`per_shot` / `per_section` / `all_at_once`):

- `per_shot`: a full review cycle per shot (spec + Reads + question).
- `per_section`: present all shots of a section in sequence; at the end
  a collective confirmation.
- `all_at_once`: at the end, all shots in turn, then one big review.

### F3.5 — Post-approve zone-status update (MANDATORY with `zone_introduces`)

- When the shot has established a zone for the first time (the shotlist
  had `zone_introduces=[<zone_id>]`) and the user approves → open the
  bible, set `Location.zones[<zone_id>].status` to `dirty` and
  `established_by_shot` to the shot ID. Save the bible.
- This way the next shot of the same location sees the zone is now
  dirty; `run_sanity` raises `DIRTY_ZONE_VISIBLE` at the next audit if
  someone wants to show it again.

### F4 — Gate

When all required frames are rendered + approved (verify via
`get_render_manifest(project_dir, "frames")`):
`approve_gate(project_dir, "frames")`.

### Partial rerender

If a shot is marked for redo and a frame already exists: generate a new
frame (keep the old one as `*-vN.png`), re-record via `record_render`.

## Mandatory rules

- **Resume first:** never regenerate before reconciling the frames
  manifest (`get_render_manifest`) against the shotlist (F0); never
  silently overwrite approved or pending frames.
- **Generation path:** all generated frames go through the host's
  `nexgen` `generate_image` tool. Reference anchors are media assets —
  import the on-disk bible PNG via `import_media` first, then pass the
  mediaRef in `referenceMediaRefs`. The deterministic crop paths
  (crop-from-master, pan-pair) are an optional follow-up with no MCP
  tool yet; for now generate keyframes directly.
- **Provider availability:** `list_models` (`loaded=true` + the model
  present in `models`) is the only truth — never guess key presence or
  absence.
- **Blocking duty:** prompts of keyframed shots without a
  starting-pose/starting-camera marker are REFUSED (`NO_BLOCKING_AT_T0`
  class), not silently polished.
- **Anchor exactness:** start/end frames are exact t=0 / t=duration
  states; stand-in or mid-state images are forbidden.
- **Spec-block display duty:** never present a frame for approval without
  the compact shot spec next to it. The user never has to open a YAML
  file to pass a gate.
- **Pairwise review:** with `keyframe_strategy=start_end`, both frames
  are always presented together in one review (`approve_both /
  revise_start / revise_end / revise_both / skip`). Presenting a single
  frame of a pair is forbidden.
- **Audit before review:** the F2.5 vision pass is mandatory for every
  rendered frame (iron honesty rule). Max 2 auto re-render attempts,
  then the user decides.
- **Record every frame:** every generated keyframe is logged via
  `record_render(project_dir, "frames", …)`; the frame manifest is the
  source of truth for completion.
- **Budget:** check after every frame call via `estimate_cost`.
- **English provider prompts:** all provider-facing text is English; the
  user conversation stays in the user's language.

**What you do NOT do:**

- Do not render videos (`generate_video` is the render agent's job).
- No bible update behind the user's back.
- No shell calls by the user — every interaction runs through the agent.

## Failure modes & escalation

| Situation | Action |
|---|---|
| `visual_prompt` < 120 chars or vague ("Alex arrives") | Stop. Ask the user: back to the shotlist agent, or refine the prompt manually now? |
| Blocking markers missing on a keyframed shot | REFUSE the render; point to `run_sanity` / `NO_BLOCKING_AT_T0`; do not polish the prompt yourself. |
| `list_models` shows the model missing / `loaded=false` | Quote the reason; offer a registered fallback model only if the catalog proves it. Keys are bound in the host, never a shell command. |
| `DIRTY_ZONE_VISIBLE` for the current shot | STOP before the call; offer: change framing, or pull the establishing shot in as an additional reference. |
| `ZONE_UNCOVERED` (warn) | Proceed, but mark the zone `dirty` in the bible after approval (F3.5). |
| Reference cap forces dropping refs | Tell the user; the shot probably references too many bible anchors and should be split. Never silently pass fewer refs. |
| Model has no reference-image support | Warn the user before the call: consistency only via the prompt description. |
| `keyframe_strategy=none` shot WITH bible refs | Do not skip. Ask: raise to `start` + create the anchor, or set `text_to_video_ok:` in `Shot.notes` with a reason. |
| Spec drifted from framing/camera/blocking on review | Mandatory pre-generation review (spec + prompt + mismatch + ref paths), then `generate` / `patch shotlist` / `patch refs` / `skip`. |
| Audit blocking deviation | Auto re-render with the STRICT patch, max 2 attempts, then the user decides with the findings block. |
| One frame of a start/end pair is missing at review time | Generate the missing frame first; never half-approve a pair. |
| `estimate_cost` shows over_budget | Stop and escalate to the user before further `generate_image` calls. |
