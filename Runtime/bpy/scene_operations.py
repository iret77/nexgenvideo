import json
import math


def find_object(identity):
    matches = [obj for obj in bpy.data.objects if obj.get("ngv_object_id") == identity]
    if len(matches) != 1:
        raise ValueError("The selected scene object no longer exists")
    return matches[0]


def key_transform(obj, frame):
    rotation = {"QUATERNION": "rotation_quaternion", "AXIS_ANGLE": "rotation_axis_angle"}.get(obj.rotation_mode, "rotation_euler")
    for path in ("location", rotation, "scale"):
        obj.keyframe_insert(data_path=path, frame=frame)


def require_pose_edit(obj, keyframe):
    if obj.constraints or obj.rigid_body:
        raise ValueError("Bake constraints or physics before changing this pose")
    for target in (obj, obj.data):
        animation = getattr(target, "animation_data", None)
        if animation and (animation.drivers or animation.nla_tracks or (not keyframe and animation.action)):
            raise ValueError("Enable Set keyframe to edit animation; driven poses must be baked first")


def apply_command(command):
    scene = bpy.context.scene
    kind = command["kind"]
    scene["ngv_spatial_schema"] = "spatial-scene/v1"
    scene.unit_settings.system = "METRIC"
    if kind == "create":
        bpy.ops.wm.read_factory_settings(use_empty=True)
        scene = bpy.context.scene
        scene["ngv_spatial_schema"] = "spatial-scene/v1"
        scene.unit_settings.system = "METRIC"
        scene.unit_settings.scale_length = 1.0
        scene.render.resolution_x = 1280
        scene.render.resolution_y = 720
        scene.render.resolution_percentage = 100
        scene.render.fps = 24
        scene.render.fps_base = 1.0
        scene["ngv_rest_frame"] = 1
        scene.frame_set(1)
    elif kind == "primitive":
        primitive = command["primitive"]
        constructors = {
            "cube": bpy.ops.mesh.primitive_cube_add,
            "sphere": bpy.ops.mesh.primitive_uv_sphere_add,
            "cylinder": bpy.ops.mesh.primitive_cylinder_add,
            "plane": bpy.ops.mesh.primitive_plane_add,
        }
        constructors[primitive]()
        bpy.context.object.name = command["name"]
    elif kind == "import_glb":
        bpy.ops.import_scene.gltf(filepath=str(input_dir / command["filename"]))
    elif kind == "transform":
        obj = find_object(command["objectID"])
        require_pose_edit(obj, command.get("keyframe", False))
        scene.frame_set(command["frame"])
        obj.matrix_world = mathutils.Matrix(command["matrixWorld"])
        if command.get("keyframe", False):
            key_transform(obj, command["frame"])
    elif kind == "delete":
        bpy.data.objects.remove(find_object(command["objectID"]), do_unlink=True)
    elif kind == "camera":
        scene.frame_set(command["frame"])
        identity = command.get("objectID")
        if identity:
            camera = find_object(identity)
            if camera.type != "CAMERA":
                raise ValueError("The selected object is not a camera")
        else:
            data = bpy.data.cameras.new(command["name"])
            camera = bpy.data.objects.new(command["name"], data)
            scene.collection.objects.link(camera)
        require_pose_edit(camera, command.get("keyframe", False))
        camera.matrix_world = mathutils.Matrix(command["matrixWorld"])
        camera.data.type = "PERSP"
        if camera.data.sensor_fit != "VERTICAL" and camera.data.animation_data and camera.data.animation_data.action:
            raise ValueError("Create a new camera before changing the projection of an imported animated camera")
        camera.data.sensor_fit = "VERTICAL"
        camera.data.angle_y = command["verticalFieldOfView"]
        camera.data.clip_start = command["near"]
        camera.data.clip_end = command["far"]
        camera["ngv_width"] = command["width"]
        camera["ngv_height"] = command["height"]
        scene.camera = camera
        if command.get("keyframe", False):
            key_transform(camera, command["frame"])
            camera.data.keyframe_insert(data_path="lens", frame=command["frame"])
    elif kind == "evaluate":
        scene.frame_set(command["frame"])
    elif kind == "render_clay":
        camera = find_object(command["cameraID"])
        if camera.type != "CAMERA":
            raise ValueError("The selected object is not a camera")
        if camera["ngv_width"] * command["height"] != camera["ngv_height"] * command["width"]:
            raise ValueError("The render aspect must match the authored camera")
        scene.camera = camera
        scene.render.engine = "CYCLES"
        scene.cycles.device = "CPU"
        scene.cycles.samples = command["samples"]
        scene.cycles.use_denoising = False
        scene.render.resolution_x = command["width"]
        scene.render.resolution_y = command["height"]
        scene.render.resolution_percentage = 100
        scene.render.pixel_aspect_x = 1.0
        scene.render.pixel_aspect_y = 1.0
        scene.render.use_compositing = False
        scene.render.use_sequencer = False
        scene.render.film_transparent = False
        scene.render.image_settings.file_format = "PNG"
        scene.render.image_settings.color_mode = "RGBA"
        scene.render.image_settings.color_depth = "8"
        material = bpy.data.materials.new("NGV neutral clay")
        material.diffuse_color = (0.5, 0.5, 0.5, 1.0)
        material.use_nodes = True
        bsdf = material.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = (0.5, 0.5, 0.5, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.8
        scene.view_layers[0].material_override = material
        world = bpy.data.worlds.new("NGV clay world")
        world.use_nodes = True
        world.node_tree.nodes.get("Background").inputs["Color"].default_value = (0.5, 0.5, 0.5, 1.0)
        world.node_tree.nodes.get("Background").inputs["Strength"].default_value = 1.0
        scene.world = world
        for obj in scene.objects:
            if obj.type == "LIGHT":
                obj.hide_render = True
        scene.view_settings.view_transform = "Standard"
        scene.view_settings.look = "None"
        if command.get("state"):
            for obj in bpy.data.objects:
                if obj.constraints or obj.rigid_body:
                    raise ValueError("Bake constraints or physics before rendering a resolved shot state")
                obj.animation_data_clear()
            camera.data.animation_data_clear()
        poses = []
        for frame in range(command["startFrame"], command["endFrame"] + 1):
            scene.frame_set(frame)
            if command.get("state"):
                sample = command["state"]["frames"][frame - command["startFrame"]]
                def depth(pose):
                    parent = find_object(pose["objectID"]).parent
                    value = 0
                    while parent:
                        value += 1
                        parent = parent.parent
                    return value
                for pose in sorted(sample["objects"], key=depth):
                    values = pose["matrixWorld"]
                    find_object(pose["objectID"]).matrix_world = mathutils.Matrix([values[index:index + 4] for index in range(0, 16, 4)])
                    bpy.context.view_layer.update()
                camera.data.sensor_fit = "VERTICAL"
                camera.data.angle_y = sample["cameraVerticalFieldOfView"]
            bpy.context.view_layer.update()
            depsgraph = bpy.context.evaluated_depsgraph_get()
            evaluated_camera = camera.evaluated_get(depsgraph)
            projection = evaluated_camera.calc_matrix_camera(depsgraph, x=command["width"], y=command["height"])
            poses.append({
                "frame": frame,
                "matrixWorld": [value for row in evaluated_camera.matrix_world for value in row],
                "projection": [value for row in projection for value in row],
                "cameraVerticalFieldOfView": 2 * math.atan(1 / projection[1][1]),
                "objects": [{"objectID": obj["ngv_object_id"],
                             "matrixWorld": [value for row in obj.evaluated_get(depsgraph).matrix_world for value in row]}
                            for obj in sorted(bpy.data.objects, key=lambda obj: obj["ngv_object_id"])],
            })
            scene.render.filepath = str(output_dir / f"clay-{frame:08d}.png")
            bpy.ops.render.render(write_still=True)
        (output_dir / "clay-frames.json").write_text(json.dumps(poses, sort_keys=True, separators=(",", ":")))
    else:
        raise ValueError("Unknown location operation")


apply_command(ngv_command)
