# NexGenVideo

AI-native macOS video editor. Swift 6.2, SwiftUI + AppKit, AVFoundation. macOS 26 only, arm64 only. Non-sandboxed Developer ID app.

## Concept — read first

The authoritative product vision and target architecture live in [docs/CONCEPT.md](docs/CONCEPT.md):
autonomous NexGenVideo (no upstream/palmier-io services), generation providers (Runway, fal.ai,
OpenArt, Higgsfield, ElevenLabs, …) bound via BYO API keys, Claude orchestrating via API key *or*
`claude -p`, format-packs like `musicvideo` driving in-app workflows. Read it before planning any
architecture, generation/provider, or de-Palmier-ization work — it supersedes the "Palmier-Integration"
section of `musicvideo/docs/v1-studio-plan.md`.

## Build

```bash
swift build
swift run
```

## Code style

- Keep comments minimal. Only write one when the *why* is non-obvious. Don't restate what the code does, don't narrate the current change, don't leave `// removed X` breadcrumbs. One short line max — no multi-line comment blocks or paragraph docstrings.

## Design System

All UI styling MUST use `AppTheme` constants from `Sources/NexGenVideo/UI/AppTheme.swift`. Never use hardcoded numeric values for:

- **Spacing/padding** → `AppTheme.Spacing.*` (xxs through xxl)
- **Font sizes** → `AppTheme.FontSize.*` (xxs through display)
- **Font weights** → `AppTheme.FontWeight.*` (regular, medium, semibold, bold)
- **Corner radii** → `AppTheme.Radius.*` (xs through xl)
- **Border widths** → `AppTheme.BorderWidth.*` (hairline, thin, medium, thick)
- **Opacity** → `AppTheme.Opacity.*` (subtle, faint, muted, medium, strong, prominent)
- **Icon frame sizes** → `AppTheme.IconSize.*` (xs through xl)
- **Shadows** → `AppTheme.Shadow.*` (sm, md, lg) via `.shadow(AppTheme.Shadow.md)`
- **Colors** → `AppTheme.Text.*`, `AppTheme.Border.*`, `AppTheme.Background.*`
- **Animation durations** → `AppTheme.Anim.*`

If a needed value doesn't exist in AppTheme, add it there first — don't hardcode it.

## Drag and drop

SwiftUI `.onDrop` on a parent view shadows every drop target inside its layout area on macOS 26 — even AppKit `NSDraggingDestination` children registered directly with the window. Inner `.onDrop` modifiers silently never fire while a parent `.onDrop` is active.

Rule: **any drop target that spans an area containing other drop targets must use native AppKit** (see `MediaPanelDropArea` in `Sources/NexGenVideo/MediaPanel/`). Inner / leaf drops can stay SwiftUI `.onDrop`. Do not stack SwiftUI `.onDrop` modifiers in parent/child layouts.

## Voice

NexGenVideo speaks like a quietly capable native Mac app for filmmakers: direct, technical, calm, and 
confident. Prefer Apple HIG-style terseness over warmth. Never chatty or cute. Never marketing. When the
product needs to ask for action, lead with the action verb; when it reports state, name the thing.

## Hard rules

Owner decisions, binding. Most of these are here because ignoring them already cost a broken
release or a wasted CI cycle.

### Building and releasing

- **Never build locally.** CI (macos-26) is the only verification surface.
- **Never merge to `main` or dispatch `release.yml` without the owner's explicit, in-the-moment
  "build now".** Stage the work, hold, ask. Concept approval is not build approval.
- **One batch, one release.** Collect fixes and release once. Never propose an intermediate or
  partial release, and never split scope that was agreed as a single batch.
- `gh` resolves to the upstream `palmier-io/palmier-pro` remote. **Always pass
  `--repo iret77/nexgenvideo`.**

### The plugin pack — two ways to ship a crash CI cannot catch

- **New stored properties go ONLY at the end of `EngineRegistry`** (and of any class the pack sees).
  The `.ngvpack` is compiled separately and bakes in ivar offsets; inserting a property in the middle
  shifts everything below it and the shipped pack crashes on launch. CI builds host and pack from one
  tree, so it will never reproduce this.
- **A pack resolves the host engine via an `@executable_path/../Frameworks` rpath, and the load must
  be verified by actually loading it** (`NGV_SELFTEST_PACK`, see `Sources/NexGenVideo/Plugins/PackSelfTest.swift`).
  Static `otool` / `nm` checks have twice passed while the shipped pack failed with "Damaged pack /
  entry point not found".
- **Plugins are real, loadable `.ngvpack` bundles.** Compiled-in is not a shippable state.

### Agent and chat surface

- **Never render an app-authored or auto-generated message as a user turn.** Seed it with
  `hidden: true` and let the agent answer — see `AgentService.send(text:mentions:hidden:)`.
- **Never show a control that doesn't do what it says.**
- **No raw prompt reaches a content model**, from the user or the agent. Everything pre-compiles
  through the prompt engine; raw is a pro escape hatch only.
- **Constrain agent output with schema-validated tool calls** (enums, `required`,
  `additionalProperties: false`) — never with prompt discipline alone.
- **Gate refusals are agent-facing.** They name tools and artifact paths; don't put them in front of
  the user unchanged.

### Providers and models

- **Provider-agnostic.** Work with whatever keys the user has. Do not extend the upstream's
  fal.ai-centric assumptions to new providers — that is exactly how the Runway integration went wrong.
- **The catalog shows only what the user can actually run:** (enabled providers) ∩ (what they really
  offer). Never list a model the user can't execute.
- **A provider key field in Settings requires a working client in the same change.** Otherwise remove
  the field.
- **Verify API facts with a live call.** Research has been wrong every single time; model lists are
  free. A 400 proves only the request envelope, never availability. Never probe a *generation* with a
  deliberately invalid field — an invalid value has been accepted and billed.
- **Never propose the Anthropic API-key mode as an alternative** to the embedded `claude -p` runtime.
  It stays in the code but is not an option for this project. Fix the embedded runtime instead.

### Working in this repo

- **Don't run `git blame`.** Every line here was written by an agent, including the "upstream"
  Palmier commits. Blame can only ever answer "an agent" — it costs tokens and reads as distancing.
  Own the defect, don't date it.
- **Docs and issues in this repo are agent-written.** An "owner decision" quoted in an issue is an
  agent citing itself — never cite it back as a mandate. `docs/CONCEPT.md` is orienting context, not
  a mandate; apply it with judgement, and surface genuine conflicts as a decision point.
- **Specs that are locked stay locked:** `docs/PROJECT_STORAGE.md`, `docs/PATTERN_FIT_CONTRACT.md`,
  `docs/PLUGIN_STANDARD.md`. Deviating requires stopping and asking, not a quiet reinterpretation.
- **No quick wins.** Partial fixes and shortcuts are not robust enough to ship; implement the
  complete, correct solution.
- The wordmark is **NexGenVideo**, one word — never "NexGen Video" in any shown copy.

