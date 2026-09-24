import json
import os
import resource
import socket
import sys
import time
import traceback
from pathlib import Path


def fail(message):
    print(message, file=sys.stderr, flush=True)
    raise SystemExit(70)


def write_manifest(path, payload):
    destination = Path(path)
    temporary = destination.with_suffix(destination.suffix + ".part")
    temporary.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    os.replace(temporary, destination)


def apply_limits(config):
    try:
        os.setpgid(0, 0)
    except PermissionError:
        pass
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (config["outputBytes"], config["outputBytes"]))
    resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
    resource.setrlimit(resource.RLIMIT_CPU, (config["cpuSeconds"], config["cpuSeconds"]))
    if hasattr(resource, "RLIMIT_AS"):
        resource.setrlimit(resource.RLIMIT_AS, (config["memoryBytes"], config["memoryBytes"]))
    if not hasattr(resource, "RLIMIT_NPROC"):
        fail("RLIMIT_NPROC is unavailable")
    resource.setrlimit(resource.RLIMIT_NPROC, (0, 0))


def load_runtime(site_packages):
    root = str(Path(site_packages).resolve())
    sys.path[:] = [root] + [path for path in sys.path if "site-packages" not in path]
    import bpy
    import bmesh
    import mathutils

    return bpy, bmesh, mathutils


def load_scene(bpy, scene_path, use_scripts):
    bpy.context.preferences.filepaths.use_scripts_auto_execute = use_scripts
    if scene_path:
        bpy.ops.wm.open_mainfile(
            filepath=str(Path(scene_path).resolve()),
            load_ui=False,
            use_scripts=use_scripts,
        )
    else:
        bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.preferences.filepaths.use_scripts_auto_execute = use_scripts


def probe(config):
    started = time.monotonic()
    bpy, _, _ = load_runtime(config["sitePackages"])
    write_manifest(config["manifest"], {
        "schema": "nexgenvideo/bpy-probe/1",
        "pythonVersion": ".".join(map(str, sys.version_info[:3])),
        "bpyVersion": bpy.app.version_string,
        "bpyModule": str(Path(bpy.__file__).resolve()),
        "executable": str(Path(sys.executable).resolve()),
        "processIdentifier": os.getpid(),
        "startupSeconds": time.monotonic() - started,
    })


def execute_job(config):
    bpy, bmesh, mathutils = load_runtime(config["sitePackages"])
    load_scene(bpy, config.get("confirmedScene"), False)
    input_dir = Path(config["inputDirectory"]).resolve()
    output_dir = Path(config["outputDirectory"]).resolve()
    session_root = Path(config["sessionRoot"]).resolve()
    if session_root not in input_dir.parents or session_root not in output_dir.parents:
        fail("job path escaped the session root")
    output_dir.mkdir(parents=True, exist_ok=False)
    namespace = {
        "__builtins__": __builtins__,
        "bpy": bpy,
        "bmesh": bmesh,
        "mathutils": mathutils,
        "Path": Path,
        "session_root": session_root,
        "input_dir": input_dir,
        "output_dir": output_dir,
    }
    source = Path(config["sourcePath"]).read_text()
    exec(compile(source, f"<ngv-bpy-job:{config['jobID']}>", "exec"), namespace)
    bpy.context.preferences.filepaths.use_scripts_auto_execute = False
    bpy.ops.wm.save_as_mainfile(
        filepath=str(output_dir / "scene.blend"),
        check_existing=False,
        relative_remap=False,
        compress=True,
    )


def evaluated_geometry(bpy, limits):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    objects = 0
    vertices = 0
    polygons = 0
    for instance in depsgraph.object_instances:
        objects += 1
        if objects > limits["objects"]:
            fail(f"evaluated object limit exceeded: {objects}")
        obj = instance.object
        if obj.type != "MESH":
            continue
        mesh = obj.to_mesh(preserve_all_data_layers=False, depsgraph=depsgraph)
        try:
            vertices += len(mesh.vertices)
            polygons += len(mesh.polygons)
        finally:
            obj.to_mesh_clear()
        if vertices > limits["vertices"] or polygons > limits["polygons"]:
            fail(
                f"evaluated geometry limit exceeded: vertices={vertices}, polygons={polygons}"
            )
    return objects, vertices, polygons


def render_contract(bpy, limits):
    scenes = []
    for scene in bpy.data.scenes:
        width = int(scene.render.resolution_x)
        height = int(scene.render.resolution_y)
        percentage = int(scene.render.resolution_percentage)
        pixels = width * height * percentage * percentage // 10_000
        if (
            width <= 0
            or height <= 0
            or percentage <= 0
            or percentage > 100
            or width > limits["renderWidth"]
            or height > limits["renderHeight"]
            or pixels > limits["renderPixels"]
        ):
            fail(
                f"render limit exceeded: width={width}, height={height}, pixels={pixels}"
            )
        scenes.append({
            "name": scene.name,
            "width": width,
            "height": height,
            "percentage": percentage,
            "pixels": pixels,
            "engine": scene.render.engine,
            "cyclesDevice": getattr(getattr(scene, "cycles", None), "device", None),
        })
    return scenes


def denial_contract(paths):
    denied = {}
    for path in paths:
        try:
            with open(path, "rb") as handle:
                handle.read(1)
            denied[path] = {"denied": False, "errno": None}
        except OSError as error:
            denied[path] = {"denied": True, "errno": error.errno}
    try:
        connection = socket.create_connection(("1.1.1.1", 443), timeout=1)
        connection.close()
        network = {"denied": False, "errno": None}
    except OSError as error:
        network = {"denied": True, "errno": error.errno}
    return denied, network


def verify_scene(config):
    started = time.monotonic()
    bpy, _, _ = load_runtime(config["sitePackages"])
    load_scene(bpy, config["scenePath"], False)
    objects, vertices, polygons = evaluated_geometry(bpy, config["limits"])
    scenes = render_contract(bpy, config["limits"])
    denied, network = denial_contract(config.get("diagnosticDeniedPaths", []))
    write_manifest(config["manifest"], {
        "schema": "nexgenvideo/bpy-verification/1",
        "jobID": config["jobID"],
        "fingerprint": config["fingerprint"],
        "pythonVersion": ".".join(map(str, sys.version_info[:3])),
        "bpyVersion": bpy.app.version_string,
        "executable": str(Path(sys.executable).resolve()),
        "bpyModule": str(Path(bpy.__file__).resolve()),
        "processIdentifier": os.getpid(),
        "verificationSeconds": time.monotonic() - started,
        "objects": objects,
        "vertices": vertices,
        "polygons": polygons,
        "scenes": scenes,
        "objectNames": sorted(obj.name for obj in bpy.data.objects),
        "modifiers": {
            obj.name: [modifier.type for modifier in obj.modifiers]
            for obj in bpy.data.objects if obj.modifiers
        },
        "autorunTextPresent": "NGV_AutorunProbe.py" in bpy.data.texts,
        "autorunMarkerAbsent": "AUTORUN_RAN" not in bpy.data.objects,
        "deniedPaths": denied,
        "networkDenied": network,
        "secretEnvironmentAbsent": all(
            name not in os.environ
            for name in (
                "RUNWAY_API_KEY",
                "ANTHROPIC_API_KEY",
                "OPENAI_API_KEY",
                "NGV_TEST_SECRET",
            )
        ),
        "blenderUserConfig": os.environ.get("BLENDER_USER_CONFIG"),
        "sessionRoot": config["sessionRoot"],
    })


def autoexec_positive_control(config):
    bpy, _, _ = load_runtime(config["sitePackages"])
    load_scene(bpy, config["scenePath"], True)
    write_manifest(config["manifest"], {
        "schema": "nexgenvideo/bpy-autoexec-positive/1",
        "jobID": config["jobID"],
        "processIdentifier": os.getpid(),
        "autorunMarkerPresent": "AUTORUN_RAN" in bpy.data.objects,
    })


def main():
    if len(sys.argv) != 3:
        fail("invalid worker bootstrap arguments")
    mode = sys.argv[1]
    descriptor_limit = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
    if descriptor_limit == resource.RLIM_INFINITY:
        descriptor_limit = 1_048_576
    os.closerange(3, min(int(descriptor_limit), 1_048_576))
    config = json.loads(Path(sys.argv[2]).read_text())
    apply_limits(config)
    if mode == "probe":
        probe(config)
    elif mode == "job":
        execute_job(config)
    elif mode == "verify":
        verify_scene(config)
    elif mode == "autoexec-positive":
        autoexec_positive_control(config)
    else:
        fail("invalid worker mode")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except MemoryError:
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(71)
    except BaseException:
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(70)
