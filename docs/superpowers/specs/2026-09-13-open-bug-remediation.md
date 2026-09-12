# Open Bug Remediation Specification

Status: approved by the owner on 2026-09-13 through the instruction “Implement”.

## Scope

Implement GitHub issues #510, #511, #512, #513, #514, #516, #529, #530, #531, and #532 as one release batch.

## Observable requirements

- Agent and MCP numeric arguments reject non-finite, fractional, string, overflowing, and unsafe derived integer values before reads, mutations, package preparation, or pipeline execution. Errors identify the tool and full field path.
- XML export reports encoding or durable-write failure to both the native export surface and the agent. Existing destinations survive failed overwrite attempts.
- Muted audio tracks are not resolved, composed, mixed, or exported. Clip-level zero volume remains distinct from track mute.
- Home remains visible until an editor window becomes key. Cancelled and failed opens do not hide Home, and the key document owns active-project state.
- Transcription removes Unicode locale extensions before supported-locale matching while preserving language, script, and region. Agent conversation language is unchanged.
- Waveforms derive from decoded frames and timestamps, remain bounded for long or malformed assets, align with source trims, and use a deterministic versioned cache written atomically off the main thread.
- A generation package is approvable only when every exact request has a typed, current price. Transient quote failures can be retried without generation; unsupported routing can be changed and re-prepared without restarting the app. Unknown price remains a hard stop.
- Batch review uses a compact numbered list with image previews, expandable technical details, one bounded scrolling region, and persistent Remove, total, approval, retry, and route actions. Pointer and keyboard activation reach the same handlers.
- Copying a confirmed identity asset into a phase does not mutate import truth. Phase-owned derived provenance records original and destination hashes. Existing affected projects use an explicit transactional Recovery-copy migration; unchanged artifacts can be rebound in one reviewed operation, while changed artifacts remain stale.
- User-visible transcript and gate state comes from typed host outcomes, never assistant prose. Rejected, persisted-unvalidated, validated-awaiting-review, approved, and stale states remain distinguishable; internal paths and fingerprints stay in expandable diagnostics.

## Compatibility decisions

- Do not add stored properties to `EngineRegistry` except at its end.
- Do not add stored properties to existing public value types that cross the pack boundary.
- Add new sidecar types and files for derived provenance and recovery receipts.
- Keep older Music Video pack versions installable and openable. Any schema change ships as a new side-by-side pack version and is entered only through the existing transactional Recovery-copy upgrade flow.
- Do not add a track-solo property; the current timeline model has no solo state.
- Do not add FCPXML support. Issue #511 hardens the existing XMEML/FCP7 XML path.
- Do not widen `copy_project_file` into Storyboard; it remains available only in its declared Production Design and Bible phases.

## Verification boundary

Tests must be authored before their production changes. The repository prohibits local builds and tests, so red/green execution is deferred to GitHub Actions and remains unverified until the owner separately says “build now”. No workflow dispatch, push, merge, or release is authorized by this specification.
