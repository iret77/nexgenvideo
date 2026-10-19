import array
import ctypes
import errno
import json
import mmap
import os
import socket


def storage_probe(mode):
    limit = 64 * 1024 * 1024
    capacity = os.statvfs(output_dir).f_blocks * os.statvfs(output_dir).f_frsize
    if not 0 < capacity <= limit:
        raise RuntimeError("runtime is not on the bounded 64 MiB test volume")
    libc = ctypes.CDLL(None, use_errno=True)
    task = ctypes.c_uint32.in_dll(libc, "mach_task_self_").value
    port = ctypes.c_uint32(0)
    libc.mach_port_deallocate.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    libc.mach_port_deallocate.restype = ctypes.c_int
    descriptor = os.open(output_dir / "retained.bin", os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    sockets = []
    denied = 0
    retained = 4 * 1024 * 1024
    block = b"x" * (256 * 1024)
    try:
        try:
            os.unlink(output_dir / "retained.bin")
            for _ in range(retained // len(block)):
                if os.write(descriptor, block) != len(block):
                    raise RuntimeError("short retained-file write")
            os.fsync(descriptor)
            if mode == "fileport":
                libc.fileport_makeport.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint32)]
                libc.fileport_makeport.restype = ctypes.c_int
                if libc.fileport_makeport(descriptor, ctypes.byref(port)) != 0:
                    denied = ctypes.get_errno()
                    if denied not in (errno.EPERM, errno.EACCES):
                        raise RuntimeError(f"unexpected fileport error: {denied}")
            elif mode == "memory-entry":
                mapping = mmap.mmap(descriptor, retained, flags=mmap.MAP_SHARED, prot=mmap.PROT_READ | mmap.PROT_WRITE)
                try:
                    address = ctypes.addressof(ctypes.c_char.from_buffer(mapping))
                    size = ctypes.c_uint64(retained)
                    libc.mach_make_memory_entry_64.argtypes = [
                        ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint64,
                        ctypes.c_int, ctypes.POINTER(ctypes.c_uint32), ctypes.c_uint32,
                    ]
                    libc.mach_make_memory_entry_64.restype = ctypes.c_int
                    result = libc.mach_make_memory_entry_64(task, ctypes.byref(size), address, 1, ctypes.byref(port), 0)
                    if result != 0 or size.value != retained or port.value == 0:
                        raise RuntimeError(f"memory entry was not created exactly: {result}/{size.value}")
                finally:
                    mapping.close()
            elif mode == "scm-rights":
                try:
                    sockets = list(socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM))
                    sockets[0].sendmsg([b"retain"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [descriptor]))])
                except OSError as error:
                    denied = error.errno
                    if denied not in (errno.EPERM, errno.EACCES):
                        raise
            else:
                raise RuntimeError("unknown storage retention probe")
        finally:
            os.close(descriptor)
        filled = 0
        observed = 0
        descriptor = os.open(output_dir / "pressure.bin", os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
        try:
            os.unlink(output_dir / "pressure.bin")
            while filled <= capacity + len(block):
                try:
                    count = os.write(descriptor, block)
                    if count <= 0:
                        raise RuntimeError("storage write stopped without ENOSPC")
                    filled += count
                except OSError as error:
                    observed = error.errno
                    break
            if observed == 0:
                try:
                    os.fsync(descriptor)
                except OSError as error:
                    observed = error.errno
            if observed != errno.ENOSPC or filled <= 0 or filled > capacity:
                raise RuntimeError(f"filesystem did not enforce its capacity: {observed}/{filled}/{capacity}")
        finally:
            os.close(descriptor)
        (output_dir / "storage-proof.json").write_text(json.dumps({
            "mode": mode, "capacityBytes": capacity, "filledBytes": filled, "retainedBytes": retained,
            "retentionDeniedErrno": denied, "storageErrno": observed,
        }))
    finally:
        for endpoint in sockets:
            endpoint.close()
        if port.value and libc.mach_port_deallocate(task, port.value) != 0:
            raise RuntimeError("retained Mach resource was not released")



storage_probe(ngv_storage_probe_mode)
