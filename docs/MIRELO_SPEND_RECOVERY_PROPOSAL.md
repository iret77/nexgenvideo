# Mirelo Spend Recovery Proposal

Status: review proposal only. This document does not change an approved storage contract.

## Problem

A Mirelo request can be accepted after the Recovery copy diverges from the saved package. If the
user then discards recovered editing changes, `ProjectWorkingCopy.rematerialize` correctly restores
the saved creative state, but it also removes the only project copy of the reservation and submitted
spend events. The host-owned Mirelo authority survives and still proves possible or actual provider
acceptance.

Opening a different Finder copy does not repair the evidence. It carries the same project UUID but
can have a different creative and spend projection, and the current Mirelo authority record does not
retain the exact `GenerationSpendEvent` bytes needed to restore the projection safely.

## Existing contract and conflict

`docs/PROJECT_STORAGE.md` says that host execution authority is authoritative over an older project
projection, retains append-only spend events, and that discarding editing changes never erases
incurred spend. It also says that a project package cannot mint or restore authority.

The implementation cannot currently satisfy all of those statements for Mirelo:

- `MireloExecutionRecord` retains the spend transaction ID, preflight credits and provider evidence,
  but not the exact project reservation/submission events.
- A valid project ledger must begin with its original `reserved` event and preserve its event ID,
  route and optional monetary quote. Creating replacements from the Mirelo request would fabricate
  audit evidence.
- Mirelo publishes credits, not a dependable credit-to-EUR conversion. Recovery cannot infer money.
- A package duplicate with the same UUID provides no proof that its ledger is the projection that
  originally approved the request.

Consequently, the current safe behavior is a budget stop. The app must not invent a reservation,
price, lineage acknowledgement or new project identity to clear it.

## Smallest recommended contract delta

Require every host-owned Mirelo authority to retain an immutable spend-projection sidecar containing
the exact canonical project `GenerationSpendEvent` bytes that the host observed:

1. Approval records the already-persisted `reserved` event byte-for-byte.
2. Provider acceptance appends the exact `submitted` event byte-for-byte.
3. Settlement appends an exact `charged` or `released` event when one exists.
4. Events remain append-only and are validated against the authority's project UUID, transaction,
   model, provider, transport, endpoint and provider job ID.
5. Open and post-discard reconciliation may copy only those retained bytes into the project spend
   projection. It may not restore media, prompts, timeline edits or other discarded creative work.
6. Every package carrying the same project UUID receives the same host spend projection on this
   host. That does not grant new execution authority or restore provider output. Save As continues to
   mint a new UUID and therefore cannot execute or absorb the source authority.

A separate canonical sidecar is preferable to adding stored fields to `MireloExecutionRecord`: it
avoids changing that value type's layout and permits old authority records to remain readable. The
sidecar needs its own schema identifier, immutable digest and atomic update rules. The locked storage
contract should name this separation between authoritative spend projection and creative state
before implementation.

## Existing data and compatibility

- New approvals can retain exact events without changing project `generation-log/v2`.
- Existing authority records have no exact reservation event. They remain blocked and must not be
  backfilled from inferred model, timestamp, event ID or price.
- Existing projects remain readable. A project receives retained events only when event IDs and the
  complete transaction identity validate without conflict.
- Older app versions will ignore the host sidecar. Once a recovered projection is saved, they can
  read the existing project ledger format, subject to their normal provider support.
- No format-pack ABI or project schema change is required if the sidecar stays host-owned. The
  storage-contract clarification is still required because post-discard host-to-project projection
  is observable behavior.

## UI and budget behavior

- While exact retained events are available, show `Restore Mirelo spend record`; explain that it
  restores cost history only, not discarded media or edits.
- Apply automatically during open/discard only if the approved contract explicitly chooses automatic
  authoritative projection. Otherwise require the visible action above.
- If exact events are unavailable, say that no safe in-app recovery exists and ask the user to retain
  the project and Recovery data for diagnosis. Do not suggest opening a copy that is already gone.
- Preserve `money: nil` when the original event was unpriced. Show the exact Mirelo credits from the
  authority, but do not convert them to EUR.
- A configured EUR budget stop remains blocked by unpriced spend. No acknowledgement may waive that
  uncertainty. Without an EUR stop, normal ledger rules may continue once the exact spend projection
  is restored.
- Conflicting project and authority events remain a hard stop with no automatic overwrite.

## Required tests

1. Accepted spend followed by Discard restores exact spend events but not the generated placeholder,
   media, timeline edits or prompt changes.
2. Repeated open/discard is byte-idempotent and never duplicates an event.
3. A same-UUID Finder copy receives spend projection only; it receives no authority, artifacts or
   creative changes.
4. Save As receives neither source authority nor source spend projection under its new UUID.
5. Missing legacy sidecar remains blocked without synthesized data.
6. Event-ID, route, transaction, provider-job and digest conflicts remain blocked and leave both
   records unchanged.
7. Unknown acceptance retains the original reservation and never creates a second provider request.
8. Unpriced credits remain unpriced; an EUR budget stop stays closed.
9. Crash injection at each sidecar/project write boundary converges from exact retained evidence.
10. Concurrent jobs reconcile independently; completing one never clears another conflict or unknown
    acceptance issue.

## Alternatives

- **Keep the permanent stop.** Safest with current data, but leaves a project UUID unusable after its
  only Recovery projection is discarded.
- **Add a new external-spend event kind.** Makes provenance explicit, but changes the portable ledger
  schema and requires old-project/app migration. It is larger than retaining existing exact events.
- **Add a package-lineage UUID beneath the project UUID.** Distinguishes Finder copies, but changes
  authority identity and migration semantics and still does not recover spend after the originating
  Recovery copy is discarded.
- **Acknowledge or estimate the orphan.** Rejected: it invents price or permits a user acknowledgement
  to bypass unknown paid acceptance.
- **Silently mint a new project identity.** Rejected: it evades, rather than reconciles, the existing
  spend authority.
