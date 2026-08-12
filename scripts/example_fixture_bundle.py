#!/usr/bin/env python3
"""Build and verify private, content-addressed example fixture bundles."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import shutil
import subprocess
import tarfile
from pathlib import Path, PurePosixPath


SCHEMA = "nexgenvideo.example-fixtures/v1"
EXPECTATIONS_SCHEMA = "nexgenvideo.example-fixture-expectations/v2"
ARCHIVE_ROOT = "examples"
AUDIO_EXTENSIONS = {".aac", ".aiff", ".flac", ".m4a", ".mp3", ".wav"}
LYRICS_EXTENSIONS = {".lrc", ".md", ".txt"}
IMAGE_EXTENSIONS = {".avif", ".gif", ".heic", ".jpeg", ".jpg", ".png", ".tif", ".tiff", ".webp"}


class FixtureError(ValueError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def media_kind(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in AUDIO_EXTENSIONS:
        return "audio"
    if suffix in LYRICS_EXTENSIONS:
        return "lyrics"
    if suffix in IMAGE_EXTENSIONS:
        return "image"
    return "other"


def validate_relative_path(raw: str) -> PurePosixPath:
    path = PurePosixPath(raw)
    if path.is_absolute() or not path.parts or any(part in {"", ".", ".."} for part in path.parts):
        raise FixtureError("unsafe fixture path")
    return path


def load_expectations(path: Path | None) -> dict[str, dict]:
    if path is None:
        return {}
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schema") != EXPECTATIONS_SCHEMA:
        raise FixtureError(f"expectations schema must be {EXPECTATIONS_SCHEMA}")
    datasets = document.get("datasets")
    if not isinstance(datasets, dict):
        raise FixtureError("expectations.datasets must be an object")
    for dataset_id, values in datasets.items():
        if not isinstance(dataset_id, str) or not dataset_id or not isinstance(values, dict):
            raise FixtureError("each expectations dataset must be a named object")
        audio = values.get("audio")
        if not isinstance(audio, dict):
            raise FixtureError(f"{dataset_id}: audio expectations are required")
        required = [
            "path",
            "duration_s",
            "duration_tolerance_s",
            "bpm",
            "bpm_tolerance",
            "expect_boundary_reduction",
            "section_boundaries_s",
            "section_boundary_tolerance_s",
        ]
        if any(key not in audio for key in required):
            raise FixtureError(f"{dataset_id}: incomplete audio expectations")
        validate_relative_path(audio["path"])
        for key in ["duration_s", "duration_tolerance_s", "bpm", "bpm_tolerance", "section_boundary_tolerance_s"]:
            if not isinstance(audio[key], (int, float)) or audio[key] <= 0:
                raise FixtureError(f"{dataset_id}: {key} must be positive")
        if not isinstance(audio["expect_boundary_reduction"], bool):
            raise FixtureError(f"{dataset_id}: expect_boundary_reduction must be boolean")
        boundaries = audio["section_boundaries_s"]
        if (
            not isinstance(boundaries, list)
            or not boundaries
            or any(not isinstance(value, (int, float)) or value <= 0 for value in boundaries)
            or any(left >= right for left, right in zip(boundaries, boundaries[1:]))
            or boundaries[-1] >= audio["duration_s"]
        ):
            raise FixtureError(f"{dataset_id}: section_boundaries_s must be a non-empty increasing list")
    return datasets


def collect_manifest(source: Path, expectations_path: Path | None = None) -> dict:
    source = source.resolve()
    if not source.is_dir():
        raise FixtureError(f"fixture source is not a directory: {source}")
    expectations = load_expectations(expectations_path)
    datasets: dict[str, list[dict]] = {}
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            raise FixtureError(f"symlinks are not allowed in fixture bundles: {path}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise FixtureError(f"special files are not allowed in fixture bundles: {path}")
        relative = path.relative_to(source).as_posix()
        parts = validate_relative_path(relative).parts
        if len(parts) < 2:
            raise FixtureError(f"fixture files must live below a dataset directory: {relative}")
        entry = {
            "kind": media_kind(path),
            "path": relative,
            "sha256": sha256_file(path),
            "size": path.stat().st_size,
        }
        datasets.setdefault(parts[0], []).append(entry)
    if not datasets:
        raise FixtureError("fixture source contains no files")

    records = []
    canonical_lines = []
    for dataset_id, files in sorted(datasets.items()):
        audio = [entry for entry in files if entry["kind"] == "audio"]
        lyrics = [entry for entry in files if entry["kind"] == "lyrics"]
        if len(audio) != 1:
            raise FixtureError(f"{dataset_id}: expected exactly one audio file, found {len(audio)}")
        if len(lyrics) > 1:
            raise FixtureError(f"{dataset_id}: expected at most one lyrics file, found {len(lyrics)}")
        record = {"id": dataset_id, "files": files}
        if dataset_id in expectations:
            expected_audio = expectations[dataset_id]["audio"]
            expected_path = validate_relative_path(expected_audio["path"]).as_posix()
            if expected_path != audio[0]["path"]:
                raise FixtureError(
                    f"{dataset_id}: expected audio path {expected_path!r} does not match {audio[0]['path']!r}"
                )
            record["expectations"] = expectations[dataset_id]
        records.append(record)
        for entry in files:
            canonical_lines.append(f"{entry['path']}\0{entry['size']}\0{entry['sha256']}\n")

    missing = sorted(set(expectations) - set(datasets))
    if missing:
        raise FixtureError(f"expectations reference missing datasets: {', '.join(missing)}")
    tree_sha256 = hashlib.sha256("".join(canonical_lines).encode("utf-8")).hexdigest()
    return {"schema": SCHEMA, "tree_sha256": tree_sha256, "datasets": records}


def canonical_json(document: dict) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def write_archive(source: Path, archive: Path, manifest: dict) -> None:
    source = source.resolve()
    archive.parent.mkdir(parents=True, exist_ok=True)
    files = [entry for dataset in manifest["datasets"] for entry in dataset["files"]]
    directories = {PurePosixPath(ARCHIVE_ROOT)}
    for entry in files:
        current = PurePosixPath(ARCHIVE_ROOT) / validate_relative_path(entry["path"])
        directories.update(current.parents)
    with archive.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as bundle:
                for directory in sorted(directories, key=lambda item: (len(item.parts), item.as_posix())):
                    if directory == PurePosixPath("."):
                        continue
                    info = tarfile.TarInfo(directory.as_posix())
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    info.mtime = 0
                    bundle.addfile(info)
                for entry in files:
                    source_path = source / Path(*validate_relative_path(entry["path"]).parts)
                    info = tarfile.TarInfo((PurePosixPath(ARCHIVE_ROOT) / entry["path"]).as_posix())
                    info.size = entry["size"]
                    info.mode = 0o644
                    info.mtime = 0
                    with source_path.open("rb") as handle:
                        bundle.addfile(info, handle)


def load_manifest(path: Path) -> dict:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schema") != SCHEMA:
        raise FixtureError(f"fixture manifest schema must be {SCHEMA}")
    if not isinstance(document.get("datasets"), list) or not document["datasets"]:
        raise FixtureError("fixture manifest has no datasets")
    return document


def verify_tree(root: Path, manifest: dict) -> None:
    root = root.resolve()
    expected = {}
    canonical_lines = []
    for dataset in manifest["datasets"]:
        if not isinstance(dataset, dict) or not isinstance(dataset.get("id"), str):
            raise FixtureError("invalid dataset record")
        for index, entry in enumerate(dataset.get("files", [])):
            path = validate_relative_path(entry.get("path", "")).as_posix()
            digest = entry.get("sha256")
            digest_prefix = digest[:8] if isinstance(digest, str) else "unknown"
            reference = f"dataset={dataset['id']} entry={index} digest={digest_prefix}"
            if path in expected:
                raise FixtureError(f"duplicate fixture manifest entry: {reference}")
            if entry.get("kind") not in {"audio", "lyrics", "image", "other"}:
                raise FixtureError(f"invalid fixture kind: {reference}")
            if not isinstance(entry.get("size"), int) or entry["size"] < 0:
                raise FixtureError(f"invalid fixture size: {reference}")
            if not isinstance(digest, str) or len(digest) != 64:
                raise FixtureError(f"invalid fixture digest: {reference}")
            expected[path] = (entry, reference)
            canonical_lines.append(f"{path}\0{entry['size']}\0{digest}\n")
    actual_tree = hashlib.sha256("".join(canonical_lines).encode("utf-8")).hexdigest()
    if manifest.get("tree_sha256") != actual_tree:
        raise FixtureError("fixture manifest tree digest is invalid")

    actual = set()
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise FixtureError("symlink found in extracted fixtures")
        if path.is_dir():
            continue
        relative = path.relative_to(root).as_posix()
        actual.add(relative)
        expected_record = expected.get(relative)
        if expected_record is None:
            raise FixtureError("unexpected fixture file")
        entry, reference = expected_record
        if path.stat().st_size != entry["size"] or sha256_file(path) != entry["sha256"]:
            raise FixtureError(f"fixture integrity check failed: {reference}")
    missing = sorted(set(expected) - actual)
    if missing:
        references = [expected[path][1] for path in missing]
        raise FixtureError(f"fixture files are missing: {', '.join(references)}")


def extract_archive(archive: Path, destination: Path, manifest: dict) -> Path:
    if destination.exists() and any(destination.iterdir()):
        raise FixtureError("extraction destination must be empty")
    destination.mkdir(parents=True, exist_ok=True)
    seen = set()
    with tarfile.open(archive, mode="r:gz") as bundle:
        for member in bundle.getmembers():
            relative = validate_relative_path(member.name)
            if relative.parts[0] != ARCHIVE_ROOT:
                raise FixtureError(f"archive entry is outside {ARCHIVE_ROOT}/")
            if member.name in seen:
                raise FixtureError("duplicate archive entry")
            seen.add(member.name)
            target = destination / Path(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise FixtureError("archive links and special files are forbidden")
            target.parent.mkdir(parents=True, exist_ok=True)
            source = bundle.extractfile(member)
            if source is None:
                raise FixtureError("archive file has no payload")
            with source, target.open("xb") as output:
                shutil.copyfileobj(source, output)
    root = destination / ARCHIVE_ROOT
    verify_tree(root, manifest)
    return root


def fixture_digests_by_size(manifest: dict) -> dict[int, set[str]]:
    fixture_digests: dict[int, set[str]] = {}
    for dataset in manifest["datasets"]:
        for entry in dataset["files"]:
            fixture_digests.setdefault(entry["size"], set()).add(entry["sha256"])
    return fixture_digests


def assert_not_tracked(repository: Path, manifest: dict) -> None:
    repository = repository.resolve()
    result = subprocess.run(
        ["git", "-C", str(repository), "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
    )
    fixture_digests = fixture_digests_by_size(manifest)
    matches = []
    for raw in result.stdout.split(b"\0"):
        if not raw:
            continue
        relative = raw.decode("utf-8", errors="surrogateescape")
        path = repository / relative
        if not path.is_file() or path.is_symlink():
            continue
        candidates = fixture_digests.get(path.stat().st_size)
        if candidates and sha256_file(path) in candidates:
            matches.append(relative)
    if matches:
        raise FixtureError(
            "private fixture content is tracked in git: " + ", ".join(sorted(matches))
        )


def assert_not_in_history(repository: Path, manifest: dict) -> None:
    repository = repository.resolve()
    shallow = subprocess.run(
        ["git", "-C", str(repository), "rev-parse", "--is-shallow-repository"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.strip()
    if shallow != "false":
        raise FixtureError("repository history scan requires a full clone")

    objects = subprocess.run(
        ["git", "-C", str(repository), "rev-list", "--objects", "--all"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.splitlines()
    object_ids = sorted({line.split(maxsplit=1)[0] for line in objects if line})
    if not object_ids:
        return

    batch = subprocess.run(
        [
            "git",
            "-C",
            str(repository),
            "cat-file",
            "--batch-check=%(objectname) %(objecttype) %(objectsize)",
        ],
        check=True,
        input="".join(f"{object_id}\n" for object_id in object_ids),
        stdout=subprocess.PIPE,
        text=True,
    ).stdout.splitlines()
    fixture_digests = fixture_digests_by_size(manifest)
    for record in batch:
        fields = record.split()
        if len(fields) != 3 or fields[1] != "blob":
            continue
        object_id, _, raw_size = fields
        try:
            candidates = fixture_digests.get(int(raw_size))
        except ValueError as error:
            raise FixtureError("git returned an invalid object size") from error
        if not candidates:
            continue
        payload = subprocess.run(
            ["git", "-C", str(repository), "cat-file", "blob", object_id],
            check=True,
            stdout=subprocess.PIPE,
        ).stdout
        if hashlib.sha256(payload).hexdigest() in candidates:
            raise FixtureError(
                f"private fixture content exists in git history: object {object_id[:12]}"
            )


def command_create(args: argparse.Namespace) -> None:
    manifest = collect_manifest(args.source, args.expectations)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_bytes(canonical_json(manifest))
    write_archive(args.source, args.archive, manifest)
    verify_tree(args.source, manifest)
    print(manifest["tree_sha256"])


def command_verify(args: argparse.Namespace) -> None:
    manifest = load_manifest(args.manifest)
    verify_tree(args.root, manifest)
    print(manifest["tree_sha256"])


def command_extract(args: argparse.Namespace) -> None:
    manifest = load_manifest(args.manifest)
    root = extract_archive(args.archive, args.destination, manifest)
    print(root)


def command_check_repository(args: argparse.Namespace) -> None:
    manifest = load_manifest(args.manifest)
    assert_not_tracked(args.repository, manifest)
    assert_not_in_history(args.repository, manifest)
    print("private fixture content is absent from the index and reachable history")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("--source", type=Path, required=True)
    create.add_argument("--archive", type=Path, required=True)
    create.add_argument("--manifest", type=Path, required=True)
    create.add_argument("--expectations", type=Path)
    create.set_defaults(handler=command_create)
    verify = commands.add_parser("verify")
    verify.add_argument("--root", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.set_defaults(handler=command_verify)
    extract = commands.add_parser("extract")
    extract.add_argument("--archive", type=Path, required=True)
    extract.add_argument("--manifest", type=Path, required=True)
    extract.add_argument("--destination", type=Path, required=True)
    extract.set_defaults(handler=command_extract)
    repository = commands.add_parser("check-repository")
    repository.add_argument("--repository", type=Path, required=True)
    repository.add_argument("--manifest", type=Path, required=True)
    repository.set_defaults(handler=command_check_repository)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except (
        FixtureError,
        OSError,
        subprocess.CalledProcessError,
        tarfile.TarError,
        json.JSONDecodeError,
    ) as error:
        print(f"fixture bundle error: {error}", flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
