import hashlib
import json
import re


def validate_library_evidence(lock, payloads, records=None):
    references = lock["bpyWheelLayout"]["officialLibraryEvidence"]
    for key, item in references.items():
        if hashlib.sha256(payloads[key]).hexdigest() != item["sha256"]:
            raise ValueError(f"official library evidence changed: {key}")
    evidence = json.loads(payloads["correspondence"])
    submodule = json.loads(payloads["releaseSubmodule"])
    wheel = next(item for item in lock["wheels"] if item["name"] == "bpy")
    if evidence["schema"] != "nexgenvideo/bpy-official-library-correspondence/1" \
            or evidence["wheelSHA256"] != wheel["sha256"] \
            or evidence["wheelSize"] != wheel["size"] \
            or evidence["officialReleaseCommit"] != lock["bpyWheelLayout"]["officialReleaseCommit"] \
            or evidence["libraryCommit"] != submodule["sha"] \
            or submodule["submodule_git_url"] != evidence["libraryRepository"] + ".git" \
            or evidence["dependencyManifest"]["sha256"] != references["dependencies"]["sha256"] \
            or evidence["releaseSubmoduleResponseSHA256"] != references["releaseSubmodule"]["sha256"]:
        raise ValueError("official library release linkage changed")
    libraries = evidence["libraries"]
    if sorted(item["wheelPath"] for item in libraries) != lock["bpyWheelLayout"]["nativeLibraries"]:
        raise ValueError("official library evidence does not cover the exact native inventory")
    families = {item["name"]: item for item in lock["bpyWheelLayout"]["candidateSourceFamilies"]}
    dependency_versions = dict(re.findall(
        r"\| `([^`]+)` \| `([^`]+)` \|", payloads["dependencies"].decode()
    ))
    dependency_names = {
        "OpenEXR": "OPENEXR", "Imath": "IMATH", "MaterialX": "MATERIALX",
        "OpenColorIO": "OPENCOLORIO", "OpenImageDenoise": "OIDN", "OpenImageIO": "OPENIMAGEIO",
        "SDL": "SDL", "Ceres Solver": "CERES", "Draco": "DRACO", "Embree": "EMBREE",
        "meshoptimizer": "MESHOPTIMIZER", "OpenJPH": "OPENJPH", "OpenVDB": "OPENVDB",
        "OpenXR SDK": "XR_OPENXR_SDK", "OpenSubdiv": "OPENSUBDIV", "Open Shading Language": "OSL",
        "oneTBB": "TBB", "OpenUSD": "USD",
    }
    for item in libraries:
        pointer = item["pointer"].encode()
        match = re.fullmatch(rb"version https://git-lfs.github.com/spec/v1\noid sha256:([a-f0-9]{64})\nsize ([0-9]+)\n?", pointer)
        if not match or hashlib.sha256(pointer).hexdigest() != item["pointerSHA256"] \
                or match[1].decode() != item["sha256"] or int(match[2]) != item["size"]:
            raise ValueError("official LFS pointer differs from the wheel library")
        family = families[item["family"]]
        if item["wheelPath"] not in family["libraries"] \
                or family["version"].lstrip("v") != dependency_versions[dependency_names[item["family"]]].lstrip("v"):
            raise ValueError("official dependency manifest does not bind the native family")
        if records is not None and records.get(item["wheelPath"]) != (item["sha256"], item["size"]):
            raise ValueError("official library differs from the independently verified wheel RECORD")
    return evidence
