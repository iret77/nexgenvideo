import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class RuntimeStagingTests(unittest.TestCase):
    @staticmethod
    def write_resource_fixture(source, newline="\n"):
        entries = ("Fonts", "MCPB/nexgen.mcpb", "Images", "Changelog")
        (source / "AppResources.txt").parent.mkdir(parents=True, exist_ok=True)
        (source / "AppResources.txt").write_bytes(
            (newline.join(entries) + newline).encode()
        )
        for entry in entries:
            path = source / entry
            if path.suffix:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(entry)
            else:
                path.mkdir(parents=True, exist_ok=True)
                (path / "marker").write_text(entry)

    @staticmethod
    def write_fake_xcrun(root):
        fake_xcrun = root / "xcrun"
        fake_xcrun.write_text(
            "#!/bin/bash\n"
            "if [ \"$1\" = '--find' ]; then exit 0; fi\n"
            "tool=\"$1\"\n"
            "shift\n"
            "case \"$tool\" in\n"
            "  otool)\n"
            "    binary=\"$2\"\n"
            "    echo \"$binary:\"\n"
            "    [ ! -f \"$binary.deps\" ] || cat \"$binary.deps\"\n"
            "    ;;\n"
            "  vtool) echo 'platform MACOS' ;;\n"
            "  metal|metallib)\n"
            "    output=''\n"
            "    while [ \"$#\" -gt 0 ]; do\n"
            "      if [ \"$1\" = '-o' ]; then output=\"$2\"; shift 2; continue; fi\n"
            "      shift\n"
            "    done\n"
            "    printf compiled > \"$output\"\n"
            "    ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n"
        )
        fake_xcrun.chmod(0o700)
        return fake_xcrun

    @staticmethod
    def write_framework(root, name, dependencies=()):
        framework = root / f"{name}.framework"
        version = framework / "Versions/A"
        version.mkdir(parents=True)
        binary = version / name
        binary.write_text(name)
        (version / f"{name}.deps").write_text("\n".join(dependencies))
        (framework / "Versions/Current").symlink_to("A")
        (framework / name).symlink_to(f"Versions/Current/{name}")
        return framework

    def test_application_resources_separate_sources_from_generated_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            build = root / "build"
            destination = root / "destination"
            self.write_resource_fixture(source)
            build.mkdir()
            (build / "effects.metallib").write_text("metal")

            subprocess.run(
                [ROOT / "scripts/stage_app_resources.sh", source, build, destination],
                check=True,
            )
            subprocess.run(
                [ROOT / "scripts/stage_app_resources.sh", source, build, destination],
                check=True,
            )

            for name in ("Fonts", "Images", "Changelog"):
                self.assertEqual((destination / name / "marker").read_text(), name)
            self.assertEqual(
                (destination / "nexgen.mcpb").read_text(), "MCPB/nexgen.mcpb"
            )
            self.assertEqual((destination / "effects.metallib").read_text(), "metal")

    def test_repository_resource_manifest_is_complete_and_collision_free(self):
        source = ROOT / "Sources/NexGenVideo/Resources"
        entries = (source / "AppResources.txt").read_text().splitlines()
        self.assertGreater(len(entries), 0)
        self.assertEqual(len({Path(entry).name for entry in entries}), len(entries))
        for entry in entries:
            self.assertFalse(Path(entry).is_absolute())
            self.assertNotIn("..", Path(entry).parts)
            self.assertTrue((source / entry).exists())

    def test_application_resource_staging_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.run(
                [
                    ROOT / "scripts/stage_app_resources.sh",
                    root / "source",
                    root / "build",
                    root / "destination",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing application resource manifest", result.stderr)

    def test_application_resource_staging_requires_generated_metallib(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            build = root / "build"
            self.write_resource_fixture(source)
            build.mkdir()

            result = subprocess.run(
                [
                    ROOT / "scripts/stage_app_resources.sh",
                    source,
                    build,
                    root / "destination",
                ],
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no generated .metallib", result.stderr)

    def test_application_resource_manifest_accepts_crlf(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            build = root / "build"
            destination = root / "destination"
            self.write_resource_fixture(source, newline="\r\n")
            build.mkdir()
            (build / "effects.metallib").write_text("metal")

            subprocess.run(
                [ROOT / "scripts/stage_app_resources.sh", source, build, destination],
                check=True,
            )

            self.assertTrue((destination / "Fonts").is_dir())
            self.assertTrue((destination / "nexgen.mcpb").is_file())

    def test_runtime_dependencies_stage_all_consumers_and_transitive_frameworks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_directory = root / "bin"
            destination = bin_directory / "PackageFrameworks"
            bin_directory.mkdir()
            app_tests = bin_directory / "NexGenVideoTests"
            engine_tests = bin_directory / "NexGenEngineTests"
            app_tests.write_text("app tests")
            engine_tests.write_text("engine tests")
            artifacts = root / "artifacts"
            artifacts.mkdir()
            support_dependency = (
                "@rpath/Support Framework.framework/Versions/A/Support Framework "
                "(compatibility version 1.0.0)"
            )
            self.write_framework(artifacts, "whisper", [support_dependency])
            self.write_framework(artifacts, "Support Framework")
            self.write_framework(artifacts, "Sparkle")
            engine = bin_directory / "libNexGenEngine.dylib"
            engine.write_text("engine")
            engine.with_suffix(".dylib.deps").write_text("")
            app_tests.with_suffix(".deps").write_text(
                "@rpath/whisper.framework/Versions/A/whisper "
                "(compatibility version 0.0.0)\n"
                "@rpath/libNexGenEngine.dylib (compatibility version 0.0.0)\n"
            )
            engine_tests.with_suffix(".deps").write_text(
                "@rpath/Sparkle.framework/Versions/A/Sparkle "
                "(compatibility version 2.0.0)\n"
            )

            environment = os.environ.copy()
            environment["NGV_XCRUN"] = str(self.write_fake_xcrun(root))
            command = [
                ROOT / "scripts/stage_runtime_dependencies.sh",
                destination,
                app_tests,
                engine_tests,
                "--",
                bin_directory,
                artifacts,
            ]
            subprocess.run(command, check=True, env=environment)
            subprocess.run(command, check=True, env=environment)

            for framework in ("whisper", "Sparkle", "Support Framework"):
                staged = destination / f"{framework}.framework"
                self.assertTrue((staged / "Versions/A" / framework).is_file())
                self.assertTrue((staged / "Versions/Current").is_symlink())
                self.assertTrue((staged / framework).is_symlink())
            self.assertTrue((destination / "libNexGenEngine.dylib").is_file())

    def test_framework_staging_fails_when_dependency_is_unresolved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            consumer = root / "consumer"
            consumer.write_text("test")
            consumer.with_suffix(".deps").write_text(
                "@rpath/Missing.framework/Versions/A/Missing "
                "(compatibility version 1.0.0)\n"
            )
            artifacts = root / "artifacts"
            artifacts.mkdir()
            bin_directory = root / "bin"
            bin_directory.mkdir()
            environment = os.environ.copy()
            environment["NGV_XCRUN"] = str(self.write_fake_xcrun(root))

            result = subprocess.run(
                [
                    ROOT / "scripts/stage_runtime_dependencies.sh",
                    bin_directory / "PackageFrameworks",
                    consumer,
                    "--",
                    bin_directory,
                    root / "artifacts",
                ],
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no declared macOS arm64 artifact provides", result.stderr)

    def test_runtime_dependency_staging_uses_declared_root_precedence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            consumer = root / "consumer"
            consumer.write_text("test")
            consumer.with_suffix(".deps").write_text(
                "@rpath/Shared.framework/Versions/A/Shared "
                "(compatibility version 1.0.0)\n"
            )
            first = root / "first"
            second = root / "second"
            first.mkdir()
            second.mkdir()
            self.write_framework(first, "Shared")
            self.write_framework(second, "Shared")
            self.write_framework(first / "nested", "Shared")
            (first / "Shared.framework/Versions/A/Shared").write_text("first")
            (second / "Shared.framework/Versions/A/Shared").write_text("second")
            bin_directory = root / "bin"
            bin_directory.mkdir()
            environment = os.environ.copy()
            environment["NGV_XCRUN"] = str(self.write_fake_xcrun(root))

            subprocess.run(
                [
                    ROOT / "scripts/stage_runtime_dependencies.sh",
                    bin_directory / "PackageFrameworks",
                    consumer,
                    "--",
                    first,
                    second,
                ],
                check=True,
                env=environment,
            )

            staged = bin_directory / "PackageFrameworks/Shared.framework/Versions/A/Shared"
            self.assertEqual(staged.read_text(), "first")

    def test_runtime_dependency_staging_fails_on_ambiguity_within_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            consumer = root / "consumer"
            consumer.write_text("test")
            consumer.with_suffix(".deps").write_text(
                "@rpath/Shared.framework/Versions/A/Shared "
                "(compatibility version 1.0.0)\n"
            )
            artifacts = root / "artifacts"
            (artifacts / "first").mkdir(parents=True)
            (artifacts / "second").mkdir(parents=True)
            self.write_framework(artifacts / "first", "Shared")
            self.write_framework(artifacts / "second", "Shared")
            bin_directory = root / "bin"
            bin_directory.mkdir()
            environment = os.environ.copy()
            environment["NGV_XCRUN"] = str(self.write_fake_xcrun(root))

            result = subprocess.run(
                [
                    ROOT / "scripts/stage_runtime_dependencies.sh",
                    bin_directory / "PackageFrameworks",
                    consumer,
                    "--",
                    artifacts,
                ],
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ambiguous macOS arm64 artifact", result.stderr)

    def test_runtime_dependency_staging_fails_without_rpath_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            consumer = root / "consumer"
            consumer.write_text("test")
            consumer.with_suffix(".deps").write_text("")
            artifacts = root / "artifacts"
            artifacts.mkdir()
            bin_directory = root / "bin"
            bin_directory.mkdir()
            environment = os.environ.copy()
            environment["NGV_XCRUN"] = str(self.write_fake_xcrun(root))

            result = subprocess.run(
                [
                    ROOT / "scripts/stage_runtime_dependencies.sh",
                    bin_directory / "PackageFrameworks",
                    consumer,
                    "--",
                    artifacts,
                ],
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("declare no @rpath dependencies", result.stderr)

    def test_test_runtime_stages_every_built_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_directory = root / "bin"
            bin_directory.mkdir()
            (bin_directory / "NexGenVideo_NexGenVideo.bundle").mkdir()
            vendor = root / "vendor"
            artifacts = root / "artifacts"
            swift_runtime = root / "swift-runtime"
            platform_frameworks = root / "platform-frameworks"
            vendor.mkdir()
            artifacts.mkdir()
            swift_runtime.mkdir()
            platform_frameworks.mkdir()
            for name, framework in (
                ("NexGenVideoTests", "whisper"),
                ("NexGenEngineTests", "Sparkle"),
            ):
                consumer = bin_directory / f"{name}.xctest/Contents/MacOS/{name}"
                consumer.parent.mkdir(parents=True)
                consumer.write_text(name)
                consumer.with_suffix(".deps").write_text(
                    f"@rpath/{framework}.framework/Versions/A/{framework} "
                    "(compatibility version 1.0.0)\n"
                )
                self.write_framework(artifacts, framework)
            app_tests = (
                bin_directory
                / "NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"
            )
            with app_tests.with_suffix(".deps").open("a") as dependencies:
                dependencies.write(
                    "@rpath/Testing.framework/Versions/A/Testing "
                    "(compatibility version 1.0.0)\n"
                )
            self.write_framework(platform_frameworks, "Testing")
            fake_swift = root / "swift"
            fake_swift.write_text(f"#!/bin/bash\nprintf '%s\\n' '{bin_directory}'\n")
            fake_swift.chmod(0o700)
            environment = os.environ.copy()
            environment["NGV_SWIFT"] = str(fake_swift)
            environment["NGV_XCRUN"] = str(self.write_fake_xcrun(root))
            environment["NGV_VENDOR_ARTIFACT_ROOT"] = str(vendor)
            environment["NGV_SWIFTPM_ARTIFACT_ROOT"] = str(artifacts)
            environment["NGV_SWIFT_RUNTIME_ROOT"] = str(swift_runtime)
            environment["NGV_PLATFORM_FRAMEWORK_ROOT"] = str(platform_frameworks)

            subprocess.run(
                [ROOT / "scripts/stage_test_runtime.sh", "debug"],
                check=True,
                env=environment,
            )

            runtime = bin_directory / "PackageFrameworks"
            self.assertTrue((runtime / "whisper.framework").is_dir())
            self.assertTrue((runtime / "Sparkle.framework").is_dir())
            self.assertTrue((runtime / "Testing.framework").is_dir())
            self.assertGreater(
                len(list((bin_directory / "NexGenVideo_NexGenVideo.bundle").glob("*.metallib"))),
                0,
            )

    def test_metal_resources_compile_one_library_per_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Metal"
            destination = root / "resources"
            source.mkdir()
            (source / "Glow.metal").write_text("kernel glow")
            (source / "Levels.metal").write_text("kernel levels")
            destination.mkdir()
            (destination / "RemovedKernel.metallib").write_text("stale")
            fake_xcrun = root / "xcrun"
            fake_xcrun.write_text(
                "#!/bin/bash\n"
                "if [ \"$1\" = '--find' ]; then exit 0; fi\n"
                "output=''\n"
                "while [ \"$#\" -gt 0 ]; do\n"
                "  if [ \"$1\" = '-o' ]; then output=\"$2\"; shift 2; continue; fi\n"
                "  shift\n"
                "done\n"
                "printf compiled > \"$output\"\n"
            )
            fake_xcrun.chmod(0o700)
            environment = os.environ.copy()
            environment["NGV_XCRUN"] = str(fake_xcrun)

            subprocess.run(
                [ROOT / "scripts/compile_metal_resources.sh", source, destination],
                check=True,
                env=environment,
            )

            self.assertEqual(
                [path.name for path in sorted(destination.glob("*.metallib"))],
                ["Glow.metallib", "Levels.metallib"],
            )
            self.assertEqual(list(destination.glob("*.air")), [])

    def test_metal_compilation_fails_without_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Metal"
            source.mkdir()
            (root / "resources").mkdir()
            fake_xcrun = root / "xcrun"
            fake_xcrun.write_text("#!/bin/bash\nexit 0\n")
            fake_xcrun.chmod(0o700)
            environment = os.environ.copy()
            environment["NGV_XCRUN"] = str(fake_xcrun)

            result = subprocess.run(
                [
                    ROOT / "scripts/compile_metal_resources.sh",
                    source,
                    root / "resources",
                ],
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no .metal sources", result.stderr)


if __name__ == "__main__":
    unittest.main()
