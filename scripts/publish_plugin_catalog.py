#!/usr/bin/env python3
"""Merge freshly built pack entries into the stable, multi-version plugin catalog.

Usage: publish_plugin_catalog.py <entries_dir> <base_url> <output> [--existing <catalog.json>]

Reads every <entries_dir>/*.entry.json (written by assemble_ngvpack.sh), stages each
pack's zip/badge under a VERSION-STAMPED asset name (`<id>-<version>.ngvpack.zip`) so a
published version's URL always addresses that exact version, and merges the result into
the catalog already published on the channel (--existing).

Merge rules:
  * a version not yet in the catalog is APPENDED — older versions are never dropped, so an
    older app still finds its last compatible pack (the app picks the newest whose
    minAppVersion <= its own; see PluginManager.selectCompatiblePerPack).
  * a rebuild of a version already published REPLACES that one entry (signatures are
    timestamped, so the same pack version rebuilds to a different sha). Loud, never silent.

Writes {"schema": "plugins/v2", "plugins": [...]} — the shape PluginCatalog decodes. v2 is
v1 plus the promise that MULTIPLE versions per pack id may be listed.
"""
import argparse
import glob
import json
import os
import shutil

parser = argparse.ArgumentParser()
parser.add_argument("entries_dir")
parser.add_argument("base_url", help="asset base of the plugin channel release")
parser.add_argument("output")
parser.add_argument("--existing", help="catalog.json currently published on the channel")
args = parser.parse_args()

base = args.base_url.rstrip("/")


def key(entry):
    return entry["id"], entry["version"]


published = {}
if args.existing and os.path.exists(args.existing):
    for entry in json.load(open(args.existing)).get("plugins", []):
        published[key(entry)] = entry
    print(f"==> channel has {len(published)} published pack version(s)")

for path in sorted(glob.glob(os.path.join(args.entries_dir, "*.entry.json"))):
    entry = json.load(open(path))
    stem = f"{entry['id']}-{entry['version']}"

    zip_name = entry.pop("zip")
    asset = f"{stem}.ngvpack.zip"
    shutil.copyfile(os.path.join(args.entries_dir, zip_name), os.path.join(args.entries_dir, asset))
    entry["url"] = f"{base}/{asset}"

    badge_name = entry.pop("badge", None)
    if badge_name:
        badge_asset = f"{stem}.badge.png"
        shutil.copyfile(os.path.join(args.entries_dir, badge_name), os.path.join(args.entries_dir, badge_asset))
        entry["badge"] = f"{base}/{badge_asset}"

    prior = published.get(key(entry))
    if prior is None:
        print(f"==> publishing {stem} (new version)")
    elif prior.get("sha256") != entry.get("sha256"):
        print(f"==> REPUBLISHING {stem} — rebuilt, sha {prior.get('sha256', '?')[:12]} -> {entry['sha256'][:12]}")
    else:
        print(f"==> {stem} unchanged")
    published[key(entry)] = entry

# Newest version first per pack, so the catalog reads in the order the app resolves it.
def sort_key(entry):
    parts = [int(p) if p.isdigit() else 0 for p in entry["version"].split(".")[:3]]
    parts += [0] * (3 - len(parts))
    return (entry["id"], [-p for p in parts])


plugins = sorted(published.values(), key=sort_key)
with open(args.output, "w") as f:
    json.dump({"schema": "plugins/v2", "plugins": plugins}, f, indent=2)
    f.write("\n")

versions = ", ".join(f"{e['id']}@{e['version']}" for e in plugins)
print(f"wrote {args.output} with {len(plugins)} pack version(s): {versions}")
