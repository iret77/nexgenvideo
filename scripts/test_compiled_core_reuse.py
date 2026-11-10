import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import shutil
import zipfile

import compiled_app_release as release
import compiled_core_reuse as core
import native_xctest_host as xhost
import run_macos_tests as native


def retained_fixture(original='a' * 40, current='b' * 40):
    objects = {'Sources': 'c' * 40}; host_inputs = {'host-input': 'd' * 64}
    expected = {'modules': {}, 'xctest': {'exactIndividualPassedIDs': ['case%d' % i for i in range(48)]}}
    summaries = {}
    framework = {'passed': True, 'expectedRuns': {'swiftTesting': 1, 'xctest': 0},
        'startedRuns': {'swiftTesting': 1, 'xctest': 0}, 'completedRuns': {'swiftTesting': 1, 'xctest': 0}, 'failures': []}
    for module, count, skips, cases in [('app', 3712, 8, 371), ('engine', 896, 14, 49)]:
        ids = [module + '/function%d' % i for i in range(count)]
        skipped = [module + '/skip%d' % i for i in range(skips)]
        expected['modules'][module] = {'exactDiscoveredFunctionIDs': sorted(ids + skipped),
            'exactEndedFunctionIDs': sorted(ids), 'exactSkippedFunctionIDs': sorted(skipped),
            'expectedCaseCountsByFunction': {ids[0]: cases}}
        summaries[module] = {'events': {'recordCount': 10000, 'discoveredFunctionIDs': sorted(ids + skipped),
            'startedFunctionIDs': sorted(ids), 'endedFunctionIDs': sorted(ids), 'skippedFunctionIDs': sorted(skipped),
            'functionExecutions': count, 'runStarted': 1, 'runEnded': 1, 'emptySelection': False, 'skippedSelection': False},
            'parameterCaseCounts': {ids[0]: cases}, 'eventSHA256': 'e' * 64, 'consoleSHA256': 'f' * 64,
            'framework': copy.deepcopy(framework)}
    expected['originalEightAppFailureIDsRequiredToEndWithoutIssues'] = expected['modules']['app']['exactEndedFunctionIDs'][:8]
    context = {'original': {'swift': 'Swift', 'xcode': 'Xcode', 'python': '3.13.17', 'osVersion': '27.2', 'osBuild': 'build'},
        'architecture': 'arm64'}
    context['current'] = dict(context['original'])
    summaries['engine'].update(environment=context, sourceObjects={'Engine': 'd' * 40},
        eventSHA256=release.engine.EVENT_DIGEST, consoleSHA256=release.engine.CONSOLE_DIGEST,
        originalJobSHA256=release.engine.LOG_DIGEST)
    process = lambda pid: {'exitCode': 0, 'pid': pid, 'observation': {'pid': pid, 'parentPID': 44,
        'hostExecutable': '/original/host', 'hostSHA256': release.retained.HOST_SHA,
        'outputCapture': {'originalExitCode': 0, 'eof': True}}}
    app = summaries['app']; app.update(process=process(66), command=['/original/host', '--event-stream-version', '0', '--no-parallel'])
    app['hostReceipt'] = {'schema': 1, 'sourceSHA': original, 'parentPID': 44, 'pid': 66,
        'hostExecutable': '/original/host', 'eventRecordCount': 10000, **dict.fromkeys(('mainThread',
            'applicationRunningAtStart', 'started', 'completed', 'abiSucceeded', 'runReturnedAfterCompletion'), True)}
    products, selectors = {}, {}
    for index, phase in enumerate(release.PHASES):
        product = {'schema': 'native-app-target-product/v1', 'phase': phase, 'sourceSHA': original,
            'runID': 100 + index, 'attempt': 1, 'appSourceSHA': release.APP_SOURCE,
            'nativeSourceObjects': objects, 'compilerSHA256': release.COMPILER_SHA,
            'state': {'compileComplete': True, 'linkComplete': True}}
        digest = hashlib.sha256((json.dumps(product, indent=2) + '\n').encode()).hexdigest()
        selectors[phase] = {'runID': product['runID'], 'artifactID': 200 + index, 'sourceSHA': original,
            'artifactSHA256': '1' * 64, 'receiptSHA256': digest}
        products[phase] = {'receipt': product, 'originalArchiveSHA256': '1' * 64}
    selectors['metadata'] = {'runID': 103, 'artifactID': 203, 'sourceSHA': original, 'artifactSHA256': '2' * 64}
    fixture = {'schema': 'compiled-complete-core-origin/v1', 'appSourceSHA': release.APP_SOURCE,
        'nativeSourceObjects': objects, 'hostInputs': host_inputs, 'compiledSelectors': selectors,
        'compilerSHA256': release.COMPILER_SHA, 'criteriaSHA256': release.checksum(release.CRITERIA),
        'originalExecution': {'runID': 10, 'jobID': 20, 'sourceSHA': original, 'artifactID': 30,
            'artifactSHA256': '3' * 64, 'fullRawSHA256': '4' * 64},
        'engineSourceObjects': {'Engine': 'd' * 40}, 'members': {
            'app-swift-testing/events.jsonl': {'bytes': 1, 'sha256': app['eventSHA256']},
            'app-swift-testing/console.log': {'bytes': 1, 'sha256': app['consoleSHA256']}},
        'counts': {'freshApp': 0, 'freshXCTest': 0, 'retainedApp': 3712, 'retainedXCTest': 48,
            'retainedEngine': 896, 'executions': 4656, 'appSkips': 8, 'engineSkips': 14}}
    xprocess = process(55); xprocess['parentPID'] = 44
    xprocess['observation'].update(hostExecutable='/original/xctest', hostSHA256='9' * 64)
    proof = {'schema': 'retained-complete-native-core/v1', 'originalExecution': fixture['originalExecution'],
        'appSourceSHA': fixture['appSourceSHA'], 'nativeSourceObjects': objects, 'compilerSHA256': fixture['compilerSHA256'],
        'selected': selectors, 'criteriaSHA256': fixture['criteriaSHA256'], 'memberIdentities': fixture['members'],
        'app': app, 'engine': summaries['engine'], 'xctest': {'verified': {'pid': 55, 'parentPID': 44,
            'hostSHA256': '9' * 64, 'hostReceipt': {'hostPath': '/original/xctest', 'bundlePath': '/original/bundle'}},
            'process': xprocess, 'discovery': {'passed': False},
            'command': ['/original/xctest', '/original/bundle', 'expected', 'receipt', 'events', 'exception']}}
    fixture['proofSHA256'] = hashlib.sha256(core.canonical(proof)).hexdigest()
    receipt = {'schema': 'release-native-compiled-app/v4', 'sourceSHA': current, 'runID': 999, 'attempt': 1,
        'appSourceSHA': fixture['appSourceSHA'], 'nativeSourceObjects': objects, 'compilerSHA256': release.COMPILER_SHA,
        'hostSHA256': release.retained.HOST_SHA, 'criteriaSHA256': fixture['criteriaSHA256'], 'passed': True,
        'selected': selectors, 'products': products, 'counts': copy.deepcopy(fixture['counts']), 'freshProofs': {},
        'retainedNative': proof, 'currentRetainedEnvironment': copy.deepcopy(context)}
    return fixture, receipt, expected


class CompiledCoreReuseTests(unittest.TestCase):
    def test_origin_fixture_is_bound_before_untrusted_records_are_read(self):
        self.assertEqual(core.origin()['originalExecution']['runID'], 42737812158)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'origin.json'; path.write_text('{}')
            with patch.object(core, 'FIXTURE', path), self.assertRaisesRegex(ValueError, 'fixture changed'):
                core.origin()

    def test_complete_receipt_verification_is_self_contained_and_retains_original_processes(self):
        fixture, receipt, expected = retained_fixture()
        serialized = json.dumps(receipt)
        with patch.object(core, 'origin', return_value=fixture), patch.object(release, 'criteria', return_value=expected), \
                patch.object(release, 'source_objects', return_value=fixture['nativeSourceObjects']), \
                patch.object(xhost, 'inputs', return_value=fixture['hostInputs']), patch.object(xhost, 'verify_proof') as xverify, \
                patch.object(core, 'api', side_effect=AssertionError('No verification network')), \
                patch.object(core, 'download', side_effect=AssertionError('No original files required')):
            restored = json.loads(serialized)
            release.verify_receipt(restored, receipt['sourceSHA'], receipt['runID'])
        self.assertEqual(restored['retainedNative']['app']['hostReceipt']['sourceSHA'], 'a' * 40)
        self.assertEqual(restored['retainedNative']['app']['hostReceipt']['pid'], 66)
        self.assertEqual(restored['counts']['freshApp'], 0)
        xverify.assert_called_once_with(receipt['retainedNative']['xctest']['verified'],
            expected['xctest']['exactIndividualPassedIDs'], 'a' * 40, receipt['products']['tests']['receipt'])

    def test_semantic_guards_reject_forged_summaries_even_with_a_recomputed_golden_digest(self):
        fixture, receipt, expected = retained_fixture()
        mutations = [(['retainedNative', 'app', 'events', 'endedFunctionIDs'], []),
            (['retainedNative', 'app', 'parameterCaseCounts'], {}),
            (['retainedNative', 'app', 'hostReceipt', 'sourceSHA'], receipt['sourceSHA']),
            (['retainedNative', 'app', 'hostReceipt', 'parentPID'], 45),
            (['retainedNative', 'app', 'process', 'exitCode'], 1),
            (['retainedNative', 'app', 'process', 'observation', 'outputCapture', 'eof'], False),
            (['retainedNative', 'app', 'command'], ['original-host', '--filter']),
            (['retainedNative', 'app', 'events', 'runStarted'], True),
            (['retainedNative', 'xctest', 'discovery', 'passed'], True),
            (['retainedNative', 'engine', 'events', 'skippedFunctionIDs'], []),
            (['retainedNative', 'engine', 'sourceObjects'], {'Engine': 'changed'}),
            (['retainedNative', 'engine', 'environment', 'current', 'osVersion'], 'different'),
            (['freshProofs'], {'app-swift-testing': {}}), (['counts', 'freshApp'], 3712),
            (['products', 'tests', 'receipt', 'state', 'linkComplete'], False),
            (['currentRetainedEnvironment', 'architecture'], 'x86_64')]
        for path, value in mutations:
            broken = copy.deepcopy(receipt); current = broken
            for key in path[:-1]: current = current[key]
            current[path[-1]] = value
            changed_fixture = copy.deepcopy(fixture)
            changed_fixture['proofSHA256'] = hashlib.sha256(core.canonical(broken['retainedNative'])).hexdigest()
            with self.subTest(path=path), patch.object(core, 'origin', return_value=changed_fixture), \
                    patch.object(xhost, 'inputs', return_value=fixture['hostInputs']), patch.object(xhost, 'verify_proof'), \
                    self.assertRaises(ValueError):
                core.verify(broken['retainedNative'], broken, expected, release)

    def test_current_cohort_never_starts_native_processes_or_falls_back_after_reuse_failure(self):
        fixture, receipt, expected = retained_fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / 'bound.json').write_text('{}')
            with patch.object(core, 'origin', return_value=fixture), patch.object(release, 'native_guard'), \
                    patch.object(release, 'criteria', return_value=expected), patch.object(core, 'acquire', return_value=receipt) as acquire, \
                    patch.object(xhost, 'run') as xrun, patch.object(native, 'run_process') as process:
                self.assertIs(release.run_tests(root), receipt)
                acquire.side_effect = ValueError('Invalid retained original')
                with self.assertRaisesRegex(ValueError, 'Invalid retained original'): release.run_tests(root)
                xrun.assert_not_called(); process.assert_not_called()
                self.assertFalse((root / 'native-tests.STARTED.json').exists())

    def test_changed_compiler_selectors_or_native_objects_fail_before_origin_acquisition(self):
        fixture, receipt, expected = retained_fixture()
        bound = {'sourceSHA': receipt['sourceSHA'], 'runID': receipt['runID'], 'appSourceSHA': fixture['appSourceSHA'],
            'selected': fixture['compiledSelectors'], 'nativeSourceObjects': fixture['nativeSourceObjects']}
        for key in ['selected', 'nativeSourceObjects', 'appSourceSHA', 'sourceSHA', 'runID']:
            broken = copy.deepcopy(bound); broken[key] = {} if isinstance(broken[key], dict) else 'changed'
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temporary, \
                    patch.dict(os.environ, GITHUB_SHA=receipt['sourceSHA'], GITHUB_RUN_ID=str(receipt['runID'])), \
                    patch.object(core, 'origin', return_value=fixture), patch.object(core, 'api') as api, \
                    patch.object(release, 'source_objects', return_value=fixture['nativeSourceObjects']), self.assertRaises(ValueError):
                core.acquire(Path(temporary), broken, expected, release)
            api.assert_not_called()

    def test_original_capture_precedes_decode_failure_and_rejects_foreign_producers(self):
        import verified_pr_source_checks as checks
        for change in ('valid-then-malformed-json', 'repository', 'runner', 'artifact', 'attempt'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); fixture, receipt, expected = retained_fixture()
                payload = b'{'; source_zip = root / 'source.zip'
                with zipfile.ZipFile(source_zip, 'w') as archive: archive.writestr('bound.json', payload)
                fixture['members'] = {'bound.json': {'bytes': 1, 'sha256': hashlib.sha256(payload).hexdigest()}}
                fixture['archiveNames'] = ['bound.json']
                original = fixture['originalExecution']; original['artifactSHA256'] = release.checksum(source_zip)
                raw = b'complete original producer log'; original['fullRawSHA256'] = hashlib.sha256(raw).hexdigest()
                run = {'id': original['runID'], 'head_sha': original['sourceSHA'], 'run_attempt': 1,
                    'repository': {'full_name': 'other/repo' if change == 'repository' else 'iret77/nexgenvideo'},
                    'status': 'completed', 'conclusion': 'failure', 'workflow_id': 303346287,
                    'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch', 'actor': {'login': 'iret77'}}
                job = {'id': original['jobID'], 'name': 'release-build', 'run_id': run['id'], 'head_sha': run['head_sha'],
                    'run_attempt': 2 if change == 'attempt' else 1, 'status': 'completed', 'conclusion': 'failure',
                    'labels': ['macos-latest'] if change == 'runner' else ['macrunner'],
                    'started_at': '2026-11-10T01:00:00Z', 'completed_at': '2026-11-10T02:00:00Z'}
                artifact = {'id': original['artifactID'], 'name': 'release-compiled-app-evidence-10-a1',
                    'digest': 'sha256:' + ('0' * 64 if change == 'artifact' else original['artifactSHA256']),
                    'size_in_bytes': source_zip.stat().st_size, 'expired': False,
                    'workflow_run': {'id': run['id'], 'head_sha': run['head_sha']},
                    'created_at': '2026-11-10T01:30:00Z', 'updated_at': '2026-11-10T01:30:00Z',
                    'expires_at': '2099-01-01T00:00:00Z'}
                def api(route):
                    if '/attempts/1/jobs?' in route: return {'total_count': 1, 'jobs': [job]}
                    if route.startswith('actions/runs/'): return run
                    if route.startswith('actions/artifacts/'): return artifact
                    raise AssertionError(route)
                bound = {'sourceSHA': receipt['sourceSHA'], 'runID': receipt['runID'], 'appSourceSHA': fixture['appSourceSHA'],
                    'selected': fixture['compiledSelectors'], 'nativeSourceObjects': fixture['nativeSourceObjects']}
                target = root / 'target'; target.mkdir()
                with patch.object(core, 'origin', return_value=fixture), patch.object(core, 'api', side_effect=api), \
                        patch.object(core, 'download', side_effect=lambda item, destination: shutil.copyfile(source_zip, destination)), \
                        patch.object(checks, 'read_api', return_value=raw), \
                        patch.object(release, 'source_objects', return_value=fixture['nativeSourceObjects']), \
                        patch.dict(os.environ, GITHUB_SHA=receipt['sourceSHA'], GITHUB_RUN_ID=str(receipt['runID'])), \
                        patch.object(xhost, 'run') as xrun, patch.object(native, 'run_process') as process:
                    with self.assertRaises(json.JSONDecodeError if change == 'valid-then-malformed-json' else ValueError):
                        core.acquire(target, bound, expected, release)
                    xrun.assert_not_called(); process.assert_not_called()
                secured = target / 'retained-core/originals-secured.json'
                self.assertEqual(secured.exists(), change == 'valid-then-malformed-json')
                if secured.exists():
                    self.assertEqual((target / 'retained-core/original.zip').read_bytes(), source_zip.read_bytes())
                    self.assertEqual((target / 'retained-core/original-job.log').read_bytes(), raw)
                    self.assertEqual((target / 'retained-core/original-records/bound.json').read_bytes(), payload)
                    before = secured.read_bytes()
                    with self.assertRaises(FileExistsError): core.persist(secured, {'overwritten': True})
                    self.assertEqual(secured.read_bytes(), before)
                    import yaml
                    workflow = yaml.safe_load(Path(__file__).resolve().parents[1].joinpath('.github/workflows/release.yml').read_text())
                    uploads = [step for step in workflow['jobs']['release-build']['steps']
                        if 'compiled-app-release/retained-core/' in step.get('with', {}).get('path', '')]
                    self.assertEqual(len(uploads), 2)
                    self.assertTrue(all('always()' in step.get('if', '') for step in uploads))
                self.assertFalse((target / 'receipt.json').exists())
