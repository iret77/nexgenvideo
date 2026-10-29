import argparse
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from verify_bpy_binary_evidence import validate


REPOSITORY = "iret77/nexgenvideo"
WORKFLOW = ".github/workflows/bpy-source-closure.yml"
COMMIT = re.compile(r"[0-9a-f]{40}")
LIMIT = 2 * 1024 * 1024


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
        or run.get("path") != WORKFLOW or run.get("event") != "workflow_dispatch"
        or run.get("status") != "completed"):
        raise ValueError("Binary evidence requires the exact completed source-closure run")
    candidates = [item for item in jobs if item.get("name") == "binary-evidence"]
    if not candidates:
        raise ValueError("The requested run has no binary measurement")
    latest = max(candidates, key=lambda item: (item["run_attempt"], item["id"]))
    if (latest.get("run_id") != run_id or latest.get("head_sha") != original_sha
        or latest.get("status") != "completed" or latest.get("conclusion") != "success"
        or "macos-26" not in latest.get("labels", [])):
        raise ValueError("The latest binary measurement did not pass on macOS 26")
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


def download(artifact):
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
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output-directory", required=True, type=Path)
    args = parser.parse_args()
    reuse(args.run_id, args.source_sha, args.output_directory)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(f"binary evidence reuse refused: {error}")
