#!/usr/bin/env python3
"""Append or validate a Sparkle <item> in appcast.xml.

usage: update_appcast.py <version> <build> <dmg_length> <ed_signature> <tag>
"""
import sys
from email.utils import formatdate
from pathlib import Path
import plistlib
from xml.etree import ElementTree
from xml.sax.saxutils import escape, quoteattr

SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def _shipping_minimum_system_version(info_path: Path) -> str:
    with info_path.open("rb") as handle:
        minimum_system_version = plistlib.load(handle).get("LSMinimumSystemVersion")
    if not isinstance(minimum_system_version, str) or not minimum_system_version.strip():
        raise ValueError(
            f"{info_path}: LSMinimumSystemVersion must be a non-empty string"
        )
    return minimum_system_version


def _matching_items(root: ElementTree.Element, version: str):
    version_key = f"{{{SPARKLE_NAMESPACE}}}shortVersionString"
    item_path = "./item" if root.tag == "channel" else "./channel/item"
    return [
        item
        for item in root.findall(item_path)
        if item.findtext(version_key) == version
    ]


def _validate_item(
    item: ElementTree.Element,
    version: str,
    build: str,
    length: str,
    signature: str,
    tag: str,
    minimum_system_version: str,
) -> None:
    sparkle = f"{{{SPARKLE_NAMESPACE}}}"
    expected_url = (
        f"https://github.com/iret77/nexgenvideo/releases/download/"
        f"{tag}/NexGenVideo.dmg"
    )
    expected_text = {
        f"{sparkle}version": build,
        f"{sparkle}shortVersionString": version,
        f"{sparkle}minimumSystemVersion": minimum_system_version,
    }
    for key, expected in expected_text.items():
        if item.findtext(key) != expected:
            raise ValueError(
                f"appcast.xml: existing {version} item has mismatched {key}"
            )
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError(f"appcast.xml: existing {version} item has no enclosure")
    expected_attributes = {
        "url": expected_url,
        "length": length,
        "type": "application/octet-stream",
        f"{sparkle}edSignature": signature,
    }
    for key, expected in expected_attributes.items():
        if enclosure.get(key) != expected:
            raise ValueError(
                f"appcast.xml: existing {version} item has mismatched {key}"
            )


def update_appcast(
    version: str,
    build: str,
    length: str,
    signature: str,
    tag: str,
    *,
    root: Path = Path("."),
    require_existing: bool = False,
) -> bool:
    info_path = root / "Sources/NexGenVideo/Resources/Info.plist"
    minimum_system_version = _shipping_minimum_system_version(info_path)
    path = root / "appcast.xml"
    content = path.read_text()
    xml_root = ElementTree.fromstring(content)
    matches = _matching_items(xml_root, version)
    if len(matches) > 1:
        raise ValueError(f"{path}: contains duplicate {version} entries")
    if matches:
        _validate_item(
            matches[0],
            version,
            build,
            length,
            signature,
            tag,
            minimum_system_version,
        )
        return False
    if require_existing:
        raise ValueError(f"{path}: missing {version} entry")

    url = (
        f"https://github.com/iret77/nexgenvideo/releases/download/"
        f"{tag}/NexGenVideo.dmg"
    )
    item = f"""        <item>
            <title>Version {escape(version)}</title>
            <pubDate>{formatdate()}</pubDate>
            <sparkle:version>{escape(build)}</sparkle:version>
            <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{escape(minimum_system_version)}</sparkle:minimumSystemVersion>
            <enclosure url={quoteattr(url)} length={quoteattr(length)} type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
        </item>"""
    marker = "    </channel>"
    if content.count(marker) != 1:
        raise ValueError(f"{path}: expected exactly one channel closing tag")
    path.write_text(content.replace(marker, item + "\n" + marker))
    return True


def main() -> int:
    if len(sys.argv) != 6:
        raise SystemExit(__doc__)
    version, build, length, signature, tag = sys.argv[1:]
    try:
        changed = update_appcast(version, build, length, signature, tag)
    except (ElementTree.ParseError, OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    state = "added" if changed else "already contains"
    print(f"appcast.xml: {state} {version} (build {build})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
