"""Compare the exact failed scene outside Seatbelt without qualifying the App."""
import argparse
import base64
import binascii
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_macos_tests import host_binary_identity

SOURCE_PATH = "Sources/NexGenVideo/ThreeD/BpyRuntimeSelfTest.swift"
SCOPE = "unconfined-metal-diagnostic-not-product-acceptance"


class ControlCancelled(BaseException):
    pass


def cancel(number, _frame):
    raise ControlCancelled(number)


SCENE_TRACE = r'''
import faulthandler, sys, time

class SceneObservationFailed(BaseException):
    pass

def device_snapshot(bpy):
    scene = bpy.context.scene
    preferences = bpy.context.preferences.addons["cycles"].preferences
    devices = []
    for item in preferences.devices:
        if len(devices) == 64:
            raise ValueError("device inventory exceeds its bound")
        devices.append(dict(type=str(item.type)[:256], name=str(item.name)[:256], use=bool(item.use)))
    return dict(device=str(scene.cycles.device)[:256], engine=str(scene.render.engine)[:256],
        samples=scene.cycles.samples, computeDeviceType=str(preferences.compute_device_type)[:256], devices=devices)

def observe_scene(source, namespace, bpy, receipt, persist):
    code = compile(source, "<ngv-exact-scene-metal-control>", "exec")
    lines = {index for index, line in enumerate(source.decode().splitlines(), 1)
             if line.strip() == "bpy.ops.render.render(write_still=True)"}
    if not 1 <= len(lines) <= 2:
        raise SceneObservationFailed("expected one or two exact render call sites")
    calls = receipt["renderCalls"] = []
    active = None
    def trace(frame, event, arg):
        nonlocal active
        if frame.f_code is not code:
            return None
        try:
            if active is not None and event in ("line", "return", "exception"):
                active.update(state="raised" if event == "exception" else "returned",
                    endedWall=time.time(), endedMonotonic=time.monotonic())
                if event == "exception":
                    active.update(error=arg[0].__name__[:256], message=str(arg[1])[:512])
                active = None
                persist()
            if event == "line" and frame.f_lineno in lines:
                if len(calls) >= len(lines):
                    raise ValueError("render call count exceeds its bound")
                active = dict(ordinal=len(calls) + 1, line=frame.f_lineno, state="entered",
                    enteredWall=time.time(), enteredMonotonic=time.monotonic(), **device_snapshot(bpy))
                calls.append(active)
                persist()
        except Exception as error:
            raise SceneObservationFailed("render observation failed: " + type(error).__name__) from error
        return trace
    previous, timer = sys.gettrace(), False
    try:
        faulthandler.dump_traceback_later(20, repeat=True, file=sys.stderr, exit=False)
        timer = True
        sys.settrace(trace)
        exec(code, namespace)
    finally:
        try:
            sys.settrace(previous)
        finally:
            if timer:
                faulthandler.cancel_dump_traceback_later()
'''


CHILD = SCENE_TRACE + r'''
import hashlib, json, os, signal
from pathlib import Path
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGINT, signal.SIGTERM})
config = json.loads(Path(sys.argv[1]).read_text())
root = Path(config["root"])
receipt = dict(schema="nexgenvideo/bpy-metal-control-result/1", scope=config["scope"],
    appSourceSHA=config["source"], sceneSHA256=config["sceneSHA256"], pid=os.getpid(),
    executable=str(Path(sys.executable).resolve()), python=sys.version.split()[0], phases=[], renderCalls=[],
    metalAsyncPSOCreation=os.environ.get("CYCLES_METAL_ASYNC_PSO_CREATION"))
def persist():
    temporary = root / "result.part"
    temporary.write_text(json.dumps(receipt, sort_keys=True) + "\n")
    temporary.replace(root / "result.json")
def save(state):
    receipt["state"] = state
    receipt["phases"].append(dict(state=state, wall=time.time(), monotonic=time.monotonic()))
    persist()
save("loading")
try:
    if receipt["metalAsyncPSOCreation"] != "0":
        raise RuntimeError("synchronous Metal diagnostic flag differs")
    runtime = Path(config["runtime"])
    worker_path = Path(config["worker"])
    worker_bytes = worker_path.read_bytes()
    receipt["workerSHA256"] = hashlib.sha256(worker_bytes).hexdigest()
    if receipt["workerSHA256"] != config["workerSHA256"]:
        raise RuntimeError("original worker bytes changed")
    worker = dict(__name__="ngv_metal_control", __file__=str(worker_path))
    exec(compile(worker_bytes, str(worker_path), "exec"), worker)
    bpy, bmesh, mathutils, native = worker["load_runtime"](str(runtime / "site-packages"))
    receipt.update(bpy=".".join(map(str, bpy.app.version)), nativeModule=native,
        bpyModuleSHA256=hashlib.sha256(Path(native).read_bytes()).hexdigest())
    if native != config["nativeModule"] or receipt["bpyModuleSHA256"] != config["bpyModuleSHA256"]:
        raise RuntimeError("original bpy module bytes changed")
    save("runtimeLoaded")
    source = (root / "scene.py").read_bytes()
    if hashlib.sha256(source).hexdigest() != config["sceneSHA256"]:
        raise RuntimeError("bound scene bytes changed")
    save("rendering")
    observe_scene(source,
         dict(bpy=bpy, bmesh=bmesh, mathutils=mathutils, Path=Path,
              input_dir=root / "inputs", output_dir=root / "outputs"), bpy, receipt, persist)
    receipt.update(device_snapshot(bpy))
    save("completed")
except BaseException as error:
    receipt.update(error=type(error).__name__, message=str(error)[:512])
    save("failed")
    raise
'''


def scene_source(raw):
    matches = re.findall(r'private static func acceptanceSceneSource\(\) -> String \{\n'
                         r'        """\n(.*?)\n        """\n    }', raw.decode(), re.S)
    if len(matches) != 1:
        raise ValueError("one original acceptance scene required")
    lines = matches[0].split("\n")
    if any(line and not line.startswith("        ") for line in lines):
        raise ValueError("unexpected Swift multiline indentation")
    value = "\n".join(line[8:] if line else "" for line in lines)
    result, index = [], 0
    while index < len(value):
        character = value[index]
        if character == "\\":
            index += 1
            if index == len(value) or value[index] != "\\":
                raise ValueError("unsupported Swift string escape or interpolation")
        result.append(character)
        index += 1
    return "".join(result).encode()


class SourceRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, target):
        raise ValueError("original source redirect refused")


def original_source(source):
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("invalid original source identity")
    request = urllib.request.Request(
        "https://api.github.com/repos/iret77/nexgenvideo/contents/" + SOURCE_PATH + "?ref=" + source,
        headers={"Authorization": "Bearer " + os.environ["GH_TOKEN"], "Accept": "application/vnd.github+json"})
    with urllib.request.build_opener(SourceRedirect()).open(request, timeout=30) as response:
        body = response.read(1024 * 1024 + 1)
    if len(body) > 1024 * 1024:
        raise ValueError("original scene response exceeds its bound")
    record = json.loads(body)
    if record.get("path") != SOURCE_PATH or record.get("encoding") != "base64":
        raise ValueError("foreign original source response")
    raw = base64.b64decode(record["content"].replace("\n", ""), validate=True)
    digest = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
    if len(raw) != record.get("size") or digest != record.get("sha"):
        raise ValueError("original source blob digest differs")
    return raw, digest


def prefetch_source(source, destination):
    raw, blob = original_source(source)
    destination.write_text(json.dumps(dict(schema="nexgenvideo/bpy-metal-source/1", sourceSHA=source,
        path=SOURCE_PATH, blobSHA=blob, content=base64.b64encode(raw).decode())) + "\n")


def source_input(source, path):
    with path.open("rb") as handle:
        data = handle.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise ValueError("bound original source input exceeds its limit")
    record = json.loads(data)
    if (record.get("schema") != "nexgenvideo/bpy-metal-source/1" or record.get("sourceSHA") != source
        or record.get("path") != SOURCE_PATH):
        raise ValueError("bound original source input differs")
    raw = base64.b64decode(record["content"], validate=True)
    blob = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
    if blob != record.get("blobSHA"):
        raise ValueError("bound original source input blob differs")
    return raw, blob


def environment(root):
    return {"USER": "nexgenvideo", "CYCLES_METAL_ASYNC_PSO_CREATION": "0",
            "HOME": str(root / "home"), "TMPDIR": str(root / "tmp"), "LANG": "en_US.UTF-8",
            "BLENDER_USER_CONFIG": str(root / "blender-config"),
            "BLENDER_USER_SCRIPTS": str(root / "blender-scripts"),
            "BLENDER_USER_DATAFILES": str(root / "blender-data")}


def leader_exited(pid):
    status = os.waitid(os.P_PID, pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    return status is not None and status.si_pid == pid


def group_rows(raw, pid):
    if len(raw) > 65536:
        raise ValueError("owned group output exceeds its bound")
    rows = []
    for line in raw.decode("ascii").splitlines():
        fields = line.split()
        if (len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit()
            or int(fields[0]) <= 1 or int(fields[1]) != pid or not re.fullmatch(r"[A-Za-z+<>-]+", fields[2])):
            raise ValueError("invalid or foreign owned-group row")
        rows.append(dict(pid=int(fields[0]), pgid=int(fields[1]), state=fields[2]))
        if len(rows) > 256:
            raise ValueError("owned group entry count exceeds its bound")
    if len({row["pid"] for row in rows}) != len(rows):
        raise ValueError("duplicate owned-group row")
    return rows


def group_snapshot(pid, root):
    selection = ["-x", "-g", str(pid)] if sys.platform == "darwin" else ["-s", str(pid)]
    command = ["/bin/ps", *selection, "-o", "pid=,pgid=,state="]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, env={"LANG": "C"})
    selector, raw, eof, timed_out = None, bytearray(), False, False
    try:
        selector = selectors.DefaultSelector()
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + 5
        while not (eof and leader_exited(process.pid)):
            if time.monotonic() >= deadline:
                timed_out = True
                raise ValueError("owned group inspection timed out")
            for key, _ in selector.select(min(.1, max(0, deadline - time.monotonic()))):
                block = os.read(key.fd, 65536)
                if not block:
                    eof = True
                    selector.unregister(key.fileobj)
                    continue
                raw.extend(block[:max(0, 65537 - len(raw))])
                if len(raw) > 65536:
                    raise ValueError("owned group output exceeds its bound")
    finally:
        try:
            if selector is not None:
                selector.close()
        finally:
            try:
                if not leader_exited(process.pid):
                    os.kill(process.pid, signal.SIGKILL)
            finally:
                try:
                    code = process.wait(timeout=5)
                finally:
                    process.stdout.close()
    if code != 0 or timed_out:
        raise ValueError("owned group inspection failed")
    rows = group_rows(bytes(raw), pid)
    (root / "group-inventory.json").write_text(json.dumps(dict(command=command,
        bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(), rows=rows), sort_keys=True) + "\n")
    return rows


def run_bounded(command, child_environment, root, log, timeout=120):
    if not hasattr(os, "waitid") or not hasattr(os, "WNOWAIT"):
        raise RuntimeError("diagnostic supervision requires waitid with WNOWAIT")
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
    process, selector = None, None
    receipt = dict(parentPID=os.getpid(), timeoutSeconds=timeout, bytes=0, discardedBytes=0,
                   reaped=False, timedOut=False, groupKill="notAttempted",
                   startedWall=time.time(), startedMonotonic=time.monotonic())
    try:
        process = subprocess.Popen(command, cwd=root, env=child_environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        receipt["pid"] = process.pid
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        selector = selectors.DefaultSelector()
        os.set_blocking(process.stdout.fileno(), False)
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline, eof = time.monotonic() + timeout, False
        with log.open("xb") as out:
            while True:
                if eof:
                    if leader_exited(process.pid):
                        receipt["leaderExitObservedMonotonic"] = time.monotonic()
                        break
                if time.monotonic() >= deadline:
                    receipt["timedOut"] = True
                    break
                for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                    try:
                        block = os.read(key.fd, 65536)
                    except BlockingIOError:
                        continue
                    if not block:
                        eof = True
                        selector.unregister(key.fileobj)
                        continue
                    kept = block[:max(0, 4 * 1024 * 1024 - receipt["bytes"])]
                    out.write(kept)
                    receipt["bytes"] += len(kept)
                    receipt["discardedBytes"] += len(block) - len(kept)
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
        errors = []
        try:
            try:
                if selector is not None:
                    selector.close()
            except Exception as error:
                errors.append(type(error).__name__)
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                    receipt["groupKill"] = "sent"
                except ProcessLookupError:
                    receipt["groupKill"] = "absent"
                except (KeyboardInterrupt, ControlCancelled):
                    raise
                except PermissionError:
                    receipt["groupKill"] = "failed"
                    try:
                        if not leader_exited(process.pid):
                            raise ValueError("group permission failure without observed leader exit")
                        rows = group_snapshot(process.pid, root)
                        receipt["groupRows"] = rows[:64]
                        if len(rows) != 1 or rows[0]["pid"] != process.pid or not rows[0]["state"].startswith("Z"):
                            raise ValueError("group permission failure with live or unknown members")
                        receipt["groupKill"] = "zombieOnly"
                    except (KeyboardInterrupt, ControlCancelled):
                        raise
                    except Exception as error:
                        errors.append("PermissionError: " + str(error)[:256])
                except OSError as error:
                    errors.append(type(error).__name__)
                try:
                    receipt["exitCode"] = process.wait(timeout=5)
                    receipt["reaped"] = True
                except subprocess.TimeoutExpired:
                    errors.append("reaping timed out")
                    raise
        finally:
            try:
                if process is not None:
                    process.stdout.close()
            finally:
                receipt["cleanupErrors"] = errors
                receipt.update(endedWall=time.time(), endedMonotonic=time.monotonic())
                receipt["elapsedSeconds"] = receipt["endedMonotonic"] - receipt["startedMonotonic"]
                try:
                    (root / "supervision.json").write_text(json.dumps(receipt, sort_keys=True) + "\n")
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous)
        if errors:
            raise RuntimeError("owned control cleanup failed")
    return receipt


def image_bytes(path):
    with path.open("rb") as handle:
        data = handle.read(3_000_001)
    if len(data) > 3_000_000 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("missing bounded control image")
    offset, header, compressed, kind = 8, None, bytearray(), None
    while offset < len(data):
        if len(data) - offset < 12:
            raise ValueError("truncated control image")
        size = struct.unpack_from(">I", data, offset)[0]
        if size > len(data) - offset - 12:
            raise ValueError("truncated control chunk")
        kind, payload = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + size]
        if header is None and kind != b"IHDR":
            raise ValueError("control image has no first header")
        if binascii.crc32(kind + payload) & 0xffffffff != struct.unpack_from(">I", data, offset + size + 8)[0]:
            raise ValueError("control image checksum differs")
        if kind == b"IHDR":
            if header is not None or size != 13:
                raise ValueError("ambiguous control header")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        offset += size + 12
        if kind == b"IEND":
            if size != 0 or offset != len(data):
                raise ValueError("trailing control image bytes")
            break
    if header not in ((640, 360, 8, 2, 0, 0, 0), (640, 360, 8, 6, 0, 0, 0)) or kind != b"IEND":
        raise ValueError("control dimensions or format differ")
    stride = 640 * (3 if header[3] == 2 else 4) + 1
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(compressed, stride * 360 + 1)
    if (not decoder.eof or decoder.unused_data or decoder.unconsumed_tail
        or len(pixels) != stride * 360 or any(pixels[y * stride] > 4 for y in range(360))):
        raise ValueError("invalid control raster")
    channels = 3 if header[3] == 2 else 4
    previous, first, varied = bytearray(stride - 1), None, False
    for y in range(360):
        mode = pixels[y * stride]
        row = bytearray(pixels[y * stride + 1:(y + 1) * stride])
        for index in range(len(row)):
            left = row[index - channels] if index >= channels else 0
            above, corner = previous[index], previous[index - channels] if index >= channels else 0
            candidate = left + above - corner
            distances = [abs(candidate - left), abs(candidate - above), abs(candidate - corner)]
            paeth = (left, above, corner)[distances.index(min(distances))]
            row[index] = (row[index] + (0, left, above, (left + above) // 2, paeth)[mode]) & 255
        for x in range(640):
            color = bytes(row[x * channels:x * channels + 3])
            if first is None:
                first = color
            varied = varied or color != first
        previous = row
    if not varied:
        raise ValueError("uniform control raster")
    return data


def read_json(path):
    with path.open("rb") as handle:
        raw = handle.read(65537)
    if len(raw) > 65536:
        raise ValueError("diagnostic receipt exceeds its bound")
    return json.loads(raw)


def valid_render_calls(calls, phases, supervision):
    if not isinstance(calls, list) or len(calls) > 2:
        return False
    rendering = next((p["monotonic"] for p in phases if p["state"] == "rendering"), None)
    previous = rendering
    for index, call in enumerate(calls):
        if (not isinstance(call, dict) or type(call.get("ordinal")) is not int or call["ordinal"] != index + 1
            or type(call.get("line")) is not int or not 1 <= call["line"] <= 100000
            or call.get("state") not in ("entered", "returned", "raised")
            or any(not isinstance(call.get(k), str) or len(call[k]) > 256
                   for k in ("device", "engine", "computeDeviceType"))
            or type(call.get("samples")) is not int or not 1 <= call["samples"] <= 1000000):
            return False
        devices = call.get("devices")
        if (not isinstance(devices, list) or len(devices) > 64
            or any(not isinstance(d, dict) or type(d.get("use")) is not bool
                   or any(not isinstance(d.get(k), str) or len(d[k]) > 256 for k in ("type", "name")) for d in devices)):
            return False
        keys = ("enteredWall", "enteredMonotonic")
        if call["state"] != "entered":
            keys += ("endedWall", "endedMonotonic")
        elif any(k in call for k in ("endedWall", "endedMonotonic")) or phases[-1]["state"] == "completed":
            return False
        if any(type(call.get(k)) not in (int, float) or not math.isfinite(call[k]) for k in keys):
            return False
        end = call.get("endedMonotonic", supervision["endedMonotonic"])
        if (previous is None or not previous <= call["enteredMonotonic"] <= end <= supervision["endedMonotonic"]
            or call["state"] == "entered" and index != len(calls) - 1
            or call["state"] != "entered" and end > phases[-1]["monotonic"] and phases[-1]["state"] in ("completed", "failed")
            or call["state"] == "raised" and any(not isinstance(call.get(k), str) or len(call[k]) > bound
                                                for k, bound in (("error", 256), ("message", 512)))):
            return False
        previous = end
    return True


def verdict(root, supervision, source, digest, executable, bindings):
    proof = dict(status="invalidReceipt", childState=None, phaseDurations=[],
                 imagePresent=(root / "outputs/render.png").is_file())
    try:
        result = read_json(root / "result.json")
    except (KeyboardInterrupt, ControlCancelled):
        raise
    except (OSError, ValueError) as error:
        proof.update(status="timedOutBeforeState" if supervision["timedOut"] else "processFailed",
                     childEvidenceError=str(error)[:256])
        return proof
    if (result.get("schema") != "nexgenvideo/bpy-metal-control-result/1"
        or result.get("scope") != SCOPE or result.get("appSourceSHA") != source
        or result.get("sceneSHA256") != digest or result.get("pid") != supervision["pid"]
        or result.get("executable") != str(executable) or result.get("python") != "3.13.15"
        or result.get("metalAsyncPSOCreation") != "0"):
        return proof
    phases = result.get("phases")
    allowed = ["loading", "runtimeLoaded", "rendering", "completed"]
    if (not isinstance(phases, list) or not 1 <= len(phases) <= 5
        or any(not isinstance(p, dict) or p.get("state") not in allowed + ["failed"]
               or any(type(p.get(k)) not in (float, int) or not math.isfinite(p[k]) for k in ("wall", "monotonic")) for p in phases)
        or result.get("state") != phases[-1]["state"]):
        return proof
    states = [p["state"] for p in phases]
    normal = states[:-1] if states[-1] == "failed" else states
    if (normal != allowed[:len(normal)] or any(a["monotonic"] > b["monotonic"] for a, b in zip(phases, phases[1:]))
        or phases[0]["monotonic"] < supervision["startedMonotonic"]
        or phases[-1]["monotonic"] > supervision["endedMonotonic"]
        or not valid_render_calls(result.get("renderCalls"), phases, supervision)):
        return proof
    proof["childState"] = result["state"]
    proof["child"] = {k: result[k] for k in ("state", "device", "samples", "engine", "computeDeviceType",
        "devices", "workerSHA256", "nativeModule", "bpyModuleSHA256", "phases", "renderCalls",
        "metalAsyncPSOCreation", "error", "message") if k in result}
    for index, phase in enumerate(phases):
        end = phases[index + 1]["monotonic"] if index + 1 < len(phases) else supervision["endedMonotonic"]
        proof["phaseDurations"].append(dict(state=phase["state"], seconds=end - phase["monotonic"]))
    if supervision["timedOut"]:
        proof["status"] = {"completed": "timedOutAfterCompletion", "rendering": "timedOutDuringRender",
                           "failed": "timedOutAfterFailure", "loading": "timedOutWhileLoading",
                           "runtimeLoaded": "timedOutWhileLoading"}[result["state"]]
        return proof
    if supervision.get("exitCode") != 0 or not supervision["reaped"]:
        proof["status"] = ("observationFailed" if supervision.get("exitCode") != 0 and result.get("error") == "SceneObservationFailed"
                           else "processFailedAfterCompletion" if result["state"] == "completed" else "processFailed")
        return proof
    if (result.get("state") != "completed" or result.get("bpy") != "5.2.2"
        or result.get("engine") != "CYCLES" or result.get("samples") != 8
        or not result["renderCalls"] or result["renderCalls"][-1]["state"] != "returned"
        or result["renderCalls"][-1]["device"] != result.get("device")
        or any(call["engine"] != "CYCLES" or call["samples"] != 8 for call in result["renderCalls"])
        or any(result.get(k) != bindings[k] for k in ("workerSHA256", "nativeModule", "bpyModuleSHA256"))):
        return proof
    if result.get("device") != "GPU":
        proof["status"] = "cpuFallbackNotGPUProof"
        return proof
    if len(result["renderCalls"]) != 1 or result["renderCalls"][0]["device"] != "GPU":
        return proof
    devices = result.get("devices")
    if (result.get("computeDeviceType") != "METAL" or not isinstance(devices, list) or not 1 <= len(devices) <= 64
        or any(not isinstance(d, dict) or type(d.get("use")) is not bool
               or any(not isinstance(d.get(k), str) or len(d[k]) > 256 for k in ("type", "name")) for d in devices)
        or not any(d["type"] == "METAL" and d["use"] for d in devices)):
        return proof
    try:
        proof["imageSHA256"] = hashlib.sha256(image_bytes(root / "outputs/render.png")).hexdigest()
    except (KeyboardInterrupt, ControlCancelled):
        raise
    except (OSError, ValueError, zlib.error) as error:
        proof.update(status="invalidImage", imageError=str(error)[:256])
        return proof
    proof.update(status="gpuBranchCompletedDiagnosticOnly",
        meaning="The configured Metal GPU branch completed; this is not per-sample device attestation.")
    return proof


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inventory(root, limit=100000, partial=False):
    pending, entries, total, caches = [root], [], 0, []
    capped = False
    while pending and not capped:
        with os.scandir(pending.pop()) as children:
            for entry in children:
                if len(entries) >= limit:
                    if not partial:
                        raise ValueError("runtime inventory exceeds its entry bound")
                    capped = True
                    break
                path = Path(entry.path)
                info = entry.stat(follow_symlinks=False)
                relative = path.relative_to(root).as_posix()
                kind = "directory" if stat.S_ISDIR(info.st_mode) else "file" if stat.S_ISREG(info.st_mode) else "symlink" if stat.S_ISLNK(info.st_mode) else "other"
                value = dict(path=relative, kind=kind, bytes=info.st_size, mtimeNs=info.st_mtime_ns)
                if kind == "symlink":
                    value["target"] = os.readlink(path)
                elif kind == "directory":
                    pending.append(path)
                elif kind == "file":
                    total += info.st_size
                if "__pycache__" in path.parts:
                    caches.append(relative)
                entries.append(value)
    entries.sort(key=lambda x: x["path"])
    result = dict(observedEntries=len(entries), observedFileBytes=total, capped=capped,
        pycacheEntries=len(caches), pycacheExamples=sorted(caches)[:16],
        metadataSHA256=hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest())
    if partial:
        result["entries"] = entries
    return result


def error_text(error):
    message = str(error)
    token = os.environ.get("GH_TOKEN")
    if token:
        message = message.replace(token, "[redacted]")
    return re.sub(r"(?i)authorization[:=][^\r\n]*", "Authorization: [redacted]", message)[:512]


def exit_status(receipt):
    supervision = receipt.get("supervision", {})
    return int(bool(receipt.get("error") or receipt.get("status") in ("unverified", "interrupted")
                    or not supervision.get("reaped") or supervision.get("cleanupErrors")))


def collect(app, output, source, original_input=None):
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    receipt = dict(schema="nexgenvideo/bpy-metal-control/1", scope=SCOPE,
        diagnosticVariant="metal-synchronous-pso",
        appSourceSHA=source, harnessSHA=os.environ.get("GITHUB_SHA"),
        executionRunID=os.environ.get("GITHUB_RUN_ID"), status="unverified", phaseDurations=[],
        differences=["Seatbelt is not applied.", "App pressure, disk/file and physical-volume supervision are not applied.",
            "Production RLIMIT_CORE, FSIZE, CPU, NOFILE=256 and NPROC=0 are not applied.",
            "The supervisor execve launch and fixed descriptor layout are not reproduced.",
            "Storage uses synthetic ordinary directories rather than host-created APFS images.",
            "The confirmed warm-probe scene and load_scene scripts-auto-exec setting are not opened; the scene resets factory state itself.",
            "Production uses -I -S with denied pycache writes; this control adds -B to preserve App bytes and -u for unbuffered output.",
            "Exact-scene line tracing records state before each render call; a line event alone does not attest native renderer entry.",
            "A 20-second faulthandler watchdog repeats Python-only stacks into the bounded output; no native C stack is captured.",
            "This control supplies fixed USER=nexgenvideo; older App launch environments may omit USER.",
            "This diagnostic sets CYCLES_METAL_ASYNC_PSO_CREATION=0; the original App retains its source-stamped worker environment.",
            "Production runs save_as_mainfile after the scene; this control stops after the scene.",
            "This diagnostic runs before native App selftests in its job VM. Later native results are supplemental; VM order does not prove a clean physical GPU or cold OS-managed Metal caches."])
    scratch, bindings, executable, identity, runtime = None, None, None, None, None
    try:
        with (app / "Contents/Info.plist").open("rb") as f:
            if plistlib.load(f).get("NGVSourceCommit") != source:
                raise ValueError("original App source stamp differs")
        runtime = (app / "Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/Resources/BpyRuntime").resolve(strict=True)
        executable = (runtime / "python/bin/python3.13").resolve(strict=True)
        if not runtime.is_relative_to(app.resolve()) or not executable.is_relative_to(runtime):
            raise ValueError("runtime escaped the original App")
        identity = host_binary_identity(executable)
        if not identity["hostUUID"]:
            raise ValueError("original Python has no Mach image identity")
        worker = (runtime / "worker.py").resolve(strict=True)
        module = (runtime / "site-packages/bpy/__init__.so").resolve(strict=True)
        if (any(not p.is_relative_to(runtime) or not p.is_file() for p in (worker, module))
            or (runtime / "worker.py").is_symlink() or (runtime / "site-packages/bpy/__init__.so").is_symlink()):
            raise ValueError("worker or bpy module escaped the original runtime")
        bindings = dict(workerSHA256=file_digest(worker), nativeModule=str(module), bpyModuleSHA256=file_digest(module))
        receipt.update(bindings, workerPath=str(worker), runtimeBefore=inventory(runtime))
        raw, blob = source_input(source, original_input) if original_input is not None else original_source(source)
        scene = scene_source(raw)
        receipt.update(sourceBlobSHA=blob, sourceFileSHA256=hashlib.sha256(raw).hexdigest(),
            sceneSHA256=hashlib.sha256(scene).hexdigest(), pythonIdentity=identity,
            scriptSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            childSHA256=hashlib.sha256(CHILD.encode()).hexdigest())
        (output / "original-selftest.swift").write_bytes(raw)
        (output / "scene.py").write_bytes(scene)
        for name in ("inputs", "outputs"):
            (output / name).mkdir(mode=0o700)
        scratch = Path(tempfile.mkdtemp(prefix="ngv-metal-control-", dir=output.parent.parent))
        for name in ("home", "tmp", "blender-config", "blender-scripts", "blender-data"):
            (scratch / name).mkdir(mode=0o700)
        (output / "inputs/fixture.json").write_text('{"approved":true}\n')
        config = dict(root=str(output.resolve()), runtime=str(runtime), scope=SCOPE, worker=str(worker),
                      source=source, sceneSHA256=receipt["sceneSHA256"], **bindings)
        (output / "control.json").write_text(json.dumps(config) + "\n")
        (output / "control.py").write_text(CHILD)
        command = [str(executable), "-I", "-B", "-S", "-u", str(output / "control.py"), str(output / "control.json")]
        receipt["supervision"] = run_bounded(command, environment(scratch), output, output / "process.log")
    except (KeyboardInterrupt, ControlCancelled):
        receipt["status"] = "interrupted"
        raise
    except Exception as error:
        receipt.update(error=type(error).__name__, errorMessage=error_text(error))
    finally:
        try:
            if (output / "supervision.json").is_file():
                receipt["supervision"] = read_json(output / "supervision.json")
            supervision = receipt.get("supervision")
            if supervision and bindings:
                proof = verdict(output, supervision, source, receipt["sceneSHA256"], executable, bindings)
                status = receipt["status"]
                receipt.update(proof)
                if receipt.get("error") or status == "interrupted":
                    receipt["status"] = status
            if bindings is not None and "runtimeBefore" in receipt:
                receipt["runtimeAfter"] = inventory(runtime)
                receipt["runtimeUnchanged"] = receipt["runtimeBefore"] == receipt["runtimeAfter"]
                if (host_binary_identity(executable) != identity or file_digest(Path(receipt["workerPath"])) != bindings["workerSHA256"]
                    or file_digest(Path(bindings["nativeModule"])) != bindings["bpyModuleSHA256"] or not receipt["runtimeUnchanged"]):
                    raise ValueError("original runtime bytes or inventory changed during control")
        except (KeyboardInterrupt, ControlCancelled):
            receipt["status"] = "interrupted"
            raise
        except Exception as error:
            receipt.update(status="evidenceFailed", error=type(error).__name__, errorMessage=error_text(error))
        finally:
            try:
                if scratch is not None:
                    receipt["scratchInventory"] = inventory(scratch, limit=256, partial=True)
                    if not receipt.get("supervision") or receipt["supervision"].get("reaped"):
                        shutil.rmtree(scratch)
                        receipt["scratchRemoved"] = True
                    else:
                        receipt["scratchRetained"] = True
            except (KeyboardInterrupt, ControlCancelled):
                receipt["status"] = "interrupted"
                raise
            except Exception as error:
                receipt.update(error=type(error).__name__, errorMessage=error_text(error))
            finally:
                (output / "receipt.json").write_text(json.dumps(receipt, sort_keys=True) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-input", required=True, type=Path)
    arguments = parser.parse_args()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, cancel)
    result = collect(arguments.app.resolve(strict=True), arguments.output.resolve(), arguments.source_sha, arguments.source_input)
    print(json.dumps({"scope": result["scope"], "status": result["status"]}))
    raise SystemExit(exit_status(result))
