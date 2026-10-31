"""Keep owned-process diagnostics and require an actual armed host-crash probe."""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_macos_tests import (host_binary_identity, owned_crash_report, read_stable_crash_report,
                             report_candidates, report_directories)


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


def verify_storage_scope(log_text, process, binary):
    events = []
    for line in log_text.splitlines():
        if line.startswith("Filtering the log data using "):
            continue
        if not line.strip():
            continue
        event = json.loads(line)
        message = event.get("eventMessage", "")
        if not message.startswith(("open.", "bookmark.resolve ")):
            continue
        parts = message.split()
        fields = dict(item.split("=", 1) for item in parts[1:])
        require(len(fields) == len(parts) - 1, "duplicate storage event fields")
        events.append((parts[0], fields, event))
    preparations = [entry for entry in events if entry[0] == "open.preparation"
                    and entry[2].get("processID") == process["pid"]]
    require(len(preparations) == 1, "one original host storage preparation required")
    preparation = preparations[0]
    session = preparation[1]["session"]
    uuid.UUID(session)
    service = int(preparation[1]["servicePID"])
    start = preparation[1]["serviceStart"]
    require(service > 1 and service != process["pid"] and int(start) > 0, "storage service identity")
    host_path = str(binary)
    service_path = re.escape(str(binary.parent.parent)) + r"/XPCServices/NexGenVideoBpyService[0-9]+\.xpc/Contents/MacOS/NexGenVideoBpyService"

    host_events = []

    def selected(tag, host=False, role=None):
        matches = [entry for entry in events if entry[0] == tag
                   and entry[1].get("pair" if tag == "bookmark.resolve" else "session") == session
                   and (role is None or entry[1].get("role") == role)]
        if tag == "bookmark.resolve":
            require(1 <= len(matches) <= 2, "bounded host bookmark resolution")
            require([item[1].get("attempt") for item in matches] == [str(n + 1) for n in range(len(matches))],
                    "ordered host bookmark refresh")
            require([item[1].get("stale") for item in matches] ==
                    (["true", "false"] if len(matches) == 2 else ["false"]), "fresh host bookmark required")
            for _, fields, _ in matches:
                require(all(fields.get(key) == matches[-1][1].get(key)
                            for key in ("id", "pair", "role", "device", "capacity")), "host refresh changed storage identity")
                require(all(fields.get(key) == "true" for key in ("file", "pathMatches"))
                        and fields.get("volumeMatch") == "equal"
                        and re.fullmatch(r"[0-9a-f]{64}", fields.get("sha256", "")), "host bookmark identity")
            host_events.extend(matches)
        else:
            require(len(matches) == 1, "one storage event required: " + tag)
        for _, fields, event in matches:
            require(event.get("processID") == (process["pid"] if host else service), "foreign storage event PID")
            require(event.get("processImagePath") == host_path if host else
                    re.fullmatch(service_path, event.get("processImagePath", "")), "foreign storage event image")
            require(event.get("subsystem") == ("de.h5ventures.nexgenvideo" if host else "de.h5ventures.nexgenvideo.bpy-service")
                    and event.get("category") == ("bpy-open" if host else "open-diagnostic"), "storage event origin")
            if not host:
                require((tag == "open.result" or fields.get("pid") == str(service)), "storage event reported PID")
        return matches[-1]

    preparation = selected("open.preparation", host=True)
    prepared = selected("open.prepared")
    owner = prepared[1]["owner"]
    uuid.UUID(owner)
    storage_roles = {}
    scope_events = []
    for role in ("worker", "data"):
        host = selected("bookmark.resolve", host=True, role=role)
        before = selected("open.beforeScope", role=role)
        checked = selected("open.check", role=role)
        validated = selected("open.validated", role=role)
        lease = host[1]["id"]
        uuid.UUID(lease)
        digest = host[1]["sha256"]
        require(re.fullmatch(r"[0-9a-f]{64}", digest), "bookmark digest")
        require(int(before[1]["errno"]) in (errno.EPERM, errno.EACCES)
                and before[1].get("closeErrno") == "0", "mount accessible before bookmark scope")
        for item in (host, checked):
            require(item[1].get("file") == "true" and item[1].get("pathMatches") == "true"
                    and item[1].get("volumeMatch") == "equal", "resolved storage identity")
        require(checked[1].get("stale") in ("true", "false"), "receiver freshness observation required")
        require(all(item[1].get("pair") == session and item[1].get("storage") == lease
                    and item[1].get("owner") == owner and item[1].get("start") == start
                    for item in (before, checked, validated)), "storage role/connection identity")
        require(checked[1]["sha256"] == validated[1]["sha256"] == digest, "exact storage bookmark handoff")
        device, capacity = int(host[1]["device"]), int(host[1]["capacity"])
        require(device > 0 and 0 < capacity <= 8 * 1024 ** 3
                and host[1]["device"] == str(device) and host[1]["capacity"] == str(capacity)
                and validated[1].get("device") == str(device)
                and validated[1].get("capacity") == str(capacity), "kernel-validated mount identity")
        storage_roles[role] = dict(leaseID=lease, device=device, capacityBytes=capacity,
            bookmarkSHA256=digest, receiverStale=checked[1]["stale"] == "true",
            preScopeErrno=int(before[1]["errno"]))
        scope_events.extend((before, checked, validated))
    for tag in ("open.beforeScope", "open.check", "open.validated"):
        matches = [entry for entry in events if entry[0] == tag and entry[1].get("session") == session]
        require(len(matches) == 2 and {entry[1].get("role") for entry in matches} == {"worker", "data"},
                "exactly both storage roles required")
    require(sum(entry[0] == "bookmark.resolve" and entry[1].get("pair") == session for entry in events)
            == len(host_events), "unknown host storage role")
    require(storage_roles["worker"]["leaseID"] == session
            and storage_roles["worker"]["leaseID"] != storage_roles["data"]["leaseID"]
            and storage_roles["worker"]["device"] != storage_roles["data"]["device"], "distinct paired storage required")
    roles = ("pythonAlias", "pythonTarget", "supervisor", "worker", "sitePackages")
    resources = [selected("open.runtime-resource", role=role) for role in roles]
    preflight = selected("open.runtime-preflight")
    opened = selected("open.result")
    require(opened[1].get("owner") == owner and prepared[1].get("start") == start
            and opened[1].get("ok") == "true", "validated storage handoff")
    require(all(preflight[1].get(field) == "true" for field in ("python", "supervisor", "worker", "sitePackages")),
            "all runtime executable preflight clauses required")
    require(all(item[1].get("start") == start for item in (*resources, preflight)), "runtime preflight process start")
    diagnostic_fields = {"lstatErrno", "lstatType", "lstatMode", "lstatFlags", "statErrno", "statType",
                         "statMode", "statFlags", "existsErrno", "readErrno", "executeErrno", "openErrno",
                         "closeErrno", "foundationExecutable", "quarantineErrno", "quarantinePresent",
                         "provenanceErrno", "provenancePresent"}
    for role, item in zip(roles, resources):
        required = diagnostic_fields | ({"readlinkErrno", "targetMatches"} if role == "pythonAlias" else set())
        require(all(re.fullmatch(r"[0-9]+", item[1].get(field, "")) for field in required),
                "missing or malformed runtime resource diagnostics: " + role)
        require(all(item[1][field] in ("0", "1") for field in
                    ("foundationExecutable", "quarantinePresent", "provenancePresent")), "invalid runtime diagnostic boolean")
    target = resources[1][1]
    require(target["executeErrno"] == "0" and target["foundationExecutable"] == "1"
            and target["statErrno"] == "0" and int(target["statType"]) == 0o100000,
            "pinned Python executable access not proven")
    times = [item[2]["machTimestamp"] for item in
             (prepared, preparation, *host_events, *scope_events, *resources, preflight, opened)]
    require(all(type(value) is int and value > 0 for value in times)
            and all(a < b for a, b in zip(times, times[1:])), "storage event order")
    return dict(schema="nexgenvideo/bpy-storage-scope/2", hostPID=process["pid"], servicePID=service,
                serviceStart=start, sessionID=session, ownerID=owner, storageRoles=storage_roles,
                runtimeResources={role: {key: int(value) for key, value in item[1].items() if key in diagnostic_fields
                                        or key in ("readlinkErrno", "targetMatches")}
                                  for role, item in zip(roles, resources)})


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


def prepare_worker_postmortem(binary):
    app = binary.resolve().parents[2]
    templates, errors = [], []
    for slot in range(2):
        service = app / ("Contents/XPCServices/NexGenVideoBpyService" + str(slot) + ".xpc")
        for role, path in (("supervisor", service / "Contents/MacOS/NexGenVideoBpySupervisor"),
                           ("python", service / "Contents/Resources/BpyRuntime/python/bin/python3.13")):
            try:
                resolved = path.resolve(strict=True)
                resolved.relative_to(app)
                templates.append(dict(role=role, **host_binary_identity(resolved)))
            except InterruptedError:
                raise
            except (OSError, ValueError) as error:
                errors.append(dict(role=role, slot=slot, error=str(error)))
    directories = report_directories()
    prefixes = tuple(sorted({Path(t["hostExecutable"]).name for t in templates} | {"Python", "python"}))
    baseline, scan_errors = report_candidates(directories, prefixes)
    return dict(templates=templates, directories=[str(p) for p in directories], prefixes=prefixes,
                baseline=baseline, preparationErrors=errors, baselineErrors=scan_errors)


def failed_worker_contexts(path, host_pid, source_sha, preparation, started, observed):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and before.st_nlink == 1 and 0 < before.st_size <= 1_048_576, "unsafe failed-response record")
        data = stream.read(1_048_577)
        after = os.fstat(stream.fileno())
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
            == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
            and len(data) == after.st_size, "failed-response record changed")
    record = json.loads(data)
    require(isinstance(record, dict), "invalid failed-response record")
    require(record.get("schema") == "nexgenvideo/bpy-open-failure/1"
            and type(record.get("hostPID")) is int and record["hostPID"] == host_pid
            and record.get("sourceSHA") == source_sha, "foreign failed-response record")
    require(isinstance(record.get("sessionID"), str), "invalid failed-response session")
    uuid.UUID(record["sessionID"])
    raw = base64.b64decode(record["response"], validate=True)
    require(hashlib.sha256(raw).hexdigest() == record.get("responseSHA256"), "failed-response digest differs")
    response = json.loads(raw)
    require(isinstance(response, dict), "invalid failed startup response")
    require(response.get("ok") is False, "not a failed startup response")
    metrics = response.get("metrics", {})
    require(isinstance(metrics, dict), "invalid startup metrics")
    if "probe.exitStatus" not in metrics:
        return []

    def integer(name, minimum, maximum):
        value = metrics.get(name)
        require(type(value) in (int, float) and minimum <= value <= maximum
                and math.isfinite(value) and int(value) == value, "invalid " + name)
        return int(value)

    status = integer("probe.exitStatus", 0, 255)
    if status == 0:
        return []
    supervisor = integer("probe.supervisorPID", 2, 2_147_483_647)
    worker = integer("probe.workerPID", -1, 2_147_483_647)
    termination = integer("probe.terminationSignal", -1, 127)
    require(supervisor != host_pid and worker not in (0, 1, host_pid, supervisor), "reused process identity")
    target, parent = (supervisor, host_pid) if termination > 0 else (worker, supervisor)
    if target < 2:
        return []
    return [dict(template, pid=target, parentPID=parent, launchEarliest=started,
                 launchLatest=observed, exitObserved=observed, sourceSHA=source_sha,
                 hostPID=host_pid, sessionID=record["sessionID"], workerExitStatus=status,
                 failureResponseSHA256=record["responseSHA256"])
            for template in preparation["templates"]
            if termination <= 0 or template["role"] == "supervisor"]


def capture_worker_log(folder, pid, contexts, started, observed, deadline):
    paths = sorted({c["hostExecutable"] for c in contexts if c["pid"] == pid})
    predicate = " OR ".join("processImagePath == " + json.dumps(path) for path in paths)
    dates = [datetime.fromtimestamp(stamp, timezone.utc).strftime("%Y-%m-%d %H:%M:%S%z")
             for stamp in (started - 1, observed + 1)]
    command = ["/usr/bin/log", "show", "--style", "json", "--no-pager", "--info", "--debug",
               "--process", str(pid), "--start", dates[0], "--end", dates[1], "--predicate", predicate]
    result, captured, discarded = dict(command=command), bytearray(), 0
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    selector = selectors.DefaultSelector()
    try:
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        end = min(deadline, time.monotonic() + 5)
        eof = False
        while not (eof and process.poll() is not None):
            require(time.monotonic() < end, "worker log query timed out")
            for key, _ in selector.select(min(0.1, max(0, end - time.monotonic()))):
                try:
                    block = os.read(key.fd, 65_536)
                except BlockingIOError:
                    continue
                if not block:
                    eof = True
                    selector.unregister(key.fileobj)
                    continue
                remaining = max(0, 4 * 1024 * 1024 - len(captured))
                captured.extend(block[:remaining])
                discarded += max(0, len(block) - remaining)
        result["exitCode"] = process.wait(timeout=1)
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        process.stdout.close()
        (folder / ("process-" + str(pid) + ".log")).write_bytes(captured)
        result.update(bytes=len(captured), discardedBytes=discarded)
    return result


def collect_worker_postmortem(output, host_pid, source_sha, preparation, started):
    folder = output / "worker-postmortem"
    folder.mkdir()
    observed = time.time()
    receipt = dict(schema="nexgenvideo/bpy-worker-postmortem/1", appSourceSHA=source_sha,
                   harnessSHA=os.environ.get("GITHUB_SHA", ""), hostPID=host_pid,
                   contexts=[], reports=[], errors=[], candidateStatus={},
                   preparationErrors=preparation["preparationErrors"],
                   baselineErrors=preparation.get("baselineErrors", []),
                   causality="An encoded exit status does not identify the crash cause")
    paths = sorted(output.glob("open-failure-*.json"))
    require(len(paths) <= 16, "failed-response record bound exceeded")
    for path in paths:
        try:
            receipt["contexts"].extend(failed_worker_contexts(path, host_pid, source_sha, preparation, started, observed))
        except InterruptedError:
            raise
        except (OSError, ValueError, TypeError, KeyError, AssertionError) as error:
            receipt["errors"].append(dict(file=path.name, error=str(error)))
    pending = {c["pid"] for c in receipt["contexts"]}
    deadline, previous, checked = time.monotonic() + 30, {}, {}
    receipt["unifiedLogs"] = {}
    for pid in sorted(pending):
        if time.monotonic() >= deadline:
            break
        try:
            receipt["unifiedLogs"][str(pid)] = capture_worker_log(
                folder, pid, receipt["contexts"], started, observed, deadline)
        except InterruptedError:
            raise
        except (OSError, subprocess.SubprocessError, AssertionError) as error:
            receipt["unifiedLogs"][str(pid)] = dict(error=str(error))
    directories = [Path(p) for p in preparation["directories"]]
    while pending and time.monotonic() < deadline:
        candidates, receipt["scanErrors"] = report_candidates(directories, preparation["prefixes"])
        for name, identity in candidates.items():
            if not pending or time.monotonic() >= deadline:
                break
            if identity == preparation["baseline"].get(name) or identity != previous.get(name) or identity == checked.get(name):
                continue
            checked[name] = identity
            try:
                raw = read_stable_crash_report(name, identity)
                contexts = [c for c in receipt["contexts"] if c["pid"] in pending]
                rejections = []
                for context in contexts:
                    try:
                        binding = owned_crash_report(raw, context)
                    except (ValueError, TypeError, KeyError) as error:
                        rejections.append(str(error))
                        continue
                    destination = folder / ("worker-" + str(context["pid"]) + ".ips")
                    destination.write_bytes(raw)
                    receipt["reports"].append(dict(file=destination.name, bytes=len(raw), pid=context["pid"],
                        sha256=hashlib.sha256(raw).hexdigest(), expectedImage=context["hostExecutable"], **binding))
                    pending.remove(context["pid"])
                    break
                else:
                    raise ValueError("; ".join(sorted(set(rejections))) or "No pending owned worker identity")
                receipt["candidateStatus"][name] = "Bound original worker report copied"
            except InterruptedError:
                raise
            except (OSError, ValueError, TypeError, KeyError) as error:
                receipt["candidateStatus"][name] = str(error)
        previous = candidates
        if pending:
            time.sleep(min(1, max(0, deadline - time.monotonic())))
    receipt["missingPIDs"] = sorted(pending)
    receipt["status"] = "bound-report-captured" if receipt["reports"] else "no-bound-report"
    (folder / "receipt.json").write_text(json.dumps(receipt, sort_keys=True) + "\n")
    return receipt


def supervise(binary, output, mode, source_sha, timeout):
    output.mkdir(parents=True, exist_ok=True)
    proof_path = output / "armed.json"
    require(not proof_path.exists(), "occupied host-crash proof")
    environment = dict(os.environ, NGV_BPY_COMMAND_EVIDENCE=str(output))
    if mode != "runtime":
        environment.update(NGV_SELFTEST_BPY_HOST_CRASH=mode, NGV_SELFTEST_BPY_HOST_CRASH_EVIDENCE=str(proof_path))
    captured = set()
    try:
        postmortem = prepare_worker_postmortem(binary)
    except InterruptedError:
        raise
    except Exception as error:
        diagnostic_error(output, "worker-postmortem-preparation", error)
        postmortem = None
    start = time.time()
    deadline = time.monotonic() + timeout
    with (output / "runtime.log").open("wb") as stdout, (output / "runtime-stderr.log").open("wb") as stderr:
        process = subprocess.Popen([str(binary), "-hangDiagnosticMode", "disabled"],
            env=environment, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
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
            except InterruptedError:
                raise
            except Exception as sample_error:
                diagnostic_error(output, "sample", sample_error)
            if postmortem is not None and not isinstance(error, (InterruptedError, KeyboardInterrupt, SystemExit)):
                try:
                    collect_worker_postmortem(output, process.pid, source_sha, postmortem, start)
                except InterruptedError:
                    raise
                except Exception as capture_error:
                    diagnostic_error(output, "worker-postmortem", capture_error)
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
        if args.mode != "runtime":
            output = args.output.resolve()
            raw = (output / "open-events.ndjson").read_bytes()
            process = json.loads((output / "process-result.json").read_text())
            proof = verify_storage_scope(raw.decode(), process, binary)
            proof.update(sourceSHA=args.source_sha, openEventsSHA256=hashlib.sha256(raw).hexdigest())
            (output / "storage-scope-proof.json").write_text(json.dumps(proof, sort_keys=True) + "\n")
    else:
        supervise(binary, args.output.resolve(), args.mode, args.source_sha, timeout)


if __name__ == "__main__":
    main()
