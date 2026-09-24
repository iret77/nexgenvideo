#!/usr/bin/env python3
import argparse
import base64
import csv
import hashlib
import io
import json
import tarfile
from pathlib import Path, PurePosixPath

from assemble_bpy_source_closure import blender_dependencies


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "Runtime/bpy/runtime-lock.json"


def fail(message):
    raise ValueError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class ClosureArchive:
    def __init__(self, path):
        self.archive = tarfile.open(path, "r:")
        self.members = {}
        for item in self.archive.getmembers():
            pure = PurePosixPath(item.name)
            if not item.isfile() or pure.is_absolute() or ".." in pure.parts \
                    or item.name in self.members:
                fail("source closure contains an unsafe or duplicate member")
            self.members[item.name] = item

    def close(self):
        self.archive.close()

    def read(self, name):
        item = self.members.get(name)
        if item is None:
            return None
        return self.archive.extractfile(item).read()

    def digest(self, name, algorithms):
        item = self.members.get(name)
        if item is None:
            return None
        values = {algorithm: hashlib.new(algorithm) for algorithm in algorithms}
        handle = self.archive.extractfile(item)
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            for value in values.values():
                value.update(chunk)
        return {algorithm: value.hexdigest() for algorithm, value in values.items()}

    def size(self, name):
        item = self.members.get(name)
        return None if item is None else item.size

    @property
    def names(self):
        return set(self.members)


def build_file_inventory(source_archive):
    result = []
    with tarfile.open(fileobj=io.BytesIO(source_archive), mode="r:*") as archive:
        for item in sorted(archive.getmembers(), key=lambda candidate: candidate.name):
            marker = "/build_files/build_environment/"
            if not item.isfile() or marker not in item.name:
                continue
            data = archive.extractfile(item).read()
            result.append({
                "path": item.name.split(marker, 1)[1],
                "sha256": sha256(data),
                "size": len(data),
            })
    return result


def validate(archive_path, manifest_path, require_distributable=False):
    lock = json.loads(LOCK_PATH.read_text())
    members = ClosureArchive(archive_path)
    external = manifest_path.read_bytes()
    if members.read("manifest.json") != external:
        fail("external and archived source-closure manifests differ")
    manifest = json.loads(external)
    if manifest.get("schema") != "nexgenvideo/bpy-source-closure/1":
        fail("unexpected source-closure schema")

    bpy = next(item for item in lock["wheels"] if item["name"] == "bpy")
    binary = manifest.get("binaryCorrespondence", {})
    plan = lock["sourceClosurePlan"]["binaryCorrespondence"]
    if binary.get("wheelFilename") != plan["wheel"] \
            or binary.get("wheelSHA256") != plan["wheelSHA256"] \
            or binary.get("wheelSize") != bpy["size"] \
            or binary.get("metadataSHA256") != plan["wheelMetadataSHA256"] \
            or binary.get("metadataSourceCodeURLs") != bpy["metadata"]["sourceCodeURLs"] \
            or binary.get("nativeSourceCandidates") \
            != lock["bpyWheelLayout"]["candidateSourceFamilies"] \
            or binary.get("releaseSourceSHA256") != plan["releaseSourceSHA256"]:
        fail("source closure is not bound to the pinned bpy binary/release inputs")

    metadata_data = members.read(binary.get("metadataPath"))
    if metadata_data is None or sha256(metadata_data) != plan["wheelMetadataSHA256"]:
        fail("pinned bpy metadata evidence is missing")
    metadata_text = metadata_data.decode("utf-8")
    for line in [
        f"Name: {bpy['name']}",
        f"Version: {bpy['version']}",
        f"License: {bpy['metadata']['license']}",
        f"Requires-Python: {bpy['metadata']['requiresPython']}",
    ]:
        if f"\n{line}\n" not in f"\n{metadata_text}\n":
            fail("pinned bpy metadata identity drift")
    for url in bpy["metadata"]["sourceCodeURLs"]:
        if url not in metadata_text:
            fail("pinned bpy metadata does not contain the declared release-source link")

    records = binary.get("recordEntries", [])
    expected_paths = [
        lock["bpyWheelLayout"]["entryPoint"],
        *lock["bpyWheelLayout"]["nativeLibraries"],
    ]
    if [item.get("path") for item in records] != expected_paths \
            or not all(len(item.get("sha256", "")) == 64 and item.get("size", 0) > 0 for item in records):
        fail("pinned wheel RECORD/native evidence is incomplete")
    record_data = members.read(binary.get("recordPath"))
    if record_data is None:
        fail("pinned wheel RECORD evidence is missing")
    record_rows = {
        row[0]: row[1:]
        for row in csv.reader(io.StringIO(record_data.decode("utf-8")))
    }
    for item in records:
        encoded = base64.urlsafe_b64encode(bytes.fromhex(item["sha256"])).decode().rstrip("=")
        if record_rows.get(item["path"]) != [f"sha256={encoded}", str(item["size"])]:
            fail(f"pinned wheel RECORD evidence drift: {item['path']}")

    release_manifest = manifest.get("releaseBuildManifest", {})
    versions_path = release_manifest.get("path")
    versions_data = members.read(versions_path)
    if versions_data is None \
            or sha256(versions_data) != plan["releaseBuildManifestSHA256"] \
            or release_manifest.get("sha256") != plan["releaseBuildManifestSHA256"]:
        fail("exact Blender release build manifest is missing")
    dependencies = blender_dependencies(versions_data.decode("utf-8"))

    expected_sources = {
        "python-build-standalone": {
            "name": lock["runtime"]["name"],
            "version": lock["runtime"]["version"],
            "url": lock["runtime"]["source"]["url"],
            "upstreamHash": lock["runtime"]["source"]["sha256"],
            "upstreamHashType": "SHA256",
            "sourceRevision": lock["runtime"]["sourceCommit"],
        },
    }
    expected_sources.update({
        f"wheel:{item['name']}": {
            "name": "Blender" if item["name"] == "bpy" else item["name"],
            "version": item["version"],
            "url": item["source"]["url"],
            "upstreamHash": item["source"]["sha256"],
            "upstreamHashType": "SHA256",
        }
        for item in lock["wheels"]
    })
    expected_sources.update({
        f"python-build-input:{item['name']}": {
            "name": item["name"],
            "version": item["version"],
            "url": item["url"],
            "upstreamHash": item["sha256"],
            "upstreamHashType": "SHA256",
        }
        for item in lock["pythonBuildInputs"]
    })
    expected_sources.update({
        f"blender-release-dependency:{item['key']}": {
            "name": item["name"],
            "version": item["version"],
            "url": item["url"],
            "upstreamHash": item["upstreamHash"],
            "upstreamHashType": item["upstreamHashType"],
        }
        for item in dependencies
    })
    expected_components = set(expected_sources)
    sources = manifest.get("sources", [])
    components = [item.get("component") for item in sources]
    if set(components) != expected_components or len(components) != len(set(components)):
        fail("source closure does not cover every release, Python, wheel, static, and transitive candidate")
    for source in sources:
        member_path = source.get("archivePath")
        algorithms = {"sha256", source.get("upstreamHashType", "").lower()}
        digests = members.digest(member_path, algorithms)
        if digests is None or members.size(member_path) != source.get("size") \
                or digests["sha256"] != source.get("sha256"):
            fail(f"source archive mismatch: {source.get('component')}")
        expected = expected_sources[source["component"]]
        if any(source.get(key) != value for key, value in expected.items()):
            fail(f"source release metadata mismatch: {source['component']}")
        algorithm = source["upstreamHashType"].lower()
        if digests[algorithm] != source["upstreamHash"].lower():
            fail(f"source upstream checksum mismatch: {source['component']}")
        notice_paths = source.get("noticePaths", [])
        if not notice_paths or any(path not in members.names for path in notice_paths):
            fail(f"source notice coverage missing: {source.get('component')}")

    notices = manifest.get("notices", [])
    notice_paths = [item.get("path") for item in notices]
    if len(notice_paths) != len(set(notice_paths)):
        fail("notice inventory contains duplicates")
    for notice in notices:
        notice_path = notice.get("path")
        digests = members.digest(notice_path, {"sha256"})
        if digests is None or members.size(notice_path) != notice.get("size") \
                or digests["sha256"] != notice.get("sha256"):
            fail(f"notice mismatch: {notice.get('path')}")

    build_files = manifest.get("releaseBuildFiles", [])
    build_paths = {item.get("path") for item in build_files}
    blender_source_path = next(
        item["archivePath"] for item in sources if item["component"] == "wheel:bpy"
    )
    if "cmake/versions.cmake" not in build_paths \
            or not any("patch" in path.lower() for path in build_paths if path) \
            or build_files != build_file_inventory(members.read(blender_source_path)):
        fail("Blender build recipes/patch inventory is incomplete")

    legal = manifest.get("legalBoundary", {})
    if legal != {
        "sourceMustMatchBuildInputs": True,
        "bitIdenticalRebuildRequired": False,
        "processBoundaryTreatedAsGPLException": False,
    }:
        fail("source-distribution boundary drift")
    if manifest.get("provenanceComplete"):
        provenance_data = members.read(manifest.get("provenanceEvidence"))
        if provenance_data is None:
            fail("completed provenance evidence is missing")
        provenance = json.loads(provenance_data)
        if provenance.get("schema") != "nexgenvideo/bpy-wheel-build-provenance/1" \
                or provenance.get("wheelSHA256") != plan["wheelSHA256"] \
                or provenance.get("releaseSourceSHA256") != plan["releaseSourceSHA256"] \
                or provenance.get("releaseBuildManifestSHA256") != plan["releaseBuildManifestSHA256"] \
                or set(provenance.get("closureComponents", [])) != expected_components:
            fail("completed provenance evidence does not bind the source closure")
        build_inputs = provenance.get("buildInputComponents", [])
        if not build_inputs or len(build_inputs) != len(set(build_inputs)) \
                or not set(build_inputs).issubset(expected_components) \
                or "wheel:bpy" not in build_inputs:
            fail("completed provenance evidence does not identify exact build inputs")
    if manifest.get("noticeComplete"):
        coverage_data = members.read(manifest.get("noticeCoverageEvidence"))
        if coverage_data is None:
            fail("completed notice coverage evidence is missing")
        coverage = json.loads(coverage_data)
        if coverage.get("schema") != "nexgenvideo/bpy-notice-coverage/1" \
                or set(coverage.get("components", {})) != expected_components:
            fail("completed notice coverage does not bind the source closure")
    if require_distributable:
        if lock.get("distributionStatus") != "ready":
            fail("runtime lock remains fail-closed for public distribution")
        if not manifest.get("provenanceComplete"):
            fail("upstream per-wheel build-input provenance remains unresolved")
        if not manifest.get("noticeComplete"):
            fail("required notice text still contains candidate-only entries")
        if binary.get("status") != "official per-wheel build-input correspondence preserved":
            fail("binary/source correspondence status remains unresolved")
    expected_members = {
        "manifest.json",
        versions_path,
        binary.get("metadataPath"),
        binary.get("recordPath"),
    }
    expected_members.update(source["archivePath"] for source in sources)
    expected_members.update(notice["path"] for notice in notices)
    for evidence in [manifest.get("provenanceEvidence"), manifest.get("noticeCoverageEvidence")]:
        if evidence:
            expected_members.add(evidence)
    if members.names != expected_members:
        fail("source closure contains unmanifested or missing files")
    members.close()
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--require-distributable", action="store_true")
    args = parser.parse_args()
    value = validate(args.archive, args.manifest, args.require_distributable)
    print(json.dumps({
        "sources": len(value["sources"]),
        "notices": len(value["notices"]),
        "provenanceComplete": value["provenanceComplete"],
        "noticeComplete": value["noticeComplete"],
    }, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError, json.JSONDecodeError, tarfile.TarError) as error:
        raise SystemExit(f"invalid bpy source closure: {error}")
