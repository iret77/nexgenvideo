# Managed bpy runtime

The 3D runtime is a host-owned component, not another engine. The Swift host retains document,
pipeline, provider, approval, and project-write ownership. One persistent Python/`bpy` worker is
created per active runtime session and processes one job at a time. Sessions are explicitly bound
to an NGV document identity. Two differently identified XPC services cap concurrency at two active
3D documents and give each worker a distinct OS sandbox container.

## Security boundary

The app talks only to two embedded `NexGenVideoBpyService` slots. macOS launches each service in
its own App Sandbox and container. Neither has network, user-selected-file, Keychain,
application-group, or temporary-exception entitlements. Each Python child is signed only with App
Sandbox inheritance. Inputs cross the boundary as bounded byte chunks after the host opens a
regular, single-link file without
following symlinks and hashes the exact descriptor bytes. The service writes them into its private
job directory. Outputs return as bounded chunks and the host verifies length, SHA-256, declared
type, and magic bytes into host-owned staging. The worker never receives a project path and never
writes project truth.

The CI probe passes one service's private session path to the other and requires an OS-level
`EPERM`/`EACCES`, in addition to the host-home, foreign-project, canonical-artifact, secret, and
network denials. The child starts with an allowlisted environment, isolated Python flags, empty
Blender config, scripts and data directories, auto-execution disabled, resource limits, and a new
process group. Timeout, cancel, close, crash, and app termination kill that group and its enumerated
process tree. These measures reduce ambient state and clean up work; the OS App Sandbox is the
filesystem/network control.

Apple documents XPC services as private to the containing app, independently sandboxed with
minimal access, and managed by `launchd`. Apple also recommends XPC when a helper needs different
capabilities from its host:

- <https://developer.apple.com/documentation/security/app-sandbox>
- <https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations>
- <https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html>

## Transaction and restart semantics

A Job ID is immutable within a session. A duplicate joins the running job or receives its cached
terminal result; it never executes again. A successful execution is only a candidate. The host
must validate its outputs and explicitly confirm a new revision before another mutating job.
Until confirmation, restart loads the previous confirmed checkpoint. Failed, cancelled, timed-out,
or crashed jobs are terminal and can never be confirmed.

The runtime seam deliberately accepts native `bpy`/BMesh Python rather than inventing a reduced 3D
API. #543 owns the schema-validated agent tool and operation policy above this internal seam; #542
owns portable scene revisions and canonical persistence. This issue adds neither a phase nor a
canonical scene artifact.

## Runtime and distribution

`Runtime/bpy/runtime-lock.json` pins CPython, the `bpy` wheel, every declared Python dependency,
the standalone Python build inputs, source locations, hashes, and licenses. CI extracts wheels
directly; `pip` is absent from runtime assembly and never runs in the installed app. The full
python-build-standalone archive supplies its build manifest and license set for audit. The lock
also records the independently fetched PEP 658 metadata hash and its exact CPython/dependency
contract rather than inferring that contract from the wheel filename.

Public distribution remains fail-closed while the lock says
`blocked-pending-corresponding-source-review`. The unresolved item is concrete: the native
libraries already vendored inside the Blender Foundation wheel still need an exact binary-to-source
and notices mapping. The Blender source tarball by itself is not asserted to settle that duty.

## CI evidence

`bpy-runtime-acceptance.yml` is manual because it consumes the configured current-macOS runner and
signing/notarization credentials. It performs cheap lock/source checks first, then builds via
`scripts/bundle.sh`, verifies nested signatures and sandbox entitlements, notarizes, relocates the
app outside the build directory, and runs the real wheel on Apple Silicon. The self-test covers two
documents, duplicate IDs, confirmation, timeout, cancel, crash/restart, close/quit, denied host
files/secrets/network, foreign Python/Blender isolation, BMesh plus a modifier, and a perspective
render. It records hardware, runtime identity, renderer/device selection, package size, cold/warm
start, edit/render time, and peak memory. GPU/Metal is evidence only if the runtime reports and uses
a Metal Cycles device; otherwise the report identifies and measures the CPU fallback.
