#!/usr/bin/env python3
import argparse
import base64
import concurrent.futures
import hashlib
import json
import re
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path


FOLDERS = {
    "OpenEXR": "openexr", "Imath": "imath", "MaterialX": "materialx",
    "OpenColorIO": "opencolorio", "OpenImageDenoise": "openimagedenoise",
    "OpenImageIO": "openimageio", "SDL": "sdl", "Ceres Solver": "ceres",
    "Draco": "draco", "Embree": "embree", "meshoptimizer": "meshoptimizer",
    "OpenJPH": "openjph", "OpenVDB": "openvdb", "OpenXR SDK": "xr_openxr_sdk",
    "OpenSubdiv": "opensubdiv", "Open Shading Language": "osl",
    "oneTBB": "tbb", "OpenUSD": "usd",
}


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "NexGenVideo-source-evidence"})
    with urllib.request.urlopen(request, timeout=45) as response:
        return response.read()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wheel", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    args = parser.parse_args()
    lock = json.loads(args.lock.read_text())
    wheel = next(item for item in lock["wheels"] if item["name"] == "bpy")
    wheel_data = args.wheel.read_bytes()
    if digest(wheel_data) != wheel["sha256"] or len(wheel_data) != wheel["size"]:
        raise SystemExit("wheel bytes differ from the runtime lock")
    release = lock["bpyWheelLayout"]["officialReleaseCommit"]
    submodule_url = f"https://api.github.com/repos/blender/blender/contents/lib/macos_arm64?ref={release}"
    submodule_data = download(submodule_url)
    submodule = json.loads(submodule_data)
    revision = submodule["sha"]
    repository = "https://projects.blender.org/blender/lib-macos_arm64"
    if submodule["submodule_git_url"] != repository + ".git":
        raise SystemExit("Blender release has an unexpected library source")
    base = "https://projects.blender.org/api/v1/repos/blender/lib-macos_arm64/contents/"

    def contents(path):
        url = base + urllib.parse.quote(path, safe="/") + "?ref=" + revision
        response = json.loads(download(url))
        return base64.b64decode(response["content"], validate=False), url

    deps, deps_url = contents("deps.md")
    expected = []
    with zipfile.ZipFile(args.wheel) as archive:
        for family in lock["bpyWheelLayout"]["candidateSourceFamilies"]:
            for path in family["libraries"]:
                data = archive.read(path)
                expected.append((family["name"], path, digest(data), len(data)))

    def inspect(item):
        family, path, sha256, size = item
        source_path = f"{FOLDERS[family]}/lib/{Path(path).name}"
        pointer, url = contents(source_path)
        match = re.fullmatch(
            rb"version https://git-lfs.github.com/spec/v1\noid sha256:([a-f0-9]{64})\nsize ([0-9]+)\n?",
            pointer,
        )
        if not match or match[1].decode() != sha256 or int(match[2]) != size:
            raise ValueError(f"wheel library differs from the official release: {path}")
        return {
            "family": family, "wheelPath": path, "sha256": sha256, "size": size,
            "officialLibraryPath": source_path, "pointerURL": url,
            "pointerSHA256": digest(pointer), "pointer": pointer.decode(),
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        libraries = list(pool.map(inspect, expected))
    args.output_directory.mkdir(parents=True, exist_ok=True)
    (args.output_directory / "blender-release-library-submodule.json").write_bytes(submodule_data)
    (args.output_directory / "blender-library-dependencies.md").write_bytes(deps)
    evidence = {
        "schema": "nexgenvideo/bpy-official-library-correspondence/1",
        "wheelSHA256": wheel["sha256"], "wheelSize": wheel["size"],
        "officialReleaseCommit": release, "libraryRepository": repository,
        "libraryCommit": revision, "releaseSubmoduleURL": submodule_url,
        "releaseSubmoduleResponseSHA256": digest(submodule_data),
        "dependencyManifest": {"path": "blender-library-dependencies.md", "sha256": digest(deps), "url": deps_url},
        "libraries": sorted(libraries, key=lambda item: item["wheelPath"]),
        "scope": "Exact bytes of all 43 shipped native libraries match the official release submodule. The dependency manifest identifies source versions; the Blender source archive supplies recipes and patches. This does not assert that every platform dependency candidate was linked or that native runtime acceptance passed.",
    }
    (args.output_directory / "official-library-correspondence.json").write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n"
    )
    print(f"Recorded {len(libraries)} exact official-library matches at {revision}")


if __name__ == "__main__":
    main()
