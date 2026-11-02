# dmgbuild settings for the NexGenVideo DMG — headless branded install window (no Finder/AppleScript).
# Driven by env vars from bundle.sh. Icon positions are tuned to the backdrop but can't be rendered in
# CI — adjust icon_locations / window_rect after a visual check on a Mac.
import os
import json
from pathlib import Path

application = os.environ["DMG_APP"]
_app = os.path.basename(application)

format = "UDZO"
filesystem = "APFS"
_capacity = json.loads(Path(os.environ["DMG_CAPACITY_PLAN"]).read_text())
if (_capacity.get("schema") != "release-dmg-capacity-plan/v1"
        or _capacity.get("capacityVerified") is not True
        or _capacity.get("appPath") != str(Path(application).resolve())
        or type(_capacity.get("imageSizeSectors")) is not int or _capacity["imageSizeSectors"] <= 0):
    raise ValueError("Missing or mismatched measured DMG capacity")
size = str(_capacity["imageSizeSectors"]) + "b"
files = [application]
symlinks = {"Applications": "/Applications"}

_icns = os.environ.get("DMG_VOLICON")
badge_icon = _icns if _icns and os.path.exists(_icns) else None

_bg = os.environ.get("DMG_BG")
background = _bg if _bg and os.path.exists(_bg) else None

# Window sized to the @2x backdrop's point size (1499x1049 px @144 dpi -> ~750x525 pt).
window_rect = ((360, 220), (750, 525))
default_view = "icon-view"

# Chromeless install window (macOS best practice): just the two icons on the artwork, no toolbar,
# sidebar, status or path bar, and don't let Finder auto-arrange over our positions.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
arrange_by = None

icon_size = 128
text_size = 13
label_pos = "bottom"

# App on the left, Applications alias on the right — the canonical "drag me there" layout, seated in
# the dark centre of the backdrop for legible white labels.
icon_locations = {
    _app: (205, 250),
    "Applications": (545, 250),
}
