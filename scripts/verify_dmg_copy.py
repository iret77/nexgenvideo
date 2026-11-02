import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
import stat
import os

from release_checkpoint import NATIVE_TIMEOUT, tree_digest
from retained_app_test_products import checksum, require


def command(*args):
    subprocess.run(args, stdin=subprocess.DEVNULL, check=True, timeout=NATIVE_TIMEOUT)


def detach(directory):
    for attempt in range(5):
        try:
            command("hdiutil", "detach", directory)
            return
        except subprocess.CalledProcessError:
            time.sleep(min(0.25 * 2**attempt, 4))
    command("hdiutil", "detach", "-force", directory)


def tree_entries(root):
    result = {}
    for path in [root, *sorted(root.rglob("*"))]:
        if not path.exists() and not path.is_symlink():
            continue
        entry = {"mode": stat.S_IMODE(path.lstat().st_mode)}
        if path.is_symlink():
            entry.update(kind="symlink", target=os.readlink(path))
        elif path.is_file():
            entry.update(kind="file", bytes=path.stat().st_size, sha256=checksum(path))
        else:
            entry.update(kind="directory")
        result[path.relative_to(root).as_posix()] = entry
    return result


def differences(app, mounted):
    source, copy = tree_entries(app), tree_entries(mounted)
    return [{"path": name, "source": source.get(name), "mounted": copy.get(name)}
            for name in sorted(source.keys() | copy.keys()) if source.get(name) != copy.get(name)][:50]


def verify(app, dmg):
    durations = {}
    def run(stage, *args):
        start = time.monotonic()
        try:
            command(*args)
        finally:
            durations[stage] = time.monotonic() - start
            print(json.dumps({"stage": stage, "seconds": durations[stage]}), flush=True)
    require(app.is_dir() and dmg.is_file(), "Missing DMG or source App")
    run("sourceSignature", "codesign", "--verify", "--deep", "--strict", "--verbose=3", str(app))
    start = time.monotonic()
    expected = tree_digest(app)
    durations["sourceTree"] = time.monotonic() - start
    run("imageVerify", "hdiutil", "verify", str(dmg))
    with tempfile.TemporaryDirectory() as directory:
        run("attach", "hdiutil", "attach", str(dmg), "-nobrowse", "-readonly", "-mountpoint", directory)
        try:
            mounted = Path(directory) / app.name
            start = time.monotonic()
            matches = mounted.is_dir() and tree_digest(mounted) == expected
            durations["mountedTree"] = time.monotonic() - start
            require(matches, "DMG App differs: " + json.dumps(differences(app, mounted) if not matches else []))
            volume = Path(directory)
            inventory = [{"name": item.name, "kind": "symlink" if item.is_symlink() else
                          "file" if item.is_file() else "directory",
                          "target": os.readlink(item) if item.is_symlink() else None}
                         for item in sorted(volume.iterdir())]
            require((volume / ".DS_Store").is_file() and not (volume / ".DS_Store").is_symlink()
                    and any(p.is_file() and not p.is_symlink() for p in volume.glob(".background.*"))
                    and (volume / "Applications").is_symlink()
                    and os.readlink(volume / "Applications") == "/Applications", "Missing DMG installer branding")
            run("mountedSignature", "codesign", "--verify", "--deep", "--strict", "--verbose=3", str(mounted))
        finally:
            start = time.monotonic()
            detach(directory)
            durations["detach"] = time.monotonic() - start
    return {"schema": "release-dmg-copy/v1", "sourceAppTreeSHA256": expected,
            "mountedAppTreeSHA256": expected, "deepSignaturesVerified": True,
            "volumeInventory": inventory, "volumeIconPresent": any(i["name"] == ".VolumeIcon.icns" for i in inventory),
            "phaseSeconds": durations}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("app", type=Path)
    parser.add_argument("dmg", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.app, args.dmg), sort_keys=True))
