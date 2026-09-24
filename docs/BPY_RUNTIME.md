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
Before Python starts, a signed native supervisor applies an additional Seatbelt profile that denies
network, fork, the SBPL `signal` operation, and every write outside that process's private write root.
The inherited XPC container is therefore not the worker's write boundary.

Native stdout and stderr are bounded diagnostic streams only. The service derives state from the
process exit observed by `Process`, not from worker output. After a zero exit, a fresh verifier opens
`scene.blend` with `use_scripts=false` and independently checks the exact Job ID and fingerprint,
Python and bpy identities, evaluated geometry, render settings, object/modifier evidence, output
types, and diagnostic OS denials. Only that verified result becomes a candidate. The autorun test
uses a real Blender Text side effect: production loading proves the side effect absent, while a
separate isolated `use_scripts=true` process proves the fixture can trigger it.

The child applies hard `RLIMIT_CORE`, `RLIMIT_FSIZE`, `RLIMIT_NOFILE`, `RLIMIT_CPU`, `RLIMIT_AS`, and
`RLIMIT_NPROC=0` limits before importing bpy. The service additionally monitors worker physical
footprint, its own physical footprint, total bytes and files across every worker-writable root, wall
deadline, and the live descendant tree. Recursive accounting includes package descendants, fails
closed on traversal errors, counts the greater of logical size and allocated blocks plus directory
storage, and stops as soon as a byte or file bound is crossed. A violation asks
the exact native supervisor to terminate its directly owned worker and does not yield a candidate.
The verifier rejects excessive evaluated objects/vertices/polygons and
render dimensions/pixels; PNG dimensions and total outputs are checked again in native code.

These are layered, bounded controls rather than a claim of a race-free general-purpose Python
sandbox. `RLIMIT_AS` remains enabled because current XNU carries an address-space size limit in the
VM map; acceptance records the configured limit and an over-allocation outcome so the shipped macOS
behavior is measured. `RLIMIT_NPROC` supplies the kernel fork/spawn barrier for the non-root app
identity. Process-tree polling is cleanup and evidence around that barrier, not a replacement for
it. The service launches a native supervisor while Python is still gated. The host
must record the supervisor's exact PID, bundled executable, XNU start time, and
one-use authorization ID before the service releases the gate. The supervisor is Python's direct
parent, so an in-place `execve` does not change ownership; it also verifies the service parent's PID
and start time and kills/reaps its exact child if that parent dies. On XPC invalidation the service
terminates the supervisor through its live `Process` handle; the host can independently send SIGTERM
only after rechecking the in-memory lease's PID, XNU start time, and executable. The supervisor owns
the only SIGKILL path and validates its unreaped direct child's PID/start identity first. Every
post-launch error unwinds through direct-child cleanup; before a start identity is observable it uses
the live Foundation `Process` handle it just launched, and afterward it signals only the matching
PID/start identity. No
worker-writable registry, global process scan, unrelated PID, or app configuration participates, and
an app restart does not need the lost in-memory lease to reap an old worker.

Primary platform references:

- <https://developer.apple.com/documentation/security/app-sandbox>
- <https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations>
- <https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html>
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c>
- <https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_map_xnu.h>
- <https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h>
- <https://chromium.googlesource.com/chromium/src/+/refs/heads/main/sandbox/policy/mac/common.sb>
- <https://github.com/anthropics/sandbox-runtime/blob/main/src/sandbox/macos-sandbox-utils.ts>

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
`blocked-pending-corresponding-source-evidence`. The lock maps all 43 paths exactly once to candidate
source families, versions, URLs, SPDX licenses, and archive checksums from Blender v5.2.2's official
dependency manifest. Those MD5 or SHA-256 values identify Blender's candidates but are not accepted
as the final SHA-256 distribution closure. The official wheel METADATA links Blender's source, the
v5.2.2 tag resolves to commit `d13f752e3b9c4f8c261cda552b1021f8bcc0382c`, and the lock pins the
release tar, `versions.cmake`, recipes, and patches. That linkage does not prove every actual wheel
build input. The remaining work is to bind the pinned wheel to the actual source archives,
recipes/patches, and configuration, then hash-pin and ship the matching Corresponding Source plus
required notices. Filename or version matching alone is insufficient.

Changing `distributionStatus` to `ready` also requires a complete `distributionClosure`: one
SHA-256- and size-pinned archive mapping every Python-build-standalone source, wheel source, CPython
build input, and bpy native candidate exactly once (shared archives may name multiple components),
repository-hashed binary/source-correspondence and notice/coverage evidence, plus the exact public
source asset.
Declared URLs and existing SHA-256 pins must match the lock; MD5-only Blender-manifest
candidates gain a final SHA-256 pin in this closure. Staging then embeds all archives and evidence,
and bundle verification rehashes them.

Each `sourceArchives` entry carries `components`, `filename`, `url`, `sha256`, and `size`.
Component IDs are `python-build-standalone`, `wheel:<lock name>`,
`python-build-input:<lock name>`, and `bpy-native:<candidate-family name>`. The remaining closure
keys are `wheelBinaryCorrespondence`, `noticeCoverage`, and nonempty `noticeFiles` entries (`path`,
`sha256`), plus `publicSourceAsset` (`filename`, `manifestFilename`, `sha256`, `size`,
`manifestSHA256`). Evidence paths live under `Runtime/bpy/compliance/`.

The deterministic source builder additionally preserves every dependency in the exact Blender 5.2.2
release manifest, including static/transitive candidates, the complete release build recipe/patch
inventory, every installed wheel source and notice, and python-build-standalone/CPython inputs. Its
validator binds these to the exact wheel hash, metadata hash, and `RECORD`. This establishes real
release-input linkage but remains candidate-only until evidence identifies the actual binary inputs.
The ready-state correspondence record may use any robust primary evidence; it does not require a
special upstream per-wheel attestation or a bit-identical rebuilt-binary hash.
The stable release tag itself targets the exact build commit and supplies NexGenVideo's GPL source;
the managed-runtime archive supplies the third-party closure not contained in that repository snapshot.

The distribution gate runs before release builds, including dry runs, and before the managed-runtime
acceptance build/transfer ZIP. Regular public CI does not upload the app or transfer it to the runtime
runner while blocked. Other CI workflows that must transfer a diagnostic app use an explicit
CI-only bundle mode that omits the runtime and embeds an omission marker. Normal dev, acceptance,
and release bundles continue to require the runtime; readiness is never synthesized.

## Prepared Actions acceptance

`.github/workflows/bpy-source-closure-candidate.yml` is a separate manual, SHA-bound Ubuntu path.
It performs only source/notice assembly, independent source-archive validation, and hash-manifest
publication. It does not build or run binaries, access providers or generation services, use secrets,
or bypass the public distribution guard. Its artifacts state `candidate-only` and
`publicDistributionAuthorized: false`.

`.github/workflows/bpy-binary-evidence-candidate.yml` is a separate manual, SHA-bound `macos-26`
path. It downloads the pinned runtime artifacts without building the app, imports only the exact
RECORD-verified `bpy` module, and records `bpy.app.build_hash` plus Blender's exposed library versions.
It uses no provider, generation service, or secret and also emits a non-distributable candidate.

`.github/workflows/bpy-runtime-acceptance.yml` is manual and SHA-bound. Once the source/notice gate is
truthfully ready, its Linux preflight first rebuilds and independently validates the exact pinned
Corresponding Source asset. It then builds and unit-tests on `xcode-27`, assembles the pinned runtime,
signs and notarizes the app, and transfers the matching source asset with it before relocation and
execution on `macos-26` arm64. No local execution is an acceptance substitute.

The runtime probe uses real `VideoProject` instances and windows through `BpyRuntimeHost`. It covers
two slots, a denied third document, failed-open reuse, close/reuse, and AppDelegate shutdown. It also
covers exact and changed duplicate payloads, forged native stdout plus an infinite loop, a persistent
thread, ctypes stdout, a kernel-blocked fork, in-place `execve`, memory over-allocation, timeout,
cancellation, worker crash, service and host kill/reopen cleanup, denied-file host positive controls,
network and cross-container denials, disabled autorun plus isolated positive control, BMesh/modifier
geometry, package-hidden file counts, aggregate writes outside outputs, resource-scan failure/recovery,
the exact `signal` denial for probes 0/SIGSTOP/SIGKILL followed by a healthy job, a supervisor failure
after child start but before identity write followed by a healthy job, and a perspective Cycles render.

Evidence separates host-observed open-to-ready and job durations from service-observed cold start,
worker/verifier wall times, worker/verifier/service footprints, disk/file peaks, and descendant peak.
It also records the host process peak through `getrusage`, package size, OS, hardware, exact runtime
identity, renderer/device result, exact `bpy.app.build_hash`, the Blender-exposed `LibraryVersion`
subset, and distinct worker/verifier PIDs. The build hash must match the official v5.2.2 tag commit;
the exposed library versions must reconcile with the pinned `versions.cmake`. This is evidence for a
subset: the OpenImageIO tuple is less granular than the pinned `v3.1.13.1`, and SDL is not exposed as
a supported library version. It is not an assertion that the release source equals every source
actually used for the wheel.
Until the distribution blocker is resolved and an owner explicitly dispatches the workflow, these
are prepared assertions, not claimed PASS results.
