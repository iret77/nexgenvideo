import io
import json
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

from scripts import example_fixture_bundle as fixtures


class ExampleFixtureBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        dataset = self.source / "song_one"
        dataset.mkdir(parents=True)
        (dataset / "track.mp3").write_bytes(b"audio")
        (dataset / "lyrics.txt").write_text("words\n", encoding="utf-8")
        (dataset / "cover.png").write_bytes(b"image")
        self.expectations = self.root / "expectations.json"
        self.expectations.write_text(
            json.dumps(
                {
                    "schema": fixtures.EXPECTATIONS_SCHEMA,
                    "datasets": {
                        "song_one": {
                            "audio": {
                                "path": "song_one/track.mp3",
                                "duration_s": 10.0,
                                "duration_tolerance_s": 0.1,
                                "bpm": 120.0,
                                "bpm_tolerance": 1.0,
                                "expect_boundary_reduction": True,
                            }
                        }
                    },
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    def bundle(self):
        manifest = fixtures.collect_manifest(self.source, self.expectations)
        archive = self.root / "examples.tar.gz"
        manifest_path = self.root / "fixtures.manifest.json"
        manifest_path.write_bytes(fixtures.canonical_json(manifest))
        fixtures.write_archive(self.source, archive, manifest)
        return manifest, archive, manifest_path

    def test_round_trip_preserves_all_files_and_expectations(self):
        manifest, archive, _ = self.bundle()
        destination = self.root / "extracted"
        extracted = fixtures.extract_archive(archive, destination, manifest)
        fixtures.verify_tree(extracted, manifest)
        self.assertEqual(manifest["datasets"][0]["id"], "song_one")
        self.assertTrue(
            manifest["datasets"][0]["expectations"]["audio"]["expect_boundary_reduction"]
        )
        self.assertEqual((extracted / "song_one/lyrics.txt").read_text(), "words\n")

    def test_archive_is_deterministic(self):
        manifest = fixtures.collect_manifest(self.source, self.expectations)
        first = self.root / "first.tar.gz"
        second = self.root / "second.tar.gz"
        fixtures.write_archive(self.source, first, manifest)
        fixtures.write_archive(self.source, second, manifest)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_modified_file_fails_integrity_check(self):
        manifest, _, _ = self.bundle()
        (self.source / "song_one/track.mp3").write_bytes(b"changed")
        with self.assertRaisesRegex(fixtures.FixtureError, "integrity check failed"):
            fixtures.verify_tree(self.source, manifest)

    def test_boundary_reduction_expectation_is_required(self):
        expectations = json.loads(self.expectations.read_text(encoding="utf-8"))
        del expectations["datasets"]["song_one"]["audio"]["expect_boundary_reduction"]
        self.expectations.write_text(json.dumps(expectations), encoding="utf-8")
        with self.assertRaisesRegex(fixtures.FixtureError, "incomplete audio expectations"):
            fixtures.collect_manifest(self.source, self.expectations)

    def test_symlink_is_rejected(self):
        (self.source / "song_one/link.mp3").symlink_to("track.mp3")
        with self.assertRaisesRegex(fixtures.FixtureError, "symlinks are not allowed"):
            fixtures.collect_manifest(self.source, self.expectations)

    def test_archive_path_traversal_is_rejected(self):
        manifest, _, _ = self.bundle()
        archive = self.root / "malicious.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            payload = b"escape"
            member = tarfile.TarInfo("examples/../escape.txt")
            member.size = len(payload)
            bundle.addfile(member, io.BytesIO(payload))
        with self.assertRaisesRegex(fixtures.FixtureError, "unsafe fixture path"):
            fixtures.extract_archive(archive, self.root / "malicious", manifest)

    def test_exact_fixture_content_cannot_be_tracked_under_another_name(self):
        _, _, manifest_path = self.bundle()
        repository = self.root / "repository"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", str(repository)], check=True)
        copied = repository / "renamed.bin"
        copied.write_bytes((self.source / "song_one/track.mp3").read_bytes())
        subprocess.run(["git", "-C", str(repository), "add", "renamed.bin"], check=True)
        with self.assertRaisesRegex(fixtures.FixtureError, "renamed.bin"):
            fixtures.assert_not_tracked(repository, fixtures.load_manifest(manifest_path))

    def test_exact_fixture_content_cannot_remain_in_reachable_history(self):
        _, _, manifest_path = self.bundle()
        manifest = fixtures.load_manifest(manifest_path)
        repository = self.root / "repository"
        repository.mkdir()
        subprocess.run(["git", "init", "--quiet", str(repository)], check=True)
        copied = repository / "renamed.bin"
        copied.write_bytes((self.source / "song_one/track.mp3").read_bytes())
        subprocess.run(["git", "-C", str(repository), "add", "renamed.bin"], check=True)
        self.commit(repository, "Add fixture copy")
        copied.unlink()
        subprocess.run(["git", "-C", str(repository), "add", "-u"], check=True)
        self.commit(repository, "Remove fixture copy")

        fixtures.assert_not_tracked(repository, manifest)
        with self.assertRaisesRegex(fixtures.FixtureError, "git history: object"):
            fixtures.assert_not_in_history(repository, manifest)

    def commit(self, repository: Path, message: str):
        subprocess.run(
            [
                "git",
                "-C",
                str(repository),
                "-c",
                "user.name=Fixture Test",
                "-c",
                "user.email=fixture-test@example.invalid",
                "commit",
                "--quiet",
                "-m",
                message,
            ],
            check=True,
        )


if __name__ == "__main__":
    unittest.main()
