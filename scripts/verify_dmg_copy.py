import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from release_checkpoint import tree_digest
from retained_app_test_products import require


def command(*args):
    subprocess.run(args, stdin=subprocess.DEVNULL, check=True, timeout=180)


def verify(app, dmg):
    require(app.is_dir() and dmg.is_file(), "Missing DMG or source App")
    command("codesign", "--verify", "--deep", "--strict", "--verbose=3", str(app))
    expected = tree_digest(app)
    command("hdiutil", "verify", str(dmg))
    with tempfile.TemporaryDirectory() as directory:
        command("hdiutil", "attach", str(dmg), "-nobrowse", "-readonly", "-mountpoint", directory)
        try:
            mounted = Path(directory) / app.name
            require(mounted.is_dir() and tree_digest(mounted) == expected,
                    "DMG App differs from the complete signed source App")
            command("codesign", "--verify", "--deep", "--strict", "--verbose=3", str(mounted))
        finally:
            command("hdiutil", "detach", directory)
    return {"schema": "release-dmg-copy/v1", "sourceAppTreeSHA256": expected,
            "mountedAppTreeSHA256": expected, "deepSignaturesVerified": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("app", type=Path)
    parser.add_argument("dmg", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.app, args.dmg), sort_keys=True))
