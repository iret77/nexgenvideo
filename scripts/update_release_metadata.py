#!/usr/bin/env python3
"""Update or validate source metadata for a signed release."""

import argparse
import base64
import binascii
import plistlib
import re
from pathlib import Path
from xml.etree import ElementTree

from update_appcast import update_appcast


INFO_PATH = Path("Sources/NexGenVideo/Resources/Info.plist")
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def _replace_plist_string(content: str, key: str, value: str) -> str:
    pattern = re.compile(
        rf"(<key>{re.escape(key)}</key>\s*<string>)([^<]*)(</string>)"
    )
    updated, count = pattern.subn(rf"\g<1>{value}\g<3>", content)
    if count != 1:
        raise ValueError(f"{INFO_PATH}: expected exactly one {key} string")
    return updated


def _validate_inputs(
    version: str, build: str, length: str, signature: str, tag: str
) -> None:
    if SEMVER.fullmatch(version) is None:
        raise ValueError(f"version must be X.Y.Z (got {version!r})")
    if not build.isdigit() or int(build) < 1:
        raise ValueError("build must be a positive integer")
    if not length.isdigit() or int(length) < 1:
        raise ValueError("dmg_length must be a positive integer")
    try:
        decoded_signature = base64.b64decode(signature, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("ed_signature must be valid base64") from error
    if len(decoded_signature) != 64:
        raise ValueError("ed_signature must encode a 64-byte Ed25519 signature")
    if tag != f"v{version}":
        raise ValueError(f"tag must be v{version}")


def _validate_plist(version: str, build: str) -> None:
    with INFO_PATH.open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleShortVersionString") != version:
        raise ValueError(f"{INFO_PATH}: release version does not match {version}")
    if str(info.get("CFBundleVersion")) != build:
        raise ValueError(f"{INFO_PATH}: build number does not match {build}")


def update_release_metadata(
    version: str,
    build: str,
    length: str,
    signature: str,
    tag: str,
    *,
    check: bool = False,
) -> None:
    _validate_inputs(version, build, length, signature, tag)
    if not check:
        content = INFO_PATH.read_text()
        content = _replace_plist_string(
            content, "CFBundleShortVersionString", version
        )
        content = _replace_plist_string(content, "CFBundleVersion", build)
        INFO_PATH.write_text(content)
    _validate_plist(version, build)
    update_appcast(
        version,
        build,
        length,
        signature,
        tag,
        require_existing=check,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("dmg_length")
    parser.add_argument("ed_signature")
    parser.add_argument("tag")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        update_release_metadata(
            args.version,
            args.build,
            args.dmg_length,
            args.ed_signature,
            args.tag,
            check=args.check,
        )
    except (ElementTree.ParseError, OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
    print(
        f"release metadata: {'verified' if args.check else 'updated'} "
        f"{args.version} (build {args.build})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
