"""Native Settings acceptance with local transports and real, supplied pack ZIPs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import zipfile


def pack_metadata(path):
    path = path.resolve(strict=True)
    with zipfile.ZipFile(path) as archive:
        candidates = [name for name in archive.namelist()
                      if name.endswith(".ngvpack/Contents/Info.plist") and not name.startswith("__MACOSX/")]
        if len(candidates) != 1:
            raise ValueError("The pack ZIP must contain exactly one real bundle Info.plist")
        info_bytes = archive.read(candidates[0])
    info = plistlib.loads(info_bytes)
    return {
        "id": info["NGVPackID"], "displayName": info["NGVPackDisplayName"],
        "zipPath": str(path), "version": info["CFBundleShortVersionString"],
        "projectSchema": info["NGVProjectSchema"], "minAppVersion": info["NGVMinAppVersion"],
        "migratesFrom": info.get("NGVMigratesFrom", []),
        "engineContract": info["NGVEngineContract"],
        "infoSHA256": hashlib.sha256(info_bytes).hexdigest(),
    }


def validate_result(output, isolated_home, baseline, target, scale):
    result = json.loads((output / "settings-owner-result.json").read_text())
    driver = result["driver"]
    progress = json.loads((output / driver["progress"]).read_text())
    if progress.get("failure") is not None or progress["interactions"] != driver["interactions"]:
        raise AssertionError("The actual native progress log disagrees with the final result")
    interactions = progress["interactions"]
    pointers = [row for row in interactions if row.get("kind") == "pointer"]
    clicked = {row["id"] for row in pointers}
    required = {
        "settings.tab.general", "settings.tab.providers", "settings.tab.models", "settings.tab.agent",
        "settings.tab.storage", "settings.tab.plugins", "settings.general.notifications", "settings.general.telemetry",
        "settings.providers.raw", "settings.provider.key.fal", "settings.provider.save.fal", "settings.provider.remove.fal",
        "settings.models.enabled.fal-ai/qwen-image", "settings.models.search", "settings.research.accept",
        "settings.research.decline",
        "settings.research.cancel", "settings.agent.backend", "settings.agent.key", "settings.agent.key.save",
        "settings.agent.key.remove", "settings.agent.mcp", "settings.mcp.add", "settings.mcp.name",
        "settings.mcp.connection", "settings.mcp.cancel", "settings.mcp.save", "settings.mcp.edit.fixture",
        "settings.mcp.remove.renamed-fixture", "settings.storage.folder.choose", "settings.storage.folder.reset",
        "settings.storage.search", "settings.storage.cache.clear", "settings.storage.index.clear",
        "settings.storage.model.remove", "settings.pack.update." + baseline["id"],
        "settings.pack.remove." + baseline["id"] + "@" + baseline["version"],
        "settings.pack.removal.cancel", "settings.pack.removal.confirm",
    }
    if missing := required - clicked:
        raise AssertionError("Missing native pointer inputs: " + ", ".join(sorted(missing)))
    for row in pointers:
        frame = row.get("frame", [])
        if len(frame) != 4 or min(frame[2:]) <= 0 or not row.get("hitClass") or not row.get("window"):
            raise AssertionError("A pointer observation has no real native target")
    for prefix in ("settings.research.start.", "settings.research.disable.", "settings.research.enable.",
                   "settings.research.archive.", "settings.research.update.", "settings.research.delete.", "settings.provider.signin.", "settings.provider.local."):
        if not any(value.startswith(prefix) for value in clicked):
            raise AssertionError("Missing actual control: " + prefix)
    menus = [row for row in interactions if row.get("kind") in ("menu", "menu-selection")]
    if not menus:
        raise AssertionError("No actual native scale menu was selected")
    dialogs = {row.get("evidence", {}).get("title") for row in interactions
               if row.get("kind") == "verified-state" and row.get("label") == "native-dialog-pointer"}
    if not {"Cancel", "Trust and Save", "Delete specifications", "Remove “renamed-fixture”"}.issubset(dialogs):
        raise AssertionError("Native confirmation/cancellation is missing")
    if not any(row.get("kind") == "keyboard" and row.get("code") == 48 for row in interactions):
        raise AssertionError("No actual keyboard commit input was posted")
    if not any(row.get("kind") == "file-panel-cancel" for row in interactions):
        raise AssertionError("No native folder-panel cancellation was observed")
    screenshots = progress["screenshots"]
    if len(screenshots) < 8 or len(set(screenshots)) != len(screenshots):
        raise AssertionError("Incomplete native Settings screenshots")
    for name in screenshots:
        if Path(name).name != name:
            raise AssertionError("Screenshot escaped its evidence directory")
        raw = (output / name).read_bytes()
        if len(raw) < 2048 or raw[:8] != b"\x89PNG\r\n\x1a\n":
            raise AssertionError("Missing actual window PNG")
        width, height = struct.unpack(">II", raw[16:24])
        if not any(label in name for label in ("file-panel", "file-selected")) and (width < 900 or height < 600):
            raise AssertionError("The actual native window was smaller than the acceptance viewport")
    installs = list(isolated_home.rglob(target["version"] + ".ngvpack/Contents/Info.plist"))
    if len(installs) != 1 or hashlib.sha256(installs[0].read_bytes()).hexdigest() != target["infoSHA256"]:
        raise AssertionError("The actual target pack bytes were not retained in the isolated install")
    if list(isolated_home.rglob(baseline["version"] + ".ngvpack/Contents/Info.plist")):
        raise AssertionError("The selected baseline version was not actually removed")
    pinned = json.loads((output / ("settings-owner-" + str(round(scale * 100))) / "Pinned original format.ngv/ngv.json").read_text())
    if (pinned.get("activePlugin") != baseline["id"] or pinned.get("activePluginVersion") != baseline["version"]
            or pinned.get("activePluginProjectSchema") != baseline["projectSchema"]):
        raise AssertionError("The original exact project pin changed")
    if result.get("scale") != scale or result.get("realCredentials") is not False or result.get("realNetworkRequests") != 0:
        raise AssertionError("The native result does not declare its isolation limits")
    return {"scale": scale, "pointerInputs": len(pointers), "screenshots": len(screenshots),
            "actualPackInfoSHA256": target["infoSHA256"], "recoveryUpgrade": "pending separate native project flow"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-pack-zip", type=Path, required=True)
    parser.add_argument("--target-pack-zip", type=Path, required=True)
    parser.add_argument("--scale", type=float, choices=(1, 1.25, 1.5), action="append")
    args = parser.parse_args()
    baseline, target = pack_metadata(args.baseline_pack_zip), pack_metadata(args.target_pack_zip)
    if baseline["id"] != target["id"]:
        raise ValueError("The two actual pack artifacts must share their ID")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for scale in args.scale or (1.0, 1.25, 1.5):
        run = output / ("scale-" + str(round(scale * 100)))
        run.mkdir(exist_ok=False)
        home = run / "isolated-user"
        home.mkdir()
        manifest = run / "pack-fixtures.json"
        manifest.write_text(json.dumps({"id": baseline["id"], "displayName": baseline["displayName"],
                                       "baseline": baseline, "target": target}, indent=2))
        safe_keys = {"PATH", "TMPDIR", "LANG", "LC_ALL", "__CF_USER_TEXT_ENCODING", "DISPLAY", "TERM"}
        env = {key: value for key, value in os.environ.items() if key in safe_keys}
        env.update({"CFFIXED_USER_HOME": str(home), "NGV_SETTINGS_OWNER_ACCEPTANCE": "1",
                    "NGV_WORKSPACE_UI_ACCEPTANCE": "1", "NGV_SETTINGS_OWNER_EVIDENCE": str(run),
                    "NGV_SETTINGS_OWNER_SCALE": str(scale), "NGV_SETTINGS_PACK_FIXTURE": str(manifest)})
        with (run / "settings.log").open("w") as log:
            process = subprocess.run([str(args.executable.resolve(strict=True)), "-ApplePersistenceIgnoreState", "YES",
                                      "-interfaceTextScale", str(scale)], env=env, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=subprocess.STDOUT, timeout=360, check=False)
        if process.returncode:
            raise RuntimeError("The native Settings process failed; inspect " + str(run / "settings.log"))
        results.append(validate_result(run, home, baseline, target, scale))
    (output / "settings-owner-validation.json").write_text(json.dumps({"nativeSettings": results}, indent=2))


if __name__ == "__main__":
    main()
