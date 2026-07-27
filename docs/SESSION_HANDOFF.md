# Session handoff — 2026-07-27

## Objective

Ship one consolidated NexGenVideo 1.0 release candidate. Never build locally. The latest on-device
candidate still showed Story intake first because its separately installed musicvideo 0.0.5 pack
remained the resident runtime despite the corrected app source. The current batch fixes the pack
version/update/project-binding lifecycle and carries the corrected workflow in musicvideo 0.0.6.
It is prepared locally but not yet CI-verified.
Do not run the next CI/DMG build, merge, open a release PR or publish without the owner's explicit
in-the-moment approval.

## Prepared state

- Branch: `codex/release-1.0-rc`
- Base: `origin/main`
- App/changelog version: `1.0.0`
- Musicvideo pack candidate: `0.0.6` with project schema `musicvideo/1.0.0`
- Last green dry-run commit: `38d644efb917fe96ff89fe8943cfac6df344e482`
- Green release workflow: `30138553162`
- The run passed the full test suite, signing, app and pack notarization/stapling, external signed-pack
  loading, DMG verification, Sparkle signing and artifact upload.
- The dry-run artifact `NexGenVideo-1.0.0-dry-run` contains the DMG and both publication names of the
  same musicvideo pack. Stable release, appcast and catalog publication were skipped.
- The first on-device Higgsfield failure was an AuthenticationServices XPC-queue `SIGTRAP`. The
  subsequent candidate passed the callback but then crashed on the main thread in SwiftUI's
  AttributeGraph/`NSHostingView.updateConstraints` after successful authentication.
- The new correction removes the manually retained `ASWebAuthenticationSession`, presentation context
  and unsafe AppKit anchor entirely. SwiftUI's macOS 26 `webAuthenticationSession` environment owns the
  browser lifecycle; one provider snapshot replaces four piecemeal state dictionaries, and the login
  task is cancelled when the page leaves the view tree.
- Browser callback tests cover task cancellation, provider errors, system login cancellation and
  generic failure mapping.
- No local build or test was run; macOS 26 GitHub Actions remains the only verification surface.

The current pipeline and pack-lifecycle correction is uncommitted on `codex/release-1.0-rc`:

- `AGENTS.md` and `CLAUDE.md` now contain the same standalone project rules with no cross-file include;
  `scripts/release_preflight.py` blocks drift between them.
- The locked observable contract is `docs/MUSICVIDEO_START_CONTRACT.md`: Track → optional Lyrics →
  Project Init → approved Audio Analysis → optional existing story/identity/style material → story
  development.
- Musicvideo `project_init` owns only Track and Lyrics. Existing story, characters, locations and
  style references are optional Brief intake and therefore cannot appear before approved analysis.
- Media-library presence is candidate-only. Persisted asset roles keep Lyrics from reappearing as
  Existing story and reject incompatible reuse at submission.
- Gate approval now refreshes and resolves host-owned phase intake before resuming the in-app agent.
  Brief-writing and agent-dialog tools are hard-blocked while Brief intake is unresolved, including
  external MCP use.
- Every in-app start, resume and successful gate transition now includes the packaged instructions
  for the actual current phase; the formerly reference-only phase documents are live agent input.
- Every remaining phase now executes through one current-phase capability contract, typed canonical
  writers/runners, deterministic acceptance gates and cumulative exact-byte lineage. Agent and native
  Shot List edits converge on `PipelineShotlistWriter` before invalidation and lineage capture.
- Intake, analysis, planning writers and gates now share one project-confined track discovery path.
  Analysis interpretation and Shot List writing reject measurements for replaced track bytes before
  mutation; Production Design, Bible and Shot List reject non-image references at write and approval.
- Render proof records semantic source/start/end/reference slots independently of the current model
  catalog. AI-enhanced shots declare one exact project-local `source_path`; Frames excludes imported
  and AI-enhanced footage, and Render rejects a missing, stale or substituted source.
- Chained generated shots have one conditioning truth: the predecessor's exact last frame. They skip
  Frames, use no separate start/reference image, and Render proof binds that predecessor frame.
- Format-pack resolution is fail-closed across open, save, native gate actions and every harness entry.
  Missing, unreadable or mismatched `ngv.json` cannot silently disable the musicvideo contract.
- Intake and gate image types now share `ProjectMediaExtensions`; unsupported broad image formats
  cannot enter through a host card and fail later in the pipeline.
- Legacy optional declines migrate from the former `project_init.*` ids to `brief.*`; role state and
  decline state survive project round-trips and media deletion.
- Release tests cover the visible first Track card with preloaded Media, the analysis frontier, both
  greenfield and existing-story paths, gate-to-intake ordering, role isolation and runtime phase order.
- Pack candidate source and publication manifest now both report `0.0.6`; their minimum app version
  is locked to `1.0.0` by release preflight.
- Static JSON/Python/AppTheme checks pass. Swift/macOS verification remains CI-only.

The release-blocking pack-lifecycle correction is now part of that batch:

- installed versions coexist under `Plugins/<id>/<version>.ngvpack`; legacy flat installs remain
  readable but no longer win over a newer compatible version by default;
- every new or upgraded project pins pack id, exact version and project schema in `ngv.json`;
- catalog/update staging is shared between launch, Home, Settings and new-project creation; the UI
  distinguishes update-available from restart-required with the approved symbols;
- new Music Video projects wait for the catalog check and refuse stale resident code instead of
  binding whichever dylib happened to load first;
- explicit runtime-version selection commits only from `willTerminate`, so cancelling the
  save/restart review changes no persistent selection and cannot strand an open project;
- existing projects keep their exact binding. A version change is explicit; a schema change also
  requires matching bundle metadata and a pack-owned runtime migration;
- migrations clone the Recovery working copy, validate before atomic replacement, keep the saved
  package untouched until Save, survive a crash, and remain cancelable until Save;
- legacy `musicvideo/legacy → musicvideo/1.0.0` is explicitly data-identical; only the binding changes;
- contract-3 hosts accept the additive contract-2 pack ABI, while contract-2 hosts reject contract-3
  packs before load;
- Finder/open-document events now route through the same fail-closed `AppState` pack gate;
- release tests cover stale-resident startup, newest-compatible selection, delayed restart commit,
  project-specific attention, exact binding decode, rollback and data-identical legacy adoption.

The Settings release pass is present but the latest correction is not yet CI-verified:

- all six pages share one hierarchy of page context, sections, cards, rows, status badges and notices;
- General, Format Packs, Providers, Models and Storage show only actionable, accurately named controls;
- Format Packs shows a right-aligned sidebar indicator for available updates and restart-required updates;
- Providers uses honest transport states and an adaptive one-/two-column layout;
- Provider cards now share one header/body geometry in every normal state; error rows alone may expand.
- Agent keeps `Check again` in the Claude status row instead of spending a separate row.
- Help/MCP uses the same window size, sidebar, page header, scroll insets, sections, cards and visible
  control labels as Settings.
- Agent selects exactly one runtime, verifies Claude Code installation and authentication, fixes
  headless permissions to `bypassPermissions`, and restricts built-in Claude tools to `Read`;
- Claude Code makes the loopback MCP bridge mandatory, while API mode retains the user's MCP choice;
- release builds ignore stored external Claude plugin/MCP escape hatches.

The owner explicitly deferred the Finish action strip until after 1.0. It is not part of the release
scope and must remain unchanged for this candidate.

The AppTheme release gate is now implemented:

- visible SwiftUI and AppKit chrome uses `AppTheme` for spacing, dimensions, typography, colors,
  opacity, borders, radii, shadows and animation timing;
- the former global layout, track and trim constants now live under `AppTheme`;
- themed dividers and timeline/keyframe drawing metrics remove remaining system/default styling;
- `scripts/lint_app_theme.py` blocks new hardcoded UI styling before CI, bundle and release work.

The release-blocker implementations for #279–#287 are present:

- #279: complete working-copy recovery and recovery regression coverage.
- #280: persistent project-song identity, awaited/idempotent attach and atomic replacement.
- #281: isolated preview publication and retry-safe stable release transaction.
- #282: off-main content-addressed bulk import, cancellation, rollback, undo and redo.
- #283: fail-closed remote import policy for URLs, redirects, DNS/peer addresses, limits and payloads.
- #284: immutable model revisions plus mandatory SHA-256 verification and cache repair.
- #285: typed control turns that never render app-authored commands as user messages.
- #286: central pre-dispatch monetary ledger and hard budget guard.
- #287: notarized downloadable packs plus quarantined runtime load verification.

The issues stay open until the corrected candidate passes CI and final on-device verification.

## Review and static verification

- Independent reviews found and the batch fixes:
  - import undo deleting bytes without redo;
  - remote temp-file installation assuming a same-volume move;
  - `URLSession` download files not being retained from the delegate callback;
  - cross-thread model-download error state;
  - deferred `set_gate_state` approvals incorrectly dirtying the project;
  - new multi-line comments violating the repository's one-line comment rule.
- A bounded-input Gemini 3.1 Pro High spec audit passed storage/recovery, media import and remote
  security, generation/budget, model integrity, agent/chat/UI and the app design system. Its claimed
  `bundle.sh` initialization defect was rejected after direct source verification: `RESOURCES` is
  assigned before `package_release` can run.
- The owner explicitly approved the locked `docs/PATTERN_FIT_CONTRACT.md` partial-library change on
  2026-07-24. A targeted Gemini 3.1 Pro High re-review then passed the contract, implementation,
  tool projection and tests with no findings.
- Gemini 3.1 Pro High reviewed the OAuth correction, weak-provider lifetime and off-main regression
  test. After receiving the complete actor-isolation context, it approved the final patch with no
  release blocker.
- Gemini 3.1 Pro High separately reviewed the Settings composition with no findings. Its Agent/MCP
  review found one valid lifecycle-hardening opportunity: `AppState` now reconciles MCP for every
  backend-change notification. Claimed missing MCP awaits, missing main-actor isolation and ignored
  allowed tools were rejected against the actual source. The brief Claude-status loading state and
  stale-result fencing were tightened during verification.
- Gemini 3.1 Pro High reviewed the new SwiftUI-owned OAuth flow and UI correction. Two claimed blockers
  were rejected against Apple's macOS 26 API and the actual `.onAppear` implementation. Its valid
  lifecycle, narrow-layout and error-preservation findings were fixed.
- Claude Opus 4.6 Thinking then found no critical release blocker. Its cancellation-notification,
  browser-error-test, duplicate-sidebar-layer and copy-feedback lifecycle findings were fixed.
- Claude Opus, run through the authenticated `claude -p` Subscription/OAuth CLI, reviewed the complete
  pipeline hardening batch. Its valid findings were fixed: the release-trace analysis fixture now
  proves real lineage, chained-render conditioning is internally consistent, image intake and gate
  types share one whitelist, unreadable format settings fail closed, and native/agent Shot List edits
  use one canonical writer.
- The targeted Claude follow-up found three Swift test compile errors and one declaration-integrity
  gap. The fixtures now use valid symbols and MainActor isolation; a separate
  `declaredPluginName` snapshot is captured from the package or an explicitly recovered/host-mutated
  state and independently verifies every mutable working-copy read.
- The same Claude CLI/Subscription follow-up exposed three remaining callers that bypassed that
  guarantee. Rewind now resolves the live pack fail-closed, a move/rename preserves the open
  session's declaration, and every save context must complete the pack gate before writing.
- A final targeted Claude CLI/Subscription pass found the remaining asymmetric mutations and save
  lifecycle edges. Agent and native rewind/set-state now require a genuinely wired pack before
  deriving phase order or writing; direct `write` shares the save gate; failed snapshot handoffs are
  cleared; concrete UUID matching governs declaration preservation. Regression coverage pins valid
  mismatch, unreadable and unwired settings, both retarget branches, direct/main/off-main save
  refusal, byte-identical failed mutations, and the central durable-write hook for rewind.
- Claude's claimed rewind-persistence defect was rejected against the actual dispatcher:
  `.rewind` is an `isDurableWrite`, so `ToolExecutor.execute` marks the working copy dirty before
  execution and calls `onPipelineChanged` after success. A regression assertion now pins that path.
- The renderable release specification `docs/ui/settings-consistency.html` was rendered headlessly and
  visually passed with the compact Agent row, equal provider cards and unified Help/MCP shell.
- Gemini 3.1 Pro High and Claude Opus 4.6 Thinking reviewed the AppTheme gate. Their valid findings
  were fixed: the linter now understands Swift strings/comments and multiline modifiers, native menu
  dividers retain menu semantics, and timeline snap, razor, playhead and badge colors remain distinct.
- `git diff --check` passes.
- The AppTheme source gate passes.
- All workflow YAML parses.
- All 34 workflow `run:` blocks and release shell scripts pass `bash -n`.
- Changelog JSON, app Info.plist and Python sources pass static parsing/syntax checks.
- Branch pushes do not trigger CI; repository workflows run on pull requests or manual dispatch.
- Native Shot List source-mode edits now resolve the working copy's canonical `pipeline/` data root,
  pass through the shared current-phase/predecessor guard, invalidate downstream gates, and capture
  fresh Shot List lineage. Regression coverage rejects both a parallel top-level artifact tree and
  mutation while another pipeline phase is current.

## Remaining gates

1. Obtain the owner's explicit in-the-moment `build now` for one consolidated dry-run.
2. Run the macOS 26 release workflow and verify all workflow, pack-load and release gates.
3. From the notarized DMG, start a new musicvideo project with Track and Lyrics preloaded in Media and
   verify the locked sequence through approved Audio Analysis into greenfield and existing-story Brief.
4. Only after that succeeds: close verified blockers and prepare the release PR.
5. Production merge and publication remain separate explicit actions.

## Release workflow

The stable pack and badge bytes upload before the final catalog promotion. Pending catalog,
transaction metadata, catalog/artifact hashes and a completion marker make publication resumable
without another macOS allocation. Resume now fetches the release branch and checks out its head
detached before committing the appcast, preventing stale Linux-gate state from causing a
non-fast-forward publication failure.
