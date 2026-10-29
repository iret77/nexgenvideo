import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCK_FIELDS = ("schema", "platform", "pythonABI", "runtime", "wheels",
               "bpyWheelLayout", "pythonBuildInputs")
PRODUCER_FILES = (
    ".github/workflows/bpy-source-closure.yml",
    "scripts/stage_bpy_runtime.sh",
    "scripts/collect_bpy_binary_evidence.py",
    "scripts/verify_bpy_binary_evidence.py",
    "scripts/verify_bpy_runtime.py",
    "scripts/verify_bpy_library_evidence.py",
    "scripts/bpy_binary_inputs.py",
)


def runtime_inputs(root=ROOT):
    lock = json.loads((root / "Runtime/bpy/runtime-lock.json").read_text())
    paths = set(PRODUCER_FILES)
    paths.update(item["path"] for item in lock["bpyWheelLayout"]["officialLibraryEvidence"].values())
    files = {}
    for relative in sorted(paths):
        path = root / relative
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("Binary producer input is not a regular repository file")
        files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    value = {"schema": "nexgenvideo/bpy-binary-inputs/1",
             "lock": {key: lock[key] for key in LOCK_FIELDS}, "files": files}
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


if __name__ == "__main__":
    print(runtime_inputs())
