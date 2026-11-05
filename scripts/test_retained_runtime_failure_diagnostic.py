import copy
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zlib

import yaml

import retained_runtime_failure_diagnostic as diagnostic
from runtime_pointer_source import assess_sample, block, png_dimensions, prepare, validate_measurement


class RetainedRuntimeFailureTests(unittest.TestCase):
    def setUp(self):
        self.selected = {
            'diagnostic': {'jobID': 1, 'artifactID': 2, 'artifactSHA256': 'a' * 64},
            'bpy': {'jobID': 3, 'artifactID': 4, 'artifactSHA256': 'b' * 64},
        }
        self.env = dict(KIND='native-retained-failures', SCALE='1', VERIFIED_PR='123', CANDIDATE_RUN='456',
            CANDIDATE_ARTIFACT='789', CANDIDATE_SOURCE='a' * 40, CANDIDATE_DIGEST='c' * 64,
            PACKAGING_PRODUCER_SOURCE='b' * 40, PACKAGING_PROVENANCE_ARTIFACT_ID='321',
            PACKAGING_PROVENANCE_ARTIFACT_SHA256='d' * 64, DMG_DIGEST='e' * 64,
            RUNTIME_FAILURE_BINDING=json.dumps(self.selected))

    def test_failure_binding_rejects_ambiguous_and_noninteger_identities(self):
        self.assertEqual(diagnostic.failure_selectors(json.dumps(self.selected)), self.selected)
        for key, value in [('jobID', True), ('artifactID', '2'), ('artifactID', 0), ('artifactSHA256', 'A' * 64)]:
            item = copy.deepcopy(self.selected)
            item['diagnostic'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                diagnostic.failure_selectors(json.dumps(item))
        for raw in ('{}', '[]', '{"diagnostic":{},"diagnostic":{},"bpy":{}}', json.dumps(self.selected)[:-1] + ',"extra":0}'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                diagnostic.failure_selectors(raw)

    def test_failure_binding_cannot_alias_another_producer(self):
        for key in ('jobID', 'artifactID'):
            item = copy.deepcopy(self.selected)
            item['bpy'][key] = item['diagnostic'][key]
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'distinct producers'):
                diagnostic.failure_selectors(json.dumps(item))

    def test_mode_requires_full_runtime_source_proof_and_no_unrelated_inputs(self):
        self.assertEqual(diagnostic.validate_inputs(self.env), self.selected)
        for key in ('VERIFIED_PR', 'DMG_DIGEST', 'PACKAGING_PRODUCER_SOURCE', 'CANDIDATE_DIGEST',
                    'PACKAGING_PROVENANCE_ARTIFACT_ID', 'RUNTIME_FAILURE_BINDING'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(self.env, **{key: ''}))
        for key in diagnostic.EXTRA_FIELDS:
            with self.subTest(extra=key), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(self.env, **{key: 'foreign'}))
        for scale in ('1.25', '1.5', 'all'):
            with self.subTest(scale=scale), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(self.env, SCALE=scale))

    def failure(self):
        now = datetime.now(timezone.utc)
        earlier, later = (now - timedelta(minutes=1)).isoformat(), (now + timedelta(days=1)).isoformat()
        run = dict(id=456, head_sha='b' * 40, status='completed', conclusion='failure', run_attempt=1,
                   actor={'login': 'iret77'})
        job = dict(id=1, run_id=456, head_sha='b' * 40, run_attempt=1, labels=['macrunner'], status='completed',
                   conclusion='failure', name='diagnostic-acceptance', started_at=earlier, completed_at=now.isoformat(),
                   steps=[dict(name=diagnostic.FAILURES['diagnostic'][2], conclusion='failure')])
        artifact = dict(id=2, name='diagnostic-runtime-acceptance', digest='sha256:' + 'a' * 64,
                        expired=False, size_in_bytes=100, workflow_run={'id': 456, 'head_sha': 'b' * 40},
                        created_at=earlier, updated_at=earlier, expires_at=later)
        return run, {'total_count': 1, 'jobs': [job]}, artifact

    def test_actual_failure_requires_exact_attempt_step_runner_and_artifact(self):
        run, jobs, artifact = self.failure()
        self.assertEqual(diagnostic.verify_failure(run, jobs, artifact, 'diagnostic', self.selected['diagnostic'], 'a' * 40)['id'], 1)
        changes = [('run', 'run_attempt', 2), ('run', 'conclusion', 'success'),
                   ('job', 'labels', ['macos-latest']), ('job', 'id', 9), ('job', 'conclusion', 'success'),
                   ('job', 'steps', [{'name': 'different failure', 'conclusion': 'failure'}]),
                   ('artifact', 'digest', 'sha256:' + 'f' * 64), ('artifact', 'expired', True),
                   ('artifact', 'workflow_run', {'id': 999, 'head_sha': 'b' * 40})]
        for target, key, value in changes:
            run, jobs, artifact = self.failure()
            {'run': run, 'job': jobs['jobs'][0], 'artifact': artifact}[target][key] = value
            with self.subTest(target=target, key=key), self.assertRaises(ValueError):
                diagnostic.verify_failure(run, jobs, artifact, 'diagnostic', self.selected['diagnostic'], 'a' * 40)

    def test_failure_artifact_must_fall_inside_the_actual_failed_job(self):
        run, jobs, artifact = self.failure()
        artifact['created_at'] = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
        with self.assertRaisesRegex(ValueError, 'this attempt'):
            diagnostic.verify_failure(run, jobs, artifact, 'diagnostic', self.selected['diagnostic'], 'a' * 40)
        jobs['total_count'] = 2
        with self.assertRaisesRegex(ValueError, 'inventory'):
            diagnostic.verify_failure(run, jobs, artifact, 'diagnostic', self.selected['diagnostic'], 'a' * 40)

    def test_failure_archive_reads_all_bytes_and_rejects_escape_symlink_and_duplicates(self):
        for invalid in ('../outside', '/outside', 'x/../outside', 'x\\outside', 'duplicate', 'symlink'):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory() as root:
                path = Path(root) / 'failure.zip'
                with zipfile.ZipFile(path, 'w') as archive:
                    if invalid == 'duplicate':
                        archive.writestr('x', b'first')
                        archive.writestr('x', b'second')
                    elif invalid == 'symlink':
                        info = zipfile.ZipInfo('link')
                        info.external_attr = (stat.S_IFLNK | 0o777) << 16
                        archive.writestr(info, b'target')
                    else:
                        archive.writestr(invalid, b'bad')
                with self.assertRaisesRegex(ValueError, 'Unsafe'):
                    diagnostic.read_failure_archive(path)
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'valid.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('nested/proof.json', b'{"actual":true}')
            self.assertEqual(diagnostic.read_failure_archive(path), {'nested/proof.json': b'{"actual":true}'})

    def geometry(self):
        rows = []
        for name, frame in [('spatial.undo', [543.5, 132.5, 50, 28]),
                            ('spatial.transform.apply', [272.5, 338.5, 133, 32])]:
            point = [frame[0] + frame[2] / 2, frame[1] + frame[3] / 2]
            rows.append(dict(kind='pointer', id=name, frame=frame, point=point, windowPoint=[point[0], 640 - point[1]],
                             localMonitorDownObserved=True, localMonitorUpObserved=True))
        return {'spatial-scene-100.json': json.dumps(dict(failure='native scene revision committed after undo', interactions=rows)),
                'runtime-failure-observation.json': json.dumps(dict(sourceSHA='a' * 40))}

    def test_geometry_requires_the_actual_failed_undo_and_both_delivered_pointer_events(self):
        files = self.geometry()
        result = diagnostic.failure_geometry(files, 'a' * 40)
        self.assertFalse(result['originalSemanticCallbackObserved'])
        for change in ('duplicate', 'monitor', 'position', 'nonfinite', 'foreign'):
            files = self.geometry()
            value = json.loads(files['spatial-scene-100.json'])
            if change == 'duplicate': value['interactions'].append(value['interactions'][0])
            if change == 'monitor': value['interactions'][0]['localMonitorUpObserved'] = False
            if change == 'position': value['interactions'][0]['windowPoint'][1] += 1
            if change == 'nonfinite': value['interactions'][0]['frame'][0] = float('nan')
            if change == 'foreign': files['runtime-failure-observation.json'] = json.dumps(dict(sourceSHA='c' * 40))
            files['spatial-scene-100.json'] = json.dumps(value)
            with self.subTest(change=change), self.assertRaises(ValueError):
                diagnostic.failure_geometry(files, 'a' * 40)

    def test_new_role_does_not_admit_product_changes_or_broaden_existing_roles(self):
        from retained_packaging import consumer_harness
        from verify_diagnostic_candidate import SIGNED_WORKSPACE_HARNESS_PATHS, SIGNED_BPY_HARNESS_PATHS
        self.assertNotIn('scripts/app_termination_acceptance.py', SIGNED_WORKSPACE_HARNESS_PATHS)
        self.assertNotIn('scripts/runtime_pointer_diagnostic.swift', SIGNED_BPY_HARNESS_PATHS)
        with patch('retained_packaging.consumer_source', return_value='b' * 40), \
                patch('retained_packaging.git', side_effect=[b'c' * 40, b'']), \
                patch.dict(os.environ, GITHUB_SHA='c' * 40), \
                patch('retained_packaging.comparison', return_value={'files': [{'filename': 'Sources/NexGenVideo/App.swift'}]}):
            with self.assertRaisesRegex(ValueError, 'Unsupported consumer changes'):
                consumer_harness({}, 'a' * 40, diagnostic.HARNESS_PATHS)

    def test_source_dependency_selection_rejects_ambiguity_instead_of_guessing(self):
        text = 'enum Theme { static var x: Int { 1 } }'
        self.assertEqual(block(text, 'enum Theme {'), text)
        for value in ('nothing', text + text, 'enum Theme { incomplete'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                block(value, 'enum Theme {')

    def test_old_modes_reject_new_selectors_before_any_candidate_or_native_work(self):
        workflow = yaml.safe_load(Path('.github/workflows/diagnostic-acceptance.yml').read_text())
        first = next(step for step in workflow['jobs']['source']['steps'] if step.get('name') == 'Require exact public transport continuation inputs')
        code = first['run'].split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        inputs = workflow.get('on', workflow.get(True))['workflow_dispatch']['inputs']
        for mode in inputs['candidate_kind']['options']:
            if mode == 'native-retained-failures': continue
            env = dict(self.env, KIND=mode, PACKAGING_PRODUCER_SOURCE='', PACKAGING_PROVENANCE_ARTIFACT_ID='',
                       PACKAGING_PROVENANCE_ARTIFACT_SHA256='')
            with self.subTest(mode=mode), patch.dict(os.environ, env, clear=True), \
                    self.assertRaisesRegex(ValueError, 'cannot be ignored'):
                exec(compile(code, '<workflow-input-guard>', 'exec'), {})

    def pointer_sample(self, kind='undo', route='queued', up_observed=True):
        frame = [272.5, 338.5, 133, 32] if kind == 'apply' else [543.5, 132.5, 50, 28]
        screen = [frame[0], 640 - frame[1] - frame[3], frame[2], frame[3]]
        point = [frame[0] + frame[2] / 2, 640 - frame[1] - frame[3] / 2]
        title = 'Apply transform' if kind == 'apply' else 'Undo'
        posted_up = 0.0401 if route == 'queued' else 0.081
        observed_down, observed_up = 0.05, 0.09
        view = dict(probeTopFrame=frame, originalScreenFrame=screen,
            ax={'traversalComplete': True, 'visitedCount': 3, 'budget': 2048,
                'targets': [dict(role='AXButton', label=title, title='', help='', enabled=True, frame=screen)]},
            windowPoint=point, hitClass='NSButton' if kind == 'native' else 'NSHostingView', probeHidden=False,
            windowIsKey=True, windowIsVisible=True, contentBounds=[0, 0, 960, 640], rootFrame=[0, 0, 960, 640],
            rootPoint=point, hitTestSuperviewPoint=point, rootIsFlipped=False, superviewIsFlipped=False,
            measuredStyle=dict(paintedFont=None, paintedForeground=None, internalStyleHoverState=None,
                               physicalCursorInsideOriginalTarget=route == 'hid'),
            configuredSwiftUIStyle={} if kind == 'native' else dict(fontPointSize=13, fontWeight='medium'),
            callbackCount=0, callbackUptimes=[])
        after = copy.deepcopy(view)
        after.update(callbackCount=1, callbackUptimes=[0.1])
        events = [dict(type=1, observedUptime=observed_down)]
        if up_observed: events.append(dict(type=2, observedUptime=observed_up))
        return dict(control=kind, route=route, originalFrame=frame, before=view, after=after, events=events,
            configuredVariant='native-system' if kind == 'native' else 'secondary',
            configuredSize='native-system' if kind == 'native' else 'regular' if kind == 'apply' else 'small',
            callbackObserved=True, localMonitorPairComplete=up_observed,
            observedDownUpIntervalSeconds=observed_up - observed_down if up_observed else None,
            delivery=dict(downPostedUptime=0.04, upPostedUptime=posted_up,
                          enqueueDurationSeconds=0.0002 if route == 'queued' else None,
                          syntheticTimestampDeltaSeconds={'queued': 0.001, 'separated': 0.03, 'hid': None}[route],
                          cursorMovePosted=route == 'hid'),
            screenshot=kind + '-' + route + '.png', screenshotPixels=[960, 640])

    def test_framework_style_geometry_and_accessibility_classification_are_independent(self):
        value = self.pointer_sample('apply')
        self.assertTrue(assess_sample(value)['geometryComparable'])
        value['configuredSize'] = 'small'
        with self.assertRaisesRegex(ValueError, 'control style'): assess_sample(value)
        value = self.pointer_sample()
        value['after']['probeTopFrame'] = [500, 120, 50, 28]
        self.assertEqual(assess_sample(value)['routeComparison'], 'INCONCLUSIVE_GEOMETRY')
        for change in ('missing', 'duplicate', 'incomplete', 'disabled', 'empty', 'nonfinite'):
            value = self.pointer_sample()
            ax = value['before']['ax']
            if change == 'missing': ax['targets'] = []
            if change == 'duplicate': ax['targets'] *= 2
            if change == 'incomplete': ax['traversalComplete'] = False
            if change == 'disabled': ax['targets'][0]['enabled'] = False
            if change == 'empty': ax['targets'][0]['frame'] = [0, 0, 0, 0]
            if change == 'nonfinite': ax['targets'][0]['frame'] = [float('nan'), 0, 50, 28]
            with self.subTest(change=change), self.assertRaises(ValueError): assess_sample(value)
        value = self.pointer_sample()
        value['before']['probeHidden'] = True
        self.assertFalse(assess_sample(value)['geometryComparable'])

    def test_hit_test_coordinates_preserve_nonzero_origin_and_root_flipping(self):
        for flipped in (False, True):
            value = self.pointer_sample()
            for phase in ('before', 'after'):
                view = value[phase]
                view.update(rootFrame=[17, 23, 960, 640], rootIsFlipped=flipped)
                point = view['rootPoint']
                view['hitTestSuperviewPoint'] = [17 + point[0], 23 + (640 - point[1] if flipped else point[1])]
            self.assertTrue(assess_sample(value)['geometryComparable'])
            value['after']['hitTestSuperviewPoint'] = value['after']['rootPoint']
            with self.subTest(flipped=flipped), self.assertRaisesRegex(ValueError, 'superview coordinates'):
                assess_sample(value)

    def test_native_callback_positive_control_survives_tracking_monitor_bypass(self):
        for route in ('queued', 'separated', 'hid'):
            value = self.pointer_sample('native', route, up_observed=False)
            result = assess_sample(value)
            self.assertTrue(result['callbackObserved'])
            self.assertFalse(result['localMonitorPairComplete'])
            value['observedDownUpIntervalSeconds'] = 0.03
            with self.assertRaisesRegex(ValueError, 'Unseen Up'): assess_sample(value)
            value['observedDownUpIntervalSeconds'] = None
            value['after'].update(callbackCount=0, callbackUptimes=[])
            value['callbackObserved'] = False
            with self.assertRaisesRegex(ValueError, 'positive control'): assess_sample(value)

    def test_posted_observed_and_configured_style_facts_cannot_be_conflated(self):
        for change in ('timing', 'style', 'native', 'timestamp', 'early-callback'):
            value = self.pointer_sample('native', 'separated')
            if change == 'timing': value['delivery']['upPostedUptime'] = 0.06
            if change == 'style': value['before']['measuredStyle']['paintedFont'] = 13
            if change == 'native': value['before']['configuredSwiftUIStyle'] = {'fontPointSize': 13}
            if change == 'timestamp': value['delivery']['syntheticTimestampDeltaSeconds'] = 0.001
            if change == 'early-callback': value['after']['callbackUptimes'] = [0.01]
            with self.subTest(change=change), self.assertRaises(ValueError): assess_sample(value)

    def png(self):
        def chunk(tag, data):
            return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 960, 640, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress((b'\0' + b'\0' * 960 * 3) * 640)) + chunk(b'IEND', b''))

    def test_framework_requires_nine_real_pngs_and_exact_production_dependency_bytes(self):
        raw = self.png()
        self.assertEqual(png_dimensions(raw), [960, 640])
        for invalid in (b'', raw[:-1], raw[:-12], raw[:50] + bytes([raw[50] ^ 1]) + raw[51:], raw + b'extra'):
            with self.subTest(size=len(invalid)), self.assertRaises(ValueError): png_dimensions(invalid)
        with tempfile.TemporaryDirectory() as root:
            output = Path(root)
            prepare(output / 'pointer-support.swift')
            samples = [self.pointer_sample(kind, route) for kind in ('undo', 'apply', 'native') for route in ('queued', 'separated', 'hid')]
            for sample in samples: (output / sample['screenshot']).write_bytes(raw)
            original = diagnostic.failure_geometry(self.geometry(), 'a' * 40)
            (output / 'pointer-input.json').write_text(json.dumps(original))
            measurement = dict(schema='nexgenvideo/runtime-pointer-measurement/1', classification='framework-pointer-reproduction-only',
                               appAcceptance=False, originalUndoCause='INCONCLUSIVE', samples=samples, input=original)
            (output / 'pointer-measurement.json').write_text(json.dumps(measurement))
            self.assertEqual(len(validate_measurement(output)['samples']), 9)
            (output / 'undo-queued.png').rename(output / 'hidden.png')
            with self.assertRaisesRegex(ValueError, 'missing screenshot'): validate_measurement(output)
            (output / 'hidden.png').rename(output / 'undo-queued.png')
            (output / 'undo-queued.png').write_bytes(raw[:-1])
            with self.assertRaises(ValueError): validate_measurement(output)
            (output / 'undo-queued.png').write_bytes(raw)
            (output / 'pointer-support.swift').write_text('foreign style')
            with self.assertRaisesRegex(ValueError, 'dependency bytes'): validate_measurement(output)


if __name__ == '__main__':
    unittest.main()
