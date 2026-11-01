# Managed bpy runtime

The 3D runtime is a host-owned component, not another engine. The Swift host retains document,
pipeline, provider, approval, and project-write ownership. Two separately identified XPC services
cap concurrency at two active `VideoProject` documents. Each job starts a new Python/`bpy` process
from the last host-confirmed scene and a separate new process verifies the resulting scene. No
Python interpreter, handler, module state, thread, or monkeypatch is reused by the next job.

The host-launcher and `system-pressure-v1` changes are under review. The native checks described
below are acceptance requirements; this source has not yet passed them.

## Trust boundary

The app talks only to the two embedded `NexGenVideoBpyService` slots. Each service has its own App
Sandbox container and has no network, user-selected-file, Keychain, application-group, or temporary-
exception entitlement. The unsandboxed app owns the native supervisor; the service requests launches
through the existing reverse-XPC monitor. Supervisor and Python signatures have no App Sandbox
inheritance or code-signing exception entitlements. The supervisor's child applies a deny-default
Seatbelt profile before executing Python. It grants writes only to that execution's worker-volume
root and exact read access to its staged inputs, checkpoint, frozen configuration and runtime.
It also grants read, existence checks, and executable mapping to the OS cryptex at
`/System/Cryptexes/OS` and `/System/Volumes/Preboot/Cryptexes/OS` for the worker's lifetime.
Read and existence checks for `/` and the intermediate directories use exact directory matches.
Network, fork, foreign-process signals and undeclared IPC remain denied. Provider keys are absent
from the host-built environment. No canonical project path or write capability reaches the worker.

The host supplies a fixed, nonidentifying `USER=nexgenvideo`. Blender 5.2.2's
[vendored glog initializer](https://github.com/blender/blender/blob/v5.2.2/extern/glog/src/utilities.cc)
otherwise queries the account database and can dereference a missing result inside Seatbelt.
No account name or inherited environment is needed for native-library initialization.

The host also fixes `CYCLES_METAL_ASYNC_PSO_CREATION=0` before loading bpy. Blender 5.2.2
[reads this flag](https://github.com/blender/blender/blob/v5.2.2/intern/cycles/util/debug.cpp)
to select its existing [synchronous Metal pipeline-creation path](https://github.com/blender/blender/blob/v5.2.2/intern/cycles/device/metal/kernel.mm).
The unrestricted fresh-first comparison hung in the configured GPU render with the default
asynchronous path; changing only this flag completed the same scene without entering its CPU
fallback. This keeps Metal rendering, scene quality and execution limits intact. A subsequent
[cold constrained App run](https://github.com/iret77/nexgenvideo/actions/runs/41261960051)
completed the GPU scene and trusted verification in 19.6 seconds under the original 120-second
limit. That run then failed the staged-input protocol probe; full native qualification remains open.

Each XPC bundle contains its own `Contents/Resources/BpyRuntime` and its supervisor in
`Contents/MacOS`. No runtime executable or script falls back to the outer app bundle. The two
runtime copies use identical signed bytes; the outer app seals their exact paired inventory in
`Contents/Resources/BpyRuntimeCompliance/runtime-tree-manifest.json`. Corresponding source and
license evidence live once in that shared compliance directory. Bundle verification checks both
copies, their signatures and expected entitlements, and the shared source closure.

The service requests kernel process measurements through its existing XPC connection back to the
host. The host binds each observation to the actual connection peer, service slot, execution nonce,
kernel start identities, parent relationships and executable paths. An epoch and monotonic request
sequence prevent reuse across executions. Unknown or failed kernel views fail the execution; they
never become zero usage. The host owns pressure admission, child release and process cleanup.
The service retains directory scanning and disk/file accounting. Python cannot submit trusted
measurements or select processes for inspection.

The host and supervisor spawn their direct children through an owned POSIX handle. Exit
observation keeps the child unreaped until the owner collects its status, so a signal cannot target
a recycled PID. Separate host-owned release pipes gate the supervisor and its child. Both volume
journals contain the exact process identities before release. Configuration and source descriptors
bind the launched job to host-verified bytes; no service-writable authorization file grants execution.
The host coordinates its own process launches and pipe creation under one spawn lock. Parent loss is
detected through `getppid` and an inherited pipe, without inspecting a foreign process from inside
the sandbox. The supervisor stops and reaps its worker before exiting; the service never escalates
to killing the supervisor while its worker might survive. Failed cleanup retains the slot and its
storage. The host observes process exit and does not signal a foreign PID.

### Concurrent host launch inventory

The source audit covers the pinned dependencies as well as the app's coordinated `Process` sites.
CLI metadata probes use the owned-child launcher and share one five-second status deadline.
Version output uses bounded nonblocking reads; stdin and stderr use the null device. Timeout
cleanup keeps child ownership through termination and reaping. Chat startup only locates the binary.
[Sparkle 2.9.1's framework build phase](https://github.com/sparkle-project/Sparkle/blob/066e75a8b3e99962685d6a90cdd5293ebffd9261/Sparkle.xcodeproj/project.pbxproj)
includes [SUInstallerLauncher](https://github.com/sparkle-project/Sparkle/blob/066e75a8b3e99962685d6a90cdd5293ebffd9261/InstallerLauncher/SUInstallerLauncher.m),
which submits helper jobs through `SMJobSubmit`. The located production `NSTask` sites belong to its
separate Autoupdate executable. The framework source therefore supplies no identified direct-child
spawn that bypasses the app's spawn lock. This does not establish how opaque Apple frameworks create
their processes.

[Sentry 8.58.2's fatal-signal inventory](https://github.com/getsentry/sentry-cocoa/blob/cf44aa8cb4147f39e698c1f28be0b6b2c89f79d2/Sources/SentryCrash/Recording/Tools/SentryCrashSignalInfo.c)
excludes `SIGCHLD`; its inspected Sources contain no direct spawn or foreign-child reaper. The package
uses a binary distribution, so source inspection alone does not qualify the shipped bytes.
[MCP Swift SDK 0.12.0's StdioTransport](https://github.com/modelcontextprotocol/swift-sdk/blob/6132fd4b5b4217ce4717c4775e4607f5c3120129/Sources/MCP/Base/Transports/StdioTransport.swift)
uses supplied descriptors without spawning a child. The app's CLI wrappers own those launches.

These findings are source evidence. The deployed macOS `Foundation.Process` implementation remains a
native qualification target: [swift-corelibs-foundation builds for non-Darwin platforms](https://github.com/swiftlang/swift-foundation#foundation-framework),
so its source cannot prove Apple's deployed descriptor-inheritance behavior. Native simultaneous
launch and descriptor-isolation controls remain required.

Native stdout and stderr are bounded diagnostic streams only. The service observes process termination and native resource limits; worker output cannot set state.
The service addresses the signed `python/bin/python3.13` executable directly. Opening a session
records separate access checks for that file, the `python3` alias, supervisor, worker and site-packages,
bound to the service process and session. These diagnostics preserve the four startup guards and
record only fixed resource roles and numeric results, not paths or bookmark capabilities.
Untrusted exit codes without an observed limit fail the job rather than attest a resource violation. After a zero exit, a fresh verifier opens
`scene.blend` with `use_scripts=false` and independently checks the exact Job ID and fingerprint,
Python and bpy identities, evaluated geometry, render settings, object/modifier evidence, output
types, and diagnostic OS denials. Only that verified result becomes a candidate. The autorun test
uses a real Blender Text side effect: production loading proves the side effect absent, while a
separate isolated `use_scripts=true` process proves the fixture can trigger it.

The child applies hard `RLIMIT_CORE`, `RLIMIT_FSIZE`, `RLIMIT_NOFILE`, `RLIMIT_CPU`, and
`RLIMIT_NPROC=0` limits before importing bpy. `system-pressure-v1` imposes no address-space or
fixed per-process footprint ceiling. Footprints remain observations. The host monitors system
pressure, deadlines and exact owned processes; the service accounts for total bytes and files
across every worker-writable root. Recursive accounting uses `getattrlistbulk` to obtain
identity, type, logical size, and allocated size in the same directory-entry operation. Renamed
directories are reopened by `fsgetpath` and verified by device/inode before traversal. Three complete
bounded scans are identity-unioned, stop immediately at the file or byte limit, and fail closed after
bounded unresolved-directory retries. The service joins that scan with host measurements of the
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
The runtime workflow also invokes the bundled service's fixed directory-deletion probe directly.
It first traverses a nested file, then deletes that queued directory before the real scanner resolves
its inode. Exact event order, retained-file identity/bytes and a healthy three-snapshot followup are
required. This checks the native directory scanner on macrunner and records the actual OS; it does not substitute for XPC or bpy execution.
The retained-runtime preflight rejects changes to this service's source. Earlier app artifacts remain
bound to their earlier harness; they cannot supply this new probe's evidence.
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

FD, fileport, and mapping inspection are layered sampled controls. The host uses XNU's
`PROC_PIDLISTFILEPORTS` and `proc_pidfileportinfo` to include retained vnode fileports in the same
(device, inode) inventory. Native acceptance requires either a proven fileport denial or the actual
retained bytes and disk-limit outcome; an allowed but uncounted fileport fails.

Production storage uses two separate host-created APFS sparse images: a worker image and a data
image, each with its own role, lease, device and recovery journal. The host binds image and
parent-directory identity to each lease; the XPC service independently validates both mounts,
devices and `fstatfs` capacities before execution. Worker capacity is the requested disk budget or
the 64 MiB filesystem floor, whichever is larger. The smaller logical disk/file monitor remains
active for diagnostic budgets. The default worker budget is 2 GiB and the default data image is
5 GiB. The data formula includes 64 MiB for bounded control files and formatting; its adequacy
requires native capacity evidence. An incomplete or mismatched pair cannot launch Python.

Only the non-sandboxed host invokes `hdiutil`; neither Python nor the sandboxed XPC service receives
mount authority. Recovery checks the original host/service/supervisor/worker start identities, private image inode and
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
both the durable lease and the service request. For the transient cross-process handoff, the service
requires a file URL, the exact mount path, matching bookmark/live volume UUIDs, and the kernel-opened
directory's owner, device, APFS mountpoint and capacity. Receiver staleness is diagnostic metadata,
not resource identity: the same bytes can resolve fresh in the host and stale in the sandbox.
This follows Apple's [temporary cross-process bookmark handoff](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox):
resolution starts implicit access, and the service balances it when the paired storage is released.
The kernel rejects symlinks anywhere in the path using `O_NOFOLLOW_ANY`; opening the mounted directory
does not require read access to ancestors outside the bookmark's granted subtree.
Host resolution and service failure diagnostics compare bookmark digests and volume metadata without
recording capability bytes.
Native acceptance requires PID- and session-bound evidence that the first sandboxed open is denied
before resolving the bookmark and that the same mount passes all checks afterwards.
The worker and data roles each prove that transition with their own lease ID, device, capacity and
exact host bookmark digest; one role cannot stand in for the other. Both roles remain bound to the
same original preparation, connection owner, service PID/start and event order. Forged device,
capacity and path leases must fail on fresh session IDs at the storage validation stage, with the
specific Cocoa identity error; missing-path or later session failures cannot satisfy those controls.
Their evidence stores bookmark hashes only.
The runtime kernel must reject both ancestor and leaf symlinks while permitting a searchable but
unreadable ancestor. The existing host-crash, sandbox-denial and physical-storage probes still apply.
This path is prepared for native verification; successful cross-process resolution is not yet proven.
Native acceptance includes a real 64 MiB-volume ENOSPC probe while fileports, Mach memory entries or
queued SCM_RIGHTS retain an unlinked file (or the applicable channel is actually denied). These probes
are prepared but unexecuted. Acceptance still must prove bounded image growth, XPC container access,
all attach/close/crash transitions,
and rejection of replaced image/mount/symlink identities. None of these new volume claims is marked
verified by source inspection. Disk-quota completeness remains a distribution blocker until those
actual macrunner results exist, with the runtime OS recorded. The controlled virtual-mapping case requires exactly 8 GiB of untouched
`PROT_NONE` address space and its deallocation, with no enforced `RLIMIT_AS` ceiling. It does not
allocate 8 GiB of physical memory. `RLIMIT_NPROC` supplies the kernel fork/spawn barrier for the non-root app
identity. Process-tree polling is cleanup and evidence around that barrier, not a replacement for
it. The host launches a native supervisor while Python is still gated. It records the supervisor's
exact PID, bundled executable and XNU start time in both durable role journals before releasing the
supervisor. The child's exact identity is recorded before its separate release. The supervisor is Python's direct
parent, so an in-place `execve` does not change ownership. A retained parent pipe and `getppid`
identify parent loss without a sandbox-denied foreign-process query. On XPC invalidation the host
requests termination through its owned POSIX handle, drains prior monitor requests on the monitor's serial queue,
and observes both the supervisor and every recorded worker exiting; it never signals a foreign PID.
A retained detach receipt can be fetched again after a lost reply. The owned child handle separately
records normal exit and signal death; only normal supervisor exit proves local child cleanup when
the host connection has already disappeared. The supervisor alone escalates termination of
its unreaped direct child, then waits for the exact `waitpid` result before exiting. Cleanup failures
retain the owner, session slot and storage until reaping succeeds. Reverse-XPC replies remain serviceable during close, cancel, retirement and shutdown.
Logical retirement blocks ordinary calls and late replies while the captured connection serves cleanup.
Owner close first performs its session-close exchange with the existing ten-second bound; other retirements
perform it after host reaping within the remaining original five-second awake budget, before connection invalidation;
an unacknowledged close leaves the service's ownership and retirement gates in force. Checkpoint
and upload hashing still run synchronously, when no worker is executing. A host observation lease includes the
connection, execution nonce, epoch, sequence and kernel process identities. Completed processes,
including unreaped zombies, are distinguished from unreadable live processes; permission errors never
become a successful zero-resource sample. No worker-writable registry or global process scan owns
termination authority.
Recovery covers the supervisor and its single recorded worker; the kernel fork barrier prevents
additional Python descendants. Detach receipts are bounded by the 65,536-execution transport cap.
Recovery waits for asynchronous spawn completion, report EOF and exact worker-exit proof within the
earliest original cleanup deadline. Queue delay consumes that same five-second budget; a supervisor's
exit alone never completes recovery. Service-death probes separately stop a still-held launch and
an exec-replaced worker. The latter writes an atomic marker; both probes independently check the
captured process identity after recovery.
If an external actor forcibly kills
the supervisor while its transport is lost, a surviving worker or unavailable cleanup proof retains
the service slot and storage for restart recovery. This case does not authorize foreign-PID signals
or a successful cleanup claim.

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

The service creates an input directory for every executed job, including jobs with no input files.
The host opens that exact directory on the trusted data volume with no symlink
traversal and validates its device, owner, and directory type. Its literal read grant permits
enumerating staged input names; reading each file still requires that file's separate grant.
The frozen job configuration requires the directory grant before launch.

A Job ID is immutable within a session. Its SHA-256 fingerprint length-prefixes the protocol tag,
expected confirmed revision, requested and effective timeout, exact source bytes, ordered input
names/sizes/hashes, and diagnostic options. The client and service compute it independently. An identical retry joins
the existing job or retained result; the same ID with a different fingerprint fails closed. IDs are
never evicted and silently re-executed. A session accepts at most 1,024 Job IDs, after which the
document must explicitly call the confirmed-state rotation path. Rotation is refused without both
the host-confirmed revision and exact scene bytes, or while an unconfirmed candidate exists; only a
successful explicit rotation clears the prior session's ID tombstones.

Successful execution produces only an awaiting-confirmation candidate. File-backed results remain
owned until explicit transfer, rejection or release. There is no time-based expiry or eviction of
live results. Reserve one job's maximum output before launching; per-slot retained capacity is
`min(diskBytes, 4 * outputBytes)`. Exhausted capacity asks the caller to release owned results.
Physical files, read pins and transfer overlap remain charged until disposal or acknowledgment
actually completes. Compact Job ID/fingerprint receipts prevent a released result from running again.
Confirmation checks the host-staged scene hash and retains its exact checkpoint file in the service
and host. Failed, cancelled, timed-out, resource-limited, crashed or rejected jobs cannot be confirmed.

XPC interruption, invalidation, timeout, and service death retire the transport. A live reverse endpoint
remains available for authenticated cleanup through the bounded close exchange. The service
also closes only the session IDs owned by a client connection when that connection disappears. Reopening uses
a new transport/session identity and restores only the host's exact last-confirmed scene bytes and
revision. An incomplete revision/checkpoint pair fails closed. A failed open removes the service
session; a client that exhausts both open attempts closes its transport and no longer occupies a host
slot. Document close schedules cleanup; confirmed application termination awaits runtime shutdown.
Canonical revisions retain exact scene, snapshot, resources and authenticated host adoption records.
Transport recovery restores the last confirmed checkpoint file until the host explicitly loads a
canonical revision. Intentional rotation preserves independently transferred host derivatives;
unexpected transport loss invalidates untransferred results. Document close invalidates all its leases.

## Automatic memory control

The primary observation is an exact UInt32 read of `kern.memorystatus_vm_pressure_level`:
normal `1`, warning `2`, critical `4`. Dispatch pressure events supplement that reading. A critical
event latches a stop even when combined with other flags; a normal event cannot authorize work.
Unknown pressure fails closed. New releases require a sample no older than 250 ms. An independent
watchdog stops active work after 2.25 awake seconds without a valid observation; a historical gap
does not override a valid reading already published before the decision.

Normal pressure admits two logical executions; warning admits one new execution. A worker and its
fresh verifier share that execution's permit, including optional diagnostic autoexec. Critical pressure
requests both owned supervisors to stop before waiting for either. Stop decisions remain irreversible.
Cleanup has its original five-second awake deadline. Unproved owned-process or storage cleanup
blocks new work; a slow host media reader or encoder retains its own file pins and failed consumer
without preventing the other document from making progress.

The admission deadline and running deadline are distinct. Probes use the session's admission budget
and a 120-second child budget. Collection may finish through `T + 15` only after all owned children
have ended before `T`; one final bounded status read observes the original deadline without extending
it. No stopped job retries automatically or reduces its quality.

A launch failure after admission and before the first child release ends the accepted job as failed once
cleanup is proven. Unlaunched launch refusals and environmental stops still fail admission.

Cancellation requests process cleanup without retiring the executing call's admission. The call keeps
its permit through its last receipt read, including when cleanup finishes first. The executing call owns
the permit before monitor installation so installation failures also retire unpublished permits. Each live host
launch independently retains that same canonical permit until its terminal replay or launch-failure record exists,
or its launcher is torn down.
Caller completion and process cleanup cannot remove a receipt still needed for service sampling or detach. Native acceptance
pauses a running caller before a receipt read, completes cancellation and cleanup, then resumes that
same caller and verifies cancellation, absent child processes and final permit retirement.

Runtime and canonical scenes use streamed, hash-verified files. Worker storage stays independently
bounded by `W = diskBytes`, with its existing 64 MiB image floor. The separate data image provisions
`ceilGiB(I + 3 * max(I, O) + min(W, 4 * O) + 64 MiB)`, at most 8 GiB per image. Sequence-owned
staging has independent disk accounting and may exceed one job's retained-output allowance.
Decoding reserves per-frame capacity before allocation; encoding streams frames rather than retaining
an array of all decoded images.

Productive execution, download, validation and bounded cleanup own observed ProcessInfo activities.
Waiting for user confirmation owns none. Persisted media validation follows the document's working-copy
generation and operation cancellation, including transaction staging; reading a saved image or hashing
the runtime does not reserve a Blender slot. Closing a document cancels these reads before waiting for
phases to settle. Readers and encoders retain their physical files until their cancellation APIs return.

Native evidence records the actual OS version/build/kernel, architecture, image status, pressure source
and UInt32 length, observed per-role footprints, swap, both clocks, activity lifetimes, stop grounds,
request times and original cleanup state. Controlled critical-pressure cases are synthetic. Bounded
native malloc and Python small-allocation probes use a measured baseline plus 128 MiB as the diagnostic
threshold, baseline plus 256 MiB as the observed safety threshold, a 256 MiB maximum request and
4 MiB touched chunks. These are diagnostic bounds, not production memory budgets. The safe acceptance
plan proves no genuine system-wide critical-pressure delivery or forced-sleep behavior.

## Runtime and distribution

Each XPC service owns an immutable Python/bpy tree in its own
`Contents/Resources/BpyRuntime`, preserving internal library and module paths. Its supervisor resides
in that service's `Contents/MacOS`. Only the storage helper remains in the app's `Contents/Helpers`.
Every runtime Mach-O is signed once, then the exact signed bytes are copied to the second slot;
verification compares both trees and their app-sealed inventory. Source archives and licenses are
shared in the outer `Contents/Resources/BpyRuntimeCompliance`. Resealing validates an existing
inventory before signing, then atomically replaces it after checking the new paired trees. This is
build-time verification plus the app's code-signing seal, not a claim of a complete startup rehash.
Geometry evidence may select slot zero only because distribution verification requires byte parity.

Runtime updates replace the whole app through Sparkle, never individual files inside the signed tree.
Python bytecode and job output cannot modify it. The native signing fixture exercises the complete
resource layout; distribution signing and runtime execution retain their separate Actions gates.
Historical original-app diagnostics stay bound to their original sources. Their harness-only reuse
gates reject this product/bundle change; an old host-level runtime cannot qualify the new layout.

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

Owned bpy acceptance processes select the normal `-hangDiagnosticMode disabled` preference for
that launch only, including the derived boundary fixture; the choice is not persisted. Ordinary
first-launch consent is unchanged. The independent main-thread hang watchdog stays active and its
reports and samples are still collected. The recorder stays off because this self-test deliberately
blocks the main actor; recorder recovery or startup-failure dialogs would block its continuations.

The first scene's actual response and staged output names are saved to
`acceptance-scene-response.json` before its result gate, including when that gate fails.
The full Actions self-test also retains each accepted job on the client's `runJob` → `finish` path in
immutable `job-response-*.json` files: the client result, last successfully decoded server reply and host permit
decision. `finishReturned` describes terminal handling; missing responses and permit receipts are
explicitly marked unavailable, and a thrown error is retained. Only the last reply is retained, up to
8 MiB; oversized replies are marked as not retained. `warm-job.json` identifies the warm no-op job
before execution. When the self-test run fails before shutdown, `runtime-failure-observation.json`
preserves the partial resource trace. These diagnostics are not acceptance evidence; the complete
result gates remain unchanged. A failed protocol-probe terminal state also writes one partial
`job-response-*.json` record behind the same CI, self-test and evidence-directory gate: the last
successfully decoded reply up to 8 MiB, the initial replay response, no permit receipt and
service-declared output names. It is diagnostic data, not acceptance evidence.

Cross-document isolation uses the other document's retained confirmed scene file. Its host-visible
SHA-256 must match the first trusted verification before the second document runs, and the second
verifier must report a permission denial for that same file. `native-duplicate-replay.json` records
the actual confirmed replay and changed-source refusal; `native-cross-document-denial.json` binds
the host scene hash and path to the second document's verification.
Both records are diagnostic localization aids behind the self-test evidence gate; they do not
replace acceptance evidence or the complete result gates.

The runtime driver binds the verifier's configuration to the exact worker volume, slot, session
and original scene job recorded by the protocol and scene receipts. The session root remains on
the separate data volume.

`.github/workflows/bpy-source-closure.yml` is a manual/reusable source-evidence workflow bound to
`github.sha`. Its Linux job assembles the exact source/notice closure and independently validates the
archive membership, all hashes, official library evidence and source inventory. Candidate mode also
runs the pinned Python/bpy binary inspector on `macrunner`, uploading JSON evidence only. It does not
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
`macrunner`, recording the runtime OS actually used. Standalone workspace acceptance can build its own artifact through the same source gate.
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

Failed startup probes retain their bounded process output, exit status, launch stage and validation
stage in the existing service response. Native CI saves the exact failed response with its source,
session and SHA-256 in the diagnostic artifact; it never records the open request or its bookmarks.
In all three native CI modes, failed kernel inspections and stream reads also retain the original
error domain/code, operation, target PID and available query results and raw errno in a 128-event
host buffer. Launch observation and stream-read failures add the execution, permit and process
identities. Open/job failure diagnostics and the full self-test's partial trace include this buffer
with an explicit overflow flag. Each failing native self-test catch path (boundary, host-crash,
full run) also saves it as `host-inspection-failures-*.json`. Capture performs no file I/O on the
observation path and does not change stop decisions or process cleanup.
Typed pending exits for an exact recorded supervisor or worker PID and birth, after observed
termination or a terminal launch stage, are retained separately as `expectedTerminalExits` rather
than inspection-failure `events`. This separate 128-record buffer deduplicates the same execution,
permit, operation, role and process identity and shares the inspection overflow flag. It uses the
same three CI-mode gates and never adds an activity begin/end event. Pending-exit context includes
the actual pending PID, birth, known owner and observed termination. Unmatched process identities
and operating-system errors remain inspection failures; a reported but uncaptured child is unmatched.
Native failure diagnostics also bind OS child reports to the recorded PID, parent, launch/crash
interval and known supervisor or Python image. Missing reports stay explicit. Capture preserves the
original failure and cancellation; a spawned-child announcement does not establish Python readiness.

Probe and scene-verification manifests encode `bpyVersion` as `major.minor.micro` from
`bpy.app.version`. `bpy.app.version_string` is display text and can include an `LTS` suffix.
The host still requires the exact pinned version.

Their `bpyModule` identity is the bundled native extension loader's path, captured before that
exact loader creates and initializes Blender. Blender replaces its module metadata with the Python
facade during startup; the facade's `__file__` is not the loaded native image. Preloaded modules,
non-native loaders and mismatched native paths are rejected before initialization.
The exact finder paths must agree, and a leaf-only `lstat` requires a regular native file;
this does not require access to metadata outside the runtime subtree.

The runtime probe uses real `VideoProject` instances and windows through `BpyRuntimeHost`. It covers
two slots, a denied third document, failed-open reuse, close/reuse, and AppDelegate shutdown. It also
covers exact and changed duplicate payloads, forged native stdout plus an infinite loop, a persistent
thread, ctypes stdout, a kernel-blocked fork, in-place `execve`, bounded footprint observation,
untouched virtual mapping, injected pressure/observer failure, timeout,
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

The deformation acceptance fixture uses one scene, one view layer, and an explicit frame interval
containing its rest frame. A render-hidden mesh remains in the portable snapshot but must not enter
evaluated geometry. Separate native jobs require verifier rejection of a second scene, a second view
layer, and a rest frame outside the interval; their exact programs and responses are retained.

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
from PNGs and is decoded frame by frame against them. Each exact rational presentation interval ends
at the next decoded frame's output PTS or the independently loaded video track end. Decoded buffers
may omit duration; a known nonfinal output duration must equal its interval exactly. Only the final
coded sample may extend past the verified track end. Independent native acceptance checks coded timing
and separates zero-sample controls from frames. A leading boundary has PTS zero before the first
frame and no active recognized end flags or notification. Flag values must be CFBoolean.
Decoder-drain (CFBoolean true) and consumption
notification (an opaque CFDictionary) occur after all frames; their PTS may be absent, otherwise it
must equal the verified track end. The permanent end carries both EmptyMedia and PermanentEmptyMedia
flags and the exact track-end PTS. Every control has numeric zero raw/output duration and no format,
data or image payload. Each role occurs at most once; every other zero-sample buffer fails.
Both paths require the exact frame count, track range, total
duration and end of stream; the decoded verifier also checks every image. Canonical adoption copies the complete output
map before calling `discard()`; discard revokes its receipt and schedules removal of temporary files.
Native acceptance includes 241 frames at 384×384, beyond both former whole-shot limits, a partial
last frame, substituted-image rejection and receipt revocation. This acceptance is prepared, not yet passed.

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
