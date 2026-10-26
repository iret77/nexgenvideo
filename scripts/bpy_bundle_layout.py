import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile


def inventory(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError("missing sealed runtime directory")
    entries = {}
    paths = []
    def fail(error):
        raise error
    for directory, directories, files in os.walk(root, onerror=fail, followlinks=False):
        paths.extend(Path(directory) / name for name in directories + files)
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix()
        info = path.lstat()
        item = {"mode": stat.S_IMODE(info.st_mode)}
        if path.is_symlink():
            target = os.readlink(path)
            if not path.resolve(strict=True).is_relative_to(root.resolve()):
                raise ValueError("runtime symlink escapes its service")
            item.update(kind="symlink", target=target)
        elif path.is_dir():
            item.update(kind="directory")
        elif path.is_file():
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            item.update(kind="file", size=info.st_size, sha256=digest.hexdigest())
        else:
            raise ValueError("unsupported runtime entry")
        entries[relative] = item
    if not entries:
        raise ValueError("empty runtime")
    return entries


def inside_app(app, relative):
    current = app
    for component in Path(relative).parts:
        current = current / component
        if current.is_symlink():
            raise ValueError("bundle ancestor is a symlink")
    return current


def paired(app):
    for old in ["Contents/Resources/BpyRuntime", "Contents/Helpers/NexGenVideoBpySupervisor"]:
        if os.path.lexists(app / old):
            raise ValueError("legacy runtime outside the service bundle")
    entries = [inventory(inside_app(app, f"Contents/XPCServices/NexGenVideoBpyService{slot}.xpc/Contents/Resources/BpyRuntime"))
               for slot in range(2)]
    if entries[0] != entries[1]:
        raise ValueError("service runtime copies differ")
    return {"schema": "nexgenvideo/bpy-bundle-runtime/1", "slots": [0, 1], "entries": entries[0]}


def seal(app):
    actual = paired(app)
    path = inside_app(app, "Contents/Resources/BpyRuntimeCompliance/runtime-tree-manifest.json")
    payload = json.dumps(actual, sort_keys=True, separators=(",", ":")) + "\n"
    descriptor, name = tempfile.mkstemp(prefix=".runtime-tree-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def verify(app):
    path = inside_app(app, "Contents/Resources/BpyRuntimeCompliance/runtime-tree-manifest.json")
    if json.loads(path.read_text()) != paired(app):
        raise ValueError("runtime differs from the app-sealed inventory")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["compare", "seal", "verify"])
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    if args.mode == "seal":
        seal(args.app)
    elif args.mode == "verify":
        verify(args.app)
    else:
        paired(args.app)


if __name__ == "__main__":
    main()
