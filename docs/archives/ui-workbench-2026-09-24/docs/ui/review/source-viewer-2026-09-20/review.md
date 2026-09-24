# Schnitt: Quellenwahl und Viewer — 20.09.2026

Scope: static Clickdummy. Self-review by Codex; no new external/Fable review and no native application verification. Earlier context-menu checks did not establish that sequential source opening produced a usable Viewer toolbar. That coverage gap invalidated a general UX sign-off.

## Findings corrected

- Opening successive sources accumulated four history buttons beside Timeline/Quelle. Their shared shrinking rule truncated the navigation itself. There is now one stable Timeline/Quelle switch with a separate source name; no history tabs or source-close button in Schnitt. Production source previews retain their own close action.
- Source transport moved the visible Timeline playhead although its underlying Timeline cursor was unchanged. Both now remain independent.
- Timeline titles could appear over source images and their Inspector could override source controls. Source previews now exclude Timeline titles, comparison and direct transforms. Scrubbing the Timeline synchronizes the Viewer switch and Inspector.
- In/Out inputs rejected ordinary fractional seconds because HTML number inputs defaulted to a step of one. They accept fractions, quantize to project frames and constrain the interval. Reselecting the same source retains the range and cursor.
- Source-frame capture used Timeline time and provenance. It now records the selected source and source time without changing the montage.
- Source placement controls were below metadata and secondary actions. Quellbereich, Einfügen and Überschreiben now appear first in the source Inspector. Text documents have no insertion range.
- Visual inspection of the 900-pixel/130% screenshot exposed a fixed header height hiding the wrapped name, despite initially passing geometric assertions. The header now accommodates its content. The check additionally verifies vertical containment and actual visibility with hit testing.

## Evidence

`node docs/ui/check-desktop-production-viewer.mjs`: 27 passing checks, no runtime exceptions. One connected sequence opens four sources by mouse, edits In/Out, switches Timeline/Quelle, inserts and undoes, selects a title, revisits sources, captures a source frame, scrubs the Timeline, uses the picker context menu and changes workspace. Layout variants use 100%/130%, long source names, resized panes, hidden panes and 1048/900-pixel windows. Empty source and audio preview states are checked separately.

Screenshots personally inspected: `sequential-sources.png`, `final-source.png`, `final-timeline.png`, `scaled-130.png`, `narrow-long-source-130.png`, `narrow-900-130.png`. Controls retain full labels; the name remains a noninteractive caption. In the deliberately narrow variant the name occupies a second line and transport groups wrap. Source insertion controls remain visible at 130% in the ordinary window arrangement.

The existing context-menu regression suite also passed its 56 checks after the source/state changes, including locks, multiselection, source reveal, real mouse drag and the single Inspector scroller. The subsequent changes affected only adaptive toolbar height and source Inspector ordering; the connected Viewer suite was rerun on the final artifact.

This evidence supports the source/Timeline workflow covered here. It is not a blanket approval of every project phase, native rendering, playback or the whole product UX. Playback remains the existing still-image simulation.
