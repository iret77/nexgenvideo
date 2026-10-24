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

Native stdout and stderr are bounded diagnostic streams only. The service observes process termination and native resource limits; worker output cannot set state.
Untrusted exit codes without an observed limit fail the job rather than attest a resource violation. After a zero exit, a fresh verifier opens
`scene.blend` with `use_scripts=false` and independently checks the exact Job ID and fingerprint,
Python and bpy identities, evaluated geometry, render settings, object/modifier evidence, output
types, and diagnostic OS denials. Only that verified result becomes a candidate. The autorun test
uses a real Blender Text side effect: production loading proves the side effect absent, while a
separate isolated `use_scripts=true` process proves the fixture can trigger it.

The child applies hard `RLIMIT_CORE`, `RLIMIT_FSIZE`, `RLIMIT_NOFILE`, `RLIMIT_CPU`, `RLIMIT_AS`, and
`RLIMIT_NPROC=0` limits before importing bpy. The service additionally monitors worker physical
footprint, its own physical footprint, total bytes and files across every worker-writable root, wall
deadline, and the live descendant tree. Recursive accounting uses `getattrlistbulk` to obtain
identity, type, logical size, and allocated size in the same directory-entry operation. Renamed
directories are reopened by `fsgetpath` and verified by device/inode before traversal. Three complete
bounded scans are identity-unioned, stop immediately at the file or byte limit, and fail closed after
bounded unresolved-directory retries. The service joins that scan with the
exact owned worker's regular-vnode descriptors from XNU `proc_pidinfo(PROC_PIDLISTFDS)` plus
`proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)`, and its file-backed mappings from
`proc_pidinfo(PROC_PIDREGIONPATHINFO)`. Device/inode identity deduplicates directory, descriptor, fileport, and mapping views and the
largest observed vnode size wins. Unlinked vnodes remain charged when retained by a writable/read-only
descriptor or by a surviving file-backed mapping. Linked files outside the managed
roots are excluded only when their kernel `FWRITE` bit is clear, so normal external read sources do
not become job storage and an unexpected external writable descriptor fails closed. This does not
trust a worker report, scan unrelated PIDs, or attribute a host-volume delta. PID reuse is excluded
by rechecking the worker's XNU start identity around each bounded traversal; `EINVAL` from the still-
identical process ends the address-space walk only after at least one region. Process end returns no
stale ownership, and visibility or malformed-kernel-view errors fail closed. Normal file renames do
not create a path-to-`lstat` gap; incomplete directory re-resolution, permission failures, entry-level
errors, and malformed attribute records remain fatal.
The service deliberately does not treat cumulative process write-I/O as disk occupancy: overwrites
and healthy temp-file churn can increase it without increasing retained storage. A violation asks
the exact native supervisor to terminate its directly owned worker and does not yield a candidate.
The verifier rejects excessive evaluated objects/vertices/polygons and render dimensions/pixels;
the effective width and height must each be at least one pixel, and this contract is checked before
any render operator runs.
PNG dimensions and total outputs are checked again in native code. Geometry validation registers a
temporary Blender render engine and invokes `bpy.ops.render.render` for every scene and enabled view
layer. Each call binds the expected scene/View Layer identities and must produce exactly one matching
`render(self, depsgraph)` callback before it can contribute a scenario. A scene without an enabled
View Layer is rejected. The callback measures the public render-evaluated dependency graph,
so render-only modifiers, viewport-hidden renderable objects, and non-active scenes do not escape the
bound. The verifier restores scene settings and produces no image.

FD, fileport, and mapping inspection are layered sampled controls. The service uses XNU's
`PROC_PIDLISTFILEPORTS` and `proc_pidfileportinfo` to include retained vnode fileports in the same
(device, inode) inventory. Native acceptance requires either a proven fileport denial or the actual
retained bytes and disk-limit outcome; an allowed but uncounted fileport fails.

Production worker roots now live on a host-created, private APFS sparse image. The host binds image
and parent-directory identity to its lease; the XPC service independently validates the exact mount,
device and `fstatfs` capacity before launching Python. Its virtual filesystem capacity is the requested disk budget or the 64 MiB filesystem floor,
whichever is larger. The smaller logical disk/file monitor remains active for diagnostic budgets. The normal budget is 2 GiB. The host image additionally
permits 64 MiB of format metadata; this is not an assertion that sparse-image metadata has already
been measured on the deployment OS.

Only the non-sandboxed host invokes `hdiutil`; neither Python nor the sandboxed XPC service receives
mount authority. Recovery checks the original host/service start identities, private image inode and
current machine-readable image/device/mount mapping. It never force-unmounts or detaches an arbitrary
device from a serialized path. The separate, non-sandboxed `NexGenVideoBpyStorage` helper atomically
journals its own PID/start identity, rechecks the host, and waits for its directly launched hdiutil
child. The host writes an operation intent before starting the helper; only normal child completion
produces a completed journal. A timeout retains the live helper and lease. The slot directory becomes
visible only after its lease is complete. A helper crash or signalled hdiutil without a completion
record remains quarantined; automatic recovery does not infer safety from the absence of a process.
Ambiguous identities remain blocked; no replacement process or mount is killed.

The mountpoint is inside a private host cache directory, outside the XPC service's writable container.
An implicit security-scoped bookmark grants the service access to the mounted root only. The service
must drain its execution queue before closing that scope. Cleanup obtains a fresh ownership response,
including retiring sessions, from the kernel-identified XPC process; a session-close reply alone does
not authorize unmounting a lease still used by another session.
The host resolves a newly created bookmark before storing it, refreshing stale data once from the
resolved URL. A changed path or a still-stale refresh is rejected. The exact verified bytes enter
both the durable lease and the service request. The service continues to reject stale bookmarks.
Host resolution and service failure diagnostics compare bookmark digests and volume metadata without
recording capability bytes.
This path is prepared for native verification; successful cross-process resolution is not yet proven.
Native acceptance includes a real 64 MiB-volume ENOSPC probe while fileports, Mach memory entries or
queued SCM_RIGHTS retain an unlinked file (or the applicable channel is actually denied). These probes
are prepared but unexecuted. Acceptance still must prove bounded image growth, XPC container access,
all attach/close/crash transitions,
and rejection of replaced image/mount/symlink identities. None of these new volume claims is marked
verified by source inspection. Disk-quota completeness remains a distribution blocker until those
actual macOS 26 results exist. `RLIMIT_AS` remains
enabled because current XNU carries an address-space size limit in the VM map; acceptance records the
configured limit and an over-allocation outcome so the shipped macOS
behavior is measured. `RLIMIT_NPROC` supplies the kernel fork/spawn barrier for the non-root app
identity. Process-tree polling is cleanup and evidence around that barrier, not a replacement for
it. The service launches a native supervisor while Python is still gated. The host
must record the supervisor's exact PID, bundled executable, XNU start time, and
one-use authorization ID before the service releases the gate. The supervisor is Python's direct
parent, so an in-place `execve` does not change ownership; it also verifies the service parent's PID
and start time and kills/reaps its exact child if that parent dies. On XPC invalidation the service
terminates the supervisor through its live `Process` handle; the host can independently send SIGTERM
only after rechecking the in-memory lease's PID, XNU start time, and executable. The supervisor owns
the only SIGKILL path and uses its unreaped direct child's PID/start identity when observable. Every
post-launch error unwinds through direct-child cleanup; before a start identity is observable it uses
the live Foundation `Process` handle it just launched, gives SIGTERM a bounded interval, and then
stops and kills that still-running owned child. A failed later identity query uses the same bounded
handle path; a confirmed mismatched start identity is never signaled. Afterward cleanup signals only
the matching PID/start identity. No
worker-writable registry, global process scan, unrelated PID, or app configuration participates, and
an app restart does not need the lost in-memory lease to reap an old worker.

Primary platform references:

- <https://developer.apple.com/documentation/security/app-sandbox>
- <https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations>
- <https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html>
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c>
- <https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_map_xnu.h>
- <https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h>
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c>
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h>
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fcntl.h>
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/getattrlistbulk.2>
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fsgetpath.h>
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/fileport_makeport.2>
- <https://docs.blender.org/api/5.2/bpy.types.RenderEngine.html>
- <https://docs.blender.org/api/5.2/bpy.ops.render.html>
- <https://docs.blender.org/api/5.2/bpy.types.Context.html>
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
slot. Document close schedules cleanup; confirmed application termination awaits runtime shutdown.
Canonical revisions retain exact scene, snapshot, resources and authenticated host adoption records.
Transport recovery uses only the last confirmed in-memory checkpoint until the host explicitly loads a
canonical revision.

## Runtime and distribution

The immutable Python/bpy tree lives in `Contents/Resources/BpyRuntime`, keeping its internal
library and module paths intact. Every Mach-O in that tree is signed individually before the app's
outer resource seal; bundle verification checks each signature independently. Native supervisor and
storage tools remain in `Contents/Helpers`, and the two services remain in `Contents/XPCServices`.
This deliberately accepts the extra resource sealing described in Apple's
[code-signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/): runtime
updates replace the whole app through Sparkle, never individual files inside the signed tree.
Python bytecode and job output cannot modify that tree. The native signing fixture exercises the
complete resource layout before the full app build; distribution signing and runtime execution still
require their separate Actions gates.

`Runtime/bpy/runtime-lock.json` pins CPython, the `bpy` wheel, all declared Python dependencies,
python-build-standalone inputs, source locations, hashes, and licenses. The wheel entry point is the
RECORD-backed native module `bpy/__init__.so`. The lock also records the exact 43 `bpy/lib/*.dylib`
paths observed in the pinned wheel. Staging requires those exact paths and verifies every entry point
and native library against its wheel `RECORD` hash and size. CI extracts wheels directly; `pip` is
absent from assembly and from the installed app.

The lock is `ready` with an exact qualified source archive and original Actions producer pin.
Every binary transfer still requires the current independent distribution validator. The lock maps
all 43 paths exactly once to candidate
source families, versions, URLs, SPDX licenses, and archive checksums from Blender v5.2.2's official
dependency manifest. Those MD5 or SHA-256 values identify Blender's candidates but are not accepted
as the final SHA-256 distribution closure. The official wheel METADATA links Blender's source, the
v5.2.2 tag resolves to commit `d13f752e3b9c4f8c261cda552b1021f8bcc0382c`, and the lock pins the
release tar, `versions.cmake`, recipes, and patches. That linkage does not prove every actual wheel
build input. The committed correspondence binds measured binary facts and official library evidence
to 20 supported build-input components, explicitly a subset of the 144 conservatively retained source
components. It does not claim exhaustive static linkage or compiler flags. The qualified archive
contains 965 notice entries; its exact bytes and manifest are pinned for reuse and must accompany
the binary release. Qualification does not authorize a release. Filename or version matching alone
is insufficient.

A `ready` lock requires a complete `distributionClosure`: one
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
`manifestSHA256`, the fixed original `releaseTag`, and the exact original Actions `producer`
identity). Evidence paths live under `Runtime/bpy/compliance/`.

The deterministic source builder additionally preserves every dependency in the exact Blender 5.2.2
release manifest, including static/transitive candidates, the complete release build recipe/patch
inventory, every installed wheel source and notice, and python-build-standalone/CPython inputs. Its
validator binds these to the exact wheel hash, metadata hash, and `RECORD`. This establishes real
release-input linkage but remains candidate-only until evidence identifies the actual binary inputs.
The ready-state correspondence record may use any robust primary evidence; it does not require a
special upstream per-wheel attestation or a bit-identical rebuilt-binary hash.
The stable release tag itself targets the exact build commit and supplies NexGenVideo's GPL source;
the managed-runtime archive supplies the third-party closure not contained in that repository snapshot.

One shared validator proves the ready state and revalidates the actual assembled archive, archive
manifest, required notices, and binary/source correspondence before release, full-runtime acceptance,
or a public CI binary upload. Hash-only lock readiness is insufficient. This does not impose blanket
legal approval, a special attestation, or bit-identical rebuild evidence.

The distribution gate runs before release builds, including dry runs, and before any full-runtime
CI app upload. A blocked lock prevents these binary transfers. Replay-only diagnostic builds explicitly
omit Python/bpy with `--without-bpy-runtime-for-ci-transfer`; they cannot provide 3D acceptance.

## Prepared Actions acceptance

`.github/workflows/bpy-source-closure.yml` is a manual/reusable source-evidence workflow bound to
`github.sha`. Its Linux job assembles the exact source/notice closure and independently validates the
archive membership, all hashes, official library evidence and source inventory. Candidate mode also
runs the pinned Python/bpy binary inspector on `macos-26`, uploading JSON evidence only. It does not
upload the wheel or an app. Distribution mode additionally requires committed evidence/notice pins,
complete source-to-notice mappings and the exact public source-archive pin. Candidate notices or
self-declared completion flags cannot authorize distribution. Committed correspondence/notice evidence
can enrich a candidate while the lock remains blocked, so the final archive can be assembled and
hash-pinned before declaring readiness; adding its public pin does not change archive contents.

`ci.yml` and `ci-batch.yml` consume the exact qualified source pair through
`bpy-qualified-source.yml` and `prepare-bpy-source`. Before publication they retrieve the pinned
successful Actions artifact; afterward they retrieve the same bytes from the fixed original release
tag. Every consumer rechecks the current hashes and independent distribution gate. The app is compiled and tested once on
`macrunner`; native bpy and workspace acceptance consume its exact transferred artifact on
`macos-26`. Standalone workspace acceptance can build its own artifact through the same source gate.
The workspace scopes include `all`, `filmreview`, `activity` and `planning`.

`.github/workflows/bpy-runtime-acceptance.yml` is reusable and builds nothing. It verifies the exact
source commit, relocated bundle, runtime and source archives before real runtime execution. Release
invokes it with the signed, notarized and stapled app from its DMG packaging transaction; successful
runtime and diagnostic acceptance are prerequisites for publication. Publication recovery requires the
original acceptance marker, checks its source/DMG binding, then downloads and independently revalidates
the release's corresponding-source assets before advertising that binary again. A failed acceptance
job is resumed in its original run; publication recovery cannot manufacture acceptance.

Actions app, DMG and diagnostic artifacts carry a small source receipt binding the original producer,
public source pins and consuming commit. Workspace qualification validates the full source once on
Linux before native workers consume the bound app; it does not copy the source tar into every test
artifact. Each public binary release carries the exact corresponding-source tar and manifest beside
its binaries. The release tag supplies NexGenVideo's own exact source. No local execution substitutes
for acceptance.

The runtime probe uses real `VideoProject` instances and windows through `BpyRuntimeHost`. It covers
two slots, a denied third document, failed-open reuse, close/reuse, and AppDelegate shutdown. It also
covers exact and changed duplicate payloads, forged native stdout plus an infinite loop, a persistent
thread, ctypes stdout, a kernel-blocked fork, in-place `execve`, memory over-allocation, timeout,
cancellation, worker crash, service and host kill/reopen cleanup, denied-file host positive controls,
network and cross-container denials, disabled autorun plus isolated positive control, BMesh/modifier
geometry, package-hidden file counts, aggregate writes outside outputs, resource-scan failure/recovery,
open-unlinked writes with a healthy following job, native no-bpy writable/read-only/mapping-retained
unlinked resources, linked internal writable deduplication, a linked external read-only control, and
fileport-retention denial/accounting, bounded-volume ENOSPC with fileports, Mach memory entries and
queued SCM_RIGHTS (or an actual channel denial), healthy concurrent nested-directory rename/delete temp churn, adversarial
closed-file rename churn above quota,
render-only modifier geometry, viewport-hidden renderable geometry, a second scene, and legitimate
user mesh geometry carrying the verifier-camera name prefix, zero effective resolution, and a scene
without an enabled View Layer,
the exact `signal` denial for probes 0/SIGSTOP/SIGKILL followed by a healthy job, a supervisor failure
after child start but before identity write followed by a healthy job, an unavailable child identity
with a TERM-ignoring owned child followed by a healthy job, and a perspective Cycles render.

Evidence separates host-observed open-to-ready and job durations from service-observed cold start,
worker/verifier wall times, worker/verifier/service footprints, disk/file peaks, and descendant peak.
It also records the host process peak through `getrusage`, package size, OS, hardware, exact runtime
identity, renderer/device result, exact `bpy.app.build_hash`, the Blender-exposed `LibraryVersion`
subset, and distinct worker/verifier PIDs. The build hash must match the official v5.2.2 tag commit;
the exposed library versions must reconcile with the pinned `versions.cmake`. This is evidence for a
subset. The separate, committed official-library evidence binds all 43 wheel dylibs byte for byte to
the release's arm64 submodule and its exact dependency manifest, including full `v3.1.13.1` OpenImageIO
and `3.4.2` SDL versions. This does not relabel every conservative platform-specific source archive
as an actual linked input.
Until the distribution blocker is resolved and an owner explicitly dispatches the workflow, these
are prepared assertions, not claimed PASS results.

## Scene authoring and Clay provenance

Scene reads, full inventory/receipt hashing, staging and resource copies run off the main actor. A
held phase mutation lease and source fingerprint bind preparation to the current canonical state;
final publication checks canonical identities and uses an atomic directory exchange. A committed edit
updates Undo/Redo even if cancellation arrives after the commit.

Each camera keeps its own render dimensions. Saved frame and scene rest frame are distinct. Native
transform edits evaluate the viewed frame first and key the object's actual Euler/quaternion/axis-angle
channel; hidden NLA/driven edits and unkeyed animated edits fail visibly. Input-resource receipts bind
the exact bytes actually staged in the runtime job.

Bible and Storyboard geometry use the saved rest frame. Shot Planning passes a complete resolved
`SpatialClayState`: exact scene-manifest hash, camera, frame sequence, every object's world pose and
camera field of view. The render copy clears transform animation before applying that state, rejects
constraints/physics, and records evaluated poses. The host authenticates the actual runtime job,
render command, executable/script hashes and output PNGs before a canonical owner can adopt them.
Persisted host adoption evidence is separate from agent-authored JSON. The camera-snapshot hash binds
the camera at scene save time; per-frame render poses record the camera actually used for each image.

PNG frames are authoritative. MOV is a decoded/validated H.264 preview with explicit rational timing
and BT.709 color metadata; it is not a lossless or pixel-identical substitute. Blender's float32 FPS
base is reconstructed as a small rational only when that value round-trips to the identical stored
float32. Native acceptance requires 24000/1001 timestamps, real GLB import, quaternion keys, a child
edit under an animated parent at the viewed frame, separate camera dimensions, stable rest frame,
resource authentication, and divergent rendered pixels for an explicit state overriding animation.
These new acceptance cases are prepared, not yet passed.

Complete Shot Planning renders use a file-backed sequence candidate. Deterministic internal chunks
respect the per-job frame/pixel envelope; the shot itself is not truncated or resampled. Each chunk
is authenticated before checkpoint rotation discards its runtime cache. A private host aggregate
binds the full request/state, ordered chunk receipts and every output byte. The final MOV streams
from PNGs and is decoded frame by frame against them, including exact rational PTS and the final
partial sample duration from canonical story timing. Canonical adoption copies the complete output
map before calling `discard()`; discard revokes its receipt and schedules removal of temporary files.
Native acceptance includes 241 frames at 384×384, beyond both former whole-shot limits, a partial
last frame, substituted-image rejection and receipt revocation. This acceptance is prepared, not run.

## Document and application shutdown

Document unregister returns immediately; the host closes its XPC session and releases its bounded
volume on a detached task. The service slot stays reserved until cleanup succeeds, including when
startup and document close overlap. Cleanup errors remain visible, retain their lease, and can be
retried through `BpyRuntimeHost.retryCleanup()` or another application Quit. A partially created
image follows the same ownership-checked recovery path; it is not treated as an unused slot.

Storage intents bind a unique operation ID and the kernel boot-session UUID. The helper holds an
exclusive journal lock and verifies the current intent before starting hdiutil; a delayed helper
cannot overwrite a newer operation. A live operation stays reserved. A dead helper without a normal
completion record stays reserved for the current boot and shows a Save/Restart recovery instruction.
After a proven boot change, recovery still checks the persistent host-volume UUID, directory/image
inodes, ownership and actual image/mount mapping before cleanup. A timeout alone never releases it.

`shutdown()` remains false when storage is retained. `canQuitWithReservedStorage` only permits the
application to offer an explicit Quit-with-reserved-storage choice after verified service/worker
ownership ends and every remaining failure requires restart recovery. Live or unknown ownership
never permits that choice. Quit does not claim cleanup and never detaches the unresolved volume.
After explicit confirmation, `confirmQuitWithReservedStorage()` rechecks that state and prevents new
operations before the delegate replies. Cancel leaves that barrier unset. Live or unverifiable
ownership cancels normal Quit and retains its recovery alert; no forced cleanup is offered.
After a real OS restart, the next allocation of that slot retries recovery; a relaunch within the same
boot does not permit recovery without a completion record.
Prepared native controls exercise the real helper's normal completion, stale nonce rejection,
journal lock and killed-helper retention. Boot-transition classification and the Quit eligibility
matrix have unit regressions; no test here claims to have rebooted the CI host.

`BpyRuntimeHost.shutdown()` is async and returns whether all slots were released. The application
delegate returns `terminateLater`, awaits this result, and replies exactly once; failure cancels
termination and presents recovery information. It does not repeat shutdown in `applicationWillTerminate`.
Apple's current [`NSApplication.terminate(_:)` contract](https://developer.apple.com/documentation/appkit/nsapplication/terminate(_:))
asks the document controller to handle unsaved changes before `applicationShouldTerminate` is called.
Runtime shutdown therefore starts only after Save/Discard consent; Cancel preserves runtimes for
any documents that remain open. Native acceptance must cover this order, active-job termination,
startup/close overlap, cleanup failure and retry, and an actually detached volume before slot reuse.
