# Session handoff — 2026-07-23

## Objective

Prepare NexGenVideo for a real 1.0 release without spending a macOS/DMG CI run only to discover the next avoidable blocker. Do not build, dispatch `release.yml`, merge, or release without the owner's explicit in-the-moment approval.

## Current state

- Branch: `docs/agents-hard-rules`
- The working batch is intentionally a checkpoint, not a verified release candidate.
- No local build or test was run; repository rules require macOS 26 GitHub Actions.
- No CI, DMG, merge, push, or release was triggered during this audit.
- `git diff --check` passed immediately before the checkpoint.

The batch currently includes the storage/recovery overhaul, working-copy routing for durable writes, atomic project and media mutations, fail-closed workflow artifact reads, stricter tool schemas, budget-stop groundwork, inline replacement of transient agent status messages, release preflight hardening, and plugin-pack notarization/quarantine checks.

## Known release blockers

- #279: complete Recovery behavior
- #280: song replacement durability and success reporting
- #281: dry-run release must not mutate the stable plugin channel
- #282: import correctness, deduplication, undo, symlink cycles, and scope
- #283: import redirects and private targets
- #284: model revisions must be pinned
- #285: app-authored turns must not appear as user messages
- #286: enforce project budget stops at the central paid-generation boundary
- #287: notarize downloadable `.ngvpack` bundles and verify quarantined loading

Issues #286 and #287 were created during the audit and labeled `release-blocker`. Do not close blockers merely because code exists; verify their acceptance criteria in the one consolidated CI run.

## Resume here

1. Confirm the checkpoint commit and clean working tree with `git status --short --branch`.
2. Statically syntax-check every `run:` block in `.github/workflows/release.yml`; YAML parsing already passed, but the new notarization heredoc still needs a shell-level check.
3. Reconcile all open `release-blocker` labels in GitHub and inspect the retry/transaction semantics of stable plugin publication.
4. Finish #286 at the provider-normalized paid-generation boundary. Do not invent a credits-to-EUR conversion and do not let direct generation, image, audio, upscale, or rerun paths bypass the project stop.
5. Continue the full static diff review against `docs/CONCEPT.md` and the locked storage/plugin/pattern-fit specs.
6. Only after all static blockers are resolved, present the complete batch and wait for the owner's explicit `build now` before CI.

## Release workflow detail to revisit

Stable plugin publication currently precedes app release publication. A failure after that point can make a retry conflict because signed/notarized ZIP bytes can change. Define a retry-safe, idempotent publication transaction before calling the workflow release-ready.
