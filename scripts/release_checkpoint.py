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
import sys
import tarfile
import tempfile
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact, write


REPOSITORY = "iret77/nexgenvideo"
FILES = ("NexGenVideo.zip", "symbols.tar.gz", "plugins.tar.gz", "bpy-source-receipt.json")
NATIVE_TIMEOUT = 900


def packaging_binding():
    if not os.environ.get("RETAINED_PACKAGING_ROOT") and not os.environ.get("RETAINED_PACKAGING_INPUT_SHA256"):
        return None
    from retained_packaging import current_binding
    return current_binding()


def product_source():
    binding = packaging_binding()
    return binding["productSourceSHA"] if binding is not None else os.environ["GITHUB_SHA"]


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


def native_test_products(root, scratch, cache, phase):
    require(os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('GITHUB_JOB') == 'release-build' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
            and sys.platform == 'darwin', 'Native test products require the owned release job')
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    require(root.resolve().is_relative_to(temporary) and scratch.resolve().is_relative_to(temporary),
            'Native checkpoint paths must remain in the owned job')
    root.mkdir(parents=True, exist_ok=True)
    python_proof = json.loads((temporary / 'native-test-python.json').read_text())
    required_python = ('waitid', 'P_PID', 'WEXITED', 'WNOHANG', 'WNOWAIT', 'CLD_EXITED', 'CLD_KILLED', 'CLD_DUMPED')
    require(python_proof.get('passed') is True and python_proof.get('platform') == 'darwin'
            and python_proof.get('machine') == 'arm64' and python_proof.get('version', '').startswith('3.13.')
            and all(python_proof.get('interfaces', {}).get(key) is True for key in required_python)
            and Path(python_proof.get('executable', '')).resolve() == Path(sys.executable).resolve(),
            'Native Python capability proof failed')
    argv = ['swift', 'build', '--cache-path', cache, '-c', 'release', '--scratch-path', str(scratch),
            '-Xswiftc', '-enable-testing', '--show-bin-path']
    query = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    require(query.returncode == 0 and len(query.stdout.strip().splitlines()) == 1, 'Native product metadata query failed')
    binary = Path(query.stdout.strip()).resolve()
    require(binary.is_relative_to(scratch.resolve()), 'Native product root escapes its scratch path')
    with Path(os.environ['GITHUB_ENV']).open('a') as environment:
        environment.write('NGV_RELEASE_TEST_PRODUCTS_ROOT=' + str(binary) + '\n')
    source = os.environ['GITHUB_SHA']
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == source,
            'Native compiler checkpoint source differs')
    dirty = subprocess.check_output(['git', 'diff', '--no-renames', '--name-only'], text=True).splitlines()
    require(set(dirty) <= {'Sources/NexGenVideo/Resources/Info.plist'}, 'Native source changed beyond the release version')
    if phase == 'runtime':
        require((root / 'compiler-upload.json').is_file(), 'Confirmed compiler checkpoint required before runtime staging')
    manifest = {'schema': 'release-native-products/v1', 'phase': phase, 'sourceSHA': source,
                'runID': os.environ['GITHUB_RUN_ID'], 'attempt': '1', 'binaryRoot': str(binary),
                'scratchPath': str(scratch), 'configuration': 'release', 'swiftcFlags': ['-enable-testing'],
                'binPathCommand': argv, 'binPathStderr': query.stderr, 'pythonProof': python_proof,
                'trackedDirtyPaths': dirty, 'runtimeReady': phase == 'runtime', 'images': {}, 'files': {}}
    manifest['sourceObjects'] = {name: subprocess.check_output(['git', 'rev-parse', 'HEAD:' + name], text=True).strip()
        for name in ('Sources', 'Engine', 'Tests', 'Package.swift', 'Package.resolved', 'Runtime', 'Metal', 'Vendor', 'plugins')}
    manifest['recipeHashes'] = {name: checksum(Path(name)) for name in
        ('.github/workflows/release.yml', 'scripts/run_macos_tests.py', 'scripts/stage_test_runtime.sh',
         'scripts/compile_metal_resources.sh', 'scripts/stage_runtime_dependencies.sh',
         '.github/actions/setup-native-test-python/action.yml')}
    for path in sorted(binary.rglob('*')) if binary.is_dir() else []:
        relative = path.relative_to(binary).as_posix()
        metadata = {'mode': stat.S_IMODE(path.lstat().st_mode)}
        if path.is_symlink():
            metadata.update(kind='symlink', target=os.readlink(path))
        elif path.is_file():
            metadata.update(kind='file', bytes=path.stat().st_size, sha256=checksum(path))
        elif path.is_dir():
            metadata.update(kind='directory')
        else:
            raise ValueError('Native product contains a special file')
        manifest['files'][relative] = metadata
    for name in ('NexGenVideoAppKitTestHost', 'NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests'):
        path = binary / name
        if path.is_file():
            uuid = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True, timeout=30)
            manifest['images'][name] = {'sha256': checksum(path), 'uuidOutput': uuid}
    if phase in ('compiler', 'runtime'):
        require(len(manifest['images']) == 2, 'Successful native product checkpoint is incomplete')
        manifest['treeSHA256'] = tree_digest(binary)
    write(root / (phase + '-manifest.json'), manifest)
    if phase in ('compiler', 'runtime'):
        archive = root / (phase + '-products.zip')
        require(not archive.exists(), 'Native product archive already exists; never overwrite a checkpoint')
        run('ditto', '-c', '-k', '--keepParent', str(binary), str(archive))
        write(root / (phase + '-archive.json'), {'schema': 'release-native-product-archive/v1',
              'sourceSHA': source, 'runID': os.environ['GITHUB_RUN_ID'], 'attempt': '1',
              'phase': phase, 'bytes': archive.stat().st_size, 'sha256': checksum(archive),
              'manifestSHA256': checksum(root / (phase + '-manifest.json'))})


def confirm_native_test_products(root, artifact_id, artifact_digest):
    require(os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_JOB') == 'release-build'
            and os.environ.get('GITHUB_RUN_ATTEMPT') == '1' and sys.platform == 'darwin', 'Owned native release checkpoint required')
    require(artifact_id and artifact_id.isdecimal() and int(artifact_id) > 0
            and re.fullmatch('[a-f0-9]{64}', artifact_digest or ''), 'Exact successful compiler upload required')
    artifact = api('actions/artifacts/' + artifact_id)
    require(artifact['id'] == int(artifact_id) and artifact['digest'] == 'sha256:' + artifact_digest
            and artifact['name'] == 'release-test-compiler-products-' + os.environ['GITHUB_RUN_ID'] + '-a1'
            and artifact['workflow_run']['id'] == int(os.environ['GITHUB_RUN_ID'])
            and artifact['workflow_run']['head_sha'] == os.environ['GITHUB_SHA'] and not artifact['expired'],
            'Compiler checkpoint upload belongs to a different artifact or execution')
    saved = json.loads((root / 'compiler-archive.json').read_text())
    require(saved['sourceSHA'] == os.environ['GITHUB_SHA'] and saved['runID'] == os.environ['GITHUB_RUN_ID'],
            'Compiler archive source differs')
    write(root / 'compiler-upload.json', {'artifact': artifact, 'archive': saved})


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
    subprocess.run(args, stdin=subprocess.DEVNULL, check=True, timeout=NATIVE_TIMEOUT)


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
        if evidence.get("schema") == "release-native-scoped-repair/v1":
            from release_test_repair import verify_receipt
            verify_receipt(evidence, os.environ["GITHUB_SHA"], int(os.environ["GITHUB_RUN_ID"]))
        else:
            require(evidence.get("schema") == "release-native-reuse/v1"
                    and evidence.get("sourceSHA") == os.environ["GITHUB_SHA"], "Native release proof differs")
    else:
        suite = json.loads(Path(os.environ["RELEASE_TEST_EVIDENCE"]).joinpath("suite.json").read_text())
        require(suite.get("sourceSHA") == os.environ["GITHUB_SHA"] and suite.get("completed") is True
                and suite.get("configuration") == "release" and suite.get("scope") == "all"
                and suite.get("filter") == "", "Fresh Release tests did not complete")
        if "retainedBackends" in suite:
            from release_engine_resume import verify_completed_suite
            verify_completed_suite(suite, os.environ["GITHUB_SHA"], int(os.environ["GITHUB_RUN_ID"]))
            evidence = {"schema": "resumed-release-tests/v1", "suite": suite}
        else:
            require(not any(key in suite for key in ("freshTestExecutions", "reusedTestExecutions"))
                    and all("reusedFrom" not in phase for phase in suite.get("phases", [])),
                    "Retained Release executions cannot be labeled fresh")
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
    if evidence.get("schema") == "release-native-scoped-repair/v1":
        from release_test_repair import verify_receipt
        verify_receipt(evidence, source, run_id)
    elif evidence.get("schema") == "release-native-reuse/v1":
        from release_native_proof import SOURCE, RUN, ARTIFACT, DIGEST
        require(evidence.get("sourceSHA") == source and evidence.get("originalSourceSHA") == SOURCE
                and evidence.get("originalRun", {}).get("id") == RUN
                and evidence.get("artifact", {}).get("id") == ARTIFACT
                and evidence.get("artifactSHA256") == DIGEST
                and evidence.get("proof", {}).get("executions") == 4607,
                "Reused native test evidence differs")
    elif evidence.get("schema") == "resumed-release-tests/v1":
        from release_engine_resume import verify_completed_suite
        verify_completed_suite(evidence.get("suite", {}), source, run_id)
    else:
        suite = evidence.get("suite", {})
        require(evidence.get("schema") == "fresh-release-tests/v1"
                and suite.get("sourceSHA") == source and suite.get("completed") is True
                and suite.get("configuration") == "release" and suite.get("scope") == "all"
                and suite.get("filter") == ""
                and not any(key in suite for key in ("retainedBackends", "freshTestExecutions", "reusedTestExecutions"))
                and all("reusedFrom" not in phase for phase in suite.get("phases", [])),
                "Signed input lacks completed fresh Release tests")
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


def require_saved_notary(producer, jobs, inventory, root, *, retained=None):
    if producer["id"] == int(os.environ["GITHUB_RUN_ID"]):
        return
    name = "release-notary-state-" + producer["head_sha"]
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
            require(binding.get("schema") == ("release-notary-binding/v2" if retained is not None else "release-notary-binding/v1")
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
    retained = packaging_binding()
    source = retained["productSourceSHA"] if retained is not None else os.environ["GITHUB_SHA"]
    if retained is not None:
        require(run_id == retained["originalSignedBuildRunID"], "Retained packaging selected another signed build")
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
    require_saved_notary(producer, jobs["jobs"], artifacts["artifacts"], root, retained=retained)
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
    binding = {"schema": "release-signed-binding/v1", "sourceSHA": source,
               "producer": producer, "builder": builders[0], "artifact": selected[prefix], "manifest": manifest}
    if retained is not None:
        binding.update(schema="release-signed-binding/v2", producerSourceSHA=os.environ["GITHUB_SHA"],
                       executionRunID=int(os.environ["GITHUB_RUN_ID"]),
                       packagingInputSHA256=os.environ["RETAINED_PACKAGING_INPUT_SHA256"])
    write(root / "binding.json", binding)


def restore(root):
    binding = json.loads((root / "binding.json").read_text())
    retained = packaging_binding()
    source = retained["productSourceSHA"] if retained is not None else os.environ["GITHUB_SHA"]
    require(binding.get("schema") == ("release-signed-binding/v2" if retained is not None else "release-signed-binding/v1")
            and binding.get("sourceSHA") == source, "Signed input binding differs")
    if retained is not None:
        require(binding.get("producerSourceSHA") == os.environ["GITHUB_SHA"]
                and binding.get("executionRunID") == int(os.environ["GITHUB_RUN_ID"])
                and binding.get("packagingInputSHA256") == os.environ["RETAINED_PACKAGING_INPUT_SHA256"]
                and binding.get("producer", {}).get("id") == retained["originalSignedBuildRunID"],
                "Retained signed binding belongs to another execution")
    artifact = binding["artifact"]
    require(artifact["size_in_bytes"] < 8 * 1024**3, "Signed input archive exceeds its bound")
    download(artifact, root / "payload.zip")
    require(checksum(root / "payload.zip") == artifact["digest"][7:], "Signed input archive changed")
    manifest = verify_manifest(binding["manifest"], source, binding["producer"]["id"])
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
        context = {"schema": "release-notary-context/v1", "repository": REPOSITORY,
                   "sourceSHA": binding["sourceSHA"], "buildRunID": binding["producer"]["id"],
                   "runID": int(os.environ["GITHUB_RUN_ID"])}
        if retained is not None:
            context.update(schema="release-notary-context/v2", producerSourceSHA=os.environ["GITHUB_SHA"])
        write(state / "context.json", context)


def create_dmg(root):
    root.mkdir(parents=True, exist_ok=False)
    build = Path(".build")
    shutil.copyfile(build / "NexGenVideo.dmg", root / "NexGenVideo.dmg")
    run("tar", "-czf", str(root / "plugins.tar.gz"), "-C", str(build), "plugins")
    context = json.loads(Path(os.environ["NOTARY_STATE_DIR"]).joinpath("context.json").read_text())
    retained = packaging_binding()
    source = retained["productSourceSHA"] if retained is not None else os.environ["GITHUB_SHA"]
    require(context["sourceSHA"] == source
            and context.get("schema") == ("release-notary-context/v2" if retained is not None else "release-notary-context/v1"),
            "Notary context belongs to another source")
    if retained is not None:
        require(context.get("producerSourceSHA") == os.environ["GITHUB_SHA"]
                and context.get("runID") == int(os.environ["GITHUB_RUN_ID"])
                and context.get("buildRunID") == retained["originalSignedBuildRunID"], "DMG context belongs to another packaging execution")
    checkpoint = {"schema": "release-dmg-checkpoint/v2" if retained is not None else "release-dmg-checkpoint/v1", "context": context,
          "appTreeSHA256": tree_digest(build / "NexGenVideo.app"), "files": {
              name: {"bytes": (root / name).stat().st_size, "sha256": checksum(root / name)}
              for name in ("NexGenVideo.dmg", "plugins.tar.gz")}}
    if retained is not None:
        from release_acceptance_identity import tree_sha256
        checkpoint['appRuntimeTreeSHA256'] = tree_sha256(build / 'NexGenVideo.app')
    write(root / 'dmg-checkpoint.json', checkpoint)
    if retained is not None:
        with Path(os.environ["GITHUB_ENV"]).open("a") as output:
            output.write("RETAINED_PACKAGING_DMG_CHECKPOINT=" + str((root / "dmg-checkpoint.json").resolve()) + "\n")


def prepare_notary(run_id, root):
    retained = packaging_binding()
    source = retained["productSourceSHA"] if retained is not None else os.environ["GITHUB_SHA"]
    producer_source = source
    if retained is not None:
        require(run_id == retained["mode"]["priorNotaryRunID"], "Retained packaging selected another notary producer")
        producer_source = retained["previousNotary"]["producer"]["head_sha"]
    producer = api(f"actions/runs/{run_id}")
    require(producer.get("repository", {}).get("full_name") == REPOSITORY
            and producer.get("head_sha") == producer_source and producer.get("actor", {}).get("login") == "iret77"
            and producer.get("path") == ".github/workflows/release.yml"
            and producer.get("event") == "workflow_dispatch" and producer.get("run_attempt") == 1
            and producer.get("status") == "completed" and producer.get("conclusion") in ("failure", "cancelled"),
            "Notary continuation requires a completed failed same-source release")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete notarization job inventory")
    matches = [job for job in jobs["jobs"] if job.get("name") == "release"]
    require(len(matches) == 1 and matches[0].get("labels") == ["macrunner"]
            and matches[0].get("head_sha") == producer_source and matches[0].get("run_id") == run_id
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
        require(context.get("schema") in ({"release-notary-context/v1", "release-notary-context/v2"} if retained is not None else {"release-notary-context/v1"})
                and context.get("repository") == REPOSITORY and context.get("sourceSHA") == source
                and context.get("runID") == run_id and type(context.get("buildRunID")) is int
                and context["buildRunID"] > 0, "Notary context differs")
        if retained is not None:
            require(context == retained["previousNotary"]["context"], "Retained notary context changed")
            require(context["schema"] == "release-notary-context/v1" and producer_source == source
                    or context["schema"] == "release-notary-context/v2" and context.get("producerSourceSHA") == producer_source,
                    "Retained notary source meaning differs")
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
    binding = {"schema": "release-notary-binding/v1", "context": context,
               "producer": producer, "job": job, "stateArtifact": state,
               "dmgArtifact": selected.get("release-dmg-input-" + source)}
    if retained is not None:
        binding.update(schema="release-notary-binding/v2", producerSourceSHA=os.environ["GITHUB_SHA"],
                       executionRunID=int(os.environ["GITHUB_RUN_ID"]),
                       packagingInputSHA256=os.environ["RETAINED_PACKAGING_INPUT_SHA256"])
    write(root / "notary-binding.json", binding)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("build_run_id=" + str(context["buildRunID"]) + "\n")


def restore_notary(root):
    binding = json.loads((root / "notary-binding.json").read_text())
    context = binding["context"]
    retained = packaging_binding()
    source = retained["productSourceSHA"] if retained is not None else os.environ["GITHUB_SHA"]
    require(binding.get("schema") == ("release-notary-binding/v2" if retained is not None else "release-notary-binding/v1")
            and context.get("sourceSHA") == source, "Notary binding belongs to another source")
    if retained is not None:
        require(binding.get("producerSourceSHA") == os.environ["GITHUB_SHA"]
                and binding.get("executionRunID") == int(os.environ["GITHUB_RUN_ID"])
                and binding.get("packagingInputSHA256") == os.environ["RETAINED_PACKAGING_INPUT_SHA256"]
                and context == retained["previousNotary"]["context"], "Retained notary binding belongs to another execution")
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
            expected_schema = "release-dmg-checkpoint/v2" if context["schema"] == "release-notary-context/v2" else "release-dmg-checkpoint/v1"
            require(manifest.get("schema") == expected_schema
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
        if retained is not None:
            with Path(os.environ["GITHUB_ENV"]).open("a") as output:
                output.write("RETAINED_PACKAGING_DMG_CHECKPOINT=" + str((payload / "dmg-checkpoint.json").resolve()) + "\n")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("dmg_present=" + str(bool(artifact)).lower() + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("operation", choices=("create", "prepare", "restore", "create-dmg",
                                             "prepare-notary", "restore-notary", "native-test-products", "confirm-native-test-products"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--scratch-path", type=Path)
    parser.add_argument("--cache-path")
    parser.add_argument("--phase", choices=('plan', 'compiler', 'runtime', 'available'))
    parser.add_argument("--artifact-id")
    parser.add_argument("--artifact-digest")
    args = parser.parse_args()
    if args.operation not in ('native-test-products', 'confirm-native-test-products') and any(
            (args.scratch_path, args.cache_path, args.phase, args.artifact_id, args.artifact_digest)):
        parser.error('Native test checkpoint inputs cannot be ignored by another operation')
    if args.operation == 'native-test-products':
        require(args.scratch_path is not None and args.cache_path and args.phase, 'Exact native product selection required')
        native_test_products(args.root, args.scratch_path, args.cache_path, args.phase)
    elif args.operation == 'confirm-native-test-products':
        confirm_native_test_products(args.root, args.artifact_id, args.artifact_digest)
    elif args.operation == "create":
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
