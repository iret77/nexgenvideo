# dmgbuild settings for the NexGenVideo DMG — headless branded window (no Finder/AppleScript).
# Driven by env vars from bundle.sh. Icon positions are best-effort guesses (the DMG can't be
# rendered in CI); adjust icon_locations / window_rect after a visual check on a Mac.
import os

application = os.environ["DMG_APP"]
_app = os.path.basename(application)

format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}

_icns = os.environ.get("DMG_VOLICON")
badge_icon = _icns if _icns and os.path.exists(_icns) else None

_bg = os.environ.get("DMG_BG")
background = _bg if _bg and os.path.exists(_bg) else None

window_rect = ((200, 200), (600, 400))
default_view = "icon-view"
icon_size = 100
text_size = 12
icon_locations = {
    _app: (150, 300),
    "Applications": (450, 300),
}
