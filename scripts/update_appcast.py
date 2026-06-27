#!/usr/bin/env python3
"""Append a Sparkle <item> to appcast.xml. Called by the release workflow.

usage: update_appcast.py <version> <build> <dmg_length> <ed_signature> <tag>
"""
import sys
from email.utils import formatdate

version, build, length, signature, tag = sys.argv[1:6]
url = f"https://github.com/iret77/nexgen-video/releases/download/{tag}/NexGenVideo.dmg"

item = f"""        <item>
            <title>Version {version}</title>
            <pubDate>{formatdate()}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
        </item>"""

path = "appcast.xml"
content = open(path).read().replace("    </channel>", item + "\n    </channel>")
open(path, "w").write(content)
print(f"appcast.xml: added {version} (build {build})")
