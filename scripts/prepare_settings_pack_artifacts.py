"""Select a real published baseline and package the unchanged CI target bundle."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from settings_owner_acceptance import pack_metadata


def command(arguments):
    return subprocess.run(arguments, stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, check=True, timeout=90).stdout


def version(value):
    if not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise ValueError("The actual pack has an invalid version")
    return tuple(map(int, value.split(".")))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--current-pack", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--github-output", type=Path, required=True)
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
    release = json.loads(command(["gh", "api", "repos/iret77/nexgenvideo/releases/tags/plugins"]))
    pattern = re.compile(r"^musicvideo-(\d+\.\d+\.\d+)\.ngvpack\.zip$")
    candidates = []
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        parsed = pattern.fullmatch(name)
        if parsed and version(parsed.group(1)) < version(target["version"]):
            candidates.append((version(parsed.group(1)), asset.get("created_at", ""), asset))
    for _, _, asset in sorted(candidates, key=lambda row: (row[0], row[1]), reverse=True):
        name = asset["name"]
        expected = asset.get("digest", "")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", expected):
            raise ValueError("The published baseline has no GitHub exact-byte digest")
        command(["gh", "release", "download", "plugins", "--repo", "iret77/nexgenvideo",
                 "--pattern", name, "--dir", str(output)])
        archive = output / name
        if "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            raise ValueError("The actual published pack digest does not match GitHub")
        baseline = pack_metadata(archive)
        if baseline["id"] != target["id"] or baseline["version"] != pattern.fullmatch(name).group(1):
            raise ValueError("Published filename and actual pack metadata disagree")
        if (minimum_contract <= baseline["engineContract"] <= target["engineContract"]
                and baseline["projectSchema"] in target["migratesFrom"]):
            evidence = {"schema": "actual-settings-pack-pair/v1", "baseline": baseline, "target": target,
                        "publishedBaselineSHA256": expected, "rewrittenBundleMetadata": False}
            (output / "pack-pair.json").write_text(json.dumps(evidence, indent=2))
            with args.github_output.open("a") as stream:
                stream.write("baseline=" + str(archive) + "\n")
                stream.write("target=" + str(target_zip) + "\n")
            return
    raise ValueError("No actual published compatible baseline has a declared migration to the CI target; no substitute was generated")


if __name__ == "__main__":
    main()
