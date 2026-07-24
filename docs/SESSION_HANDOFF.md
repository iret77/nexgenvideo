# Session handoff — 2026-07-24

## Objective

Ship one consolidated NexGenVideo 1.0 release candidate. Never build locally. Do not merge, open a
release PR, dispatch CI or `release.yml`, or publish without the owner's explicit in-the-moment
approval.

## Prepared state

- Branch: `codex/release-1.0-rc`
- Base: `origin/main`
- App/changelog version: `1.0.0`
- Musicvideo pack candidate: `0.0.5` (stable catalog currently `0.0.4`)
- No local build or test was run; macOS 26 GitHub Actions is the only verification surface.
- No PR, CI run, DMG build, merge, tag, issue closure, or release was triggered.

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

The issues stay open until the consolidated macOS CI run proves their acceptance criteria.

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
- `git diff --check` passes.
- All workflow YAML parses.
- All 31 workflow `run:` blocks and release shell scripts pass `bash -n`.
- Changelog JSON, app Info.plist and Python sources pass static parsing/syntax checks.
- Branch pushes do not trigger CI; repository workflows run on pull requests or manual dispatch.

## Remaining gates

1. Resolve the locked-spec gate: this branch changes `docs/PATTERN_FIT_CONTRACT.md` to make partial
   authored libraries shippable. `AGENTS.md` requires explicit owner approval for any change to that
   locked file. Do not infer approval; either record it or revert the contract and dependent code.
2. Re-run the targeted Gemini spec scope after that decision. The standard `spec-check` Codex
   reviewer remains unavailable under the managed host policy; the user explicitly approved Gemini
   3.1 Pro via AGY as the fallback.
3. Obtain the owner's explicit in-the-moment `build now`.
4. Run one consolidated macOS 26 CI verification and review every #279–#287 acceptance criterion.
5. Only after green CI: close verified blockers and prepare the release PR.
6. Production merge, `release.yml` dispatch and publication each remain separate explicit actions.

## Release workflow

The stable pack and badge bytes upload before the final catalog promotion. Pending catalog,
transaction metadata, catalog/artifact hashes and a completion marker make publication resumable
without another macOS allocation. Resume now fetches the release branch and checks out its head
detached before committing the appcast, preventing stale Linux-gate state from causing a
non-fast-forward publication failure.
