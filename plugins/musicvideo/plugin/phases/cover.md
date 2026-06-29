# Phase C — Cover Images (optional, per platform format)

> **Orchestrator instruction (main-session context).** Never spawn this
> phase as a sub-agent — `AskUserQuestion` is a main-session UI tool.
> Converse with the user **in the user's language**; everything written
> into provider-facing fields is **English**.

All paths below are relative to the **project data root**.

## Goal

Produce album/cover artwork per selected platform format: one clean
image (mandatory) plus optionally a second variant with artist + title.
Every cover is a `generateImage` call whose prompt the agent composes
from the subject hint + bible refs + format-specific layout.

| Format | Aspect | Use |
|---|---|---|
| `square` | 1:1 | Spotify, Apple Music, Bandcamp, Instagram feed post |
| `landscape` | 16:9 | YouTube thumbnail, Facebook cover |
| `portrait` | 9:16 | TikTok, Instagram Reels/Story, YouTube Shorts |

## Inputs

- Gate `bible` approved (K5; check via `get_project_state(project_dir)`).
  The phase can run any time after that — it blocks **no** render. A
  sensible last step before R2 or in parallel with rendering.
- Bible sheets as optional generation refs (e.g.
  `bible/main_character/front.png`, `bible/main_location/wide.png`),
  read via `get_bible(project_dir)`.
- A text-capable image model when a text variant is wanted (confirm via
  `list_models` with `type="image"`).

## Outputs & gate

Per format under `cover/`:

- `<format>_clean.png` — without text (mandatory variant)
- `<format>_text.png` — optional, with artist + title

Gate: after the user approves the produced covers,
`approve_gate(project_dir, "cover")`. The phase is optional and blocks
no render — if the user skips it, leave the gate unset.

## Steps

### C1 — Which formats?

`AskUserQuestion`: "Which platforms do you need covers for?"
Multi-select options:

- "Streaming standard (square, 1:1) — Spotify, Apple Music, IG post"
- "YouTube thumbnail (landscape, 16:9)"
- "TikTok / Reels / Shorts (portrait, 9:16)"

The selected formats are processed one after another through C2–C5.

### C2 — Per format: cover briefing

Briefly clarify with the user for the current format:

1. **Subject hint** (`AskUserQuestion`): "What does the cover show?"
   - "Main character (central, from the bible)"
   - "Location motif (mood image, from the bible)"
   - "Abstract style image"
   - "Other — user free text"

2. **Model** (`AskUserQuestion`): present the host's registered image
   models (resolve via `list_models` with `type="image"`). Offer a
   multi-ref high-consistency model (good for character/location
   motifs), a text-capable model (pick this if a text variant comes
   later), and a photoreal model as the three concrete options.

**Bake the format-specific hint into the subject hint:**

- `landscape`: the image is meant as a **YouTube thumbnail** — subject
  slightly off-center, plenty of negative space for a title overlay,
  readable at 320px width.
- `portrait`: the image is for **TikTok/Reels** — compose vertically,
  main motif in the upper or middle third, let the lower third breathe
  (the app UI with username, caption, like button overlays the lower
  15% + the right edge).

### C3 — Generate the clean cover

Compose the cover prompt from the subject hint + the format layout note
+ `bible.look.style` (verbatim). For the reference images: import the
chosen bible sheets via `import_media(source={path:...})` and pass the
mediaRefs in `generateImage(..., referenceMediaRefs=[...])`. Confirm
generation availability first (`get_timeline` `canGenerate`).

```
generateImage(
  prompt="<concrete motif, format layout, bible.look.style verbatim>",
  model="<chosen image model>",
  aspectRatio="1:1 | 16:9 | 9:16 per the format",
  referenceMediaRefs=[<imported bible refs>],
)
```

When the asset is ready, bring it into the project as
`cover/<format>_clean.png`.

**Show the output** via the `Read` tool (`cover/<format>_clean.png`) and
**get approval**:

- `approve` / `revise` (different subject hint / model) / `skip` (the
  format is skipped).

### C4 — Offer the text variant

`AskUserQuestion`: "Render a second variant with artist + title?"

- `yes` → C5
- `no` → done with this format; next format or end of phase.

### C5 — Artist + title + renderer

**Mandatory explicit question** (never derive from the project name or
the brief):

`AskUserQuestion` form with:

- **Artist** (required, free text)
- **Title** (required, free text)
- **Renderer**:
  - "Text-capable image model (the model generates the cover with
    integrated typography — the text feels like part of the design)"
  - "Deterministic overlay (100% correct letters, but the text looks
    pasted on)"

Background: most image models do not render text reliably (wrong
letters, smeared glyphs). A text-capable image model is the path for
covers-with-text; a deterministic overlay is the safety variant when the
user prioritizes correctness over aesthetics.

**With the text-capable image model:** fold the artist + title into the
`generateImage` prompt — "integrate the title '<title>' and artist
'<artist>' as part of the cover typography" — anchored on the clean
cover (`cover/<format>_clean.png`) imported as a `referenceMediaRefs`
entry so the composition carries over. Bring the result in as
`cover/<format>_text.png`.

**With the deterministic overlay:** additionally ask:

- Layout (`bottom` / `top` / `center`)
- Font (`Helvetica` / `Avenir` / `Avenir Condensed`)
- Color (`auto` / `white` / `black`) — default `auto`

Then overlay the text onto `cover/<format>_clean.png` locally (e.g.
`Bash` with an image tool — Pillow / ImageMagick) and write
`cover/<format>_text.png`. This path makes no provider call and is
exact.

**Show the output** and get approval. On `revise`:

- Switch the renderer (text-capable model ↔ deterministic overlay)
- Different layout / font / color (overlay)
- Different artist/title wording (with another explicit follow-up
  question)

### C6 — Loop or end

If the user selected multiple formats in C1: continue with the next
format from C2. When all are done: display the produced covers inline
via `Read`, get final user approval, and set the gate
`approve_gate(project_dir, "cover")`.

## Mandatory rules

- **Never** derive the artist or title from the project name,
  `target_platform`, treatment texts, or the brief subject. **Always**
  ask the user explicitly. A wrong artist credit in a persisted cover
  artifact is 3× worse than a short question.
- The mandatory variant per format is `<format>_clean.png`. The text
  variant is additive; the original is kept.
- The aspect is **not** derived from the brief — `format` determines
  everything. The brief aspect is for the video render, not for covers.
- Cover generation runs through the host's `nexgen` `generateImage`
  tool; bible refs are imported via `import_media` first, then passed as
  `referenceMediaRefs`. Provider costs accrue per attempt — tell the
  user the estimate before the call (`estimate_cost` shows the project
  budget picture).
- Never guess generation availability; check `get_timeline`
  (`canGenerate`) / `list_models`.

## Failure modes & escalation

- **Generation unavailable** (`canGenerate: false`, or the chosen model
  missing from `list_models`): inform the user and either have the model
  / key bound in the host, or fall back to the deterministic overlay for
  the text variant (it needs no provider). Keys are bound in the host
  (Keychain / Settings), never a shell command.
- **Text comes out garbled** from the image model: switch to the
  deterministic overlay path.
- **Repeated rejection in review:** revise loop — switch model or
  renderer, adjust the subject hint, change layout/font/color (overlay),
  or `skip` the format.
