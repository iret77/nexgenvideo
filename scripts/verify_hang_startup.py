"""Exercise recorder startup through the ordinary application delegate."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def verify_startup(app, *, expect_recording=True, starts=6, protected_recordings=()):
    root = Path.home() / "Library/Logs/NexGenVideo/HangIncidents"
    retained = set(protected_recordings)
    environment = {k: v for k, v in os.environ.items() if not k.startswith("NGV_")}
    modes = ["structure" if i % 2 == 0 else "replay" for i in range(starts)] + ["disabled"]
    for mode in modes:
        before = {p for p in root.glob("*") if p.is_dir()}
        process = subprocess.Popen([str(app / "Contents/MacOS/NexGenVideo"),
                                    "-hangDiagnosticMode", mode], env=environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        found = None
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                assert process.poll() is None, "ordinary application launch exited unexpectedly"
                created = {p for p in root.glob("*") if p.is_dir()} - before
                if mode == "disabled" or not expect_recording:
                    assert not created, "recording started despite the expected disabled state"
                else:
                    assert len(created) <= 1, "startup created multiple recordings"
                    if created:
                        folder = next(iter(created))
                        try:
                            metadata = json.loads((folder / "build.json").read_text())
                            pulse = json.loads((folder / "heartbeat.json").read_text())
                        except (OSError, ValueError):
                            time.sleep(0.1)
                            continue
                        assert metadata["mode"] == ("encrypted-replay" if mode == "replay" else "structure")
                        assert pulse["processID"] == process.pid
                        assert not pulse["stopped"]
                        assert pulse["mainUptime"] > 0 and pulse["writerUptime"] > 0
                        found = folder
                        break
                time.sleep(0.1)
            if mode != "disabled" and expect_recording:
                assert found is not None, "normal launch did not start the requested recorder"
            assert all(p.is_dir() for p in retained), "startup removed retained evidence"
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    return {"mode": "ordinary-startup", "starts": starts,
            "disabledChecked": True, "recordingExpected": expect_recording, "passed": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--expect-missing-recorder", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = verify_startup(args.app, expect_recording=not args.expect_missing_recorder,
                            starts=1 if args.expect_missing_recorder else 6)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
