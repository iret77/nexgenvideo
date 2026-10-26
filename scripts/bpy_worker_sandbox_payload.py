import errno
import json
import os
from pathlib import Path
import resource
import sys
import time


def emit_limit(stage, **values):
    print("NGV_LIMIT " + json.dumps(dict(stage=stage, pid=os.getpid(), **values)), flush=True)


def emit_failure(stage, **values):
    try:
        emit_limit(stage, **values)
    except BaseException:
        pass


def observed_limits():
    try:
        return resource.getrlimit(resource.RLIMIT_AS)
    except BaseException as error:
        return dict(errorType=type(error).__name__, error=str(error))


def address_space_boundary(label):
    original = resource.getrlimit(resource.RLIMIT_AS)
    setter = resource.setrlimit
    getter = resource.getrlimit
    which = resource.RLIMIT_AS
    page = resource.getpagesize()
    upper = 1 << 56 if original[1] == resource.RLIM_INFINITY else min(original[1], 1 << 56)
    upper = upper // page
    lower = 0
    attempts = 0
    deadline = time.monotonic() + 10

    def accepted(pages):
        nonlocal attempts
        if attempts >= 64 or time.monotonic() >= deadline:
            raise RuntimeError("address-space boundary probe exhausted its bound")
        pair = (pages * page, original[1])
        failure = None
        success = False
        try:
            setter(which, pair)
            success = True
        except (ValueError, OSError, MemoryError) as error:
            failure = error
        finally:
            try:
                setter(which, original)
            except BaseException as restore_error:
                emit_failure("boundary-restore-failure", label=label, requested=pair,
                             errorType=type(restore_error).__name__, error=str(restore_error))
                raise
        restored = getter(which)
        attempts += 1
        emit_limit("boundary-attempt", label=label, requested=pair, accepted=success,
                   errorType=type(failure).__name__ if failure else None,
                   error=str(failure) if failure else None, restored=restored, restoreVerified=restored == original)
        if restored != original:
            raise RuntimeError("address-space soft limit was not restored")
        if failure is not None and not (type(failure) is ValueError
                and str(failure) == "current limit exceeds maximum limit"):
            raise failure
        return success

    try:
        if upper <= 0 or not accepted(upper):
            raise RuntimeError("no accepted address-space upper bracket")
        while upper - lower > 1:
            middle = (upper + lower) // 2
            if accepted(middle):
                upper = middle
            else:
                lower = middle
        upper_confirmed = accepted(upper)
        lower_rejected = not accepted(lower)
        emit_limit("boundary", label=label, rejectedBytes=lower * page, acceptedBytes=upper * page,
                   pageBytes=page, attempts=attempts, restored=original,
                   endpointsConfirmed=upper_confirmed and lower_rejected,
                   interpretation="observed setter threshold; map can change during Python bookkeeping")
        return (lower * page, upper * page)
    finally:
        setter(which, original)
        if getter(which) != original:
            raise RuntimeError("address-space limit restoration failed")


def post_failure_map():
    import ctypes

    class TaskInfo(ctypes.Structure):
        _fields_ = [("virtual", ctypes.c_uint64), ("resident", ctypes.c_uint64),
                    ("times", ctypes.c_uint64 * 4), ("counters", ctypes.c_int32 * 12)]

    class Region(ctypes.Structure):
        _pack_ = 4
        _fields_ = [("protection", ctypes.c_int32), ("maxProtection", ctypes.c_int32),
                    ("inheritance", ctypes.c_int32), ("offset", ctypes.c_uint64),
                    ("userTag", ctypes.c_uint32), ("pagesResident", ctypes.c_uint32),
                    ("pagesSharedNowPrivate", ctypes.c_uint32), ("pagesSwappedOut", ctypes.c_uint32),
                    ("pagesDirtied", ctypes.c_uint32), ("references", ctypes.c_uint32),
                    ("shadowDepth", ctypes.c_uint16), ("externalPager", ctypes.c_uint8),
                    ("shareMode", ctypes.c_uint8), ("isSubmap", ctypes.c_int32),
                    ("behavior", ctypes.c_int32), ("objectID", ctypes.c_uint32),
                    ("wiredCount", ctypes.c_uint16), ("flags", ctypes.c_uint16)]

    class BasicRegion(ctypes.Structure):
        _pack_ = 4
        _fields_ = [("protection", ctypes.c_int32), ("maxProtection", ctypes.c_int32),
                    ("inheritance", ctypes.c_int32), ("shared", ctypes.c_int32),
                    ("reserved", ctypes.c_int32), ("offset", ctypes.c_uint64),
                    ("behavior", ctypes.c_int32), ("wiredCount", ctypes.c_uint16)]

    if ctypes.sizeof(TaskInfo) != 96 or ctypes.sizeof(Region) != 64 or ctypes.sizeof(BasicRegion) != 36:
        raise RuntimeError("unexpected Darwin region ABI")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    pidinfo = library.proc_pidinfo
    pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    pidinfo.restype = ctypes.c_int
    info = TaskInfo()
    received = pidinfo(os.getpid(), 4, 0, ctypes.byref(info), ctypes.sizeof(info))
    if received != ctypes.sizeof(info):
        raise RuntimeError(f"own proc_pidinfo failed: bytes={received}, errno={ctypes.get_errno()}")
    emit_limit("post-ctypes-task", virtualBytes=info.virtual, residentBytes=info.resident,
               timing="after original failure and diagnostic ctypes import")
    task = ctypes.c_uint32.in_dll(library, "mach_task_self_").value
    if task == 0:
        raise RuntimeError("own task port unavailable")
    region_call = library.mach_vm_region_recurse
    region_call.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64),
                           ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    region_call.restype = ctypes.c_int
    basic_call = library.mach_vm_region
    basic_call.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64),
                          ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32),
                          ctypes.POINTER(ctypes.c_uint32)]
    basic_call.restype = ctypes.c_int
    release_port = library.mach_port_deallocate
    release_port.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    release_port.restype = ctypes.c_int
    cursor = 0
    total = 0
    submap_bytes = 0
    writable_objects = 0
    writable_submaps = 0
    deadline = time.monotonic() + 10
    for index in range(4096):
        if time.monotonic() >= deadline:
            raise RuntimeError("own VM inventory deadline")
        address = ctypes.c_uint64(cursor)
        size = ctypes.c_uint64()
        depth = ctypes.c_uint32(0)
        count = ctypes.c_uint32(16)
        region = Region()
        code = region_call(task, ctypes.byref(address), ctypes.byref(size), ctypes.byref(depth),
                           ctypes.byref(region), ctypes.byref(count))
        if code == 1:
            emit_limit("map-end", regions=index, topLevelBytes=total, submapBytes=submap_bytes,
                       objectBytes=total - submap_bytes, maximumWritableObjectBytes=writable_objects,
                       maximumWritableSubmapBytes=writable_submaps,
                       endCode=code, scope="top-level mappings; submap internals and reclaimability unproved")
            break
        if code != 0 or count.value != 16 or depth.value != 0 or size.value <= 0 or address.value < cursor:
            raise RuntimeError(f"own VM region failed: code={code}, count={count.value}, depth={depth.value}")
        end = address.value + size.value
        if end <= cursor or end >= 1 << 64:
            raise RuntimeError("own VM region did not advance")
        basic_address = ctypes.c_uint64(address.value)
        basic_size = ctypes.c_uint64()
        basic_count = ctypes.c_uint32(9)
        basic = BasicRegion()
        object_name = ctypes.c_uint32()
        basic_code = basic_call(task, ctypes.byref(basic_address), ctypes.byref(basic_size), 9,
                                ctypes.byref(basic), ctypes.byref(basic_count), ctypes.byref(object_name))
        if object_name.value and release_port(task, object_name.value) != 0:
            raise RuntimeError("own region object port release failed")
        if basic_code != 0 or basic_count.value != 9:
            raise RuntimeError(f"own basic region failed: code={basic_code}, count={basic_count.value}")
        emit_limit("map-region", index=index, address=address.value, bytes=size.value,
                   basic=dict(address=basic_address.value, bytes=basic_size.value,
                              sameRange=basic_address.value == address.value and basic_size.value == size.value,
                              **{name: getattr(basic, name) for name, _ in basic._fields_}),
                   **{name: getattr(region, name) for name, _ in region._fields_})
        total += size.value
        if region.isSubmap:
            submap_bytes += size.value
            if region.maxProtection & 2:
                writable_submaps += size.value
        elif region.maxProtection & 2:
            writable_objects += size.value
        cursor = end
    else:
        raise RuntimeError("own VM region count exhausted")
    address_space_boundary("post-ctypes-inventory")
    received = pidinfo(os.getpid(), 4, 0, ctypes.byref(info), ctypes.sizeof(info))
    if received != ctypes.sizeof(info):
        raise RuntimeError(f"own final proc_pidinfo failed: bytes={received}, errno={ctypes.get_errno()}")
    emit_limit("post-boundary-task", virtualBytes=info.virtual, residentBytes=info.resident,
               timing="immediately after third boundary probe and limit restoration")


def set_address_space_limit(limit):
    before = resource.getrlimit(resource.RLIMIT_AS)
    emit_limit("before-original-call", requested=[limit, limit], limits=before,
               kernel=os.uname().version, pythonVersion=list(sys.version_info[:3]))
    try:
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
    except (ValueError, OSError) as original_error:
        emit_failure("original-failure", errorType=type(original_error).__name__, error=str(original_error),
                   before=before, after=observed_limits())
        try:
            if resource.getrlimit(resource.RLIMIT_AS) != before:
                raise RuntimeError("failed original call changed the limit")
            address_space_boundary("before-ctypes-1")
            address_space_boundary("before-ctypes-2")
            post_failure_map()
        except Exception as diagnostic_error:
            emit_failure("diagnostic-failure", errorType=type(diagnostic_error).__name__, error=str(diagnostic_error))
        finally:
            emit_failure("diagnostic-end", limits=observed_limits(), runtimeAcceptance=False)
        raise
    emit_limit("original-success", limits=resource.getrlimit(resource.RLIMIT_AS))


def main():
    root = Path.cwd()
    config = json.loads((root / "input.json").read_text())
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024 * 1024,) * 2)
    resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
    resource.setrlimit(resource.RLIMIT_CPU, (120, 120))
    set_address_space_limit(6 * 1024 * 1024 * 1024)
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


if __name__ == "__main__":
    main()
