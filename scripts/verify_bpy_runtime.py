#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "Runtime/bpy/runtime-lock.json"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MD5 = re.compile(r"^[0-9a-f]{32}$")
SAFE_FILENAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
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
    if require_size and (type(item.get("size")) is not int or item["size"] <= 0):
        fail(f"{label}: missing byte size")


def validate_repository_evidence(item, label):
    relative = item.get("path", "")
    if not relative.startswith("Runtime/bpy/compliance/") or ".." in Path(relative).parts:
        fail(f"{label}: invalid repository evidence path")
    path = ROOT / relative
    compliance_root = (ROOT / "Runtime/bpy/compliance").resolve()
    if path.is_symlink() or not path.is_file() \
            or not path.resolve().is_relative_to(compliance_root) \
            or not SHA256.fullmatch(item.get("sha256", "")):
        fail(f"{label}: missing evidence or SHA-256")
    if hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
        fail(f"{label}: evidence hash mismatch")


def validate_distribution_closure(lock, families):
    closure = lock.get("distributionClosure", {})
    archives = closure.get("sourceArchives", [])
    declared = {
        "python-build-standalone": (
            lock["runtime"]["source"]["url"],
            lock["runtime"]["source"]["sha256"],
        ),
    }
    declared.update({
        f"wheel:{item['name']}": (item["source"]["url"], item["source"]["sha256"])
        for item in lock["wheels"]
    })
    declared.update({
        f"python-build-input:{item['name']}": (item["url"], item["sha256"])
        for item in lock["pythonBuildInputs"]
    })
    declared.update({
        f"bpy-native:{item['name']}": (
            item["url"],
            item["manifestHash"] if item["manifestHashType"] == "SHA256" else None,
        )
        for item in families
    })
    components = [component for item in archives for component in item.get("components", [])]
    if set(components) != set(declared) or len(components) != len(set(components)):
        fail("ready distribution source archive closure is incomplete")
    filenames = set()
    for item in archives:
        validate_artifact(item, f"distribution source {item.get('name')}", True)
        item_components = item.get("components", [])
        if not item_components:
            fail("distribution source archive has no declared components")
        for component in item_components:
            expected_url, expected_sha256 = declared[component]
            if item["url"] != expected_url or (
                expected_sha256 is not None and item["sha256"] != expected_sha256
            ):
                fail(f"distribution source {component}: artifact drift")
        filename = item.get("filename", "")
        if not SAFE_FILENAME.fullmatch(filename) or filename in filenames:
            fail("distribution source filenames must be safe and unique")
        filenames.add(filename)
    provenance = closure.get("wheelBinaryProvenance", {})
    validate_repository_evidence(provenance, "bpy wheel binary provenance")
    notices = closure.get("noticeFiles", [])
    if not notices:
        fail("ready distribution must include a notice inventory")
    evidence_names = [Path(provenance.get("path", "")).name]
    evidence_names += [Path(item.get("path", "")).name for item in notices]
    if len(evidence_names) != len(set(evidence_names)):
        fail("distribution evidence filenames must be unique")
    for index, item in enumerate(notices):
        validate_repository_evidence(item, f"distribution notice {index}")
    if not closure.get("reviewReference", "").strip():
        fail("ready distribution must name its combined-distribution review")


def validate(lock):
    if lock.get("schema") != "nexgenvideo/bpy-runtime-lock/1":
        fail("unexpected runtime lock schema")
    if lock.get("platform") != "macos-arm64" or lock.get("pythonABI") != "cp313":
        fail("runtime platform/ABI must stay macOS arm64 CPython 3.13")
    layout = lock.get("bpyWheelLayout", {})
    if layout.get("entryPoint") != "bpy/__init__.so" \
            or layout.get("recordPath") != "bpy-5.2.2.dist-info/RECORD":
        fail("unexpected bpy wheel entry point or RECORD path")
    native_libraries = layout.get("nativeLibraries", [])
    if len(native_libraries) != 43 or len(set(native_libraries)) != 43 \
            or native_libraries != sorted(native_libraries) \
            or not all(path.startswith("bpy/lib/") and path.endswith(".dylib")
                       for path in native_libraries):
        fail("bpy native-library inventory is incomplete or unstable")
    if not layout.get("inventoryEvidence") or not layout.get("sourceMappingStatus"):
        fail("bpy native-library provenance status is missing")
    if layout.get("officialBuildManifest") != (
        "https://raw.githubusercontent.com/blender/blender/v5.2.2/"
        "build_files/build_environment/cmake/versions.cmake"
    ):
        fail("unexpected Blender dependency-manifest evidence")
    families = layout.get("candidateSourceFamilies", [])
    family_names = [family.get("name") for family in families]
    if not family_names or len(family_names) != len(set(family_names)):
        fail("candidate source family names must be unique")
    mapped_libraries = [path for family in families for path in family.get("libraries", [])]
    if sorted(mapped_libraries) != native_libraries or len(mapped_libraries) != len(set(mapped_libraries)):
        fail("candidate source families do not cover the native-library inventory exactly once")
    for family in families:
        if not family.get("name") or not family.get("version") or not family.get("license"):
            fail("candidate source family metadata is incomplete")
        if not family.get("url", "").startswith("https://"):
            fail("candidate source family URL must use HTTPS")
        hash_type = family.get("manifestHashType")
        manifest_hash = family.get("manifestHash", "")
        if (hash_type == "MD5" and not MD5.fullmatch(manifest_hash)) or \
                (hash_type == "SHA256" and not SHA256.fullmatch(manifest_hash)) or \
                hash_type not in {"MD5", "SHA256"}:
            fail("candidate source family manifest hash is invalid")
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
    if status == "ready":
        validate_distribution_closure(lock, families)


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
