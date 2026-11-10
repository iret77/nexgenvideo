import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact, write


RUN = 42500881402
JOB = 128793684809
SOURCE = "849cdd32d702e0b86219ee0a44f10360f68cbfe6"
LINKED_RUN = 42518096376
LINKED_JOB = 128845862907
LINKED_SOURCE = "1b005345afc65ba705fa3256d94bd1a1c93cd2c9"
LINKED_ARTIFACT = 13631869778
LINKED_ARCHIVE_SHA = "ae6fae1699e3a0671fc3d6aeb6d653d94c451b26376fed8ffbccb817542205a4"
LINKED_IMAGE_SHA = "a0ccfaeb72dd1cd7ddf84f3892090571060067258b6e0ae1ebd9e3ee19904eee"
LINKED_OBJECT_SHA = "eb9d90baad8af70cb189c9226e5aab30055514dff7e5a7b7285b49cec9fc8b95"
LINKED_MODULE_SHA = "a9519218f4367b167dd6965740cd89daaf0b51f2a895d27ebe7874e4905a6a75"
FIXTURE = "Tests/NexGenVideoTests/Generation/GenerationBatchTests.swift"
PREFIX = "NexGenVideoTests.GenerationBatchTests/"
FAILED = PREFIX + "terminalCancellationResumesOtherApprovedWorkOnlyAfterTheHostLeaseEnds()"
ADDED = PREFIX + "boundedWaitObservesDelayedStateAndRejectsMissingState()"
EVENT_SHA = "ff44586fc16740996b715b1c27bb6587582f33796ab5639a7871c64f0bd5c662"
MANIFEST_SHA = "8942741043167ff08b5434abb352c8ef65c7e3426de948ded9e1479543ddaf96"
RUNTIME_SHA = "ebc283fca95cac3f289378097d7157391cefe787adbf35e8d1175c427727285a"
TREE_SHA = "357a8857cda33fb399c08c5b5f814430171c32d24ec298eebbb01733e1be6b18"
HOST_SHA = "70330e80bf88fa7e23032d80b9b2df2b855e9baaa00c87c1195a5093edc333f5"
APP_OBJECT = "ExecutableModules/NexGenVideo-7B8DE44438834347-testable.o"
APP_OBJECT_SHA = "66bf00ae1c94b0866abdd34427145d1aa4aa189b18b12add9e71f67919695000"
SELECTED_SHA = "f8954ec6c0825f094bbbf0d7a30c73ceba39e98bcaee7518323801b91d324325"
REUSED_SHA = "7e8c852c25874bfccfc11d4d3fdadbf4f16b46b67196048989f6c92fa09e9622"
ARTIFACTS = {
    "runtime": (13626102447, "9d9a40671b071e86cbc5daff9ca11add8d50885a1699d7552e90499c6f96f8af",
                "release-test-runtime-products-42500881402-a1"),
    "metadata": (13626364298, "c2fffaf3d3c2260346b78cde650ea61dc52c344991aa440a37a1e4bdcc7e9cd8",
                 "release-test-product-evidence-42500881402-a1"),
    "tests": (13627235121, "80913a8efe2303a77c4f6aad75db5efd01c149b4e7ef04ff00306babf2ee95e7",
              "release-test-evidence"),
}
PATHS = {FIXTURE, ".github/workflows/release.yml", "scripts/release_test_repair.py",
         "scripts/test_release_test_repair.py", "scripts/release_native_proof.py",
         "scripts/release_checkpoint.py", "scripts/test_release_recovery.py", "scripts/test_release_workflow.py",
         "scripts/retained_packaging.py", "scripts/test_retained_packaging.py"}
TEST_SOURCES = (FIXTURE, "Tests/NexGenVideoTests/Generation/GenerationPackageTests.swift",
                "Tests/NexGenVideoTests/Fixtures.swift")
EXCLUDED_OBJECTS = {"NexGenEngine.o", "AppKitTestHostSupport.o", "MusicvideoPlugin.o",
                    "FixtureFictionPlugin.o", "Yams.o", "CYaml.o"}


def git(*args):
    return subprocess.check_output(["git", *args], stdin=subprocess.DEVNULL, text=True, timeout=40).strip()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def method(identity):
    return identity.rsplit("/", 1)[0]


def verify_sources(source, manifest):
    require(re.fullmatch("[a-f0-9]{40}", source or "") and git("rev-parse", "HEAD") == source,
            "Repair source differs from the actual checkout")
    subprocess.run(["git", "merge-base", "--is-ancestor", SOURCE, source],
                   stdin=subprocess.DEVNULL, check=True, timeout=30)
    changed = git("diff", "--no-renames", "--name-only", SOURCE, source).splitlines()
    require(FIXTURE in changed and set(changed) <= PATHS, "Unrelated product or test source changed")
    dirty = git("diff", "--no-renames", "--name-only", "HEAD").splitlines()
    require(set(dirty) <= {"Sources/NexGenVideo/Resources/Info.plist"}, "Unreviewed working-copy changes")
    for name, expected in manifest["sourceObjects"].items():
        if name != "Tests":
            require(git("rev-parse", "HEAD:" + name) == expected, "Retained source identity differs: " + name)
    original = git("show", SOURCE + ":" + FIXTURE)
    current = Path(FIXTURE).read_text().rstrip()
    before = "    private func waitUntil("
    after = "    @Test func busyPhasePreservesApprovedQueuedItemsAndDoesNotAdvanceTheBatchQueue()"
    require(original.count(before) == current.count(before) == original.count(after) == current.count(after) == 1,
            "Generation batch waiter boundaries differ")
    require(original.partition(before)[0] == current.partition(before)[0]
            and original.partition(after)[2] == current.partition(after)[2],
            "Existing generation batch assertions or fixtures changed")
    for name, expected in manifest["recipeHashes"].items():
        if name != ".github/workflows/release.yml":
            require(checksum(Path(name)) == expected, "Retained runtime reader or staging recipe changed")
    return {"changedPaths": changed, "sourceObjects": manifest["sourceObjects"],
            "testSources": {name: checksum(Path(name)) for name in TEST_SOURCES}}


def original_inventory(data):
    require(sha(data) == EVENT_SHA, "Original App events differ")
    records = [json.loads(line) for line in data.splitlines()]
    discovered = {row["payload"]["id"]: row["payload"] for row in records if row.get("kind") == "test"}
    functions = {key for key, value in discovered.items() if value["kind"] == "function"}
    started, ended, skipped = Counter(), Counter(), set()
    issues = []
    for row in records:
        if row.get("kind") != "event":
            continue
        value = row["payload"]
        if value["kind"] == "testStarted":
            started[value["testID"]] += 1
        elif value["kind"] == "testEnded":
            ended[value["testID"]] += 1
        elif value["kind"] == "testSkipped":
            skipped.add(value["testID"])
        elif value["kind"] == "issueRecorded":
            issues.append(value)
    require(len(functions) == 3712 and started == ended
            and len(functions & started.keys()) == 3704 and len(functions & skipped) == 8
            and all(count == 1 for count in started.values()), "Original complete App inventory differs")
    require(len(issues) == 1 and method(issues[0]["testID"]) == FAILED
            and issues[0]["issue"]["sourceLocation"]["line"] == 287
            and issues[0]["issue"]["isFailure"] is True and issues[0]["issue"]["isKnown"] is False,
            "Original App failure is not the reviewed single expectation")
    selected = sorted(method(identity) for identity in functions if identity.startswith(PREFIX))
    require(len(selected) == len(set(selected)) == 58 and FAILED in selected
            and all(identity in started for identity in functions if identity.startswith(PREFIX))
            and not any(identity.startswith(PREFIX) for identity in skipped), "Original repair scope differs")
    return {"originalEventSHA256": EVENT_SHA, "originalFailure": FAILED,
            "selectedMethods": selected, "reusedAppMethods": 3646,
            "reusedAppMethodIDs": sorted(method(identity) for identity in functions & started.keys()
                                         if not identity.startswith(PREFIX)),
            "originalSkippedIDs": sorted(skipped & functions)}


def verify_original(run, jobs):
    require(run.get("id") == RUN and run.get("head_sha") == SOURCE and run.get("run_attempt") == 1
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("path") == ".github/workflows/release.yml" and run.get("event") == "workflow_dispatch"
            and run.get("actor", {}).get("login") == "iret77" and run.get("status") == "completed"
            and run.get("conclusion") == "failure", "Original failed release producer differs")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Original job inventory is incomplete")
    matches = [job for job in jobs["jobs"] if job.get("id") == JOB]
    require(len(matches) == 1, "Original release builder is missing")
    job = matches[0]
    require(job.get("run_id") == RUN and job.get("run_attempt") == 1 and job.get("head_sha") == SOURCE
            and job.get("name") == "release-build" and job.get("labels") == ["macrunner"]
            and job.get("status") == "completed" and job.get("conclusion") == "failure",
            "Original builder result or runner differs")
    require([step["name"] for step in job["steps"] if step["conclusion"] in ("failure", "cancelled")]
            == ["Test the exact release configuration"], "Original release failed in a different step")
    for name in ("Build the exact release test configuration", "Checkpoint successful native compiler products before staging",
                 "Confirm compiler product upload before staging", "Stage release test runtime inputs",
                 "Retain staged runtime products before native tests", "Upload staged runtime products before native tests",
                 "Upload release test evidence"):
        steps = [step for step in job["steps"] if step["name"] == name]
        require(len(steps) == 1 and steps[0]["conclusion"] == "success", "Original retained product step failed")
    return job


def prepare(root, run_id):
    inputs = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())["inputs"]
    require(run_id in {RUN, LINKED_RUN} and os.environ.get("GITHUB_REPOSITORY") == "iret77/nexgenvideo"
            and os.environ.get("GITHUB_RUN_ATTEMPT") == "1"
            and inputs.get("version") == "1.8.0" and inputs.get("dry_run") == "true"
            and inputs.get("artifact_only") == "true" and inputs.get("completed_release_tests_run_id") == str(run_id),
            "Scoped test repair requires the exact artifact-only RC")
    root.mkdir(parents=True, exist_ok=False)
    run = api(f"actions/runs/{RUN}")
    jobs = api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100")
    job = verify_original(run, jobs)
    write(root / "original-run.json", run)
    write(root / "original-jobs.json", jobs)
    artifacts = {}
    for role, (identifier, digest, name) in ARTIFACTS.items():
        value = api(f"actions/artifacts/{identifier}")
        verify_artifact(value, run, job, identifier, digest, name)
        download(value, root / (role + ".zip"))
        artifacts[role] = value
    with zipfile.ZipFile(root / "metadata.zip") as archive:
        data = archive_bytes(archive, "release-test-product-checkpoints/runtime-manifest.json", 4 * 1024**2)
        require(sha(data) == MANIFEST_SHA, "Original runtime manifest differs")
        (root / "runtime-manifest.json").write_bytes(data)
    manifest = json.loads(data)
    require(manifest["sourceSHA"] == SOURCE and manifest["runID"] == str(RUN)
            and manifest["attempt"] == "1" and manifest["runtimeReady"] is True
            and manifest["configuration"] == "release" and manifest["swiftcFlags"] == ["-enable-testing"]
            and manifest["treeSHA256"] == TREE_SHA, "Original staged runtime identity differs")
    with zipfile.ZipFile(root / "tests.zip") as archive:
        prefix = "_temp/release-test-evidence/"
        inventory = original_inventory(archive_bytes(archive, prefix + "app-swift-testing/events.jsonl"))
        suite = json.loads(archive_bytes(archive, prefix + "suite.json"))
        require(suite["sourceSHA"] == SOURCE and suite["completed"] is False
                and suite["scope"] == "all" and suite["filter"] == "" and suite["serialAppTests"] is True
                and [phase["name"] for phase in suite["phases"]] == ["xctest", "engine-swift-testing", "app-swift-testing"]
                and suite["phases"][0]["status"] == suite["phases"][1]["status"] == "verified-execution"
                and suite["phases"][0]["testCaseExecutions"] == 48
                and suite["phases"][1]["events"]["functionExecutions"] == 896,
                "Original passed backends differ")
    binding = verify_sources(os.environ["GITHUB_SHA"], manifest)
    linked = prepare_linked(root, binding) if run_id == LINKED_RUN else None
    write(root / "pending.json", {"schema": "release-native-scoped-repair-pending/v1",
          "sourceSHA": os.environ["GITHUB_SHA"], "originalSourceSHA": SOURCE, "originalRun": RUN,
          "artifacts": artifacts, "sourceBinding": binding,
          "inventory": inventory, "linkedProducer": linked})


def linked_inputs(archive, binding):
    prefix = "release-native/"
    pending = json.loads(archive_bytes(archive, prefix + "pending.json"))
    commands = json.loads(archive_bytes(archive, prefix + "repair-evidence/commands.json"))
    require(pending["sourceSHA"] == LINKED_SOURCE and pending["originalSourceSHA"] == SOURCE
            and pending["originalRun"] == RUN and pending["sourceBinding"]["testSources"] == binding["testSources"]
            and pending["sourceBinding"]["sourceObjects"] == binding["sourceObjects"],
            "Retained compiled test source identity differs")
    require(len(commands) == 32 and all(item["exitCode"] == 0 for item in commands[:-1])
            and [item["label"] for item in commands[-3:]] == ["compile-tests", "link-test-bundle", "sign-test-bundle"]
            and commands[-1]["exitCode"] == 1,
            "Retained compilation or link did not finish before the reviewed signing failure")
    require(sha(archive_bytes(archive, prefix + "repair-evidence/sign-test-bundle.stderr"))
            == "7d7c0a45f9f145f099bcc519f76edfadf054d66e379deadefe040e635046a9b9",
            "Retained producer failed at another signing boundary")
    require(sha(archive_bytes(archive, prefix + "runtime-manifest.json", 4 * 1024**2)) == MANIFEST_SHA,
            "Retained linked tests use another runtime")
    files = {
        "repair-evidence/NexGenVideoTests.o": LINKED_OBJECT_SHA,
        "repair-evidence/NexGenVideoTests.swiftmodule": LINKED_MODULE_SHA,
        "repaired/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests": LINKED_IMAGE_SHA,
    }
    for name, expected in files.items():
        require(sha(archive_bytes(archive, prefix + name, 256 * 1024**2)) == expected,
                "Retained compiler product differs: " + name)
    return {"sourceSHA": LINKED_SOURCE, "runID": LINKED_RUN, "attempt": 1,
            "sourceBinding": pending["sourceBinding"], "commands": commands, "products": files,
            "testingMacroInput": json.loads(archive_bytes(archive, prefix + "repair-evidence/testing-macro-input.json")),
            "clangInputsSHA256": sha(archive_bytes(archive, prefix + "clang-inputs.json"))}


def prepare_linked(root, binding):
    subprocess.run(["git", "merge-base", "--is-ancestor", LINKED_SOURCE, os.environ["GITHUB_SHA"]],
                   stdin=subprocess.DEVNULL, check=True, timeout=30)
    run = api(f"actions/runs/{LINKED_RUN}")
    require(run.get("id") == LINKED_RUN and run.get("head_sha") == LINKED_SOURCE and run.get("run_attempt") == 1
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("actor", {}).get("login") == "iret77" and run.get("event") == "workflow_dispatch"
            and run.get("path") == ".github/workflows/release.yml" and run.get("status") == "completed"
            and run.get("conclusion") == "failure", "Linked compiler producer differs")
    jobs = api(f"actions/runs/{LINKED_RUN}/attempts/1/jobs?per_page=100")
    require(jobs["total_count"] == len(jobs["jobs"]), "Linked producer job inventory is incomplete")
    matches = [job for job in jobs["jobs"] if job["id"] == LINKED_JOB]
    require(len(matches) == 1, "Linked producer builder differs")
    job = matches[0]
    require(job["run_id"] == LINKED_RUN and job["run_attempt"] == 1 and job["head_sha"] == LINKED_SOURCE
            and job["name"] == "release-build" and job["labels"] == ["macrunner"]
            and job["status"] == "completed" and job["conclusion"] == "failure"
            and [step["name"] for step in job["steps"] if step["conclusion"] in {"failure", "cancelled"}]
            == ["Compile the changed App test module using retained products"], "Linked producer result differs")
    artifact = api(f"actions/artifacts/{LINKED_ARTIFACT}")
    verify_artifact(artifact, run, job, LINKED_ARTIFACT, LINKED_ARCHIVE_SHA,
                    "release-scoped-test-evidence-42518096376-a1")
    download(artifact, root / "linked-products.zip")
    with zipfile.ZipFile(root / "linked-products.zip") as archive:
        origin = linked_inputs(archive, binding)
    origin.update(artifact=artifact, run=run, job=job)
    verify_linked_producer(origin, binding)
    write(root / "linked-compiler-producer.json", origin)
    return origin


def verify_linked_producer(origin, binding):
    require(origin.get("sourceSHA") == LINKED_SOURCE and origin.get("runID") == LINKED_RUN
            and origin.get("attempt") == 1 and origin.get("sourceBinding", {}).get("testSources") == binding["testSources"]
            and origin.get("sourceBinding", {}).get("sourceObjects") == binding["sourceObjects"],
            "Compiler origin source identity differs")
    artifact = origin.get("artifact", {})
    require(artifact.get("id") == LINKED_ARTIFACT and artifact.get("expired") is False
            and artifact.get("digest") == "sha256:" + LINKED_ARCHIVE_SHA
            and artifact.get("workflow_run", {}).get("id") == LINKED_RUN
            and artifact.get("workflow_run", {}).get("head_sha") == LINKED_SOURCE,
            "Compiler origin artifact differs")
    require(origin.get("products") == {
        "repair-evidence/NexGenVideoTests.o": LINKED_OBJECT_SHA,
        "repair-evidence/NexGenVideoTests.swiftmodule": LINKED_MODULE_SHA,
        "repaired/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests": LINKED_IMAGE_SHA},
        "Compiler origin product identity differs")
    commands = origin.get("commands", [])
    require(len(commands) == 32 and all(item["exitCode"] == 0 for item in commands[:-1])
            and [item["label"] for item in commands[-3:]] == ["compile-tests", "link-test-bundle", "sign-test-bundle"]
            and commands[-1]["exitCode"] == 1, "Compiler origin result was reclassified")


def restore_linked(root, binding, image, evidence):
    require(checksum(root / "linked-products.zip") == LINKED_ARCHIVE_SHA, "Transferred linked archive differs")
    with zipfile.ZipFile(root / "linked-products.zip") as archive:
        origin = linked_inputs(archive, binding)
        for name in archive.namelist():
            base = "release-native/"
            if name.startswith(base + "repair-evidence/") and not name.endswith("/"):
                relative = PurePosixPath(name.removeprefix(base + "repair-evidence/"))
                require(len(relative.parts) == 1 and str(relative) not in {".", ".."}, "Compiler evidence path differs")
                data = archive_bytes(archive, name, 32 * 1024**2)
                (evidence / ("origin-" + str(relative))).write_bytes(data)
            elif name in {base + "clang-inputs.json", base + "dependency-lock.json"} or re.fullmatch(
                    r"release-native/module-[A-Za-z_0-9]+\.modulemap", name):
                (root / PurePosixPath(name).name).write_bytes(archive_bytes(archive, name))
        image.write_bytes(archive_bytes(archive, "release-native/repaired/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests",
                                        256 * 1024**2))
        for name in ("NexGenVideoTests.o", "NexGenVideoTests.swiftmodule"):
            (evidence / name).write_bytes(archive_bytes(archive, "release-native/repair-evidence/" + name, 32 * 1024**2))
    require(checksum(image) == LINKED_IMAGE_SHA and checksum(evidence / "NexGenVideoTests.o") == LINKED_OBJECT_SHA,
            "Restored link product differs")
    return origin


def sign_copied_bundle(bundle, logged):
    real = bundle.resolve()
    magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
             b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    images = []
    for path in bundle.rglob("*"):
        require(path.resolve().is_relative_to(real), "Copied test code escapes its bundle")
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in magic:
                    images.append(path)
    require(bundle / "Contents/MacOS/NexGenVideoTests" in images, "Copied test image is missing")
    containers = {parent for image in images for parent in image.parents
                  if parent != bundle and parent.is_relative_to(bundle)
                  and parent.suffix in {".framework", ".app", ".xpc", ".bundle"}}
    targets = sorted(images, key=lambda path: (-len(path.parts), str(path)))
    targets += sorted(containers, key=lambda path: (-len(path.parts), str(path)))
    targets.append(bundle)
    for index, path in enumerate(targets):
        logged(["codesign", "--force", "--sign", "-", str(path)], "sign-copied-code-" + str(index))
    logged(["codesign", "--verify", "--deep", "--strict", str(bundle)], "verify-signed-test-bundle")
    return [path.relative_to(bundle).as_posix() if path != bundle else "." for path in targets]


def verify_runtime(binary, manifest):
    from release_checkpoint import tree_digest
    require(set(path.relative_to(binary).as_posix() for path in binary.rglob("*")) == set(manifest["files"]),
            "Retained runtime contains missing or additional paths")
    for name, expected in manifest["files"].items():
        path = binary / name
        mode = path.lstat().st_mode
        require(stat.S_IMODE(mode) == expected["mode"], "Retained runtime mode differs: " + name)
        if expected["kind"] == "symlink":
            require(path.is_symlink() and os.readlink(path) == expected["target"]
                    and path.resolve(strict=True).is_relative_to(binary.resolve()), "Retained runtime link differs")
        elif expected["kind"] == "directory":
            require(stat.S_ISDIR(mode), "Retained runtime directory differs")
        else:
            require(stat.S_ISREG(mode) and path.stat().st_size == expected["bytes"]
                    and checksum(path) == expected["sha256"], "Retained runtime file differs: " + name)
    require(tree_digest(binary) == TREE_SHA, "Retained runtime tree differs")


def restore_runtime(root, manifest, logged, *, reuse_crc=False):
    binary = Path(manifest["binaryRoot"])
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve()
    require(binary == temporary / "release-tests/out/Products/Release" and not binary.exists()
            and not binary.is_symlink(), "Original runtime path is occupied or outside this job")
    for parent in binary.parents:
        if parent == temporary:
            break
        require(not parent.is_symlink(), "Runtime parent is linked")
    if reuse_crc:
        require(checksum(root / 'runtime.zip') == ARTIFACTS['runtime'][1]
            and checksum(root / 'bank-runtime-manifest.json') == MANIFEST_SHA
            and json.loads((root / 'bank-runtime-manifest.json').read_text()) == manifest,
            'Qualified runtime original archive or manifest changed')
    with zipfile.ZipFile(root / "runtime.zip") as outer:
        require(set(outer.namelist()) == {"runtime-manifest.json", "runtime-products.zip", "runtime-archive.json", "compiler-upload.json"}
                and (reuse_crc or outer.testzip() is None), "Runtime artifact inventory or CRC differs")
        require(sha(archive_bytes(outer, "runtime-manifest.json", 4 * 1024**2)) == MANIFEST_SHA,
                "Runtime archive manifest differs")
        with outer.open("runtime-products.zip") as source, (root / "runtime-products.zip").open("xb") as destination:
            shutil.copyfileobj(source, destination, 1024 * 1024)
    nested = root / "runtime-products.zip"
    require(checksum(nested) == RUNTIME_SHA, "Nested runtime archive differs")
    with zipfile.ZipFile(nested) as archive:
        seen = set()
        require(sum(entry.file_size for entry in archive.infolist()) < 4 * 1024**3, "Runtime archive exceeds its bound")
        for entry in archive.infolist():
            name = entry.filename.rstrip("/")
            path = PurePosixPath(name)
            require(name and str(path) == name and not path.is_absolute() and ".." not in path.parts
                    and "\\" not in name and path.parts[0] in {"Release", "__MACOSX"}
                    and name.casefold() not in seen, "Runtime archive path is unsafe or duplicated")
            seen.add(name.casefold())
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = archive.read(entry).decode()
                resolved = posixpath.normpath(posixpath.join(str(path.parent), target))
                require(not target.startswith("/") and resolved.startswith("Release/")
                        and "\\" not in target, "Runtime archive link escapes")
        require(reuse_crc or archive.testzip() is None, "Nested runtime archive CRC failed")
    binary.parent.mkdir(parents=True, exist_ok=True)
    logged(["/usr/bin/ditto", "-x", "-k", str(nested), str(binary.parent)], "restore-runtime", 300)
    verify_runtime(binary, manifest)
    require(checksum(binary / APP_OBJECT) == APP_OBJECT_SHA and checksum(binary / "NexGenVideoAppKitTestHost") == HOST_SHA,
            "Retained App object or host differs")
    return binary


def module_maps(root, binary, logged):
    scratch = root / "dependency-metadata"
    cache = os.environ["NGV_SWIFTPM_CACHE_PATH"]
    lock_sha = checksum(Path("Package.resolved"))
    require("ORT_POD_LOCAL_PATH" not in os.environ, "Onnx metadata cannot use a local override")
    logged(["swift", "package", "--cache-path", cache, "--scratch-path", str(scratch),
            "--force-resolved-versions", "resolve"], "resolve-metadata", 300)
    pins = json.loads(Path("Package.resolved").read_text())["pins"]
    require(checksum(Path("Package.resolved")) == lock_sha and len(pins) == 18, "Package lockfile changed")
    locked = {pin["identity"]: pin for pin in pins}
    state = json.loads((scratch / "workspace-state.json").read_text())["object"]["dependencies"]
    resolved = [value for value in state if value["state"].get("checkoutState")]
    require(len(locked) == len(resolved) == 18
            and {value["packageRef"]["identity"] for value in resolved} == set(locked), "Resolved dependencies differ")
    checkouts = []
    for value in resolved:
        pin = locked[value["packageRef"]["identity"]]
        path = scratch / "checkouts" / value["subpath"]
        require(path.resolve().is_relative_to((scratch / "checkouts").resolve()) and path.is_dir()
                and value["packageRef"]["location"] == pin["location"]
                and value["state"]["checkoutState"]["revision"] == pin["state"]["revision"]
                and subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True,
                                            timeout=30).strip() == pin["state"]["revision"]
                and not subprocess.check_output(["git", "-C", str(path), "status", "--porcelain", "--untracked-files=no"],
                                                text=True, timeout=30).strip(), "Dependency checkout identity differs")
        checkouts.append(path)
    write(root / "dependency-lock.json", {"Package.resolved": lock_sha, "pins": pins, "resolved": resolved})
    packages = []
    for index, package in enumerate([Path.cwd(), *checkouts]):
        output = logged(["swift", "package", "--package-path", str(package), "dump-package"],
                        "package-metadata-" + str(index), 90)
        packages.append((package, json.loads(output)))
    swift_modules = {path.name.removesuffix(".swiftmodule") for path in binary.glob("*.swiftmodule")}
    c_modules = {path.stem for path in binary.glob("*.o")} - swift_modules - {"AppKitTestHostSupport"}
    maps = []
    for name in sorted(c_modules):
        candidates = [(package, target) for package, description in packages for target in description["targets"]
                      if target["name"] == name]
        require(len(candidates) == 1 and re.fullmatch("[A-Za-z_][A-Za-z_0-9]*", name), "Clang target identity is ambiguous")
        package, target = candidates[0]
        directory = package / (target.get("path") or "Sources/" + name)
        headers = directory / (target.get("publicHeadersPath") or "include")
        require(headers.is_dir() and headers.resolve().is_relative_to(package.resolve()), "Clang public headers are absent or escaping")
        custom = headers / "module.modulemap"
        files = header_inputs(package, directory, headers)
        if custom.is_file():
            mapping = custom
        else:
            header = headers / (name + ".h")
            nested = headers / name / (name + ".h")
            umbrella = 'umbrella header "' + str(header if header.is_file() else nested) + '"' if header.is_file() or nested.is_file() else 'umbrella "' + str(headers) + '"'
            mapping = root / ("module-" + name + ".modulemap")
            mapping.write_text("module " + name + " {\n    " + umbrella + "\n    export *\n}\n")
        require(files, "Clang target contains no proven headers")
        maps.append({"name": name, "package": str(package), "target": target, "headers": str(headers),
                     "moduleMap": str(mapping), "moduleMapSHA256": checksum(mapping), "headerHashes": files})
    write(root / "clang-inputs.json", maps)
    return maps


def header_inputs(package, directory, headers):
    package = package.resolve()
    directory = directory.resolve()
    require(directory.is_relative_to(package), "Clang target directory escapes its package")
    relative = directory.relative_to(package).as_posix()
    listing = subprocess.check_output(["git", "-C", str(package), "ls-tree", "-r", "-z", "HEAD", "--", relative],
                                      timeout=30)
    tracked = {}
    for row in listing.split(b"\0"):
        if not row:
            continue
        metadata, name = row.split(b"\t", 1)
        mode, kind, object_id = metadata.decode().split()
        name = name.decode()
        path = package / name
        if path.is_relative_to(headers) or path.suffix in {".h", ".hpp", ".inc", ".def", ".modulemap"}:
            require(kind == "blob" and mode in {"100644", "100755"} and path.is_file() and not path.is_symlink(),
                    "Clang header type differs from its pin")
            original = subprocess.check_output(["git", "-C", str(package), "cat-file", "blob", object_id], timeout=30)
            require(checksum(path) == sha(original), "Clang header bytes differ from their pin")
            tracked[name] = sha(original)
    actual_public = {path.relative_to(package).as_posix() for path in headers.rglob("*") if not path.is_dir()}
    expected_public = {name for name in tracked if (package / name).is_relative_to(headers)}
    require(actual_public == expected_public and actual_public, "Public header inventory differs from its pin")
    return tracked


def testing_macro_input(compiler):
    compiler = Path(compiler)
    toolchain = compiler.parent.parent.resolve(strict=True)
    directory = toolchain / "lib/swift/host/plugins/testing"
    library = directory / "libTestingMacros.dylib"
    require(compiler.is_absolute() and compiler.is_file() and compiler.name == "swiftc" and compiler.parent.name == "bin"
            and compiler.resolve().is_relative_to(toolchain)
            and library.is_file() and library.resolve().is_relative_to(toolchain),
            "Swift Testing macro plugin is absent from the selected compiler toolchain")
    return {"compiler": str(compiler), "compilerSHA256": checksum(compiler),
            "directory": str(directory), "library": str(library), "librarySHA256": checksum(library)}


def execute(root):
    require(os.environ.get("GITHUB_REPOSITORY") == "iret77/nexgenvideo" and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("GITHUB_JOB") == "release-build" and os.environ.get("GITHUB_RUN_ATTEMPT") == "1"
            and sys.platform == "darwin" and platform.machine() == "arm64", "Repair requires the owned native release job")
    require(Path.cwd().name == "nexgenvideo", "SwiftPM package identity differs from the retained checkout")
    require(root.resolve().is_relative_to(Path(os.environ["RUNNER_TEMP"]).resolve()), "Repair root escapes its job")
    pending = json.loads((root / "pending.json").read_text())
    require(pending["schema"] == "release-native-scoped-repair-pending/v1"
            and pending["sourceSHA"] == os.environ["GITHUB_SHA"] and pending["originalRun"] == RUN, "Pending repair differs")
    for role, (_, expected, _) in ARTIFACTS.items():
        require(checksum(root / (role + ".zip")) == expected, "Transferred original artifact differs")
    require(checksum(root / "runtime-manifest.json") == MANIFEST_SHA, "Transferred runtime manifest differs")
    manifest = json.loads((root / "runtime-manifest.json").read_text())
    require(verify_sources(os.environ["GITHUB_SHA"], manifest) == pending["sourceBinding"], "Reviewed source binding changed")
    evidence = root / "repair-evidence"
    evidence.mkdir(exist_ok=False)
    commands = []

    def logged(argv, label, timeout=180):
        command_path = evidence / (label + ".command.json")
        write(command_path, argv)
        with (evidence / (label + ".stdout")).open("xb") as out, (evidence / (label + ".stderr")).open("xb") as err:
            result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=timeout)
        commands.append({"command": argv, "exitCode": result.returncode, "label": label})
        write(evidence / "commands.json", commands)
        require(result.returncode == 0, "Native repair command failed: " + label)
        return (evidence / (label + ".stdout")).read_text()

    require(logged(["xcodebuild", "-version"], "xcode").strip() == "Xcode 27.2\nBuild version 27B52"
            and logged(["swift", "--version"], "swift").splitlines()[0]
            == "Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)"
            and logged(["sw_vers", "-productVersion"], "os").strip() == "27.2"
            and logged(["sw_vers", "-buildVersion"], "os-build").strip() == "26B123"
            and platform.python_version() == "3.13.17", "Original compiler or native runtime environment changed")
    with (root / "native-repair.STARTED.json").open("x") as stream:
        json.dump({"runID": os.environ["GITHUB_RUN_ID"], "sourceSHA": os.environ["GITHUB_SHA"], "oneShot": True}, stream)
        stream.flush(); os.fsync(stream.fileno())
    binary = restore_runtime(root, manifest, logged)
    sdk = logged(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "sdk").strip()
    sdk_version = logged(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "sdk-version").strip()
    require(sdk_version == "27.2" and Path(sdk).is_dir(), "Retained product SDK changed")
    platform_root = Path(logged(["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], "platform").strip())
    developer_frameworks = platform_root / "Developer/Library/Frameworks"
    compiler = logged(["xcrun", "--find", "swiftc"], "swiftc").strip()
    macros = testing_macro_input(compiler)
    write(evidence / "testing-macro-input.json", macros)
    object_path = evidence / "NexGenVideoTests.o"
    bundle = root / "repaired/NexGenVideoTests.xctest"
    shutil.copytree(binary / "NexGenVideoTests.xctest", bundle, symlinks=True)
    image = bundle / "Contents/MacOS/NexGenVideoTests"
    objects = sorted(path for path in binary.glob("*.o") if path.name not in EXCLUDED_OBJECTS)
    objects.append(binary / APP_OBJECT)
    require(len(objects) == 35 and all(checksum(path) == manifest["files"][path.relative_to(binary).as_posix()]["sha256"]
                                     for path in objects), "App static object closure differs")
    origin = None
    if pending.get("linkedProducer"):
        origin = restore_linked(root, pending["sourceBinding"], image, evidence)
        verify_linked_producer(pending["linkedProducer"], pending["sourceBinding"])
        require(all(pending["linkedProducer"][key] == value for key, value in origin.items())
                and macros == origin["testingMacroInput"], "Retained compiler producer or current toolchain differs")
    else:
        maps = module_maps(root, binary, logged)
        flags = ["-target", "arm64-apple-macos26.0", "-sdk", sdk, "-F", str(developer_frameworks),
                 "-F", str(binary), "-I", str(binary)]
        for item in maps:
            flags += ["-I", item["headers"], "-Xcc", "-fmodule-map-file=" + item["moduleMap"]]
        logged([compiler, *flags, "-plugin-path", macros["directory"], "-c", "-parse-as-library", "-module-name", "NexGenVideoTests",
                "-package-name", "nexgenvideo", "-swift-version", "6", "-O", "-g", "-whole-module-optimization",
                "-enable-testing", "-Xfrontend", "-enable-cross-import-overlays", "-D", "SWIFT_PACKAGE", "-emit-module", "-emit-module-path",
                str(evidence / "NexGenVideoTests.swiftmodule"), *(str(Path.cwd() / name) for name in TEST_SOURCES),
                "-o", str(object_path)], "compile-tests", 300)
        link = [compiler, *flags, "-Xlinker", "-bundle", "-o", str(image), str(object_path), *map(str, objects),
                "-L", str(binary), "-lNexGenEngine", "-lproc", "-lc++", "-framework", "XCTest",
                "-framework", "Testing", "-framework", "Sparkle", "-framework", "Sentry", "-framework", "whisper",
                "-framework", "onnxruntime", "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", str(binary),
                "-Xlinker", "-weak_framework", "-Xlinker", "MusicUnderstanding", "-Xlinker", "-dead_strip"]
        logged(link, "link-test-bundle", 180)
    pre_sign_image = checksum(image)
    signed_objects = sign_copied_bundle(bundle, logged)
    load_commands = logged(["otool", "-hvL", str(image)], "test-bundle-image")
    require("BUNDLE" in load_commands and "@rpath/libNexGenEngine.dylib" in load_commands,
            "Repaired test bundle type or dynamic Engine differs")
    logged(["xcrun", "dwarfdump", "--uuid", str(image)], "test-bundle-uuid")
    verify_runtime(binary, manifest)
    compile_receipt = {"sourceBinding": pending["sourceBinding"], "commands": commands,
                       "testObjectSHA256": checksum(object_path), "testBundleSHA256": checksum(image),
                       "appObjectSHA256": APP_OBJECT_SHA, "staticObjects": {
                           path.relative_to(binary).as_posix(): checksum(path) for path in objects},
                       "clangInputsSHA256": checksum(root / "clang-inputs.json"),
                       "testingMacroInput": macros, "preBundleSignImageSHA256": pre_sign_image,
                       "compilerSourceSHA": LINKED_SOURCE if origin else os.environ["GITHUB_SHA"],
                       "compilerProducer": pending.get("linkedProducer"), "signedCodeObjects": signed_objects}
    write(evidence / "compile-receipt.json", compile_receipt)
    logged(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(bundle), str(root / "repaired-test-products.zip")],
           "archive-repaired-test-products", 180)
    write(root / "built.json", {"schema": "release-native-scoped-products/v1", "sourceSHA": os.environ["GITHUB_SHA"],
          "runID": int(os.environ["GITHUB_RUN_ID"]), "attempt": 1, "binaryRoot": str(binary), "testImage": str(image),
          "compilerSourceSHA": compile_receipt["compilerSourceSHA"],
          "compileReceiptSHA256": checksum(evidence / "compile-receipt.json"),
          "archiveSHA256": checksum(root / "repaired-test-products.zip")})


def confirm(root, identifier, digest):
    require(sys.platform == "darwin" and os.environ.get("GITHUB_JOB") == "release-build"
            and re.fullmatch("[1-9][0-9]*", identifier or "") and re.fullmatch("[a-f0-9]{64}", digest or ""),
            "Exact successful native product upload is required")
    artifact = api("actions/artifacts/" + identifier)
    require(artifact.get("name") == "release-scoped-test-products-" + os.environ["GITHUB_RUN_ID"] + "-a1"
            and artifact.get("digest") == "sha256:" + digest and artifact.get("expired") is False
            and artifact.get("workflow_run", {}).get("id") == int(os.environ["GITHUB_RUN_ID"])
            and artifact.get("workflow_run", {}).get("head_sha") == os.environ["GITHUB_SHA"], "Product upload identity differs")
    built = json.loads((root / "built.json").read_text())
    require(checksum(root / "repaired-test-products.zip") == built["archiveSHA256"]
            and checksum(root / "repair-evidence/compile-receipt.json") == built["compileReceiptSHA256"],
            "Uploaded scoped compiler products changed")
    write(root / "compiler-upload.json", {"artifact": artifact, "built": built})


def run_selected(root):
    from run_macos_tests import app_environment, framework_output, host_receipt, run_process, swift_events
    require(sys.platform == "darwin" and platform.machine() == "arm64"
            and os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("GITHUB_JOB") == "release-build"
            and os.environ.get("GITHUB_RUN_ATTEMPT") == "1", "Scoped tests require the owned native release job")
    pending = json.loads((root / "pending.json").read_text())
    manifest = json.loads((root / "runtime-manifest.json").read_text())
    built = json.loads((root / "built.json").read_text())
    upload = json.loads((root / "compiler-upload.json").read_text())
    require(upload["built"] == built and built["sourceSHA"] == pending["sourceSHA"] == os.environ["GITHUB_SHA"]
            and built["runID"] == int(os.environ["GITHUB_RUN_ID"]) and built["attempt"] == 1
            and checksum(root / "repaired-test-products.zip") == built["archiveSHA256"]
            and checksum(root / "repair-evidence/compile-receipt.json") == built["compileReceiptSHA256"],
            "Scoped test input or confirmed compiler upload changed")
    require(checksum(root / "runtime-manifest.json") == MANIFEST_SHA
            and verify_sources(os.environ["GITHUB_SHA"], manifest) == pending["sourceBinding"], "Source or manifest binding changed")
    binary, image = Path(built["binaryRoot"]), Path(built["testImage"])
    require(binary == Path(manifest["binaryRoot"]) and image == root / "repaired/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests",
            "Scoped test image path differs")
    verify_runtime(binary, manifest)
    compile_receipt = json.loads((root / "repair-evidence/compile-receipt.json").read_text())
    require(checksum(image) == compile_receipt["testBundleSHA256"] and checksum(binary / APP_OBJECT) == APP_OBJECT_SHA,
            "Scoped test image or App object changed")
    if pending.get("linkedProducer"):
        verify_linked_producer(compile_receipt["compilerProducer"], pending["sourceBinding"])
        require(compile_receipt["compilerProducer"] == pending["linkedProducer"]
                and built["compilerSourceSHA"] == compile_receipt["compilerSourceSHA"] == LINKED_SOURCE
                and compile_receipt["preBundleSignImageSHA256"] == LINKED_IMAGE_SHA
                and checksum(root / "repair-evidence/NexGenVideoTests.o") == LINKED_OBJECT_SHA,
                "Signed test derivative lost its original compiler provenance")
    folder = root / "repair-evidence/app-swift-testing"
    folder.mkdir(exist_ok=False)
    host = binary / "NexGenVideoAppKitTestHost"
    environment = app_environment(dict(os.environ), binary, image, folder)
    require(not any(key.startswith(("NGV_ACCEPTANCE", "NGV_APP_DIAGNOSTIC", "NSZombie"))
                    for key in environment), "Scoped execution cannot use a diagnostic substitute")
    environment.update(NGV_APPKIT_TEST_BUNDLE=str(image), NGV_APPKIT_TEST_EVENTS=str(folder / "events.jsonl"),
                       NGV_APPKIT_TEST_RECEIPT=str(folder / "host-receipt.json"),
                       NGV_APPKIT_EXCEPTION_EVIDENCE=str(folder / "exception.jsonl"),
                       SWIFT_BACKTRACE="enable=yes,interactive=no,demangle=yes,cache=no")
    command = [str(host), "--event-stream-version", "0", "--filter", "NexGenVideoTests.GenerationBatchTests", "--no-parallel"]
    write(folder / "command.json", command)
    with (root / "native-tests.STARTED.json").open("x") as stream:
        json.dump({"runID": os.environ["GITHUB_RUN_ID"], "sourceSHA": os.environ["GITHUB_SHA"], "command": command}, stream)
        stream.flush(); os.fsync(stream.fileno())
    observation = {}
    code, pid = run_process(command, folder / "console.log", environment, observation)
    write(folder / "process.json", {"exitCode": code, "pid": pid, "observation": observation})
    require(code == 0 and observation.get("outputCapture", {}).get("originalExitCode") == 0
            and observation["outputCapture"].get("eof") is True, "Scoped App process failed or output is incomplete")
    events = swift_events(folder / "events.jsonl", "NexGenVideoTests")
    selected = sorted([*pending["inventory"]["selectedMethods"], ADDED])
    require(events["functionExecutions"] == 59 and not events["skippedFunctionIDs"]
            and sorted(method(identity) for identity in events["startedFunctionIDs"]) == selected
            and events["startedFunctionIDs"] == events["endedFunctionIDs"], "Scoped App method coverage differs")
    raw = [json.loads(line) for line in (folder / "events.jsonl").read_text().splitlines()]
    starts = [row["payload"]["testID"] for row in raw if row.get("kind") == "event" and row["payload"]["kind"] == "testCaseStarted"]
    ends = [row["payload"]["testID"] for row in raw if row.get("kind") == "event" and row["payload"]["kind"] == "testCaseEnded"]
    require(len(starts) == len(ends) == 9 and Counter(starts) == Counter(ends), "Scoped parameter cases differ")
    receipt = host_receipt(folder / "host-receipt.json", events, pid=pid, bundle=image, host=host, source_sha=os.environ["GITHUB_SHA"])
    assessment = framework_output(folder / "console.log", 1, 0)
    verify_runtime(binary, manifest)
    require(verify_sources(os.environ["GITHUB_SHA"], manifest) == pending["sourceBinding"], "Sources changed during scoped execution")
    write(folder / "verified.json", {"events": events, "hostReceipt": receipt, "framework": assessment})
    result = {"schema": "release-native-scoped-repair/v1", "sourceSHA": os.environ["GITHUB_SHA"],
              "runID": int(os.environ["GITHUB_RUN_ID"]), "attempt": 1, "originalRun": RUN, "originalSourceSHA": SOURCE,
              "originalEventSHA256": EVENT_SHA, "originalRuntimeSHA256": RUNTIME_SHA, "originalRuntimeTreeSHA256": TREE_SHA,
              "selectedMethods": selected, "hostSHA256": HOST_SHA, "appObjectSHA256": APP_OBJECT_SHA, "passed": True,
              "counts": {"freshAppMethods": 59, "reusedAppMethods": 3646, "reusedXCTest": 48, "reusedEngineMethods": 896,
                         "executions": 4649, "declaredAppMethods": 3713, "appSkips": 8, "engineSkips": 14, "freshParameterCases": 9},
              "eventSHA256": checksum(folder / "events.jsonl"), "consoleSHA256": checksum(folder / "console.log"),
              "hostReceiptSHA256": checksum(folder / "host-receipt.json"), "compileReceiptSHA256": built["compileReceiptSHA256"],
              "testBundleSHA256": checksum(image), "sourceBinding": pending["sourceBinding"], "compilerUpload": upload}
    result.update(compilerSourceSHA=compile_receipt["compilerSourceSHA"], compilerProducer=compile_receipt["compilerProducer"])
    result["reusedAppMethodIDsSHA256"] = sha(json.dumps(pending["inventory"]["reusedAppMethodIDs"], separators=(",", ":")).encode())
    verify_receipt(result, os.environ["GITHUB_SHA"], int(os.environ["GITHUB_RUN_ID"]))
    write(root / "receipt.json", result)


def verify_receipt(receipt, source, run_id):
    require(receipt.get("schema") == "release-native-scoped-repair/v1" and receipt.get("sourceSHA") == source
            and receipt.get("runID") == run_id and receipt.get("attempt") == 1
            and receipt.get("originalSourceSHA") == SOURCE and receipt.get("originalRun") == RUN
            and receipt.get("originalEventSHA256") == EVENT_SHA and receipt.get("originalRuntimeSHA256") == RUNTIME_SHA
            and receipt.get("originalRuntimeTreeSHA256") == TREE_SHA and receipt.get("passed") is True,
            "Scoped repair execution identity differs")
    counts = {"freshAppMethods": 59, "reusedAppMethods": 3646, "reusedXCTest": 48,
              "reusedEngineMethods": 896, "executions": 4649, "declaredAppMethods": 3713,
              "appSkips": 8, "engineSkips": 14, "freshParameterCases": 9}
    require(receipt.get("counts") == counts and receipt.get("hostSHA256") == HOST_SHA
            and receipt.get("appObjectSHA256") == APP_OBJECT_SHA
            and len(set(receipt.get("selectedMethods", []))) == 59
            and FAILED in receipt["selectedMethods"] and ADDED in receipt["selectedMethods"]
            and all(value.startswith(PREFIX) for value in receipt["selectedMethods"])
            and sha(json.dumps(receipt["selectedMethods"], separators=(",", ":")).encode()) == SELECTED_SHA
            and receipt.get("reusedAppMethodIDsSHA256") == REUSED_SHA, "Scoped repair coverage differs")
    for name in ("eventSHA256", "consoleSHA256", "hostReceiptSHA256", "compileReceiptSHA256", "testBundleSHA256"):
        require(re.fullmatch("[a-f0-9]{64}", receipt.get(name, "")), "Scoped repair evidence digest is missing")
    upload = receipt.get("compilerUpload", {})
    artifact, built = upload.get("artifact", {}), upload.get("built", {})
    require(type(artifact.get("id")) is int and artifact["id"] > 0 and artifact.get("expired") is False
            and artifact.get("name") == "release-scoped-test-products-" + str(run_id) + "-a1"
            and artifact.get("workflow_run", {}).get("id") == run_id
            and artifact.get("workflow_run", {}).get("head_sha") == source
            and re.fullmatch("sha256:[a-f0-9]{64}", artifact.get("digest", ""))
            and built.get("schema") == "release-native-scoped-products/v1"
            and re.fullmatch("[a-f0-9]{64}", built.get("archiveSHA256", ""))
            and built.get("sourceSHA") == source and built.get("runID") == run_id and built.get("attempt") == 1
            and built.get("compileReceiptSHA256") == receipt["compileReceiptSHA256"], "Scoped compiler producer differs")
    require(re.fullmatch("[a-f0-9]{40}", built.get("compilerSourceSHA", ""))
            and receipt.get("compilerSourceSHA") == built["compilerSourceSHA"]
            and (built["compilerSourceSHA"] == source or receipt.get("compilerProducer") is not None),
            "A retained compiler origin is missing")
    if receipt.get("compilerProducer") is not None:
        verify_linked_producer(receipt["compilerProducer"], receipt["sourceBinding"])
        require(receipt.get("compilerSourceSHA") == built.get("compilerSourceSHA") == LINKED_SOURCE,
                "Signing execution cannot replace the original compiler source")
    return receipt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("prepare", "build", "confirm", "run"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--artifact-id")
    parser.add_argument("--artifact-digest")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.root, args.run_id)
    elif args.command == "build":
        execute(args.root)
    elif args.command == "confirm":
        confirm(args.root, args.artifact_id, args.artifact_digest)
    else:
        run_selected(args.root)


if __name__ == "__main__":
    main()
