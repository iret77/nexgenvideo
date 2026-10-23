#!/usr/bin/env python3
import re
import subprocess
import sys


DYLIB_LOADS = {
    "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
    "LC_LAZY_LOAD_DYLIB", "LC_LOAD_UPWARD_DYLIB",
}
RELOCATABLE = ("@rpath/", "@loader_path/", "@executable_path/", "/usr/lib/", "/System/Library/")


def verify_load_commands(output):
    blocks = re.split(r"(?m)^Load command \d+\s*$", output)[1:]
    if not blocks:
        raise ValueError("missing Mach-O load commands")
    for block in blocks:
        commands = re.findall(r"(?m)^\s*cmd (\S+)\s*$", block)
        if len(commands) != 1:
            raise ValueError("malformed Mach-O load command")
        command = commands[0]
        if not re.fullmatch(r"LC_[A-Z0-9_]+", command):
            raise ValueError(f"unrecognized Mach-O load command: {command}")
        if command == "LC_ID_DYLIB":
            continue
        if command not in DYLIB_LOADS:
            if command.endswith("DYLIB"):
                raise ValueError(f"unsupported dylib command: {command}")
            continue
        names = re.findall(r"(?m)^\s*name (.+) \(offset \d+\)\s*$", block)
        if len(names) != 1 or not names[0].startswith(RELOCATABLE):
            raise ValueError(f"non-relocatable or malformed dependency: {names}")


def main():
    binary = sys.argv[1]
    result = subprocess.run(["otool", "-l", binary], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, check=True, timeout=30)
    try:
        verify_load_commands(result.stdout)
    except ValueError as error:
        raise SystemExit(f"{binary}: {error}") from error


if __name__ == "__main__":
    main()
