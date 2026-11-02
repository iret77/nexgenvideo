import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import zipfile
import tempfile
import platform

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact, write
from release_checkpoint import NATIVE_TIMEOUT, identity, tree_digest, validate_app_zip, verify_manifest
from verify_dmg_copy import detach, verify


SOURCE = "abd136f44ea643ac6e001b63b5833aa217aff0e5"
RUN = 41477792134
ARTIFACT = 13159028671
DIGEST = "d486805bcce8f44a38cfdf824f84644ffedbea7b8ab8ddf4caaf4c350300c8d6"
PATHS = {"scripts/dmg-settings.py", "scripts/bundle.sh", "scripts/verify_dmg_copy.py",
         "scripts/release_dmg_probe.py", "scripts/test_release_dmg_packaging.py",
         ".github/workflows/signing-preflight.yml", "scripts/release_native_proof.py",
         "scripts/release_checkpoint.py"}


def validate(producer, jobs, artifact):
    require(producer.get("id") == RUN and producer.get("head_sha") == SOURCE
            and producer.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and producer.get("actor", {}).get("login") == "iret77"
            and producer.get("path") == ".github/workflows/release.yml"
            and producer.get("event") == "workflow_dispatch" and producer.get("run_attempt") == 1
            and producer.get("status") == "completed" and producer.get("conclusion") == "failure",
            "Original signed producer differs")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete original job inventory")
    selected = [job for job in jobs["jobs"] if job.get("name") == "release-build"]
    require(len(selected) == 1 and selected[0].get("head_sha") == SOURCE
            and selected[0].get("run_id") == RUN and selected[0].get("run_attempt") == 1
            and selected[0].get("status") == "completed"
            and selected[0].get("labels") == ["macrunner"] and selected[0].get("conclusion") == "success",
            "Original signed build did not pass")
    for name in ("Build and sign app", "Retain signed build input", "Retain signed build proof"):
        steps = [step for step in selected[0].get("steps", []) if step.get("name") == name]
        require(len(steps) == 1 and steps[0].get("conclusion") == "success", "Original build stage differs")
    verify_artifact(artifact, producer, selected[0], ARTIFACT, DIGEST, "release-signed-input-" + SOURCE)
    return selected[0]


def bind(root, mode="copy"):
    require(os.environ["GITHUB_REPOSITORY"] == "iret77/nexgenvideo", "Foreign probe repository")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], stdin=subprocess.DEVNULL, text=True, timeout=30).strip()
    require(head == os.environ["GITHUB_SHA"], "Probe checkout differs")
    subprocess.run(["git", "merge-base", "--is-ancestor", SOURCE, head],
                   stdin=subprocess.DEVNULL, check=True, timeout=30)
    require(not subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"],
            stdin=subprocess.DEVNULL, text=True, timeout=30).strip(), "Probe tracked source is dirty")
    changed = subprocess.check_output(["git", "diff", "--name-only", "--no-renames", SOURCE, "HEAD"],
        stdin=subprocess.DEVNULL, text=True, timeout=30).splitlines()
    require(set(changed) <= PATHS, "Probe changed native product inputs")
    producer = api(f"actions/runs/{RUN}")
    jobs = api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100")
    artifact = api(f"actions/artifacts/{ARTIFACT}")
    job = validate(producer, jobs, artifact)
    root.mkdir(parents=True, exist_ok=False)
    write(root / "binding.json", {"schema": "release-dmg-probe-binding/v1", "productSourceSHA": SOURCE,
          "harnessSourceSHA": os.environ["GITHUB_SHA"], "mode": mode,
          "producer": producer, "job": job, "artifact": artifact})


def capacity(app, root):
    entries = [app, *app.rglob("*")]
    regular = [p for p in entries if p.is_file() and not p.is_symlink()]
    estimated = 128 * 1024**2 + 4096
    for directory, _, names in os.walk(app):
        estimated += sum(((Path(directory) / name).lstat().st_size + 4095) // 4096 * 4096 for name in names)
    def space(path):
        value = os.statvfs(path)
        return {"blockBytes": value.f_frsize, "totalBytes": value.f_blocks * value.f_frsize,
                "freeBytes": value.f_bavail * value.f_frsize}
    report = {"schema": "release-dmg-capacity/v1", "qualified": False, "releaseAccepted": False,
              "appState": "verified-original-unstapled",
              "productSourceSHA": SOURCE, "harnessSourceSHA": os.environ["GITHUB_SHA"],
              "restoredAppTreeSHA256": tree_digest(app), "macOS": platform.mac_ver()[0],
              "machine": platform.machine(), "fileCount": len(regular), "entryCount": len(entries),
              "logicalBytes": sum(p.lstat().st_size for p in regular),
              "allocatedBytes": sum(p.lstat().st_blocks * 512 for p in entries),
              "largestFiles": [{"path": p.relative_to(app).as_posix(), "bytes": p.lstat().st_size,
                                "allocatedBytes": p.lstat().st_blocks * 512}
                               for p in sorted(regular, key=lambda p: p.lstat().st_size, reverse=True)[:10]],
              "defaultDmgbuildEstimateBytes": estimated, "hostBeforeCreate": space(root)}
    output = root / "report"
    output.mkdir()
    write(output / "capacity.json", report)
    image = root / "capacity.dmg"
    subprocess.run(["hdiutil", "create", "-ov", "-volname", "NexGenVideo-capacity", "-fs", "APFS",
                    "-fsargs", "", "-size", str(estimated / 1000) + "K", str(image)],
                   stdin=subprocess.DEVNULL, check=True, timeout=NATIVE_TIMEOUT)
    report["hostAfterCreate"] = space(root)
    report["imageLogicalBytes"] = image.stat().st_size
    report["imageAllocatedBytes"] = image.stat().st_blocks * 512
    write(output / "capacity.json", report)
    with tempfile.TemporaryDirectory() as mount:
        subprocess.run(["hdiutil", "attach", str(image), "-nobrowse", "-owners", "off", "-mountpoint", mount],
                       stdin=subprocess.DEVNULL, check=True, timeout=NATIVE_TIMEOUT)
        try:
            report["emptyImage"] = space(mount)
            report["copyPerformed"] = False
            write(output / "capacity.json", report)
        finally:
            detach(mount)
    write(output / "capacity.json", report)
    print(json.dumps(report, sort_keys=True), flush=True)


def inspect(root, mode="copy"):
    started = time.monotonic()
    durations = {}
    def timed(stage, operation):
        start = time.monotonic()
        try:
            return operation()
        finally:
            durations[stage] = time.monotonic() - start
            print(json.dumps({"stage": stage, "seconds": durations[stage]}), flush=True)
    def run(*args, **kwargs):
        subprocess.run(args, stdin=subprocess.DEVNULL, check=True, timeout=NATIVE_TIMEOUT, **kwargs)
    binding = json.loads((root / "binding.json").read_text())
    require(binding.get("schema") == "release-dmg-probe-binding/v1"
            and binding.get("productSourceSHA") == SOURCE
            and binding.get("harnessSourceSHA") == os.environ["GITHUB_SHA"]
            and binding.get("mode", "copy") == mode, "Probe source binding differs")
    artifact = api(f"actions/artifacts/{ARTIFACT}")
    validate(binding["producer"], {"total_count": 1, "jobs": [binding["job"]]}, artifact)
    timed("download", lambda: download(artifact, root / "signed.zip"))
    require(checksum(root / "signed.zip") == DIGEST, "Signed source artifact changed")
    app_zip = root / "NexGenVideo.zip"
    with zipfile.ZipFile(root / "signed.zip") as archive:
        manifest = verify_manifest(json.loads(archive_bytes(archive, "manifest.json")), SOURCE, RUN)
        entry = archive.getinfo("NexGenVideo.zip")
        require(entry.file_size == manifest["files"]["NexGenVideo.zip"]["bytes"], "App ZIP size differs")
        with archive.open(entry) as source, app_zip.open("xb") as target:
            shutil.copyfileobj(source, target)
    require(checksum(app_zip) == manifest["files"]["NexGenVideo.zip"]["sha256"], "App ZIP bytes differ")
    validate_app_zip(app_zip)
    timed("extract", lambda: run("ditto", "-x", "-k", str(app_zip), str(root)))
    app = root / "NexGenVideo.app"
    restored = tree_digest(app)
    require(restored == manifest["appTreeSHA256"] and identity(root) == manifest["identity"],
            "Restored App differs from its signed manifest")
    if mode == "capacity":
        capacity(app, root)
        return
    timed("staple", lambda: run("xcrun", "stapler", "staple", str(app)))
    timed("stapleValidate", lambda: run("xcrun", "stapler", "validate", str(app)))
    dmg = root / "NexGenVideo.dmg"
    background = Path("assets/dmg-background.png").resolve()
    icon = Path("Sources/NexGenVideo/Resources/AppIcon.icns").resolve()
    require(background.is_file() and icon.is_file(), "Missing DMG background or volume icon")
    tooling = json.loads(subprocess.check_output([str(Path(os.environ["DMGBUILD_BIN"]).with_name("python")),
        "-c", "import json,sys,importlib.metadata as m; print(json.dumps({'python':sys.version,"
        "'executable':sys.executable,'packages':{p:m.version(p) for p in ['dmgbuild','ds-store','mac-alias']}}))"],
        stdin=subprocess.DEVNULL, text=True, timeout=NATIVE_TIMEOUT))
    require(tooling["packages"]["dmgbuild"] == "1.6.7", "DMG tooling version differs")
    print(json.dumps({"tooling": tooling, "python": sys.version, "executable": sys.executable}), flush=True)
    environment = dict(os.environ, DMG_APP=str(app), DMG_BG=str(background), DMG_VOLICON=str(icon))
    timed("dmgbuild", lambda: run(os.environ["DMGBUILD_BIN"], "-s", "scripts/dmg-settings.py",
                                "NexGenVideo", str(dmg), env=environment))
    result = verify(app, dmg)
    result.update(productSourceSHA=SOURCE, harnessSourceSHA=os.environ["GITHUB_SHA"],
                  originalProducerRun=RUN, originalArtifactID=ARTIFACT, compilationPerformed=False,
                  notarizationSubmitted=False, releaseAccepted=False, qualified=False, dmgSHA256=checksum(dmg),
                  restoredAppTreeSHA256=restored, python={"version": sys.version, "executable": sys.executable},
                  tooling=tooling, totalSeconds=time.monotonic() - started,
                  phaseSeconds={**durations, **{"verify." + k: v for k, v in result["phaseSeconds"].items()}})
    report = root / "report"
    report.mkdir()
    write(report / "result.json", result)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("operation", choices=("bind", "inspect"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--mode", choices=("copy", "capacity"), default="copy")
    args = parser.parse_args()
    bind(args.root, args.mode) if args.operation == "bind" else inspect(args.root, args.mode)
