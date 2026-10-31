import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ngv_worker_contract", Path(__file__).resolve().parents[1] / "Runtime/bpy/worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerVersionIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def runtime(self, version, display):
        library = SimpleNamespace(supported=True, version=(1, 2, 3), version_string="1.2.3 fixture")
        app = SimpleNamespace(version=version, version_string=display, build_hash=b"fixture-hash",
                              build_branch=b"main", build_type=b"Release", build_system=b"fixture",
                              **{name: library for name in ("alembic", "ocio", "oiio", "opensubdiv", "openvdb", "sdl", "usd")})
        return SimpleNamespace(app=app, __file__=__file__, context=SimpleNamespace(scene={}),
                               data=SimpleNamespace(objects=[], texts={}))

    def test_probe_manifest_reports_the_actual_release_version(self):
        for version, display, expected in [((5, 2, 2), "5.2.2 LTS", "5.2.2"),
                                           ((5, 2, 3), "5.2.2 LTS", "5.2.3")]:
            with self.subTest(version=version, display=display):
                manifest = self.root / "probe.json"
                runtime = self.runtime(version, display)
                with patch.object(worker, "load_runtime", return_value=(runtime, None, None)):
                    worker.probe({"sitePackages": str(self.root), "manifest": str(manifest)})
                payload = json.loads(manifest.read_text())
                self.assertEqual(payload["schema"], "nexgenvideo/bpy-probe/1")
                self.assertEqual(payload["bpyVersion"], expected)
                self.assertEqual(payload["processIdentifier"], os.getpid())
                self.assertEqual(payload["bpyModule"], str(Path(__file__).resolve()))

    def test_scene_manifest_reports_the_actual_release_version(self):
        scene = self.root / "scene.blend"
        scene_bytes = b"frozen-scene-fixture"
        scene.write_bytes(scene_bytes)
        for version, display, expected in [((5, 2, 2), "5.2.2 LTS", "5.2.2"),
                                           ((5, 2, 3), "5.2.2 LTS", "5.2.3")]:
            with self.subTest(version=version, display=display):
                manifest = self.root / "verification.json"
                runtime = self.runtime(version, display)
                with patch.object(worker, "load_runtime", return_value=(runtime, None, None)), \
                        patch.object(worker, "load_scene"), \
                        patch.object(worker, "render_contract", return_value=[]), \
                        patch.object(worker, "evaluated_geometry", return_value=(0, 0, 0)):
                    worker.verify_scene({"sitePackages": str(self.root), "scenePath": str(scene),
                                         "limits": {}, "jobID": "fixture-job", "fingerprint": "fixture-fingerprint",
                                         "sessionRoot": str(self.root), "manifest": str(manifest)})
                payload = json.loads(manifest.read_text())
                self.assertEqual(payload["schema"], "nexgenvideo/bpy-verification/1")
                self.assertEqual(payload["bpyVersion"], expected)
                self.assertEqual(payload["sceneSHA256"], hashlib.sha256(scene_bytes).hexdigest())
                self.assertEqual(payload["processIdentifier"], os.getpid())
                self.assertEqual(payload["libraryVersions"]["ocio"]["versionString"], "1.2.3 fixture")


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
