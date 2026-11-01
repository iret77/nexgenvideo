import ast
import errno
import json
import os
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


class BpyStorageProbeCleanupTests(unittest.TestCase):
    def test_actual_probe_unlinks_retained_file_before_write_or_flush_failure(self):
        source = Path(__file__).resolve().parents[1] / "Runtime/bpy/storage_probe.py"
        tree = ast.parse(source.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "storage_probe")
        compiled = compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec")

        class Port:
            def __init__(self, value):
                self.value = value

            @classmethod
            def in_dll(cls, library, name):
                return cls(0)

        for failure in ("write-error", "short-write", "flush-error"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                descriptors = []
                original_write = os.write

                def write(descriptor, block):
                    descriptors.append(descriptor)
                    self.assertFalse((root / "retained.bin").exists())
                    if failure == "write-error":
                        raise OSError(errno.EIO, "isolated write fault")
                    if failure == "short-write":
                        return 0
                    return original_write(descriptor, block)

                library = mock.Mock()
                namespace = {"os": os, "output_dir": root,
                             "ctypes": types.SimpleNamespace(CDLL=lambda *args, **kwargs: library, c_uint32=Port, c_int=int)}
                exec(compiled, namespace)
                capacity = types.SimpleNamespace(f_blocks=64 * 1024, f_frsize=1024)
                with mock.patch.object(os, "statvfs", return_value=capacity), \
                        mock.patch.object(os, "write", side_effect=write), \
                        mock.patch.object(os, "fsync", side_effect=OSError(errno.EIO, "isolated flush fault")):
                    with self.assertRaises((OSError, RuntimeError)):
                        namespace["storage_probe"]("fileport")
                self.assertTrue(descriptors)
                self.assertFalse((root / "retained.bin").exists())
                self.assertFalse((root / "pressure.bin").exists())
                with self.assertRaises(OSError) as closed:
                    os.fstat(descriptors[-1])
                self.assertEqual(closed.exception.errno, errno.EBADF)

    def test_actual_probe_fills_bounded_volume_without_exceeding_individual_file_limit(self):
        source = Path(__file__).resolve().parents[1] / "Runtime/bpy/storage_probe.py"
        tree = ast.parse(source.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "storage_probe")
        compiled = compile(ast.Module(body=[function], type_ignores=[]), str(source), "exec")
        mib = 1024 * 1024

        class Port:
            def __init__(self, value):
                self.value = value

            @classmethod
            def in_dll(cls, library, name):
                return cls(0)

        for file_limit, full_at_open in ((4 * mib, False), (4 * mib, True), (8 * mib, False), (-1, False)):
            with self.subTest(file_limit=file_limit, full_at_open=full_at_open), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                capacity = 16 * mib
                files = {}
                descriptors = []
                open_failures = []
                used = 0
                retained = 0
                port_live = False
                original_open, original_close = os.open, os.close

                def open_file(path, flags, mode):
                    if full_at_open and path.name.startswith("pressure-") and used == capacity:
                        open_failures.append(path)
                        raise OSError(errno.ENOSPC, "bounded volume has no file space")
                    descriptor = original_open(path, flags, mode)
                    files[descriptor] = {"size": 0, "retained": path.name == "retained.bin"}
                    descriptors.append(descriptor)
                    return descriptor

                def write(descriptor, block):
                    nonlocal used
                    file = files[descriptor]
                    if file_limit != -1 and file["size"] + len(block) > file_limit:
                        raise OSError(errno.EFBIG, "per-file limit")
                    if used + len(block) > capacity:
                        raise OSError(errno.ENOSPC, "bounded volume full")
                    file["size"] += len(block)
                    used += len(block)
                    return len(block)

                def close_file(descriptor):
                    nonlocal used, retained
                    file = files.pop(descriptor)
                    if file["retained"] and port_live:
                        retained = file["size"]
                    else:
                        used -= file["size"]
                    original_close(descriptor)

                def make_port(descriptor, port):
                    nonlocal port_live
                    port.value = 17
                    port_live = True
                    return 0

                def release_port(task, port):
                    nonlocal used, retained, port_live
                    self.assertEqual(port, 17)
                    used -= retained
                    retained = 0
                    port_live = False
                    return 0

                library = mock.Mock()
                library.fileport_makeport.side_effect = make_port
                library.mach_port_deallocate.side_effect = release_port
                limits = types.SimpleNamespace(RLIMIT_FSIZE=1, RLIM_INFINITY=-1,
                                               getrlimit=mock.Mock(return_value=(file_limit, file_limit)))
                namespace = {"os": os, "errno": errno, "json": json, "resource": limits, "output_dir": root,
                             "ctypes": types.SimpleNamespace(CDLL=lambda *args, **kwargs: library,
                                                             c_uint32=Port, c_int=int, POINTER=lambda kind: kind,
                                                             byref=lambda port: port)}
                exec(compiled, namespace)
                size = types.SimpleNamespace(f_blocks=capacity // 1024, f_frsize=1024)
                with mock.patch.object(os, "statvfs", return_value=size), \
                        mock.patch.object(os, "open", side_effect=open_file), \
                        mock.patch.object(os, "write", side_effect=write), \
                        mock.patch.object(os, "close", side_effect=close_file), \
                        mock.patch.object(os, "fsync"):
                    namespace["storage_probe"]("fileport")
                proof = json.loads((root / "storage-proof.json").read_text())
                self.assertEqual(proof["storageErrno"], errno.ENOSPC)
                self.assertEqual(proof["filledBytes"], capacity - 4 * mib)
                self.assertEqual(proof["retainedBytes"], 4 * mib)
                self.assertEqual(proof["fileSizeLimitBytes"], file_limit)
                if file_limit != -1:
                    self.assertGreaterEqual(proof["pressureFileCount"], 2)
                    self.assertLessEqual(proof["largestPressureFileBytes"], file_limit)
                self.assertEqual(used, 0)
                self.assertFalse(files)
                self.assertFalse(port_live)
                self.assertEqual(bool(open_failures), full_at_open)
                self.assertEqual([path.name for path in root.iterdir()], ["storage-proof.json"])
                limits.getrlimit.assert_called_with(limits.RLIMIT_FSIZE)
                for descriptor in descriptors:
                    with self.assertRaises(OSError) as closed:
                        os.fstat(descriptor)
                    self.assertEqual(closed.exception.errno, errno.EBADF)


if __name__ == "__main__":
    unittest.main()
