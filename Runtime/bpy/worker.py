import contextlib
import io
import json
import os
import resource
import sys
import threading
import time
import traceback
from pathlib import Path


def emit(payload):
    sys.__stdout__.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.__stdout__.flush()


def fail(message):
    emit({"type": "fatal", "message": message})
    raise SystemExit(70)


if len(sys.argv) != 10:
    fail("invalid worker bootstrap arguments")

site_packages = Path(sys.argv[1]).resolve()
session_root = Path(sys.argv[2]).resolve()
confirmed_scene = Path(sys.argv[3]).resolve() if sys.argv[3] != "-" else None
memory_limit = int(sys.argv[4])
object_limit = int(sys.argv[5])
vertex_limit = int(sys.argv[6])
polygon_limit = int(sys.argv[7])
stdout_limit = int(sys.argv[8])
output_limit = int(sys.argv[9])

try:
    os.setsid()
except PermissionError:
    pass

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_FSIZE, (output_limit, output_limit))
resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
if hasattr(resource, "RLIMIT_AS"):
    resource.setrlimit(resource.RLIMIT_AS, (memory_limit, memory_limit))


def audit(event, args):
    if event in {
        "os.exec",
        "os.fork",
        "os.forkpty",
        "os.kill",
        "os.killpg",
        "os.posix_spawn",
        "os.posix_spawnp",
        "os.spawn",
        "os.system",
        "pty.spawn",
        "subprocess.Popen",
    }:
        raise PermissionError("child processes are not permitted in the bpy worker")


sys.addaudithook(audit)

parent_pid = os.getppid()


def exit_with_parent():
    while os.getppid() == parent_pid:
        time.sleep(0.25)
    os._exit(71)


threading.Thread(target=exit_with_parent, daemon=True).start()

sys.path[:] = [str(site_packages)] + [path for path in sys.path if "site-packages" not in path]

started = time.monotonic()
import bpy
import bmesh
import mathutils


def reset_or_load():
    bpy.context.preferences.filepaths.use_scripts_auto_execute = False
    if confirmed_scene and confirmed_scene.is_file():
        bpy.ops.wm.open_mainfile(
            filepath=str(confirmed_scene), load_ui=False, use_scripts=False
        )
    else:
        bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.preferences.filepaths.use_scripts_auto_execute = False


reset_or_load()
emit({
    "type": "ready",
    "python_version": ".".join(map(str, sys.version_info[:3])),
    "bpy_version": bpy.app.version_string,
    "executable": str(Path(sys.executable).resolve()),
    "pid": os.getpid(),
    "startup_seconds": time.monotonic() - started,
})


class BoundedTextIO(io.StringIO):
    def write(self, value):
        remaining = max(0, stdout_limit - self.tell())
        if remaining:
            return super().write(str(value)[:remaining])
        return len(value)


for line in sys.stdin:
    try:
        command = json.loads(line)
    except Exception as error:
        fail(f"invalid command: {error}")
    if command.get("type") == "shutdown":
        emit({"type": "stopped"})
        raise SystemExit(0)
    if command.get("type") != "job":
        fail("unexpected command")

    job_id = command["job_id"]
    input_dir = Path(command["input_dir"]).resolve()
    output_dir = Path(command["output_dir"]).resolve()
    if session_root not in input_dir.parents or session_root not in output_dir.parents:
        fail("job path escaped the session root")
    output_dir.mkdir(parents=True, exist_ok=False)
    stdout = BoundedTextIO()
    metrics = {}
    progress_sequence = 0

    def progress(stage, fraction):
        nonlocal_holder[0] += 1
        emit({
            "type": "progress",
            "job_id": job_id,
            "sequence": nonlocal_holder[0],
            "stage": str(stage)[:128],
            "fraction": max(0.0, min(1.0, float(fraction))),
        })

    nonlocal_holder = [progress_sequence]
    namespace = {
        "__builtins__": __builtins__,
        "bpy": bpy,
        "bmesh": bmesh,
        "mathutils": mathutils,
        "Path": Path,
        "session_root": session_root,
        "input_dir": input_dir,
        "output_dir": output_dir,
        "progress": progress,
        "metrics": metrics,
    }
    edit_started = time.monotonic()
    try:
        progress("execute", 0.05)
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stdout):
            exec(compile(command["source"], f"<ngv-bpy-job:{job_id}>", "exec"), namespace)
        metrics.setdefault("edit_seconds", time.monotonic() - edit_started)
        objects = len(bpy.data.objects)
        vertices = sum(len(mesh.vertices) for mesh in bpy.data.meshes)
        polygons = sum(len(mesh.polygons) for mesh in bpy.data.meshes)
        if objects > object_limit or vertices > vertex_limit or polygons > polygon_limit:
            raise RuntimeError(
                f"geometry limit exceeded: objects={objects}, vertices={vertices}, polygons={polygons}"
            )
        metrics.update({
            "objects": float(objects),
            "vertices": float(vertices),
            "polygons": float(polygons),
            "peak_memory_bytes": float(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss),
        })
        progress("checkpoint", 0.9)
        scene_path = output_dir / "scene.blend"
        bpy.ops.wm.save_as_mainfile(
            filepath=str(scene_path), check_existing=False, relative_remap=False, compress=True
        )
        progress("complete", 1.0)
        emit({
            "type": "result",
            "job_id": job_id,
            "ok": True,
            "stdout": stdout.getvalue(),
            "metrics": metrics,
        })
    except BaseException as error:
        traceback.print_exc(file=stdout)
        emit({
            "type": "result",
            "job_id": job_id,
            "ok": False,
            "message": f"{type(error).__name__}: {error}",
            "stdout": stdout.getvalue(),
            "metrics": metrics,
        })
        raise SystemExit(70)
