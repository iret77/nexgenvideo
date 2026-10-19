import ast
import errno
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


if __name__ == "__main__":
    unittest.main()
