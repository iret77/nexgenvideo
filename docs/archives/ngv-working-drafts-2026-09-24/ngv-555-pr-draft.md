# PR draft: Close production navigation review findings (#555)

## Stack

- Proposed base: `codex/ui-507-inspector`
- Exact stack base SHA: `76a6eaeca196ecbc49b98ec453b28f8b92d54d17`
- Reviewfix start SHA: `e15d09294505045034c5f483352ca54214949048`
- Head branch: `codex/issue-555`
- Local head SHA: `38cf97b7e59847c02df6d7f37846e63a4597782c`
- This remains stacked on #507 → #506. Nothing was integrated into `main`.

## Summary

Close the seven confirmed review gaps in the contract-driven Production navigator: valid ViewBuilder composition, truthful spend and readiness presentation, loaded artifact evidence, native read-only control evidence, adaptive narrow layout, correct writable-state transitions, and state-specific user actions.

Closes #555.

## What changed

- Wrap heterogeneous routed surfaces before applying their shared overlay.
- Preserve the configured budget stop and distinguish unknown remaining money from no hard stop; surface incomplete-spend and budget warnings.
- Create deterministic local Brief, Treatment, Frames, and Render-take fixtures and identify artifacts from their loaded consumers.
- Verify visible native control and accessibility enabled states, attempt locked mutations, and prove project/working-copy/transcript/undo invariants.
- Keep real Frames and Render inspection usable while a coordinator job holds the write lease.
- Adapt phase navigation and the phase dock at narrow widths, with 960 px geometry checks across interface scales 1.0, 1.25, and 1.5.
- Recompute effective write availability correctly across transient locks and dismiss stale Redo/Remix/Rewind affordances when readiness is lost.
- Distinguish checking, current, future, approved, host-decision, and running explanations. Checking performs no model action; a host decision opens the existing Agent decision; only substantive blockers offer an Agent repair action.

## Contract boundaries

- Existing SharedReadiness, native writers, coordinator jobs, and mutation leases remain authoritative.
- Generic, Musicvideo, legacy deep links, the single declarative pack surface, and invalid-pack fail-closed behavior are unchanged.
- No locked spec, artifact schema, Pack ABI, `EngineRegistry` layout, provider, or GitHub workflow change.
- No full #558 artifact implementation, #476 budget feature, or #556 chat removal.

## Prepared regression evidence

- Unit coverage for readiness action mapping and configured-stop/unknown spend state.
- Native macOS 26 harness coverage for loaded artifact IDs, actual NSControl/AX disabled states, click effects, inspection, readiness-driven dialog/popover closure, byte invariants, and compact-layout geometry.
- Local deterministic PNG/video fixtures only; no generated-media provider call.

## Verification status

- `git diff --check HEAD^ HEAD` — clean.
- Worktree — clean after local commit.
- Local compiler/build/test/app execution — not run, per repository policy and task instruction.
- GitHub Actions/native screenshots — prepared but not dispatched or executed; no PASS is claimed.

## Not done

- No push, PR creation, CI dispatch/rerun, merge, main integration, or release.
