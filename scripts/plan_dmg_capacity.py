import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from release_checkpoint import NATIVE_TIMEOUT, tree_digest
from retained_app_test_products import require, write
from verify_dmg_copy import detach


RESERVE = 128 * 1024**2
MIN_GROWTH = 1024**2
MAX_MEASUREMENTS = 8


def measure(sectors):
    with tempfile.TemporaryDirectory(prefix="ngv-dmg-capacity-") as directory:
        image = Path(directory) / "capacity.dmg"
        mount = Path(directory) / "mounted"
        mount.mkdir()
        subprocess.run(["hdiutil", "create", "-volname", "NexGenVideo-capacity", "-fs", "APFS",
                        "-fsargs", "", "-size", str(sectors) + "b", str(image)],
                       stdin=subprocess.DEVNULL, check=True, timeout=NATIVE_TIMEOUT)
        subprocess.run(["hdiutil", "attach", str(image), "-nobrowse", "-owners", "off", "-mountpoint", str(mount)],
                       stdin=subprocess.DEVNULL, check=True, timeout=NATIVE_TIMEOUT)
        try:
            space = os.statvfs(mount)
            return {"freeBytes": space.f_bavail * space.f_frsize, "totalBytes": space.f_blocks * space.f_frsize,
                    "blockBytes": space.f_frsize, "imageBytes": image.stat().st_size}
        finally:
            detach(str(mount))


def plan(app, pack=None, guide=None):
    require(app.is_dir(), "Missing signed App for DMG sizing")
    require(pack is None or pack.is_dir() and not pack.is_symlink() and pack.suffix == '.ngvpack',
            "Missing external format pack for joint DMG sizing")
    require((pack is None and guide is None) or (pack is not None and guide is not None
            and guide.is_file() and not guide.is_symlink()), "Joint DMG requires its installation guide")
    roots = [app] + ([pack, guide] if pack is not None else [])
    payload = sum(max(path.lstat().st_blocks * 512, (path.lstat().st_size + 4095) // 4096 * 4096)
                  for root in roots for path in [root, *root.rglob("*")]) + 4096
    required = payload + RESERVE
    sectors = (required + 511) // 512
    attempts = []
    for _ in range(MAX_MEASUREMENTS):
        observed = measure(sectors)
        require(all(type(observed.get(name)) is int for name in ("freeBytes", "totalBytes", "blockBytes", "imageBytes"))
                and observed["blockBytes"] > 0 and observed["imageBytes"] > 0
                and 0 <= observed["freeBytes"] <= observed["totalBytes"] <= observed["imageBytes"],
                "Invalid DMG capacity measurement")
        attempts.append(dict(observed, requestedSectors=sectors))
        print(json.dumps({"stage": "DMG capacity", "requiredFreeBytes": required, **attempts[-1]}), flush=True)
        if observed["freeBytes"] >= required:
            return {"schema": "release-dmg-capacity-plan/v2" if pack is not None else "release-dmg-capacity-plan/v1", "appPath": str(app.resolve()),
                    "packPath": str(pack.resolve()) if pack is not None else None,
                    "packTreeSHA256": tree_digest(pack) if pack is not None else None,
                    "guidePath": str(guide.resolve()) if guide is not None else None,
                    "guideSHA256": hashlib.sha256(guide.read_bytes()).hexdigest() if guide is not None else None,
                    "capacityVerified": True, "payloadBytes": payload, "reserveBytes": RESERVE,
                    "requiredFreeBytes": required, "imageSizeSectors": sectors, "attempts": attempts}
        blocks = (max(required - observed["freeBytes"], MIN_GROWTH) + observed["blockBytes"] - 1) // observed["blockBytes"]
        growth = blocks * observed["blockBytes"]
        sectors += (growth + 511) // 512
    raise ValueError("DMG capacity did not reach the complete payload plus reserve: " + json.dumps(attempts))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--pack", type=Path)
    parser.add_argument("--guide", type=Path)
    args = parser.parse_args()
    result = plan(args.app, args.pack, args.guide)
    write(args.output, result)
    print(json.dumps(result, sort_keys=True), flush=True)
