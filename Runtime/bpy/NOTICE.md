# Managed bpy runtime notices

NexGenVideo prepares a separately sandboxed `bpy` worker built from the exact artifacts in
`runtime-lock.json`. The application does not install packages at runtime and does not use a
system Blender or Python.

`bpy` and Blender are distributed under GPL-3.0-or-later. NexGenVideo is GPL-3.0. This repository
does not claim that a process boundary removes GPL obligations. CPython, python-build-standalone,
the declared Python wheels, and the native libraries listed in the lock carry their own licenses.
The build copies the license files contained by the pinned artifacts into the runtime bundle.

Public distribution is blocked until the exact native libraries vendored by the `bpy` wheel are
mapped to their Corresponding Source and license notices and the combined distribution has been
reviewed. `scripts/verify_bpy_runtime.py --distribution` enforces that block before a stable
release can ship it.

Primary sources:

- <https://pypi.org/project/bpy/5.2.2/>
- <https://download.blender.org/source/blender-5.2.2.tar.xz>
- <https://github.com/astral-sh/python-build-standalone/releases/tag/20260901>
- <https://www.python.org/downloads/release/python-31315/>
