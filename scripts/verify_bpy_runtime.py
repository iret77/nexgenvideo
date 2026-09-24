#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "Runtime/bpy/runtime-lock.json"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_WHEELS = {
    "bpy", "numpy", "cattrs", "Cython", "requests", "zstandard", "attrs",
    "typing-extensions", "charset-normalizer", "idna", "urllib3", "certifi",
}
EXPECTED_BUILD_INPUTS = {
    "CPython", "bzip2", "expat", "libedit", "libffi", "mpdecimal", "ncurses",
    "OpenSSL", "SQLite", "Tcl", "Tk", "XZ liblzma", "zlib",
}


def fail(message):
    raise ValueError(message)


def validate_artifact(item, label, require_size=False):
    if not item.get("url", "").startswith("https://"):
        fail(f"{label}: source must use HTTPS")
    if not SHA256.fullmatch(item.get("sha256", "")):
        fail(f"{label}: invalid SHA-256")
    if require_size and not isinstance(item.get("size"), int):
        fail(f"{label}: missing byte size")


def validate(lock):
    if lock.get("schema") != "nexgenvideo/bpy-runtime-lock/1":
        fail("unexpected runtime lock schema")
    if lock.get("platform") != "macos-arm64" or lock.get("pythonABI") != "cp313":
        fail("runtime platform/ABI must stay macOS arm64 CPython 3.13")
    runtime = lock.get("runtime", {})
    if runtime.get("version") != "3.13.15+20260901":
        fail("unexpected CPython runtime pin")
    validate_artifact(runtime.get("artifact", {}), "runtime artifact", True)
    validate_artifact(runtime.get("source", {}), "runtime source")

    wheels = lock.get("wheels", [])
    names = {item.get("name") for item in wheels}
    if names != EXPECTED_WHEELS or len(names) != len(wheels):
        fail(f"wheel closure mismatch: {sorted(names)}")
    for item in wheels:
        validate_artifact(item, f"wheel {item.get('name')}", True)
        validate_artifact(item.get("source", {}), f"source {item.get('name')}")
        if not item.get("license"):
            fail(f"wheel {item.get('name')}: missing license")
    bpy = next(item for item in wheels if item["name"] == "bpy")
    if bpy["version"] != "5.2.2" or bpy["sha256"] != (
        "e447dba63ea14ac6a3f10ea23fa7828c6af2a3d5b2ba206ad2262a54d5aa7cf7"
    ):
        fail("bpy version/hash drift")
    metadata = bpy.get("metadata", {})
    validate_artifact(metadata, "bpy wheel metadata")
    if metadata.get("license") != "GPL-3.0" or metadata.get("requiresPython") != "==3.13.*" \
            or set(metadata.get("requiresDist", [])) != {
        "cattrs", "cython", "numpy<3.0,>=2.2", "requests", "zstandard",
    }:
        fail("bpy wheel metadata drift")

    build_inputs = lock.get("pythonBuildInputs", [])
    input_names = {item.get("name") for item in build_inputs}
    if input_names != EXPECTED_BUILD_INPUTS or len(input_names) != len(build_inputs):
        fail(f"CPython build-input closure mismatch: {sorted(input_names)}")
    for item in build_inputs:
        validate_artifact(item, f"CPython input {item.get('name')}")
        if not item.get("license"):
            fail(f"CPython input {item.get('name')}: missing license")

    blockers = lock.get("distributionBlockers", [])
    status = lock.get("distributionStatus")
    if status == "ready" and blockers:
        fail("a ready distribution cannot retain blockers")
    if status != "ready" and not blockers:
        fail("a blocked distribution must state concrete blockers")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--distribution", action="store_true")
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    validate(lock)
    if args.distribution and lock["distributionStatus"] != "ready":
        print("bpy runtime distribution blocked:", file=sys.stderr)
        for blocker in lock["distributionBlockers"]:
            print(f"- {blocker}", file=sys.stderr)
        return 2
    print(
        f"bpy {next(x['version'] for x in lock['wheels'] if x['name'] == 'bpy')} / "
        f"CPython {lock['runtime']['version']} lock verified"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"invalid bpy runtime lock: {error}", file=sys.stderr)
        raise SystemExit(1)
