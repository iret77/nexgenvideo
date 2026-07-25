# Session handoff — 2026-07-25

## Objective

Ship one consolidated NexGenVideo 1.0 release candidate. Never build locally. The latest successful
dry-run was tested on-device and exposed a second Higgsfield OAuth crash plus three Settings/Help
composition defects; the corrective candidate is prepared.
Do not run the next CI/DMG build, merge, open a release PR or publish without the owner's explicit
in-the-moment approval.

## Prepared state

- Branch: `codex/release-1.0-rc`
- Base: `origin/main`
- App/changelog version: `1.0.0`
- Musicvideo pack candidate: `0.0.5` (stable catalog currently `0.0.4`)
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
- The renderable release specification `docs/ui/settings-consistency.html` was rendered headlessly and
  visually passed with the compact Agent row, equal provider cards and unified Help/MCP shell.
- Gemini 3.1 Pro High and Claude Opus 4.6 Thinking reviewed the AppTheme gate. Their valid findings
  were fixed: the linter now understands Swift strings/comments and multiline modifiers, native menu
  dividers retain menu semantics, and timeline snap, razor, playhead and badge colors remain distinct.
- `git diff --check` passes.
- The AppTheme source gate passes.
- All workflow YAML parses.
- All 31 workflow `run:` blocks and release shell scripts pass `bash -n`.
- Changelog JSON, app Info.plist and Python sources pass static parsing/syntax checks.
- Branch pushes do not trigger CI; repository workflows run on pull requests or manual dispatch.

## Remaining gates

1. Obtain the owner's explicit in-the-moment `build now` for a new dry-run containing the corrected
   SwiftUI-owned OAuth flow and Settings/Help consistency pass.
2. Run the macOS 26 release workflow and verify the browser-callback tests plus all existing gates.
3. Test Higgsfield sign-in and the revised Settings pages from the new notarized DMG on-device.
4. Only after that succeeds: close verified blockers and prepare the release PR.
5. Production merge and publication remain separate explicit actions.

## Release workflow

The stable pack and badge bytes upload before the final catalog promotion. Pending catalog,
transaction metadata, catalog/artifact hashes and a completion marker make publication resumable
without another macOS allocation. Resume now fetches the release branch and checks out its head
detached before committing the appcast, preventing stale Linux-gate state from causing a
non-fast-forward publication failure.
