#!/usr/bin/env python3
"""Verify the shipped app's independent capture path; never use owner data."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from analyze_hang_diagnostics import analyze


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("symbols", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path.home() / "Library/Logs/NexGenVideo/HangIncidents"
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    retained_recordings = []
    replay_account = None
    replay_key = None
    for mode in ("wait", "spin"):
        before = set(root.glob("*"))
        temporary = tempfile.TemporaryDirectory()
        key_file = Path(temporary.name) / "replay.key"
        exported = Path(temporary.name) / "export"
        test_environment = {**os.environ, "NGV_HANG_SELFTEST": mode}
        if mode == "wait":
            test_environment.update(NGV_HANG_SELFTEST_KEY=str(key_file), NGV_HANG_SELFTEST_EXPORT=str(exported))
        process = subprocess.Popen([str(args.app / "Contents/MacOS/NexGenVideo")],
                                   env=test_environment,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            process.wait(timeout=65)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise RuntimeError("diagnostic self-test did not recover")
        assert process.returncode == 0, process.returncode
        folders = set(root.glob("*")) - before
        assert len(folders) == 1, "exactly one recording required"
        folder = folders.pop()
        retained_recordings.append(folder)
        reports = list(folder.glob("incident-*/incident.json"))
        assert len(reports) == 1, "exactly one detected hang required"
        report = json.loads(reports[0].read_text())
        assert len(report["samples"]) == 2, report
        assert report.get("recoveredUptime"), report
        stacks = list(folder.glob("self-*.stacks"))
        assert len(stacks) == 6, "two captures of three raw stack snapshots required"
        symbolized = []
        for stack in stacks:
            text = stack.read_text()
            assert "NGV_SELF_STACKS_V1" in text
            images = [line.split() for line in text.splitlines() if line.startswith("image ")]
            symbol_uuid = subprocess.check_output(["dwarfdump", "--uuid", str(args.symbols)], text=True).split()[1].replace("-", "").lower()
            host = next(image for image in images if image[2] == symbol_uuid)
            addresses = [line for line in text.splitlines() if line.startswith("0x")]
            output = subprocess.check_output(["atos", "-arch", "arm64", "-o",
                str(args.symbols / "Contents/Resources/DWARF/NexGenVideo"), "-l", host[1],
                *addresses], text=True)
            symbolized.append(output)
        marker = "knownMainThreadWait" if mode == "wait" else "knownMainThreadSpin"
        assert any(marker in output for output in symbolized), "missing injected blocking frame"
        events = [record for file in folder.glob("events-*.json") for record in json.loads(file.read_text())]
        assert any(event["operation"] == ("testWait" if mode == "wait" else "testSpin") for event in events)
        if mode == "wait":
            replay_account = f"hang-diagnostic-{folder.name}"
            replay_key = key_file.read_text().strip()
            export = exported / folder.name
            assert list(export.glob("replay-*.enc")), "encrypted replay content missing"
            assert (export / "checksums.json").is_file()
            summary = analyze(export)
            assert summary["eventCount"] > 0 and not summary["gaps"], summary
            replay_environment = {**os.environ, "NGV_DIAGNOSTIC_REPLAY": str(export),
                                  "NGV_DIAGNOSTIC_KEY_FILE": str(key_file)}
            command = [str(args.app / "Contents/MacOS/NexGenVideo")]
            subprocess.run(command, env=replay_environment, check=True, timeout=65,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            reached = Path(temporary.name) / "fault-reached"
            fault = subprocess.Popen(command, env={**replay_environment, "NGV_DIAGNOSTIC_REPLAY_FAULT": "1",
                                     "NGV_DIAGNOSTIC_REPLAY_FAULT_REACHED": str(reached)},
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                fault.wait(timeout=12)
            except subprocess.TimeoutExpired:
                fault.kill()
                fault.wait()
                assert reached.is_file(), "replay timed out before reaching the injected blocking frame"
            else:
                raise AssertionError("fault-enabled replay did not reproduce the injected hang")
        temporary.cleanup()
        results.append({"mode": mode, "samples": len(stacks), "symbolizedMarker": marker, "passed": True})
    before = set(root.glob("*"))
    process = subprocess.Popen([str(args.app / "Contents/MacOS/NexGenVideo")],
        env={**os.environ, "NGV_HANG_SELFTEST": "wait"}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 20
        folder = None
        while time.monotonic() < deadline:
            folders = set(root.glob("*")) - before
            if len(folders) == 1:
                folder = next(iter(folders))
                if list(folder.glob("self-*.stacks")):
                    break
            time.sleep(0.2)
        else:
            raise AssertionError("force-quit control never reached a persisted stack")
        process.kill()
        process.wait(timeout=5)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            reports = list(folder.glob("incident-*/incident.json"))
            if reports and json.loads(reports[0].read_text()).get("processLost"):
                break
            time.sleep(0.2)
        else:
            raise AssertionError("helper did not finalize after force quit")
        assert list(folder.glob("events-*.json")), "pre-hang journal missing after force quit"
        results.append({"mode": "force-quit", "passed": True})
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
    retained_recordings.append(folder)
    with tempfile.TemporaryDirectory() as retention_temporary:
        expected_key = Path(retention_temporary) / "expected.key"
        expected_key.write_text(replay_key)
        expected_key.chmod(0o600)
        for _ in range(6):
            before = set(root.glob("*"))
            subprocess.run([str(args.app / "Contents/MacOS/NexGenVideo")],
                env={**os.environ, "NGV_HANG_SELFTEST": "startup",
                     "NGV_HANG_SELFTEST_VERIFY_ACCOUNT": replay_account,
                     "NGV_HANG_SELFTEST_VERIFY_KEY_FILE": str(expected_key)}, check=True, timeout=15,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            started = set(root.glob("*")) - before
            assert len(started) == 1, "startup did not create exactly one recording"
            assert (started.pop() / "build.json").is_file(), "startup did not initialize recording"
            assert all(recording.is_dir() for recording in retained_recordings), "restart removed hang evidence"
    results.append({"mode": "repeated-startup-retention", "starts": 6, "passed": True})
    (args.output / "result.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
