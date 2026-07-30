# Session handoff — 2026-07-28

## Objective

Finish one consolidated NexGenVideo 1.0 correction after on-device testing exposed six coupled
release blockers:

1. content-addressed Media storage hashes reached visible Track intake and agent context;
2. the agent inferred German instead of defaulting to the app UI language;
3. Audio Analysis had no trustworthy user-visible progress and remained approvable while running;
4. the embedded Claude MCP transport dropped the long `run_phase("analysis")` response;
5. repeatable prepared-character intake did not identify the current item, exposed an active-looking
   incomplete Attach action, and offered no explicit Skip/Done exit;
6. the agent transcript entered an unbounded SwiftUI main-thread layout cycle while the Brief intake
   opened after Audio Analysis.

Never build or test locally. GitHub Actions on `macos-26` is the only Swift/build verification
surface. Do not dispatch CI, merge, publish, or build a DMG without the owner's explicit
in-the-moment `build now`.

## Working state

- Branch: `codex/transcript-hang-watchdog`
- The branch starts from the pipeline hardening content merged through PRs #289 and #290.
- Release candidate: app `1.0.1`, source `CFBundleVersion` `68`; the release workflow will emit
  build `69`. The failing on-device DMG was app `1.0.0`, build `68`.
- Musicvideo pack candidate: `0.0.10`, project schema `musicvideo/1.0.0`
- Engine binary contract: current `4`, minimum compatible `2`
- The commit containing this handoff is the one consolidated correction; read its live CI and release
  state from GitHub rather than inferring it from this document.

## Binding product contracts

- Startup order remains
  `Track → optional Lyrics → Project Init → approved Audio Analysis → optional existing creative material → story development`.
- Media import is candidate discovery, not workflow assignment.
- The original imported filename is durable metadata and is used in UI, agent context, and workflow
  destinations. A content hash is storage identity only.
- The agent defaults to the actual app interface localization. OS locale, pack prose, filenames,
  project content, and lyrics cannot change it. Only an explicit user request changes conversation
  language.
- A project has exactly one active phase job. Same-phase calls and MCP reconnect retries join it;
  a different phase is refused without execution.
- Runner-emitted deterministic stage boundaries are the only progress truth; there is no invented
  percentage or ETA.
- Approval, gate-state mutation, and rewind are impossible while a phase job is running. Approval
  appears only after the canonical artifact and lineage pass the shared structural gate.
- Repeatable optional intake names and numbers the current item. Attach stays disabled until the item
  is complete; the first empty item has Skip, and subsequent empty items have Done.
- Transcript layout never feeds animated/inserting/resizing secondary content back from scroll
  geometry. User scroll intent comes from scroll phases, while agent updates follow the true transcript
  tail unless the user deliberately scrolled away.

The locked source documents are:

- `docs/MUSICVIDEO_START_CONTRACT.md`
- `docs/PIPELINE_AGENT_HARNESS.md`
- `docs/ui/pipeline-phase-progress.html`
- `docs/ui/repeatable-intake.html`

## Implemented in the working tree

### Original filenames

- `MediaManifest` v5 persists `originalFilename`; legacy projects derive a readable fallback from the
  media name without ever exposing a 64-character storage hash.
- Finder, folder, URL, bytes, relink, dialog, mention, `get_media`, transcript-error, and Track
  assignment paths carry the user-facing filename.
- Track assignment copies the song into `audio/` under the sanitized original filename while the Media
  library keeps its content-addressed durable copy.
- Agent context explicitly distinguishes original filename metadata from the opaque backing path.
- Round-trip, legacy, dialog, mention, copy, import, relink, and Track-assignment regressions are added.

### Language

- `AgentInterfaceLanguage` resolves from `Bundle.main.preferredLocalizations`, falling back to the
  development localization.
- Both embedded Claude Subscription/CLI and Anthropic API-key mode receive the same hard language
  rule through `AgentInstructions.serverInstructions`.
- Pack phase documents defer to the host-provided interface language and permit a switch only after an
  explicit user request.
- Fixed German host-authored artifact labels were converted to the current English UI language.

### MCP and phase execution

- The former adapter incorrectly created one `Server`/`StatelessHTTPServerTransport` per TCP
  connection and also advertised a fabricated GET SSE stream unrelated to that transport.
- The adapter uses official stateless POST/JSON semantics and lets GET return the SDK-defined 405.
  One SDK server/transport survives all HTTP connections within a logical client session. A new
  `initialize` rotates to a fresh SDK session because the SDK rejects reinitialization; retired
  sessions stay alive until their in-flight calls settle.
- Rotation ownership and listener generations prevent an old async resume from unlocking or reviving
  a newer lifecycle. A post-start listener failure reaches `MCPService`, clears its running state and
  exposes Retry instead of leaving a false healthy badge.
- MCP stop is terminal for that service instance. Stop, restart and rapid Settings off/on transitions
  finish the old listener teardown before another listener may bind the port.
- HTTP requests are accumulated through fragmentation by `Content-Length`, bounded, and parsed without
  assuming one network receive equals one request.
- The shared editor-level `PipelinePhaseRunCoordinator` keeps one execution task per project;
  reconnect retries join the same phase instead of starting duplicate analysis, while different phases
  fail closed.
- MCP transport tests disconnect a delayed phase call, reinitialize, retry it through a new SDK
  session, require the retry to join the original project job, and assert that the runner executes
  exactly once. They also pin the SDK-defined GET 405 response.

### Progress and approval

- Engine contract 4 adds an ABI-safe `ProgressPhaseRunner` registry at the end of `EngineRegistry`.
- Musicvideo 0.0.7 reports seven real Audio Analysis stage boundaries from decode through canonical
  artifact write.
- The transcript replaces the generic running tool row with the approved compact progress card showing
  phase, original filename, current stage, measured stage count, progress bar, and next stage.
- Pipeline rows show `Running`; direct Approve is absent and the gate menu is disabled during work.
- Agent approval, native approval, gate-state changes, deferred approval commits, and rewind share
  fail-closed running/structural checks.
- Closing and reopening a project while a phase settles cannot let the retired session delete the new
  Recovery working copy; every open owns an independent generation claim.

### Repeatable optional intake

- Musicvideo 0.0.10 declares prepared characters and locations as numbered repeatable items.
- Host-owned dialog state distinguishes first empty, completed, and subsequent empty items.
- The primary Attach action requires all declared required fields; Skip and Done are explicit
  secondary actions with schema-validated continuation values.
- Shared capsule button styles now own a visibly disabled treatment across app surfaces.
- Manifest/runtime tests cover numbering, incomplete submission rejection, Skip, Done, and continuation.
- `docs/ui/repeatable-intake.html` is the normative rendered UI specification.

### Transcript hang

- The macOS hang report identifies a main-thread SwiftUI/AttributeGraph layout loop:
  `SecondaryLayerGeometryQuery → LayoutEngine.explicitAlignment → sizeThatFits`; it is not an Audio
  Analysis or MCP stall.
- `WrapLayout` now reports only bounded finite geometry, measures and places against the same width,
  proposes the measured size to children, and explicitly declines merged subview alignment guides.
- Scroll visibility no longer mutates the observed hierarchy from a geometry callback. Scroll intent
  is derived only from user scroll phases; the button remains mounted as a sibling outside the
  observed `ScrollView` modifier chain, and programmatic following is not animated.
- Transcript mutations carry a revision so growth inside an existing assistant turn follows the true
  final entry rather than an earlier running-activity row.
- Ignored Claude stream-json lines no longer republish an unchanged observable transcript, and activity
  status changes no longer apply an implicit layout animation.
- Geometry and revision regression tests cover wrapping, non-finite/overflow input, consistent
  measurement, and in-place transcript growth.
- A background main-thread watchdog distinguishes a blocked UI thread from whole-process suspension.
  After eight continuously observed seconds it writes state history and requests a bounded
  three-second macOS process sample under `~/Library/Logs/NexGenVideo`; Help → Reveal Diagnostics
  opens that folder even when process sampling is unavailable.

## Verification completed without a local build

- `git diff --check`
- `python3 scripts/lint_app_theme.py`
- `python3 scripts/release_preflight.py 1.0.1 <empty-catalog>`
- JSON/plist/YAML metadata parsing and the standalone `AGENTS.md`/`CLAUDE.md` parity check
- `ci-lint` with zero failures and zero warnings after pinning Linux images and adding the missing PR
  concurrency guard.
- Three independent Claude Subscription/CLI passes reviewed the complete diff and the corrected
  lifecycle subset. Their actionable findings affecting transport lifetime, session rotation,
  listener failure reporting, job settlement, gate visibility, working-copy lifetime, test teardown
  and join determinism were corrected.
- A critical transcript-hang review used Claude Opus at maximum effort plus bounded-input AGY/Gemini.
  The verified findings about user scroll intent, true-tail following, repeated projection, inert
  transitions, consistent wrapping and bounded pathological geometry were corrected. Apple's Layout
  documentation independently confirms that the default explicit-alignment implementation merges
  subview guides, while an explicit `nil` declares no explicit guide.
- The Claude/AGY watchdog review confirmed the transcript sibling-layer correction and found
  compile-access, privacy, duplicate-report, and sampling-timeout defects in the first watchdog
  draft. Those findings are corrected.
- The final independent repository gate passed both its text conformance review and its degraded
  visual review against the normative UI specs, rendered mockups, and Swift UI diff.
- No Swift build or test has been run locally.

## Release procedure for this batch

1. Never trigger CI until the owner says `build now`.
2. On explicit approval, commit/push as one batch, require every PR gate to pass, merge, then run one
   GitHub Actions macOS release build.
3. Verify the notarized DMG with the exact on-device trace: original Track name, English default agent,
   visible advancing Audio Analysis, no active Approve, successful analysis completion, interpretation,
   then approval.
4. Continue through Brief with prepared-character intake: visible item number, disabled incomplete
   Attach, Skip on the first empty item, Done after a completed item, and no transcript beachball while
   progress/report/dialog content changes.
