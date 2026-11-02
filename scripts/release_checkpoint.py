import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact, write


REPOSITORY = "iret77/nexgenvideo"
FILES = ("NexGenVideo.zip", "symbols.tar.gz", "plugins.tar.gz", "bpy-source-receipt.json")


def tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            target = os.readlink(path)
            require(path.resolve().is_relative_to(root.resolve()), "Signed payload symlink escapes its bundle")
            value = "link:" + target
        elif path.is_file():
            value = checksum(path)
        elif path.is_dir():
            value = "directory"
        else:
            raise ValueError("Signed payload contains a special file")
        digest.update(json.dumps([relative, mode, value], separators=(",", ":")).encode() + b"\n")
    return digest.hexdigest()


def validate_app_zip(path):
    total = 0
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)) and names, "App archive has missing or duplicate entries")
        for item in archive.infolist():
            name = PurePosixPath(item.filename)
            require(bool(name.parts) and not name.is_absolute() and ".." not in name.parts
                    and name.parts[0] in ("NexGenVideo.app", "__MACOSX"),
                    "App archive path escapes its bundle")
            total += item.file_size
            require(total <= 12 * 1024**3, "App archive exceeds its extraction bound")
            mode = item.external_attr >> 16
            require(not stat.S_IFMT(mode) or stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode),
                    "App archive contains a special file")
            if stat.S_ISLNK(mode):
                target = archive.read(item).decode()
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(item.filename), target))
                require(not target.startswith("/") and resolved.startswith("NexGenVideo.app/"),
                        "App archive symlink escapes its bundle")
    return total


def run(*args):
    subprocess.run(args, stdin=subprocess.DEVNULL, check=True, timeout=900)


def identity(root):
    info = plistlib.loads((root / "NexGenVideo.app/Contents/Info.plist").read_bytes())
    return {"version": info["CFBundleShortVersionString"], "build": str(info["CFBundleVersion"]),
            "sourceSHA": info["NGVSourceCommit"], "catalogURL": info["NGVPluginCatalogURL"]}


def create(root):
    require(os.environ["GITHUB_REPOSITORY"] == REPOSITORY, "Foreign release repository")
    build = Path(".build")
    run("codesign", "--verify", "--strict", str(build / "NexGenVideo.app"))
    root.mkdir(parents=True, exist_ok=False)
    run("/usr/bin/ditto", "-c", "-k", "--keepParent", str(build / "NexGenVideo.app"),
        str(root / "NexGenVideo.zip"))
    binary = subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"],
                                    stdin=subprocess.DEVNULL, text=True, timeout=40).strip()
    run("dsymutil", str(Path(binary) / "libMusicvideoPlugin.dylib"), "-o", str(build / "MusicvideoPlugin.dSYM"))
    run("tar", "-czf", str(root / "symbols.tar.gz"), "-C", str(build),
        "NexGenVideo.dSYM", "NexGenVideoDiagnostics.dSYM", "NexGenEngine.dSYM", "MusicvideoPlugin.dSYM")
    run("tar", "-czf", str(root / "plugins.tar.gz"), "-C", str(build), "plugins")
    (root / "bpy-source-receipt.json").write_bytes((build / "bpy-source/bpy-source-receipt.json").read_bytes())
    native = os.environ.get("RELEASE_NATIVE_PROOF", "")
    if native:
        evidence = json.loads(Path(native).read_text())
        require(evidence.get("schema") == "release-native-reuse/v1"
                and evidence.get("sourceSHA") == os.environ["GITHUB_SHA"], "Native release proof differs")
    else:
        suite = json.loads(Path(os.environ["RELEASE_TEST_EVIDENCE"]).joinpath("suite.json").read_text())
        require(suite.get("sourceSHA") == os.environ["GITHUB_SHA"] and suite.get("completed") is True
                and suite.get("configuration") == "release" and suite.get("scope") == "all"
                and suite.get("filter") == "", "Fresh Release tests did not complete")
        evidence = {"schema": "fresh-release-tests/v1", "suite": suite}
    info = identity(build)
    require(info["version"] == os.environ["REL_VERSION"]
            and info["sourceSHA"] == os.environ["GITHUB_SHA"], "Signed App version or source differs")
    manifest = {"schema": "release-signed-input/v1", "repository": REPOSITORY,
                "sourceSHA": os.environ["GITHUB_SHA"], "runID": int(os.environ["GITHUB_RUN_ID"]),
                "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]), "identity": info,
                "appTreeSHA256": tree_digest(build / "NexGenVideo.app"),
                "nativeEvidence": evidence, "files": {
                    name: {"bytes": (root / name).stat().st_size, "sha256": checksum(root / name)}
                    for name in FILES}}
    validate_app_zip(root / "NexGenVideo.zip")
    write(root / "manifest.json", manifest)


def verify_manifest(manifest, source, run_id):
    require(manifest.get("schema") == "release-signed-input/v1"
            and manifest.get("repository") == REPOSITORY and manifest.get("sourceSHA") == source
            and manifest.get("runID") == run_id and manifest.get("attempt") == 1,
            "Signed input belongs to another source or execution")
    info = manifest.get("identity", {})
    require(isinstance(info.get("version"), str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", info["version"])
            and isinstance(info.get("build"), str) and re.fullmatch(r"[1-9][0-9]*", info["build"])
            and info.get("sourceSHA") == source
            and isinstance(info.get("catalogURL"), str) and info["catalogURL"].startswith("https://")
            and isinstance(manifest.get("appTreeSHA256"), str)
            and re.fullmatch(r"[a-f0-9]{64}", manifest["appTreeSHA256"]), "Invalid signed App identity")
    evidence = manifest.get("nativeEvidence", {})
    if evidence.get("schema") == "release-native-reuse/v1":
        from release_native_proof import SOURCE, RUN, ARTIFACT, DIGEST
        require(evidence.get("sourceSHA") == source and evidence.get("originalSourceSHA") == SOURCE
                and evidence.get("originalRun", {}).get("id") == RUN
                and evidence.get("artifact", {}).get("id") == ARTIFACT
                and evidence.get("artifactSHA256") == DIGEST
                and evidence.get("proof", {}).get("executions") == 4607,
                "Reused native test evidence differs")
    else:
        suite = evidence.get("suite", {})
        require(evidence.get("schema") == "fresh-release-tests/v1"
                and suite.get("sourceSHA") == source and suite.get("completed") is True
                and suite.get("configuration") == "release" and suite.get("scope") == "all"
                and suite.get("filter") == "", "Signed input lacks completed Release tests")
    require(set(manifest.get("files", {})) == set(FILES), "Signed input file inventory differs")
    for value in manifest["files"].values():
        require(type(value.get("bytes")) is int and 0 < value["bytes"] < 12 * 1024**3
                and isinstance(value.get("sha256"), str) and
                re.fullmatch(r"[a-f0-9]{64}", value["sha256"]), "Invalid signed input digest")
    return manifest


def extract_tar(path, build, allowed):
    with tarfile.open(path) as archive:
        members = archive.getmembers()
        require(members and len({item.name for item in members}) == len(members),
                "Payload tar has missing or duplicated entries")
        for item in members:
            name = PurePosixPath(item.name)
            require(bool(name.parts) and not name.is_absolute() and ".." not in name.parts
                    and name.parts[0] in allowed, "Payload tar escapes its declared roots")
            require(not (build / name.parts[0]).is_symlink(), "Payload tar root is a symlink")
            if item.issym() or item.islnk():
                target = posixpath.normpath(posixpath.join(str(name.parent), item.linkname)
                                           if item.issym() else item.linkname)
                link = PurePosixPath(target)
                require(not link.is_absolute() and bool(link.parts) and ".." not in link.parts
                        and link.parts[0] == name.parts[0], "Payload tar link escapes its declared root")
        def confined(item, destination):
            checked = tarfile.data_filter(item, destination)
            root = PurePosixPath(checked.name).parts[0]
            require((build / checked.name).resolve().is_relative_to((build / root).resolve()),
                    "Payload tar resolves outside its declared root")
            return checked
        archive.extractall(build, filter=confined)


def require_saved_notary(producer, jobs, inventory, root):
    if producer["id"] == int(os.environ["GITHUB_RUN_ID"]):
        return
    name = "release-notary-state-" + os.environ["GITHUB_SHA"]
    matches = [item for item in inventory if item.get("name") == name]
    require(len(matches) <= 1, "Original notary state is ambiguous")
    if not matches:
        return
    packaging = [job for job in jobs if job.get("name") == "release"]
    require(len(packaging) == 1 and packaging[0].get("head_sha") == producer["head_sha"]
            and packaging[0].get("labels") == ["macrunner"], "Original notary job differs")
    artifact = api(f"actions/artifacts/{matches[0]['id']}")
    digest = artifact.get("digest", "")
    require(re.fullmatch(r"sha256:[a-f0-9]{64}", digest) and artifact["size_in_bytes"] < 4 * 1024**2,
            "Invalid original notary state")
    verify_artifact(artifact, producer, packaging[0], artifact["id"], digest[7:], name)
    with tempfile.TemporaryDirectory(dir=root.parent) as directory:
        path = Path(directory) / "state.zip"
        download(artifact, path)
        require(checksum(path) == digest[7:], "Original notary state changed")
        with zipfile.ZipFile(path) as archive:
            journals = [name for name in archive.namelist() if re.fullmatch(r"[a-f0-9]{64}\.json", name)]
            if not journals:
                return
            notary_root = os.environ.get("RELEASE_NOTARY_BINDING", "")
            require(notary_root, "Original build has Apple submissions; use notary_progress_run_id")
            notary_root = Path(notary_root)
            binding = json.loads((notary_root / "notary-binding.json").read_text())
            context = binding.get("context", {})
            require(binding.get("schema") == "release-notary-binding/v1"
                    and context.get("sourceSHA") == producer["head_sha"]
                    and context.get("buildRunID") == producer["id"]
                    and context.get("runID") == binding.get("producer", {}).get("id")
                    and checksum(notary_root / "state.zip") == binding["stateArtifact"]["digest"][7:],
                    "Saved notary continuation belongs to another build")
            with zipfile.ZipFile(notary_root / "state.zip") as saved:
                for name in journals:
                    require(json.loads(archive_bytes(archive, name)) == json.loads(archive_bytes(saved, name)),
                            "Saved continuation lost an original Apple submission")


def prepare(run_id, root):
    source = os.environ["GITHUB_SHA"]
    require(run_id > 0 and os.environ["GITHUB_REPOSITORY"] == REPOSITORY, "Invalid signed input producer")
    producer = api(f"actions/runs/{run_id}")
    require(producer.get("head_sha") == source
            and producer.get("repository", {}).get("full_name") == REPOSITORY
            and producer.get("path") == ".github/workflows/release.yml"
            and producer.get("event") == "workflow_dispatch" and producer.get("run_attempt") == 1
            and producer.get("actor", {}).get("login") == "iret77"
            and (producer.get("status") == "completed" or
                 run_id == int(os.environ["GITHUB_RUN_ID"]) and producer.get("status") == "in_progress"),
            "Signed input producer differs")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete signed build job inventory")
    builders = [job for job in jobs["jobs"] if job.get("name") == "release-build"]
    require(len(builders) == 1 and builders[0].get("conclusion") == "success"
            and builders[0].get("head_sha") == source and builders[0].get("labels") == ["macrunner"],
            "Original signed build did not pass")
    artifacts = api(f"actions/runs/{run_id}/artifacts?per_page=100")
    require(artifacts.get("total_count") == len(artifacts.get("artifacts", [])), "Incomplete signed artifact inventory")
    require_saved_notary(producer, jobs["jobs"], artifacts["artifacts"], root)
    prefix = "release-signed-input-" + source
    selected = {}
    for name in (prefix, prefix + "-proof"):
        values = [item for item in artifacts["artifacts"] if item.get("name") == name]
        require(len(values) == 1, "Signed input artifact is missing or duplicated")
        item = api(f"actions/artifacts/{values[0]['id']}")
        require(isinstance(item.get("digest"), str) and item["digest"].startswith("sha256:"),
                "Signed artifact has no immutable digest")
        verify_artifact(item, producer, builders[0], item["id"], item["digest"][7:], name)
        selected[name] = item
    root.mkdir(parents=True, exist_ok=False)
    proof = selected[prefix + "-proof"]
    require(proof["size_in_bytes"] < 16 * 1024**2, "Signed input proof is oversized")
    download(proof, root / "proof.zip")
    require(checksum(root / "proof.zip") == proof["digest"][7:], "Signed proof archive changed")
    with zipfile.ZipFile(root / "proof.zip") as archive:
        require(archive.namelist() == ["manifest.json"], "Unexpected signed proof entries")
        manifest = verify_manifest(json.loads(archive_bytes(archive, "manifest.json")), source, run_id)
    write(root / "binding.json", {"schema": "release-signed-binding/v1", "sourceSHA": source,
          "producer": producer, "builder": builders[0], "artifact": selected[prefix], "manifest": manifest})


def restore(root):
    binding = json.loads((root / "binding.json").read_text())
    require(binding.get("schema") == "release-signed-binding/v1"
            and binding.get("sourceSHA") == os.environ["GITHUB_SHA"], "Signed input binding differs")
    artifact = binding["artifact"]
    require(artifact["size_in_bytes"] < 8 * 1024**3, "Signed input archive exceeds its bound")
    download(artifact, root / "payload.zip")
    require(checksum(root / "payload.zip") == artifact["digest"][7:], "Signed input archive changed")
    manifest = verify_manifest(binding["manifest"], os.environ["GITHUB_SHA"], binding["producer"]["id"])
    payload = root / "payload"
    payload.mkdir()
    with zipfile.ZipFile(root / "payload.zip") as archive:
        require(len(archive.namelist()) == len(FILES) + 1
                and set(archive.namelist()) == set(FILES) | {"manifest.json"}, "Unexpected signed payload files")
        require(json.loads(archive_bytes(archive, "manifest.json")) == manifest, "Signed manifests differ")
        for name in FILES:
            entry = archive.getinfo(name)
            expected = manifest["files"][name]
            require(entry.file_size == expected["bytes"], "Signed payload size differs")
            with archive.open(entry) as source, (payload / name).open("xb") as destination:
                shutil.copyfileobj(source, destination)
            require(checksum(payload / name) == expected["sha256"], "Signed payload bytes differ")
    validate_app_zip(payload / "NexGenVideo.zip")
    build = Path(".build")
    build.mkdir(exist_ok=True)
    run("/usr/bin/ditto", "-x", "-k", str(payload / "NexGenVideo.zip"), str(build))
    for name in ("symbols.tar.gz", "plugins.tar.gz"):
        allowed = {"plugins"} if name == "plugins.tar.gz" else {
            "NexGenVideo.dSYM", "NexGenVideoDiagnostics.dSYM", "NexGenEngine.dSYM", "MusicvideoPlugin.dSYM"}
        extract_tar(payload / name, build, allowed)
    require(tree_digest(build / "NexGenVideo.app") == manifest["appTreeSHA256"]
            and identity(build) == manifest["identity"], "Restored signed App differs")
    require(manifest["identity"]["version"] == os.environ["REL_VERSION"], "Requested release version differs")
    require(manifest["identity"]["catalogURL"] == os.environ["PLUGIN_CATALOG_URL"],
            "Restored App belongs to another plugin channel")
    run("codesign", "--verify", "--strict", str(build / "NexGenVideo.app"))
    shutil.copyfile(payload / "NexGenVideo.zip", build / "NexGenVideo.zip")
    (build / "bpy-source").mkdir(exist_ok=True)
    shutil.copyfile(payload / "bpy-source-receipt.json", build / "bpy-source/bpy-source-receipt.json")
    with Path(os.environ["GITHUB_ENV"]).open("a") as output:
        output.write("BUILD_NUMBER=" + manifest["identity"]["build"] + "\n")
        output.write("NGV_SIGNED_APP_ARCHIVE_SHA256=" + manifest["files"]["NexGenVideo.zip"]["sha256"] + "\n")
    write(root / "restored.json", {"sourceSHA": binding["sourceSHA"], "producerRun": binding["producer"]["id"],
          "appTreeSHA256": manifest["appTreeSHA256"], "identity": manifest["identity"]})
    if os.environ.get("NOTARY_STATE_DIR"):
        state = Path(os.environ["NOTARY_STATE_DIR"])
        state.mkdir(parents=True, exist_ok=True)
        write(state / "context.json", {"schema": "release-notary-context/v1", "repository": REPOSITORY,
              "sourceSHA": binding["sourceSHA"], "buildRunID": binding["producer"]["id"],
              "runID": int(os.environ["GITHUB_RUN_ID"])})


def create_dmg(root):
    root.mkdir(parents=True, exist_ok=False)
    build = Path(".build")
    shutil.copyfile(build / "NexGenVideo.dmg", root / "NexGenVideo.dmg")
    run("tar", "-czf", str(root / "plugins.tar.gz"), "-C", str(build), "plugins")
    context = json.loads(Path(os.environ["NOTARY_STATE_DIR"]).joinpath("context.json").read_text())
    require(context["sourceSHA"] == os.environ["GITHUB_SHA"], "Notary context belongs to another source")
    write(root / "dmg-checkpoint.json", {"schema": "release-dmg-checkpoint/v1", "context": context,
          "appTreeSHA256": tree_digest(build / "NexGenVideo.app"), "files": {
              name: {"bytes": (root / name).stat().st_size, "sha256": checksum(root / name)}
              for name in ("NexGenVideo.dmg", "plugins.tar.gz")}})


def prepare_notary(run_id, root):
    source = os.environ["GITHUB_SHA"]
    producer = api(f"actions/runs/{run_id}")
    require(producer.get("repository", {}).get("full_name") == REPOSITORY
            and producer.get("head_sha") == source and producer.get("actor", {}).get("login") == "iret77"
            and producer.get("path") == ".github/workflows/release.yml"
            and producer.get("event") == "workflow_dispatch" and producer.get("run_attempt") == 1
            and producer.get("status") == "completed" and producer.get("conclusion") in ("failure", "cancelled"),
            "Notary continuation requires a completed failed same-source release")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete notarization job inventory")
    matches = [job for job in jobs["jobs"] if job.get("name") == "release"]
    require(len(matches) == 1 and matches[0].get("labels") == ["macrunner"]
            and matches[0].get("head_sha") == source and matches[0].get("run_id") == run_id
            and matches[0].get("run_attempt") == 1
            and matches[0].get("status") == "completed", "Original notarization job differs")
    job = matches[0]
    inventory = api(f"actions/runs/{run_id}/artifacts?per_page=100")
    require(inventory.get("total_count") == len(inventory.get("artifacts", [])), "Incomplete notary artifacts")
    selected = {}
    for name in ("release-notary-state-" + source, "release-dmg-input-" + source):
        values = [item for item in inventory["artifacts"] if item.get("name") == name]
        require(len(values) <= 1, "Notary artifact is ambiguous")
        if not values:
            continue
        item = api(f"actions/artifacts/{values[0]['id']}")
        require(isinstance(item.get("digest"), str) and item["digest"].startswith("sha256:"),
                "Notary artifact has no digest")
        verify_artifact(item, producer, job, item["id"], item["digest"][7:], name)
        selected[name] = item
    state = selected.get("release-notary-state-" + source)
    require(state and state["size_in_bytes"] < 4 * 1024**2, "Notary state is missing or oversized")
    if selected.get("release-dmg-input-" + source):
        for name in ("Record DMG before notarization", "Retain DMG before notarization"):
            steps = [step for step in job.get("steps", []) if step.get("name") == name]
            require(len(steps) == 1 and steps[0].get("conclusion") == "success",
                    "Original DMG stage did not pass: " + name)
        steps = {step.get("name"): step.get("conclusion") for step in job.get("steps", [])}
        require(steps.get("Build and sign DMG") == "success"
                or steps.get("Build and sign DMG") == "skipped"
                and steps.get("Restore saved notarization and DMG") == "success",
                "Original DMG was neither built nor restored successfully")
    root.mkdir(parents=True, exist_ok=False)
    download(state, root / "state.zip")
    require(checksum(root / "state.zip") == state["digest"][7:], "Notary state changed")
    with zipfile.ZipFile(root / "state.zip") as archive:
        require(len(set(archive.namelist())) == len(archive.namelist()), "Duplicate notary entries")
        context = json.loads(archive_bytes(archive, "context.json"))
        require(context.get("schema") == "release-notary-context/v1"
                and context.get("repository") == REPOSITORY and context.get("sourceSHA") == source
                and context.get("runID") == run_id and type(context.get("buildRunID")) is int
                and context["buildRunID"] > 0, "Notary context differs")
        for name in archive.namelist():
            if name == "context.json":
                continue
            require(re.fullmatch(r"[a-f0-9]{64}\.json", name), "Unexpected notary state entry")
            value = json.loads(archive_bytes(archive, name))
            require(value.get("schema") == "release-notary/v1" and value.get("sourceSHA") == source
                    and value.get("sha256") == name[:-5]
                    and isinstance(value.get("submissionID"), str)
                    and re.fullmatch(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", value["submissionID"]),
                    "Notary submission binding differs")
    write(root / "notary-binding.json", {"schema": "release-notary-binding/v1", "context": context,
          "producer": producer, "job": job, "stateArtifact": state,
          "dmgArtifact": selected.get("release-dmg-input-" + source)})
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("build_run_id=" + str(context["buildRunID"]) + "\n")


def restore_notary(root):
    binding = json.loads((root / "notary-binding.json").read_text())
    context = binding["context"]
    require(binding.get("schema") == "release-notary-binding/v1"
            and context.get("sourceSHA") == os.environ["GITHUB_SHA"], "Notary binding belongs to another source")
    require(checksum(root / "state.zip") == binding["stateArtifact"]["digest"][7:], "Saved notary state changed")
    state = Path(os.environ["NOTARY_STATE_DIR"])
    current = json.loads((state / "context.json").read_text())
    require(current["buildRunID"] == context["buildRunID"], "Notary state belongs to another signed build")
    with zipfile.ZipFile(root / "state.zip") as archive:
        for name in archive.namelist():
            if name != "context.json":
                require(re.fullmatch(r"[a-f0-9]{64}\.json", name), "Invalid notary state filename")
                (state / name).write_bytes(archive_bytes(archive, name))
    artifact = binding.get("dmgArtifact")
    if artifact:
        require(artifact["size_in_bytes"] < 8 * 1024**3, "DMG continuation is oversized")
        download(artifact, root / "dmg.zip")
        require(checksum(root / "dmg.zip") == artifact["digest"][7:], "DMG continuation changed")
        payload = root / "dmg"
        payload.mkdir()
        with zipfile.ZipFile(root / "dmg.zip") as archive:
            require(len(archive.namelist()) == 3
                    and set(archive.namelist()) == {"NexGenVideo.dmg", "plugins.tar.gz", "dmg-checkpoint.json"},
                    "Unexpected DMG checkpoint files")
            manifest = json.loads(archive_bytes(archive, "dmg-checkpoint.json"))
            require(manifest.get("schema") == "release-dmg-checkpoint/v1"
                    and manifest.get("context") == context, "DMG checkpoint context differs")
            for name in ("NexGenVideo.dmg", "plugins.tar.gz"):
                expected = manifest["files"][name]
                require(archive.getinfo(name).file_size == expected["bytes"], "DMG checkpoint size differs")
                with archive.open(name) as source, (payload / name).open("xb") as target:
                    shutil.copyfileobj(source, target)
                require(checksum(payload / name) == expected["sha256"], "DMG checkpoint bytes differ")
        build = Path(".build")
        shutil.copyfile(payload / "NexGenVideo.dmg", build / "NexGenVideo.dmg")
        extract_tar(payload / "plugins.tar.gz", build, {"plugins"})
        with tempfile.TemporaryDirectory(dir=root) as mount:
            run("hdiutil", "attach", str(build / "NexGenVideo.dmg"), "-nobrowse", "-readonly", "-mountpoint", mount)
            try:
                app = Path(mount) / "NexGenVideo.app"
                require(tree_digest(app) == manifest["appTreeSHA256"], "Checkpoint DMG App differs")
                run("ditto", str(app), str(build / "NexGenVideo.app"))
            finally:
                run("hdiutil", "detach", mount)
        require(tree_digest(build / "NexGenVideo.app") == manifest["appTreeSHA256"], "Restored notarized App differs")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("dmg_present=" + str(bool(artifact)).lower() + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("operation", choices=("create", "prepare", "restore", "create-dmg",
                                             "prepare-notary", "restore-notary"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--run-id", type=int)
    args = parser.parse_args()
    if args.operation == "create":
        create(args.root)
    elif args.operation == "prepare":
        prepare(args.run_id, args.root)
    elif args.operation == "restore":
        restore(args.root)
    elif args.operation == "create-dmg":
        create_dmg(args.root)
    elif args.operation == "prepare-notary":
        prepare_notary(args.run_id, args.root)
    else:
        restore_notary(args.root)
