# Session handoff — 2026-07-24

## Objective

Ship one consolidated NexGenVideo 1.0 release candidate. Never build locally. A successful dry-run
was tested on-device and exposed an OAuth callback crash; the corrective candidate is prepared.
Do not run the next CI/DMG build, merge, open a release PR or publish without the owner's explicit
in-the-moment approval.

## Prepared state

- Branch: `codex/release-1.0-rc`
- Base: `origin/main`
- App/changelog version: `1.0.0`
- Musicvideo pack candidate: `0.0.5` (stable catalog currently `0.0.4`)
- Last green dry-run commit: `081a1f015c9074da50c9637aa90983dc598c22e1`
- Green release workflow: `30064697840`
- The run passed the full test suite, signing, app and pack notarization/stapling, external signed-pack
  loading, DMG verification, Sparkle signing and artifact upload.
- The dry-run artifact `NexGenVideo-1.0.0-dry-run` contains the DMG and both publication names of the
  same musicvideo pack. Stable release, appcast and catalog publication were skipped.
- On-device testing found a `SIGTRAP` after a successful Higgsfield browser login. AuthenticationServices
  called `presentationAnchor(for:)` on its SafariLaunchAgent XPC queue while the old implementation
  asserted main-actor isolation.
- The corrective patch captures the `NSWindow` on the main actor before starting authentication,
  retains a dedicated presentation context and serves the immutable anchor without an actor assertion.
  A regression test invokes this witness from a detached task.
- No local build or test was run; macOS 26 GitHub Actions remains the only verification surface.

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
- `git diff --check` passes.
- All workflow YAML parses.
- All 31 workflow `run:` blocks and release shell scripts pass `bash -n`.
- Changelog JSON, app Info.plist and Python sources pass static parsing/syntax checks.
- Branch pushes do not trigger CI; repository workflows run on pull requests or manual dispatch.

## Remaining gates

1. Obtain the owner's explicit in-the-moment `build now` for a new dry-run.
2. Run the macOS 26 release workflow and verify the OAuth regression test plus all existing gates.
3. Test Higgsfield sign-in from the new notarized DMG on-device.
4. Only after that succeeds: close verified blockers and prepare the release PR.
5. Production merge and publication remain separate explicit actions.

## Release workflow

The stable pack and badge bytes upload before the final catalog promotion. Pending catalog,
transaction metadata, catalog/artifact hashes and a completion marker make publication resumable
without another macOS allocation. Resume now fetches the release branch and checks out its head
detached before committing the appcast, preventing stale Linux-gate state from causing a
non-fast-forward publication failure.
