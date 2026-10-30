import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("ngv_worker_binding", Path(__file__).resolve().parents[1] / "Runtime/bpy/worker.py")
WORKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WORKER)


class WorkerSourceBindingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.source = Path(temporary.name) / "source.py"
        self.original = b"value = 'host-authorized'\n"
        self.source.write_bytes(self.original)
        self.descriptor = os.open(self.source, os.O_RDONLY)
        self.addCleanup(os.close, self.descriptor)
        self.expected = hashlib.sha256(self.original).hexdigest()

    def test_compiles_exact_bytes_from_the_verified_descriptor(self):
        bound, identity = WORKER.read_authorized_source(self.descriptor, self.expected)
        WORKER.require_source_identity(self.source, identity)
        values = {}
        exec(compile(bound.decode("utf-8"), "<binding-test>", "exec"), values)
        self.assertEqual(values["value"], "host-authorized")

    def test_path_replacement_cannot_reach_runtime_import(self):
        bound = WORKER.read_authorized_source(self.descriptor, self.expected)
        replacement = self.source.with_name("replacement.py")
        replacement.write_text("raise AssertionError('unapproved-source')\n")
        replacement.replace(self.source)
        with mock.patch.object(WORKER, "load_runtime") as load:
            with self.assertRaises(SystemExit) as failure:
                WORKER.execute_job({"sourcePath": str(self.source)}, bound)
            self.assertEqual(failure.exception.code, 70)
            load.assert_not_called()

    def test_in_place_mutation_fails_the_host_digest_before_compile(self):
        self.source.write_bytes(b"value = 'unapproved'\n")
        with self.assertRaises(SystemExit) as failure:
            WORKER.read_authorized_source(self.descriptor, self.expected)
        self.assertEqual(failure.exception.code, 70)

    def test_configuration_requires_a_readonly_regular_single_link(self):
        with self.assertRaises(SystemExit) as failure:
            WORKER.read_bootstrap_descriptor(self.descriptor, 1024, immutable=True)
        self.assertEqual(failure.exception.code, 70)
        os.chmod(self.source, 0o400)
        data, _ = WORKER.read_bootstrap_descriptor(self.descriptor, 1024, immutable=True)
        self.assertEqual(data, self.original)
        os.link(self.source, self.source.with_name("another-link.py"))
        with self.assertRaises(SystemExit) as failure:
            WORKER.read_bootstrap_descriptor(self.descriptor, 1024, immutable=True)
        self.assertEqual(failure.exception.code, 70)


if __name__ == "__main__":
    unittest.main()
