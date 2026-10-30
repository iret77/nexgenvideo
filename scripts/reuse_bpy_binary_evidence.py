import argparse
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from verify_bpy_binary_evidence import validate
from assemble_bpy_source_closure import SourceDownloads
from verify_bpy_source_closure import validate as validate_source_closure
from pinned_download import download_file


REPOSITORY = "iret77/nexgenvideo"
WORKFLOW = ".github/workflows/bpy-source-closure.yml"
BATCH_WORKFLOW = ".github/workflows/ci-batch.yml"
BATCH_BINARY_JOB = "bpy-qualification / binary-evidence"
COMMIT = re.compile(r"[0-9a-f]{40}")
LIMIT = 2 * 1024 * 1024
HOSTED_MEASUREMENT_CUTOFF = datetime.fromisoformat("2026-10-30T12:40:30+00:00")
SOURCE_LIMIT = 32 * 1024 * 1024 * 1024


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, target):
        return None


def request(path):
    return urllib.request.Request("https://api.github.com/repos/" + REPOSITORY + path,
        headers={"Accept": "application/vnd.github+json", "Authorization": "Bearer " + os.environ["GH_TOKEN"],
                 "X-GitHub-Api-Version": "2022-11-28"})


def api(path):
    try:
        with urllib.request.build_opener(NoRedirect()).open(request(path), timeout=30) as response:
            data = response.read(4 * LIMIT + 1)
    except urllib.error.URLError:
        raise ValueError("GitHub did not return the requested binary-evidence metadata") from None
    if len(data) > 4 * LIMIT:
        raise ValueError("Binary-evidence metadata exceeds its size bound")
    return json.loads(data)


def pages(path, key):
    values = []
    separator = "&" if "?" in path else "?"
    for page in range(1, 101):
        batch = api(f"{path}{separator}per_page=100&page={page}")[key]
        values.extend(batch)
        if len(batch) < 100:
            return values
    raise ValueError("Binary-evidence metadata pagination exceeds its bound")


def instant(value):
    result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Binary evidence has an unqualified timestamp")
    return result


def require_producer(run_id, run, artifacts, jobs):
    original_sha = run.get("head_sha", "")
    if (run.get("id") != run_id or not COMMIT.fullmatch(original_sha)
        or run.get("repository", {}).get("full_name") != REPOSITORY
        or run.get("head_repository", {}).get("full_name") != REPOSITORY
        or run.get("path") not in (WORKFLOW, BATCH_WORKFLOW) or run.get("event") != "workflow_dispatch"
        or run.get("status") != "completed"):
        raise ValueError("Binary evidence requires the exact completed source-closure run")
    job_name = "binary-evidence" if run["path"] == WORKFLOW else BATCH_BINARY_JOB
    candidates = [item for item in jobs if item.get("name") == job_name]
    if not candidates:
        raise ValueError("The requested run has no binary measurement")
    latest = max(candidates, key=lambda item: (item["run_attempt"], item["id"]))
    # Only measurements completed before this migration retain hosted-runner provenance.
    labels = latest.get("labels", [])
    accepted_runner = "macrunner" in labels or ("macos-26" in labels
        and instant(latest["completed_at"]) < HOSTED_MEASUREMENT_CUTOFF)
    if (latest.get("run_id") != run_id or latest.get("head_sha") != original_sha
        or latest.get("status") != "completed" or latest.get("conclusion") != "success"
        or not accepted_runner):
        raise ValueError("The latest binary measurement did not pass on an accepted measurement runner")
    name = "managed-bpy-binary-evidence-" + original_sha
    matches = [item for item in artifacts if item.get("name") == name]
    if len(matches) != 1:
        raise ValueError("The exact binary-evidence artifact is missing or ambiguous")
    artifact = matches[0]
    origin = artifact.get("workflow_run", {})
    if (type(artifact.get("id")) is not int or artifact["id"] <= 0
        or artifact.get("expired") is not False or origin.get("id") != run_id
        or origin.get("head_sha") != original_sha
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", ""))
        or type(artifact.get("size_in_bytes")) is not int
        or not 0 < artifact["size_in_bytes"] <= LIMIT
        or not instant(latest["started_at"]) <= instant(artifact["created_at"]) <= instant(latest["completed_at"])
        or not instant(latest["started_at"]) <= instant(artifact["updated_at"]) <= instant(latest["completed_at"])):
        raise ValueError("The artifact does not belong to the latest passing binary measurement")
    return artifact, latest


def source_response(artifact, offset, timeout):
    opener = urllib.request.build_opener(NoRedirect())
    try:
        response = opener.open(request(f"/actions/artifacts/{artifact['id']}/zip"), timeout=min(30, timeout))
    except urllib.error.HTTPError as error:
        with error:
            if error.code != 302:
                raise
            location = error.headers.get("Location", "")
    else:
        response.close()
        raise ValueError("GitHub did not return the exact source artifact redirect")
    target = urllib.parse.urlsplit(location)
    if target.scheme != "https" or not target.hostname or target.username or target.password:
        raise ValueError("GitHub returned an invalid source artifact redirect")
    headers = {"Accept-Encoding": "identity"}
    if offset:
        headers["Range"] = f"bytes={offset}-"
    try:
        return opener.open(urllib.request.Request(location, headers=headers), timeout=timeout)
    except ValueError:
        raise ValueError("Invalid source artifact redirect; URL withheld") from None


def download(artifact, destination=None):
    if destination is not None:
        return download_file(lambda offset, timeout: source_response(artifact, offset, timeout),
                             destination, artifact["size_in_bytes"], artifact["digest"], SOURCE_LIMIT)
    opener = urllib.request.build_opener(NoRedirect())
    try:
        response = opener.open(request(f"/actions/artifacts/{artifact['id']}/zip"), timeout=30)
    except urllib.error.HTTPError as error:
        if error.code != 302:
            raise ValueError("GitHub refused the exact binary-evidence download") from None
        location = error.headers.get("Location", "")
        error.close()
        target = urllib.parse.urlsplit(location)
        if target.scheme != "https" or not target.hostname or target.username or target.password:
            raise ValueError("GitHub returned an invalid binary-evidence redirect")
        # The signed storage URL must never receive the repository token.
        try:
            response = opener.open(urllib.request.Request(location), timeout=120)
        except urllib.error.URLError:
            raise ValueError("The exact binary-evidence download failed") from None
    except urllib.error.URLError:
        raise ValueError("GitHub did not provide the exact binary-evidence artifact") from None
    with response:
        data = response.read(LIMIT + 1)
    if len(data) > LIMIT or "sha256:" + hashlib.sha256(data).hexdigest() != artifact["digest"]:
        raise ValueError("Binary-evidence archive digest mismatch")
    return data


def require_source_producer(run_id, run, artifacts, jobs):
    original_sha = run.get("head_sha", "")
    if (run.get("id") != run_id or not COMMIT.fullmatch(original_sha)
        or run.get("repository", {}).get("full_name") != REPOSITORY
        or run.get("head_repository", {}).get("full_name") != REPOSITORY
        or run.get("path") not in (WORKFLOW, BATCH_WORKFLOW)
        or run.get("event") != "workflow_dispatch" or run.get("status") != "completed"):
        raise ValueError("Source reuse requires the exact completed qualification run")
    name = "source" if run["path"] == WORKFLOW else "bpy-qualification / source"
    candidates = [item for item in jobs if item.get("name") == name]
    if not candidates:
        raise ValueError("The requested run has no qualification source job")
    job = max(candidates, key=lambda item: (item["run_attempt"], item["id"]))
    if (job.get("run_id") != run_id or job.get("head_sha") != original_sha
        or job.get("status") != "completed"
        or job.get("conclusion") not in {"success", "failure", "cancelled", "timed_out"}
        or "ubuntu-24.04" not in job.get("labels", [])):
        raise ValueError("The latest qualification source job is not a completed source producer")
    matches = [item for item in artifacts if item.get("name") == "managed-bpy-source-" + original_sha]
    if len(matches) != 1:
        raise ValueError("The exact source artifact is missing or ambiguous")
    artifact = matches[0]
    origin = artifact.get("workflow_run", {})
    if (type(artifact.get("id")) is not int or artifact["id"] <= 0
        or artifact.get("expired") is not False or origin.get("id") != run_id
        or origin.get("head_sha") != original_sha
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", ""))
        or type(artifact.get("size_in_bytes")) is not int
        or not 0 < artifact["size_in_bytes"] <= SOURCE_LIMIT
        or not instant(job["started_at"]) <= instant(artifact["created_at"]) <= instant(job["completed_at"])
        or not instant(job["started_at"]) <= instant(artifact["updated_at"]) <= instant(job["completed_at"])):
        raise ValueError("The source artifact does not belong to the latest source attempt")
    return artifact, job


def stage_sources(archive_path, stage, source_sha):
    with zipfile.ZipFile(archive_path) as archive:
        members = {}
        for item in archive.infolist():
            parts = item.filename.split("/")
            if (item.filename in members or item.filename.startswith("/")
                or ".." in parts or "\\" in item.filename
                or stat.S_IFMT(item.external_attr >> 16) not in {0, stat.S_IFREG, stat.S_IFDIR}):
                raise ValueError("Source artifact has unsafe or duplicate members")
            members[item.filename] = item

        def metadata(name):
            if name not in members or not 0 < members[name].file_size <= LIMIT:
                raise ValueError("Source artifact metadata is missing or exceeds its bound")
            return archive.read(name)

        def preserve(item, source):
            nonlocal retained_size
            algorithm = item.get("upstreamHashType", "").upper()
            expected = item.get("upstreamHash", "")
            length = {"SHA256": 64, "SHA1": 40, "MD5": 32}.get(algorithm)
            if (length is None or not re.fullmatch(r"[0-9a-f]{%d}" % length, expected)
                or not re.fullmatch(r"[0-9a-f]{64}", item.get("sha256", ""))
                or type(item.get("size")) is not int or not 0 < item["size"] <= SOURCE_LIMIT):
                raise ValueError("Retained source has invalid original pins")
            retained_size += item["size"]
            if retained_size > SOURCE_LIMIT:
                raise ValueError("Retained source subset exceeds its total bound")
            relative = SourceDownloads.relative_path(item["component"], item["url"], expected,
                                                     algorithm, Path(item["path"]).name[65:])
            if relative != item["path"] or relative in retained:
                raise ValueError("Retained source identity/path differs from its pins")
            path = stage / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            value = hashlib.sha256()
            upstream = hashlib.new(algorithm.lower())
            size = 0
            with source, path.open("wb") as output:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    size += len(block)
                    if size > item["size"]:
                        raise ValueError("Retained source exceeds its recorded size")
                    value.update(block)
                    upstream.update(block)
                    output.write(block)
            if (size != item["size"] or value.hexdigest() != item["sha256"]
                or upstream.hexdigest() != expected):
                raise ValueError("Retained source archive bytes differ from their original pins")
            retained[relative] = item

        retained = {}
        retained_size = 0
        if "verified-sources.json" in members:
            record = json.loads(metadata("verified-sources.json"))
            if (record.get("schema") != "nexgenvideo/bpy-verified-source-downloads/1"
                or record.get("sourceSHA") != source_sha
                or record.get("classification") != "verified-subset-only"
                or record.get("sourceClosureComplete") is not False
                or record.get("publicDistributionAuthorized") is not False
                or not isinstance(record.get("downloads"), list)
                or not 0 < len(record["downloads"]) <= 10000):
                raise ValueError("Partial source artifact has no bound verified subset")
            for item in record["downloads"]:
                member = members.get(item["path"])
                if member is None or member.is_dir() or member.file_size != item["size"]:
                    raise ValueError("Partial source artifact is missing recorded bytes")
                preserve(item, archive.open(member))
        else:
            tar_name = "NexGenVideo-bpy-5.2.2-corresponding-source.tar"
            manifest_name = "NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json"
            manifest_path = stage / "input.manifest.json"
            manifest_data = metadata(manifest_name)
            manifest_path.write_bytes(manifest_data)
            if tar_name not in members or not 0 < members[tar_name].file_size <= SOURCE_LIMIT:
                raise ValueError("Complete source artifact has no bounded source tar")
            tar_path = stage / "input.tar"
            with archive.open(tar_name) as source, tar_path.open("wb") as output:
                shutil.copyfileobj(source, output)
            evidence = json.loads(metadata("evidence.json"))
            if (evidence.get("schema") != "nexgenvideo/bpy-source-evidence/1"
                or evidence.get("sourceSHA") != source_sha):
                raise ValueError("Complete source evidence differs from its producer")
            for name, path in ((tar_name, tar_path), (manifest_name, manifest_path)):
                pins = [item for item in evidence.get("artifacts", []) if item.get("filename") == name]
                value = hashlib.sha256()
                with path.open("rb") as source:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        value.update(block)
                if (len(pins) != 1 or pins[0].get("sha256") != value.hexdigest()
                    or pins[0].get("size") != path.stat().st_size):
                    raise ValueError("Complete source tar/manifest differs from its producer evidence")
            manifest = validate_source_closure(tar_path, manifest_path)
            with tarfile.open(tar_path, "r:") as source_tar:
                for source in manifest["sources"]:
                    item = {key: source[key] for key in (
                        "component", "url", "upstreamHash", "upstreamHashType", "sha256", "size")}
                    item["upstreamHash"] = item["upstreamHash"].lower()
                    item["retrievalURL"] = source.get("retrievalURL", source["url"])
                    item["path"] = SourceDownloads.relative_path(
                        item["component"], item["url"], item["upstreamHash"],
                        item["upstreamHashType"], Path(source["archivePath"]).name)
                    preserve(item, source_tar.extractfile(source["archivePath"]))
        record = {"schema": "nexgenvideo/bpy-verified-source-downloads/1", "sourceSHA": source_sha,
                  "classification": "verified-subset-only", "publicDistributionAuthorized": False,
                  "sourceClosureComplete": False,
                  "downloads": list(retained.values())}
        (stage / "verified-sources.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        return record


def reuse_sources(run_id, current_sha, output):
    if run_id <= 0 or not COMMIT.fullmatch(current_sha):
        raise ValueError("Explicit source run ID and current source SHA are required")
    run = api(f"/actions/runs/{run_id}")
    artifact, job = require_source_producer(run_id, run,
        pages(f"/actions/runs/{run_id}/artifacts", "artifacts"),
        pages(f"/actions/runs/{run_id}/jobs?filter=all", "jobs"))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bpy-source-reuse-", dir=output.parent) as temporary:
        stage = Path(temporary)
        archive_path = download(artifact, stage / "artifact.zip")
        record = stage_sources(archive_path, stage, run["head_sha"])
        final_artifact, final_job = require_source_producer(run_id, api(f"/actions/runs/{run_id}"),
            pages(f"/actions/runs/{run_id}/artifacts", "artifacts"),
            pages(f"/actions/runs/{run_id}/jobs?filter=all", "jobs"))
        if (final_job["id"] != job["id"] or final_artifact["id"] != artifact["id"]
            or final_artifact["digest"] != artifact["digest"]):
            raise ValueError("Source artifact changed during reuse")
        output.mkdir(parents=True, exist_ok=True)
        for item in record["downloads"]:
            target = output / item["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.is_symlink():
                raise ValueError("Retained source destination must not be a symlink")
            shutil.copyfile(stage / item["path"], target)
        shutil.copyfile(stage / "verified-sources.json", output / "verified-sources.json")
        receipt = {"schema": "nexgenvideo/bpy-source-reuse/1", "publicDistributionAuthorized": False,
                   "sourceSHA": current_sha, "originalSourceSHA": run["head_sha"],
                   "originalRunID": run_id, "originalJobID": job["id"],
                   "originalJobAttempt": job["run_attempt"], "originalArtifactID": artifact["id"],
                   "originalArtifactDigest": artifact["digest"], "verifiedDownloadCount": len(record["downloads"]),
                   "currentOriginalPinValidation": "required when assembler consumes each retained entry"}
        (output / "source-reuse.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def read_evidence(data):
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = archive.infolist()
        if len(members) != 2 or {item.filename for item in members} != {"binary-evidence.json", "validation.json"}:
            raise ValueError("Binary-evidence archive contains unexpected files")
        for item in members:
            if (item.is_dir() or stat.S_IFMT(item.external_attr >> 16) not in {0, stat.S_IFREG}
                or not 0 < item.file_size <= LIMIT):
                raise ValueError("Binary-evidence archive contains an invalid member")
        return archive.read("binary-evidence.json")


def reuse(run_id, current_sha, output):
    if run_id <= 0 or not COMMIT.fullmatch(current_sha):
        raise ValueError("Explicit binary run ID and current source SHA are required")
    run = api(f"/actions/runs/{run_id}")
    artifact, job = require_producer(run_id, run,
        pages(f"/actions/runs/{run_id}/artifacts", "artifacts"),
        pages(f"/actions/runs/{run_id}/jobs?filter=all", "jobs"))
    data = read_evidence(download(artifact))
    evidence = json.loads(data)
    validate(evidence, run["head_sha"])
    final_artifact, final_job = require_producer(run_id, api(f"/actions/runs/{run_id}"),
        pages(f"/actions/runs/{run_id}/artifacts", "artifacts"),
        pages(f"/actions/runs/{run_id}/jobs?filter=all", "jobs"))
    if (final_job["id"] != job["id"] or final_artifact["id"] != artifact["id"]
        or final_artifact["digest"] != artifact["digest"]):
        raise ValueError("The binary measurement changed during reuse")
    record = {"schema": "nexgenvideo/bpy-binary-evidence-reuse/1", "classification": "candidate-only",
              "publicDistributionAuthorized": False, "sourceSHA": current_sha,
              "originalSourceSHA": run["head_sha"], "originalRunID": run_id,
              "originalJobID": job["id"], "originalJobAttempt": job["run_attempt"],
              "originalArtifactID": artifact["id"], "originalArtifactDigest": artifact["digest"],
              "binaryEvidenceSHA256": hashlib.sha256(data).hexdigest(),
              "runtimeInputsSHA256": evidence["runtimeInputsSHA256"]}
    output.mkdir(parents=True, exist_ok=True)
    (output / "reused-binary-evidence.json").write_bytes(data)
    (output / "binary-evidence-reuse.json").write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--source-run-id", type=int)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output-directory", required=True, type=Path)
    args = parser.parse_args()
    if args.run_id is None and args.source_run_id is None:
        parser.error("An explicit binary or source run ID is required")
    if args.run_id is not None:
        reuse(args.run_id, args.source_sha, args.output_directory)
    if args.source_run_id is not None:
        reuse_sources(args.source_run_id, args.source_sha, args.output_directory)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError, OSError, zipfile.BadZipFile, tarfile.TarError) as error:
        raise SystemExit(f"binary evidence reuse refused: {error}")
