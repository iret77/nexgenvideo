#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path

from verify_bpy_runtime import validate as validate_runtime
from verify_bpy_source_closure import validate as validate_closure


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "Runtime/bpy/runtime-lock.json"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def validate(archive, manifest):
    lock = json.loads(LOCK_PATH.read_text())
    validate_runtime(lock)
    if lock.get("distributionStatus") != "ready":
        raise ValueError("runtime lock remains fail-closed for public distribution")
    closure = validate_closure(archive, manifest, require_distributable=True)
    public = lock["distributionClosure"]["publicSourceAsset"]
    if digest(archive) != public["sha256"] or archive.stat().st_size != public["size"]:
        raise ValueError("public corresponding-source archive pin mismatch")
    if digest(manifest) != public["manifestSHA256"]:
        raise ValueError("public corresponding-source manifest pin mismatch")
    return {
        "schema": "nexgenvideo/bpy-distributable-source-validation/1",
        "sources": len(closure["sources"]),
        "notices": len(closure["notices"]),
        "correspondenceComplete": closure["correspondenceComplete"],
        "noticeComplete": closure["noticeComplete"],
        "archiveSHA256": public["sha256"],
        "manifestSHA256": public["manifestSHA256"],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    print(json.dumps(validate(args.archive, args.manifest), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"invalid distributable bpy source closure: {error}")
