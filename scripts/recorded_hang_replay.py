#!/usr/bin/env python3
"""Replay authenticated private inputs; publish only counts and encrypted evidence."""
import base64
import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import zipfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("fixture", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--match-geometry", action="store_true")
    args = parser.parse_args()
    app, fixture, output = args.app, args.fixture, args.output
    output.mkdir(parents=True, exist_ok=True)
    key = base64.b64decode(os.environ["NGV_HANG_FIXTURE_KEY"], validate=True)
    encrypted = fixture.read_bytes()
    plain = AESGCM(key).decrypt(encrypted[:12], encrypted[12:], b"NGV_HANG_FIXTURE_V1")
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        with zipfile.ZipFile(io.BytesIO(plain)) as archive:
            for entry in archive.infolist():
                target = root / entry.filename
                if not target.resolve().is_relative_to(root.resolve()):
                    raise ValueError("fixture path escapes temporary directory")
            archive.extractall(root)
        folder, = [p for p in root.iterdir() if p.is_dir()]
        frames = sorted(folder.glob("replay-*.enc"))
        replay_key = base64.b64decode((root / "replay.key").read_text(), validate=True)
        decoded = []
        for file in frames:
            data = file.read_bytes()
            decoded.append(json.loads(AESGCM(replay_key).decrypt(data[:12], data[12:], folder.name.encode())))
        duration = decoded[-1]["uptime"] - decoded[0]["uptime"]
        environment = {**os.environ, "NGV_DIAGNOSTIC_REPLAY": str(folder),
                       "NGV_DIAGNOSTIC_KEY_FILE": str(root / "replay.key")}
        environment.pop("NGV_HANG_FIXTURE_KEY", None)
        if args.match_geometry:
            environment.update(NGV_DIAGNOSTIC_REPLAY_MATCH_GEOMETRY="1",
                               NGV_DIAGNOSTIC_REPLAY_PROGRESS=str(root / "progress.json"))
        started = time.monotonic()
        with (root / "app.log").open("wb") as log:
            process = subprocess.Popen([str(app / "Contents/MacOS/NexGenVideo")], env=environment,
                                       stdout=log, stderr=log)
            timed_out = False
            try:
                process.wait(timeout=duration + 75)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    subprocess.run(["sample", str(process.pid), "2", "-file", str(root / "sample.txt")],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
                except subprocess.TimeoutExpired:
                    pass
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        evidence = io.BytesIO()
        with zipfile.ZipFile(evidence, "w", zipfile.ZIP_DEFLATED) as archive:
            for name in ("app.log", "sample.txt", "progress.json"):
                if (root / name).exists():
                    archive.write(root / name, name)
        nonce = os.urandom(12)
        (output / "diagnostics.enc").write_bytes(nonce + AESGCM(key).encrypt(
            nonce, evidence.getvalue(), b"NGV_HANG_EVIDENCE_V1"))
        result = {"frames": len(frames), "recordedSeconds": duration,
                  "elapsedSeconds": time.monotonic() - started, "exitCode": process.returncode,
                  "timedOut": timed_out, "geometryRequested": args.match_geometry}
        result["constraintOverflowWarning"] = "constant that exceeds internal limits" in (root / "app.log").read_text(errors="replace")
        if (root / "progress.json").exists():
            result["progress"] = json.loads((root / "progress.json").read_text())
        (output / "result.json").write_text(json.dumps(result, indent=2))
        print(json.dumps(result))


if __name__ == "__main__":
    main()
