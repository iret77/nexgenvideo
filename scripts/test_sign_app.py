import hashlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from verify_bpy_signing import INHERIT, SANDBOX, entitlements, validate


ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(sys.platform == "darwin", "requires the native macOS signing gate")
class AppSigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ngv-signing-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        source = self.root / "fixture.c"
        source.write_text("int main(void) { return 0; }\n")
        self.executable = self.root / "fixture"
        self.library = self.root / "fixture.dylib"
        self.extension = self.root / "fixture.so"
        common = ["xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=26.0"]
        self.run_command([*common, str(source), "-o", str(self.executable)])
        self.run_command([*common, "-dynamiclib", str(source), "-o", str(self.library),
                          "-Wl,-install_name,@rpath/fixture.dylib"])
        self.run_command([*common, "-bundle", str(source), "-o", str(self.extension)])
        for binary in [self.executable, self.library, self.extension]:
            self.run_command(["codesign", "--remove-signature", binary])
            unsigned = self.run_command(["codesign", "-d", binary], check=False)
            self.assertNotEqual(unsigned.returncode, 0)
            self.assertIn("code object is not signed at all", unsigned.stderr)

    def run_command(self, arguments, check=True):
        result = subprocess.run([str(value) for value in arguments], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=60)
        if check:
            self.assertEqual(result.returncode, 0,
                             f"{arguments[0]} failed:\n{result.stdout}\n{result.stderr}")
        return result

    def copy_binary(self, destination, library=False, extension=False):
        destination.parent.mkdir(parents=True, exist_ok=True)
        source = self.extension if extension else self.library if library else self.executable
        shutil.copy2(source, destination)

    def bundle(self, path, executable, kind="APPL"):
        self.copy_binary(path / "Contents/MacOS" / executable)
        info = {"CFBundleExecutable": executable,
                "CFBundleIdentifier": "org.nexgenvideo.signing-fixture." + path.stem.lower(),
                "CFBundlePackageType": kind, "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0", "LSMinimumSystemVersion": "26.0"}
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

    def app(self, name, runtime_mode):
        app = self.root / f"{name}.app"
        self.bundle(app, "NexGenVideo")
        contents = app / "Contents"
        (contents / "Resources").mkdir()
        (contents / "XPCServices").mkdir()
        self.copy_binary(contents / "Helpers/NexGenVideoDiagnostics")
        self.copy_binary(contents / "Frameworks/libNexGenEngine.dylib", library=True)
        sparkle = contents / "Frameworks/Sparkle.framework"
        version = sparkle / "Versions/A"
        self.copy_binary(version / "Sparkle", library=True)
        (version / "Resources").mkdir()
        (version / "Resources/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Sparkle", "CFBundleIdentifier": "org.nexgenvideo.signing-fixture.sparkle",
            "CFBundlePackageType": "FMWK", "CFBundleVersion": "1"}))
        (sparkle / "Versions/Current").symlink_to("A")
        (sparkle / "Sparkle").symlink_to("Versions/Current/Sparkle")
        (sparkle / "Resources").symlink_to("Versions/Current/Resources")
        self.copy_binary(version / "Autoupdate")
        self.bundle(version / "Updater.app", "Updater")
        for helper in ["Downloader", "Installer"]:
            self.bundle(version / "XPCServices" / f"{helper}.xpc", helper, "XPC!")
        if runtime_mode != "omitted":
            self.copy_binary(contents / "Helpers/NexGenVideoBpySupervisor")
            self.copy_binary(contents / "Helpers/NexGenVideoBpyStorage")
            for slot in range(2):
                self.bundle(contents / "XPCServices" / f"NexGenVideoBpyService{slot}.xpc",
                            "NexGenVideoBpyService", "XPC!")
        if runtime_mode == "full":
            runtime = contents / "Resources/BpyRuntime"
            self.copy_binary(runtime / "python/bin/python3.13")
            (runtime / "python/bin/python3").symlink_to("python3.13")
            self.copy_binary(runtime / "python/lib/libpython3.13.dylib", library=True)
            self.copy_binary(runtime / "python/lib/python3.13/lib-dynload/fixture.so", extension=True)
            self.copy_binary(runtime / "site-packages/bpy/__init__.so", extension=True)
            for relative in ["python/include/python3.13/Python.h", "python/lib/python3.13/fixture.py",
                             "site-packages/bpy-5.2.2.dist-info/RECORD", "worker.py", "PYTHON.json",
                             ".complete", "licenses/python/LICENSE"]:
                path = runtime / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("signing fixture data\n")
        return app

    def verify(self, app):
        self.run_command(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app])
        for path in app.rglob("*"):
            if path.is_file() and not path.is_symlink():
                kind = self.run_command(["file", "--brief", path]).stdout
                if "Mach-O" in kind:
                    self.run_command(["codesign", "--verify", "--strict", "--verbose=2", path])

    def test_previous_deep_signing_rejects_nested_runtime_content(self):
        app = self.app("previous", "omitted")
        header = app / "Contents/Helpers/BpyRuntime/python/include/python3.13/Python.h"
        header.parent.mkdir(parents=True)
        header.write_text("signing fixture data\n")
        previous = self.run_command(["codesign", "--force", "--deep", "--sign", "-", app], check=False)
        self.assertNotEqual(previous.returncode, 0)
        self.assertIn("bundle format unrecognized", previous.stderr)
        self.assertIn("BpyRuntime/", previous.stderr)

    def test_development_modes_preserve_nested_runtime_and_entitlements(self):
        for mode in ["dev", "fast"]:
            with self.subTest(mode=mode):
                app = self.app(mode, "full")
                header = app / "Contents/Resources/BpyRuntime/python/include/python3.13/Python.h"
                original = hashlib.sha256(header.read_bytes()).hexdigest()
                self.run_command([ROOT / "scripts/sign_app.sh", app, mode, "full", "-"])
                self.verify(app)
                validate(app, development=True)
                self.assertEqual(hashlib.sha256(header.read_bytes()).hexdigest(), original)
                self.assertEqual(entitlements(app / "Contents/Helpers/NexGenVideoDiagnostics"), {})
                self.assertFalse((app / "Contents/Helpers/BpyRuntime").exists())
                header.write_text("changed after signing\n")
                tampered = self.run_command(["codesign", "--verify", "--strict", app], check=False)
                self.assertNotEqual(tampered.returncode, 0)

    def test_nonproduct_development_modes_keep_their_signing_boundaries(self):
        for runtime_mode in ["boundary", "omitted"]:
            with self.subTest(runtime_mode=runtime_mode):
                app = self.app(runtime_mode, runtime_mode)
                self.run_command([ROOT / "scripts/sign_app.sh", app, "dev", runtime_mode, "-"])
                self.verify(app)
                self.assertFalse((app / "Contents/Resources/BpyRuntime").exists())
                self.assertFalse((app / "Contents/Helpers/BpyRuntime").exists())
                if runtime_mode == "boundary":
                    self.assertEqual(entitlements(app / "Contents/Helpers/NexGenVideoBpySupervisor"),
                                     {SANDBOX: True, INHERIT: True})
                    self.assertEqual(entitlements(app / "Contents/Helpers/NexGenVideoBpyStorage"), {})
                    for slot in range(2):
                        service = app / "Contents/XPCServices" / f"NexGenVideoBpyService{slot}.xpc"
                        self.assertEqual(entitlements(service), {SANDBOX: True})


if __name__ == "__main__":
    unittest.main()
