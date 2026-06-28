"""Generic workflow modes.

A pack may use a subset (music uses PHRASE/SECTION). The *duration semantics* per
mode are deliberately NOT here — they come from a pack's `DurationPolicy` (see
`nexgen_engine.pack`, seam 1), so the engine's Shot / project / sanity logic stays
format-neutral. (Extracted from musicvideo `shotlist.schema.Mode`; the music
`MODE_DURATION_RANGES` moved to the pack.)
"""

from __future__ import annotations

from enum import Enum


class Mode(str, Enum):
    BEAT = "beat"
    PHRASE = "phrase"
    SECTION = "section"
    MULTICAM = "multicam"
