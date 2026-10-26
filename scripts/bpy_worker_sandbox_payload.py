import errno
import json
import os
from pathlib import Path
import resource
import sys
import time


root = Path.cwd()
config = json.loads((root / "input.json").read_text())
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024 * 1024,) * 2)
resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
resource.setrlimit(resource.RLIMIT_AS, (6 * 1024 * 1024 * 1024,) * 2)
resource.setrlimit(resource.RLIMIT_NPROC, (0, 0))
denials = {}
for label, operation in [
    ("read", lambda: os.open(config["outside"], os.O_RDONLY)),
    ("write", lambda: os.open(config["outside"], os.O_WRONLY)),
]:
    try:
        fd = operation()
    except OSError as error:
        denials[label] = error.errno
    else:
        os.close(fd)
        denials[label] = 0
expected = (errno.EPERM, errno.EACCES) if config["confined"] else (0,)
if any(value not in expected for value in denials.values()):
    raise RuntimeError("sandbox read/write boundaries did not survive Python exec")
sys.path.insert(0, config["sitePackages"])
started = time.monotonic()
import bpy

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.mesh.primitive_cube_add()
camera = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
bpy.context.collection.objects.link(camera)
camera.location = (4, -4, 3)
camera.rotation_euler = (-camera.location).to_track_quat("-Z", "Y").to_euler()
scene = bpy.context.scene
scene.camera = camera
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 1
scene.cycles.use_denoising = False
if hasattr(scene.cycles, "denoising_use_gpu"):
    scene.cycles.denoising_use_gpu = False
scene.render.resolution_x = 32
scene.render.resolution_y = 32
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = str(root / "render.png")
bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=str(root / "scene.blend"), check_existing=False)
(root / "result.json").write_text(json.dumps(dict(
    schema="nexgenvideo/worker-sandbox-component/1", pid=os.getpid(),
    pythonVersion=list(sys.version_info[:3]), bpyVersion=list(bpy.app.version), bpyVersionString=bpy.app.version_string,
    executable=os.path.realpath(sys.executable), bpyModule=os.path.realpath(bpy.__file__),
    denials=denials, confined=config["confined"], renderEngine=scene.render.engine, device=scene.cycles.device,
    denoising=scene.cycles.use_denoising,
    renderSize=[32, 32], elapsedSeconds=time.monotonic() - started,
    scope="isolated component; not product acceptance"), indent=2) + "\n")
