#!/usr/bin/env python3
import argparse
import json
import plistlib
import re
import subprocess
from email.utils import parsedate_to_datetime
from pathlib import Path
from xml.etree import ElementTree

from update_appcast import _matching_items, render_item
from update_release_metadata import INFO_PATH, _replace_plist_string, _validate_inputs


def git(*args):
    return subprocess.check_output(["git", *args])


def verify_metadata(transaction, version, head):
    if transaction.get("schema") != "release-publication/3":
        raise ValueError("unsupported release transaction")
    if transaction.get("version") != version:
        raise ValueError("release transaction version mismatch")
    source = transaction["source_sha"]
    if not isinstance(source, str) or not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("invalid release source SHA")
    build, length, signature, tag = (
        transaction[key] for key in ("build_number", "dmg_length", "ed_signature", "tag")
    )
    if not all(isinstance(value, str) for value in (build, length, signature, tag)):
        raise ValueError("invalid release transaction fields")
    _validate_inputs(version, build, length, signature, tag)
    git("merge-base", "--is-ancestor", source, head)
    entries = git("diff", "--no-renames", "--raw", "-z", source, head).split(b"\0")
    paths = set()
    for index in range(0, len(entries) - 1, 2):
        fields = entries[index].decode().split()
        path = entries[index + 1].decode()
        if fields[:2] != [":100644", "100644"] or fields[-1] != "M":
            return False
        paths.add(path)
    if not paths or paths - {str(INFO_PATH), "appcast.xml"}:
        return False

    original_info = git("show", f"{source}:{INFO_PATH}").decode()
    expected_info = _replace_plist_string(original_info, "CFBundleShortVersionString", version)
    expected_info = _replace_plist_string(expected_info, "CFBundleVersion", build)
    if git("show", f"{head}:{INFO_PATH}").decode() != expected_info:
        raise ValueError("Info.plist contains changes beyond the signed release version and build")
    minimum = plistlib.loads(original_info.encode())["LSMinimumSystemVersion"]
    original_feed = git("show", f"{source}:appcast.xml").decode()
    current_feed = git("show", f"{head}:appcast.xml").decode()
    if _matching_items(ElementTree.fromstring(original_feed), version):
        raise ValueError("release source already contains this appcast version")
    matches = _matching_items(ElementTree.fromstring(current_feed), version)
    if len(matches) != 1:
        raise ValueError("expected one release appcast entry")
    date = matches[0].findtext("pubDate", "")
    parsedate_to_datetime(date)
    marker = "    </channel>"
    if original_feed.count(marker) != 1:
        raise ValueError("expected one appcast channel")
    item = render_item(version, build, length, signature, tag, minimum, date)
    if current_feed != original_feed.replace(marker, item + "\n" + marker):
        raise ValueError("appcast differs from the signed release transaction or changes older entries")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--transaction", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--head", required=True)
    args = parser.parse_args()
    try:
        verified = verify_metadata(json.loads(args.transaction.read_text()), args.version, args.head)
    except (KeyError, TypeError, ValueError, OSError, ElementTree.ParseError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Release metadata verification failed: {error}") from error
    print("true" if verified else "false")


if __name__ == "__main__":
    main()
