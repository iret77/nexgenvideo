# dmgbuild settings for the NexGenVideo DMG — headless branded install window (no Finder/AppleScript).
# Driven by env vars from bundle.sh. Icon positions are tuned to the backdrop but can't be rendered in
# CI — adjust icon_locations / window_rect after a visual check on a Mac.
import os
import hashlib
import json
import re
from pathlib import Path

application = os.environ["DMG_APP"]
pack = os.environ.get("DMG_PACK")
guide = os.environ.get("DMG_GUIDE")
_app = os.path.basename(application)

format = "UDZO"
filesystem = "APFS"
_capacity = json.loads(Path(os.environ["DMG_CAPACITY_PLAN"]).read_text())
if (_capacity.get("schema") != ("release-dmg-capacity-plan/v2" if pack else "release-dmg-capacity-plan/v1")
        or _capacity.get("capacityVerified") is not True
        or _capacity.get("appPath") != str(Path(application).resolve())
        or type(_capacity.get("imageSizeSectors")) is not int or _capacity["imageSizeSectors"] <= 0):
    raise ValueError("Missing or mismatched measured DMG capacity")
if pack and (_capacity.get("packPath") != str(Path(pack).resolve())
             or not Path(pack).is_dir() or Path(pack).is_symlink()
             or not isinstance(_capacity.get("packTreeSHA256"), str)
             or not re.fullmatch('[a-f0-9]{64}', _capacity['packTreeSHA256'])):
    raise ValueError("Missing or mismatched external format-pack capacity binding")
if pack and (not guide or not Path(guide).is_file() or Path(guide).is_symlink()
             or _capacity.get("guidePath") != str(Path(guide).resolve())
             or _capacity.get("guideSHA256") != hashlib.sha256(Path(guide).read_bytes()).hexdigest()):
    raise ValueError("Missing installation guide in the joint DMG")
size = str(_capacity["imageSizeSectors"]) + "b"
files = [application] + ([pack, guide] if pack else [])
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
if pack:
    icon_locations[os.path.basename(pack)] = (
        icon_locations["Applications"][0],
        window_rect[1][1] - icon_size,
    )
    icon_locations[os.path.basename(guide)] = (icon_locations[_app][0], window_rect[1][1] - icon_size)
