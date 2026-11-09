import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import compiled_app_release as release
import native_xctest_host as fresh_host
import compiled_xctest_reuse as reuse
import run_macos_tests as native


class CompiledXCTestReuseTests(unittest.TestCase):
    def inventory(self):
        value = json.loads(release.CRITERIA.read_text())
        for module in value['modules'].values():
            module['exactDiscoveredFunctionIDs'] = sorted(module['exactEndedFunctionIDs'] + module['exactSkippedFunctionIDs'])
        return value

    def transcript(self):
        ids = self.inventory()['xctest']['exactIndividualPassedIDs']
        lines = ["Test Suite 'All tests' started at 2026-11-09 13:17:20.811."]
        for identifier in ids:
            lines += [f"Test Case '{identifier}' started.", f"Test Case '{identifier}' passed (0.001 seconds)."]
        lines += ["Test Suite 'All tests' passed at 2026-11-09 13:17:43.833.",
            '\t Executed 48 tests, with 0 failures (0 unexpected) in 23.019 (23.022) seconds',
            '◇ Test run started.', '✘ Test run with 3716 tests in 528 suites failed after 443.242 seconds with 285 issues.']
        return ('\n'.join(lines) + '\n').encode(), ids

    def process(self):
        return {'pid': 1729, 'exitCode': 1, 'observation': {'outputCapture': {
            'eof': True, 'originalExitCode': 1, 'postExitDrainSeconds': 2}}}

    def proof(self):
        raw, ids = self.transcript()
        scope = reuse.framework(raw, self.process(), ['/Xcode/usr/bin/xctest', '/Release/NexGenVideoTests.xctest'], ids)
        scope['consoleSHA256'] = reuse.MEMBERS['xctest/console.log']['sha256']
        run = {'id': reuse.RUN, 'head_sha': reuse.SOURCE, 'run_attempt': 1, 'status': 'completed', 'conclusion': 'failure',
            'workflow_id': 303346287, 'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch',
            'actor': {'login': 'iret77'}, 'repository': {'full_name': 'iret77/nexgenvideo'}}
        job = {'id': reuse.JOB, 'run_id': reuse.RUN, 'head_sha': reuse.SOURCE, 'run_attempt': 1, 'name': 'release-build',
            'status': 'completed', 'conclusion': 'failure', 'labels': ['macrunner'],
            'started_at': '2026-11-09T13:13:00Z', 'completed_at': '2026-11-09T13:27:23Z'}
        artifact = {'id': reuse.ARTIFACT, 'name': f'release-compiled-app-evidence-{reuse.RUN}-a1',
            'digest': 'sha256:' + reuse.DIGEST, 'expired': False, 'workflow_run': {'id': reuse.RUN, 'head_sha': reuse.SOURCE},
            'created_at': '2026-11-09T13:26:00Z', 'updated_at': '2026-11-09T13:27:00Z', 'expires_at': '2099-01-01T00:00:00Z'}
        context = {key: 'measured ' + key for key in ('swift', 'xcode', 'python', 'osVersion', 'osBuild')}
        return {'schema': 'retained-current-candidate-xctest/v1', 'runID': reuse.RUN, 'sourceSHA': reuse.SOURCE,
            'artifactID': reuse.ARTIFACT, 'artifactSHA256': reuse.DIGEST, 'fullRawSHA256': reuse.LOG_DIGEST,
            'signedTestsImageSHA256': reuse.IMAGE_SHA, 'selected': {'tests': 'same exact selector'},
            'nativeSourceObjects': {'Sources': 'a' * 40},
            'originalEnvironment': {'original': context, 'current': context, 'architecture': 'arm64'},
            'memberIdentities': copy.deepcopy(reuse.MEMBERS), 'originalSignatureVerificationExitCode': 0,
            'producer': {'run': run, 'job': job, 'artifact': artifact}, 'framework': scope}

    def test_completed_xctest_scope_keeps_the_mixed_process_failure_and_later_swift_failure(self):
        raw, ids = self.transcript()
        result = reuse.framework(raw, self.process(), ['/Xcode/usr/bin/xctest', '/Release/NexGenVideoTests.xctest'], ids)
        self.assertEqual(result['individualStartedIDs'], sorted(ids))
        self.assertEqual(result['individualPassedIDs'], sorted(ids))
        self.assertEqual(result['originalProcessExitCode'], 1)
        self.assertTrue(result['originalProcessEOF'])
        self.assertFalse(result['wholeProcessQualifiedAsSuccess'])
        self.assertFalse(result['unexpectedSwiftTestingQualified'])
        self.assertEqual(result['consoleSHA256'], hashlib.sha256(raw).hexdigest())

    def test_partial_duplicate_failed_reordered_filtered_or_unfinished_frameworks_cannot_be_reused(self):
        raw, ids = self.transcript()
        command = ['/Xcode/usr/bin/xctest', '/Release/NexGenVideoTests.xctest']
        text = raw.decode()
        variants = [text.replace(f"Test Case '{ids[0]}' passed (0.001 seconds).\n", ''),
            text.replace(f"Test Case '{ids[0]}' started.", f"Test Case '{ids[1]}' started."),
            text.replace(f"Test Case '{ids[0]}' passed", f"Test Case '{ids[0]}' failed"),
            text.replace("Test Suite 'All tests' passed at 2026-11-09 13:17:43.833.", ''),
            text.replace('0 failures (0 unexpected)', '1 failures (1 unexpected)'),
            '◇ Test run started.\n' + text.replace('◇ Test run started.\n', ''),
            text + '◇ Test run started.\n', text.replace('with 285 issues.', 'with 284 issues.')]
        for value in variants:
            with self.subTest(value=value[-120:]), self.assertRaises(ValueError):
                reuse.framework(value.encode(), self.process(), command, ids)
        for field, value in [('exitCode', 0), ('eof', False), ('originalExitCode', 0)]:
            process = self.process()
            target = process if field == 'exitCode' else process['observation']['outputCapture']
            target[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                reuse.framework(raw, process, command, ids)
        with self.assertRaises(ValueError):
            reuse.framework(raw, self.process(), command + ['-XCTest', ids[0]], ids)

    def test_retained_scope_rejects_changed_producer_artifact_input_image_context_or_success_relabeling(self):
        proof = self.proof()
        ids = self.inventory()['xctest']['exactIndividualPassedIDs']
        args = (ids, proof['selected'], proof['nativeSourceObjects'], proof['originalEnvironment'])
        self.assertIs(reuse.verify(proof, *args), proof)
        changes = [(['runID'], reuse.RUN + 1), (['sourceSHA'], 'b' * 40), (['signedTestsImageSHA256'], 'b' * 64),
            (['selected', 'tests'], 'different'), (['nativeSourceObjects', 'Sources'], 'b' * 40),
            (['originalEnvironment', 'architecture'], 'x86_64'), (['originalSignatureVerificationExitCode'], 1),
            (['memberIdentities', 'bound.json', 'sha256'], 'b' * 64),
            (['producer', 'run', 'conclusion'], 'success'), (['producer', 'run', 'run_attempt'], 2),
            (['producer', 'run', 'repository', 'full_name'], 'other/repo'),
            (['producer', 'job', 'labels'], ['macos-latest']), (['producer', 'job', 'id'], reuse.JOB + 1),
            (['producer', 'artifact', 'expired'], True), (['producer', 'artifact', 'digest'], 'sha256:' + 'b' * 64),
            (['producer', 'artifact', 'updated_at'], '2026-11-09T14:00:00Z'),
            (['framework', 'individualPassedIDs'], sorted(ids[:-1])), (['framework', 'originalProcessExitCode'], 0),
            (['framework', 'wholeProcessQualifiedAsSuccess'], True), (['framework', 'unexpectedSwiftTestingQualified'], True)]
        for path, value in changes:
            broken = copy.deepcopy(proof)
            parent = broken
            for key in path[:-1]: parent = parent[key]
            parent[path[-1]] = value
            with self.subTest(path=path), self.assertRaises(ValueError): reuse.verify(broken, *args)

    def test_changed_candidate_executes_fresh_xctest_and_full_appkit_host_once_each(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            host = root / 'runtime/NexGenVideoAppKitTestHost'
            image = root / 'tests/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests'
            compiler = root / 'swiftc'
            bound = {'sourceSHA': 'b' * 40, 'runID': 999, 'nativeSourceObjects': {'Sources': 'a' * 40},
                'runtime': str(host.parent), 'selected': {'tests': 'exact selector'},
                'prepared': {'plans': {'production': {'driver': {'argv': [str(compiler)]}}}},
                'products': {phase: {'receipt': {}, 'originalArchiveSHA256': 'f' * 64,
                    'output': str(image)} for phase in release.PHASES}}
            (root / 'bound.json').write_text(json.dumps(bound))
            inventory = self.inventory()
            events = {'endedFunctionIDs': inventory['modules']['app']['exactEndedFunctionIDs'], 'functionExecutions': 3712}
            observation = {'outputCapture': {'originalExitCode': 0, 'eof': True}}
            retained_engine = {'environment': {'architecture': 'arm64'}}
            fresh_xctest = {'schema': 'native-xctest-host-proof/v1'}
            def checksum(path):
                return release.retained.HOST_SHA if path == host else release.COMPILER_SHA if path == compiler else 'f' * 64
            with patch.object(release, 'native_guard'), patch.object(release, 'source_objects', return_value=bound['nativeSourceObjects']), \
                    patch.object(release.targets, 'logged') as signed, \
                    patch.object(release, 'criteria', return_value=inventory), patch.object(release, 'checksum', side_effect=checksum), \
                    patch.object(release, 'retained_engine_evidence', return_value=retained_engine), \
                    patch.object(reuse, 'acquire') as acquire, \
                    patch.object(fresh_host, 'run', return_value=fresh_xctest) as fresh, \
                    patch.object(native, 'app_environment', return_value={}), \
                    patch.object(native, 'prepare_post_mortem', return_value=observation), \
                    patch.object(native, 'run_process', return_value=(0, 123)) as process, \
                    patch.object(native, 'host_receipt', return_value={'complete': True}), \
                    patch.object(native, 'framework_output', return_value={'passed': True}), \
                    patch.object(release, 'verify_events', return_value=events), patch.object(release, 'verify_receipt') as verify, \
                    patch.dict(os.environ, {'GITHUB_SHA': bound['sourceSHA'], 'GITHUB_RUN_ID': '999'}):
                release.run_tests(root)
            process.assert_called_once()
            signed.assert_called_once_with(root, 'verify-test-bundle',
                ['codesign', '--verify', '--deep', '--strict', str(image.parents[2])])
            self.assertEqual(process.call_args.args[0], [str(host), '--event-stream-version', '0', '--no-parallel'])
            self.assertEqual(process.call_args.args[2]['NGV_APPKIT_TEST_BUNDLE'], str(image.resolve()))
            acquire.assert_not_called()
            fresh.assert_called_once_with(root / 'xctest', bound, image, inventory['xctest']['exactIndividualPassedIDs'])
            receipt = json.loads((root / 'receipt.json').read_text())
            self.assertEqual(receipt['schema'], 'release-native-compiled-app/v3')
            self.assertEqual(receipt['counts'], {'freshApp': 3712, 'freshXCTest': 48, 'retainedEngine': 896,
                'executions': 4656, 'appSkips': 8, 'engineSkips': 14})
            self.assertEqual(set(receipt['freshProofs']), {'app-swift-testing', 'xctest'})
            self.assertEqual(receipt['freshProofs']['xctest'], fresh_xctest)
            self.assertNotIn('retainedCurrentXCTest', receipt)
            self.assertFalse((root / 'xctest').exists())
            verify.assert_called_once()

    def test_receipt_versions_keep_fresh_and_retained_xctest_roles_separate(self):
        class RolesReached(Exception):
            pass
        source, objects = 'b' * 40, {'Sources': 'a' * 40}
        receipt = {'schema': 'release-native-compiled-app/v2', 'sourceSHA': source, 'runID': 999, 'attempt': 1,
            'appSourceSHA': release.APP_SOURCE, 'nativeSourceObjects': objects, 'compilerSHA256': release.COMPILER_SHA,
            'hostSHA256': release.retained.HOST_SHA, 'criteriaSHA256': 'c' * 64, 'passed': True,
            'products': {phase: {} for phase in release.PHASES}, 'freshProofs': {'app-swift-testing': {}},
            'counts': {'freshApp': 3708, 'retainedCurrentXCTest': 48, 'retainedEngine': 896,
                'executions': 4652, 'appSkips': 8, 'engineSkips': 14}}
        legacy = copy.deepcopy(receipt)
        legacy['schema'] = 'release-native-compiled-app/v1'
        legacy['counts']['freshXCTest'] = legacy['counts'].pop('retainedCurrentXCTest')
        legacy['freshProofs']['xctest'] = {}
        bad = []
        for path, value in [(['counts', 'retainedCurrentXCTest'], 47), (['counts', 'freshApp'], 3707),
                (['schema'], 'release-native-compiled-app/v3'), (['freshProofs', 'xctest'], {})]:
            broken = copy.deepcopy(receipt)
            parent = broken
            for key in path[:-1]: parent = parent[key]
            parent[path[-1]] = value
            bad.append(broken)
        broken = copy.deepcopy(receipt)
        broken['counts']['freshXCTest'] = broken['counts'].pop('retainedCurrentXCTest')
        bad.append(broken)
        with patch.object(release, 'source_objects', return_value=objects), patch.object(release, 'checksum', return_value='c' * 64), \
                patch.object(release, 'selector_identities', side_effect=RolesReached) as roles:
            for valid in (receipt, legacy):
                with self.assertRaises(RolesReached): release.verify_receipt(valid, source, 999)
            for broken in bad:
                roles.reset_mock()
                with self.subTest(schema=broken['schema']), self.assertRaises(ValueError):
                    release.verify_receipt(broken, source, 999)
                roles.assert_not_called()


if __name__ == '__main__':
    unittest.main()
