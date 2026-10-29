"""Select a real published baseline and package the unchanged CI target bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from settings_owner_acceptance import pack_metadata


STABLE_PROFILE = "stable-compatible"
PREVIEW_PROFILE = "known-preview172-approved-resume"
PREVIEW_RELEASE = "preview-39124049687"
PREVIEW_COMMIT = "0b4a4e311d17c6c0673cbebd70b2c8d57531fa65"
PREVIEW_SHA256 = "99db97945144934e1d948f487826f401018b9de689df1e43265647712c68a6de"
STABLE_058_SHA256 = "201bcc7c300e5307338e4a020c782f914426925b85c5c9a0dfafea9956c66478"
BASELINE_PATTERN = re.compile(r"^musicvideo-(\d+\.\d+\.\d+)\.ngvpack\.zip$")


def command(arguments):
    return subprocess.run(arguments, stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, check=True, timeout=90).stdout


def version(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("The actual pack has an invalid version")
    return tuple(map(int, value.split(".")))


def baseline_assets(release, target_version, profile=STABLE_PROFILE, requested_version=None):
    if profile not in {STABLE_PROFILE, PREVIEW_PROFILE}:
        raise ValueError("Unknown actual baseline profile")
    tag = PREVIEW_RELEASE if profile == PREVIEW_PROFILE else "plugins"
    if release.get("tag_name") != tag:
        raise ValueError("The baseline came from a different release")
    if requested_version is not None:
        version(requested_version)
    if profile == PREVIEW_PROFILE:
        if requested_version not in (None, "0.5.16"):
            raise ValueError("The known 1.7.2 preview requires its original 0.5.16 pack")
        requested_version = "0.5.16"
    candidates = []
    for asset in release.get("assets", []):
        parsed = BASELINE_PATTERN.fullmatch(asset.get("name", ""))
        if (parsed and version(parsed.group(1)) < version(target_version)
                and (requested_version is None or parsed.group(1) == requested_version)):
            candidates.append(asset)
    if requested_version is not None and len(candidates) != 1:
        raise ValueError("The exact baseline release asset is missing or ambiguous")
    return sorted(candidates, key=lambda item: (
        version(BASELINE_PATTERN.fullmatch(item["name"]).group(1)), item.get("created_at", "")), reverse=True)


def require_baseline(profile, baseline, archive_sha256):
    if profile == PREVIEW_PROFILE:
        expected = {"id": "musicvideo", "version": "0.5.16", "projectSchema": "musicvideo/2.0.0",
                    "minAppVersion": "1.7.2", "engineContract": 11}
        if any(baseline.get(key) != value for key, value in expected.items()) or archive_sha256 != PREVIEW_SHA256:
            raise ValueError("The known preview baseline is not the exact released 1.7.2 pack")
    elif profile == STABLE_PROFILE:
        if baseline.get("version") == "0.5.8" and archive_sha256 != STABLE_058_SHA256:
            raise ValueError("The original stable 0.5.8 pack bytes changed")
    else:
        raise ValueError("Unknown actual baseline profile")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--current-pack", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    parser.add_argument("--baseline-profile", choices=(STABLE_PROFILE, PREVIEW_PROFILE), default=STABLE_PROFILE)
    parser.add_argument("--baseline-version")
    args = parser.parse_args()
    bundle = args.current_pack.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    target_zip = output / "current.ngvpack.zip"
    command(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(bundle), str(target_zip)])
    target = pack_metadata(target_zip)
    manifest = json.loads((Path(__file__).resolve().parents[1] / "plugins/musicvideo.json").read_text())
    if (target["id"] != "musicvideo" or target["projectSchema"] != "musicvideo/3.0.0"
            or any(target[key] != manifest[key] for key in ("id", "version", "projectSchema", "minAppVersion", "migratesFrom"))):
        raise ValueError("The actual CI target does not match the current Musicvideo source declaration")
    contract_file = Path(__file__).resolve().parents[1] / "Engine/Sources/NexGenEngine/Packs/EngineContract.swift"
    match = re.search(r"public static let minimumCompatible = (\d+)", contract_file.read_text())
    if not match:
        raise ValueError("The source has no explicit minimum pack contract")
    minimum_contract = int(match.group(1))
    tag = PREVIEW_RELEASE if args.baseline_profile == PREVIEW_PROFILE else "plugins"
    release = json.loads(command(["gh", "api", "repos/iret77/nexgenvideo/releases/tags/" + tag]))
    source_commit = None
    if args.baseline_profile == PREVIEW_PROFILE:
        ref = json.loads(command(["gh", "api", "repos/iret77/nexgenvideo/git/ref/tags/" + tag]))
        if ref.get("object", {}).get("type") != "commit" or ref["object"].get("sha") != PREVIEW_COMMIT:
            raise ValueError("The original 1.7.2 preview source tag changed")
        source_commit = PREVIEW_COMMIT
    for asset in baseline_assets(release, target["version"], args.baseline_profile, args.baseline_version):
        name = asset["name"]
        expected = asset.get("digest", "")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", expected):
            raise ValueError("The published baseline has no GitHub exact-byte digest")
        command(["gh", "release", "download", tag, "--repo", "iret77/nexgenvideo",
                 "--pattern", name, "--dir", str(output)])
        archive = output / name
        archive_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
        if "sha256:" + archive_sha256 != expected:
            raise ValueError("The actual published pack digest does not match GitHub")
        baseline = pack_metadata(archive)
        if baseline["id"] != target["id"] or baseline["version"] != BASELINE_PATTERN.fullmatch(name).group(1):
            raise ValueError("Published filename and actual pack metadata disagree")
        require_baseline(args.baseline_profile, baseline, archive_sha256)
        if (minimum_contract <= baseline["engineContract"] <= target["engineContract"]
                and baseline["projectSchema"] in target["migratesFrom"]):
            evidence = {"schema": "actual-settings-pack-pair/v1", "baseline": baseline, "target": target,
                        "publishedBaselineSHA256": expected, "rewrittenBundleMetadata": False,
                        "baselineProfile": args.baseline_profile,
                        "targetArchiveSHA256": hashlib.sha256(target_zip.read_bytes()).hexdigest(),
                        "publishedBaseline": {"repository": "iret77/nexgenvideo", "releaseTag": tag,
                            "releaseID": release["id"], "assetID": asset["id"], "assetName": name,
                            "digest": expected, "sourceCommit": source_commit}}
            (output / "pack-pair.json").write_text(json.dumps(evidence, indent=2))
            with args.github_output.open("a") as stream:
                stream.write("baseline=" + str(archive) + "\n")
                stream.write("target=" + str(target_zip) + "\n")
            return
    raise ValueError("No actual published compatible baseline has a declared migration to the CI target; no substitute was generated")


if __name__ == "__main__":
    main()
