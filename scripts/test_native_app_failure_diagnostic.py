"""Diagnostic protocol fixtures; these do not execute the native app."""
import copy
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
import yaml

import native_app_failure_diagnostic as diagnostic


class OriginalNativeFailureDiagnosticTests(unittest.TestCase):
    def rows(self):
        identities = ['App.First/check()/First.swift:1:1', 'App.Second/check()/Second.swift:1:1']
        rows = [{'kind': 'test', 'payload': {'kind': 'function', 'id': identity}} for identity in identities]
        rows += [{'kind': 'event', 'payload': {'kind': 'runStarted'}}]
        for index, identity in enumerate(identities):
            rows += [{'kind': 'event', 'payload': {'kind': 'testStarted', 'testID': identity}}]
            if index == 0:
                rows += [{'kind': 'event', 'payload': {'kind': 'issueRecorded', 'testID': identity,
                    'issue': {'isFailure': True, 'isKnown': False}, 'messages': [{'text': 'Actual refusal.'}]}}]
            rows += [{'kind': 'event', 'payload': {'kind': 'testEnded', 'testID': identity}}]
        rows += [{'kind': 'event', 'payload': {'kind': 'runEnded'}}]
        return identities, rows

    def encode(self, rows):
        return b''.join((json.dumps(dict(row, version='6.4.0')) + '\n').encode() for row in rows)

    def test_failed_complete_native_measurement_keeps_issues_and_never_qualifies_release(self):
        identities, rows = self.rows()
        result = diagnostic.measure(self.encode(rows), identities, expected_cases={})
        self.assertTrue(result['selectionComplete'])
        self.assertFalse(result['passed'])
        self.assertFalse(result['fullReleaseAcceptance'])
        self.assertEqual(result['failedFunctionIDs'], identities[:1])
        self.assertEqual(result['issues'][0]['messages'], [{'text': 'Actual refusal.'}])

    def test_missing_extra_duplicate_cancelled_and_unfinished_native_measurements_reject(self):
        identities, rows = self.rows()
        for defect in ('missing-end', 'extra', 'duplicate-start', 'cancelled', 'unknown-issue', 'no-run-end', 'truncated',
                       'unknown-record', 'unknown-event', 'case-end-before-start', 'open-case'):
            changed = copy.deepcopy(rows)
            if defect == 'missing-end': changed.pop(-2)
            elif defect == 'extra': identities_for_check = identities[:1]
            elif defect == 'duplicate-start': changed.insert(4, copy.deepcopy(changed[3]))
            elif defect == 'cancelled': changed.insert(-1, {'kind': 'event', 'payload': {'kind': 'testCancelled', 'testID': identities[0]}})
            elif defect == 'unknown-issue': changed[4]['payload']['issue']['isKnown'] = True
            elif defect == 'no-run-end': changed.pop()
            elif defect == 'unknown-record': changed.insert(3, {'kind': 'foreign', 'payload': {}})
            elif defect == 'unknown-event': changed.insert(4, {'kind': 'event', 'payload': {'kind': 'foreign'}})
            elif defect == 'case-end-before-start':
                changed[4:4] = [{'kind': 'event', 'payload': {'kind': kind, 'testID': identities[0]}}
                               for kind in ('testCaseEnded', 'testCaseStarted')]
            elif defect == 'open-case': changed.insert(4, {'kind': 'event', 'payload': {'kind': 'testCaseStarted', 'testID': identities[0]}})
            raw = self.encode(changed)
            if defect == 'truncated': raw = raw[:-1]
            with self.subTest(defect=defect), self.assertRaises(ValueError):
                diagnostic.measure(raw, identities_for_check if defect == 'extra' else identities, expected_cases={})

    def inputs(self):
        value = diagnostic.fixture()
        return {'inputs': {'candidate_kind': diagnostic.KIND, 'run_id': str(value['failureRunID']),
            'source_sha': value['failureSourceSHA'], 'artifact_id': str(value['failureArtifactID']),
            'artifact_sha256': value['failureArtifactSHA256'], 'verified_pr_run_id': '123',
            'interface_scale': '1', 'journey_scenario': 'journey'}}

    def test_exact_original_input_mapping_rejects_unrelated_or_foreign_selectors(self):
        valid = self.inputs()
        self.assertEqual(diagnostic.validate_inputs(valid), diagnostic.fixture())
        for key, value in [('run_id', '124'), ('source_sha', 'a' * 40), ('artifact_sha256', 'a' * 64),
                           ('verified_pr_run_id', ''), ('interface_scale', '1.5'),
                           ('runtime_failure_binding', '{}'), ('products_artifact_id', '123'),
                           ('packaging_producer_source_sha', 'a' * 40), ('test_bundle_run_id', '123')]:
            changed = copy.deepcopy(valid); changed['inputs'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): diagnostic.validate_inputs(changed)

    def origin(self):
        value = diagnostic.fixture()
        run = {'id': value['failureRunID'], 'head_sha': value['failureSourceSHA'], 'run_attempt': 1,
            'status': 'completed', 'conclusion': 'failure', 'path': '.github/workflows/release.yml',
            'event': 'workflow_dispatch', 'actor': {'login': 'iret77'}, 'repository': {'full_name': 'iret77/nexgenvideo'}}
        job = {'id': value['failureJobID'], 'name': 'release-build', 'run_id': run['id'], 'run_attempt': 1,
            'head_sha': run['head_sha'], 'status': 'completed', 'conclusion': 'failure', 'labels': ['macrunner'],
            'started_at': '2026-11-14T14:00:00Z', 'completed_at': '2026-11-14T14:20:00Z',
            'steps': [{'name': 'Verify the complete new App and XCTest scope', 'conclusion': 'failure'}]}
        artifact = {'id': value['failureArtifactID'], 'name': f"release-compiled-app-evidence-{run['id']}-a1",
            'digest': 'sha256:' + value['failureArtifactSHA256'], 'expired': False,
            'workflow_run': {'id': run['id'], 'head_sha': run['head_sha']}, 'size_in_bytes': value['failureArtifactBytes'],
            'created_at': '2026-11-14T14:19:00Z', 'updated_at': '2026-11-14T14:19:00Z', 'expires_at': '2099-01-01T00:00:00Z'}
        return value, run, {'jobs': [job], 'total_count': 1}, artifact

    def test_failure_provenance_rejects_wrong_phase_attempt_runner_digest_or_timestamps(self):
        value, run, jobs, artifact = self.origin()
        self.assertEqual(diagnostic.verify_failure_origin(value, run, jobs, artifact), jobs['jobs'][0])
        for defect in ('phase', 'attempt', 'runner', 'digest', 'size', 'time', 'inventory', 'actor'):
            changed_run, changed_jobs, changed_artifact = copy.deepcopy((run, jobs, artifact))
            job = changed_jobs['jobs'][0]
            if defect == 'phase': job['steps'][0]['name'] = 'Sign app'
            elif defect == 'attempt': changed_run['run_attempt'] = 2
            elif defect == 'runner': job['labels'] = ['macos-latest']
            elif defect == 'digest': changed_artifact['digest'] = 'sha256:' + 'a' * 64
            elif defect == 'size': changed_artifact['size_in_bytes'] += 1
            elif defect == 'time': changed_artifact['created_at'] = '2026-11-14T13:59:00Z'
            elif defect == 'inventory': changed_jobs['total_count'] += 1
            else: changed_run['actor']['login'] = 'different'
            with self.subTest(defect=defect), self.assertRaises(ValueError):
                diagnostic.verify_failure_origin(value, changed_run, changed_jobs, changed_artifact)

    def test_filter_is_canonical_and_cannot_match_another_function(self):
        identities = diagnostic.fixture()['failedFunctionIDs']
        selected = diagnostic.scope_filter(identities)
        self.assertEqual(selected, diagnostic.scope_filter(list(reversed(identities))))
        self.assertEqual(len(identities), 10)
        for identity in identities: self.assertRegex(identity, selected)
        self.assertIsNone(re.search(selected, 'NexGenVideoTests.NativePointerInteractionTests/foreign()/Other.swift:1:1'))

    def test_bounded_owned_process_preserves_success_failure_and_complete_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            for code in (0, 1):
                log = Path(temporary) / str(code)
                result = diagnostic.run_owned([sys.executable, '-c', f'print("complete"); raise SystemExit({code})'], log, dict(os.environ))
                self.assertEqual(result['exitCode'], code)
                self.assertTrue(result['eof'])
                self.assertTrue(result['processReaped'])
                self.assertIsNone(result['stoppedReason'])
                self.assertEqual(log.read_bytes().strip(), b'complete')

    def test_bounded_owned_process_stops_its_child_on_deadline_or_output_cap(self):
        with tempfile.TemporaryDirectory() as temporary:
            for reason, command, options in [
                ('timeout', 'import time; time.sleep(60)', {'timeout': 0.1}),
                ('output-cap', 'print("x" * 128)', {'byte_limit': 16})]:
                log = Path(temporary) / reason
                result = diagnostic.run_owned([sys.executable, '-c', command], log, dict(os.environ), **options)
                self.assertEqual(result['stoppedReason'], reason)
                self.assertTrue(result['processReaped'])
                if reason == 'output-cap': self.assertEqual(log.stat().st_size, 16)

    def test_workflow_keeps_original_diagnostic_separate_from_compilation_and_release_acceptance(self):
        workflow = yaml.safe_load(Path('.github/workflows/diagnostic-acceptance.yml').read_text())
        job = workflow['jobs']['app-native-failure-diagnostic']
        self.assertEqual(job['runs-on'], 'macrunner')
        self.assertEqual(job['needs'], 'source')
        self.assertEqual(job['if'], "inputs.candidate_kind == 'native-app-native-failure-diagnostic'")
        commands = [step['run'] for step in job['steps'] if 'run' in step]
        self.assertEqual(len(commands), 2)
        self.assertIn('native_app_failure_diagnostic.py run', commands[1])
        self.assertNotIn('swift build', '\n'.join(commands))
        source_steps = workflow['jobs']['source']['steps']
        producer = next(step for step in source_steps if step.get('id') == 'native-failure-binding-upload')
        self.assertEqual(producer['if'], job['if'])
        source_proof = next(step for step in source_steps if step.get('name') == 'Reuse complete current merged PR source proof')
        self.assertIn(job['if'], source_proof['if'])
        for step in source_steps:
            if step.get('name') == 'Bind the successful release job and immutable artifact':
                self.assertIn("inputs.candidate_kind != 'native-app-native-failure-diagnostic'", step['if'])


if __name__ == '__main__': unittest.main()
