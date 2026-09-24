# Managed bpy source closure

Public binary distribution remains blocked until the lock is `ready` and the source-closure
workflow validates the exact public source asset. This is a technical distribution gate, not a
request for generic legal approval.

The pinned PyPI metadata identifies `bpy` 5.2.2, GPL-3.0, Python 3.13, Blender Foundation, and the
Blender release source locations. The wheel hash, size, `RECORD`, native entry point, and 43 native
library files bind the artifact NexGenVideo installs. Blender's exact v5.2.2 source archive binds the
release build recipes, patches, dependency versions, URLs, upstream hashes, and license-generation
metadata. The official v5.2.2 tag resolves to commit
`d13f752e3b9c4f8c261cda552b1021f8bcc0382c`; the exact `versions.cmake` and release build-file
inventory are pinned. These facts establish authoritative release inputs, but they do not by
themselves prove that every embedded wheel library was made from every candidate archive.

`scripts/assemble_bpy_source_closure.py` downloads and verifies the exact wheel/release inputs, every
wheel source, python-build-standalone plus its declared CPython inputs, and every dependency in the
Blender v5.2.2 build manifest, including static/transitive candidates. It preserves source archives,
the complete Blender build-file/patch inventory, wheel `RECORD` evidence, and notice candidates in a
deterministic tar archive. `scripts/verify_bpy_source_closure.py` independently checks that archive.
`.github/workflows/bpy-source-closure-candidate.yml` can assemble and validate this candidate on
Ubuntu before the distribution gate is ready. Its artifact is explicitly candidate-only and never
authorizes a binary for publication.

To move the lock to `ready`, add repository-hashed evidence with these schemas:

- `nexgenvideo/bpy-binary-source-correspondence/1`: the wheel and METADATA hashes, official release
  commit, observed `blenderBuildHash` and `libraryVersions`, release source and build-manifest hashes,
  `closureComponents` covering every component
  emitted by the builder, and a distinct `buildInputComponents` list naming only actual build
  inputs supported by its cited primary `evidence`. `unresolvedFacts` must be empty. Acceptable
  evidence can combine official release/build records, the pinned wheel's `bpy.app.build_hash`,
  Blender-exposed `LibraryVersion` values, and independently inspected binary metadata. No special
  upstream per-wheel attestation or bit-identical rebuild is required. The evidence must not turn
  the conservative all-candidate archive into a claim that every candidate was linked.
- `nexgenvideo/bpy-notice-coverage/1`: a `components` object mapping every emitted component to one
  or more paths listed in `distributionClosure.noticeFiles`.

The prepared `.github/workflows/bpy-binary-evidence-candidate.yml` path records `bpy.app.build_hash`
and the Blender-exposed Alembic, OpenColorIO, OpenImageIO, OpenSubdiv, OpenVDB, and USD versions from
the exact pinned wheel without building or publishing an app. Runtime acceptance independently
records the same fields. That evidence narrows binary/source correspondence; it does not cover native
families the API does not expose, nor prove which patches and configuration produced each embedded
binary. In particular, Blender exposes OpenImageIO as `[3, 1, 13]` while `versions.cmake` pins
`v3.1.13.1`, and its SDL `LibraryVersion` is unsupported; neither observation proves the full source
archive identity. Those remaining facts and every generated `NOTICE-CANDIDATE.json` must be resolved
before the gate can become ready.

The ready closure also pins the generated public tar and manifest filenames, archive SHA-256 and byte
size, and manifest SHA-256. The release workflow publishes both beside the binary. A link or version
instruction to another equally accessible source server is also valid if the lock and workflow are
changed together to verify that exact public location.

Primary policy references:

- <https://pypi.org/pypi/bpy/5.2.2/json>
- <https://github.com/blender/blender/commit/d13f752e3b9c4f8c261cda552b1021f8bcc0382c>
- <https://docs.blender.org/api/5.2/bpy.app.html>
- <https://www.blender.org/about/license/>
- <https://www.gnu.org/licenses/gpl-faq.en.html#AnonFTPAndSendSources>
- <https://www.gnu.org/licenses/gpl-faq.en.html#MustSourceBuildToMatchExactHashOfBinary>
