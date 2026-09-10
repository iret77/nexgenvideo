# CI execution and measurement

CI classifies the complete PR diff, runs inexpensive source checks on Linux, then
compiles debug products and tests once on `xcode-27`. When bundle paths change,
the same job assembles the app from that build directory through SwiftPM's
incremental build. Real external pack loads, historical compatibility checks and
relaunch checks still run. Normal-startup acceptance consumes the zipped app on
`macos-26`. Build directories are never cached or restored across jobs.

Agent UI specification rendering runs in a separate Linux job for changes to its
inputs or CI wiring. A documentation-only UI specification edit now produces
render evidence without allocating a macOS runner. Runtime Markdown in source
and pack directories is treated as code. `Merge Gate` requires all selected jobs,
including UI evidence and normal-startup acceptance, and rejects missing plans,
failed jobs and unexpected skips. The manual Bundle workflow calls the same CI.

## Release metadata

The publication script dispatches CI with `metadata_version` on the version's
metadata branch. CI downloads that release's existing publication transaction
from the plugin channel. It verifies ancestry and reconstructs the only allowed
changes from the transaction: the two Info.plist version strings and one appcast
entry. Other plist keys, earlier appcast entries, signatures, URLs and file modes
cannot use the shortcut. Changed source since the release requires full CI;
malformed or mismatched release metadata fails on Linux. A manual CI dispatch
without metadata input always selects full verification.

## Release compilation

Release tests still use their separate scratch directory with `-enable-testing`.
Tests import app, engine and pack internals using `@testable`; the distributed app
and pack compile without that flag. Sharing their build directory or shipping
testable products would change the production configuration. This optimization
therefore retains both release compilations and all signed-artifact checks.

## Monitoring

Collect edits before one PR push. Monitor an exact run and commit with
`scripts/ci_watch.py`; it polls once per minute, remains quiet while unchanged,
reports API failures and timeouts explicitly, and prints one JSON result plus
bounded excerpts for failed jobs. It does not dispatch or retry workflows.

From an interactive project shell with the repo auth helpers:

```sh
python3 scripts/ci_watch.py RUN_ID --sha COMMIT_SHA --gh-command gho "$(getpat)"
```

Inside Actions the default authenticated `gh` command is used. The report sums
job timestamps as raw runner seconds, reports workflow elapsed time separately,
and includes step durations and runner labels. Queue time is excluded from runner
seconds. These are operational timings, not rounded billing minutes or costs.

Compare equivalent successful changes and configurations; also count failed and
cancelled attempts when assessing a batch. Baseline observations before these
changes:

| Run | Measured steps |
| --- | --- |
| [CI 34416977181](https://github.com/iret77/nexgenvideo/actions/runs/34416977181) | Compile 453 s; UI rendering 79 s |
| [Bundle 34416977199](https://github.com/iret77/nexgenvideo/actions/runs/34416977199) | Build and bundle 274 s |
| [Release preview 34175620480](https://github.com/iret77/nexgenvideo/actions/runs/34175620480) | Test compilation 1,003 s; production build and signing 410 s |

The bundle baseline includes assembly and signing; it is not all removable
compilation time. Wall-clock savings also depend on the former parallelism and
runner queues. Measure the resulting runs before claiming a percentage.
