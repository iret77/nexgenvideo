"""NexGenVideo music-video format pack.

Thin by contract: registers only music-specific behavior into the Generic Engine
(duration bands, project subdirs, phases, checks). Bible / consistency / sanity /
render live in the engine core; generation + timeline go through nexgen's own tools,
driven by Claude. See docs/PLUGIN_STANDARD.md.
"""

from nexgen_pack_musicvideo.pack import MusicvideoPack

__version__ = "0.0.1"
__all__ = ["MusicvideoPack"]
