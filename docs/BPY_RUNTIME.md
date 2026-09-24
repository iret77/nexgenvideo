# Managed bpy runtime

The 3D runtime is a host-owned component, not another engine. The Swift host retains document,
pipeline, provider, approval, and project-write ownership. Two separately identified XPC services
cap concurrency at two active `VideoProject` documents. Each job starts a new Python/`bpy` process
from the last host-confirmed scene and a separate new process verifies the resulting scene. No
Python interpreter, handler, module state, thread, or monkeypatch is reused by the next job.

## Trust boundary

The app talks only to the two embedded `NexGenVideoBpyService` slots. Each service has its own App
Sandbox container and has no network, user-selected-file, Keychain, application-group, or temporary-
exception entitlement. The Python executable is signed only with App Sandbox inheritance. Provider
keys are absent from its allowlisted environment. A worker receives private staged inputs and an
in-memory-confirmed scene copy; it receives no project path and cannot write canonical project truth.

Native stdout and stderr are bounded diagnostic streams only. The service derives state from the
process exit observed by `Process`, not from worker output. After a zero exit, a fresh verifier opens
`scene.blend` with `use_scripts=false` and independently checks the exact Job ID and fingerprint,
Python and bpy identities, evaluated geometry, render settings, object/modifier evidence, output
types, and diagnostic OS denials. Only that verified result becomes a candidate. The autorun test
uses a real Blender Text side effect: production loading proves the side effect absent, while a
separate isolated `use_scripts=true` process proves the fixture can trigger it.

The child applies hard `RLIMIT_CORE`, `RLIMIT_FSIZE`, `RLIMIT_NOFILE`, `RLIMIT_CPU`, `RLIMIT_AS`, and
`RLIMIT_NPROC=0` limits before importing bpy. The service additionally monitors worker physical
footprint, its own physical footprint, total private-session bytes and files, wall deadline, and the
live descendant tree. A violation stops the process group, exact PID, and observed descendants and
does not yield a candidate. The verifier rejects excessive evaluated objects/vertices/polygons and
render dimensions/pixels; PNG dimensions and total outputs are checked again in native code.

These are layered, bounded controls rather than a claim of a race-free general-purpose Python
sandbox. `RLIMIT_AS` remains enabled because current XNU carries an address-space size limit in the
VM map; acceptance records the configured limit and an over-allocation outcome so the shipped macOS
behavior is measured. `RLIMIT_NPROC` supplies the kernel fork/spawn barrier for the non-root app
identity. Process-tree polling and kill order are cleanup and evidence around that barrier, not a
replacement for it. While a job is running, the service sends the trusted host an exact PID,
bundled-executable path, and process-start-time lease. XPC loss lets the host stop and revalidate
that exact leased process before killing its process group; no worker-writable registry, global
process scan, or unrelated app configuration participates. Recovery remains blocked if the leased
identity cannot be observed exiting within the bounded kill check.

Primary platform references:

- <https://developer.apple.com/documentation/security/app-sandbox>
- <https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations>
- <https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html>
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c>
- <https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_map_xnu.h>
- <https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h>

## Inputs, identity, and confirmation

The host opens every approved input relative to an already opened directory with `O_NOFOLLOW`,
requires a regular single-link file, hashes and streams the same descriptor, and verifies inode,
device, size, mtime, and ctime afterward. The service rechecks bytes, hashes, names, counts, links,
and aggregate limits.

A Job ID is immutable within a session. Its SHA-256 fingerprint length-prefixes the protocol tag,
expected confirmed revision, requested and effective timeout, exact source bytes, ordered input
names/sizes/hashes, and diagnostic options. The client and service compute it independently. An identical retry joins
the existing job or retained result; the same ID with a different fingerprint fails closed. IDs are
never evicted and silently re-executed. A session accepts at most 1,024 Job IDs, after which the
document must explicitly call the confirmed-state rotation path. Rotation is refused without both
the host-confirmed revision and exact scene bytes, or while an unconfirmed candidate exists; only a
successful explicit rotation clears the prior session's ID tombstones.

Successful execution produces only an awaiting-confirmation candidate. Candidate/result bytes are
retained for at most 15 minutes and within a documented per-session byte budget: the smaller of the
session disk limit, half the service-memory limit, and four output limits. If capacity is needed,
oldest terminal bytes expire first; their Job ID/fingerprint tombstones remain, and an expired
candidate becomes rejected. Confirmation checks the host-staged scene hash and stores its exact
bytes in both the service and host. Failed, cancelled, timed-out, resource-limited, crashed,
rejected, or expired jobs cannot be confirmed.

XPC interruption, invalidation, timeout, and service death invalidate the transport. The service
also closes only the session IDs owned by a client connection when that connection disappears. Reopening uses
a new transport/session identity and restores only the host's exact last-confirmed scene bytes and
revision. An incomplete revision/checkpoint pair fails closed. A failed open removes the service
session; a client that exhausts both open attempts closes its transport and no longer occupies a host
slot. Document close and `AppDelegate.applicationWillTerminate` close all sessions and active work.
Portable/canonical scene persistence remains #542; #541 recovery is deliberately in-memory.

## Runtime and distribution

`Runtime/bpy/runtime-lock.json` pins CPython, the `bpy` wheel, all declared Python dependencies,
python-build-standalone inputs, source locations, hashes, and licenses. The wheel entry point is the
RECORD-backed native module `bpy/__init__.so`. The lock also records the exact 43 `bpy/lib/*.dylib`
paths observed in the pinned wheel. Staging requires those exact paths and verifies every entry point
and native library against its wheel `RECORD` hash and size. CI extracts wheels directly; `pip` is
absent from assembly and from the installed app.

Public distribution remains fail-closed while `distributionStatus` is
`blocked-pending-corresponding-source-review`. The lock maps all 43 paths exactly once to candidate
source families, versions, URLs, SPDX licenses, and archive checksums from Blender v5.2.2's official
dependency manifest. Those MD5 or SHA-256 values identify Blender's candidates but are not accepted
as the final SHA-256 distribution closure. That is research evidence, not binary provenance: the remaining work is to prove the
pinned wheel used those exact candidates, hash-pin and ship the proven Corresponding Source plus
required notices, and review the combined distribution. The Blender source tarball alone is not
treated as proof of that closure.

Changing `distributionStatus` to `ready` also requires a complete `distributionClosure`: one
SHA-256- and size-pinned archive mapping every Python-build-standalone source, wheel source, CPython
build input, and bpy native candidate exactly once (shared archives may name multiple components),
repository-hashed wheel-provenance and notice evidence, and a combined-distribution review
reference. Declared URLs and existing SHA-256 pins must match the lock; MD5-only Blender-manifest
candidates gain a final SHA-256 pin in this closure. Staging then embeds all archives and evidence,
and bundle verification rehashes them.

Each `sourceArchives` entry carries `components`, `filename`, `url`, `sha256`, and `size`.
Component IDs are `python-build-standalone`, `wheel:<lock name>`,
`python-build-input:<lock name>`, and `bpy-native:<candidate-family name>`. The remaining closure
keys are `wheelBinaryProvenance` (`path`, `sha256`), nonempty `noticeFiles` entries with the same
shape, and `reviewReference`. Evidence paths live under `Runtime/bpy/compliance/`.

The distribution gate runs before release builds, including dry runs, and before the managed-runtime
acceptance build/transfer ZIP. Regular public CI does not upload the app or transfer it to the runtime
runner while blocked. Other CI workflows that must transfer a diagnostic app use an explicit
CI-only bundle mode that omits the runtime and embeds an omission marker. Normal dev, acceptance,
and release bundles continue to require the runtime; readiness is never synthesized.

## Prepared Actions acceptance

`.github/workflows/bpy-runtime-acceptance.yml` is manual and SHA-bound. Once the source/notice gate is
truthfully ready, it builds and unit-tests on `xcode-27`, assembles the pinned runtime, signs and
notarizes the app, then relocates and runs it on `macos-26` arm64. No local execution is an acceptance
substitute.

The runtime probe uses real `VideoProject` instances and windows through `BpyRuntimeHost`. It covers
two slots, a denied third document, failed-open reuse, close/reuse, and AppDelegate shutdown. It also
covers exact and changed duplicate payloads, forged native stdout plus an infinite loop, a persistent
thread, ctypes stdout, a kernel-blocked fork, memory over-allocation, timeout, cancellation, worker
crash, service kill/reopen from the confirmed host checkpoint, denied-file host positive controls,
network and cross-container denials, disabled autorun plus isolated positive control, BMesh/modifier
geometry, and a perspective Cycles render.

Evidence separates host-observed open-to-ready and job durations from service-observed cold start,
worker/verifier wall times, worker/verifier/service footprints, disk/file peaks, and descendant peak.
It also records the host process peak through `getrusage`, package size, OS, hardware, exact runtime
identity, renderer/device result, and distinct worker/verifier PIDs. Until the distribution blocker
is resolved and an owner explicitly dispatches the workflow, these are prepared assertions, not
claimed PASS results.
