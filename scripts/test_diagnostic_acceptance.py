import os
import unittest
from unittest.mock import patch

from diagnostic_test_keychain import DiagnosticKeychain, isolated_keychain
from verify_diagnostic_candidate import HARNESS_PATHS, verify


class CandidateProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.source = "a" * 40
        self.digest = "b" * 64
        self.run = dict(id=12, head_sha=self.source, path=".github/workflows/release.yml",
                        event="workflow_dispatch", head_branch="main", status="completed",
                        repository=dict(full_name="iret77/nexgenvideo"), conclusion="failure")
        self.jobs = dict(total_count=2, jobs=[dict(name="release", conclusion="success"),
                                            dict(name="diagnostic-acceptance", conclusion="failure")])
        self.artifact = dict(id=34, name="diagnostic-release-evidence", expired=False,
                             digest=f"sha256:{self.digest}",
                             workflow_run=dict(id=12, head_sha=self.source))

    def check(self, paths=HARNESS_PATHS):
        verify(self.run, self.jobs, self.artifact, 12, self.source, 34, self.digest, paths)

    def test_accepts_failed_runtime_job_only_when_signed_release_succeeded(self):
        self.check()
        self.jobs["jobs"][0]["conclusion"] = "failure"
        with self.assertRaisesRegex(ValueError, "release job"):
            self.check()

    def test_rejects_foreign_or_incomplete_source_runs(self):
        for field, value in dict(id=13, head_sha="c" * 40, path=".github/workflows/ci.yml",
                                 event="pull_request", head_branch="feature", status="in_progress",
                                 repository=dict(full_name="another/repository")).items():
            with self.subTest(field=field):
                original = self.run
                self.run = {**original, field: value}
                with self.assertRaises(ValueError):
                    self.check()
                self.run = original

    def test_rejects_missing_duplicate_or_truncated_release_jobs(self):
        for jobs in (dict(total_count=1, jobs=[]), dict(total_count=0, jobs=[]),
                     dict(total_count=2, jobs=[self.jobs["jobs"][0]] * 2)):
            with self.subTest(jobs=jobs):
                self.jobs = jobs
                with self.assertRaises(ValueError):
                    self.check()

    def test_rejects_substituted_expired_or_modified_artifacts(self):
        for field, value in dict(id=35, name="other", expired=True, digest="sha256:" + "c" * 64,
                                 workflow_run=dict(id=13, head_sha=self.source)).items():
            with self.subTest(field=field):
                original = self.artifact
                self.artifact = {**original, field: value}
                with self.assertRaises(ValueError):
                    self.check()
                self.artifact = original
        self.artifact["workflow_run"]["head_sha"] = "c" * 40
        with self.assertRaises(ValueError):
            self.check()

    def test_rejects_any_app_build_or_pack_change(self):
        for path in ("Sources/NexGenVideo/App/NexGenVideoApp.swift", "Package.resolved",
                     "scripts/bundle.sh", ".github/workflows/release.yml", "Info.plist",
                     "musicvideo/manifest.json"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "new signed build"):
                self.check([*HARNESS_PATHS, path])


class DisposableKeychainTests(unittest.TestCase):
    def test_restores_runner_configuration_even_after_acceptance_failure(self):
        calls = []

        def security(*arguments):
            calls.append(arguments)
            if arguments == ("default-keychain", "-d", "user"):
                return '"/original/login.keychain-db"'
            if arguments == ("list-keychains", "-d", "user"):
                return '"/original/login.keychain-db"\n"/original/other.keychain-db"'
            return ""

        with patch("diagnostic_test_keychain.security", side_effect=security), \
                patch("diagnostic_test_keychain.sys.platform", "darwin"), \
                patch.dict(os.environ, GITHUB_ACTIONS="true"):
            with self.assertRaisesRegex(RuntimeError, "acceptance failed"):
                with isolated_keychain() as keychain:
                    self.assertIn(("list-keychains", "-d", "user", "-s", keychain.path), calls)
                    raise RuntimeError("acceptance failed")
        self.assertEqual(calls[-3:], [
            ("default-keychain", "-d", "user", "-s", "/original/login.keychain-db"),
            ("list-keychains", "-d", "user", "-s", "/original/login.keychain-db", "/original/other.keychain-db"),
            ("delete-keychain", keychain.path),
        ])

    def test_never_touches_keychains_outside_actions(self):
        with patch("diagnostic_test_keychain.security") as security, \
                patch.dict(os.environ, GITHUB_ACTIONS="false"), self.assertRaises(RuntimeError):
            with isolated_keychain():
                self.fail("must refuse before entering")
        security.assert_not_called()

    def test_missing_retained_item_is_never_recreated(self):
        keychain = DiagnosticKeychain("/temporary/acceptance.keychain-db", "synthetic-password")
        with patch.object(keychain, "_grant_reader", side_effect=RuntimeError("item missing")), \
                patch("diagnostic_test_keychain.security") as security, self.assertRaisesRegex(RuntimeError, "item missing"):
            keychain.read_retained_key("hang-diagnostic-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        security.assert_not_called()


if __name__ == "__main__":
    unittest.main()
