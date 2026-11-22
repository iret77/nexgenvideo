"""Build once and recover the exact independent file dialog XCTest from the app producer."""
import argparse
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile

from retained_app_test_products import checksum

sys.path.insert(0, str(Path(__file__).resolve().parent / "external-gui"))
from test_bundle import check_test_paths, products_sha256, unpack_products
from retained_packaging import api, artifact_bytes, verify_artifact, environment_selectors, load_provenance


def uses_external_dialogs(product):
    if not re.fullmatch(r"[a-f0-9]{40}", product):
        raise ValueError("Missing product source")
    path = "Sources/NexGenVideo/App/ProductionVisualSourcesDriver.swift"
    if not subprocess.check_output(["git", "ls-tree", product, "--", path], timeout=10):
        return False
    source = subprocess.check_output(["git", "show", product + ":" + path], timeout=10)
    return b'NGV_FILE_DIALOG_EVIDENCE' in source


def build(work):
    project = work / "project"
    shutil.copytree(Path(__file__).resolve().parent / "file-dialog-ui", project)
    with (work / "build.log").open("xb") as log:
        subprocess.run(["xcodegen", "generate"], cwd=project, stdin=subprocess.DEVNULL,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        subprocess.run(["xcodebuild", "build-for-testing", "-project", project / "FileDialogUI.xcodeproj",
                        "-scheme", "FileDialogUI", "-destination", "platform=macOS,arch=arm64",
                        "-derivedDataPath", work / "build", "MACOSX_DEPLOYMENT_TARGET=26.0", "ARCHS=arm64"], stdin=subprocess.DEVNULL,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)


def project_tree(source):
    return subprocess.check_output(["git", "rev-parse", source + ":scripts/file-dialog-ui"], text=True).strip()


def package(work, products, source):
    build(work)
    original, = products.glob("FileDialogUI*.xctestrun")
    check_test_paths(original, products)
    publication = work / "transfer"
    publication.mkdir()
    archive = publication / "products.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        for path in sorted(products.iterdir()):
            bundle.add(path, arcname=path.name)
    receipt = dict(tree=project_tree(source), source=source, run=int(os.environ["GITHUB_RUN_ID"]),
                   attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]), sha256=checksum(archive),
                   products=products_sha256(products), xctestrun=original.name)
    (publication / "client.json").write_text(json.dumps(receipt))


def restore(work, products, product, run_id, *, native_origin=None):
    selected = environment_selectors()
    if native_origin and (selected or os.environ.get("GITHUB_JOB") != "app-target-build"):
        raise ValueError("A native Track check requires a direct original client")
    if selected:
        provenance = load_provenance(run_id, product, selected)["record"]
        run_id = provenance["originalSignedBuildRunID"]
    run = api(f"actions/runs/{run_id}")
    if (run.get("repository", {}).get("full_name") != "iret77/nexgenvideo" or run.get("id") != run_id
            or run.get("head_sha") != product or run.get("path") not in {
                ".github/workflows/bundle.yml", ".github/workflows/ci.yml", ".github/workflows/ci-batch.yml", ".github/workflows/workspace-ui-acceptance.yml",
                ".github/workflows/private-example-analysis.yml", ".github/workflows/release.yml"}):
        raise ValueError("Unexpected file dialog producer")
    inventory = api(f"actions/runs/{run_id}/artifacts?name=file-dialog-ui&per_page=100")
    item, = inventory["artifacts"]
    artifact = api("actions/artifacts/" + str(item["id"]))
    if (artifact.get("name") != "file-dialog-ui" or artifact.get("expired") is not False
            or artifact.get("workflow_run", {}).get("id") != run_id
            or artifact["workflow_run"].get("head_sha") != product or artifact["id"] != item["id"]):
        raise ValueError("File dialog artifact does not belong to the app producer")
    if native_origin and (artifact["id"] != native_origin["artifactID"] or artifact["digest"] != native_origin["digest"]
            or run["actor"]["login"] != "iret77" or run["run_attempt"] != native_origin["attempt"]
            or run["status"] != "completed" or run["workflow_id"] != 303346287):
        raise ValueError("Native Track check received a different original client")
    size = artifact["size_in_bytes"]
    if not 0 < size <= 128 * 1024**2 or shutil.disk_usage(work).free < 512 * 1024**2 + size:
        raise ValueError("Insufficient file dialog client archive reserve")
    raw = artifact_bytes(artifact, size)
    with zipfile.ZipFile(io.BytesIO(raw)) as outer:
        if sorted(outer.namelist()) != ["client.json", "products.tar.gz"] or outer.getinfo("client.json").file_size > 16384:
            raise ValueError("Unexpected file dialog client archive")
        receipt = json.loads(outer.read("client.json"))
        if outer.getinfo("products.tar.gz").file_size > 128 * 1024**2:
            raise ValueError("Oversize file dialog client products")
        archive = work / "products.tar.gz"
        with outer.open("products.tar.gz") as src, archive.open("xb") as dest:
            shutil.copyfileobj(src, dest)
    attempt = receipt["attempt"]
    if (receipt["source"] != product or receipt["run"] != run_id or type(attempt) is not int or not 1 <= attempt <= run["run_attempt"]
            or receipt["tree"] != project_tree(os.environ["GITHUB_SHA"]) or checksum(archive) != receipt["sha256"]):
        raise ValueError("File dialog client source or archive differs")
    jobs = api(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
    candidates = jobs["jobs"]
    for page in range(2, (jobs["total_count"] + 99) // 100 + 1):
        candidates.extend(api(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")["jobs"])
    if native_origin:
        candidates = [j for j in candidates if j["id"] == native_origin["jobID"] and j["name"] == "release-build"
                      and j["status"] == "completed" and j["conclusion"] in {"failure", "success"}
                      and j["run_attempt"] == native_origin["attempt"]]
    else:
        candidates = [j for j in candidates if j["conclusion"] == "success"]
    job, = [j for j in candidates if j["labels"] == ["macrunner"]
            and j["head_sha"] == product and j["run_id"] == run_id and j["run_attempt"] == attempt
            and any(s["name"] == "Build file dialog XCTest" and s["conclusion"] == "success" for s in j["steps"])]
    verify_artifact(artifact, run, job, item["id"], artifact["digest"].removeprefix("sha256:"), "file-dialog-ui")
    with tarfile.open(archive) as tar:
        if sum(i.size for i in tar) > 400 * 1024**2:
            raise ValueError("Oversize expanded file dialog products")
    unpack_products(archive, products)
    original, = products.glob("FileDialogUI*.xctestrun")
    check_test_paths(original, products)
    if original.name != receipt["xctestrun"] or products_sha256(products) != receipt["products"]:
        raise ValueError("Restored file dialog client differs")
    (work / "client.json").write_text(json.dumps(dict(receipt, artifactID=item["id"], artifactDigest=artifact["digest"])))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("build", "restore"))
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REPOSITORY") != "iret77/nexgenvideo":
        raise ValueError("Requires the NexGenVideo CI job")
    runner = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    work = runner / "file-dialog-ui"
    product = os.environ.get("DIALOG_APP_SOURCE") or os.environ["GITHUB_SHA"]
    if not uses_external_dialogs(product):
        return
    work.mkdir()
    products = work / "build/Build/Products"
    if args.mode == "build":
        package(work, products, product)
    else:
        run_id = int(os.environ.get("DIALOG_APP_RUN") or os.environ["GITHUB_RUN_ID"])
        restore(work, products, product, run_id)
    with open(os.environ["GITHUB_ENV"], "a") as stream:
        stream.write("NGV_FILE_DIALOG_PRODUCTS=" + str(products) + "\n")


if __name__ == "__main__":
    main()
