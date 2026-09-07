"""Run the CI-only real Agent panel with an out-of-process stall detector."""
import json
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import zipfile


def main():
    executable, output = sys.argv[1:]
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    # Private transcript logs and samples must never enter the uploaded evidence directory.
    private_fixture = bool(os.environ.get("NGV_CHAT_REPLAY_FIXTURE"))
    diagnostics = Path(tempfile.mkdtemp(prefix="ngv-private-replay-")) if private_fixture else output
    log_path = diagnostics / "replay.log"
    child_env = {key: value for key, value in os.environ.items()
                 if key not in {"NGV_CHAT_REPLAY_KEY", "NGV_CHAT_REPLAY_KEY_FILE"}}
    with log_path.open("w") as log:
        process = subprocess.Popen([executable], stdout=log, stderr=subprocess.STDOUT,
                                   env={**child_env, "NGV_CHAT_HANG_REPLAY": "1",
                                        "NGV_CHAT_REPLAY_EVIDENCE": str(output.resolve())})
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
                reason = ("main-thread-stall" if last_step >= 0 else "startup-timeout") if stalled else "runtime-limit"
                try:
                    subprocess.run(["/usr/bin/sample", str(process.pid), "3", "-file",
                                    str(diagnostics / "sample.txt")], timeout=15, check=False,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except subprocess.TimeoutExpired:
                    reason += ":sample-timeout"
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                break
        # Read the final marker after exit as well.
        completed |= '"event":"completed"' in log_path.read_text().replace(" ", "")
        result = {"completed": completed, "last_step": last_step,
                  "exit_code": process.wait(), "reason": reason,
                  "private_fixture": private_fixture,
                  "elapsed_seconds": round(time.monotonic() - started, 2)}
        (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        if private_fixture:
            from chat_replay_crypto import seal
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
                for path in diagnostics.iterdir():
                    if path.is_file():
                        archive.write(path, path.name)
            seal(buffer.getvalue(), output / "diagnostics.enc")
        print(json.dumps(result))
        return 0 if completed and result["exit_code"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
