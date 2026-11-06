import copy
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

import yaml

import button_query_diagnostic as diagnostic


class ButtonQueryDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.env = dict(KIND='native-button-query', CANDIDATE_RUN='12', CANDIDATE_ARTIFACT='34', VERIFIED_PR='56',
                        CANDIDATE_SOURCE=diagnostic.SOURCE, CANDIDATE_DIGEST='b' * 64, SCALE='1', DMG_DIGEST='')
        self.run = dict(id=12, head_sha=diagnostic.SOURCE, run_attempt=1, actor=dict(login='iret77'),
                        repository=dict(full_name='iret77/nexgenvideo'), path='.github/workflows/release.yml',
                        event='workflow_dispatch', status='completed', conclusion='failure')
        self.job = dict(id=78, name='release-build', run_id=12, head_sha=diagnostic.SOURCE, run_attempt=1,
                        labels=['macrunner'], status='completed', conclusion='failure', steps=[
                            dict(name='Build the exact release test configuration', conclusion='success'),
                            dict(name='Test the exact release configuration', conclusion='failure')])
        self.jobs = dict(total_count=1, jobs=[self.job])
        self.artifact = dict(id=34, name='release-test-evidence', expired=False, digest='sha256:' + 'b' * 64,
                             workflow_run=dict(id=12, head_sha=diagnostic.SOURCE))

    def test_inputs_reject_every_unconsumed_selector_and_missing_identity(self):
        diagnostic.validate_inputs(self.env)
        for field, value in [('KIND', 'signed-release'), ('CANDIDATE_RUN', '0'), ('CANDIDATE_ARTIFACT', '-1'),
                             ('VERIFIED_PR', ''), ('CANDIDATE_SOURCE', 'c' * 40), ('CANDIDATE_DIGEST', 'B' * 64),
                             ('SCALE', '1.5'), *[(key, 'unexpected') for key in (
                                 'DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'EXTRA_SOURCE',
                                 'EXTRA_PRODUCTS', 'EXTRA_FAILURE', 'EXTRA_PRODUCTS_SHA', 'EXTRA_FAILURE_SHA',
                                 'RUNTIME_FAILURE_BINDING', 'PACKAGING_PRODUCER_SOURCE', 'PACKAGING_PROVENANCE_ARTIFACT_ID',
                                 'PACKAGING_PROVENANCE_ARTIFACT_SHA256')]]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(self.env, **{field: value}))

    def test_producer_requires_actual_failed_native_job_and_exact_source_attempt(self):
        self.assertEqual(diagnostic.verify_producer(self.run, self.jobs, self.artifact, self.env), self.job)
        for key, bad in [('id', 13), ('head_sha', 'c' * 40), ('run_attempt', 2), ('conclusion', 'success'),
                         ('actor', dict(login='someone')), ('repository', dict(full_name='other/repository'))]:
            with self.subTest(field=key), self.assertRaises(ValueError):
                diagnostic.verify_producer(dict(self.run, **{key: bad}), self.jobs, self.artifact, self.env)
        for key, bad in [('run_id', 13), ('head_sha', 'c' * 40), ('run_attempt', 2), ('conclusion', 'success'),
                         ('labels', ['ubuntu-24.04']), ('status', 'in_progress')]:
            jobs = dict(total_count=1, jobs=[dict(self.job, **{key: bad})])
            with self.subTest(job=key), self.assertRaises(ValueError):
                diagnostic.verify_producer(self.run, jobs, self.artifact, self.env)

    def test_failed_compile_or_ambiguous_native_job_cannot_authorize_observation(self):
        for variant in ('compile', 'test', 'missing', 'duplicate', 'truncated'):
            jobs = copy.deepcopy(self.jobs)
            if variant == 'compile': jobs['jobs'][0]['steps'][0]['conclusion'] = 'failure'
            elif variant == 'test': jobs['jobs'][0]['steps'][1]['conclusion'] = 'success'
            elif variant == 'missing': jobs = dict(total_count=0, jobs=[])
            elif variant == 'duplicate': jobs = dict(total_count=2, jobs=[self.job, self.job])
            else: jobs['total_count'] = 2
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                diagnostic.verify_producer(self.run, jobs, self.artifact, self.env)

    def test_evidence_identity_cannot_move_between_runs_or_change_digest(self):
        for key, bad in [('id', 35), ('name', 'NexGenVideo-app'), ('expired', True), ('digest', 'sha256:' + 'c' * 64),
                         ('workflow_run', dict(id=13, head_sha=diagnostic.SOURCE)),
                         ('workflow_run', dict(id=12, head_sha='c' * 40))]:
            with self.subTest(field=key), self.assertRaises(ValueError):
                diagnostic.verify_producer(self.run, self.jobs, dict(self.artifact, **{key: bad}), self.env)

    def archive(self, root, change=None):
        prefix = '_temp/release-test-evidence/'
        suite = dict(sourceSHA=diagnostic.SOURCE, completed=False, scope='all', filter='', phases=[
            dict(name=name, exitCode=code) for name, code in [('xctest', 0), ('engine-swift-testing', 0), ('app-swift-testing', 1)]])
        host = dict(sourceSHA=diagnostic.SOURCE, started=True, completed=True, abiSucceeded=False, mainThread=True,
                    runReturnedAfterCompletion=True)
        issues = [dict(kind='event', payload=dict(kind='issueRecorded', issue=dict(isFailure=True, isKnown=False),
            testID='NexGenVideoTests.NativeButtonInteractionTests/' + name + '()/NativeButtonInteractionTests.swift:1:6'))
            for name in sorted(diagnostic.FAILED)]
        issues += copy.deepcopy(issues[:2] * 4)
        if change == 'foreign': issues[0]['payload']['testID'] = 'NexGenVideoTests.OtherTests/other()/OtherTests.swift:1:6'
        if change == 'missing': issues.pop()
        if change == 'host': host['abiSucceeded'] = True
        if change == 'filtered': suite['filter'] = 'NativeButtonInteractionTests'
        path = root / 'original.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, value in [('suite.json', suite), ('app-swift-testing/host-receipt.json', host),
                                ('retained-engine-receipt.json', dict(toolchain=dict(xcode='Xcode 27.2')))]:
                archive.writestr(prefix + name, json.dumps(value))
            archive.writestr(prefix + 'app-swift-testing/events.jsonl', '\n'.join(json.dumps(value) for value in issues))
        return path

    def test_original_failure_archive_keeps_all_issues_and_host_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.archive(Path(directory))
            result = diagnostic.failure_archive(path)
            self.assertEqual(len(result['issues']), 14)
            self.assertEqual(len(result['members']), 4)
            self.assertFalse(result['host']['abiSucceeded'])

    def test_another_failure_branch_or_filtered_original_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for variant in ('foreign', 'missing', 'host', 'filtered'):
                with self.subTest(variant=variant), self.assertRaises(ValueError):
                    diagnostic.failure_archive(self.archive(Path(directory), variant))

    def test_style_subset_preserves_exact_original_byte_ranges_without_stubs(self):
        originals = {path: (diagnostic.ROOT / path).read_bytes() for path in diagnostic.FILES}
        selected, ranges = diagnostic.source_subset(originals)
        self.assertEqual(selected['NativeButtonAccessibility.swift'], originals[diagnostic.QUERY])
        self.assertEqual(selected['CapsuleButton.swift'], originals['Sources/NexGenVideo/UI/CapsuleButton.swift'])
        for name, pieces in ranges.items():
            self.assertEqual(selected[name], b''.join(originals[path][left:right] for path, left, right in pieces))
        self.assertNotIn(b'EditorViewModel', b''.join(selected.values()))
        self.assertNotIn(b'import NexGenEngine', b''.join(selected.values()))
        self.assertIn(b'@Environment(\\.interfaceScale)', selected['CapsuleButton.swift'])

    def test_source_subset_rejects_missing_or_ambiguous_extraction_boundaries(self):
        originals = {path: (diagnostic.ROOT / path).read_bytes() for path in diagnostic.FILES}
        for path, marker in [('Sources/NexGenVideo/UI/AppTheme.swift', b'// MARK: - ClipType color mapping'),
                             ('Sources/NexGenVideo/UI/DesignSystem.swift', b'struct ProjectInterface<Content: View>: View {'),
                             ('Sources/NexGenVideo/UI/PackAccent.swift', b'extension Color {')]:
            for replacement in (b'', marker + marker):
                changed = dict(originals, **{path: originals[path].replace(marker, replacement)})
                with self.subTest(path=path, replacement=replacement), self.assertRaises(ValueError):
                    diagnostic.source_subset(changed)

    def test_owned_timeout_reaps_only_its_fresh_process_group_without_retry(self):
        child = Mock(pid=12345)
        child.wait.side_effect = [subprocess.TimeoutExpired(['probe'], 18), 0]
        with tempfile.TemporaryDirectory() as directory, patch.object(diagnostic.subprocess, 'Popen', return_value=child) as launch, \
                patch.object(diagnostic.os, 'killpg') as kill, self.assertRaisesRegex(ValueError, 'timed out'):
            diagnostic.owned_command(['probe'], Path(directory) / 'probe.log', 18)
        launch.assert_called_once()
        self.assertTrue(launch.call_args.kwargs['start_new_session'])
        self.assertEqual(launch.call_args.kwargs['stdin'], subprocess.DEVNULL)
        kill.assert_called_once_with(12345, signal.SIGTERM)
        self.assertEqual(child.wait.call_count, 2)

    def test_native_observer_needs_both_source_binding_and_current_source_proof(self):
        workflow = yaml.safe_load((diagnostic.ROOT / '.github/workflows/diagnostic-acceptance.yml').read_text())
        native = workflow['jobs']['native-button-query']
        self.assertEqual(native['needs'], 'source')
        self.assertEqual(native['if'], "inputs.candidate_kind == 'native-button-query'")
        self.assertEqual(native['runs-on'], 'macrunner')
        self.assertEqual(native['timeout-minutes'], 5)
        download = next(step for step in native['steps'] if step.get('uses') == 'actions/download-artifact@v4')
        self.assertEqual(download['with']['name'], 'native-button-query-source-binding')
        source = workflow['jobs']['source']['steps']
        proof = next(step for step in source if step.get('name') == 'Reuse complete current merged PR source proof')
        self.assertIn("inputs.candidate_kind == 'native-button-query'", proof['if'])
        binder = next(step for step in source if step.get('name') == 'Bind the original failed button query and unchanged framework sources')
        self.assertLess(source.index(proof), source.index(binder))
        self.assertIn('--source-proof "$RUNNER_TEMP/transport-source-proof"', binder['run'])
        for step in source:
            if step.get('name') == 'Bind the successful release job and immutable artifact':
                self.assertIn("inputs.candidate_kind != 'native-button-query'", step['if'])

    def test_observation_cannot_claim_another_process_or_hide_the_native_child_response(self):
        frame = [0, 0, 600, 200]
        geometry = dict(window=55, frame=frame, CGWindows=[dict(pid=123, number=55, frame=frame, onscreen=True)])
        query = dict(pid=123, window=55, expectedWindowFrame=frame, readOnMainThread=False, plane='public-AX',
                     truncated=True, failure='query-deadline', nodes=[])
        root = dict(AXRole='AXWindow', pid=123, parent=None, AXPosition=[0, 0], AXSize=[600, 200],
                    statuses=dict(attributeNames=0, AXChildren=0, pid=0, AXRole=0, AXPosition=0, AXSize=0),
                    attributeNames=['AXRole', 'AXChildren', 'AXPosition', 'AXSize'], attributeNamesType=10,
                    **{'advertised:AXChildren': True, 'type:AXChildren': 10, 'childTypes:AXChildren': [99], 'count:AXChildren': 1})
        node = dict(AXRole='AXButton', pid=123, parent=0, AXPosition=[20, 20], AXSize=[50, 28],
                    statuses=dict(attributeNames=0, AXChildren=-25212, pid=0, AXRole=0, AXPosition=0, AXSize=0),
                    attributeNames=['AXRole', 'AXPosition', 'AXSize'], attributeNamesType=10,
                    **{'advertised:AXChildren': False, 'type:AXChildren': None, 'count:AXChildren': None})
        raw = dict(pid=123, window=55, requestFrame=frame, readOnMainThread=False, nodes=[root, node],
                   windows=[copy.deepcopy(root)], windowsAfter=[copy.deepcopy(root)], errors=[],
                   applicationStatuses=dict(pid=0, AXWindows=0), applicationStatusesAfter=dict(pid=0, AXWindows=0),
                   hierarchyEnumerationEnded=True, hierarchyComplete=True, targetStillPresentByCFEqual=True,
                   CFArrayTypeID=10, AXUIElementTypeID=99)
        report = dict(schema='nexgenvideo/button-query-framework-control/1', mode='slow-cancel', pid=123,
            mainLoopRunning=True, mainThread=True, originalQueryBeforeAdditionalAX=True, appAcceptance=False,
            sourceSubsetFrameworkFixture=True, parallelAppTestHost=False, originalFirstQuery=query,
            originalQueryAfterCGStability=query, queryAfterAdditionalAX=query,
            beforeFirstQuery=geometry, beforeWarmQuery=geometry, afterWarmQuery=geometry,
            beforeLastQuery=geometry, beforeRawAttributes=geometry, afterRawAttributes=geometry,
            rawAttributesAfterOriginalQueries=raw,
            slowObservation=dict(status='not-reached-warmup-unqualified'))
        diagnostic.validate_observation(report, 'slow-cancel', 123)
        for field, value in [('pid', 124), ('appAcceptance', True), ('originalQueryBeforeAdditionalAX', False),
                             ('slowObservation', dict(status='observed-after-complete-warmup')),
                             ('rawAttributesAfterOriginalQueries', dict(pid=123, readOnMainThread=False, nodes=[]))]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                diagnostic.validate_observation(dict(report, **{field: value}), 'slow-cancel', 123)
        for variant in ('foreign-node', 'other-window', 'unknown-window', 'wrong-root', 'lost-parent',
                        'generic-children', 'lost-child-type', 'hidden-child', 'unfinished', 'deadline',
                        'false-complete', 'unknown-names', 'moved-frame', 'false-status'):
            changed = copy.deepcopy(report)
            value = changed['rawAttributesAfterOriginalQueries']
            if variant == 'foreign-node': value['nodes'][1]['pid'] = 124
            elif variant == 'other-window': value['window'] = 56
            elif variant == 'unknown-window': value['windows'].append(dict(root, AXSize=None))
            elif variant == 'wrong-root': value['nodes'][0]['AXRole'] = 'AXApplication'
            elif variant == 'lost-parent': value['nodes'][1]['parent'] = None
            elif variant == 'generic-children': value['nodes'][1]['statuses']['AXChildren'] = -25200
            elif variant == 'lost-child-type': value['nodes'][0]['childTypes:AXChildren'] = [98]
            elif variant == 'hidden-child': value['nodes'][0]['count:AXChildren'] = 2
            elif variant == 'unfinished': value['hierarchyEnumerationEnded'] = False
            elif variant == 'deadline': value['errors'] = ['deadline']
            elif variant == 'false-complete': value['hierarchyComplete'] = False
            elif variant == 'unknown-names': value['nodes'][1]['attributeNames'] = None
            elif variant == 'moved-frame': changed['afterRawAttributes']['frame'] = [100, 100, 600, 200]
            else: value['nodes'][1]['statuses']['AXChildren'] = False
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                diagnostic.validate_observation(changed, 'slow-cancel', 123)
