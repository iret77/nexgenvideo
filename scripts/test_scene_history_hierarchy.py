import copy
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zlib

import scene_history_hierarchy as diagnostic


def selected_environment():
    return {'KIND': diagnostic.MODE, 'PRODUCER_RUN': '100', 'PRODUCER_SHA': 'a' * 40,
        'DIAGNOSTIC_ID': '200', 'DIAGNOSTIC_DIGEST': 'b' * 64, 'FAILURE_ID': '300',
        'FAILURE_DIGEST': 'c' * 64, 'DMG_DIGEST': 'd' * 64, 'VERIFIED_PR': '400', 'SCALE': '1'}


def original_metadata():
    source = 'a' * 40
    run = {'id': 100, 'head_sha': source, 'repository': {'full_name': 'iret77/nexgenvideo'},
        'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch', 'actor': {'login': 'iret77'},
        'run_attempt': 1, 'status': 'completed', 'conclusion': 'failure'}
    job = {'id': 500, 'run_id': 100, 'head_sha': source, 'run_attempt': 1, 'labels': ['macrunner'],
        'name': 'bpy-runtime / runtime', 'status': 'completed', 'conclusion': 'failure',
        'started_at': '2026-11-05T00:00:00Z', 'completed_at': '2026-11-05T00:10:00Z',
        'steps': [{'name': 'Run real bpy acceptance without ambient Blender or Python', 'conclusion': 'failure'}]}
    artifact = {'id': 300, 'name': 'managed-bpy-runtime-evidence-' + source, 'expired': False,
        'workflow_run': {'id': 100, 'head_sha': source}, 'digest': 'sha256:' + 'c' * 64, 'size_in_bytes': 1024,
        'created_at': '2026-11-05T00:09:00Z', 'updated_at': '2026-11-05T00:09:30Z', 'expires_at': '2099-01-01T00:00:00Z'}
    return run, {'total_count': 1, 'jobs': [job]}, artifact


def screenshot():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 320, 240, 8, 2, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress((b'\0' + b'\x80\x80\x80' * 320) * 240)) + chunk(b'IEND', b''))


def canonical_files(files, completed=False):
    scene = '11111111-1111-1111-1111-111111111111'
    identifiers = ['00000000-0000-0000-0000-' + str(i).zfill(12) for i in range(9 if completed else 3)]
    prefix = 'spatial-history-project.ngv/pipeline/production_design/spatial/'
    matrix = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    cube = {'id': 'cube-id', 'name': 'Cube', 'kind': 'MESH', 'matrixWorld': matrix}
    changed = copy.deepcopy(cube); changed['matrixWorld'][3] = 0.5
    states = [[], [cube], [changed], [cube], [changed], [cube], [changed], [cube],
        [cube, {'id': 'sphere-id', 'name': 'Sphere', 'kind': 'MESH', 'matrixWorld': matrix}]]
    targets = {3: 1, 4: 2, 5: 3, 6: 4, 7: 5}
    manifests = []
    for index, identifier in enumerate(identifiers):
        state_index = 1 if index in (3, 5, 7) else 2 if index in (4, 6) else index
        scene_bytes = ('scene-state-' + str(state_index)).encode()
        snapshot = json.dumps({'objects': states[index]}, sort_keys=True).encode()
        receipt = {'sceneSHA256': hashlib.sha256(scene_bytes).hexdigest(),
            'snapshotSHA256': hashlib.sha256(snapshot).hexdigest(), 'resourceClosureSHA256': hashlib.sha256(b'[]').hexdigest()}
        manifest = {'schema': 'spatial-scene-manifest/v1', 'sceneID': scene, 'revision': identifier,
            'resources': [], 'receipt': receipt, **receipt}
        if index:
            manifest['parentRevision'] = identifiers[index - 1]
        if index in targets:
            manifest['restoredFromRevision'] = identifiers[targets[index]]
        path = prefix + 'scenes/' + scene + '/revisions/' + identifier + '/'
        raw = json.dumps(manifest, sort_keys=True).encode()
        files.update({path + 'manifest.v1.json': raw, path + 'scene.blend': scene_bytes, path + 'snapshot.v1.json': snapshot})
        manifests.append(manifest)
    last_path = prefix + 'scenes/' + scene + '/revisions/' + identifiers[-1] + '/manifest.v1.json'
    files[prefix + 'index.v1.json'] = json.dumps({'schema': 'spatial-scene-index/v1', 'scenes': [
        {'id': scene, 'revision': identifiers[-1], 'manifestSHA256': hashlib.sha256(files[last_path]).hexdigest()}]}).encode()
    return scene, identifiers, manifests


def refresh_project(files, outcome):
    prefix = 'spatial-history-project.ngv/'
    entries = [{'path': name[len(prefix):], 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
        for name, raw in sorted(files.items()) if name.startswith(prefix)]
    files['spatial-history-project-files.json'] = json.dumps({'schema': 'nexgenvideo/spatial-history-project/1',
        'project': 'spatial-history-project.ngv', 'outcome': outcome, 'files': entries}).encode()


def failure_files():
    error = diagnostic.FAILURE_PREFIX + ' native diagnostic'
    records = [{'path': '.ngv-dirty', 'bytes': 0, 'sha256': hashlib.sha256(b'').hexdigest()}]
    files = {'spatial-history-project.ngv/.ngv-dirty': b''}
    for index in range(30):
        raw = ('project-' + str(index)).encode()
        relative = 'pipeline/evidence-' + str(index) + '.json'
        files['spatial-history-project.ngv/' + relative] = raw
        records.append({'path': relative, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()})
    values = {
        'process.json': {'pid': 900, 'sourceSHA': 'a' * 40, 'mode': 'runtime'},
        'runtime-failure-observation.json': {'hostPID': 900, 'sourceSHA': 'a' * 40, 'error': error},
        'spatial-history-failure.json': {'error': error, 'busyAfterCleanup': False,
            'historyTrace': {'overflow': False, 'events': [{'status': 'rejectedHistory'}, {'status': 'rejectedBusy'}]}},
        'spatial-history-admission.json': {'schema': 'native-visual-source-progress/v1', 'failure': error,
            'stage': 'actual history callback failure', 'screenshots': ['retry.png', 'failure.png'],
            'interactions': [{'kind': 'button-accessibility', 'id': 'spatial.undo', 'item': 'Undo',
                'elements': [], 'visited': 1, 'truncated': False, 'window': 931},
                {'kind': 'verified-state', 'label': 'actual history callback failure', 'evidence': {
                    'admissionCallbacks': 0, 'admitted': None, 'reloadAttemptUptime': None,
                    'admissionFailure': None, 'busyBeforeReload': False, 'busyAfterReload': False}}]},
        'spatial-history-project-files.json': {'schema': 'nexgenvideo/spatial-history-project/1',
            'project': 'spatial-history-project.ngv', 'outcome': 'failed', 'files': records},
    }
    files.update({name: json.dumps(value).encode() for name, value in values.items()})
    files.update({'retry.png': screenshot(), 'failure.png': screenshot()})
    canonical_files(files)
    refresh_project(files, 'failed')
    return files


def deadline_failure_files():
    files = failure_files()
    progress = json.loads(files['spatial-history-admission.json'])
    button = progress['interactions'][0]
    nodes = [{'pid': 900, 'role': role, 'parent': parent} for role, parent in
             [('AXGroup', None), ('AXSplitGroup', 0), ('AXGroup', 1), ('AXStaticText', 2), ('AXButton', 2)]]
    nodes[-1].update(enabled=True, label='Evaluate')
    button.update(visited=5, truncated=True, publicAX={
        'visited': 5, 'truncated': True, 'failure': 'query-deadline', 'plane': 'public-AX',
        'scope': 'whole-content-root', 'rootInventoryComplete': True, 'readOnMainThread': False,
        'pid': 900, 'window': 931, 'windowCandidates': 1, 'contentCandidates': 1,
        'expectedWindowFrame': [32, 32, 960, 672], 'contentRoots': [{'pid': 900, 'role': 'AXGroup'}],
        'CGWindows': [{'number': 931, 'pid': 900, 'onscreen': True, 'frame': [32, 32, 960, 672]}],
        'startedUptime': 10.21, 'finishedUptime': 11.21, 'nodes': nodes,
        'reader': {'imageSHA256': 'e' * 64, 'AXTrusted': True, 'ownerPID': 900, 'ownerStart': 123,
                   'readerPID': 901, 'readerStart': 124, 'startupStarted': 10, 'readyAt': 10.1,
                   'sentAt': 10.2, 'deadline': 11.2, 'receivedAt': 11.22, 'stderr': ''}},
        readerLifecycle={'pid': 901, 'exitStatus': 0, 'forced': False, 'processReaped': True,
                         'protocolClean': True, 'stdoutClosed': True, 'stderrClosed': True,
                         'stderr': '', 'finishedAt': 11.23})
    files['spatial-history-admission.json'] = json.dumps(progress).encode()
    return files


def successful_files():
    files = {name: value for name, value in failure_files().items()
        if not name.endswith(('index.v1.json', 'manifest.v1.json', 'snapshot.v1.json', 'scene.blend'))
        and name not in ('spatial-history-failure.json', 'runtime-failure-observation.json')}
    scene, identifiers, _ = canonical_files(files, completed=True)
    refresh_project(files, 'completed')
    callbacks, trace = [], [{'status': 'rejectedHistory'}, {'status': 'rejectedBusy'}]
    for action, source, prior in [('undo', identifiers[2], identifiers[1]), ('redo', identifiers[3], identifiers[2])]:
        admitted = {'id': action + '-click', 'action': action, 'status': 'admitted', 'origin': 'userInterface',
            'busyAtRequest': False, 'sourceRevision': source, 'priorRevision': prior, 'observedUptime': 2}
        committed = dict(admitted, status='committed')
        callback = {'action': action, 'admissionCallbacks': 1, 'admissionFailure': None, 'busyBeforeReload': True,
            'busyAfterReload': True, 'errorAfterRejection': None, 'expectedSourceRevision': source, 'expectedPriorRevision': prior,
            'observerCreatedUptime': 1, 'reloadAttemptUptime': 3, 'admitted': admitted, 'completed': committed,
            'concurrentRejection': {'status': 'rejectedBusy', 'busyAtRequest': True}}
        callbacks.append({'kind': 'verified-state', 'label': 'actual history callback reload order', 'evidence': callback})
        trace.extend([admitted, {'status': 'rejectedBusy'}, committed])
    trace.extend([{'status': 'admitted'}, {'status': 'failed'}])
    for _ in range(3):
        trace.extend([{'status': 'admitted'}, {'status': 'committed'}])
    trace.append({'status': 'rejectedBusy'})
    complete = {'sceneID': scene, 'priorRevision': identifiers[1], 'editedRevision': identifiers[2],
        'undoRevision': identifiers[3], 'redoRevision': identifiers[4], 'emptyRejected': True,
        'busyReloadRejectedWithRetryNotice': True, 'invalidatedRedoRejectedWithoutRetryInstruction': True,
        'cancelledBeforeWork': True, 'awaitedCompletionVerified': True, 'historyTrace': {'overflow': False, 'events': trace}}
    events = [{'kind': 'pointer', 'id': name, 'window': 931, 'localMonitorDownObserved': True,
        'localMonitorUpObserved': True} for name in ['spatial.undo', 'spatial.redo']]
    events += callbacks + [{'kind': 'verified-state', 'label': 'history admission regression complete', 'evidence': complete}]
    history = {'interactions': events, 'screenshots': ['retry.png', 'failure.png', 'restored.png'], 'canonicalProject': {
        'project': 'spatial-history-project.ngv', 'manifest': 'spatial-history-project-files.json',
        'sha256': hashlib.sha256(files['spatial-history-project-files.json']).hexdigest()}}
    files['restored.png'] = screenshot()
    files['result.json'] = json.dumps({'schema': 'nexgenvideo/scene-history-runtime/1', 'scope': 'scene-history',
        'sourceSHA': 'a' * 40, 'operationShutdown': True, 'appDelegateShutdown': True, 'historyAdmission': history}).encode()
    files['process-result.json'] = json.dumps({'pid': 900, 'sourceSHA': 'a' * 40, 'mode': 'runtime', 'returncode': 0}).encode()
    files['runtime.log'] = b'SELFTEST_BPY_HISTORY_OK\n'
    return files


def window_evidence():
    def node(identity, role, label, position, size, enabled=None):
        return {'identity': identity, 'pid': 900, 'pidStatus': 0, 'unsupportedChildrenCount': 0,
            'attributes': {'AXRole': role, 'AXDescription': label, 'AXPosition': position,
                'AXSize': size, 'AXEnabled': enabled},
            'statuses': {'AXRole': 0, 'AXPosition': 0, 'AXSize': 0, 'AXEnabled': 0}}
    tree = {'windowIdentity': 1, 'visited': 3, 'truncated': False, 'localSwiftObjectTypesObserved': False,
        'nodes': [node(1, 'AXWindow', '', [20, 30], [960, 662]),
            node(2, 'AXStaticText', 'History admission control', [30, 60], [180, 20]),
            node(3, 'AXButton', 'Undo', [800, 60], [50, 28], True)]}
    cg = [{'kCGWindowOwnerPID': 900, 'kCGWindowIsOnscreen': True, 'kCGWindowNumber': 931,
        'kCGWindowBounds': {'X': 20, 'Y': 30, 'Width': 960, 'Height': 662}}]
    return tree, cg


class SceneHistoryHierarchyTests(unittest.TestCase):
    def test_supervisor_exit_one_uses_actual_assertion_contract_without_masking_other_errors(self):
        from bpy_runtime_acceptance import require as native_require
        def expected(*args):
            self.assertEqual(args, ('app', 'evidence', 'runtime', 'a' * 40, 180))
            native_require(False, 'bpy runtime exited with status 1')
        self.assertEqual(diagnostic.supervise_scope('app', 'evidence', 'a' * 40, expected),
            'bpy runtime exited with status 1')
        self.assertIsNone(diagnostic.supervise_scope('app', 'evidence', 'a' * 40, lambda *_args: None))
        for error in [AssertionError('owned bpy process timed out'), AssertionError('cleanup failed'),
                      ValueError('bpy runtime exited with status 1'), InterruptedError('interrupted')]:
            def other(*_args):
                raise error
            with self.subTest(error=type(error).__name__), self.assertRaises(type(error)):
                diagnostic.supervise_scope('app', 'evidence', 'a' * 40, other)

    def test_original_raw_capture_preserves_escape_bytes_and_rejects_cli_failure(self):
        raw = b'\x1b[32moriginal complete native log\x1b[0m\n'
        calls = []
        def capture(command, **kwargs):
            calls.append((command, kwargs))
            kwargs['stdout'].write(raw)
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'actual.log'
            with patch.object(diagnostic.subprocess, 'run', side_effect=capture):
                result = diagnostic.download_job_log(500, target)
            self.assertEqual(target.read_bytes(), raw)
            self.assertEqual(result, hashlib.sha256(raw).hexdigest())
            self.assertEqual(calls[0][0], ['gh', 'api',
                'repos/iret77/nexgenvideo/actions/jobs/500/logs', '--allow-escape-sequences'])
            self.assertTrue(calls[0][1]['check'])
            with patch.object(diagnostic.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['gh'])):
                with self.assertRaises(subprocess.CalledProcessError):
                    diagnostic.download_job_log(500, Path(folder) / 'failed.log')
            with patch.object(diagnostic.subprocess, 'run', return_value=None):
                with self.assertRaises(ValueError):
                    diagnostic.download_job_log(500, Path(folder) / 'empty.log')

    def test_exact_selectors_reject_partial_cross_mode_and_unconsumed_inputs(self):
        env = selected_environment()
        selected = diagnostic.validate_inputs(env)
        self.assertEqual(selected['runID'], 100)
        self.assertEqual(selected['verifiedPRRunID'], 400)
        for key in env:
            changed = dict(env); changed.pop(key)
            with self.subTest(missing=key), self.assertRaises(ValueError):
                diagnostic.validate_inputs(changed)
        for key, value in [('KIND', 'signed-bpy'), ('SCALE', '1.5'), ('FAILURE_ID', '0'),
                           ('PRODUCT_SHA', 'a' * 40), ('PRODUCTS_ID', '5'), ('RUNTIME_FAILURE_BINDING', '{}'),
                           ('JOURNEY_JOB', '5'), ('PACKAGING_PRODUCER_SOURCE', 'a' * 40)]:
            changed = dict(env, **{key: value})
            with self.subTest(unconsumed=key), self.assertRaises(ValueError):
                diagnostic.validate_inputs(changed)

    def test_original_failure_rejects_foreign_attempt_source_job_artifact_and_expiry(self):
        selected = diagnostic.validate_inputs(selected_environment())
        run, jobs, artifact = original_metadata()
        self.assertEqual(diagnostic.verify_failure(run, jobs, artifact, selected)['id'], 500)
        for key, value in [('head_sha', 'f' * 40), ('run_attempt', 2), ('conclusion', 'success')]:
            changed = dict(run, **{key: value})
            with self.subTest(run=key), self.assertRaises(ValueError):
                diagnostic.verify_failure(changed, jobs, artifact, selected)
        for mutate in [lambda j: j['jobs'][0].update(labels=['macos-27']),
                       lambda j: j.update(total_count=2),
                       lambda j: j['jobs'][0]['steps'][0].update(name='Some other failure')]:
            changed = copy.deepcopy(jobs); mutate(changed)
            with self.assertRaises(ValueError):
                diagnostic.verify_failure(run, changed, artifact, selected)
        for key, value in [('id', 301), ('expired', True), ('digest', 'sha256:' + 'f' * 64),
                           ('expires_at', '2000-01-01T00:00:00Z'), ('created_at', '2026-11-04T00:00:00Z')]:
            changed = dict(artifact, **{key: value})
            with self.subTest(artifact=key), self.assertRaises(ValueError):
                diagnostic.verify_failure(run, jobs, changed, selected)

    def test_ci_only_role_rejects_app_changes_renames_deletions_and_other_roles(self):
        diagnostic.validate_changed_paths(['A\tscripts/scene_history_hierarchy.py'])
        for line in ['M\tSources/NexGenVideo/App/ProductionVisualSourcesDriver.swift',
                     'M\tscripts/bpy_runtime_acceptance.py', 'M\tPackage.swift',
                     'R100\tscripts/scene_history_hierarchy.py\tscripts/other.py',
                     'D\tscripts/scene_history_hierarchy.py']:
            with self.subTest(line=line), self.assertRaises(ValueError):
                diagnostic.validate_changed_paths([line])

    def test_expected_locator_failure_is_measurement_only_and_requires_no_real_admission(self):
        files = failure_files()
        outcome = diagnostic.expected_locator_failure(files, 'a' * 40, 900)
        self.assertEqual(outcome, {'expectedLocatorFailure': True, 'windowNumber': 931, 'appScopePassed': False})
        for key, value in [('admissionCallbacks', 1), ('reloadAttemptUptime', 10), ('busyBeforeReload', True)]:
            changed = dict(files); progress = json.loads(changed['spatial-history-admission.json'])
            progress['interactions'][1]['evidence'][key] = value
            changed['spatial-history-admission.json'] = json.dumps(progress).encode()
            with self.subTest(callback=key), self.assertRaises(ValueError):
                diagnostic.expected_locator_failure(changed, 'a' * 40, 900)
        changed = dict(files); progress = json.loads(changed['spatial-history-admission.json'])
        progress['interactions'].append({'kind': 'pointer', 'id': 'spatial.undo'})
        changed['spatial-history-admission.json'] = json.dumps(progress).encode()
        with self.assertRaises(ValueError):
            diagnostic.expected_locator_failure(changed, 'a' * 40, 900)

    def test_owned_partial_public_ax_deadline_is_measurement_only_with_exact_app_image(self):
        files = deadline_failure_files()
        outcome = diagnostic.expected_locator_failure(files, 'a' * 40, 900, expected_image_sha256='e' * 64)
        self.assertEqual(outcome, {'expectedLocatorFailure': True, 'windowNumber': 931,
                                  'appScopePassed': False, 'locatorBoundary': 'query-deadline', 'coverageComplete': False})
        for image in (None, 'f' * 64):
            with self.subTest(image=image), self.assertRaises(ValueError):
                diagnostic.expected_locator_failure(files, 'a' * 40, 900, expected_image_sha256=image)

    def test_partial_deadline_rejects_foreign_incomplete_unreaped_or_different_locator_evidence(self):
        mutations = [
            lambda b: b.update(visited=1, truncated=False),
            lambda b: (b.update(visited=1, truncated=False), b['publicAX'].update(visited=1, truncated=False)),
            lambda b: b['publicAX'].update(failure='some-other-failure'),
            lambda b: b['publicAX'].update(rootInventoryComplete=False),
            lambda b: b['publicAX'].update(windowCandidates=2),
            lambda b: b['publicAX'].update(contentCandidates=0),
            lambda b: b['publicAX'].update(pid=999),
            lambda b: b['publicAX']['reader'].update(ownerPID=999),
            lambda b: b['publicAX']['reader'].update(AXTrusted=False),
            lambda b: b['publicAX']['reader'].update(sentAt=float('nan')),
            lambda b: b['publicAX']['reader'].update(deadline=12),
            lambda b: b['readerLifecycle'].update(forced=True),
            lambda b: b['readerLifecycle'].update(processReaped=False),
            lambda b: b['readerLifecycle'].update(exitStatus=1),
            lambda b: b['readerLifecycle'].update(protocolClean=False),
            lambda b: b['readerLifecycle'].update(stdoutClosed=False),
            lambda b: b['readerLifecycle'].update(stderr='unexpected output'),
            lambda b: b['publicAX']['nodes'][4].update(pid=999),
            lambda b: b['publicAX']['nodes'][4].update(parent=4),
            lambda b: b['publicAX']['nodes'][0].update(parent=0),
            lambda b: b['publicAX']['nodes'][1].update(parent=None),
            lambda b: b['publicAX']['nodes'][4].update(label='Undo'),
            lambda b: b['publicAX']['CGWindows'][0].update(number=932),
        ]
        for index, mutate in enumerate(mutations):
            files = deadline_failure_files()
            progress = json.loads(files['spatial-history-admission.json'])
            mutate(progress['interactions'][0])
            files['spatial-history-admission.json'] = json.dumps(progress).encode()
            with self.subTest(index=index), self.assertRaises(ValueError):
                diagnostic.expected_locator_failure(files, 'a' * 40, 900, expected_image_sha256='e' * 64)

    def test_failure_identity_unknown_error_hidden_project_mutation_and_png_truncation_fail(self):
        files = failure_files()
        for source, pid in [('f' * 40, 900), ('a' * 40, 901)]:
            with self.assertRaises(ValueError):
                diagnostic.expected_locator_failure(files, source, pid)
        changed = dict(files); failure = json.loads(changed['spatial-history-admission.json'])
        failure['failure'] = 'A different crash'
        changed['spatial-history-admission.json'] = json.dumps(failure).encode()
        with self.assertRaises(ValueError):
            diagnostic.expected_locator_failure(changed, 'a' * 40, 900)
        for name, value in [('spatial-history-project.ngv/.ngv-dirty', b'changed'), ('failure.png', screenshot()[:-8])]:
            changed = dict(files); changed[name] = value
            with self.subTest(file=name), self.assertRaises(ValueError):
                diagnostic.expected_locator_failure(changed, 'a' * 40, 900)

    def test_public_ax_cg_mapping_requires_real_source_bound_unique_window(self):
        tree, cg = window_evidence()
        self.assertEqual(diagnostic.associate_window(tree, cg, 900)['windowNumber'], 931)
        for mutation in [lambda t: t.update(truncated=True),
                         lambda t: t['nodes'][2]['attributes'].update(AXEnabled=False),
                         lambda t: t['nodes'][1].update(pid=901),
                         lambda t: t['nodes'][2].update(unsupportedChildrenCount=1),
                         lambda t: t['nodes'][0]['statuses'].update(AXPosition=-25204)]:
            changed = copy.deepcopy(tree); mutation(changed)
            with self.assertRaises(ValueError):
                diagnostic.associate_window(changed, cg, 900)
        duplicate = copy.deepcopy(cg); duplicate.append(dict(cg[0], kCGWindowNumber=932))
        with self.assertRaises(ValueError):
            diagnostic.associate_window(tree, duplicate, 900)
        changed = copy.deepcopy(cg); changed[0]['kCGWindowBounds']['X'] += diagnostic.TOLERANCE + 0.1
        with self.assertRaises(ValueError):
            diagnostic.associate_window(tree, changed, 900)

    def test_full_history_success_cannot_be_claimed_from_marker_or_foreign_exit(self):
        files = {'result.json': json.dumps({'scope': 'scene-history', 'sourceSHA': 'a' * 40}).encode(),
            'process-result.json': json.dumps({'pid': 900, 'sourceSHA': 'a' * 40, 'mode': 'runtime', 'returncode': 0}).encode(),
            'runtime.log': b'SELFTEST_BPY_HISTORY_OK\n'}
        with self.assertRaises(ValueError):
            diagnostic.scoped_success(files, 'a' * 40, 900)
        with self.assertRaises(ValueError):
            diagnostic.scoped_success(files, 'a' * 40, 901)

    def test_complete_scene_history_requires_actual_pointers_lifecycle_and_exact_restored_bytes(self):
        files = successful_files()
        self.assertTrue(diagnostic.scoped_success(files, 'a' * 40, 900)['appScopePassed'])
        changed = dict(files); result = json.loads(changed['result.json'])
        result['historyAdmission']['interactions'][0]['localMonitorUpObserved'] = False
        changed['result.json'] = json.dumps(result).encode()
        with self.assertRaises(ValueError):
            diagnostic.scoped_success(changed, 'a' * 40, 900)
        changed = dict(files); result = json.loads(changed['result.json'])
        result['historyAdmission']['interactions'][-1]['evidence']['historyTrace']['events'].pop()
        changed['result.json'] = json.dumps(result).encode()
        with self.assertRaises(ValueError):
            diagnostic.scoped_success(changed, 'a' * 40, 900)
        changed = dict(files)
        scene = next(name for name in changed if name.endswith('000000000003/scene.blend'))
        changed[scene] = b'wrong-restoration'
        refresh_project(changed, 'completed')
        with self.assertRaises(ValueError):
            diagnostic.scoped_success(changed, 'a' * 40, 900)

    def test_screenshots_require_full_crc_and_complete_pixel_payload(self):
        raw = screenshot()
        self.assertEqual(diagnostic.png_size(raw), [320, 240])
        for value in [raw[:8], raw[:-1], raw[:-13] + b'changed-data!', raw + b'extra']:
            with self.subTest(length=len(value)), self.assertRaises(ValueError):
                diagnostic.png_size(value)


if __name__ == '__main__':
    unittest.main()
