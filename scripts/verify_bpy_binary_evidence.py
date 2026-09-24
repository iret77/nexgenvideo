#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "Runtime/bpy/runtime-lock.json"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def fail(message):
    raise ValueError(message)


def validate(evidence, source_sha):
    lock = json.loads(LOCK.read_text())
    bpy = next(item for item in lock["wheels"] if item["name"] == "bpy")
    expected = lock["bpyWheelLayout"]["expectedRuntimeBinaryEvidence"]
    if evidence.get("schema") != "nexgenvideo/bpy-binary-evidence-candidate/1" \
            or evidence.get("classification") != "candidate-only" \
            or evidence.get("publicDistributionAuthorized") is not False:
        fail("binary evidence is not an explicitly non-distributable candidate")
    if not COMMIT.fullmatch(source_sha) or evidence.get("sourceSHA") != source_sha:
        fail("binary evidence is not bound to the requested source commit")
    wheel = evidence.get("wheel", {})
    if wheel.get("filename") != bpy["filename"] \
            or wheel.get("sha256") != bpy["sha256"] \
            or wheel.get("entryPoint") != lock["bpyWheelLayout"]["entryPoint"] \
            or not SHA256.fullmatch(wheel.get("entryPointSHA256", "")) \
            or type(wheel.get("entryPointSize")) is not int \
            or wheel["entryPointSize"] <= 0:
        fail("binary evidence is not bound to the pinned wheel entry point")
    if evidence.get("officialReleaseCommit") != lock["bpyWheelLayout"]["officialReleaseCommit"] \
            or evidence.get("blenderBuildHash") != expected["buildHash"]:
        fail("bpy build hash does not match the official release commit")
    libraries = evidence.get("libraryVersions", {})
    for name, version in expected["libraryVersions"].items():
        item = libraries.get(name, {})
        if item.get("supported") is not True or item.get("version") != version \
                or not item.get("versionString"):
            fail(f"bpy LibraryVersion mismatch: {name}")
    if set(libraries) != {"alembic", "ocio", "oiio", "opensubdiv", "openvdb", "sdl", "usd"}:
        fail("unexpected bpy LibraryVersion inventory")
    if "do not identify every native source archive" not in evidence.get(
        "evidenceLimitations", ""
    ):
        fail("binary evidence omits its correspondence limitation")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    evidence = json.loads(args.evidence.read_text())
    validate(evidence, args.source_sha)
    print(json.dumps({
        "blenderBuildHash": evidence["blenderBuildHash"],
        "classification": evidence["classification"],
        "libraryVersions": {
            name: value["version"] for name, value in evidence["libraryVersions"].items()
        },
        "publicDistributionAuthorized": evidence["publicDistributionAuthorized"],
        "sourceSHA": evidence["sourceSHA"],
    }, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"invalid bpy binary evidence: {error}")
