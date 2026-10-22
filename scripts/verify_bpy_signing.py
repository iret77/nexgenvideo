#!/usr/bin/env python3
import argparse
import plistlib
import re
import subprocess
from pathlib import Path


SANDBOX = "com.apple.security.app-sandbox"
INHERIT = "com.apple.security.inherit"


def details(path):
    result = subprocess.run(["codesign", "-d", "--verbose=4", str(path)],
                            stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=20)
    return result.stderr.decode("utf-8", errors="strict")


def require_identity(value, team):
    if not re.search(r"^Authority=Developer ID Application: .+", value, re.M) \
            or f"TeamIdentifier={team}\n" not in value \
            or not re.search(r"flags=0x[0-9a-fA-F]+\([^\n]*\bruntime\b", value):
        raise ValueError("runtime code must use the host's Developer ID team and hardened runtime")


def require_entitlements(actual, expected):
    if actual != expected:
        raise ValueError(f"runtime entitlement mismatch: expected {sorted(expected)}, got {sorted(actual)}")


def entitlements(path):
    result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(path)],
                            stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=20)
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


def validate(app, development=False):
    host = details(app)
    team_match = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", host, re.M)
    team = team_match.group(1) if team_match else ""
    if not development:
        if not team:
            raise ValueError("the host has no Developer ID team")
        require_identity(host, team)
    runtime = app / "Contents/Resources/BpyRuntime"
    supervisor = app / "Contents/Helpers/NexGenVideoBpySupervisor"
    storage = app / "Contents/Helpers/NexGenVideoBpyStorage"
    expected = {runtime / "python/bin/python3.13": {SANDBOX: True, INHERIT: True},
                supervisor: {SANDBOX: True, INHERIT: True}, storage: {}}
    for slot in range(2):
        service = app / f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc"
        expected[service] = {SANDBOX: True}
        expected[service / "Contents/MacOS/NexGenVideoBpyService"] = {SANDBOX: True}
    for path, wanted in expected.items():
        require_entitlements(entitlements(path), wanted)
        if not development:
            require_identity(details(path), team)
    if not development:
        for path in runtime.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            kind = subprocess.run(["file", "--brief", str(path)], stdin=subprocess.DEVNULL,
                                  capture_output=True, check=True, timeout=20).stdout
            if b"Mach-O" in kind:
                require_identity(details(path), team)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    validate(args.app, args.development)
    print("managed bpy signing authority and isolation entitlements verified")


if __name__ == "__main__":
    main()
