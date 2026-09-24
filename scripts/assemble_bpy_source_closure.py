#!/usr/bin/env python3
import argparse
import base64
import csv
import hashlib
import io
import json
import re
import shutil
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "Runtime/bpy/runtime-lock.json"
NOTICE_NAME = re.compile(r"^(license|licence|copying|copyright|notice)([._-].*)?$", re.I)
SAFE = re.compile(r"[^A-Za-z0-9._-]+")


def digest(path, algorithm="sha256"):
    value = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def fetch(url, destination, expected=None, algorithm="sha256"):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)
    if expected and digest(destination, algorithm.lower()) != expected.lower():
        raise ValueError(f"checksum mismatch: {url}")
    return {
        "sha256": digest(destination),
        "size": destination.stat().st_size,
    }


def cmake_sets(text):
    result = {}
    position = 0
    opener = re.compile(r"(?m)^\s*set\(")
    while match := opener.search(text, position):
        cursor = match.end()
        depth = 1
        quote = False
        bracket_end = None
        while cursor < len(text) and depth:
            if bracket_end:
                if text.startswith(bracket_end, cursor):
                    cursor += len(bracket_end)
                    bracket_end = None
                    continue
            elif not quote and text[cursor] == "[":
                bracket = re.match(r"\[(=*)\[", text[cursor:])
                if bracket:
                    bracket_end = "]" + bracket.group(1) + "]"
                    cursor += len(bracket.group(0))
                    continue
            elif text[cursor] == '"' and (cursor == 0 or text[cursor - 1] != "\\"):
                quote = not quote
            elif not quote and text[cursor] == "(":
                depth += 1
            elif not quote and text[cursor] == ")":
                depth -= 1
                if depth == 0:
                    break
            cursor += 1
        if depth:
            raise ValueError("unterminated set() in Blender versions manifest")
        body = text[match.end():cursor].strip()
        position = cursor + 1
        parts = body.split(None, 1)
        if not parts:
            continue
        key = parts[0]
        value = parts[1].strip() if len(parts) == 2 else ""
        bracket = re.fullmatch(r"\[(=*)\[(.*)\]\1\]", value, re.S)
        if bracket:
            value = bracket.group(2).strip()
        elif len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        elif " #" in value:
            value = value.split(" #", 1)[0].rstrip()
        result[key] = value

    variable = re.compile(r"\$\{([A-Za-z0-9_]+)\}")
    for _ in range(20):
        changed = False
        for key, value in list(result.items()):
            expanded = variable.sub(lambda item: result.get(item.group(1), item.group(0)), value)
            if expanded != value:
                result[key] = expanded
                changed = True
        if not changed:
            break
    return result


def blender_dependencies(text):
    values = cmake_sets(text)
    dependencies = []
    for key in sorted({name[:-4] for name in values if name.endswith("_URI")}):
        required = [f"{key}_VERSION", f"{key}_URI", f"{key}_HASH", f"{key}_HASH_TYPE"]
        if not all(values.get(name) for name in required):
            missing = [name for name in required if not values.get(name)]
            raise ValueError(f"incomplete Blender dependency record: {key}: {missing}")
        url = values[f"{key}_URI"]
        if "${" in url:
            raise ValueError(f"unresolved Blender dependency URL: {key}={url}")
        hash_type = values[f"{key}_HASH_TYPE"].upper()
        if hash_type not in {"MD5", "SHA256"}:
            raise ValueError(f"unsupported Blender dependency hash: {key}={hash_type}")
        dependencies.append({
            "key": key,
            "name": values.get(f"{key}_NAME", key),
            "version": values[f"{key}_VERSION"],
            "url": url,
            "filename": values.get(f"{key}_FILE") or Path(urllib.parse.urlparse(url).path).name,
            "upstreamHash": values[f"{key}_HASH"].strip(),
            "upstreamHashType": hash_type,
            "license": values.get(f"{key}_LICENSE"),
            "copyright": values.get(f"{key}_COPYRIGHT"),
            "homepage": values.get(f"{key}_HOMEPAGE"),
            "buildTimeOnly": values.get(f"{key}_DEPSBUILDTIMEONLY"),
        })
    return dependencies


def member_bytes(archive, suffix):
    with tarfile.open(archive, "r:*") as value:
        matches = [item for item in value.getmembers() if item.isfile() and item.name.endswith(suffix)]
        if len(matches) != 1:
            raise ValueError(f"expected one {suffix} in {archive.name}, found {len(matches)}")
        return value.extractfile(matches[0]).read()


def build_file_inventory(archive):
    result = []
    with tarfile.open(archive, "r:*") as value:
        for item in sorted(value.getmembers(), key=lambda candidate: candidate.name):
            marker = "/build_files/build_environment/"
            if not item.isfile() or marker not in item.name:
                continue
            data = value.extractfile(item).read()
            result.append({
                "path": item.name.split(marker, 1)[1],
                "sha256": hashlib.sha256(data).hexdigest(),
                "size": len(data),
            })
    return result


def notice_payloads(archive, component):
    found = []
    try:
        if zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as value:
                for name in sorted(value.namelist()):
                    info = value.getinfo(name)
                    if info.is_dir() or not NOTICE_NAME.fullmatch(Path(name).name):
                        continue
                    if info.file_size <= 2 * 1024 * 1024:
                        found.append((name, value.read(name)))
        elif tarfile.is_tarfile(archive):
            with tarfile.open(archive, "r:*") as value:
                for item in sorted(value.getmembers(), key=lambda candidate: candidate.name):
                    if not item.isfile() or not NOTICE_NAME.fullmatch(Path(item.name).name):
                        continue
                    if 0 <= item.size <= 2 * 1024 * 1024:
                        found.append((item.name, value.extractfile(item).read()))
    except (tarfile.TarError, zipfile.BadZipFile, OSError):
        return []
    prefix = SAFE.sub("-", component).strip("-")
    return [
        (f"notices/{prefix}/{index:03d}-{Path(name).name}", payload)
        for index, (name, payload) in enumerate(found[:128], 1)
    ]


def verify_bpy_wheel(path, lock):
    layout = lock["bpyWheelLayout"]
    with zipfile.ZipFile(path) as wheel:
        record_data = wheel.read(layout["recordPath"])
        rows = {
            row[0]: row[1:]
            for row in csv.reader(io.StringIO(record_data.decode("utf-8")))
        }
        evidence = []
        for relative in [layout["entryPoint"], *layout["nativeLibraries"]]:
            payload = wheel.read(relative)
            encoded = base64.urlsafe_b64encode(hashlib.sha256(payload).digest()).decode().rstrip("=")
            fields = rows.get(relative)
            if fields != [f"sha256={encoded}", str(len(payload))]:
                raise ValueError(f"wheel RECORD mismatch: {relative}")
            evidence.append({
                "path": relative,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size": len(payload),
            })
    return evidence, record_data


def normalized_tar(output, files):
    with tarfile.open(output, "w", format=tarfile.PAX_FORMAT) as archive:
        for name, source in sorted(files.items()):
            data = source if isinstance(source, bytes) else source.read_bytes()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()
    lock = json.loads(LOCK_PATH.read_text())
    output = args.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="ngv-bpy-source-") as temporary:
        work = Path(temporary)
        artifacts = {}
        sources = []
        notices = {}

        def add_source(component, name, version, url, expected, hash_type, filename, license_name=None):
            safe_component = SAFE.sub("-", component).strip("-")
            destination = work / "downloads" / safe_component / Path(filename).name
            facts = fetch(url, destination, expected, hash_type)
            archive_path = f"sources/{safe_component}/{Path(filename).name}"
            artifacts[archive_path] = destination
            notice_entries = notice_payloads(destination, component)
            for notice_path, payload in notice_entries:
                notices[notice_path] = payload
            source = {
                "component": component,
                "name": name,
                "version": version,
                "url": url,
                "upstreamHash": expected,
                "upstreamHashType": hash_type.upper(),
                "sha256": facts["sha256"],
                "size": facts["size"],
                "archivePath": archive_path,
                "license": license_name,
                "noticePaths": [path for path, _ in notice_entries],
            }
            if not notice_entries:
                candidate_path = f"notices/{safe_component}/NOTICE-CANDIDATE.json"
                payload = json.dumps({
                    "component": component,
                    "declaredLicense": license_name,
                    "sourceArchive": destination.name,
                    "status": "candidate-only; replace with required upstream notice text before distribution",
                }, sort_keys=True, indent=2).encode() + b"\n"
                notices[candidate_path] = payload
                source["noticePaths"] = [candidate_path]
                source["noticeCandidateOnly"] = True
            sources.append(source)
            return destination

        bpy = next(item for item in lock["wheels"] if item["name"] == "bpy")
        blender_archive = add_source(
            "wheel:bpy", "Blender", bpy["version"], bpy["source"]["url"],
            bpy["source"]["sha256"], "SHA256", "blender-5.2.2.tar.xz", bpy["license"],
        )
        versions_data = member_bytes(
            blender_archive,
            "/build_files/build_environment/cmake/versions.cmake",
        )
        expected_versions = lock["bpyWheelLayout"]["officialBuildManifestSHA256"]
        if hashlib.sha256(versions_data).hexdigest() != expected_versions:
            raise ValueError("Blender release dependency manifest drift")
        artifacts["evidence/blender-5.2.2-versions.cmake"] = versions_data

        for dependency in blender_dependencies(versions_data.decode("utf-8")):
            component = f"blender-release-dependency:{dependency['key']}"
            archive = add_source(
                component,
                dependency["name"],
                dependency["version"],
                dependency["url"],
                dependency["upstreamHash"],
                dependency["upstreamHashType"],
                dependency["filename"],
                dependency["license"],
            )
            sources[-1]["buildTimeOnly"] = dependency["buildTimeOnly"]
            sources[-1]["homepage"] = dependency["homepage"]
            if sources[-1].get("noticeCandidateOnly"):
                candidate_path = sources[-1]["noticePaths"][0]
                notices[candidate_path] = json.dumps({
                    "component": component,
                    "declaredLicense": dependency["license"],
                    "declaredCopyright": dependency["copyright"],
                    "homepage": dependency["homepage"],
                    "sourceArchive": archive.name,
                    "status": "candidate-only; replace with required upstream notice text before distribution",
                }, sort_keys=True, indent=2).encode() + b"\n"

        runtime = lock["runtime"]
        add_source(
            "python-build-standalone", runtime["name"], runtime["version"],
            runtime["source"]["url"], runtime["source"]["sha256"], "SHA256",
            "python-build-standalone-20260901.tar.gz", runtime["source"]["license"],
        )
        sources[-1]["sourceRevision"] = runtime["sourceCommit"]
        for item in lock["pythonBuildInputs"]:
            add_source(
                f"python-build-input:{item['name']}", item["name"], item["version"],
                item["url"], item["sha256"], "SHA256", Path(urllib.parse.urlparse(item["url"]).path).name,
                item["license"],
            )
        for item in lock["wheels"]:
            if item["name"] != "bpy":
                add_source(
                    f"wheel:{item['name']}", item["name"], item["version"],
                    item["source"]["url"], item["source"]["sha256"], "SHA256",
                    Path(urllib.parse.urlparse(item["source"]["url"]).path).name, item["license"],
                )

        wheel_path = work / bpy["filename"]
        wheel_facts = fetch(bpy["url"], wheel_path, bpy["sha256"], "SHA256")
        if wheel_facts["size"] != bpy["size"]:
            raise ValueError("pinned bpy wheel size drift")
        metadata_path = work / (bpy["filename"] + ".metadata")
        metadata_facts = fetch(
            bpy["metadata"]["url"], metadata_path, bpy["metadata"]["sha256"], "SHA256"
        )
        metadata_text = metadata_path.read_text(encoding="utf-8")
        expected_metadata = [
            f"Name: {bpy['name']}",
            f"Version: {bpy['version']}",
            f"License: {bpy['metadata']['license']}",
            f"Requires-Python: {bpy['metadata']['requiresPython']}",
        ]
        if any(f"\n{line}\n" not in f"\n{metadata_text}\n" for line in expected_metadata) \
                or any(url not in metadata_text for url in bpy["metadata"]["sourceCodeURLs"]):
            raise ValueError("pinned bpy metadata no longer links the declared release source")
        record_evidence, record_data = verify_bpy_wheel(wheel_path, lock)
        metadata_evidence_path = f"evidence/{metadata_path.name}"
        record_evidence_path = f"evidence/{Path(bpy['metadata']['url']).name}.RECORD.csv"
        artifacts[metadata_evidence_path] = metadata_path
        artifacts[record_evidence_path] = record_data
        for notice_path, payload in notice_payloads(wheel_path, "wheel-bpy-binary"):
            notices[notice_path] = payload

        provenance_complete = False
        notice_complete = False
        provenance_evidence = None
        notice_coverage_evidence = None
        closure = lock.get("distributionClosure") or {}
        if lock.get("distributionStatus") == "ready":
            provenance_item = closure.get("wheelBinaryProvenance", {})
            provenance_path = ROOT / provenance_item.get("path", "")
            provenance_data = provenance_path.read_bytes()
            if hashlib.sha256(provenance_data).hexdigest() != provenance_item.get("sha256"):
                raise ValueError("committed wheel provenance evidence drift")
            provenance = json.loads(provenance_data)
            expected_components = sorted(item["component"] for item in sources)
            if provenance.get("schema") != "nexgenvideo/bpy-wheel-build-provenance/1" \
                    or provenance.get("wheelSHA256") != bpy["sha256"] \
                    or provenance.get("releaseSourceSHA256") != bpy["source"]["sha256"] \
                    or provenance.get("releaseBuildManifestSHA256") != expected_versions \
                    or sorted(provenance.get("closureComponents", [])) != expected_components:
                raise ValueError("committed wheel provenance does not bind the full source closure")
            build_inputs = provenance.get("buildInputComponents", [])
            if not build_inputs or len(build_inputs) != len(set(build_inputs)) \
                    or not set(build_inputs).issubset(expected_components) \
                    or "wheel:bpy" not in build_inputs:
                raise ValueError("committed wheel provenance does not identify exact build inputs")
            provenance_evidence = f"evidence/{provenance_path.name}"
            artifacts[provenance_evidence] = provenance_data
            provenance_complete = True

            notice_items = closure.get("noticeFiles", [])
            notice_evidence = {}
            for item in notice_items:
                path = ROOT / item["path"]
                payload = path.read_bytes()
                if hashlib.sha256(payload).hexdigest() != item["sha256"]:
                    raise ValueError(f"committed notice evidence drift: {path}")
                bundled = f"notices/distribution/{path.name}"
                notices[bundled] = payload
                notice_evidence[item["path"]] = bundled
            coverage_item = closure.get("noticeCoverage", {})
            coverage_path = ROOT / coverage_item.get("path", "")
            coverage_data = coverage_path.read_bytes()
            if hashlib.sha256(coverage_data).hexdigest() != coverage_item.get("sha256"):
                raise ValueError("committed notice coverage drift")
            coverage = json.loads(coverage_data)
            if coverage.get("schema") != "nexgenvideo/bpy-notice-coverage/1" \
                    or set(coverage.get("components", {})) != set(expected_components):
                raise ValueError("notice coverage does not name every source component")
            for source in sources:
                paths = coverage["components"][source["component"]]
                if not paths or any(path not in notice_evidence for path in paths):
                    raise ValueError(f"notice coverage is incomplete: {source['component']}")
                for candidate in source["noticePaths"]:
                    if candidate.endswith("NOTICE-CANDIDATE.json"):
                        notices.pop(candidate, None)
                source["noticePaths"] = [notice_evidence[path] for path in paths]
                source.pop("noticeCandidateOnly", None)
            notice_coverage_evidence = f"evidence/{coverage_path.name}"
            artifacts[notice_coverage_evidence] = coverage_data
            notice_complete = True

        for path, payload in notices.items():
            artifacts[path] = payload
        manifest = {
            "schema": "nexgenvideo/bpy-source-closure/1",
            "release": "bpy-5.2.2-cp313-macos-arm64",
            "binaryCorrespondence": {
                "wheelFilename": bpy["filename"],
                "wheelURL": bpy["url"],
                "wheelSHA256": wheel_facts["sha256"],
                "wheelSize": wheel_facts["size"],
                "metadataURL": bpy["metadata"]["url"],
                "metadataSHA256": metadata_facts["sha256"],
                "metadataPath": metadata_evidence_path,
                "metadataSourceCodeURLs": bpy["metadata"]["sourceCodeURLs"],
                "releaseSourceURL": bpy["source"]["url"],
                "releaseSourceSHA256": bpy["source"]["sha256"],
                "recordPath": record_evidence_path,
                "recordEntries": record_evidence,
                "nativeSourceCandidates": lock["bpyWheelLayout"]["candidateSourceFamilies"],
                "status": (
                    "official per-wheel build-input correspondence preserved"
                    if provenance_complete else
                    "release-linked; upstream per-wheel dependency/build-input attestation unresolved"
                ),
            },
            "releaseBuildManifest": {
                "url": lock["bpyWheelLayout"]["officialBuildManifest"],
                "sha256": expected_versions,
                "path": "evidence/blender-5.2.2-versions.cmake",
            },
            "releaseBuildFiles": build_file_inventory(blender_archive),
            "sources": sorted(sources, key=lambda item: item["component"]),
            "notices": [
                {"path": path, "sha256": hashlib.sha256(payload).hexdigest(), "size": len(payload)}
                for path, payload in sorted(notices.items())
            ],
            "noticeComplete": notice_complete,
            "provenanceComplete": provenance_complete,
            "provenanceEvidence": provenance_evidence,
            "noticeCoverageEvidence": notice_coverage_evidence,
            "legalBoundary": {
                "sourceMustMatchBuildInputs": True,
                "bitIdenticalRebuildRequired": False,
                "processBoundaryTreatedAsGPLException": False,
            },
        }
        manifest_data = json.dumps(manifest, sort_keys=True, indent=2).encode() + b"\n"
        artifacts["manifest.json"] = manifest_data
        archive_output = output / "NexGenVideo-bpy-5.2.2-corresponding-source.tar"
        normalized_tar(archive_output, artifacts)
        (output / "NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json").write_bytes(
            manifest_data
        )
        print(json.dumps({
            "archive": str(archive_output),
            "sha256": digest(archive_output),
            "size": archive_output.stat().st_size,
            "sourceCount": len(sources),
            "noticeCount": len(notices),
            "provenanceComplete": provenance_complete,
            "noticeComplete": notice_complete,
        }, sort_keys=True))


if __name__ == "__main__":
    main()
