#!/usr/bin/env python3
import argparse
import base64
import csv
import hashlib
import json
import sys
from pathlib import Path


def text_value(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="strict")
    return str(value)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--site-packages", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    site_packages = args.site_packages.resolve()
    lock = json.loads(args.lock.read_text())
    sys.path.insert(0, str(site_packages))
    import bpy

    entry_point = site_packages / lock["bpyWheelLayout"]["entryPoint"]
    record_path = site_packages / lock["bpyWheelLayout"]["recordPath"]
    with record_path.open(newline="") as handle:
        records = {row[0]: row[1:] for row in csv.reader(handle)}
    record = records[lock["bpyWheelLayout"]["entryPoint"]]
    encoded = base64.urlsafe_b64encode(bytes.fromhex(sha256(entry_point))).decode().rstrip("=")
    if record != [f"sha256={encoded}", str(entry_point.stat().st_size)]:
        raise SystemExit("installed bpy module does not match the pinned wheel RECORD")

    libraries = {}
    for name in ("alembic", "ocio", "oiio", "opensubdiv", "openvdb", "sdl", "usd"):
        library = getattr(bpy.app, name)
        libraries[name] = {
            "supported": bool(library.supported),
            "version": list(library.version),
            "versionString": text_value(library.version_string),
        }

    evidence = {
        "schema": "nexgenvideo/bpy-binary-evidence-candidate/1",
        "classification": "candidate-only",
        "publicDistributionAuthorized": False,
        "sourceSHA": args.source_sha,
        "wheel": {
            "filename": next(item["filename"] for item in lock["wheels"] if item["name"] == "bpy"),
            "sha256": next(item["sha256"] for item in lock["wheels"] if item["name"] == "bpy"),
            "entryPoint": lock["bpyWheelLayout"]["entryPoint"],
            "entryPointSHA256": sha256(entry_point),
            "entryPointSize": entry_point.stat().st_size,
        },
        "officialReleaseCommit": lock["bpyWheelLayout"]["officialReleaseCommit"],
        "blenderBuildHash": text_value(bpy.app.build_hash),
        "blenderBuildBranch": text_value(bpy.app.build_branch),
        "blenderBuildType": text_value(bpy.app.build_type),
        "blenderBuildSystem": text_value(bpy.app.build_system),
        "libraryVersions": libraries,
        "evidenceLimitations": (
            "The build hash and exposed library versions do not identify every native source "
            "archive, applied patch, configuration value, or build flag."
        ),
    }
    args.output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
