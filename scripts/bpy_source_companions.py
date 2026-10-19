import hashlib
import io
import json
import re
import zipfile
from pathlib import Path


EVIDENCE_PATH = "evidence/source-companions.json"
NOTICE_PREFIX = "notices/source-companions/"
SHA256 = re.compile(r"[0-9a-f]{64}")


def repository_payload(root, pin):
    relative = pin.get("path", "")
    path = root / relative
    if (not relative.startswith("Runtime/bpy/compliance/") or ".." in Path(relative).parts
        or path.is_symlink() or not path.is_file()
        or not path.resolve().is_relative_to((root / "Runtime/bpy/compliance").resolve())):
        raise ValueError("source companion repository evidence is missing or unsafe")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != pin.get("sha256"):
        raise ValueError("source companion repository evidence hash mismatch")
    return data


def load_companions(lock, root):
    value = json.loads(repository_payload(root, lock.get("sourceCompanions", {})))
    items = value.get("companions", [])
    if (value.get("schema") != "nexgenvideo/bpy-source-companions/1" or len(items) != 1
        or items[0].get("component") != "blender-release-source:FLEXBISON"):
        raise ValueError("required FLEXBISON source companion is missing")
    for item in items:
        source, dependency = item["source"], item["dependency"]
        commit = item.get("commit", "")
        if (not re.fullmatch(r"[0-9a-f]{40}", commit) or item.get("tag") != "v" + item["version"]
            or source.get("url") != "https://codeload.github.com/lexxmark/winflexbison/tar.gz/" + commit
            or source.get("filename") != "winflexbison-" + commit + ".tar.gz"
            or dependency.get("component") != "blender-release-dependency:FLEXBISON"
            or dependency.get("version") != item["version"]):
            raise ValueError("source companion tag, commit or dependency linkage changed")
        for artifact in (source, dependency):
            if (not SHA256.fullmatch(artifact.get("sha256", ""))
                or type(artifact.get("size")) is not int or artifact["size"] <= 0):
                raise ValueError("source companion archive pin is incomplete")
        binaries = dependency.get("binaryMembers", [])
        if ([member.get("path") for member in binaries] != ["win_bison.exe", "win_flex.exe"]
            or any(not SHA256.fullmatch(member.get("sha256", ""))
                   or type(member.get("size")) is not int or member["size"] <= 0 for member in binaries)):
            raise ValueError("source companion binary-member pins are incomplete")
        notices = item.get("notices", [])
        names = [Path(pin.get("path", "")).name for pin in notices]
        if not notices or len(names) != len(set(names)):
            raise ValueError("source companion original notice pins are missing or collide")
        for pin in notices:
            if len(repository_payload(root, pin)) != pin.get("size"):
                raise ValueError("source companion original notice size mismatch")
    return items


def bind_dependencies(companions, dependencies):
    declared = {"blender-release-dependency:" + item["key"]: item for item in dependencies}
    for companion in companions:
        dependency = companion["dependency"]
        actual = declared.get(dependency["component"], {})
        if any(actual.get(key) != dependency.get(key) for key in ("version", "url", "upstreamHash", "upstreamHashType")):
            raise ValueError("source companion differs from the original release dependency")


def companion_sources(companions):
    return {item["component"]: {"name": item["name"], "version": item["version"],
        "url": item["source"]["url"], "upstreamHash": item["source"]["sha256"],
        "upstreamHashType": "SHA256", "sha256": item["source"]["sha256"],
        "size": item["source"]["size"], "sourceRevision": item["commit"]} for item in companions}


def validate_archived_companions(members, manifest, lock, companions):
    evidence = members.read(EVIDENCE_PATH)
    if (manifest.get("sourceCompanionsEvidence") != EVIDENCE_PATH or evidence is None
        or hashlib.sha256(evidence).hexdigest() != lock["sourceCompanions"]["sha256"]):
        raise ValueError("source companion evidence is absent or changed in the archive")
    sources = {item["component"]: item for item in manifest["sources"]}
    for companion in companions:
        expected = companion_sources([companion])[companion["component"]]
        source = sources.get(companion["component"], {})
        if any(source.get(key) != value for key, value in expected.items()):
            raise ValueError("source companion archive metadata is missing or changed")
        digests = members.digest(source.get("archivePath"), {"sha256"})
        if (digests is None or digests["sha256"] != expected["sha256"]
            or members.size(source.get("archivePath")) != expected["size"]):
            raise ValueError("source companion source archive is absent or changed")
        dependency = companion["dependency"]
        original = sources.get(dependency["component"], {})
        raw = members.read(original.get("archivePath"))
        if (raw is None or len(raw) != dependency["size"]
            or hashlib.sha256(raw).hexdigest() != dependency["sha256"]):
            raise ValueError("source companion original binary archive changed")
        try:
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                for pin in dependency["binaryMembers"]:
                    if archive.namelist().count(pin["path"]) != 1:
                        raise ValueError("source companion binary member is missing or duplicated")
                    data = archive.read(pin["path"])
                    if len(data) != pin["size"] or hashlib.sha256(data).hexdigest() != pin["sha256"]:
                        raise ValueError("source companion binary member changed")
        except (zipfile.BadZipFile, KeyError) as error:
            raise ValueError("source companion original binary archive is unreadable") from error
        for pin in companion["notices"]:
            data = members.read(NOTICE_PREFIX + Path(pin["path"]).name)
            if data is None or len(data) != pin["size"] or hashlib.sha256(data).hexdigest() != pin["sha256"]:
                raise ValueError("source companion original notice is absent or changed")
