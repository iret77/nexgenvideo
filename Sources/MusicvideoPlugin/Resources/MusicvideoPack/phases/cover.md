# Post-pipeline utility — Cover Images

> **Orchestrator instruction (main-session context).** Never spawn this
> utility as a sub-agent — presenting a structured dialog (`show_dialog`) is a
> main-session UI capability.
> Use the **interface language supplied by the host** unless the user explicitly
> requests another language; provider-facing fields are **English**.

This is an optional utility after the production pipeline, not a pipeline
phase. It has no gate, never changes phase order or lineage, and never rewinds
an approved artifact. Run it only when `get_project_state(project_dir)` proves
that Render and every earlier phase are approved.

## Goal

Create project-media cover artwork for selected platform formats: one clean
image per format and, optionally, a second image with integrated artist/title
typography.

| Format | Aspect | Use |
|---|---|---|
| `square` | 1:1 | Spotify, Apple Music, Bandcamp, Instagram feed |
| `landscape` | 16:9 | YouTube thumbnail, Facebook cover |
| `portrait` | 9:16 | TikTok, Instagram Reels/Story, YouTube Shorts |

Generated covers remain normal project media assets with descriptive names such
as `Cover — Square — Clean` and `Cover — Square — Artist + Title`. Do not write
cover manifests or files into canonical pipeline directories.

## Inputs

- A fully approved pipeline, including Render.
- Bible sheets as optional generation references, read with `get_bible` and
  imported as host media with `import_media` when needed.
- Runnable image models from `list_models(type="image")`.

## Steps

### C1 — Choose formats

Use `show_dialog`: "Which platforms need cover artwork?" Multi-select:

- Streaming standard — square, 1:1
- YouTube thumbnail — landscape, 16:9
- TikTok / Reels / Shorts — portrait, 9:16

Process each selected format through C2–C5.

### C2 — Brief the current format

Ask for the subject:

- Main character from the Bible
- Location motif from the Bible
- Abstract style image
- Other — free text

Call `list_models(type="image")`. Offer only models the host reports as loaded
and runnable. Explain which offered model supports the selected Bible reference
count and which can render integrated typography when a text variant is wanted.

Add the format constraint to the intent:

- `square`: square composition, one clear focal point, readable at thumbnail size.
- `landscape`: YouTube thumbnail, subject slightly off-center, negative space,
  readable at 320 px width.
- `portrait`: vertical social composition, motif in the upper or middle third,
  lower 15% and right edge clear of critical detail.

### C3 — Generate and review the clean cover

Compose the intent from the subject, format constraint, and Bible look. Import
only the chosen Bible sheets, then call
`compile_prompt(..., shotId="none")` and `generate_image` with the returned
compiled prompt/token, the selected aspect ratio, optional reference media, and
a descriptive media name. To group multiple compiled requests under one native
usage review, use prepare_generation_batch instead of submitting those items
separately. The host executes approved batch items; do not call generate_image
again for the same requests.

The host owns spend approval. Never imply that a model is free or submit a paid
generation without its spend card.

When ready, show the generated media and use a granular review dialog:

- Keep
- Revise the subject or model
- Skip this format

Keep proceeds to C4. Revise returns to C2 for this format. Skip proceeds to the
next selected format, or C6 if none remains. This review decides only the current
image; it is not a phase approval.

### C4 — Offer a typography variant

Use `show_dialog`: "Create a second variant with artist and title?"

- Yes → C5
- No → next format

### C5 — Generate integrated typography

Ask explicitly for Artist and Title. Never infer either from the project name,
Brief, Treatment, or imported filenames.

Select a runnable text-capable image model. Reuse the approved clean cover's
existing media ID as a reference; do not import it again. Compile a new `shotId="none"` intent that asks the model to integrate
the exact artist/title wording into the design, and call `generate_image` with a
descriptive media name.

Show the generated variant and offer a granular Keep / Revise / Skip review.
Keep or Skip proceeds to the next format
(or C6); Skip retains the clean cover. Revise repeats C5 with the requested
changes and a new spend review. If text is
garbled, offer another text-capable model or omit the typography variant. Do not
claim a deterministic local overlay exists; the host exposes no such renderer.

### C6 — Finish

After all selected formats, show the kept media assets together and summarize
their names, aspect ratios, and models. The utility is complete immediately;
there is no aggregate approval or pipeline mutation.

## Mandatory rules

- Run only after the canonical pipeline is fully approved.
- Use the guarded post-pipeline utility capabilities `import_media`,
  `compile_prompt`, `prepare_generation_batch`, and `generate_image`.
- Use the globally available read tools `get_project_state`, `list_models`, and
  `get_bible`, plus the main-session `show_dialog`, for inspection and choices.
- Never call phase runners, gate writers, canonical artifact writers,
  `record_render`, or timeline assembly from this utility.
- Never derive artist/title text. Ask explicitly.
- Keep the clean variant when creating typography.
- Never guess model availability; use the current host catalog.
- Never write into `analysis/`, `production_design/`, `treatment/`,
  `storyboard/`, `bible/`, `shotlist/`, `frames/`, or render manifests.

## Failure modes

- No runnable image model: stop before spend and explain which provider/model
  capability is missing.
- Reference count unsupported: reduce the selected Bible references or choose a
  model that supports the exact count.
- Typography remains wrong after revision: keep the clean cover and omit text.
- Repeated visual rejection: revise the subject/model or skip that format.
