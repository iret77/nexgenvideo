# Managed bpy runtime notices

NexGenVideo prepares a separately sandboxed `bpy` worker built from the exact artifacts in
`runtime-lock.json`. The application does not install packages at runtime and does not use a
system Blender or Python.

`bpy` and Blender are distributed under GPL-3.0-or-later. NexGenVideo is GPL-3.0. This repository
does not claim that a process boundary removes GPL obligations. CPython, python-build-standalone,
the declared Python wheels, and the native libraries inventoried in the lock carry their own licenses.
The build copies the license files contained by the pinned artifacts into the runtime bundle.

The pinned wheel contains the RECORD-backed native entry point `bpy/__init__.so` and 43 dylibs under
`bpy/lib/`; their exact paths are recorded in `runtime-lock.json` and staging verifies their RECORD
hashes and sizes. The lock maps every path exactly once to a candidate source family, version, URL,
license, and archive checksum from Blender v5.2.2's official dependency manifest. That candidate
mapping does not by itself prove which sources produced the wheel binaries.

Public distribution is blocked until the upstream wheel/build-input provenance gap is resolved and
the resulting Corresponding Source and notice set is hash-pinned and shipped for the Blender build
recipes/patches, static and transitive dependency candidates, native inventory, Python runtime/build
inputs, and wheels. No generic external legal-review approval is part of this technical gate.
`scripts/verify_bpy_runtime.py --distribution` gates releases, dry runs, public app artifacts, and
the cross-runner acceptance ZIP before the runtime can leave its build job.

The stable release tag targets the exact app build commit, so the repository's GPL-3.0 source and
build scripts remain available through that tag's source archives. The separately published managed-
runtime source archive preserves the third-party sources, recipes, patches, provenance, and notices
that are not supplied merely by the NexGenVideo repository snapshot.

Primary sources:

- <https://pypi.org/project/bpy/5.2.2/>
- <https://download.blender.org/source/blender-5.2.2.tar.xz>
- <https://raw.githubusercontent.com/blender/blender/v5.2.2/build_files/build_environment/cmake/versions.cmake>
- <https://github.com/astral-sh/python-build-standalone/releases/tag/20260901>
- <https://www.python.org/downloads/release/python-31315/>
- <https://www.blender.org/about/license/>
- <https://www.gnu.org/licenses/gpl-faq.en.html#AnonFTPAndSendSources>
- <https://www.gnu.org/licenses/gpl-faq.en.html#MustSourceBuildToMatchExactHashOfBinary>
