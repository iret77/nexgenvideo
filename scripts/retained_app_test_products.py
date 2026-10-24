"""Bind and restore one retained native App diagnostic without rebuilding."""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import stat
import struct
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from verify_diagnostic_candidate import APP_DIAGNOSTIC_PATHS, verify_app_crash_archive, verify_app_diagnostic
from app_host_zombie_diagnostic import sample_image_records


REPLAY_PATHS = {
    ".github/workflows/diagnostic-acceptance.yml", "scripts/retained_app_test_products.py",
    "scripts/test_retained_app_test_products.py", "scripts/run_macos_tests.py",
    "scripts/test_run_macos_tests.py", "scripts/app_host_zombie_diagnostic.py",
    "scripts/test_app_host_zombie_diagnostic.py", "scripts/capture_render_review_test_diagnostic.py",
    "scripts/test_swift_test_failure_propagation.py",
}
SYSTEM_IMAGES = {"AppleParavirtGPUMetalIOGPUFamily", "IOGPU", "CoreImage", "MPSCore", "MPSImage", "Metal"}
UUID = r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"


def replay_selection(kind):
    if kind == "ci-app-glow-replay":
        return "glow-reproduction", "GlowKernelTests"
    if kind == "ci-app-full-replay":
        return "app-reproduction", ""
    raise ValueError("Unknown retained App replay selection")


def original_function_inventory(suite, selection):
    events = suite["phases"][0]["events"]
    ended = events["endedFunctionIDs"]
    require(isinstance(ended, list) and len(ended) == len(set(ended))
            == events["functionExecutions"] == suite["testExecutions"] > 0
            and all(name.startswith("NexGenVideoTests.") for name in ended), "Original full App inventory is inconsistent")
    selected = [name for name in ended if not selection or name.startswith("NexGenVideoTests.GlowKernelTests/")]
    require(selected and (not selection or len(selected) == 3), "Original selected inventory is incomplete")
    return sorted(selected)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def checksum(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + "\n")


def command(args, timeout=40):
    return subprocess.check_output(args, stdin=subprocess.DEVNULL, timeout=timeout, text=True).strip()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, target):
        return None


def github_request(path):
    return urllib.request.Request("https://api.github.com/repos/iret77/nexgenvideo/" + path,
        headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"], "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "nexgenvideo-retained-diagnostic"})


def api(path):
    with urllib.request.build_opener(NoRedirect()).open(github_request(path), timeout=40) as response:
        require(response.status == 200, "GitHub metadata request did not succeed")
        data = response.read(16 * 1024 * 1024 + 1)
        require(len(data) <= 16 * 1024 * 1024, "GitHub metadata exceeds its bound")
        return json.loads(data)


def archive_bytes(archive, name, limit=8 * 1024 * 1024):
    entries = [entry for entry in archive.infolist() if entry.filename == name]
    require(len(entries) == 1 and entries[0].file_size <= limit, "Missing, duplicate or oversized archive record")
    return archive.read(entries[0])


def archive_json(archive, name):
    return json.loads(archive_bytes(archive, name))


def verify_artifact(artifact, producer, job, artifact_id, digest, name):
    require(artifact.get("id") == artifact_id and artifact.get("name") == name
            and artifact.get("digest") == "sha256:" + digest and artifact.get("expired") is False
            and artifact.get("workflow_run", {}).get("id") == producer["id"]
            and artifact.get("workflow_run", {}).get("head_sha") == producer["head_sha"],
            "Retained artifact identity differs")
    instant = lambda value: datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(instant(job["started_at"]) <= instant(artifact["created_at"])
            <= instant(artifact["updated_at"]) <= instant(job["completed_at"])
            and instant(artifact["expires_at"]) > datetime.now(timezone.utc), "Retained artifact attempt or expiry differs")


def download(artifact, destination):
    opener = urllib.request.build_opener(NoRedirect())
    try:
        response = opener.open(github_request(f"actions/artifacts/{artifact['id']}/zip"), timeout=40)
    except urllib.error.HTTPError as response:
        with response:
            require(response.code == 302, "GitHub artifact redirect did not succeed")
            location = response.headers.get("Location", "")
    else:
        response.close()
        raise ValueError("GitHub artifact response is not the required redirect")
    target = urllib.parse.urlsplit(location)
    require(target.scheme == "https" and target.hostname and not target.username and not target.password,
            "GitHub artifact redirect is not a secure download")
    try:
        with opener.open(urllib.request.Request(location), timeout=180) as response, destination.open("xb") as output:
            require(response.status == 200, "Artifact download did not succeed")
            received = 0
            for block in iter(lambda: response.read(1024 * 1024), b""):
                received += len(block)
                require(received <= artifact["size_in_bytes"], "Artifact download exceeds its bound")
                output.write(block)
    except (urllib.error.URLError, OSError):
        raise ValueError("Artifact download failed; signed URL is withheld") from None
    require(destination.stat().st_size == artifact["size_in_bytes"]
            and checksum(destination) == artifact["digest"].removeprefix("sha256:"), "Downloaded artifact bytes differ")


def verify_producer(run, jobs, source_sha):
    require(run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("head_sha") == source_sha and run.get("run_attempt") == 1
            and run.get("path") == ".github/workflows/diagnostic-acceptance.yml"
            and run.get("event") == "workflow_dispatch" and run.get("status") == "completed"
            and run.get("conclusion") == "success", "Retained products require the completed original diagnostic producer")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete producer jobs")
    found = {}
    for name in ("source", "ci-app-test"):
        matches = [job for job in jobs["jobs"] if job.get("name") == name]
        require(len(matches) == 1, "Missing or duplicate producer job")
        job = matches[0]
        require(job.get("run_id") == run["id"] and job.get("run_attempt") == 1
                and job.get("head_sha") == source_sha and job.get("status") == "completed"
                and job.get("conclusion") == "success", "Producer job identity or result differs")
        found[name] = job
    for name in ("Preserve the reviewed harness and bind the original test source",
                 "Compile unchanged original native test products", "Retain compiled products before diagnostic execution",
                 "Diagnose the original full App SwiftTesting backend once", "Verify diagnostic completion and unchanged source",
                 "Upload original App diagnostic evidence", "Upload retained native test products"):
        matches = [step for step in found["ci-app-test"]["steps"] if step.get("name") == name]
        require(len(matches) == 1 and matches[0].get("status") == "completed"
                and matches[0].get("conclusion") == "success", "Required producer step did not pass")
    return found["ci-app-test"]


def verify_execution(compiled, execution, suite, wrapper, product_sha, producer_sha, run_id):
    require(compiled.get("productSourceSHA") == execution.get("buildSourceSHA") == suite.get("productSourceSHA") == product_sha
            and compiled.get("harnessSourceSHA") == execution.get("harnessSourceSHA")
            == suite.get("sourceSHA") == suite.get("harnessSourceSHA") == producer_sha,
            "Original product and harness binding differs")
    require(wrapper.get("runID") == str(run_id) and wrapper.get("sourceSHA") == producer_sha
            and wrapper.get("testExitCode") == wrapper.get("effectiveExitCode") == 0
            and suite.get("completed") is True and suite.get("scope") == "app-swift-testing"
            and suite.get("filter") == "" and len(suite.get("phases", [])) == 1,
            "Original App diagnostic did not complete")
    phase = suite["phases"][0]
    diagnostic, receipt = phase.get("diagnostic", {}), phase.get("originalHostReceipt", {})
    require(phase.get("exitCode") == 0 and phase.get("status") == "verified-execution"
            and type(phase.get("pid")) is int and phase["pid"] > 0
            and phase["pid"] == diagnostic.get("pid") == receipt.get("pid")
            and diagnostic.get("status") == "verified" and diagnostic.get("profile") == "zombies"
            and diagnostic.get("environment") == {"NSZombieEnabled": "YES", "otherDiagnosticVariablesPresent": False}
            and diagnostic.get("memoryErrors") == [] and diagnostic.get("sampleCount", 0) >= 2
            and diagnostic.get("productSourceSHA") == product_sha
            and diagnostic.get("sourceSHA") == diagnostic.get("harnessSourceSHA") == receipt.get("sourceSHA") == producer_sha
            and receipt.get("abiSucceeded") is True and receipt.get("completed") is True,
            "Original owned App execution is unproven")
    root = Path(compiled["binRoot"])
    require(root.is_absolute() and set(compiled["binaries"]) == {
                "NexGenVideoAppKitTestHost", "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"}
            and receipt.get("hostExecutable") == str(root / "NexGenVideoAppKitTestHost")
            and receipt.get("bundleBinary") == str(root / "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"),
            "Original compiled products do not match the executed paths")
    host = compiled["binaries"]["NexGenVideoAppKitTestHost"]
    require(diagnostic.get("hostSHA256") == host["sha256"]
            and diagnostic.get("hostUUID", "").lower() in {value.lower() for value in re.findall(UUID, host["uuidOutput"])},
            "Original executed host bytes or UUID differ from retained products")
    for image in compiled["binaries"].values():
        require(re.fullmatch(r"[a-f0-9]{64}", image["sha256"])
                and len(re.findall(UUID, image["uuidOutput"])) == 1, "Original executable identity is malformed")


def appledouble_attributes(data):
    require(82 <= len(data) <= 16 * 1024 * 1024, "Unsupported AppleDouble size")
    magic, version, _, count = struct.unpack_from(">II16sH", data)
    require((magic, version, count) == (0x00051607, 0x00020000, 2), "Invalid AppleDouble header")
    finder, resource = (struct.unpack_from(">III", data, offset) for offset in (26, 38))
    require(finder[0] == 9 and finder[1] == 50 and finder[2] >= 32
            and resource[0] == 2 and resource[1] == 50 + finder[2]
            and resource[1] + resource[2] == len(data), "Unsupported AppleDouble layout")
    attributes = {}
    if any(data[50:82]):
        attributes["com.apple.FinderInfo"] = data[50:82].hex()
    if resource[2]:
        attributes["com.apple.ResourceFork"] = data[resource[1]:].hex()
    if finder[2] > 32:
        require(len(data) >= 120 and data[82:84] == b"\0\0", "Truncated AppleDouble attributes")
        header = struct.unpack_from(">8I2H", data, 84)
        marker, _, total, start, length, *unused = header
        require(marker == 0x41545452 and total == resource[1] and 120 <= start <= total
                and start + length == total and unused[:4] == [0, 0, 0, 0], "Invalid AppleDouble attribute header")
        cursor, ranges = 120, []
        for _ in range(header[-1]):
            require(cursor + 11 <= start, "Truncated AppleDouble attribute entry")
            offset, size, flags, name_size = struct.unpack_from(">IIHB", data, cursor)
            require(flags == 0 and 1 < name_size <= 128 and cursor + 11 + name_size <= start
                    and start <= offset <= offset + size <= total, "Invalid AppleDouble attribute bounds")
            raw_name = data[cursor + 11:cursor + 11 + name_size]
            require(raw_name[-1:] == b"\0" and b"\0" not in raw_name[:-1], "Invalid AppleDouble attribute name")
            name = raw_name[:-1].decode("utf-8")
            require(name not in attributes, "Duplicate AppleDouble attribute")
            attributes[name] = data[offset:offset + size].hex()
            ranges.append((offset, offset + size))
            cursor += (11 + name_size + 3) & ~3
        require(cursor <= start and all(a[1] <= b[0] for a, b in zip(sorted(ranges), sorted(ranges)[1:])),
                "Overlapping AppleDouble attributes")
    return attributes


def manifest(path):
    records = {}
    metadata = {}
    folded = set()
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            name = entry.filename.rstrip("/")
            parts = PurePosixPath(name)
            require(name and not parts.is_absolute() and ".." not in parts.parts
                    and "\\" not in name and str(parts) == name, "Product archive has an unsafe path")
            require(name.casefold() not in folded, "Product archive has duplicate or colliding paths")
            folded.add(name.casefold())
            require(parts.parts[0] in ("Debug", "__MACOSX"), "Unexpected product archive root")
            if parts.parts[0] == "__MACOSX" and entry.is_dir():
                continue
            mode = entry.external_attr >> 16
            if parts.name.startswith("._"):
                require(stat.S_ISREG(mode) and entry.file_size <= 16 * 1024 * 1024, "Invalid product metadata type or size")
                target = parts.with_name(parts.name[2:])
                if parts.parts[0] == "__MACOSX":
                    target = PurePosixPath(*target.parts[1:])
                require(target.parts[0] == "Debug" and str(target) not in metadata, "Ambiguous product metadata target")
                metadata[str(target)] = appledouble_attributes(archive.read(entry))
                continue
            require(parts.parts[0] == "Debug", "Unexpected product metadata entry")
            record = {"mode": stat.S_IMODE(mode), "size": entry.file_size}
            if entry.is_dir():
                require(stat.S_ISDIR(mode), "Product directory metadata differs")
                record["kind"] = "directory"
            elif stat.S_ISLNK(mode):
                require(entry.file_size < 4096, "Product link exceeds its bound")
                target = archive.read(entry).decode()
                resolved = posixpath.normpath(str(parts.parent / target))
                require(not target.startswith("/") and "\\" not in target and "\0" not in target
                        and (resolved == "Debug" or resolved.startswith("Debug/")), "Product link escapes its archive")
                record.update(kind="symlink", target=target)
            else:
                require(stat.S_ISREG(mode), "Unexpected product file type")
                digest = hashlib.sha256()
                with archive.open(entry) as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(block)
                record.update(kind="file", sha256=digest.hexdigest())
            records[name] = record
    require(records.get("Debug", {}).get("kind") == "directory", "Product archive has no Debug directory")
    for target, attributes in metadata.items():
        require(target in records and records[target]["kind"] != "symlink", "Missing or linked product metadata target")
        records[target]["xattrs"] = attributes
    for name in records:
        for parent in PurePosixPath(name).parents:
            if str(parent) != ".":
                require(records.get(str(parent), {}).get("kind") == "directory", "Archive path has a missing or linked parent")
    return records


def read_xattrs(path):
    if sys.platform == "linux":
        return {name: os.getxattr(path, name, follow_symlinks=False).hex()
                for name in os.listxattr(path, follow_symlinks=False)}
    require(sys.platform == "darwin", "Unsupported extended-attribute platform")
    libc = ctypes.CDLL(None, use_errno=True)
    libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    libc.listxattr.restype = ctypes.c_ssize_t
    libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.getxattr.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)

    def read(operation, limit):
        size = operation(None, 0)
        if size < 0:
            raise OSError(ctypes.get_errno(), "Cannot size original extended attributes")
        require(size <= limit, "Extended attributes exceed their bound")
        buffer = ctypes.create_string_buffer(max(size, 1))
        actual = operation(buffer, size)
        if actual < 0:
            raise OSError(ctypes.get_errno(), "Cannot read original extended attributes")
        require(actual == size, "Extended attributes changed while reading")
        return bytes(buffer[:size])

    names = read(lambda buffer, size: libc.listxattr(encoded, buffer, size, 1), 65536)
    require(not names or names.endswith(b"\0"), "Malformed extended-attribute name list")
    names = names[:-1].split(b"\0") if names else []
    require(all(names) and len(set(names)) == len(names), "Empty or duplicate extended-attribute name")
    return {os.fsdecode(name): read(lambda buffer, size: libc.getxattr(encoded, name, buffer, size, 0, 1),
                                  16 * 1024 * 1024).hex() for name in names}


def verify_tree(root, records):
    actual = {"Debug": root}
    actual.update({"Debug/" + str(path.relative_to(root)): path for path in root.rglob("*")})
    require(set(actual) == set(records), "Restored products have missing or additional entries")
    for name, record in records.items():
        path = actual[name]
        mode = path.lstat().st_mode
        attributes = read_xattrs(path)
        require(attributes == record.get("xattrs", {}), "Restored product extended attributes differ: " + name)
        if record["kind"] == "symlink":
            require(stat.S_ISLNK(mode) and os.readlink(path) == record["target"], "Restored product link differs: " + name)
            path.resolve(strict=True).relative_to(root.resolve(strict=True))
        else:
            require((stat.S_ISDIR(mode) if record["kind"] == "directory" else stat.S_ISREG(mode))
                    and stat.S_IMODE(mode) == record["mode"], "Restored product type or permissions differ: " + name)
            if record["kind"] == "file":
                require(path.stat().st_size == record["size"] and checksum(path) == record["sha256"],
                        "Restored product bytes differ: " + name)


def restore(folder):
    binding = json.loads((folder / "binding.json").read_text())
    profile, selection = replay_selection(binding["kind"])
    require(binding["kind"] == os.environ["REPLAY_KIND"] and binding["diagnosticProfile"] == profile
            and binding["selection"] == selection, "Restore mode differs from the bound execution")
    require(command(["git", "rev-parse", "HEAD"]) == binding["productSHA"]
            and os.environ["GITHUB_SHA"] == binding["harnessSHA"], "Replay source binding changed")
    require(command(["xcodebuild", "-version"]) == binding["compiled"]["toolchain"].strip(), "Replay toolchain differs")
    require(command(["sw_vers", "-buildVersion"]) == binding["osBuild"], "Replay macOS build differs")
    installed = {}
    for name, image in binding["systemImages"].items():
        output = command(["xcrun", "dyld_info", "-uuid", image["path"]])
        require(image["uuid"] in {value.lower() for value in re.findall(UUID, output)}, "Installed system image differs")
        installed[name] = output
    write(folder / "installed-system-images.json", installed)
    root = Path(binding["compiled"]["binRoot"])
    workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
    require(root == workspace / ".build/out/Products/Debug" and not root.exists() and not root.is_symlink(),
            "The original product destination is not an absent checkout path")
    artifact = api("actions/artifacts/" + binding["inputs"]["PRODUCTS_ID"])
    expected = json.loads((folder / "products-artifact.json").read_text())
    require(artifact == expected, "Retained artifact metadata changed before restore")
    outer = folder / "retained-products-original.zip"
    download(artifact, outer)
    inner = folder / "app-test-products.zip"
    with zipfile.ZipFile(outer) as archive:
        require(archive.namelist() == ["app-test-products.zip"], "Unexpected outer product archive")
        with archive.open("app-test-products.zip") as source_file, inner.open("xb") as destination:
            for block in iter(lambda: source_file.read(1024 * 1024), b""):
                destination.write(block)
    require(checksum(inner) == binding["innerArchiveSHA256"], "Inner product archive differs")
    records = manifest(inner)
    engine_paths = [name for name, record in records.items()
                    if PurePosixPath(name).name == "libNexGenEngine.dylib" and record["kind"] == "file"]
    require(set(engine_paths) == {"Debug/libNexGenEngine.dylib",
            "Debug/NexGenVideoTests.xctest/Contents/Frameworks/libNexGenEngine.dylib",
            "Debug/NexGenEngineTests.xctest/Contents/Frameworks/libNexGenEngine.dylib"}
            and len({records[name]["sha256"] for name in engine_paths}) == 1,
            "Retained Engine copies are missing, ambiguous or different")
    write(folder / "restored-manifest.json", records)
    root.parent.mkdir(parents=True, exist_ok=True)
    require(root.parent.resolve(strict=True).is_relative_to(workspace), "Product destination escapes checkout")
    with (folder / "restore.stdout.log").open("xb") as output, (folder / "restore.stderr.log").open("xb") as error:
        subprocess.run(["ditto", "-x", "-k", str(inner), str(root.parent)], stdin=subprocess.DEVNULL,
                       stdout=output, stderr=error, check=True, timeout=120)
    verify_tree(root, records)
    for relative, original in binding["compiled"]["binaries"].items():
        path = root / relative
        require(checksum(path) == original["sha256"], "Retained native executable differs")
        actual = command(["xcrun", "dwarfdump", "--uuid", str(path)])
        require(re.findall(UUID, actual) == re.findall(UUID, original["uuidOutput"]), "Retained native UUID differs")
        require(binding["originalProductImages"][path.name] in {value.lower() for value in re.findall(UUID, actual)},
                "Retained executable UUID differs from the original fault")
    engine_uuid = command(["xcrun", "dwarfdump", "--uuid", str(root / "libNexGenEngine.dylib")])
    require([value.lower() for value in re.findall(UUID, engine_uuid)] == [binding["originalProductImages"]["libNexGenEngine.dylib"]],
            "Retained Engine UUID differs from the original fault")
    write(folder / "restore.json", {"status": "verified", "binRoot": str(root),
          "productSHA": binding["productSHA"], "harnessSHA": binding["harnessSHA"],
          "entryCount": len(records), "engineUUIDOutput": engine_uuid, "manifestSHA256": checksum(folder / "restored-manifest.json"),
          "outerSHA256": checksum(outer), "innerSHA256": checksum(inner)})


def loader_records(console, pid, shared):
    loaded, others = [], []
    pattern = re.compile(r"^dyld\[([1-9][0-9]*)\]: <(" + UUID + r")> (.+)$")
    movement = re.compile(r"^dyld\[([1-9][0-9]*)\]: move (?:loaded to delayed|delayed to loaded): [^\r\n]+$")
    cutoff = None
    for number, raw in enumerate(console.splitlines(keepends=True), 1):
        line = raw.removesuffix("\n")
        match = pattern.fullmatch(line)
        if shared and (not raw.endswith("\n") or line.count("dyld[") != 1
                       or "\r" in line or not (match or movement.fullmatch(line))):
            cutoff = {"line": number, "reason": "Ambiguous or incomplete loader framing; later records are not credited"}
            break
        if match:
            if int(match[1]) != pid:
                require(shared, "Loader record belongs to another PID")
                others.append({"pid": int(match[1]), "uuid": match[2].lower(), "path": match[3]})
            else:
                loaded.append({"uuid": match[2].lower(), "path": match[3]})
    return loaded, others, cutoff


def verify_replay(folder, evidence):
    binding = json.loads((folder / "binding.json").read_text())
    profile, selection = replay_selection(binding["kind"])
    require(binding["selection"] == selection and binding["diagnosticProfile"] == profile, "Replay mode binding differs")
    root = Path(binding["compiled"]["binRoot"])
    require(command(["git", "rev-parse", "HEAD"]) == binding["productSHA"]
            and os.environ["GITHUB_SHA"] == binding["harnessSHA"], "Replay source binding changed")
    verify_tree(root, json.loads((folder / "restored-manifest.json").read_text()))
    suite = json.loads((evidence / "hosted-suite/suite.json").read_text())
    wrapper = json.loads((evidence / "run.json").read_text())
    require(wrapper.get("testExitCode") == wrapper.get("effectiveExitCode") == 0
            and wrapper.get("sourceSHA") == binding["harnessSHA"] and wrapper.get("runID") == os.environ["GITHUB_RUN_ID"],
            "Replay wrapper identity or exit differs")
    require(suite.get("sourceSHA") == suite.get("harnessSourceSHA") == binding["harnessSHA"]
            and suite.get("productSourceSHA") == binding["productSHA"] and suite.get("completed") is True
            and suite.get("scope") == "app-swift-testing" and suite.get("filter") == selection
            and suite.get("binPath") == str(root) and len(suite.get("phases", [])) == 1,
            "Replay selection or source identity differs")
    phase = suite["phases"][0]
    diagnostic, receipt = phase.get("diagnostic", {}), phase.get("originalHostReceipt", {})
    host = binding["compiled"]["binaries"]["NexGenVideoAppKitTestHost"]
    expected_environment = {"DYLD_PRINT_LIBRARIES": "1", "otherDiagnosticVariablesPresent": False}
    loader_log = evidence / "hosted-suite/app-swift-testing/console.log"
    if not selection:
        loader_log = evidence / "hosted-suite/app-swift-testing/dyld-images.log"
        expected_environment["DYLD_PRINT_TO_FILE"] = str(loader_log.resolve())
        preflight_folder = evidence / "hosted-suite/child-stdio-probe"
        preflight = json.loads((preflight_folder / "receipt.json").read_text())
        require(preflight == suite.get("childStdioPreflight") and preflight.get("status") == "passed"
                and preflight.get("exitCode") == 0 and preflight.get("timedOut") is False
                and preflight.get("stdoutBytes") == preflight.get("stderrBytes") == 0
                and type(preflight.get("pid")) is int and preflight["pid"] > 0 and preflight["pid"] != phase.get("pid")
                and all((preflight_folder / name).is_file() and not (preflight_folder / name).is_symlink()
                        and (preflight_folder / name).stat().st_size == 0 for name in ("stdout.log", "stderr.log")),
                "Native child stdio preflight is unproven")
    require(phase.get("exitCode") == 0 and phase.get("status") == "verified-execution"
            and phase.get("diagnostic", {}).get("status") == "verified"
            and phase["diagnostic"].get("profile") == profile
            and phase["diagnostic"].get("environment") == expected_environment
            and type(phase.get("pid")) is int and phase["pid"] > 0
            and phase["pid"] == diagnostic.get("pid") == receipt.get("pid")
            and diagnostic.get("sourceSHA") == diagnostic.get("harnessSourceSHA") == receipt.get("sourceSHA") == binding["harnessSHA"]
            and diagnostic.get("productSourceSHA") == binding["productSHA"]
            and diagnostic.get("hostSHA256") == host["sha256"]
            and diagnostic.get("hostUUID", "").lower() in {value.lower() for value in re.findall(UUID, host["uuidOutput"])}
            and diagnostic.get("memoryErrors") == [] and diagnostic.get("sampleCount", 0) >= 2
            and receipt.get("abiSucceeded") is True and receipt.get("completed") is True
            and receipt.get("hostExecutable") == str(root / "NexGenVideoAppKitTestHost")
            and receipt.get("bundleBinary") == str(root / "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"),
            "Replay owned execution or actual diagnostic profile is unproven")
    expected_methods = {"neutralIsNoOp", "bleedsLightIntoNeighbors", "warmthTintsTheBleedRed"}
    ended = phase["events"]["endedFunctionIDs"]
    expected = binding["expectedFunctionIDs"]
    require(expected and len(expected) == len(set(expected)) and sorted(ended) == expected
            and suite.get("testExecutions") == phase["events"].get("functionExecutions") == len(expected)
            and sorted(phase["events"].get("skippedFunctionIDs", [])) == binding["expectedSkippedFunctionIDs"],
            "Replay did not complete the exact original selected function inventory")
    glow = [name for name in ended if name.startswith("NexGenVideoTests.GlowKernelTests/")]
    require(len(glow) == 3 and {name.split("/", 2)[1].removesuffix("()") for name in glow} == expected_methods,
            "Replay did not complete exactly three Glow functions")
    events_path = evidence / "hosted-suite/app-swift-testing/events.jsonl"
    events = [json.loads(line) for line in events_path.read_text().split("\n") if line.strip()]
    intervals = {}
    for record in events:
        event = record.get("payload", {})
        if record.get("kind") == "event" and event.get("testID") in glow and event.get("kind") in ("testStarted", "testEnded"):
            intervals.setdefault(event["testID"], {})[event["kind"]] = event["instant"]["since1970"]
    require(set(intervals) == set(glow) and all(set(value) == {"testStarted", "testEnded"}
            and value["testStarted"] < value["testEnded"] for value in intervals.values()), "Incomplete Glow exposure intervals")
    overlap = [(a, b) for a, first in intervals.items() for b, second in intervals.items() if a < b
               and min(first["testEnded"], second["testEnded"]) > max(first["testStarted"], second["testStarted"])]
    require(overlap, "Retained App replay did not prove concurrent Glow exposure")
    if not selection:
        fault_pair = {name for name in glow if any(method + "()" in name for method in
                      ("bleedsLightIntoNeighbors", "warmthTintsTheBleedRed"))}
        require(any(set(pair) == fault_pair for pair in overlap), "Full App replay did not overlap the original fault pair")
    require(loader_log.is_file() and not loader_log.is_symlink(), "Owned loader log is missing or linked")
    with loader_log.open(newline="") as stream:
        console = stream.read()
    loaded, other_process_images, cutoff = loader_records(console, phase["pid"], shared=not selection)
    system_loaded = loaded
    if not selection:
        write(evidence / "loader-framing.json", {"trustedPrefixOnly": True, "cutoff": cutoff,
              "hostImageCount": len(loaded), "otherProcessImageCount": len(other_process_images)})
        write(evidence / "other-process-loaded-images.json", other_process_images)
        capture = diagnostic.get("loadedImageCapture", {})
        sample_path = loader_log.with_name("owned-images.sample.txt")
        require(capture.get("status") == "verified" and capture.get("exitCode") == 0
                and capture.get("pid") == phase["pid"] and capture.get("parentPID") == diagnostic.get("parentPID")
                and type(capture.get("startAbsoluteTime")) is int and capture["startAbsoluteTime"] > 0
                and capture["startAbsoluteTime"] == diagnostic.get("startAbsoluteTime")
                and capture.get("startedAt", 0) >= max(value["testEnded"] for value in intervals.values())
                and capture.get("finishedAt", 0) >= capture["startedAt"]
                and sample_path.is_file() and not sample_path.is_symlink()
                and checksum(sample_path) == capture.get("sampleSHA256"), "Owned native image sample is unproven")
        system_loaded = sample_image_records(sample_path.read_text(), phase["pid"], diagnostic["parentPID"])
        require(system_loaded == capture.get("images"), "Native image sample records differ")
        write(evidence / "sample-loaded-images.json", system_loaded)
    for name, image in binding["systemImages"].items():
        require(image in system_loaded, "Actual loaded system image differs: " + name)
    for relative, original in binding["compiled"]["binaries"].items():
        uuids = {value.lower() for value in re.findall(UUID, original["uuidOutput"])}
        require(any(image["path"] == str(root / relative) and image["uuid"] in uuids for image in loaded),
                "Actual loaded retained executable differs")
    for name, relative in (("NexGenVideoAppKitTestHost", "NexGenVideoAppKitTestHost"),
                           ("NexGenVideoTests", "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"),
                           ("libNexGenEngine.dylib", "libNexGenEngine.dylib")):
        require({"path": str(root / relative), "uuid": binding["originalProductImages"][name]} in loaded,
                "Loaded product image differs from the original fault")
    require(not any(image["path"] == str(root / "NexGenVideo") for image in loaded), "App executable also loaded into the test host")
    write(evidence / "loaded-images.json", loaded)
    write(evidence / "interpretation.json", {"status": "single-focused-exposure-completed" if selection else "single-full-app-exposure-completed", "launches": 1,
          "selection": selection, "testExecutions": len(expected),
          "overlappingFunctionPairs": overlap, "productSHA": binding["productSHA"], "harnessSHA": binding["harnessSHA"],
          "rootCause": "not-established", "failureRateInference": False, "coreAcceptance": False,
          "nativeUXAcceptance": False, "releaseAcceptance": False})


def source(folder):
    kind = os.environ["REPLAY_KIND"]
    profile, selection = replay_selection(kind)
    names = ("PRODUCER_RUN", "PRODUCER_SHA", "PRODUCT_SHA", "DIAGNOSTIC_ID", "DIAGNOSTIC_DIGEST",
             "PRODUCTS_ID", "PRODUCTS_DIGEST", "FAILURE_ID", "FAILURE_DIGEST")
    inputs = {key: os.environ[key] for key in names}
    for key, value in inputs.items():
        expression = r"[1-9][0-9]*" if key.endswith(("_RUN", "_ID")) else r"[a-f0-9]{40}" if key.endswith("_SHA") else r"[a-f0-9]{64}"
        require(re.fullmatch(expression, value), "Invalid replay input")
    folder.mkdir(parents=True, exist_ok=False)
    head = command(["git", "rev-parse", "HEAD"])
    require(head == os.environ["GITHUB_SHA"], "Replay checkout is not its workflow source")
    producer_sha, product_sha = inputs["PRODUCER_SHA"], inputs["PRODUCT_SHA"]
    for ancestor, descendant in ((product_sha, producer_sha), (producer_sha, head)):
        subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, descendant],
                       stdin=subprocess.DEVNULL, check=True, timeout=15)
    changed = command(["git", "diff", "--name-only", producer_sha, head]).splitlines()
    require(set(changed) <= REPLAY_PATHS, "Replay changes product or unrelated source")
    original_changed = command(["git", "diff", "--name-only", product_sha, producer_sha]).splitlines()
    require(set(original_changed) <= APP_DIAGNOSTIC_PATHS, "Original diagnostic changed product source")
    run = api("actions/runs/" + inputs["PRODUCER_RUN"])
    require(run["id"] == int(inputs["PRODUCER_RUN"]), "Producer run differs")
    jobs = api(f"actions/runs/{run['id']}/attempts/1/jobs?per_page=100")
    job = verify_producer(run, jobs, producer_sha)
    artifacts = {}
    for key, name in (("DIAGNOSTIC", f"app-zombie-diagnostic-{run['id']}-a1"),
                      ("PRODUCTS", f"app-test-products-{run['id']}-a1")):
        artifact = api("actions/artifacts/" + inputs[key + "_ID"])
        verify_artifact(artifact, run, job, int(inputs[key + "_ID"]), inputs[key + "_DIGEST"], name)
        artifacts[key] = artifact
        write(folder / (key.lower() + "-artifact.json"), artifact)
    archive_path = folder / "original-diagnostic.zip"
    download(artifacts["DIAGNOSTIC"], archive_path)
    with zipfile.ZipFile(archive_path) as archive:
        compiled = archive_json(archive, "candidate-metadata/compiled-products.json")
        execution = archive_json(archive, "candidate-metadata/diagnostic-execution.json")
        suite = archive_json(archive, "app-zombie-diagnostic/hosted-suite/suite.json")
        wrapper = archive_json(archive, "app-zombie-diagnostic/run.json")
        verify_execution(compiled, execution, suite, wrapper, product_sha, producer_sha, run["id"])
        expected_functions = original_function_inventory(suite, selection)
        expected_skipped = sorted(suite["phases"][0]["events"]["skippedFunctionIDs"]) if not selection else []
        inner_digest = archive_bytes(archive, "candidate-metadata/compiled-products.sha256").decode().split()[0]
        require(re.fullmatch(r"[a-f0-9]{64}", inner_digest), "Invalid original product archive digest")
    require(execution.get("originalArtifactID") == inputs["FAILURE_ID"]
            and execution.get("originalArtifactSHA256") == inputs["FAILURE_DIGEST"], "Original failure anchor differs")
    failure_artifact = api("actions/artifacts/" + inputs["FAILURE_ID"])
    failure_run_id = failure_artifact["workflow_run"]["id"]
    require(execution.get("originalRunID") == str(failure_run_id), "Original failed run differs")
    failed_run = api(f"actions/runs/{failure_run_id}")
    failed_jobs = api(f"actions/runs/{failure_run_id}/attempts/{failed_run['run_attempt']}/jobs?per_page=100")
    verify_app_diagnostic(failed_run, failed_jobs, failure_artifact, failure_run_id, product_sha,
                          int(inputs["FAILURE_ID"]), inputs["FAILURE_DIGEST"], original_changed)
    failed_zip = folder / "original-failure.zip"
    download(failure_artifact, failed_zip)
    verify_app_crash_archive(failed_zip, failure_run_id, product_sha, inputs["FAILURE_DIGEST"])
    with zipfile.ZipFile(failed_zip) as archive:
        receipt = archive_json(archive, "hosted-suite/app-swift-testing/post-mortem/receipt.json")
        require(len(receipt["reports"]) == 1, "Original crash report is ambiguous")
        report = receipt["reports"][0]
        require(Path(report["file"]).name == report["file"], "Original report path escapes its directory")
        raw = archive_bytes(archive, "hosted-suite/app-swift-testing/post-mortem/" + report["file"])
        require(hashlib.sha256(raw).hexdigest() == report["sha256"], "Original crash report bytes differ")
        text = raw.decode()
        _, offset = json.JSONDecoder().raw_decode(text)
        crash = json.loads(text[offset:].lstrip())
        require(crash.get("pid") == receipt["ownedChild"]["pid"]
                and crash.get("parentPid") == receipt["ownedChild"]["parentPID"], "Original crash PID differs")
        images = {image["name"]: {"path": image["path"], "uuid": image["uuid"].lower()}
                  for image in crash["usedImages"] if image.get("name") in SYSTEM_IMAGES}
        require(set(images) == SYSTEM_IMAGES
                and sum(image.get("name") in SYSTEM_IMAGES for image in crash["usedImages"]) == len(SYSTEM_IMAGES),
                "Original system-image inventory is incomplete or ambiguous")
        product_images = {image["name"]: image["uuid"].lower() for image in crash["usedImages"]
                          if image.get("name") in {"NexGenVideoAppKitTestHost", "NexGenVideoTests", "libNexGenEngine.dylib"}}
        require(len(product_images) == 3
                and sum(image.get("name") in product_images for image in crash["usedImages"]) == 3,
                "Original product image inventory is incomplete or ambiguous")
    record = {"schema": 1, "inputs": inputs, "producerRunID": run["id"], "producerAttempt": 1,
              "producerJobID": job["id"], "producerSHA": producer_sha, "productSHA": product_sha,
              "harnessSHA": head, "changedPaths": changed, "compiled": compiled,
              "innerArchiveSHA256": inner_digest, "systemImages": images, "originalProductImages": product_images,
              "osBuild": crash["osVersion"]["build"], "originalFailureRunID": failure_run_id,
              "launchLimit": 1, "kind": kind, "diagnosticProfile": profile, "selection": selection,
              "expectedFunctionIDs": expected_functions, "expectedSkippedFunctionIDs": expected_skipped,
              "qualification": "diagnostic-only"}
    write(folder / "binding.json", record)
    write(folder / "producer-run.json", run)
    write(folder / "producer-jobs.json", jobs)
    write(folder / "failure-artifact.json", failure_artifact)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("mode", choices=("source", "restore", "verify"))
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.mode == "source":
        source(args.metadata)
    elif args.mode == "restore":
        restore(args.metadata)
    else:
        require(args.evidence is not None, "Replay evidence is required")
        verify_replay(args.metadata, args.evidence)


if __name__ == "__main__":
    main()
