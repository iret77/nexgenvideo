"""Run the original standalone executable on the product floor without rebuilding it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import time
import uuid
import zipfile

from ci_builtin_blur import (PATHS, api, bind_normal_arm, command, digest, environment,
    owned_process, run_measured, sample_proof, save)


SOURCE = "b1b82071e3418025dbf4336cfaeb494e95d8b87b"
ARCHIVE = "70e8ee68783d976dfc490aa220435d7c3ee6fb36d5f0a0c88b84c7545cf50371"
BINARY = "48fedf2e1c87690ed6570b7c127a0c303fb3a09884c0615e9d3e2c89be9e3ea8"
UUID = "eca195c6-44b0-4751-ad17-facb4e8f32bf"
FLOOR_PATHS = PATHS | {"scripts/ci_builtin_blur_floor.py", "scripts/test_ci_builtin_blur_floor.py"}
HELPERS = {"scripts/run_macos_tests.py", "scripts/app_host_zombie_diagnostic.py",
           "scripts/verify_diagnostic_candidate.py", "scripts/verify_swift_test_output.py"}
IMAGES = {
    "AppleParavirtGPUMetalIOGPUFamily": "aae20d61-da81-3422-9b0a-baa2e16c93a4",
    "IOGPU": "9235e8ec-599d-386f-8a8a-6b6a92d33369",
    "CoreImage": "0943679d-ff88-3f18-be4b-d8b4827ab0b5",
    "MPSCore": "dbb5f038-e085-39c8-a9bf-c3b3cb3f6fd5",
    "MPSImage": "a0be8307-7ecf-3ab8-b382-3e4059c85778",
    "Metal": "493e76d9-74d4-333b-a3b2-e5f9bc86429d",
}
FLOOR_ARCHIVE = "9ae980313ee2991c97e6b1ff8d13dde97eb9bd8c5218b07e2cafb39e9716f733"
FLOOR_SAMPLE = "10672ed7c91718f5eebe3b4e31450a3c9890371cc9885601dead7e5904fd7c62"
DRIVER = Path("/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle/Contents")


def member(archive, name, limit=4 * 1024 * 1024):
    found = [item for item in archive.infolist() if item.filename == name]
    if len(found) != 1 or not 0 < found[0].file_size <= limit:
        raise ValueError("Missing, duplicate or oversized original archive member")
    return archive.read(found[0])


def binary_proof(raw):
    if len(raw) < 32:
        raise ValueError("Truncated executable header")
    magic, cpu, subtype, kind, count, size, flags, reserved = struct.unpack_from("<8I", raw)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x0100000C, 2) or not 0 < size <= len(raw) - 32:
        raise ValueError("Not a thin arm64 Mach-O executable")
    offset, end, builds, identities, imports = 32, 32 + size, [], [], []
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated load command")
        cmd, length = struct.unpack_from("<II", raw, offset)
        if length < 8 or length % 8 or offset + length > end:
            raise ValueError("Invalid load command extent")
        if cmd == 0x32:
            if length < 24:
                raise ValueError("Truncated build version")
            builds.append(struct.unpack_from("<II", raw, offset + 8))
        elif cmd == 0x1B:
            if length != 24:
                raise ValueError("Invalid UUID command")
            identities.append(str(uuid.UUID(bytes=raw[offset + 8:offset + 24])))
        elif cmd in {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023}:
            if length < 24:
                raise ValueError("Truncated dylib command")
            start = struct.unpack_from("<I", raw, offset + 8)[0]
            value = raw[offset + start:offset + length]
            if not 24 <= start < length or b"\0" not in value:
                raise ValueError("Invalid dylib name")
            name = value.split(b"\0", 1)[0].decode()
            if not name.startswith(("/usr/lib/", "/System/Library/")) or ".." in Path(name).parts:
                raise ValueError("Executable loads a non-system library")
            imports.append(name)
        elif cmd in {0xD, 0x8000001C}:
            raise ValueError("Unexpected library identity or rpath")
        offset += length
    if offset != end or builds != [(1, 26 << 16)] or identities != [UUID] or not imports:
        raise ValueError("Executable floor, UUID or command count differs")
    return {"uuid": identities[0], "platform": "macOS", "minOS": "26.0", "arch": "arm64", "imports": imports}


def bind_floor_reference(folder):
    artifact = api("actions/artifacts/12556008735")
    run = api("actions/runs/40080033255")
    job = api("actions/jobs/120841910512")
    source = "9e93972b72f0a05b5b9a31bae10feb111a23a6b1"
    if (artifact.get("id") != 12556008735 or artifact.get("digest") != "sha256:" + FLOOR_ARCHIVE
            or artifact.get("expired") is not False or artifact.get("name") != "diagnostic-normal-startup"
            or artifact.get("workflow_run", {}).get("id") != 40080033255
            or artifact["workflow_run"].get("head_sha") != source
            or run.get("id") != 40080033255 or run.get("run_attempt") != 1
            or run.get("head_sha") != source or run.get("status") != "completed"
            or run.get("repository", {}).get("full_name") != "iret77/nexgenvideo"
            or run.get("path") != ".github/workflows/ci-batch.yml"
            or job.get("id") != 120841910512 or job.get("run_id") != 40080033255
            or job.get("run_attempt") != 1 or job.get("head_sha") != source
            or job.get("status") != "completed" or job.get("conclusion") != "success"
            or job.get("name") != "Compile, unit tests, app and native bpy acceptance / diagnostic-startup"
            or not job["started_at"] <= artifact["created_at"] <= artifact["updated_at"] <= job["completed_at"]):
        raise ValueError("Historical floor image evidence is not bound to its original producer")
    path = folder / "floor-reference.zip"
    with path.open("xb") as stream:
        subprocess.run(["gh", "api", "repos/iret77/nexgenvideo/actions/artifacts/12556008735/zip"],
                       stdin=subprocess.DEVNULL, stdout=stream, check=True, timeout=120)
    if digest(path) != FLOOR_ARCHIVE or path.stat().st_size != artifact["size_in_bytes"]:
        raise ValueError("Historical floor evidence bytes differ")
    with zipfile.ZipFile(path) as archive:
        sample = member(archive, "termination/raw-control/sample.log")
    if hashlib.sha256(sample).hexdigest() != FLOOR_SAMPLE:
        raise ValueError("Historical sample differs")
    text = sample.decode()
    if "OS Version:      macOS 26.6.2 (25G83)" not in text:
        raise ValueError("Historical floor OS differs")
    for name, image_uuid in IMAGES.items():
        if not re.search(r"^.*<" + image_uuid + r">.*\/" + re.escape(name) + r"$", text, re.I | re.M):
            raise ValueError("Historical floor image UUID differs")
    driver_line = re.search(r"^.*com\.apple\.driver\.AppleParavirtGPUMetalIOGPUFamily "
        r"\(64\.4\.7 - 64\.4\.7\) <" + IMAGES["AppleParavirtGPUMetalIOGPUFamily"]
        + r"> /System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily\.bundle/Contents/MacOS/AppleParavirtGPUMetalIOGPUFamily$",
        text, re.I | re.M)
    if not driver_line:
        raise ValueError("Historical driver version is not bound to the original image")
    save(folder / "floor-reference.json", {"run": run, "job": job, "artifact": artifact,
        "sampleSHA256": FLOOR_SAMPLE, "build": "25G83", "images": IMAGES,
        "driverVersion": "64.4.7", "driverImageLine": driver_line.group(0)})


def bind(folder):
    folder.mkdir()
    if (os.environ["REPLAY_KIND"] != "ci-builtin-blur-floor"
            or os.environ["CANDIDATE_RUN"] != "40093865040"
            or os.environ["CANDIDATE_SOURCE"] != SOURCE
            or os.environ["CANDIDATE_ARTIFACT"] != "12559669733"
            or os.environ["CANDIDATE_DIGEST"] != ARCHIVE
            or any(os.environ.get(key) for key in ("PRODUCT_SHA", "PRODUCTS_ID", "PRODUCTS_DIGEST", "FAILURE_ID", "FAILURE_DIGEST"))):
        raise ValueError("Floor experiment requires the exact original normal producer")
    head = command(["git", "rev-parse", "HEAD"]).strip()
    if head != os.environ["GITHUB_SHA"] or command(["git", "status", "--porcelain"]).strip():
        raise ValueError("Dirty or unbound source checkout")
    original_source = command(["git", "show", SOURCE + ":scripts/ci_builtin_blur.swift"])
    if "guard CommandLine.arguments.count == 3 else { exit(2) }" not in original_source or "CommandLine.arguments[3]" in original_source:
        raise ValueError("Original executable argument contract differs")
    proof = bind_normal_arm(folder, head, identity=(SOURCE, ARCHIVE, 12559669733), allowed_paths=FLOOR_PATHS)
    if proof["binarySHA256"] != BINARY:
        raise ValueError("Original executable differs")
    with zipfile.ZipFile(folder / "normal-arm.zip") as archive:
        executable = member(archive, "NGVBuiltinBlur")
    image = binary_proof(executable)
    bind_floor_reference(folder)
    save(folder / "binding.json", {"harnessSHA": head, "normalArm": proof, "binary": image,
        "harnessHashes": {name: digest(Path(name)) for name in sorted(FLOOR_PATHS | HELPERS)},
        "build": "25G83", "driverVersion": "64.4.7", "images": IMAGES,
        "diagnosticOnly": True, "productAcceptance": False, "recompile": False})


def probe(folder, name, args):
    try:
        result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, timeout=40)
    except subprocess.TimeoutExpired as error:
        (folder / (name + ".stdout")).write_bytes(error.stdout or b"")
        (folder / (name + ".stderr")).write_bytes(error.stderr or b"")
        raise
    (folder / (name + ".stdout")).write_bytes(result.stdout)
    (folder / (name + ".stderr")).write_bytes(result.stderr)
    if result.returncode != 0:
        raise ValueError(f"Platform probe {name} exited {result.returncode}")
    return result.stdout.decode()


def platform(folder):
    values = {"errors": {},
        "imageOS": os.environ.get("ImageOS"), "imageVersion": os.environ.get("ImageVersion"),
        "imageUUIDVerification": "Calibration sample before measured execution"}
    probes = {"os": ["sw_vers"], "build": ["sw_vers", "-buildVersion"], "arch": ["uname", "-m"],
        "model": ["sysctl", "-n", "hw.model"], "displays": ["system_profiler", "SPDisplaysDataType", "-json"]}
    for name, args in probes.items():
        try:
            output = probe(folder, name, args).strip()
            values[name] = ([{key: value for key, value in card.items()
                             if key in {"_name", "sppci_model", "spdisplays_vendor"}}
                            for card in json.loads(output).get("SPDisplaysDataType", [])]
                            if name == "displays" else output)
        except Exception as error:
            values["errors"][name] = str(error)
    try:
        raw_info = (DRIVER / "Info.plist").read_bytes()
        (folder / "driver-Info.plist").write_bytes(raw_info)
        values["driverVersion"] = plistlib.loads(raw_info).get("CFBundleVersion")
    except Exception as error:
        values["errors"]["driverVersion"] = str(error)
    save(folder / "platform.json", values)
    if (values["errors"] or values.get("build") != "25G83" or values.get("arch") != "arm64"
            or values.get("driverVersion") != "64.4.7"):
        raise ValueError("Current floor image differs from the predeclared OS/driver identity")


def execute(folder, metadata, result):
    start = time.monotonic()
    deadline = start + 1200
    folder.mkdir()
    binding = json.loads((metadata / "binding.json").read_text())
    if (os.environ["REPLAY_KIND"] != "ci-builtin-blur-floor"
            or binding["harnessSHA"] != os.environ["GITHUB_SHA"]
            or command(["git", "rev-parse", "HEAD"]).strip() != binding["harnessSHA"]
            or set(binding["harnessHashes"]) != FLOOR_PATHS | HELPERS
            or binding["build"] != "25G83" or binding["images"] != IMAGES
            or binding["normalArm"]["artifactSHA256"] != ARCHIVE
            or binding["normalArm"]["binarySHA256"] != BINARY):
        raise ValueError("Floor source binding differs")
    for name, checksum in binding["harnessHashes"].items():
        if digest(Path(name)) != checksum:
            raise ValueError("Reviewed source bytes changed")
    environment(os.environ)
    if any(key.startswith(("CI_", "METAL_", "_Malloc", "MALLOC_")) for key in os.environ):
        raise ValueError("Ambient rendering or allocator overrides are not allowed")
    platform(folder)
    archive = metadata / "normal-arm.zip"
    if digest(archive) != ARCHIVE:
        raise ValueError("Transferred original archive differs")
    with zipfile.ZipFile(archive) as original:
        raw = member(original, "NGVBuiltinBlur")
    if hashlib.sha256(raw).hexdigest() != BINARY or binary_proof(raw) != binding["binary"]:
        raise ValueError("Transferred original executable differs")
    binary = folder / "NGVBuiltinBlur"
    binary.write_bytes(raw)
    binary.chmod(0o755)
    save(folder / "binary.json", {"sha256": BINARY, **binding["binary"], "rebuilt": False})
    probe(folder, "codesign", ["codesign", "--verify", "--strict", str(binary)])
    outcome, context = owned_process(binary, folder / "calibration", "calibration", deadline, original_arguments=True)
    result["calibrationOutcome"] = outcome
    result["calibrationEvidence"] = "calibration"
    if outcome != "clean":
        result.update(outcome="FV", reason="Calibration did not complete; original failure retained")
        return 1
    if context.get("sampleExitCode") != 0 or context.get("sampleTimedOut"):
        raise ValueError("Calibration sample incomplete")
    sample = (folder / "calibration/sample.txt").read_text()
    if not re.search(r"^OS Version:\s+macOS 26\.6\.2 \(25G83\)$", sample, re.M):
        raise ValueError("Calibration sample OS differs")
    sample_proof(sample, context["pid"], os.getpid(), images=IMAGES)
    run_measured(binary, folder, deadline, result, original_arguments=True)
    result["underlyingOutcome"] = result["outcome"]
    result["outcome"] = {"N": "FN", "C": "FC", "V": "FV"}.get(result["outcome"], "FV")
    result["elapsedSeconds"] = time.monotonic() - start
    return 0 if result["outcome"] == "FN" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("bind", "run"))
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--metadata", type=Path)
    args = parser.parse_args()
    result = {"outcome": "FV", "diagnosticOnly": True, "productAcceptance": False,
              "scope": "Virtualized macOS 26 comparison; FN is bounded absence, FC is a measured owned crash; neither proves cause identity or a fix",
              "processesCompleted": 0, "roundsCompleted": 0, "overlappingRounds": 0}
    try:
        if args.mode == "bind":
            bind(args.evidence.resolve())
        else:
            raise SystemExit(execute(args.evidence.resolve(), args.metadata.resolve(), result))
    except Exception as error:
        args.evidence.mkdir(exist_ok=True, parents=True)
        result.update(outcome="FV", error=str(error))
        save(args.evidence / "failure.json", result)
        raise
    finally:
        if args.mode == "run":
            args.evidence.mkdir(exist_ok=True, parents=True)
            save(args.evidence / "result.json", result)
