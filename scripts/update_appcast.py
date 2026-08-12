#!/usr/bin/env python3
"""Append a Sparkle <item> to appcast.xml. Called by the release workflow.

usage: update_appcast.py <version> <build> <dmg_length> <ed_signature> <tag>
"""
import sys
from email.utils import formatdate
from pathlib import Path
import plistlib

version, build, length, signature, tag = sys.argv[1:6]
url = f"https://github.com/iret77/nexgenvideo/releases/download/{tag}/NexGenVideo.dmg"

info_path = Path("Sources/NexGenVideo/Resources/Info.plist")
with info_path.open("rb") as handle:
    minimum_system_version = plistlib.load(handle).get("LSMinimumSystemVersion")
if not isinstance(minimum_system_version, str) or not minimum_system_version.strip():
    raise SystemExit(f"{info_path}: LSMinimumSystemVersion must be a non-empty string")

item = f"""        <item>
            <title>Version {version}</title>
            <pubDate>{formatdate()}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{minimum_system_version}</sparkle:minimumSystemVersion>
            <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
        </item>"""

path = Path("appcast.xml")
content = path.read_text()
marker = "    </channel>"
if content.count(marker) != 1:
    raise SystemExit(f"{path}: expected exactly one channel closing tag")
path.write_text(content.replace(marker, item + "\n" + marker))
print(f"appcast.xml: added {version} (build {build})")
