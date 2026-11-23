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


QUALIFIED_CLIENT = {
    "tree": "186415df9e11a56ed484ee381a99d96586e27618",
    "source": "a0cf15a928be745ea692ba04a1c60544efef4e8a",
    "run": 45091463772,
    "attempt": 1,
    "sha256": "a6264b5704dd775da5dd843289e54dd6ac7963629756d5629f8d9d361e6eb120",
    "products": "ee8acfb10f5f47707da65329921a61c0c9a689ff53c32d3739b4326b9fae42d1",
    "xctestrun": "FileDialogUI_macosx27.2-arm64.xctestrun",
    "artifactID": 14781965475,
    "artifactDigest": "sha256:ed4cfad46727eb1730ab7a773dc7c49916349a2bfd9f6869219d67a1329f4c19"
}
QUALIFIED_JOB = 137422367069


def bound_client_source(client, source):
    return client["source"] == source or (client == QUALIFIED_CLIENT and project_tree(source) == client["tree"])


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


def client_producer_job(candidates, product, run_id, attempt, native_origin=None):
    if native_origin:
        candidates = [j for j in candidates if j["id"] == native_origin["jobID"] and j["name"] == "rc130-track-confirmation"
                      and j["status"] == "completed" and j["conclusion"] in {"failure", "success"}
                      and j["run_attempt"] == native_origin["attempt"]]
    else:
        candidates = [j for j in candidates if j["conclusion"] == "success"]
    job, = [j for j in candidates if j["labels"] == ["macrunner"]
            and j["head_sha"] == product and j["run_id"] == run_id and j["run_attempt"] == attempt
            and any(s["name"] == "Build file dialog XCTest" and s["conclusion"] == "success" for s in j["steps"])]
    return job


def restore(work, products, product, run_id, *, native_origin=None, native_producer=None, qualified=False):
    selected = environment_selectors()
    if native_origin and (selected or os.environ.get("GITHUB_JOB") != "app-target-build"):
        raise ValueError("A native Track check requires a direct original client")
    if qualified and (product != QUALIFIED_CLIENT["source"] or run_id != QUALIFIED_CLIENT["run"] or native_origin or native_producer):
        raise ValueError("Unexpected qualified file dialog origin")
    if selected and native_producer is None and not qualified:
        provenance = load_provenance(run_id, product, selected)["record"]
        run_id = provenance["originalSignedBuildRunID"]
    run = api(f"actions/runs/{run_id}")
    supported_workflows = {".github/workflows/" + name + ".yml" for name in
                           ("bundle", "ci", "ci-batch", "workspace-ui-acceptance", "private-example-analysis", "release")}
    if native_origin:
        supported_workflows = {".github/workflows/native-acceptance-probes.yml"}
    if qualified:
        supported_workflows = {".github/workflows/diagnostic-acceptance.yml"}
        if (run["actor"]["login"] != "iret77" or run["event"] != "workflow_dispatch" or run["workflow_id"] != 355242770
                or run["run_attempt"] != QUALIFIED_CLIENT["attempt"] or run["status"] != "completed"):
            raise ValueError("Qualified file dialog run changed")
    if native_producer is not None:
        supported_workflows = {".github/workflows/diagnostic-acceptance.yml"}
        if native_producer["run"]["id"] != run_id or run["conclusion"] != "success" or run["status"] != "completed":
            raise ValueError("The qualified native file dialog producer differs")
    if (run.get("repository", {}).get("full_name") != "iret77/nexgenvideo" or run.get("id") != run_id
            or run.get("head_sha") != product or run.get("path") not in supported_workflows):
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
            or run["status"] != "completed" or run["workflow_id"] != 388064375 or run["event"] != "workflow_dispatch"):
        raise ValueError("Native Track check received a different original client")
    if qualified and (artifact["id"] != QUALIFIED_CLIENT["artifactID"] or artifact["digest"] != QUALIFIED_CLIENT["artifactDigest"]):
        raise ValueError("Qualified file dialog archive changed")
    size = artifact["size_in_bytes"]
    if not 0 < size <= 128 * 1024**2 or shutil.disk_usage(work).free < 512 * 1024**2 + size:
        raise ValueError("Insufficient file dialog client archive reserve")
    raw = artifact_bytes(artifact, size)
    with zipfile.ZipFile(io.BytesIO(raw)) as outer:
        if outer.namelist() == ["native-client-origin.json"]:
            if (native_origin or native_producer or qualified or run["path"] != ".github/workflows/release.yml"
                    or outer.getinfo("native-client-origin.json").file_size > 16384):
                raise ValueError("Unexpected native file dialog transfer")
            transfer = json.loads(outer.read("native-client-origin.json"))
            attempt = transfer["releaseAttempt"]
            if (transfer["schema"] != "nexgenvideo/native-file-dialog-transfer/1" or transfer["releaseRun"] != run_id
                    or type(attempt) is not int or not 1 <= attempt <= run["run_attempt"]):
                raise ValueError("Unexpected release transfer identity")
            jobs = api(f"actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100")
            if jobs["total_count"] != len(jobs["jobs"]):
                raise ValueError("Incomplete release job inventory")
            job, = [row for row in jobs["jobs"] if row["name"] == "release-build"
                    and row["conclusion"] == "success" and row["labels"] == ["macrunner"]
                    and row["head_sha"] == product and row["run_id"] == run_id and row["run_attempt"] == attempt
                    and any(s["name"] == "Use qualified native file dialog XCTest" and s["conclusion"] == "success"
                            for s in row["steps"])]
            verify_artifact(artifact, run, job, item["id"], artifact["digest"].removeprefix("sha256:"), "file-dialog-ui")
            client = restore_native_client(work, products, product, transfer["metadata"])
            if client != transfer["client"]:
                raise ValueError("Release points to different native file dialog products")
            return client
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
    if qualified:
        job, = [j for j in candidates if j["id"] == QUALIFIED_JOB and j["name"] == "app-target-build"
                and j["status"] == "completed" and j["conclusion"] in {"failure", "success"} and j["labels"] == ["macrunner"]
                and j["run_id"] == run_id and j["head_sha"] == product and j["run_attempt"] == attempt == 1
                and [s["conclusion"] for s in j["steps"] if s["name"] == "Build file dialog XCTest"] == ["success"]]
    else:
        job = client_producer_job(candidates, product, run_id, attempt, native_origin)
    if native_producer is not None and job["id"] != native_producer["job"]["id"]:
        raise ValueError("Compiled App metadata and file dialog XCTest came from different jobs")
    verify_artifact(artifact, run, job, item["id"], artifact["digest"].removeprefix("sha256:"), "file-dialog-ui")
    with tarfile.open(archive) as tar:
        if sum(i.size for i in tar) > 400 * 1024**2:
            raise ValueError("Oversize expanded file dialog products")
    unpack_products(archive, products)
    original, = products.glob("FileDialogUI*.xctestrun")
    check_test_paths(original, products)
    if original.name != receipt["xctestrun"] or products_sha256(products) != receipt["products"]:
        raise ValueError("Restored file dialog client differs")
    client = dict(receipt, artifactID=item["id"], artifactDigest=artifact["digest"])
    if qualified and client != QUALIFIED_CLIENT:
        raise ValueError("Qualified file dialog receipt changed")
    (work / "client.json").write_text(json.dumps(client))
    return client


def restore_qualified_client(work, products, source):
    if project_tree(source) != QUALIFIED_CLIENT["tree"]:
        raise ValueError("The current file dialog project differs from the qualified compiler input")
    return restore(work, products, QUALIFIED_CLIENT["source"], QUALIFIED_CLIENT["run"], qualified=True)


def restore_native_client(work, products, product, metadata):
    from compiled_app_release import producer
    if (set(metadata) != {"artifactID", "artifactSHA256", "runID", "sourceSHA"} or metadata["sourceSHA"] != product
            or type(metadata["runID"]) is not int or metadata["runID"] <= 0
            or type(metadata["artifactID"]) is not int or metadata["artifactID"] <= 0
            or not re.fullmatch("[a-f0-9]{64}", metadata["artifactSHA256"])):
        raise ValueError("Unexpected native file dialog metadata selector")
    origin = producer(metadata, "metadata")
    if any(step["name"] == "Restore qualified file dialog XCTest" and step["conclusion"] == "success"
           for step in origin["job"]["steps"]):
        if origin["run"]["conclusion"] != "success" or origin["job"]["conclusion"] != "success":
            raise ValueError("Native intake did not qualify the restored client")
        raw = artifact_bytes(origin["artifact"], 256 * 1024**2)
        name = "track-intake/evidence/verified.json"
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            if archive.namelist().count(name) != 1 or archive.getinfo(name).file_size > 128 * 1024:
                raise ValueError("Missing qualified native intake receipt")
            intake = json.loads(archive.read(name))
        if (intake["source"] != product or intake["runID"] != str(metadata["runID"])
                or intake["nativeExit"] != 0 or intake["testExit"] != 0 or intake["binding"]["client"] != QUALIFIED_CLIENT):
            raise ValueError("Native intake did not exercise the selected original client")
        return restore_qualified_client(work, products, product)
    return restore(work, products, product, metadata["runID"], native_producer=origin)


def transfer_native_client(work, products, product):
    from compiled_app_release import selectors
    if os.environ.get("GITHUB_JOB") != "release-build" or product != os.environ["GITHUB_SHA"]:
        raise ValueError("Native file dialog transfer requires the release checkout")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_bytes())
    metadata = selectors(event["inputs"]["compiled_app_targets_json"], event)["metadata"]
    client = restore_native_client(work, products, product, metadata)
    transfer = dict(schema="nexgenvideo/native-file-dialog-transfer/1", releaseRun=int(os.environ["GITHUB_RUN_ID"]),
                    releaseAttempt=int(os.environ["GITHUB_RUN_ATTEMPT"]), metadata=metadata, client=client)
    publication = work / "transfer"
    publication.mkdir()
    (publication / "native-client-origin.json").write_text(json.dumps(transfer))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("build", "restore", "native-transfer", "select-native", "restore-qualified"))
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REPOSITORY") != "iret77/nexgenvideo":
        raise ValueError("Requires the NexGenVideo CI job")
    runner = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    work = runner / "file-dialog-ui"
    product = os.environ.get("DIALOG_APP_SOURCE") or os.environ["GITHUB_SHA"]
    if not uses_external_dialogs(product):
        return
    if args.mode in {"select-native", "restore-qualified"}:
        if os.environ.get("GITHUB_JOB") != "app-target-build" or product != os.environ["GITHUB_SHA"]:
            raise ValueError("Unexpected native file dialog consumer")
        if args.mode == "select-native":
            with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                stream.write("reuse=" + str(project_tree(product) == QUALIFIED_CLIENT["tree"]).lower() + "\n")
            return
    work.mkdir()
    products = work / "build/Build/Products"
    if args.mode == "build":
        package(work, products, product)
    elif args.mode == "restore-qualified":
        restore_qualified_client(work, products, product)
    elif args.mode == "native-transfer":
        transfer_native_client(work, products, product)
    else:
        run_id = int(os.environ.get("DIALOG_APP_RUN") or os.environ["GITHUB_RUN_ID"])
        restore(work, products, product, run_id)
    with open(os.environ["GITHUB_ENV"], "a") as stream:
        stream.write("NGV_FILE_DIALOG_PRODUCTS=" + str(products) + "\n")


if __name__ == "__main__":
    main()
