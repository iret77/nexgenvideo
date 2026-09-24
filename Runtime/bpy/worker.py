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
    state = {
        "expected": None,
        "failure": None,
        "observed": 0,
        "scenarios": [],
    }
    verifier_camera_prefix = "NGV_GEOMETRY_VERIFIER_CAMERA_"
    verifier_camera_identities = set()

    class NGVGeometryVerifier(bpy.types.RenderEngine):
        bl_idname = "NGV_GEOMETRY_VERIFIER"
        bl_label = "NexGenVideo Geometry Verifier"

        def render(self, depsgraph):
            counts = {"objects": 0, "vertices": 0, "polygons": 0}
            try:
                expected = state["expected"]
                if expected is None:
                    raise RuntimeError("unexpected render geometry callback")
                actual = (
                    depsgraph.scene.as_pointer(),
                    depsgraph.view_layer.as_pointer(),
                )
                if actual != expected[0]:
                    raise RuntimeError(
                        "render geometry callback mismatch: "
                        f"expected={expected[1]}, actual="
                        f"{depsgraph.scene.name}/{depsgraph.view_layer.name}"
                    )
                if state["observed"] != 0:
                    raise RuntimeError(
                        f"duplicate render geometry callback for {expected[1]}"
                    )
                state["observed"] = 1
                for instance in depsgraph.object_instances:
                    obj = instance.object
                    original = getattr(obj, "original", None)
                    source_object = original if original is not None else obj
                    if source_object.as_pointer() in verifier_camera_identities:
                        continue
                    counts["objects"] += 1
                    if counts["objects"] > limits["objects"]:
                        raise RuntimeError(
                            f"evaluated object limit exceeded: {counts['objects']}"
                        )
                    if obj.type != "MESH":
                        continue
                    mesh = obj.to_mesh(
                        preserve_all_data_layers=False,
                        depsgraph=depsgraph,
                    )
                    try:
                        counts["vertices"] += len(mesh.vertices)
                        counts["polygons"] += len(mesh.polygons)
                    finally:
                        obj.to_mesh_clear()
                    if (
                        counts["vertices"] > limits["vertices"]
                        or counts["polygons"] > limits["polygons"]
                    ):
                        raise RuntimeError(
                            "evaluated geometry limit exceeded: "
                            f"vertices={counts['vertices']}, "
                            f"polygons={counts['polygons']}"
                        )
                state["scenarios"].append((expected[1], counts))
            except BaseException as error:
                state["failure"] = str(error)
            result = self.begin_result(0, 0, 1, 1)
            self.end_result(result)

    originals = []
    temporary_cameras = []
    bpy.utils.register_class(NGVGeometryVerifier)
    try:
        for scene in bpy.data.scenes:
            originals.append((
                scene,
                scene.render.engine,
                scene.render.use_compositing,
                scene.render.use_sequencer,
                scene.camera,
            ))
            if scene.camera is None:
                camera_data = bpy.data.cameras.new(verifier_camera_prefix + scene.name)
                camera = bpy.data.objects.new(verifier_camera_prefix + scene.name, camera_data)
                scene.collection.objects.link(camera)
                scene.camera = camera
                verifier_camera_identities.add(camera.as_pointer())
                temporary_cameras.append((scene, camera, camera_data))
            scene.render.engine = NGVGeometryVerifier.bl_idname
            scene.render.use_compositing = False
            scene.render.use_sequencer = False
            enabled_layers = [
                view_layer
                for view_layer in scene.view_layers
                if getattr(view_layer, "use", True)
            ]
            if not enabled_layers:
                fail(f"render geometry has no enabled view layer for {scene.name}")
            for view_layer in enabled_layers:
                token = f"{scene.name}/{view_layer.name}"
                state["expected"] = (
                    (scene.as_pointer(), view_layer.as_pointer()),
                    token,
                )
                state["failure"] = None
                state["observed"] = 0
                result = bpy.ops.render.render(
                    animation=False,
                    write_still=False,
                    use_viewport=False,
                    scene=scene.name,
                    layer=view_layer.name,
                )
                if state["failure"] is not None:
                    fail(
                        f"render geometry rejected for {scene.name}/{view_layer.name}: "
                        f"{state['failure']}"
                    )
                if "FINISHED" not in result:
                    fail(f"render geometry evaluation failed for {token}")
                if state["observed"] != 1:
                    fail(f"render geometry callback missing for {token}")
                state["expected"] = None
    finally:
        for scene, engine, compositing, sequencer, camera in originals:
            scene.render.engine = engine
            scene.render.use_compositing = compositing
            scene.render.use_sequencer = sequencer
            scene.camera = camera
        for scene, camera, camera_data in temporary_cameras:
            if camera.name in scene.collection.objects:
                scene.collection.objects.unlink(camera)
            bpy.data.objects.remove(camera)
            bpy.data.cameras.remove(camera_data)
        bpy.utils.unregister_class(NGVGeometryVerifier)
    if not state["scenarios"]:
        fail("render geometry produced no verified scene/view-layer scenarios")
    return tuple(
        max(scenario[field] for _, scenario in state["scenarios"])
        for field in ("objects", "vertices", "polygons")
    )


def render_contract(bpy, limits):
    scenes = []
    for scene in bpy.data.scenes:
        width = int(scene.render.resolution_x)
        height = int(scene.render.resolution_y)
        percentage = int(scene.render.resolution_percentage)
        effective_width = width * percentage // 100
        effective_height = height * percentage // 100
        pixels = effective_width * effective_height
        if (
            width <= 0
            or height <= 0
            or percentage <= 0
            or percentage > 100
            or effective_width < 1
            or effective_height < 1
            or pixels < 1
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
            "effectiveWidth": effective_width,
            "effectiveHeight": effective_height,
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


def text_value(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="strict")
    return str(value)


def blender_binary_evidence(bpy):
    libraries = {}
    for name in ("alembic", "ocio", "oiio", "opensubdiv", "openvdb", "sdl", "usd"):
        library = getattr(bpy.app, name)
        libraries[name] = {
            "supported": bool(library.supported),
            "version": list(library.version),
            "versionString": text_value(library.version_string),
        }
    return {
        "blenderBuildHash": text_value(bpy.app.build_hash),
        "blenderBuildBranch": text_value(bpy.app.build_branch),
        "blenderBuildType": text_value(bpy.app.build_type),
        "blenderBuildSystem": text_value(bpy.app.build_system),
        "libraryVersions": libraries,
    }


def verify_scene(config):
    started = time.monotonic()
    bpy, _, _ = load_runtime(config["sitePackages"])
    load_scene(bpy, config["scenePath"], False)
    scenes = render_contract(bpy, config["limits"])
    objects, vertices, polygons = evaluated_geometry(bpy, config["limits"])
    denied, network = denial_contract(config.get("diagnosticDeniedPaths", []))
    manifest = {
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
    }
    manifest.update(blender_binary_evidence(bpy))
    write_manifest(config["manifest"], manifest)


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
