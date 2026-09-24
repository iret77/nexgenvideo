# Managed bpy source closure

Public binary distribution remains blocked until the lock is `ready` and the source-closure
workflow validates the exact public source asset. This is a technical distribution gate, not a
request for generic legal approval.

The pinned PyPI metadata identifies `bpy` 5.2.2, GPL-3.0, Python 3.13, Blender Foundation, and the
Blender release source locations. The wheel hash, size, `RECORD`, native entry point, and 43 native
library files bind the artifact NexGenVideo installs. Blender's exact v5.2.2 source archive binds the
release build recipes, patches, dependency versions, URLs, upstream hashes, and license-generation
metadata. Upstream does not currently publish a per-wheel build record proving which dependency
archives and build flags produced the pinned macOS arm64 wheel. That specific provenance fact must be
resolved; library filenames are not a substitute.

`scripts/assemble_bpy_source_closure.py` downloads and verifies the exact wheel/release inputs, every
wheel source, python-build-standalone plus its declared CPython inputs, and every dependency in the
Blender v5.2.2 build manifest, including static/transitive candidates. It preserves source archives,
the complete Blender build-file/patch inventory, wheel `RECORD` evidence, and notice candidates in a
deterministic tar archive. `scripts/verify_bpy_source_closure.py` independently checks that archive.

To move the lock to `ready`, add repository-hashed evidence with these schemas:

- `nexgenvideo/bpy-wheel-build-provenance/1`: `wheelSHA256`, `releaseSourceSHA256`,
  `releaseBuildManifestSHA256`, `closureComponents` covering every component emitted by the
  builder, and a distinct `buildInputComponents` list naming only the inputs the official per-wheel
  record proves were actually used. It must not turn the conservative all-candidate archive into a
  claim that every candidate was linked, and it must not assert that a bit-identical rebuilt wheel
  is required.
- `nexgenvideo/bpy-notice-coverage/1`: a `components` object mapping every emitted component to one
  or more paths listed in `distributionClosure.noticeFiles`.

The ready closure also pins the generated public tar and manifest filenames, archive SHA-256 and byte
size, and manifest SHA-256. The release workflow publishes both beside the binary. A link or version
instruction to another equally accessible source server is also valid if the lock and workflow are
changed together to verify that exact public location.

Primary policy references:

- <https://www.blender.org/about/license/>
- <https://www.gnu.org/licenses/gpl-faq.en.html#AnonFTPAndSendSources>
- <https://www.gnu.org/licenses/gpl-faq.en.html#MustSourceBuildToMatchExactHashOfBinary>
