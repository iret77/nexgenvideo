#!/usr/bin/env python3
"""Combine per-pack catalog entries into the plugins.json the app fetches.

Usage: gen_plugins_json.py <entries_dir> <base_url> <output>

Reads every <entries_dir>/*.entry.json (written by assemble_ngvpack.sh), turns
each pack's `zip` filename into a download `url` under <base_url> (the release's
asset base, e.g. https://github.com/<repo>/releases/download/dev-latest) and, when
present, its `badge` filename into a `badge` URL under the same base, then writes
{"schema": "plugins/v1", "plugins": [...]} — the shape PluginCatalog decodes.
"""
import glob
import json
import os
import sys

entries_dir, base_url, out = sys.argv[1], sys.argv[2], sys.argv[3]
base = base_url.rstrip("/")
plugins = []
for path in sorted(glob.glob(os.path.join(entries_dir, "*.entry.json"))):
    entry = json.load(open(path))
    zip_name = entry.pop("zip")
    entry["url"] = f"{base}/{zip_name}"
    badge_name = entry.pop("badge", None)
    if badge_name:
        entry["badge"] = f"{base}/{badge_name}"
    plugins.append(entry)

with open(out, "w") as f:
    json.dump({"schema": "plugins/v1", "plugins": plugins}, f, indent=2)
    f.write("\n")
print(f"wrote {out} with {len(plugins)} plugin(s)")
