import copy
from contextlib import ExitStack, chdir
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import app_cohort_v2 as cohort
import app_release_v2
import compiled_app_release as release
import compiled_current_core_reuse as current
import run_macos_tests as native
from test_compiled_core_reuse import retained_fixture


def fixture():
    origin, receipt, expected = retained_fixture()
    origin['schema'] = 'compiled-current-core-origin/v1'
    origin['counts'] = {'retainedApp': 3696, 'retainedXCTest': 48, 'retainedEngine': 896,
        'executions': 4640, 'appSkips': 8, 'engineSkips': 14}
    receipt.update(schema='release-native-compiled-app/v6', counts=copy.deepcopy(origin['counts']),
        cohortV2={'harnessSourceSHA': receipt['sourceSHA']})
    proof = receipt['retainedNative']; proof['schema'] = 'retained-current-native-core/v1'
    ids = expected['modules']['app']['exactEndedFunctionIDs'][:3696]
    expected['modules']['app']['exactEndedFunctionIDs'] = ids
    expected['modules']['app']['exactDiscoveredFunctionIDs'] = sorted(ids + expected['modules']['app']['exactSkippedFunctionIDs'])
    proof['app']['events'].update(functionExecutions=3696, startedFunctionIDs=ids, endedFunctionIDs=ids,
        discoveredFunctionIDs=expected['modules']['app']['exactDiscoveredFunctionIDs'])
    proof['app']['hostReceipt']['bundleBinary'] = '/original/bundle/Contents/MacOS/NexGenVideoTests'
    proof['xctest']['discovery'].update(schema='native-xctest-host-checkpoint/v1', boundary='discovery-complete',
        discoveredTestCaseCount=48, inventoryIDs=expected['xctest']['exactIndividualPassedIDs'], sourceSHA='a' * 40,
        pid=55, parentPID=44, bundlePath='/original/bundle', hostPath='/original/xctest')
    origin['proofSHA256'] = hashlib.sha256(current.core.canonical(proof)).hexdigest()
    value = {'appSourceSHA': origin['appSourceSHA'], 'nativeSourceObjects': origin['nativeSourceObjects'],
        'criteria': {'sha256': origin['criteriaSHA256']}}
    return origin, receipt, expected, value


class CurrentCoreReuseTests(unittest.TestCase):
    def verification(self, origin, expected, value):
        stack = ExitStack()
        for target, attribute, replacement in ((current, 'origin', origin), (current, 'criteria', expected),
                (cohort, 'verify_context', value), (cohort, 'criteria', expected),
                (release, 'source_objects', origin['nativeSourceObjects']), (cohort, 'objects', origin['engineSourceObjects'])):
            stack.enter_context(patch.object(target, attribute, return_value=replacement))
        stack.enter_context(patch.object(cohort, 'compatible_product'))
        stack.enter_context(patch.object(app_release_v2, 'verify_xctest'))
        stack.enter_context(patch.object(current, 'api', side_effect=AssertionError('Receipt verification cannot fetch originals')))
        stack.enter_context(patch.object(current, 'download', side_effect=AssertionError('Receipt verification cannot download')))
        return stack

    def test_retained_receipt_preserves_original_identity_and_has_no_fresh_execution(self):
        origin, receipt, expected, value = fixture()
        restored = json.loads(json.dumps(receipt))
        with self.verification(origin, expected, value):
            self.assertIs(release.verify_receipt(restored, receipt['sourceSHA'], receipt['runID']), restored)
        self.assertEqual(restored['freshProofs'], {})
        self.assertNotIn('freshApp', restored['counts'])
        self.assertEqual(restored['retainedNative']['app']['hostReceipt']['sourceSHA'], 'a' * 40)
        self.assertEqual(restored['sourceSHA'], 'b' * 40)

    def test_changed_original_semantics_fail_even_if_the_proof_digest_is_recomputed(self):
        origin, receipt, expected, value = fixture()
        changes = [(['retainedNative', 'app', 'events', 'endedFunctionIDs'], []),
            (['retainedNative', 'app', 'parameterCaseCounts'], {}),
            (['retainedNative', 'app', 'hostReceipt', 'sourceSHA'], receipt['sourceSHA']),
            (['retainedNative', 'app', 'hostReceipt', 'bundleBinary'], '/different/image'),
            (['retainedNative', 'app', 'hostReceipt', 'parentPID'], 45),
            (['retainedNative', 'app', 'process', 'exitCode'], 1),
            (['retainedNative', 'app', 'process', 'observation', 'outputCapture', 'eof'], False),
            (['retainedNative', 'app', 'command'], ['host', '--filter']),
            (['retainedNative', 'app', 'events', 'runStarted'], True),
            (['retainedNative', 'xctest', 'discovery', 'passed'], True),
            (['retainedNative', 'xctest', 'discovery', 'inventoryIDs'], []),
            (['retainedNative', 'xctest', 'discovery', 'sourceSHA'], receipt['sourceSHA']),
            (['retainedNative', 'engine', 'events', 'skippedFunctionIDs'], []),
            (['retainedNative', 'engine', 'sourceObjects'], {'Engine': 'changed'}),
            (['retainedNative', 'engine', 'environment', 'current', 'osVersion'], 'different'),
            (['freshProofs'], {'app-swift-testing': {}}), (['counts', 'freshApp'], 3696),
            (['products', 'tests', 'receipt', 'state', 'linkComplete'], False),
            (['currentRetainedEnvironment', 'architecture'], 'x86_64'),
            (['cohortV2', 'harnessSourceSHA'], 'a' * 40), (['runID'], True)]
        for path, replacement in changes:
            broken = copy.deepcopy(receipt); target = broken
            for key in path[:-1]: target = target[key]
            target[path[-1]] = replacement
            changed_origin = copy.deepcopy(origin)
            changed_origin['proofSHA256'] = hashlib.sha256(current.core.canonical(broken['retainedNative'])).hexdigest()
            with self.subTest(path=path), self.verification(changed_origin, expected, value), self.assertRaises(ValueError):
                release.verify_receipt(broken, receipt['sourceSHA'], receipt['runID'])

    def test_matching_current_cohort_never_reexecutes_or_falls_back_after_invalid_original(self):
        origin, receipt, _, _ = fixture()
        bound = {'appSourceSHA': origin['appSourceSHA'], 'prepared': {'cohortV2': {'harnessSourceSHA': receipt['sourceSHA']}}}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / 'bound.json').write_text(json.dumps(bound))
            with patch.object(current, 'origin', return_value=origin), patch.object(current, 'acquire', return_value=receipt) as acquire, \
                    patch.object(native, 'run_process') as process, patch.object(app_release_v2, 'run_xctest') as xctest:
                self.assertIs(release.run_tests(root), receipt)
                acquire.side_effect = ValueError('Original proof changed')
                with self.assertRaisesRegex(ValueError, 'Original proof changed'): release.run_tests(root)
                process.assert_not_called(); xctest.assert_not_called()
                self.assertFalse((root / 'native-tests.STARTED.json').exists())

    def test_origin_fixture_is_closed_before_use(self):
        original = current.origin()
        self.assertEqual(original['originalExecution']['runID'], 43351706129)
        self.assertEqual(original['counts'], {'retainedApp': 3696, 'retainedXCTest': 48, 'retainedEngine': 896,
            'executions': 4640, 'appSkips': 8, 'engineSkips': 14})
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'origin.json'; path.write_text('{}')
            with patch.object(current, 'FIXTURE', path), self.assertRaisesRegex(ValueError, 'origin changed'):
                current.origin()

    def test_changed_compiler_or_native_source_stops_before_original_acquisition(self):
        origin, receipt, expected, value = fixture()
        bound = {'sourceSHA': receipt['sourceSHA'], 'runID': receipt['runID'], 'appSourceSHA': origin['appSourceSHA'],
            'selected': origin['compiledSelectors'], 'nativeSourceObjects': origin['nativeSourceObjects']}
        for key, replacement in (('selected', {}), ('nativeSourceObjects', {'Sources': 'changed'}), ('runID', 1)):
            broken = dict(bound, **{key: replacement})
            with self.subTest(key=key), patch.dict(os.environ, GITHUB_SHA=receipt['sourceSHA'], GITHUB_RUN_ID=str(receipt['runID'])), \
                    patch.object(current, 'origin', return_value=origin), patch.object(current, 'context', return_value=receipt['cohortV2']), \
                    patch.object(current, 'criteria', return_value=expected), patch.object(cohort, 'verify_context', return_value=value), \
                    patch.object(release, 'native_guard'), patch.object(release, 'source_objects', return_value=origin['nativeSourceObjects']), \
                    patch.object(current, 'api') as api, self.assertRaisesRegex(ValueError, 'candidate differs'):
                current.acquire(Path('/unused'), broken, release)
            api.assert_not_called()

    def test_historical_criteria_permit_only_the_two_bound_location_corrections(self):
        raw_current = Path('scripts/fixtures/app-cohort-native-inventory.json').read_bytes()
        expected = json.loads(raw_current)
        key = 'originalEightAppFailureIDsRequiredToEndWithoutIssues'
        old = copy.deepcopy(expected)
        old[key][-2:] = ['original-cancellation-location', 'original-timeout-location']
        raw_old = json.dumps(old).encode()
        old_context = {'harnessSourceSHA': 'a' * 40}; new_context = {'harnessSourceSHA': 'b' * 40}
        origin = {'originalExecution': {'sourceSHA': 'a' * 40}, 'originalCohort': old_context,
            'appSourceSHA': expected['appSourceSHA'], 'nativeSourceObjects': expected['nativeSourceObjects'],
            'originalCriteriaSHA256': hashlib.sha256(raw_old).hexdigest(), 'criteriaSHA256': hashlib.sha256(raw_current).hexdigest(),
            'originalCriteriaCorrections': dict(zip(old[key][-2:], expected[key][-2:]))}
        common = {'appSourceSHA': origin['appSourceSHA'], 'nativeSourceObjects': origin['nativeSourceObjects'],
            'roleSourceObjects': {'production': {}}, 'componentSourceObjects': {}, 'retainedXCTestHost': {}}
        for defect in ('none', 'additional-change', 'original-bytes', 'source-change'):
            current_bytes = raw_current
            if defect == 'additional-change':
                changed = copy.deepcopy(expected); changed['expectedActualExecutions'] += 1
                current_bytes = json.dumps(changed).encode()
            changed_origin = dict(origin, criteriaSHA256=hashlib.sha256(current_bytes).hexdigest())
            previous = dict(common, criteria={'path': 'inventory.json', 'sha256': origin['originalCriteriaSHA256']})
            candidate = dict(common, criteria={'path': 'inventory.json', 'sha256': changed_origin['criteriaSHA256']})
            if defect == 'source-change': candidate['nativeSourceObjects'] = {'Sources': 'changed'}
            with self.subTest(defect=defect), patch.object(cohort, 'verify_context', side_effect=[previous, candidate]), \
                    patch.object(cohort, 'consumer_ci_paths', return_value={'scripts/fix.py'}), \
                    patch.object(cohort, 'git', return_value='scripts/fix.py'), patch.object(cohort, 'criteria', return_value=expected), \
                    patch.object(current.subprocess, 'check_output', side_effect=[raw_old + (b' ' if defect == 'original-bytes' else b''), current_bytes]):
                if defect == 'none':
                    self.assertIs(current.criteria(changed_origin, new_context), expected)
                else:
                    with self.assertRaises(ValueError): current.criteria(changed_origin, new_context)

    def test_v6_assembly_uses_the_current_cohort_without_entering_legacy_assembly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / 'receipt.json').write_text(json.dumps({'schema': 'release-native-compiled-app/v6'}))
            with patch.object(app_release_v2, 'assemble', return_value='current-assembly') as assemble, \
                    patch.object(release, 'native_guard', side_effect=AssertionError('Legacy assembly entered')):
                self.assertEqual(release.assemble(root), 'current-assembly')
                assemble.assert_called_once_with(root)

    def test_v6_signed_checkpoint_requires_components_and_restores_compiled_mode(self):
        import release_checkpoint as checkpoint
        import test_release_recovery as recovery
        helper = recovery.ReleaseRecoveryTests()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); manifest, _ = helper.signed(root)
            manifest['nativeEvidence'] = {'schema': 'release-native-compiled-app/v6', 'freshProofs': {}}
            with patch.object(release, 'verify_receipt') as verify, patch.object(app_release_v2, 'verify_assembly') as assembly:
                with self.assertRaisesRegex(ValueError, 'lacks its actual component assembly'):
                    checkpoint.verify_manifest(manifest, recovery.SOURCE, 123)
                verify.assert_called_once_with(manifest['nativeEvidence'], recovery.SOURCE, 123)
                manifest['componentAssembly'] = {'schema': 'compiled-component-assembly/v2'}
                self.assertIs(checkpoint.verify_manifest(manifest, recovery.SOURCE, 123), manifest)
                assembly.assert_called_once_with(manifest['componentAssembly'], recovery.SOURCE, 123,
                    manifest['identity'], manifest['files'], manifest['nativeEvidence'])
                checkpoint.write_signed_manifest(root / 'original/manifest.json', manifest)
                archive_path = root / 'v6-signed.zip'
                with zipfile.ZipFile(archive_path, 'w') as archive:
                    for name in (*checkpoint.FILES, 'manifest.json'): archive.write(root / 'original' / name, name)
                binding = helper.restore_fixture(root, manifest, archive_path)
                environment = {'GITHUB_SHA': recovery.SOURCE, 'REL_VERSION': '1.8.0',
                    'GITHUB_ENV': str(root / 'environment'), 'PLUGIN_CATALOG_URL': 'https://example.test/catalog.json'}
                with chdir(root), patch.dict(os.environ, environment), patch.object(checkpoint, 'packaging_binding', return_value=None), \
                        patch.object(checkpoint, 'run', side_effect=helper.fake_mac) as commands, \
                        patch.object(checkpoint, 'download', side_effect=lambda item, target: shutil.copyfile(archive_path, target)), \
                        patch.object(release, 'verify_component_materialization'):
                    checkpoint.restore(binding)
                self.assertIn('NGV_COMPILED_APP_RELEASE=true\n', (root / 'environment').read_text())
                self.assertFalse(any(call.args[0] in {'swift', 'xctest'} for call in commands.call_args_list))

    def test_v6_packaging_uses_exact_current_cohort_product_identity(self):
        import retained_packaging as packaging
        native = {'schema': 'release-native-compiled-app/v6', 'cohortV2': {'manifestSHA256': 'a' * 64}}
        manifest = {'sourceSHA': 'b' * 40, 'runID': 123, 'nativeEvidence': native,
            'files': {'NexGenVideo.zip': {'sha256': 'c' * 64}}, 'appTreeSHA256': 'd' * 64}
        value = {'signedBase': {'packArchiveSHA256': 'e' * 64, 'packTreeSHA256': 'f' * 64}}
        with patch.object(cohort, 'verify_context', return_value=value):
            product = app_release_v2.signed_product(manifest)
            record = {'productSourceSHA': manifest['sourceSHA'], 'originalSignedBuildRunID': 123,
                'signedInput': {'manifest': manifest, 'cohortProduct': product}}
            self.assertTrue(packaging.cohort_signed_product(record))
            for key, changed in (('sourceSHA', 'f' * 40), ('runID', 124), ('appArchiveSHA256', '0' * 64)):
                broken = copy.deepcopy(record); broken['signedInput']['cohortProduct'][key] = changed
                self.assertFalse(packaging.cohort_signed_product(broken))
            manifest['nativeEvidence']['schema'] = 'unknown'
            self.assertFalse(packaging.cohort_signed_product(record))


if __name__ == '__main__':
    unittest.main()
