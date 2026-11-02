import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact, write
from release_checkpoint import validate_app_zip, verify_manifest
from verify_dmg_copy import verify


SOURCE = "abd136f44ea643ac6e001b63b5833aa217aff0e5"
RUN = 41477792134
ARTIFACT = 13159028671
DIGEST = "d486805bcce8f44a38cfdf824f84644ffedbea7b8ab8ddf4caaf4c350300c8d6"
PATHS = {"scripts/dmg-settings.py", "scripts/bundle.sh", "scripts/verify_dmg_copy.py",
         "scripts/release_dmg_probe.py", "scripts/test_release_dmg_packaging.py",
         ".github/workflows/signing-preflight.yml", "scripts/release_native_proof.py"}


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


def bind(root):
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
          "harnessSourceSHA": os.environ["GITHUB_SHA"], "producer": producer, "job": job, "artifact": artifact})


def inspect(root):
    binding = json.loads((root / "binding.json").read_text())
    require(binding.get("schema") == "release-dmg-probe-binding/v1"
            and binding.get("productSourceSHA") == SOURCE
            and binding.get("harnessSourceSHA") == os.environ["GITHUB_SHA"], "Probe source binding differs")
    artifact = api(f"actions/artifacts/{ARTIFACT}")
    validate(binding["producer"], {"total_count": 1, "jobs": [binding["job"]]}, artifact)
    download(artifact, root / "signed.zip")
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
    subprocess.run(["ditto", "-x", "-k", str(app_zip), str(root)], stdin=subprocess.DEVNULL,
                   check=True, timeout=180)
    app = root / "NexGenVideo.app"
    subprocess.run(["xcrun", "stapler", "staple", str(app)], stdin=subprocess.DEVNULL, check=True, timeout=180)
    dmg = root / "NexGenVideo.dmg"
    environment = dict(os.environ, DMG_APP=str(app), DMG_BG=str(Path("assets/dmg-background.png").resolve()),
                       DMG_VOLICON=str(Path("Sources/NexGenVideo/Resources/AppIcon.icns").resolve()))
    subprocess.run([os.environ["DMGBUILD_BIN"], "-s", "scripts/dmg-settings.py", "NexGenVideo", str(dmg)],
                   env=environment, stdin=subprocess.DEVNULL, check=True, timeout=180)
    result = verify(app, dmg)
    result.update(productSourceSHA=SOURCE, harnessSourceSHA=os.environ["GITHUB_SHA"],
                  originalProducerRun=RUN, originalArtifactID=ARTIFACT, compilationPerformed=False,
                  notarizationSubmitted=False, releaseAccepted=False, dmgSHA256=checksum(dmg))
    report = root / "report"
    report.mkdir()
    write(report / "result.json", result)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("operation", choices=("bind", "inspect"))
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    bind(args.root) if args.operation == "bind" else inspect(args.root)
