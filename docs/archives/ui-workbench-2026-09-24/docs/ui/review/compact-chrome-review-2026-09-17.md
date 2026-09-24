# Compact window chrome — UI/UX self-review

Reviewed 2026-09-17 before presenting the revised clickdummy. Scope: panel controls and the owner-requested removal of the redundant global toolbar row. This is a self-review, not an independent agent review or a native-app verification.

## Findings and resolutions

- The View dropdown hid direct panel actions and introduced an unnecessary interaction step. Replaced with two small mirrored panel icons; each affects only its own sidebar. Buttons remain in the titlebar when either or both panes are closed.
- A second global row spent about 40 px on only window commands. Removed its DOM element entirely. Project-title menu, Undo, mode switch, pack identity and panel controls now share one 43 px titlebar at desktop widths. The working surface receives the recovered height.
- Long project names must not displace commands or the centered mode switch. The project title truncates in its available space; its accessible name contains the full title. All commands stay reachable. Below 650 px, the embedded preview wraps mode selection, preserving functionality without pretending NGV is a mobile app.
- Space on a titlebar button must activate that button, not start an Animatic. Titlebar keys retain native button behavior; the application shortcut does not intercept them. Enter and Space were exercised through real browser keyboard events.
- The standalone review document initially lacked the supplied icon runtime. The standalone builder now embeds the two actual Lucide icons exported from the supplied visualization runtime. The inline version continues using supplied Lucide names and its host runtime; no hand-drawn icon paths or new CDN script were added to it.

## Visual review

Compared the compact controls with the previously inspected official Final Cut Pro, Resolve and LTX Desktop screenshots; precise source links are in `desktop-research-2026-09-17.md`. Direct panel glyphs follow FCP's documented pattern. This does not claim that all three applications use identical controls.

Inspected the revised Storyboard in the actual supplied preview wrapper, plus standalone Storyboard, Edit and Finish screenshots. Verified neutral icon states, readable pack identity, centered mode switching, uninterrupted workspace boundaries, and additional image space. Also inspected the 320 px fallback: controls remain available; it intentionally stacks the work surface and Inspector. This fallback is not the intended desktop layout.

## Interaction evidence

- 116 existing clickdummy checks passed, including all four panel combinations, unchanged content/DOM on visibility toggles, sidebar-tab idempotence, Undo preserving layout, mode-specific content, and Animatic transport appearing only in its selected tab.
- Real Enter/Space checks passed for both panel buttons, including reopening hidden panes without starting Animatic playback.
- 15 titlebar layouts: Storyboard / Edit / Finish at 1440, 1024, 736, 500 and 320 px, using an intentionally long project title. No button overlap, clipping or titlebar overflow. Desktop titlebar remains 43 px; narrow preview fallback is 76 px.
- Full clickdummy layout checks cover 25 view/width combinations without horizontal overflow.

Evidence: `compact-chrome-checks.json`, `desktop-workbench-checks.json`, `desktop-workbench-layouts.json`. Native Swift, pipeline contracts, providers and pack ABI remain untouched.
