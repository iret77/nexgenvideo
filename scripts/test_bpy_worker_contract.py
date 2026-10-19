import errno
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ngv_worker_contract", Path(__file__).resolve().parents[1] / "Runtime/bpy/worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerDiagnosticDenialTests(unittest.TestCase):
    def test_only_actual_permission_errors_are_denials(self):
        for code in (errno.EPERM, errno.EACCES, errno.ENOENT, errno.EISDIR,
                     errno.ENETUNREACH, errno.EHOSTUNREACH, errno.ECONNREFUSED, None):
            with self.subTest(errno=code):
                failure = OSError(code, "controlled diagnostic failure") if code is not None else TimeoutError()
                with patch("builtins.open", side_effect=failure), patch.object(worker.socket, "create_connection", side_effect=failure):
                    paths, network = worker.denial_contract(["controlled-file"], probe_network=True)
                expected = code in (errno.EPERM, errno.EACCES)
                self.assertEqual(paths["controlled-file"], dict(denied=expected, errno=code))
                self.assertEqual(network, dict(denied=expected, errno=code))

    def test_normal_verification_never_opens_a_network_socket(self):
        with patch.object(worker.socket, "create_connection", side_effect=AssertionError("unexpected network probe")) as network:
            self.assertEqual(worker.denial_contract([]), ({}, None))
            network.assert_not_called()


if __name__ == "__main__":
    unittest.main()
