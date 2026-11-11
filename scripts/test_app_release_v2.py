import copy
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import app_release_v2 as release


class AppleBoundaryTests(unittest.TestCase):
    def test_main_and_dsym_match_by_uuid_with_their_distinct_original_paths(self):
        identifier = 'C1AB1815-D829-3F3E-B536-C8F3D703FEE2'
        main = {'compiledImageSHA256': 'a' * 64, 'uuid': identifier}
        state = {'unsignedLinkSHA256': 'a' * 64,
            'imageUUID': 'UUID: ' + identifier + ' (arm64) /original/NexGenVideo\n',
            'dsymUUID': 'UUID: ' + identifier + ' (arm64) /original/NexGenVideo.dSYM/Contents/Resources/DWARF/NexGenVideo\n'}
        release.verify_main_symbol_identity({'state': state}, main)
        for key, value in [('unsignedLinkSHA256', 'b' * 64), ('dsymUUID', 'missing'),
                ('imageUUID', state['imageUUID'] * 2), ('dsymUUID', state['dsymUUID'].replace(identifier, 'D' * 36))]:
            with self.subTest(changed=key, value=value), self.assertRaises(ValueError):
                release.verify_main_symbol_identity({'state': dict(state, **{key: value})}, main)

    def setUp(self):
        self.producer = {'id': 101, 'head_sha': 'a' * 40}
        self.names = ['Submit App notarization exactly once', 'Notarize and staple app',
            'Notarize and staple downloadable format packs', 'Submit DMG notarization exactly once', 'Notarize and staple DMG']
        self.job = {'id': 102, 'name': 'release', 'run_id': 101, 'head_sha': 'a' * 40,
            'labels': ['macrunner'], 'run_attempt': 1, 'status': 'completed', 'conclusion': 'failure',
            'steps': [{'name': name, 'status': 'completed', 'conclusion': 'skipped',
                'started_at': '2026-11-11T00:00:00Z'} for name in self.names]}

    def test_all_explicit_skipped_stages_prove_no_submission_despite_github_timestamps(self):
        with mock.patch.object(release.cohort, 'has_manifest', return_value=True):
            result = release.pre_submit(self.producer, self.job)
        self.assertEqual(result, {'schema': 'release-proven-pre-submit/v1', 'sourceSHA': 'a' * 40,
            'runID': 101, 'jobID': 102, 'appleStagesAllSkipped': True})

    def test_any_entered_apple_stage_prevents_pre_submit_recovery(self):
        with mock.patch.object(release.cohort, 'has_manifest', return_value=True):
            for name in self.names:
                job = copy.deepcopy(self.job)
                next(s for s in job['steps'] if s['name'] == name)['conclusion'] = 'failure'
                with self.subTest(stage=name):
                    self.assertIsNone(release.pre_submit(self.producer, job))

    def test_missing_duplicate_foreign_or_untyped_job_cannot_prove_pre_submit(self):
        cases = []
        missing = copy.deepcopy(self.job); missing['steps'].pop(); cases.append(missing)
        duplicate = copy.deepcopy(self.job); duplicate['steps'].append(copy.deepcopy(duplicate['steps'][0])); cases.append(duplicate)
        foreign = copy.deepcopy(self.job); foreign['head_sha'] = 'b' * 40; cases.append(foreign)
        for job in cases:
            with mock.patch.object(release.cohort, 'has_manifest', return_value=True):
                self.assertIsNone(release.pre_submit(self.producer, job))
        with mock.patch.object(release.cohort, 'has_manifest', return_value=False):
            self.assertIsNone(release.pre_submit(self.producer, self.job))

    def test_retained_component_inventory_detects_link_and_mode_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'App.app'
            framework = app / 'Contents/Frameworks'
            framework.mkdir(parents=True)
            (framework / 'image').write_bytes(b'unchanged compiler image')
            (framework / 'Current').symlink_to('image')
            original = release.unchanged_components(app)
            (framework / 'Current').unlink()
            (framework / 'Current').symlink_to('elsewhere')
            self.assertNotEqual(original, release.unchanged_components(app))
            (framework / 'Current').unlink()
            (framework / 'Current').symlink_to('image')
            (framework / 'image').chmod(0o700)
            self.assertNotEqual(original, release.unchanged_components(app))


if __name__ == '__main__':
    unittest.main()
