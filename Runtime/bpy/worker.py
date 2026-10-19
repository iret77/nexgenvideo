import json
import errno
import hashlib
import math
import os
import resource
import socket
import struct
import sys
import time
import traceback
import uuid
from fractions import Fraction
from pathlib import Path


class ResourceLimitError(RuntimeError):
    pass


def resource_limit(message):
    raise ResourceLimitError(message)


def file_sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


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
        "ngv_evaluated_bounds": lambda poses, camera: evaluated_bounds(bpy, config["limits"], poses, camera),
    }
    source = Path(config["sourcePath"]).read_text()
    exec(compile(source, f"<ngv-bpy-job:{config['jobID']}>", "exec"), namespace)
    if bpy.context.scene.get("ngv_spatial_schema") == "spatial-scene/v1":
        identities = set()
        for obj in bpy.data.objects:
            if obj.type == "CAMERA":
                if "ngv_width" not in obj:
                    obj["ngv_width"] = bpy.context.scene.render.resolution_x * bpy.context.scene.render.resolution_percentage // 100
                if "ngv_height" not in obj:
                    obj["ngv_height"] = bpy.context.scene.render.resolution_y * bpy.context.scene.render.resolution_percentage // 100
            identity = obj.get("ngv_object_id")
            if not isinstance(identity, str) or identity in identities:
                identity = str(uuid.uuid4())
                obj["ngv_object_id"] = identity
            try:
                uuid.UUID(identity)
            except ValueError:
                identity = str(uuid.uuid4())
                obj["ngv_object_id"] = identity
            identities.add(identity)
        if bpy.data.libraries:
            fail("Portable scenes cannot retain linked Blender libraries")
        bpy.ops.file.pack_all()
        if bpy.utils.blend_paths(absolute=True, packed=False, local=False):
            fail("Portable scenes cannot retain unpacked external resources")
    bpy.context.preferences.filepaths.use_scripts_auto_execute = False
    bpy.ops.wm.save_as_mainfile(
        filepath=str(output_dir / "scene.blend"),
        check_existing=False,
        relative_remap=False,
        compress=False,
    )


def evaluated_geometry(bpy, limits, spatial_meshes=None, spatial_bounds=None, native_state=None):
    state = {
        "expected": None,
        "failure": None,
        "observed": 0,
        "scenarios": [],
        "native": None,
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
                if native_state is not None:
                    expected_poses, camera_id = native_state
                    objects = {obj.get("ngv_object_id"): obj for obj in bpy.data.objects
                               if obj.as_pointer() not in verifier_camera_identities}
                    if set(objects) != {pose["objectID"] for pose in expected_poses}:
                        raise RuntimeError("native evaluated object coverage differs")
                    evaluated_poses = []
                    for pose in expected_poses:
                        obj = objects[pose["objectID"]].evaluated_get(depsgraph)
                        values = [value for row in obj.matrix_world for value in row]
                        if any(not math.isfinite(a) or abs(a - b) > 0.000001 * max(1, abs(b))
                               for a, b in zip(values, pose["matrixWorld"])):
                            raise RuntimeError("evaluated object transform differs from the selected native pose")
                        evaluated_poses.append({"objectID": pose["objectID"], "matrixWorld": values})
                    camera_pose = next(pose for pose in evaluated_poses if pose["objectID"] == camera_id)
                    state["native"] = {"objects": evaluated_poses, "cameraMatrix": camera_pose["matrixWorld"],
                                       "scene": depsgraph.scene.name, "viewLayer": depsgraph.view_layer.name,
                                       "metersPerUnit": depsgraph.scene.unit_settings.scale_length}
                for instance in depsgraph.object_instances:
                    obj = instance.object
                    original = getattr(obj, "original", None)
                    source_object = original if original is not None else obj
                    if source_object.as_pointer() in verifier_camera_identities:
                        continue
                    counts["objects"] += 1
                    if counts["objects"] > limits["objects"]:
                        raise ResourceLimitError(
                            f"evaluated object limit exceeded: {counts['objects']}"
                        )
                    if obj.type != "MESH":
                        if spatial_bounds is None:
                            continue
                        if obj.type in {"CURVES", "POINTCLOUD", "VOLUME", "GREASEPENCIL"} and instance.show_self:
                            raise RuntimeError(f"Convert visible {obj.type} geometry to a baked mesh sequence before exporting the plan")
                        if obj.type not in {"CURVE", "FONT", "SURFACE", "META"}:
                            continue
                    mesh = obj.to_mesh(
                        preserve_all_data_layers=False,
                        depsgraph=depsgraph,
                    )
                    try:
                        counts["vertices"] += len(mesh.vertices)
                        counts["polygons"] += len(mesh.polygons)
                        if counts["vertices"] > limits["vertices"] or counts["polygons"] > limits["polygons"]:
                            raise ResourceLimitError("evaluated geometry limit exceeded")
                        if spatial_meshes is not None and instance.show_self:
                            mesh.calc_loop_triangles()
                            object_id = source_object.get("ngv_object_id")
                            uuid.UUID(object_id)
                            spatial_meshes.append({
                                "id": f"{object_id}:{len(spatial_meshes)}",
                                "objectID": object_id,
                                "matrixWorld": [value for row in instance.matrix_world for value in row],
                                "positions": [list(vertex.co) for vertex in mesh.vertices],
                                "triangles": [index for triangle in mesh.loop_triangles for index in triangle.vertices],
                            })
                        if spatial_bounds is not None and instance.show_self and mesh.vertices:
                            object_id = source_object.get("ngv_object_id")
                            uuid.UUID(object_id)
                            parent = instance.parent
                            parent_id = parent.original.get("ngv_object_id") if parent else ""
                            identity = f"{object_id}:{parent_id}:{tuple(instance.persistent_id)}"
                            lower, upper = [math.inf] * 3, [-math.inf] * 3
                            for vertex in mesh.vertices:
                                point = instance.matrix_world @ vertex.co
                                for axis in range(3):
                                    if not math.isfinite(point[axis]):
                                        raise RuntimeError("nonfinite evaluated mesh bounds")
                                    lower[axis] = min(lower[axis], point[axis])
                                    upper[axis] = max(upper[axis], point[axis])
                            spatial_bounds.append({"id": identity, "objectID": object_id,
                                                   "minimum": lower, "maximum": upper})
                    finally:
                        obj.to_mesh_clear()
                    if (
                        counts["vertices"] > limits["vertices"]
                        or counts["polygons"] > limits["polygons"]
                    ):
                        raise ResourceLimitError(
                            "evaluated geometry limit exceeded: "
                            f"vertices={counts['vertices']}, "
                            f"polygons={counts['polygons']}"
                        )
                state["scenarios"].append((expected[1], counts))
            except BaseException as error:
                state["failure"] = error
            result = self.begin_result(0, 0, 1, 1)
            self.end_result(result)

    originals = []
    temporary_cameras = []
    bpy.utils.register_class(NGVGeometryVerifier)
    try:
        scenes = [bpy.context.scene] if spatial_bounds is not None else bpy.data.scenes
        for scene in scenes:
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
            if spatial_bounds is not None:
                active_layer = bpy.context.view_layer
                if active_layer not in enabled_layers:
                    fail("The selected native render view layer is disabled")
                enabled_layers = [active_layer]
            if not enabled_layers:
                resource_limit(f"render geometry has no enabled view layer for {scene.name}")
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
                    if isinstance(state["failure"], ResourceLimitError):
                        raise state["failure"]
                    fail(f"render geometry rejected for {scene.name}/{view_layer.name}: {state['failure']}")
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
    if native_state is not None:
        if state["native"] is None:
            fail("render evaluation produced no native object poses")
        return state["native"]
    return tuple(
        max(scenario[field] for _, scenario in state["scenarios"])
        for field in ("objects", "vertices", "polygons")
    )


def evaluated_bounds(bpy, limits, poses, camera):
    bounds = []
    native = evaluated_geometry(bpy, limits, spatial_bounds=bounds, native_state=(poses, camera))
    if len({item["id"] for item in bounds}) != len(bounds):
        raise RuntimeError("duplicate evaluated geometry instance")
    native["meshes"] = sorted(bounds, key=lambda item: item["id"])
    return native


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
            resource_limit(
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


def denial_contract(paths, probe_network=False):
    denied = {}
    for path in paths:
        try:
            with open(path, "rb") as handle:
                handle.read(1)
            denied[path] = {"denied": False, "errno": None}
        except OSError as error:
            denied[path] = {"denied": error.errno in (errno.EPERM, errno.EACCES), "errno": error.errno}
    if not probe_network:
        return denied, None
    try:
        connection = socket.create_connection(("1.1.1.1", 443), timeout=1)
        connection.close()
        network = {"denied": False, "errno": None}
    except OSError as error:
        network = {"denied": error.errno in (errno.EPERM, errno.EACCES), "errno": error.errno}
    return denied, network


def text_value(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="strict")
    return str(value)


def blender_binary_evidence(bpy):
    libraries = {}
    for name in ("alembic", "ocio", "oiio", "opensubdiv", "openvdb", "sdl", "usd"):
        library = getattr(bpy.app, name, None)
        if library is None:
            if name == "sdl":
                continue
            fail(f"Pinned runtime library evidence is unavailable: {name}")
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
    scene_digest = file_sha256(config["scenePath"])
    load_scene(bpy, config["scenePath"], False)
    if file_sha256(config["scenePath"]) != scene_digest:
        fail("Scene bytes changed while loading verification")
    scenes = render_contract(bpy, config["limits"])
    spatial = bpy.context.scene.get("ngv_spatial_schema") == "spatial-scene/v1"
    meshes = [] if spatial else None
    if spatial and (len(bpy.data.scenes) != 1 or len(bpy.context.scene.view_layers) != 1):
        fail("A portable location requires one scene and one view layer")
    objects, vertices, polygons = evaluated_geometry(bpy, config["limits"], meshes)
    paths = config.get("diagnosticDeniedPaths", [])
    denied, network = denial_contract(paths, bool(paths))
    manifest = {
        "schema": "nexgenvideo/bpy-verification/1",
        "sceneSHA256": scene_digest,
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
    if spatial:
        manifest["spatial"] = spatial_snapshot(bpy, meshes)
    write_manifest(config["manifest"], manifest)


def spatial_snapshot(bpy, meshes):
    scene = bpy.context.scene
    paths = bpy.utils.blend_paths(absolute=True, packed=False, local=False)
    if paths or bpy.data.libraries:
        fail("Portable scene resource closure is incomplete")
    depsgraph = bpy.context.evaluated_depsgraph_get()
    objects = []
    cameras = []
    identities = set()
    for obj in sorted(bpy.data.objects, key=lambda item: item.name):
        identity = obj.get("ngv_object_id")
        uuid.UUID(identity)
        if identity in identities:
            fail("Portable scene object identity is duplicated")
        identities.add(identity)
        evaluated = obj.evaluated_get(depsgraph)
        matrix = [value for row in evaluated.matrix_world for value in row]
        objects.append({"id": identity, "name": obj.name, "kind": obj.type, "matrixWorld": matrix})
        if obj.type == "CAMERA":
            if evaluated.data.type != "PERSP":
                fail("Portable shot cameras require perspective projection")
            width = int(obj["ngv_width"])
            height = int(obj["ngv_height"])
            if not 64 <= width <= 4096 or not 64 <= height <= 4096:
                fail("The authored camera dimensions are invalid")
            projection = evaluated.calc_matrix_camera(
                depsgraph, x=width, y=height,
                scale_x=scene.render.pixel_aspect_x, scale_y=scene.render.pixel_aspect_y,
            )
            cameras.append({
                "id": identity, "name": obj.name, "matrixWorld": matrix,
                "projection": [value for row in projection for value in row],
                "verticalFieldOfView": 2 * math.atan(1 / projection[1][1]),
                "near": evaluated.data.clip_start, "far": evaluated.data.clip_end,
                "width": width, "height": height,
            })
    rest_frame = scene.get("ngv_rest_frame", 1)
    if type(rest_frame) is not int or not scene.frame_start <= rest_frame <= scene.frame_end:
        fail("Portable scene rest frame must be an integer inside its declared frame interval")
    base = Fraction(str(scene.render.fps_base))
    rational_base = base.limit_denominator(10_000)
    if struct.pack("f", float(rational_base)) == struct.pack("f", scene.render.fps_base):
        base = rational_base
    rate = Fraction(scene.render.fps) / base
    return {
        "schema": "nexgenvideo/bpy-spatial-snapshot/1", "units": "meters",
        "metersPerUnit": scene.unit_settings.scale_length,
        "frame": scene.frame_current, "restFrame": rest_frame,
        "framesPerSecond": float(rate),
        "timebaseNumerator": rate.numerator, "timebaseDenominator": rate.denominator,
        "objects": objects, "cameras": cameras, "meshes": meshes, "externalPaths": [],
    }


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
    except ResourceLimitError:
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(72)
    except OSError as error:
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(71 if error.errno in (errno.EFBIG, errno.ENOSPC) else 70)
    except MemoryError:
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(71)
    except BaseException:
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(70)
