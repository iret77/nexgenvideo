# NexGenVideo — UI/UX Concept

This document records the product's interaction principles. The later approved
[native workbench](https://github.com/iret77/nexgenvideo/blob/e3ea08de33ca7cf0b0d7fbe27dc96fb88561e84b/docs/ui/implementation/README.md)
defines the desktop layout and direct-selection behavior. Its five workspaces
replace the earlier Edit/Produce toggle and Media/Project/Agent sidebar proposal.
[RC acceptance](RC_ACCEPTANCE.md) maps the complete function inventory to required
user-visible evidence; documentation and implemented controls alone establish no
release acceptance.

## 1. Positioning

NexGenVideo is a hybrid: a pro NLE (Final Cut / DaVinci Resolve / Premiere) **and** an AI generation
tool (Runway / OpenArt / Photoshop's generative fill). "Final Cut meets OpenArt."

It supports two genuinely different kinds of work:

- **Production** — develop and review the film through the project's pinned workflow. The current
  planning contract includes Script, visual Storyboard/Animatic and Shot Planning before References,
  Frames and rendered Takes. Existing projects retain their exact pack contract until an explicit upgrade.
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
   The object graph is the shared foundation of the layout and the ledger.

Action columns reserve their content's intrinsic width before flexible descriptive columns consume
remaining row space. Column tokens are minimums, not caps on action labels. Compact rows reuse
`WrapLayout` to wrap complete controls and reserve the resulting height; an individual control wider
than the entire pane may wrap its own label within that pane.

## 3. Information architecture (layout)

**Five fixed workspaces: Media, Production, Edit, Postproduction and Export.**
Each arranges the canonical project services for its task. Changing workspace
does not approve a phase, mutate project data or create a second timeline.
Returning to a workspace restores its saved working state. The generic workflow
must work fully without a pack, AI generation or external import; imported
material also remains editable and exportable without a production pipeline.

- **Title bar:** sidebar control and project name on the left, workspaces in the
  center, noninteractive format status and Inspector control on the right. The
  panel controls act independently. Project commands, Undo/Redo and Settings use
  the native menus and shortcuts.
- **Workspace sidebars:** Media organizes the shared library; the other workspaces
  expose their corresponding workflow or source navigation. The agent performs
  bounded tasks and presents structured proposals and decisions in their current
  context. Activity history is supplementary, not an alternate decision surface.
- **Main work area:** Production gives Briefing, Design/Treatment, Script,
  Storyboard/Animatic, Shot Planning, optional Blocking, References, Render-Review
  and Take review the space their artifacts require. Edit and
  Postproduction share the canonical viewer and multitrack timeline. Export
  exposes output settings, jobs, history and file verification.
- **Direct selection and Inspector:** choosing a source shows that source and its
  In/Out controls; choosing a timeline clip shows the film and that clip's instance
  controls. There are no source tabs or Timeline/Source switch. Filtering the
  library does not replace the inspected object. Remembered source position and
  range survive timeline selection. Entity, shot use and clip instance remain
  distinct identities, with explicit navigation between them.
- **References:** entity cards retain reference sheets, image roles, provenance,
  usage and locks. Bible remains the artifact's technical identity; the visible
  References surface does not merge its approval with the separate Frames phase.
- **Status strip:** persistent cost information with details, plus separate AI
  activity and Export indicators. Job details do not obscure required decisions
  or primary actions. Proven costs, provider credits and unknown-price runs stay
  distinct; the budget display is not a spending limit.

Native panes use compact headers, precise dividers and ample image space.
AppTheme supplies consistent typography, spacing, color and control states.
Text size is not reduced to conceal layout problems. Primary actions, disabled
states, keyboard focus and the next workflow step remain clear at supported
window and text sizes.

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
- **The Prompt Generator already exists in the Core** (`Engine/Sources/NexGenEngine/Prompt/`: builder +
  linter + compliance linter + content-block linter; native Swift; format-neutral). Its evolution:
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

## 9. Complete RC scope and evidence

The earlier phased rollout and first-version deferrals do not describe this RC's
scope. The complete [121-group trace](RC_ACCEPTANCE.md#function-trace) preserves
the approved desktop functions, including object use and provenance, Ledger
reconciliation, review/revision, reference editing and remix, structured contextual
tasks, executable model selection, costs and export recovery.

These surfaces share stable object identities, canonical writers, exact source
bindings, the pinned pack contract and the native Undo/Redo and persistence paths.
Text prompt checks and visual frame review remain separate evidence. A visual
Storyboard requires actual images: sketches, uploads or suitable Clay snapshots.
Planned timing comes from the same shot
durations in Storyboard and Animatic, not an independent technical-plan duration.

The candidate is assessed across the complete production journey and independent
generic editing, including failure, cancellation, reopen and recovery. The
[user-understanding criteria](RC_ACCEPTANCE.md#user-understanding-and-visual-acceptance)
cover understandable purpose, professional guidance, consistent state and visual
quality. A source review, screenshot or successful build alone cannot establish
the complete release result. Current runtime evidence is recorded in the trace.
