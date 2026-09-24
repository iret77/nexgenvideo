# Mirelo Single-Job Authority Contract Delta

Status: owner decision proposal only. This document does not change a locked contract. The dependent
#534 Mirelo Store, Coordinator, reconciliation, native-resume and agent-resume implementation is not
ship-ready unless this delta is approved and implemented.

## TL;DR

Approve one change to `docs/PROJECT_STORAGE.md`: extend its sole host-bound authority exception from
approved generation batches to **approved generation batches and approved single Mirelo jobs**.

Everything else needed here is already contractually required. Host authority retains append-only,
exact spend events; it overrides an older project projection; and Open, Reload and Discard
automatically project missing spend history back into the working copy. That projection is spend-only:
it never restores discarded media, prompts, timeline changes, generated artifacts or other creative
work. There is no manual Restore control and no separate decision about automatic projection.

## The one missing permission

Principle 1, the storage table and “Approved generation execution lifetime” currently authorize
host-bound state only for approved generation **batches**. The #534 implementation also creates
non-batch Mirelo authority through `MireloExecutionStore` and `MireloExecutionCoordinator`, keyed as:

`<hostId>/<projectId>/mirelo/<logicalJobId>/`

That authority supports first execution, `GenerationService.reconcileMireloAcceptedSpend`, native
resume and the agent `run_mirelo_audio` resume path. These paths need the same narrow exception as a
batch. They may not ship under the current wording even though their safety properties match the
batch authority.

Approval is requested only for this scope extension. It does not authorize generic host-owned project
truth, another provider, an unapproved request or a reusable approval.

## Minimal locked-spec wording

If approved, replace or extend only these three places in `docs/PROJECT_STORAGE.md`.

### 1. Principle 1

Replace the final sentence of Principle 1 with:

> The sole host-bound exception is single-use authority for already approved generation batches and
> approved single Mirelo jobs; it cannot travel with a copied package or create project truth by
> itself.

### 2. “Where each thing lives” table

Replace the approved-execution row with:

> | Single-use authority for approved generation batches and approved single Mirelo jobs, retained
> exact inputs, append-only exact spend events, provider receipts and completed output bytes |
> `~/Library/Application Support/NexGenVideo/ApprovedGenerationExecutions/<hostId>/<projectId>/<batchId>/`
> for batches; `~/Library/Application Support/NexGenVideo/ApprovedGenerationExecutions/<hostId>/<projectId>/mirelo/<logicalJobId>/`
> for single Mirelo jobs |

### 3. “Approved generation execution lifetime”

Add this paragraph after its opening paragraph:

> An approved single Mirelo job follows the same lifetime under
> `<hostId>/<projectId>/mirelo/<logicalJobId>/`: immutable exact inputs, single-use execution,
> append-only exact spend events, unknown acceptance that fails closed, provider receipts and
> verified completed output bytes. It is authority for that one logical job, not a generation batch
> and not reusable project authority.

The rest of the section remains binding without qualification: a project or Recovery copy cannot mint
or restore authority; host evidence is authoritative over an older projection; completed output is
hydrated only after receipt and digest verification; Save As receives a new project UUID; another Mac
has no authority; and Discard cannot erase incurred spend or turn submitted work into a fresh request.

## Already-required behavior

The following is implementation work under the existing contract, not another owner decision:

- Authority stores the exact canonical `GenerationSpendEvent` bytes it observed, beginning with the
  already-persisted `reserved` event and appending the exact `submitted`, `charged` or `released`
  events that occur.
- Open, Reload and Discard automatically and idempotently project missing authority spend events into
  `generation-log/v2` after validating the complete transaction identity and event sequence.
- Host spend evidence wins over an older saved-project projection. A conflicting projection remains a
  hard stop and is never overwritten.
- Projection restores spend history only. It never restores discarded creative state or provider
  output. Output hydration remains separately gated by its exact receipt and digest.
- Unknown acceptance stays fail-closed and reuses the same persisted idempotency key where the provider
  route supports one. No path creates a second request to clear uncertainty.
- A Finder copy with the same project UUID may receive the same spend projection on the originating
  host, but gains no new authority. Save As and a different Mac receive no authority.

## Storage implementation

Recommended: write `mirelo-execution-authority/v2` with canonical exact spend-event storage. A
versioned, digest-bound spend sidecar beside the Mirelo authority record is an acceptable equivalent
only if it has the same atomicity and validation boundary.

The choice is a storage-schema design choice, not a pack-ABI concern. `MireloExecutionRecord` is an
internal persistence representation; avoiding a stored field in it does not by itself establish ABI
safety. Whichever form is chosen must use canonical bytes, an explicit schema identifier, atomic
append/replace boundaries and validation binding every event to the authority’s project UUID, logical
job, spend transaction, model, provider, transport, endpoint and provider job ID.

This changes neither project `generation-log/v2` nor any format-pack ABI or compatibility version.

Existing `mirelo-execution-authority/v1` records without retained exact events remain blocked. No
event ID, timestamp, route, provider receipt or optional EUR value may be inferred or backfilled.
Because this feature has not shipped, new approvals can start with complete v2/sidecar evidence; no
invented legacy migration is required.

## Dependent #534 paths

Approval and implementation must cover the complete single-job path together:

- `MireloExecutionStore`: canonical authority and exact-event persistence;
- `MireloExecutionCoordinator`: single-use submission, unknown-acceptance and settlement transitions;
- `GenerationService.reconcileMireloAcceptedSpend`: automatic validated spend projection on Open,
  Reload and Discard;
- native Mirelo start/resume and cancellation settlement;
- agent `run_mirelo_audio` start/resume and settlement.

Until exact events are retained and these consumers reconcile them, the existing #534 non-batch code
must remain fail-closed and must not be released.

## Required verification

CI must exercise the real Store → Coordinator → project reconciliation consumers, not merely encode
and decode a proposed record:

1. Approval persists the exact existing reservation; acceptance and settlement append exact events.
2. Open, Reload and Discard restore identical spend bytes but no placeholder, media, prompt, timeline
   edit or artifact.
3. Repeated projection is byte-idempotent and cannot duplicate or reorder events.
4. A same-UUID Finder copy receives spend-only projection but no execution authority or output.
5. Save As and a different host receive neither source authority nor a mintable approval.
6. A v1 record without exact events stays blocked without synthesized backfill.
7. Event-ID, digest, route, transaction, model, provider-job and sequence conflicts leave both sides
   unchanged and keep the budget closed.
8. Unknown acceptance never creates a second request; output hydration requires the exact verified
   receipt and digest.
9. Concurrent logical jobs reconcile independently; repairing one cannot clear another conflict,
   orphan or unknown-acceptance stop.
10. Crash injection covers every durable boundary: authority approval before/after reserved-event
    persistence, provider receipt before/after submitted-event persistence, project projection
    before/after atomic commit, and settlement before/after charged/released persistence. Every
    restart must converge from retained exact evidence without restoring creative work.

## Decision

Approve or reject only this statement:

> The locked project-storage exception may include approved single Mirelo jobs at
> `<hostId>/<projectId>/mirelo/<logicalJobId>/`, with the same single-use, exact-input,
> append-only-spend, fail-closed-unknown, Save-As/different-host and verified-output guarantees as
> approved generation batches.
