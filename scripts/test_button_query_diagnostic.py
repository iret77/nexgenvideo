import copy
import json
import os
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
    def crash_env(self):
        binding = dict(schema='nexgenvideo/button-query-crash-request/1', producer_run_id=diagnostic.PRIOR_RUN,
            producer_source_sha=diagnostic.PRIOR_SOURCE, job_id=diagnostic.PRIOR_JOB,
            source_binding_artifact_id=13468987097, source_binding_artifact_sha256='c' * 64)
        return dict(self.env, KIND=diagnostic.CRASH_KIND, CANDIDATE_RUN='42121681154', CANDIDATE_ARTIFACT='13461467380',
            CANDIDATE_DIGEST='a14ad1c9fbcc0feb712ca93ec8ea3e354591be5e7834ae2b7a94bd2bf28a73f7',
            EXTRA_FAILURE='13469067268', EXTRA_FAILURE_SHA='d' * 64, RUNTIME_FAILURE_BINDING=json.dumps(binding))

    def crash_payload(self):
        files = {'original.swift': {'SHA256': 'a' * 64, 'gitBlob': 'b' * 40}}
        binding = dict(schema='nexgenvideo/button-query-binding/1', sourceSHA=diagnostic.PRIOR_SOURCE,
            sourceTree='4b944c7fd973270c072160f48b243b64f9de3567', runID=str(diagnostic.PRIOR_RUN), attempt='1',
            originalRun=dict(id=42121681154, head_sha=diagnostic.SOURCE),
            originalArtifact=dict(id=13461467380, digest='sha256:a14ad1c9fbcc0feb712ca93ec8ea3e354591be5e7834ae2b7a94bd2bf28a73f7'),
            sourceFiles=files, sourceProof=dict(schema='core-pr-source-composition/v1', sourceSHA=diagnostic.PRIOR_SOURCE,
                runID=str(diagnostic.PRIOR_RUN), attempt='1', originalRun=dict(id=42140974612)))
        source = {'binding.json': json.dumps(binding).encode(), 'original-evidence.zip': b'fresh qualified original ZIP bytes'}
        results, observations = [], {}
        for index, mode in enumerate(diagnostic.MODES):
            process = dict(pid=100 + index, exitCode=-5 if mode in diagnostic.CRASH_MODES else 0,
                processReaped=True, timedOut=False)
            results.append(dict(mode=mode, status='failed-observation', process=process))
            observations[mode + '.process.json'] = json.dumps(process).encode()
            observations[mode + '.log'] = b''
        receipt = dict(schema='nexgenvideo/button-query-observation/1', sourceSHA=diagnostic.PRIOR_SOURCE,
            runID=str(diagnostic.PRIOR_RUN), attempt='1', bindingSHA256=diagnostic.digest(source['binding.json']),
            measurementComplete=False, appAcceptance=False, appBuilds=0, nativeUnitExecutions=0,
            originalFailureResolved=False, results=results)
        observations['receipt.json'] = json.dumps(receipt).encode()
        return observations, source, files

    def ips(self):
        command = '/tmp/owned-123-a1/nbq0000000123'
        process = dict(pid=77, command=[command], exitCode=-5, processReaped=True, timedOut=False,
            executableSHA256='a' * 64, startedWall='2026-11-06T01:00:00+00:00', finishedWall='2026-11-06T01:00:02+00:00')
        report = dict(pid=77, procName=Path(command).name, procPath='/Users/USER/private/owned-123-a1/nbq0000000123',
            procLaunch='2026-11-06T01:00:00.100+00:00', captureTime='2026-11-06T01:00:01.900+00:00',
            exception=dict(signal='SIGTRAP', type='EXC_BREAKPOINT'), faultingThread=0,
            threads=[dict(frames=[dict(imageIndex=0, imageOffset=123, symbol='actual failure')])],
            usedImages=[dict(name=Path(command).name, path=command, base=4096, size=4096, uuid='11111111-2222-4333-8444-555555555555')])
        return process, report

    def slow_report(self, mode):
        frame = [0, 0, 600, 200]
        geometry = dict(window=55, frame=frame, CGWindows=[dict(pid=123, number=55, frame=frame, onscreen=True)])
        root = dict(AXRole='AXWindow', pid=123, parent=None, AXPosition=[0, 0], AXSize=[600, 200],
            statuses=dict(attributeNames=0, AXChildren=0, pid=0, AXRole=0, AXPosition=0, AXSize=0),
            attributeNames=['AXRole', 'AXChildren', 'AXPosition', 'AXSize'], attributeNamesType=10,
            **{'advertised:AXChildren': True, 'type:AXChildren': 10, 'childTypes:AXChildren': [99], 'count:AXChildren': 1})
        button = dict(AXRole='AXButton', pid=123, parent=0, AXPosition=[20, 20], AXSize=[50, 28],
            statuses=dict(attributeNames=0, AXChildren=-25212, pid=0, AXRole=0, AXPosition=0, AXSize=0),
            attributeNames=['AXRole', 'AXPosition', 'AXSize'], attributeNamesType=10,
            **{'advertised:AXChildren': False, 'type:AXChildren': None, 'count:AXChildren': None})
        node = dict(pid=123, role='AXButton', enabled=True, title=None, label='Undo', publicScreenFrame=[20, 20, 50, 28],
            statuses=dict(pid=0, AXRole=0, AXEnabled=0, AXPosition=0, AXSize=0))
        warm = dict(pid=123, window=55, expectedWindowFrame=frame, readOnMainThread=False, plane='public-AX',
            truncated=False, failure=None, windowCandidates=1, nodes=[node])
        query = dict(warm, truncated=True, failure='cancelled' if mode == 'slow-cancel' else 'AX-read-AXChildren:-25204',
            startedUptime=2.0, finishedUptime=2.2, nodes=[dict(label='Bounded child', statuses={'AXChildren': -25204, 'timeout:AXChildren': 0})])
        raw = dict(pid=123, window=55, requestFrame=frame, readOnMainThread=False, nodes=[root, button],
            windows=[copy.deepcopy(root)], windowsAfter=[copy.deepcopy(root)], errors=[],
            applicationStatuses=dict(pid=0, AXWindows=0), applicationStatusesAfter=dict(pid=0, AXWindows=0),
            hierarchyEnumerationEnded=True, hierarchyComplete=True, targetStillPresentByCFEqual=True,
            CFArrayTypeID=10, AXUIElementTypeID=99)
        return dict(schema='nexgenvideo/button-query-framework-control/1', mode=mode, pid=123,
            mainLoopRunning=True, mainThread=True, originalQueryBeforeAdditionalAX=True, appAcceptance=False,
            sourceSubsetFrameworkFixture=True, parallelAppTestHost=False, originalFirstQuery=warm,
            originalQueryAfterCGStability=warm, queryAfterAdditionalAX=warm,
            beforeFirstQuery=geometry, beforeWarmQuery=geometry, afterWarmQuery=geometry,
            beforeLastQuery=geometry, beforeRawAttributes=geometry, afterRawAttributes=geometry,
            rawAttributesAfterOriginalQueries=raw,
            slowObservation=dict(status='observed-after-complete-warmup', getterEntered=True, enabledUndoCount=1,
                enteredAt=2.05, returnedAt=2.4, cancelRequestedAt=2.1 if mode == 'slow-cancel' else 0,
                requestedSeconds=1 if mode == 'slow-cancel' else 0.2, query=query))

    def test_crash_mode_requires_exact_failed_producer_without_ignored_selectors(self):
        env = self.crash_env()
        diagnostic.validate_inputs(env)
        for key, value in [('EXTRA_FAILURE', ''), ('EXTRA_FAILURE_SHA', 'bad'), ('RUNTIME_FAILURE_BINDING', ''),
                ('CANDIDATE_RUN', '12'), ('EXTRA_PRODUCTS', '99'), ('JOURNEY_JOB', '1')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(env, **{key: value}))
        for key, value in [('producer_run_id', True), ('producer_run_id', 1), ('producer_source_sha', 'a' * 40),
                ('job_id', 1), ('source_binding_artifact_id', False), ('unexpected', 'x')]:
            changed = json.loads(env['RUNTIME_FAILURE_BINDING']); changed[key] = value
            with self.subTest(binding=key), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(env, RUNTIME_FAILURE_BINDING=json.dumps(changed)))

    def test_prior_crash_payload_requires_exact_source_objects_and_binding_bytes(self):
        observations, source, files = self.crash_payload()
        self.assertEqual(len(diagnostic.verify_crash_payload(observations, source, files, source['original-evidence.zip'])['cases']), 2)
        for archive in ({'binding.json': source['binding.json']}, dict(source, **{'original-evidence.zip': b'other ZIP bytes'})):
            with self.subTest(embedded=list(archive)), self.assertRaises(ValueError):
                diagnostic.verify_crash_payload(observations, archive, files, source['original-evidence.zip'])
        for key, value in [('sourceFiles', {}), ('sourceTree', 'c' * 40), ('originalRun', dict(id=1, head_sha=diagnostic.SOURCE))]:
            changed = json.loads(source['binding.json']); changed[key] = value
            archive = dict(source, **{'binding.json': json.dumps(changed).encode()})
            receipt = json.loads(observations['receipt.json']); receipt['bindingSHA256'] = diagnostic.digest(archive['binding.json'])
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.verify_crash_payload(dict(observations, **{'receipt.json': json.dumps(receipt).encode()}), archive, files, source['original-evidence.zip'])

    def test_prior_slow_failures_cannot_be_substituted_by_timeouts_or_other_signals(self):
        observations, source, files = self.crash_payload()
        for key, value in [('exitCode', 0), ('exitCode', -6), ('timedOut', True), ('processReaped', False), ('pid', 0)]:
            changed = copy.deepcopy(observations)
            process = json.loads(changed['slow-cancel.process.json']); process[key] = value
            changed['slow-cancel.process.json'] = json.dumps(process).encode()
            receipt = json.loads(changed['receipt.json'])
            next(item for item in receipt['results'] if item['mode'] == 'slow-cancel')['process'] = process
            changed['receipt.json'] = json.dumps(receipt).encode()
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.verify_crash_payload(changed, source, files, source['original-evidence.zip'])

    def test_ips_requires_two_objects_exact_pid_executable_and_owned_lifetime(self):
        process, report = self.ips()
        encode = lambda value: (json.dumps({'bug_type': '309'}) + '\n' + json.dumps(value)).encode()
        self.assertEqual(diagnostic.validate_crash(encode(report), process, 'a' * 64)['pid'], 77)
        for key, value in [('pid', 78), ('procName', 'other'), ('procPath', '/tmp/other/nbq0000000123'),
                ('procLaunch', '2026-11-05T01:00:00+00:00'), ('captureTime', '2026-11-06T01:01:00+00:00')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.validate_crash(encode(dict(report, **{key: value})), process, 'a' * 64)
        for raw in [json.dumps(report).encode(), encode(report) + b'\n{}']:
            with self.assertRaises(ValueError): diagnostic.validate_crash(raw, process, 'a' * 64)
        for bug_type in (None, '288', 309, '', '309-other'):
            metadata = {} if bug_type is None else {'bug_type': bug_type}
            raw = (json.dumps(metadata) + '\n' + json.dumps(report)).encode()
            with self.subTest(bug_type=bug_type), self.assertRaises(ValueError):
                diagnostic.validate_crash(raw, process, 'a' * 64)

    def test_ips_must_contain_the_actual_sigtrap_and_usable_faulting_stack(self):
        process, report = self.ips()
        for key, value in [('exception', dict(signal='SIGABRT', type='EXC_CRASH')), ('faultingThread', True),
                ('faultingThread', 1), ('threads', [dict(frames=[])]), ('usedImages', []), ('usedImages', [None]),
                ('usedImages', [{}])]:
            raw = (json.dumps({'bug_type': '309'}) + '\n' + json.dumps(dict(report, **{key: value}))).encode()
            with self.subTest(key=key), self.assertRaises(ValueError): diagnostic.validate_crash(raw, process, 'a' * 64)
        image = report['usedImages'][0]
        for key, value in [('base', 0), ('base', True), ('size', 0), ('size', 123), ('size', 2 ** 64),
                ('uuid', None), ('uuid', 'unknown'), ('uuid', '00000000-0000-0000-0000-000000000000')]:
            changed = dict(report, usedImages=[dict(image, **{key: value})])
            raw = (json.dumps({'bug_type': '309'}) + '\n' + json.dumps(changed)).encode()
            with self.subTest(image=key, value=value), self.assertRaises(ValueError):
                diagnostic.validate_crash(raw, process, 'a' * 64)
        changed = dict(report, usedImages=[dict(image, name='', path='')])
        with self.assertRaises(ValueError):
            diagnostic.validate_crash((json.dumps({'bug_type': '309'}) + '\n' + json.dumps(changed)).encode(), process, 'a' * 64)
        raw = (json.dumps({'bug_type': '309'}) + '\n' + json.dumps(report)).encode()
        self.assertEqual(diagnostic.validate_crash(raw, process, 'a' * 64)['resolvedFaultingFrames'][0]['runtimeAddress'], 4219)

    def test_owned_report_acquisition_retains_raw_candidates_but_never_qualifies_wrong_pid(self):
        process, report = self.ips()
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory); reports = home / 'Library/Logs/DiagnosticReports'; reports.mkdir(parents=True)
            evidence = home / 'evidence'; evidence.mkdir()
            for name, pid in [('a', 78), ('b', 77)]:
                target = reports / (report['procName'] + '-' + name + '.ips')
                target.write_text(json.dumps({'bug_type': '309'}) + '\n' + json.dumps(dict(report, pid=pid)))
                timestamp = diagnostic.instant(process['finishedWall']).timestamp()
                os.utime(target, (timestamp, timestamp))
            with patch.object(diagnostic.Path, 'home', return_value=home):
                captured = diagnostic.collect_crash_reports(evidence, process, 'a' * 64, seconds=0)
            self.assertEqual(captured['identity']['pid'], 77)
            acquisition = json.loads((evidence / '77-crash-acquisition.json').read_text())
            self.assertEqual(acquisition['qualifiedCount'], 1)
            self.assertEqual(sum(item['qualified'] for item in acquisition['candidates']), 1)
            self.assertEqual(len(list(evidence.glob('*.ips'))), 1)

    def test_crash_mode_normal_alternative_requires_both_original_native_contracts(self):
        for mode in diagnostic.CRASH_MODES:
            diagnostic.validate_slow_normal(self.slow_report(mode), mode, 123)

    def test_not_reached_slow_observations_cannot_replace_missing_crash_evidence(self):
        for status in ('not-reached-warmup-unqualified', 'not-reached-getter-entry'):
            report = self.slow_report('slow-cancel'); report['slowObservation']['status'] = status
            diagnostic.validate_observation(report, 'slow-cancel', 123)
            with self.subTest(status=status), self.assertRaises(ValueError):
                diagnostic.validate_slow_normal(report, 'slow-cancel', 123)

    def test_normal_slow_timing_cancellation_and_last_child_timeout_are_independent_guards(self):
        for mode in diagnostic.CRASH_MODES:
            for key, value in [('enteredAt', 1), ('returnedAt', 0), ('getterEntered', False), ('enabledUndoCount', True)]:
                report = self.slow_report(mode); report['slowObservation'][key] = value
                with self.subTest(mode=mode, key=key), self.assertRaises(ValueError): diagnostic.validate_slow_normal(report, mode, 123)
            report = self.slow_report(mode); report['slowObservation']['query']['finishedUptime'] = 3
            with self.assertRaises(ValueError): diagnostic.validate_slow_normal(report, mode, 123)
        report = self.slow_report('slow-cancel'); report['slowObservation']['cancelRequestedAt'] = 0
        with self.assertRaises(ValueError): diagnostic.validate_slow_normal(report, 'slow-cancel', 123)
        for status in (0, None, False):
            report = self.slow_report('slow-timeout'); report['slowObservation']['query']['nodes'][0]['statuses']['AXChildren'] = status
            with self.subTest(status=status), self.assertRaises(ValueError): diagnostic.validate_slow_normal(report, 'slow-timeout', 123)

    def test_crash_mode_has_its_own_source_gated_mac_leaf_and_preserves_all_five_default_cases(self):
        workflow = yaml.safe_load((diagnostic.ROOT / '.github/workflows/diagnostic-acceptance.yml').read_text())
        leaf = workflow['jobs']['native-button-query-crash']
        self.assertEqual((leaf['needs'], leaf['runs-on'], leaf['timeout-minutes']), ('source', 'macrunner', 5))
        self.assertEqual(leaf['if'], "inputs.candidate_kind == 'native-button-query-crash'")
        command = next(step['run'] for step in leaf['steps'] if 'run' in step)
        self.assertIn('--capture-crashes', command)
        original = workflow['jobs']['native-button-query']
        self.assertNotIn('--capture-crashes', next(step['run'] for step in original['steps'] if 'run' in step))
        self.assertEqual(diagnostic.MODES, ('enabled', 'disabled', 'duplicate', 'slow-cancel', 'slow-timeout'))

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
