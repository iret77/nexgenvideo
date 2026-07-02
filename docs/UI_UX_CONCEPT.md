# NexGenVideo — UI/UX Concept (North Star)

> The single reference for how the interface is organized and how the user works with the AI.
> Derived from a design review with two independent models (Claude + Codex/gpt-5.5). Layout first,
> interaction substance on top. This document defines intent; individual PRs implement against it.

## 1. Positioning

NexGenVideo is a hybrid: a pro NLE (Final Cut / DaVinci Resolve / Premiere) **and** an AI generation
tool (Runway / OpenArt / Photoshop's generative fill). "Final Cut meets OpenArt."

It supports two genuinely different kinds of work:

- **Produce** — let AI *create* the video through a structured pipeline (brief → treatment → storyboard
  → bible → shotlist → sanity → frames → render). The production cockpit is the work surface.
- **Edit** — refine the resulting video on a multi-track timeline. Classic NLE.

## 2. First principles (everything derives from these)

1. **One canonical instance per element.** Exactly one Timeline, one Inspector, one Agent, one Bible,
   one Pipeline — identical interaction everywhere. A mode may *hide* or *resize* an element; it must
   **never** present a second variant of it. (We explicitly reject Resolve's Cut-vs-Edit near-duplicate
   timelines.) **Hide, don't duplicate. Technical test:** canonical = *one* component reading *one*
   state, rendered at a different density/size; a variant = a second implementation that can diverge in
   behavior. If two surfaces can behave differently, they are variants — forbidden.
2. **Chat is not the interface spine — but prose is primary *material*.** Reject the reflexive
   "ChatGPT-in-a-Clippy-costume" pattern of a persistent chat window bolted onto everything. Yet in AI
   video, language *is* primary material for intent (prompts, creative direction) — it just isn't the
   primary *navigation* model. **Scope is the antidote to Clippy, not banishing chat:** any prose
   invocation is summoned and shows its scope ("3 shots · current frame · whole treatment · 01:12–01:28").
3. **Direct manipulation is the default; prose is earned.** For each action ask: does language express
   this better than a click? If not, it is a click.
4. **Creative memory lives on the artifact, visibly.** The hard problem is not where the prompt box
   goes — it is *how the app remembers what the director is trying to protect.* Decisions, locks, and
   rejected paths attach to objects, not to a chat transcript.
5. **Artifacts survive into editing.** Bible, shotlist, sanity, and cost are not pre-production throwaway:
   sanity findings point to timeline ranges; bible entities show where they're used; shotlist rows map
   to clips. This continuity is the product's advantage.
6. **Deliberate compute, not chance.** Which model and how much thinking each task gets is assigned by
   task class, never left to a single default.
7. **One object graph underneath everything.** Every panel, breadcrumb, lock, and prose command
   resolves to the *same* entities: `Character/Ensemble/Prop/Location/Look`, a `Shot`, a Shot's **use**
   of an entity, and a **clip instance** on a track — each with a stable ID. Selection, the Inspector,
   Bible usage-maps, sanity→timeline links, and the Intent Ledger are all *views* over this one graph.
   This is not a UI detail; it is the foundation the layout (Phase A) and the ledger (Phase C) both
   stand on. Build it first (Phase 0).

## 3. Information architecture (layout)

**Focus toggle: `Edit` ↔ `Produce`.** A workspace *focus*, not a page — "the same room rearranged,"
never a different app. Same panels, same edges, same shortcuts, same selection behavior in both. It
only shows/hides/resizes canonical panels. **No panel is ever locked away by the focus:** every
canonical panel has a persistent reveal path (a `Project` control opens the cockpit in either focus).
Default: new/empty project → Produce; a project with a full timeline → Edit.

- **Left: a single tabbed sidebar — `Media / Project / Agent`.** Fixes the "too many columns / too
  narrow" problem. The **Agent is summonable, not a permanent full-height column** in Edit; it can be a
  persistent panel in Produce. When summoned it knows the current selection/timeline context.
  **What the Agent owns:** open-ended, cross-cutting requests that fit no field or button ("organize my
  media", "make the whole thing more melancholic"). It is a **controller over the cockpit, not the
  cockpit itself** — every decision it makes lands in a structured artifact (ledger entry, gate state,
  bible edit), never only in the transcript. It does **not** own per-artifact prose (that's contextual
  fields) or structured decisions (those are buttons/boards).
- **Center: Preview over Timeline.** One canonical Timeline — in Produce it *collapses* (shows
  accumulating rendered shot blocks/status, **no** trim handles/waveforms) and expands into the *same*
  timeline; it is never a second "produce timeline."
- **Right: Inspector = the current selection, only.** It inspects **objects** (clip, asset, generated
  shot, Bible entity, reference) — never phases/pipeline-rows/budget/sanity-reports (those are panels).
  A **breadcrumb** disambiguates a strict object model: `Character: Mara` ≠ `Shot 014 use of Mara` ≠
  `Clip on V2`. **Selection semantics (one rule, no ambiguity):** there is exactly *one* app-global
  **inspected object** at a time, and it alone drives the Inspector; each panel keeps its own **local
  selection** (highlight/multi-select for its own actions) but only *promotes* to the global inspected
  object on an explicit focus (click into the Inspector / single-click a card). Clicking a Bible
  character *used* in a shot that produced a clip inspects the **entity**, not the clip — to inspect the
  clip you select it on the timeline. The breadcrumb always shows which of the three it is.
- **Cockpit panels — canonical, reachable in both focuses:** `Bible`, `Pipeline`, `Shotlist`, `Sanity`,
  `Cost`. **Bible is a mood-board** of entity cards (Characters/Ensembles/Props/Locations/Look) with
  reference sheets — it needs surface area; it must never collapse into a list (that would be a variant).
- **Status strip = the collapsed Pipeline** (phase · gate state · budget · one blocking issue). It is
  the *same* component in a compact density; clicking expands into the full Pipeline — not a second
  dashboard. Budget must be **actionable** ("can I afford the next action?"), never decorative.

## 4. Interaction model — a ladder chosen per task

1. **Direct manipulation** (default; structure, navigation, decisions; textless): boards/tables/galleries
   — reorder, inline-edit, review & accept/reject/pick, approve gates, drag-to-timeline.
2. **Structured decision + cheap reason.** Review is not just accept/reject: attach a lightweight
   **reason chip** (`Continuity · Performance · Style · Composition · Prompt-Drift · Technical`) so a
   regeneration isn't a lottery. Provide a **combine/remix** path for "none of the four are right"
   ("composition of 2 + lighting of 4, keep wardrobe").
3. **Contextual prose *command*** (Photoshop generative-fill): a one-shot prompt **bound to a selection**
   ("make the sky overcast" on this frame). Not a permanent mini-chat under every card.
4. **Scoped focused *thread*** — when intent *accumulates* ("more like the 2nd but warmer; keep her
   jacket; apply that restraint to the next five shots"). A summoned, scope-visible, temporary thread.
   This is where conversation earns its place.

Supporting patterns:
- **Assisted prose:** the AI pre-drafts a prose field (context-grounded); the user edits or replaces it.
  A suggestion, never a fait accompli. This is the front of the pipeline.
- **Gates are multi-state:** `Approve · Approve with notes · Needs revision · Regenerate` (not binary).
- **Sanity findings are actionable:** `Apply fix · Show affected shots · Ignore for project · Convert to
  rule` — and each points to the affected shots/timeline ranges.

## 5. The Intent Ledger + Prompt Generator (the differentiator)

The mechanism that turns messy, evolving prose into structured information the video model can actually
use — and that makes the agent feel *reliable*. **Prose is a process:** the user rarely knows the
destination up front; the workflow must actively support that, not treat it as a bug.

- **The object is the unit of memory** (character, shot, look, film). Each carries **attributes**, and
  each attribute has three layers:
  - **tag** — the short, always-visible handle on the object ("Wardrobe: faded red canvas jacket 🔒").
  - **directive** — the clean, model-ready phrasing that actually goes into the prompt (click the tag).
  - **source** — the user's original words + provenance (which brainstorm, when), kept as history.
- **The loop:** prose (assisted or free) → **Distiller** (a small/fast model that *reconciles* into the
  ledger — updates existing attributes, doesn't just append, so no "tag soup" or contradictory tags) →
  **Prompt Generator** (Core; composes the model prompt from the ledger + shot + look) →
  **prompt-compliance lint** → **Generation** → **frame-audit** → **Review with reasons** → Distiller
  updates the ledger.
- **Two distinct gates — do not conflate them.** *Prompt-compliance linting* is **pre-generation, on
  text**: does the assembled prompt actually carry every locked attribute, and is it internally
  consistent (no contradiction, no drift from the ledger)? Cheap, deterministic, blocks a bad request
  before spending money. *Frame-audit* is **post-generation, on pixels**: does the *rendered* image/clip
  actually show the locked jacket, the right face, the agreed look? This is a vision check and can fail
  even when the prompt was perfect. Each has its own reason-chip and its own place in Review; a green
  prompt lint never implies a green frame.
- **Locks are visible facts.** "Keep her red jacket" becomes a visible lock on the character/shot that
  the prompt generator *must* honor and the compliance linter *checks* — not something buried in chat
  memory. Feedback resolves to either **a rule** (a locked attribute, forever) or **a one-off**
  (a throwaway regenerate reason); the user/distiller chooses.
- **The Prompt Generator already exists in the Core** (`engine/nexgen_engine/render/prompt/`: builder +
  linter + compliance_linter + content_block_linter; extracted in #56; format-neutral). Its evolution:
  it moves from reading ad-hoc Bible fields to **composing from the Intent Ledger and enforcing its
  locks.** Distiller (prose → ledger) and Prompt Generator (ledger → model prompt) are two halves of one
  loop and must stay tightly coupled.
- **Agent memory is artifact-aware, not transcript-aware:** accepted/rejected versions, reject reasons,
  prompt lineage, references used, locked attributes, continuity constraints — all on the object. Any
  prose invocation is then grounded without a permanent chat.

## 6. Model routing — deliberate compute

- **Tiers, not model IDs:** `Fast / Medium / Deep` = the *latest* Haiku / Sonnet / Opus (and the
  equivalent Codex/GPT tiers). No code references a fixed ID.
- **Dynamic "latest":** a refreshable **model manifest** (the app ships defaults and can update them, à
  la the self-hosted search model) plus provider `-latest` aliases / model-list API — new model
  generations are adopted **without a code change.**
- **Effort by task class** (the anti-"overthinking" rule): **low/no thinking** for clear, direct,
  deterministic tasks (distillation, prompt assembly, classification) — high effort there makes output
  *worse*; **high/extra** for planning, conception, interpretation, ambiguity.
- **Routing = fixed floor + reactive escalation, no meta-classifier:**
  1. A **fixed floor** per task class (Distiller Fast+low · Assembly Medium+low · Treatment/interpretation
     Deep+high). Predictable, cheap, covers ~90%.
  2. **Optimistic cheap-first; escalate the *retry* one tier up only on a concrete gate failure** —
     compliance linter, schema validation, sanity check, or user reject (signals we already produce).
     Bounded (max tier, one step) and logged. No separate "how hard is this?" judgment call.
  3. **On detected ambiguity/conflict, ask — don't guess.** If the Distiller finds intent
     underspecified or contradicting a lock, surface one targeted clarification rather than silently
     escalating a guess. Cheaper, more reliable, and it honors "prose is a process."
  - No de-escalation (that would reintroduce a guess with downside); a heavy phase simply has a high floor.
  - Dispatch via `claude -p --model <resolved> --<effort>` (stays on the subscription) or the API.
- The router is a **Core service**; the plugin/engine contract declares each action's task class.

## 7. The plugin UI contract (Stufe 2)

Each phase/artifact declares its **defaults and capabilities** — is a field a `choice` (picker),
`prose`, or a `review` surface; its task class (→ model floor); which cockpit object it reads/writes —
**not rigid modes.** A phase may start as REVIEW, become PROSE when nothing works, then DIRECT once a
direction is chosen. NexGenVideo renders these natively; the scoped agent thread is the fallback for
open-ended intent.

## 8. Steal / avoid (market leaders)

- **Photoshop generative fill** — the model for bounded AI actions: selection creates scope, the prompt
  is local, results return as visual alternatives. Copy aggressively for frame/clip edits.
- **Premiere's AI** — AI as embedded timeline *utility* (Generative Extend, AI search, captions, media
  intelligence), not a personality. Copy for timeline gaps, b-roll search, caption variants, cleanup.
- **Final Cut** — spatial stability and selection-driven clarity; the "main thing is obvious."
- **Resolve** — task-focused workspaces are right; its similar-but-different timelines are wrong. Copy the
  confidence of focused workspaces; never duplicate a tool.
- **Runway** — proves prose stays core to generation (prompt, references, camera, style, consistency);
  contain language inside scoped generation modules, don't pretend it's secondary.
- **Canva 2.0** — the warning: a unified conversational orchestration layer as the center of gravity.
  Copy object-specific intelligence; never turn the editor into a chatbot command line.

## 9. Implementation sequencing

The **object model is the hidden foundation** — the layout, Inspector, breadcrumb, ledger, sanity
links, and prompt generation all sit on it. It comes *first*, not in Phase C.

- **Phase 0 — Foundations (before any UI is "real"):**
  - **The object graph:** entities (Character/Ensemble/Prop/Location/Look), `Shot`, a Shot's **use** of
    an entity, and a **clip instance** on the timeline — each with a stable ID and explicit
    relationships. Migrate the current Bible fields into it.
  - **Selection semantics:** exactly one app-global *inspected object* drives the Inspector; panels keep
    their own local selection/actions. A panel row (a sanity finding, a pipeline phase) acts/navigates
    locally — it becomes the inspected object only if it *is* an object.
  - A **minimal model-router contract** and a **minimal plugin UI contract** (what artifacts exist; is a
    surface choice/prose/review; the task class) — because Phase A/B would otherwise hardcode the first
    format pack into supposedly generic UI.
- **Phase A — Layout on the model (fixes the current screenshots, testable):** Inspector = the inspected
  object only + breadcrumb; remove the stop-gap Selection/Project toggle; left tabbed sidebar
  `Media / Project / Agent` with a summonable Agent; cockpit panels reachable in both focuses;
  **Bible = entity cards + references + selection** (not full sheet editing yet); status strip =
  collapsed Pipeline; `Edit ↔ Produce` focus presets, with the Produce timeline explicitly disabling
  trim/edit commands.
- **Phase B — Interaction substance (trimmed to V1):** review = accept / regenerate-with-note (+ a reason
  chip); **contextual one-shot prose commands** (Photoshop-style); assisted-prose drafts; sanity
  findings that navigate to the affected shots.
- **Phase C — The differentiator:** the Intent Ledger (object attributes tag/directive/source/locked,
  with reconcile + undo); the Distiller; the Prompt Generator composes from the ledger; **prompt-
  compliance linting AND a separate frame audit** (visual verification that a locked fact actually
  held — prompt text alone cannot prove the red jacket stayed red); artifact → timeline links.
- **Phase D — Dynamic infra:** the dynamic latest-model manifest + full escalation policy; the richer
  plugin capability contract.

**Deferred past the first useful version** (to ship faster): combine/remix, scoped multi-turn threads,
the multi-state gate machine, actionable global Cost (V1 shows estimated next-action cost only where the
data is real), Bible usage-maps + reference-sheet editing, automatic ledger reconciliation from every
rejection, dynamic per-pack capability rendering, and the dynamic latest-model manifest.

Builds run on CI only, on the user's explicit request — one signed DMG per deliberate batch.
