"""Keep owned-process diagnostics and require an actual armed host-crash probe."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid


def stop_open_capture(process):
    signal_errors = []
    for name in ("TERM", "KILL"):
        if process.poll() is not None:
            return
        try:
            subprocess.run(["/usr/bin/sudo", "-n", "/bin/kill", "-" + name, "--", "-" + str(process.pid)],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=5, check=False)
        except (OSError, subprocess.TimeoutExpired) as error:
            signal_errors.append(repr(error))
        try:
            process.wait(timeout=5)
            return
        except subprocess.TimeoutExpired:
            continue
    raise RuntimeError("owned open diagnostic stream did not exit: " + "; ".join(signal_errors))


@contextmanager
def capture_open_logs(output):
    output.mkdir(parents=True, exist_ok=True)
    predicate = '(subsystem == "de.h5ventures.nexgenvideo.bpy-service" AND category == "open-diagnostic") OR (subsystem == "de.h5ventures.nexgenvideo" AND category == "bpy-open")'
    process = None
    cancelled = []
    cleanup_errors = []
    with (output / "open-events.ndjson").open("wb") as stream, \
         (output / "open-stream-stderr.log").open("wb") as stream_errors:
        try:
            process = subprocess.Popen(["/usr/bin/sudo", "-n", "/usr/bin/log", "stream", "--level", "info",
                                        "--style", "ndjson", "--predicate", predicate],
                                       stdin=subprocess.DEVNULL, stdout=stream, stderr=stream_errors,
                                       start_new_session=True)
            time.sleep(0.5)
            require(process.poll() is None, "open diagnostic stream failed before app launch")
            yield
        finally:
            handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
            for sig in handlers:
                signal.signal(sig, lambda number, _frame: cancelled.append(number))
            try:
                if process is not None and process.poll() is None:
                    time.sleep(2)
                stopped_early = process is not None and process.poll() is not None
                if process is not None:
                    try:
                        stop_open_capture(process)
                    except Exception as error:
                        cleanup_errors.append(repr(error))
                receipt = dict(
                    stoppedEarly=stopped_early, cancelled=cancelled,
                    returncode=process.returncode if process is not None else None,
                    reaped=process is not None and process.poll() is not None,
                    cleanupErrors=cleanup_errors,
                )
                try:
                    (output / "open-capture.json").write_text(json.dumps(receipt) + "\n")
                except OSError as error:
                    cleanup_errors.append(repr(error))
                    diagnostic_error(output, "open-capture-write", error)
            finally:
                for sig, handler in handlers.items():
                    signal.signal(sig, handler)
            if cancelled:
                raise InterruptedError("CI interrupted open diagnostic cleanup")
    require(not cleanup_errors, "open diagnostic cleanup failed: " + "; ".join(cleanup_errors))
    require(not stopped_early, "open diagnostic stream stopped during app execution")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def verify_crash(proof, mode, pid, source_sha, returncode):
    require(returncode == -signal.SIGKILL, "host probe did not reach its intentional SIGKILL")
    require(proof.get("schema") == 1 and proof.get("pid") == pid and proof.get("sourceSHA") == source_sha,
            "host-crash proof identity mismatch")
    require(proof.get("mode") == mode and proof.get("state") == "running", "host-crash stage mismatch")
    uuid.UUID(proof["jobID"])
    supervisor = proof.get("supervisorPID")
    require(type(supervisor) is int and supervisor > 1 and supervisor != pid, "missing active supervisor")
    if mode == "before-authorization":
        uuid.UUID(proof["authorizationID"])
        require(proof.get("workerPID") is None, "pre-authorization worker already started")
    else:
        require(proof.get("authorizationID") is None, "post-authorization lease still pending")
        worker = proof.get("workerPID")
        require(type(worker) is int and worker > 1 and worker not in (pid, supervisor), "missing authorized worker")


def sample_owned(process, output, label):
    if process.poll() is not None:
        return
    with (output / (label + "-sample-tool.log")).open("wb") as log:
        result = subprocess.run(["/usr/bin/sample", str(process.pid), "3", "-mayDie", "-file",
                                 str(output / (label + "-sample.log"))], stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT, timeout=30)
    (output / (label + "-sample-status.json")).write_text(json.dumps(dict(pid=process.pid, exitCode=result.returncode)) + "\n")


def collect_hangs(process, output, start, captured):
    directory = Path.home() / "Library/Logs/NexGenVideo"
    for path in directory.glob("*main-thread-hang.json"):
        try:
            if path in captured or path.is_symlink() or not path.is_file():
                continue
            stat = path.stat()
            if stat.st_mtime < start or stat.st_size > 131072:
                continue
            data = path.read_bytes()
            report = json.loads(data)
        except InterruptedError:
            raise
        except (OSError, ValueError) as error:
            diagnostic_error(output, "report-read", error)
            continue
        if not isinstance(report, dict) or report.get("processID") != process.pid:
            continue
        try:
            captured.add(path)
            (output / path.name).write_bytes(data)
            if len(captured) <= 3:
                sample_owned(process, output, "hang-" + str(len(captured)))
        except InterruptedError:
            raise
        except Exception as error:
            diagnostic_error(output, "hang-" + str(len(captured)), error)


def diagnostic_error(output, label, error):
    try:
        (output / (label + "-error.json")).write_text(json.dumps(dict(error=str(error))) + "\n")
    except InterruptedError:
        raise
    except OSError:
        pass


def supervise(binary, output, mode, source_sha, timeout):
    output.mkdir(parents=True, exist_ok=True)
    proof_path = output / "armed.json"
    require(not proof_path.exists(), "occupied host-crash proof")
    environment = dict(os.environ, NGV_BPY_COMMAND_EVIDENCE=str(output))
    if mode != "runtime":
        environment.update(NGV_SELFTEST_BPY_HOST_CRASH=mode, NGV_SELFTEST_BPY_HOST_CRASH_EVIDENCE=str(proof_path))
    captured = set()
    start = time.time()
    deadline = time.monotonic() + timeout
    with (output / "runtime.log").open("wb") as stdout, (output / "runtime-stderr.log").open("wb") as stderr:
        process = subprocess.Popen([str(binary)], env=environment, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
        try:
            (output / "process.json").write_text(json.dumps(dict(pid=process.pid, sourceSHA=source_sha, mode=mode)) + "\n")
            while process.poll() is None:
                try:
                    collect_hangs(process, output, start, captured)
                except InterruptedError:
                    raise
                except Exception as error:
                    diagnostic_error(output, "hang-collection", error)
                require(time.monotonic() < deadline, "owned bpy process timed out")
                time.sleep(0.1)
            try:
                collect_hangs(process, output, start, captured)
            except InterruptedError:
                raise
            except Exception as error:
                diagnostic_error(output, "hang-collection", error)
            if mode == "runtime":
                require(process.returncode == 0, "bpy runtime exited with status " + str(process.returncode))
            else:
                require(proof_path.is_file(), "host probe failed before its crash was armed")
                verify_crash(json.loads(proof_path.read_text()), mode, process.pid, source_sha, process.returncode)
            (output / "process-result.json").write_text(json.dumps(dict(pid=process.pid, returncode=process.returncode,
                                                                         sourceSHA=source_sha, mode=mode)) + "\n")
        except BaseException as error:
            (output / "process-failure.json").write_text(json.dumps(dict(pid=process.pid, error=str(error))) + "\n")
            try:
                sample_owned(process, output, "failure")
            except Exception as sample_error:
                diagnostic_error(output, "sample", sample_error)
            raise
        finally:
            if process.poll() is None:
                process.kill()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired as error:
                diagnostic_error(output, "reaping", error)
                if not (output / "process-failure.json").exists():
                    raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--mode", choices=("runtime", "before-authorization", "after-authorization"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--deadline", type=float, required=True)
    parser.add_argument("--capture-open-logs", action="store_true")
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_sha), "invalid app source")
    binary = args.app.resolve() / "Contents/MacOS/NexGenVideo"
    require(binary.is_file(), "missing app binary")
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda number, _frame: (_ for _ in ()).throw(InterruptedError("CI interrupted the owned process: " + str(number))))
    remaining = args.deadline - time.time()
    require(remaining > 0, "job diagnostic deadline reached before app launch")
    timeout = min(remaining, 1800 if args.mode == "runtime" else 300)
    if args.capture_open_logs:
        with capture_open_logs(args.output.resolve()):
            supervise(binary, args.output.resolve(), args.mode, args.source_sha, timeout)
    else:
        supervise(binary, args.output.resolve(), args.mode, args.source_sha, timeout)


if __name__ == "__main__":
    main()
