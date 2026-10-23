"""Observe one original host-crash probe; this never grants runtime acceptance."""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
import uuid


def read_regular(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("diagnostic input is not a bounded regular file")
        data = os.read(fd, limit + 1)
        if len(data) > limit:
            raise ValueError("diagnostic input exceeds its bound")
        return data
    finally:
        os.close(fd)


def owned_report(path, pid, started):
    if path.lstat().st_mtime < started:
        return None
    data = read_regular(path, 131072)
    value = json.loads(data)
    return data if isinstance(value, dict) and value.get("processID") == pid else None


def sanitized_lease(data, pid):
    value = json.loads(data)
    if not isinstance(value, dict) or value.get("ownerPID") != pid:
        return None
    allowed = ("schema", "id", "serviceName", "ownerPID", "ownerStart", "bootSessionID",
               "servicePID", "serviceStart", "directoryDevice", "directoryInode", "maximumBytes")
    result = {key: value[key] for key in allowed if key in value}
    lease = value.get("lease")
    if isinstance(lease, dict):
        result["lease"] = {key: lease[key] for key in ("id", "mountPath", "device", "capacityBytes") if key in lease}
    return result


def verdict(returncode, controls, timed_out, *, host_pid=None, observer_terminated=False):
    if host_pid is None:
        outcome = "NOT_RUN"
    elif observer_terminated:
        outcome = "INCONCLUSIVE_OBSERVER_TERMINATED"
    else:
        outcome = "FAIL" if returncode != 0 or timed_out else "NOT_REPRODUCED"
    return dict(scope="diagnostic-only", runtimeAcceptance=False,
                probeVerdict=outcome, observerTerminated=observer_terminated,
                harnessReturnCode=returncode, timedOut=timed_out,
                instrumentControls=controls, instrumentsComplete=all(controls.values()),
                rootCause="UNKNOWN; requires original trace and identity review")


def command(args, output, timeout=20):
    with output.open("wb") as stream:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop_owned(process, privileged=args[0] == "sudo")
            return 124
        except BaseException:
            stop_owned(process, privileged=args[0] == "sudo")
            raise


def signal_owned(process, sig, privileged=False):
    if process.poll() is None:
        if privileged:
            subprocess.run(["sudo", "-n", "/bin/kill", "-" + sig.name.removeprefix("SIG"), "--", "-" + str(process.pid)],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        else:
            os.killpg(process.pid, sig)


def stop_owned(process, privileged=False, signalled=False):
    if process.poll() is None:
        if not signalled:
            signal_owned(process, signal.SIGTERM, privileged)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            signal_owned(process, signal.SIGKILL, privileged)
            process.wait(timeout=5)
    return process.returncode


def child_samples(raw, host_pid):
    result = {}
    for line in raw.decode(errors="replace").splitlines():
        fields = line.split(None, 8)
        if (len(fields) == 9 and fields[0].isdigit() and fields[1].isdigit()
                and int(fields[1]) == host_pid and fields[8] == "/usr/bin/sample"):
            result[int(fields[0])] = " ".join(fields[3:8])
    return result


def stop_samples(samples, group):
    stopped = []
    for pid, started in samples.items():
        try:
            if os.getpgid(pid) != group:
                raise RuntimeError("sample identity changed; not signalled: " + str(pid))
            for sig in (signal.SIGTERM, signal.SIGKILL):
                result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart=,comm="],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                if result.stdout.decode().split() != (started + " /usr/bin/sample").split():
                    raise RuntimeError("sample identity changed; not signalled: " + str(pid))
                if os.getpgid(pid) != group:
                    raise RuntimeError("sample group changed; not signalled: " + str(pid))
                os.kill(pid, sig)
                until = time.monotonic() + 5
                while time.monotonic() < until:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        stopped.append(pid)
                        break
                    time.sleep(0.1)
                else:
                    continue
                break
            else:
                raise RuntimeError("owned sample did not exit: " + str(pid))
        except ProcessLookupError:
            continue
    return stopped


def unified_control(data, host_pid):
    if host_pid is None:
        return False
    for line in data.splitlines():
        try:
            value = json.loads(line)
            if (isinstance(value, dict) and value.get("processID") == host_pid
                    and value.get("eventMessage") == "main-thread watchdog started"):
                return True
        except (ValueError, TypeError):
            continue
    return False


def observe_files(output, pid, started, seen):
    logs = Path.home() / "Library/Logs/NexGenVideo"
    for path in logs.glob("*main-thread-hang.json"):
        try:
            data = owned_report(path, pid, started)
            if data is None:
                continue
            digest = hashlib.sha256(data).hexdigest()
            if seen.get(str(path)) != digest:
                (output / (digest + "-" + path.name)).write_bytes(data)
                (output / path.name).write_bytes(data)
                seen[str(path)] = digest
            name = json.loads(data).get("sampleFilenameIfAvailable")
            if isinstance(name, str) and Path(name).name == name and name.endswith(".sample.txt"):
                sample = logs / name
                if sample.lstat().st_mtime >= started:
                    (output / name).write_bytes(read_regular(sample, 16 * 1024 * 1024))
        except InterruptedError:
            raise
        except (OSError, ValueError, TypeError):
            continue
    base = Path.home() / "Library/Caches/NexGenVideo/BpyVolumes"
    for slot in (0, 1):
        folder = base / ("de.h5ventures.nexgenvideo.bpy-service-" + str(slot))
        try:
            if not stat.S_ISDIR(folder.lstat().st_mode):
                continue
            value = sanitized_lease(read_regular(folder / "lease.json", 16384), pid)
            if value is None:
                continue
            data = json.dumps(value, sort_keys=True).encode()
            digest = hashlib.sha256(data).hexdigest()
            if seen.get(str(folder)) != digest:
                with (output / "storage-observations.jsonl").open("ab") as stream:
                    stream.write(json.dumps(dict(at=time.time(), slot=slot, record=value)).encode() + b"\n")
                seen[str(folder)] = digest
        except InterruptedError:
            raise
        except (OSError, ValueError, TypeError):
            continue


def run(app, output, source, probe_output):
    if probe_output.exists() or probe_output.is_symlink():
        raise ValueError("occupied original probe output")
    output.mkdir(parents=True, exist_ok=False)
    started = time.time()
    previous_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    seen = {}
    host_pid = None
    probe = None
    trace = None
    log_stream = None
    trace_stopped_at = None
    trace_truncated = False
    stream_stopped_early = False
    observer_terminated = False
    cancelled = False
    timed_out = False
    errors = []
    cleanup_errors = []
    samples = {}
    marker = "ngv-ctl-" + uuid.uuid4().hex[:16]
    predicate = ('(subsystem == "com.apple.sandbox.reporting") OR (process BEGINSWITH "NexGenVideo") '
                 'OR (process IN {"xpcproxy","secinitd","sandboxd","launchd","kernel"} '
                 'AND eventMessage CONTAINS[c] "nexgenvideo")')

    def identity():
        try:
            value = json.loads(read_regular(probe_output / "process.json", 4096))
            if (isinstance(value, dict) and value.get("sourceSHA") == source and type(value.get("pid")) is int
                    and value["pid"] > 1 and value.get("mode") == "before-authorization"):
                return value["pid"]
        except InterruptedError:
            raise
        except (OSError, ValueError):
            pass
        return None

    def record_error(message):
        if message not in errors:
            errors.append(message)

    def cancellation(number, _frame):
        nonlocal cancelled
        cancelled = True
        raise InterruptedError("diagnostic interrupted: " + str(number))

    def cleanup_cancellation(number, _frame):
        nonlocal cancelled
        cancelled = True
        record_error("signal during cleanup: " + str(number))

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, cancellation)
    with ExitStack() as stack:
        trace_output = stack.enter_context((output / "filesystem-trace.log").open("wb"))
        stream_output = stack.enter_context((output / "unified-stream.ndjson").open("wb"))
        harness_log = stack.enter_context((output / "probe-harness.log").open("wb"))
        try:
            trace = subprocess.Popen(["sudo", "-n", "/usr/bin/fs_usage", "-w", "-f", "filesys",
                                      "-f", "pathname", "-f", "exec", "-t", "450"],
                                     stdin=subprocess.DEVNULL, stdout=trace_output, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            log_stream = subprocess.Popen(["sudo", "-n", "/usr/bin/log", "stream", "--level", "debug",
                                           "--style", "ndjson", "--predicate", predicate],
                                          stdin=subprocess.DEVNULL, stdout=stream_output, stderr=subprocess.STDOUT,
                                          start_new_session=True)
            time.sleep(1)
            if trace.poll() is not None or log_stream.poll() is not None:
                raise RuntimeError("required tracing exited before the probe")
            (output / marker).write_bytes(b"trace positive control\n")
            deadline = time.time() + 300
            harness_deadline = str(deadline + 130)
            environment = dict(os.environ, EXPECTED_SOURCE=source, NGV_BPY_DIAGNOSTIC_DEADLINE=harness_deadline)
            probe = subprocess.Popen([sys.executable, str(Path(__file__).with_name("bpy_runtime_acceptance.py")),
                                      str(app), "--mode", "before-authorization", "--source-sha", source,
                                      "--deadline", harness_deadline, "--output", str(probe_output)], env=environment,
                                     stdin=subprocess.DEVNULL, stdout=harness_log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            with (output / "process-snapshots.log").open("wb") as snapshots:
                while probe.poll() is None:
                    host_pid = identity() or host_pid
                    if host_pid is not None:
                        observe_files(output, host_pid, started, seen)
                    try:
                        result = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,pgid=,lstart=,comm="],
                                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                        if result.returncode != 0:
                            record_error("process identity capture failed")
                        else:
                            if host_pid is not None:
                                samples.update(child_samples(result.stdout, host_pid))
                            snapshots.write(("observedAt=" + str(time.time()) + "\n").encode())
                            for line in result.stdout.splitlines():
                                if b"NexGenVideo" in line or b"/usr/bin/sample" in line or b"hdiutil" in line:
                                    snapshots.write(line + b"\n")
                            snapshots.flush()
                    except InterruptedError:
                        raise
                    except (OSError, subprocess.TimeoutExpired) as error:
                        record_error("process identity capture: " + str(error))
                    if time.time() >= deadline + 130:
                        timed_out = True
                        raise TimeoutError("owned probe diagnostic deadline")
                    if trace_stopped_at is None:
                        trace_truncated = (output / "filesystem-trace.log").stat().st_size > 64 * 1024 * 1024
                        if trace.poll() is not None or trace_truncated:
                            trace_stopped_at = time.time()
                            record_error("filesystem trace stopped before the probe completed")
                            try:
                                stop_owned(trace, True)
                            except InterruptedError:
                                raise
                            except Exception as error:
                                cleanup_errors.append("trace: " + str(error))
                    if not stream_stopped_early and (log_stream.poll() is not None
                            or (output / "unified-stream.ndjson").stat().st_size > 64 * 1024 * 1024):
                        stream_stopped_early = True
                        record_error("unified stream stopped before the probe completed")
                        try:
                            stop_owned(log_stream, True)
                        except InterruptedError:
                            raise
                        except Exception as error:
                            cleanup_errors.append("log stream: " + str(error))
                    time.sleep(0.5)
        except (Exception, KeyboardInterrupt) as error:
            errors.append(str(error))
        finally:
            for sig in (signal.SIGINT, signal.SIGTERM):
                signal.signal(sig, cleanup_cancellation)
            observer_terminated = probe is not None and probe.poll() is None
            try:
                (output / marker).write_bytes(b"trace closing control\n")
            except OSError as error:
                record_error("closing control: " + str(error))
            processes = ((trace, True), (log_stream, True), (probe, False))
            for process, privileged in processes:
                if process is not None:
                    try:
                        signal_owned(process, signal.SIGTERM, privileged)
                    except Exception as error:
                        cleanup_errors.append("capture signal: " + str(error))
            for process, privileged in processes:
                if process is not None:
                    try:
                        stop_owned(process, privileged, signalled=True)
                    except Exception as error:
                        cleanup_errors.append("capture cleanup: " + str(error))
            host_pid = identity() or host_pid
            if probe is not None:
                try:
                    stopped_samples = stop_samples(samples, probe.pid)
                    (output / "owned-sample-cleanup.json").write_text(json.dumps(
                        dict(observed=samples, stopped=stopped_samples, processGroup=probe.pid)) + "\n")
                except Exception as error:
                    cleanup_errors.append("owned sample cleanup: " + str(error))
            if host_pid is not None:
                try:
                    observe_files(output, host_pid, started, seen)
                except Exception as error:
                    cleanup_errors.append("final report collection: " + str(error))
    for args, name, limit in ((["sudo", "-n", "/usr/bin/log", "show", "--last", "10m", "--style", "compact",
                               "--info", "--debug", "--predicate", predicate], "unified.log", 30),
                              (["/usr/bin/hdiutil", "info", "-plist"], "mounted-images.plist", 20),
                              (["/sbin/mount"], "mounts.log", 20)):
        if cancelled:
            record_error("supplementary capture omitted after cancellation")
            break
        try:
            if command(args, output / name, timeout=limit) != 0:
                record_error("supplementary capture failed: " + name)
        except Exception as error:
            record_error("supplementary capture " + name + ": " + str(error))
    raw = (output / "filesystem-trace.log").read_bytes()
    unified = (output / "unified-stream.ndjson").read_bytes()
    controls = dict(filesystem=marker.encode() in raw and trace_stopped_at is None,
                    unified=unified_control(unified, host_pid) and not stream_stopped_early,
                    observer=not errors, cleanup=not cleanup_errors)
    result = verdict(probe.returncode if probe else None, controls, timed_out,
                     host_pid=host_pid, observer_terminated=observer_terminated)
    result.update(sourceSHA=source, hostPID=host_pid, startedAt=started, finishedAt=time.time(), errors=errors,
                  cleanupErrors=cleanup_errors, traceStoppedAt=trace_stopped_at, traceTruncated=trace_truncated,
                  cancelled=cancelled,
                  probeOutput=str(probe_output),
                  streamStoppedEarly=stream_stopped_early, fsUsageSuffixIsThreadID=True,
                  traceReturnCode=trace.returncode if trace else None,
                  fidelity="Original relocated app, original probe-output location, synthetic resources, harness and 300-second app deadline; EXPECTED_SOURCE and NGV_BPY_DIAGNOSTIC_DEADLINE supplied; parallel observers, CANDIDATE_* metadata and a new process session added; previously proven source-archive preparation omitted.",
                  cancellationLimit="An external SIGKILL can prevent final cleanup and evidence writing.")
    (output / "evidence-verdict.json").write_text(json.dumps(result, indent=2) + "\n")
    for sig, handler in previous_handlers.items():
        signal.signal(sig, handler)
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--probe-output", type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_sha):
        parser.error("invalid original app source")
    raise SystemExit(run(args.app.resolve(), args.output.resolve(), args.source_sha, args.probe_output.absolute()))


if __name__ == "__main__":
    main()
