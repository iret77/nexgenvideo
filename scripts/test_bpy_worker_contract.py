import errno
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ngv_worker_contract", Path(__file__).resolve().parents[1] / "Runtime/bpy/worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


def runtime_fixture(version, display, module_file):
    library = SimpleNamespace(supported=True, version=(1, 2, 3), version_string="1.2.3 fixture")
    app = SimpleNamespace(version=version, version_string=display, build_hash=b"fixture-hash",
                          build_branch=b"main", build_type=b"Release", build_system=b"fixture",
                          **{name: library for name in ("alembic", "ocio", "oiio", "opensubdiv", "openvdb", "sdl", "usd")})
    return SimpleNamespace(app=app, __file__=str(module_file), context=SimpleNamespace(scene={}),
                           data=SimpleNamespace(objects=[], texts={}))


class WorkerVersionIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def runtime(self, version, display):
        return runtime_fixture(version, display, __file__)

    def test_probe_manifest_reports_the_actual_release_version(self):
        for version, display, expected in [((5, 2, 2), "5.2.2 LTS", "5.2.2"),
                                           ((5, 2, 3), "5.2.2 LTS", "5.2.3")]:
            with self.subTest(version=version, display=display):
                manifest = self.root / "probe.json"
                runtime = self.runtime(version, display)
                native = str(self.root / "bpy" / "__init__.so")
                with patch.object(worker, "load_runtime", return_value=(runtime, None, None, native)):
                    worker.probe({"sitePackages": str(self.root), "manifest": str(manifest)})
                payload = json.loads(manifest.read_text())
                self.assertEqual(payload["schema"], "nexgenvideo/bpy-probe/1")
                self.assertEqual(payload["bpyVersion"], expected)
                self.assertEqual(payload["processIdentifier"], os.getpid())
                self.assertEqual(payload["bpyModule"], native)

    def test_scene_manifest_reports_the_actual_release_version(self):
        scene = self.root / "scene.blend"
        scene_bytes = b"frozen-scene-fixture"
        scene.write_bytes(scene_bytes)
        for version, display, expected in [((5, 2, 2), "5.2.2 LTS", "5.2.2"),
                                           ((5, 2, 3), "5.2.2 LTS", "5.2.3")]:
            with self.subTest(version=version, display=display):
                manifest = self.root / "verification.json"
                runtime = self.runtime(version, display)
                native = str(self.root / "bpy" / "__init__.so")
                with patch.object(worker, "load_runtime", return_value=(runtime, None, None, native)), \
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
                self.assertEqual(payload["bpyModule"], native)
                self.assertEqual(payload["libraryVersions"]["ocio"]["versionString"], "1.2.3 fixture")


class WorkerNativeModuleIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.native = self.root / "bpy" / "__init__.so"
        self.native.parent.mkdir()
        self.native.write_bytes(b"controlled-native-loader-boundary")
        self.facade = self.native.parent / "5.2" / "scripts" / "modules" / "bpy" / "__init__.py"
        self.facade.parent.mkdir(parents=True)
        self.facade.write_text("# controlled Blender Python facade\n")

    def replace_metadata(self, module):
        module.__dict__.update(runtime_fixture((5, 2, 2), "5.2.2 LTS", self.facade).__dict__)
        module.__spec__ = importlib.util.spec_from_file_location("bpy", self.facade)
        module.__loader__ = module.__spec__.loader

    @contextmanager
    def native_boundary(self, replace_at="exec", fail_at=None, failure=None):
        events = []

        def create(loader, native_spec):
            events.append(("create", loader.get_filename("bpy"), native_spec.origin))
            module = ModuleType("bpy")
            if fail_at == "create":
                worker.sys.modules["bpy"] = module
                raise failure
            if replace_at == "create":
                self.replace_metadata(module)
            return module

        def execute(loader, module):
            events.append(("exec", loader.get_filename("bpy")))
            if fail_at == "exec":
                raise failure
            if replace_at == "exec":
                self.replace_metadata(module)

        with patch.dict(worker.sys.modules, {name: ModuleType(name) for name in ("bmesh", "mathutils")}), \
                patch.object(worker.sys, "path", list(worker.sys.path)), \
                patch.object(worker.importlib.machinery.ExtensionFileLoader, "create_module",
                             autospec=True, side_effect=create) as creator, \
                patch.object(worker.importlib.machinery.ExtensionFileLoader, "exec_module",
                             autospec=True, side_effect=execute) as executor:
            worker.sys.modules.pop("bpy", None)
            yield events, creator, executor

    def test_probe_records_the_executed_native_loader_after_metadata_replacement(self):
        for stage in ("create", "exec"):
            with self.subTest(stage=stage), self.native_boundary(replace_at=stage) as (events, creator, executor):
                manifest = self.root / (stage + "-probe.json")
                worker.probe({"sitePackages": str(self.root), "manifest": str(manifest)})
                payload = json.loads(manifest.read_text())
                self.assertEqual(payload["bpyModule"], str(self.native))
                self.assertEqual(payload["bpyVersion"], "5.2.2")
                self.assertEqual(worker.sys.modules["bpy"].__file__, str(self.facade))
                self.assertEqual(events, [("create", str(self.native), str(self.native)), ("exec", str(self.native))])
                creator.assert_called_once()
                executor.assert_called_once_with(creator.call_args.args[0], worker.sys.modules["bpy"])

    def test_scene_manifest_preserves_native_identity_after_scene_loading(self):
        scene = self.root / "scene.blend"
        scene.write_bytes(b"frozen-scene-bytes")
        manifest = self.root / "verification.json"

        def load_scene(runtime, path, use_scripts):
            self.assertEqual(path, str(scene))
            self.assertFalse(use_scripts)
            runtime.__file__ = str(self.root / "changed-facade.py")
            runtime.__spec__ = None

        with self.native_boundary(), patch.object(worker, "load_scene", side_effect=load_scene), \
                patch.object(worker, "render_contract", return_value=[]), \
                patch.object(worker, "evaluated_geometry", return_value=(0, 0, 0)):
            worker.verify_scene({"sitePackages": str(self.root), "scenePath": str(scene),
                                 "limits": {}, "jobID": "fixture-job", "fingerprint": "fixture-fingerprint",
                                 "sessionRoot": str(self.root), "manifest": str(manifest)})
        payload = json.loads(manifest.read_text())
        self.assertEqual(payload["bpyModule"], str(self.native))
        self.assertEqual(payload["sceneSHA256"], hashlib.sha256(scene.read_bytes()).hexdigest())
        self.assertEqual(payload["schema"], "nexgenvideo/bpy-verification/1")

    def test_missing_or_non_native_spec_is_rejected_before_loading(self):
        source = importlib.util.spec_from_file_location("bpy", self.facade)
        bytecode_loader = worker.importlib.machinery.SourcelessFileLoader("bpy", str(self.native))
        bytecode = importlib.util.spec_from_file_location("bpy", self.native, loader=bytecode_loader)
        native_loader = worker.importlib.machinery.ExtensionFileLoader("bpy", str(self.native))
        for candidate in (None, source, bytecode, SimpleNamespace(name="bpy", origin=None, loader=native_loader),
                          SimpleNamespace(name="foreign", origin=str(self.native), loader=native_loader)):
            with self.subTest(spec=candidate), self.native_boundary() as (_, creator, executor), \
                    patch.object(worker.importlib.util, "find_spec", return_value=candidate), \
                    self.assertRaises(SystemExit) as error:
                worker.load_runtime(str(self.root))
            self.assertEqual(error.exception.code, 70)
            creator.assert_not_called()
            executor.assert_not_called()

    def test_foreign_inconsistent_or_missing_native_paths_are_rejected_before_loading(self):
        foreign = self.root / "foreign.so"
        foreign.write_bytes(b"foreign-native-boundary")
        for loader_path, origin in ((foreign, foreign), (foreign, self.native),
                                    (self.native, foreign)):
            with self.subTest(loader_path=loader_path, origin=origin), \
                    self.native_boundary() as (_, creator, executor):
                loader = worker.importlib.machinery.ExtensionFileLoader("bpy", str(loader_path))
                candidate = importlib.util.spec_from_file_location("bpy", str(origin), loader=loader)
                with patch.object(worker.importlib.util, "find_spec", return_value=candidate), \
                        self.assertRaises(SystemExit) as error:
                    worker.load_runtime(str(self.root))
                self.assertEqual(error.exception.code, 70)
                creator.assert_not_called()
                executor.assert_not_called()
        missing_root = self.root / "missing-runtime"
        missing = missing_root / "bpy" / "__init__.so"
        loader = worker.importlib.machinery.ExtensionFileLoader("bpy", str(missing))
        candidate = importlib.util.spec_from_file_location("bpy", str(missing), loader=loader)
        manifest = self.root / "missing-probe.json"
        with self.native_boundary() as (_, creator, executor), \
                patch.object(worker.importlib.util, "find_spec", return_value=candidate):
            with self.assertRaises(FileNotFoundError):
                worker.probe({"sitePackages": str(missing_root), "manifest": str(manifest)})
            self.assertFalse(manifest.exists())
            creator.assert_not_called()
            executor.assert_not_called()
        for kind in ("symlink", "directory"):
            runtime_root = self.root / (kind + "-runtime")
            entry = runtime_root / "bpy" / "__init__.so"
            entry.parent.mkdir(parents=True)
            if kind == "symlink":
                entry.symlink_to(self.native)
            else:
                entry.mkdir()
            loader = worker.importlib.machinery.ExtensionFileLoader("bpy", str(entry))
            candidate = importlib.util.spec_from_file_location("bpy", entry, loader=loader)
            with self.subTest(kind=kind), self.native_boundary() as (_, creator, executor), \
                    patch.object(worker.importlib.util, "find_spec", return_value=candidate):
                with self.assertRaises(SystemExit) as error:
                    worker.load_runtime(str(runtime_root))
                self.assertEqual(error.exception.code, 70)
                creator.assert_not_called()
                executor.assert_not_called()

    def test_probe_and_verifier_need_no_runtime_ancestor_metadata(self):
        real_lstat = os.lstat
        scene = self.root / "scoped-scene.blend"
        scene.write_bytes(b"frozen-scoped-scene")
        allowed, denied = [], []

        def scoped_lstat(path, *args, **kwargs):
            value = os.path.normpath(os.fsdecode(path))
            if value != str(self.root) and not value.startswith(str(self.root) + os.sep):
                denied.append(value)
                raise PermissionError(errno.EPERM, "runtime ancestor metadata is denied", value)
            allowed.append(value)
            return real_lstat(path, *args, **kwargs)

        for mode in ("probe", "verify"):
            with self.subTest(mode=mode), self.native_boundary(), \
                    patch.object(worker.os, "lstat", side_effect=scoped_lstat), \
                    patch.object(worker, "load_scene"), patch.object(worker, "render_contract", return_value=[]), \
                    patch.object(worker, "evaluated_geometry", return_value=(0, 0, 0)):
                manifest = self.root / (mode + "-scoped-manifest.json")
                config = {"sitePackages": str(self.root), "manifest": str(manifest), "scenePath": str(scene),
                          "limits": {}, "jobID": "fixture-job", "fingerprint": "fixture-fingerprint",
                          "sessionRoot": str(self.root)}
                if mode == "probe":
                    worker.probe(config)
                else:
                    worker.verify_scene(config)
                self.assertEqual(json.loads(manifest.read_text())["bpyModule"], str(self.native))
        self.assertTrue(denied)
        self.assertIn(str(self.native), allowed)

    def test_preloaded_bpy_is_rejected_without_reinitializing_it(self):
        with self.native_boundary() as (_, creator, executor):
            existing = ModuleType("bpy")
            worker.sys.modules["bpy"] = existing
            with patch.object(worker.importlib.util, "find_spec") as finder, self.assertRaises(SystemExit):
                worker.load_runtime(str(self.root))
            self.assertIs(worker.sys.modules["bpy"], existing)
            finder.assert_not_called()
            creator.assert_not_called()
            executor.assert_not_called()

    def test_failed_native_initialization_removes_the_partial_module_and_emits_no_manifest(self):
        manifest = self.root / "failed-probe.json"
        for stage, failure in (("create", RuntimeError("native create failed")),
                               ("exec", RuntimeError("native execution failed")),
                               ("create", PermissionError(errno.EACCES, "native image unreadable"))):
            with self.subTest(stage=stage, failure=type(failure).__name__), \
                    self.native_boundary(fail_at=stage, failure=failure):
                with self.assertRaises(type(failure)):
                    worker.probe({"sitePackages": str(self.root), "manifest": str(manifest)})
                self.assertFalse(manifest.exists())
                self.assertFalse(manifest.with_suffix(".json.part").exists())
                self.assertNotIn("bpy", worker.sys.modules)


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
