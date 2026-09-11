"""Run the real Agent panel with an out-of-process stall detector."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def main():
    executable, output = sys.argv[1:]
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    log_path = output / "replay.log"
    with log_path.open("w") as log:
        process = subprocess.Popen(
            [executable],
            stdout=log,
            stderr=subprocess.STDOUT,
            env={
                **os.environ,
                "NGV_CHAT_HANG_REPLAY": "1",
                "NGV_CHAT_REPLAY_EVIDENCE": str(output.resolve()),
            },
        )
        started = last_progress = time.monotonic()
        last_step = -1
        completed = False
        reason = "process-exited"
        while process.poll() is None:
            time.sleep(1)
            for line in log_path.read_text(errors="replace").splitlines():
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict) or "step" not in row:
                    continue
                if row["step"] > last_step:
                    last_step = row["step"]
                    last_progress = time.monotonic()
                completed |= row.get("event") == "completed"
            stalled = time.monotonic() - last_progress > 15
            if stalled or time.monotonic() - started > 300:
                reason = (
                    "main-thread-stall" if last_step >= 0 else "startup-timeout"
                ) if stalled else "runtime-limit"
                try:
                    subprocess.run(
                        [
                            "/usr/bin/sample",
                            str(process.pid),
                            "3",
                            "-file",
                            str(output / "sample.txt"),
                        ],
                        timeout=15,
                        check=False,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                except subprocess.TimeoutExpired:
                    reason += ":sample-timeout"
                break
        if process.poll() is None:
            process.kill()
        return_code = process.wait()
    result = {
        "completed": completed,
        "elapsedSeconds": time.monotonic() - started,
        "exitCode": return_code,
        "lastStep": last_step,
        "reason": reason,
    }
    (output / "result.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
    return 0 if completed and return_code == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
