# Approved generation lifetime

Status: accepted and implemented for NexGenVideo 1.5.7.

An approved provider request must not become unsubmitted when an older project save is reopened.
The current storage contract clears the Recovery working copy after a clean save/quit; discarding
unsaved work also replaces that copy from the saved package. If submission advanced after the saved
snapshot, that can erase the receipt while retaining an older queued authorization in the package.
Replaying that authorization would create another paid job.

## Ownership

Keep the host's approved-execution journal independently of the discardable editing working copy,
keyed by the project UUID and a stable host identity. It contains immutable batch/package identity,
single-use consumption, retained input references, central spend transaction identity and provider
receipts. It is execution recovery, not another pricing or budget ledger. The existing central spend
boundary still owns reservations, charges, releases and budget stops; missing monetary evidence
must be reconciled before another budget-constrained dispatch.

Save portable package/history projections inside the project as before. A project copy, older save
or imported package cannot mint a fresh execution authority. A different host can inspect history
and reconcile known provider jobs but cannot replay a queued authorization from another host.

## Observable behavior

- Closing or quitting preserves approved jobs and their receipts. Reopening resumes queued work
  only if the exact project direction, inputs, route, destination and price ceiling still match.
- Discarding unsaved editing changes does not undo provider spending. Already submitted jobs remain
  inspectable; queued items whose approved direction was discarded become blocked.
- `Cancel remaining` cancels queued items explicitly. Status recovery never starts a new generation.
- Submitted jobs with missing receipts remain unresolved and cannot automatically retry.
- Save As keeps output/history provenance but does not transfer a live authorization to the new UUID.

## Required acceptance

Exercise clean close and quit during pricing, upload, submission acknowledgment, polling, download
and finalization; save while each boundary advances; discard Recovery; reopen older saves; Save As;
open a copied project on another host; and reconcile a lost journal-write acknowledgment. Assert no
second content-generation request, no lost completed media and no budget bypass.

`docs/PROJECT_STORAGE.md` now defines this separate durable approved-execution lifetime. Editing still
writes the Recovery copy and package changes still use atomic save. The host authority is the only
exception to package-contained durable project state, and it can authorize only the exact retained
batch identity on the Mac that consumed the approval.
