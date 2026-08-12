import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class RuntimeStagingTests(unittest.TestCase):
    def test_application_resources_separate_sources_from_generated_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            build = root / "build"
            destination = root / "destination"
            for name in ("Fonts", "Images", "Changelog"):
                resource = source / name
                resource.mkdir(parents=True)
                (resource / "marker").write_text(name)
            (source / "MCPB").mkdir()
            (source / "MCPB" / "nexgen.mcpb").write_text("mcp")
            build.mkdir()
            (build / "effects.metallib").write_text("metal")

            subprocess.run(
                [ROOT / "scripts/stage_app_resources.sh", source, build, destination],
                check=True,
            )

            for name in ("Fonts", "Images", "Changelog"):
                self.assertEqual((destination / name / "marker").read_text(), name)
            self.assertEqual((destination / "nexgen.mcpb").read_text(), "mcp")
            self.assertEqual((destination / "effects.metallib").read_text(), "metal")

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
            self.assertIn("missing required application resource directory", result.stderr)

    def test_application_resource_staging_requires_generated_metallib(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            build = root / "build"
            for name in ("Fonts", "Images", "Changelog"):
                (source / name).mkdir(parents=True)
            (source / "MCPB").mkdir()
            (source / "MCPB" / "nexgen.mcpb").write_text("mcp")
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

    def test_local_binary_frameworks_stage_into_swiftpm_runtime_path(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            subprocess.run(
                [ROOT / "scripts/stage_test_frameworks.sh", destination],
                check=True,
            )
            runtime = (
                destination
                / "PackageFrameworks/whisper.framework/Versions/Current/whisper"
            )
            self.assertTrue(runtime.is_file())


if __name__ == "__main__":
    unittest.main()
