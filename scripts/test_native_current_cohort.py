import copy
import unittest
from unittest.mock import patch

import native_current_cohort as cohort


class NativeCurrentCohortTests(unittest.TestCase):
    def test_authentic_template_keeps_old_origin_separate_from_current_candidate(self):
        old, current = {'Sources': 'old', 'Tests': 'old'}, {'Sources': 'new', 'Tests': 'new'}
        shape = {'templateAppSourceSHA': cohort.TEMPLATE_SOURCE, 'currentAppSourceSHA': cohort.APP_SOURCE}
        origin = {'schema': 'native-app-build-plan-binding/v1',
            'harnessSourceSHA': 'e238d854cdeeebd22391d5c820674c6bf9d046e2',
            'selected': dict(cohort.TEMPLATE_SELECTED), 'nativeSourceObjects': old}
        run = {'id': 42556707333, 'head_sha': origin['harnessSourceSHA']}
        artifact = {'id': cohort.TEMPLATE_METADATA[0], 'digest': 'sha256:' + cohort.TEMPLATE_METADATA[1]}
        selected = {'schema': 'native-current-cohort-binding/v1', 'selected': {'appSourceSHA': cohort.APP_SOURCE},
            'nativeSourceObjects': current, 'templateProjection': shape}
        with patch.object(cohort, 'objects', side_effect=lambda ref: old if ref == cohort.TEMPLATE_SOURCE else current), \
                patch.object(cohort, 'buildshape', return_value=shape), \
                patch.dict(cohort.os.environ, GITHUB_SHA='c' * 40):
            cohort.verify_template(origin, run, artifact, selected)
            for key, value in [('selected', dict(cohort.TEMPLATE_SELECTED, appSourceSHA=cohort.APP_SOURCE)),
                    ('nativeSourceObjects', current), ('harnessSourceSHA', 'c' * 40)]:
                with self.subTest(key=key), self.assertRaises(ValueError):
                    cohort.verify_template(dict(origin, **{key: value}), run, artifact, selected)
            for key, value in [('nativeSourceObjects', old), ('templateProjection', {'currentAppSourceSHA': cohort.TEMPLATE_SOURCE}),
                    ('selected', {'appSourceSHA': cohort.TEMPLATE_SOURCE})]:
                with self.subTest(key=key), self.assertRaises(ValueError):
                    cohort.verify_template(origin, run, artifact, dict(selected, **{key: value}))
            for key, value in [('id', artifact['id'] + 1), ('digest', 'sha256:' + 'f' * 64)]:
                with self.subTest(key=key), self.assertRaises(ValueError):
                    cohort.verify_template(origin, run, dict(artifact, **{key: value}), selected)

    def test_template_rejects_added_or_missing_native_inputs_before_projection(self):
        import native_app_target_build as targets
        self.assertNotIn('scripts/compiled_app_release.py', targets.PATHS)
        self.assertIn('scripts/compiled_app_release.py', targets.CURRENT_PATHS)
        names = ['Sources/NexGenVideo/File%d.swift' % index for index in range(1395)]
        for current in (names[:-1], names + ['Tests/NexGenVideoTests/New.swift'], [*names[:-1], 'renamed.swift']):
            with self.subTest(current=current[-1]), patch.object(cohort, 'source_paths', side_effect=[names, current]), \
                    patch.object(cohort.capture, 'command') as command, self.assertRaises(ValueError):
                cohort.buildshape('c' * 40)
            command.assert_not_called()

    def test_current_cohort_requires_its_own_complete_merged_source_receipt_before_reading_template(self):
        import json
        import os
        import tempfile
        from pathlib import Path
        import verified_pr_source_checks as checks
        head, pr_head = 'c' * 40, 'd' * 40
        objects = {'Sources': 'new', 'Tests': 'new'}
        pr = {'number': 900, 'merged': True, 'merge_commit_sha': head,
            'head': {'sha': pr_head}, 'base': {'sha': 'e' * 40}}
        selected = {'appSourceSHA': cohort.APP_SOURCE, 'runID': 101, 'verifiedPRRunID': 101,
            'sourceSHA': pr_head, 'artifactID': 201, 'artifactSHA256': 'f' * 64}
        run = {'id': 101, 'head_sha': pr_head}
        artifact = {'id': 201, 'digest': 'sha256:' + 'f' * 64, 'size_in_bytes': 123}
        receipt = {'pullRequest': 900, 'headSHA': pr_head, 'treeSHA': 'a' * 40}
        for changed in ('valid', 'app-pin', 'missing-merge', 'different-source-run', 'different-native9', 'unreviewed-delta', 'different-pr-head', 'different-merge-tree'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                current = {'schema': 'core-pr-source-composition/v1', 'sourceSHA': head,
                    'originalRun': run.copy(), 'originalPR': copy.deepcopy(pr)}
                if changed == 'missing-merge': current['originalPR']['merged'] = False
                if changed == 'different-source-run': current['originalRun']['id'] = 102
                incoming = dict(selected)
                if changed == 'app-pin': incoming['appSourceSHA'] = cohort.TEMPLATE_SOURCE
                proof = root / 'transport-source-proof/receipt.json'; proof.parent.mkdir(); proof.write_text(json.dumps(current))
                actual_pr = copy.deepcopy(pr)
                if changed == 'different-pr-head': actual_pr['head']['sha'] = 'b' * 40
                def git(*argv):
                    if argv == ('rev-parse', 'HEAD'): return head
                    if argv == ('rev-parse', 'HEAD^{tree}'): return 'a' * 40
                    if argv == ('rev-parse', cohort.APP_SOURCE + '^{tree}'): return cohort.APP_TREE
                    if argv[:2] == ('status', '--porcelain'): return ''
                    if argv[:2] == ('diff', '--name-only'):
                        return 'Sources/NexGenVideo/New.swift' if changed == 'unreviewed-delta' else 'scripts/native_current_cohort.py'
                    raise AssertionError(argv)
                def api(route):
                    if route == 'actions/runs/101': return run
                    if route.endswith('/attempts/1/jobs?per_page=100'): return {}
                    if route == 'actions/artifacts/201': return artifact
                    if route == 'pulls/900': return actual_pr
                    if route == 'git/commits/' + head: return {'tree': {'sha': 'b' * 40 if changed == 'different-merge-tree' else 'a' * 40}}
                    raise AssertionError(route)
                with patch.dict(os.environ, GITHUB_REPOSITORY='iret77/nexgenvideo', GITHUB_SHA=head, RUNNER_TEMP=str(root)), \
                        patch.object(cohort.capture, 'git', side_effect=git), patch.object(cohort.capture, 'api', side_effect=api), \
                        patch.object(cohort.capture, 'command', return_value=b'original'), patch.object(cohort.subprocess, 'run'), \
                        patch.object(cohort, 'objects', side_effect=lambda ref: {'Sources': 'other'} if changed == 'different-native9' and ref == head else objects), \
                        patch.object(cohort, 'buildshape', return_value={'qualified': True}), \
                        patch.object(checks, 'verify_run_identity', return_value={'id': 301}), \
                        patch.object(checks, 'original_receipt', return_value=receipt), patch.object(checks, 'verify_steps', return_value={}), \
                        patch.object(checks, 'test_completion', return_value={'passed': True}):
                    if changed == 'valid':
                        cohort.bind(root / 'result', incoming, set())
                        saved = json.loads((root / 'result/binding.json').read_text())
                        self.assertEqual(saved['appCandidateSHA'], cohort.APP_SOURCE)
                        self.assertEqual(saved['appSourceRun']['head_sha'], pr_head)
                        self.assertNotEqual(saved['appCandidateSHA'], saved['appSourceRun']['head_sha'])
                    else:
                        with self.assertRaises(ValueError): cohort.bind(root / 'result', incoming, set())



if __name__ == '__main__':
    unittest.main()
