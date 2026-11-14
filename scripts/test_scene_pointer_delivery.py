import copy
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import struct
import tempfile
import unittest
import zipfile
import re
import shutil
import yaml
from unittest.mock import Mock, patch
from contextlib import contextmanager, ExitStack

import scene_pointer_delivery as diagnostic


def environment():
    return {'KIND': 'native-scene-pointer-delivery', 'PRODUCER_RUN': '100', 'PRODUCER_SHA': 'a' * 40,
        'DIAGNOSTIC_ID': '200', 'DIAGNOSTIC_DIGEST': 'b' * 64, 'FAILURE_ID': '300',
        'FAILURE_DIGEST': 'c' * 64, 'DMG_DIGEST': 'd' * 64, 'VERIFIED_PR': '400', 'SCALE': '1'}


def geometry_receipt(command):
    return {'schema': 'nexgenvideo/observer-geometry-selfcheck/1', 'sourceSHA256': command[3],
        'executableSHA256': command[4], 'nonce': command[5], 'pid': 123, 'passed': True,
        'windowConsumer': True, 'buttonConsumer': True, 'screenConsumers': True, 'invalidRejected': True,
        'oldCGFloatArrayCastsToDouble': False, 'position': [-12.5, 25.25], 'size': [960, 640],
        'screen': {'screenFrame': [-12.5, 25.25, 50, 28], 'screenPoint': [12.5, 39.25]}}


def original():
    error = 'Native visual sources: native scene revision committed after undo; unchanged revision'
    state = {'canonical': {'sceneID': 'scene', 'revision': 'transform', 'manifestSHA256': 'e' * 64},
        'currentProbe': 'transform', 'canUndo': True, 'canRedo': False, 'ready': True,
        'sceneError': None, 'historyIntent': None, 'historyTrace': '{"events":[]}'}
    records = [{'label': 'native scene revision observation',
        'evidence': {**copy.deepcopy(state), 'action': action, 'waitCompleted': action != 'undo'}}
        for action in ('create location', 'add cube', 'apply transform', 'undo')]
    records.insert(3, {'kind': 'pointer', 'id': 'spatial.undo', 'frame': [543.5, 132.5, 50, 28],
        'point': [568.5, 146.5], 'windowPoint': [568.5, 493.5], 'window': 58,
        'localMonitorDownObserved': True, 'localMonitorUpObserved': True})
    values = {'process.json': {'pid': 900, 'sourceSHA': 'a' * 40, 'mode': 'runtime'},
        'process-failure.json': {'pid': 900, 'error': 'bpy runtime exited with status 1'},
        'spatial-scene-100.json': {'failure': error, 'interactions': records},
        'runtime-failure-observation.json': {'sourceSHA': 'a' * 40, 'hostPID': 900, 'error': error}}
    return {**{name: json.dumps(value).encode() for name, value in values.items()},
        'runtime-stderr.log': ('SELFTEST_BPY_FAIL ' + error + '\n').encode()}


class PointerBoundaryTests(unittest.TestCase):
    def test_source_and_native_workflows_resolve_identical_observer_selectors(self):
        root = Path(__file__).resolve().parents[1]
        workflow = yaml.safe_load((root / '.github/workflows/diagnostic-acceptance.yml').read_text())
        reusable = yaml.safe_load((root / '.github/workflows/scene-pointer-delivery-diagnostic.yml').read_text())
        inputs = {'candidate_kind': 'native-scene-pointer-delivery', 'run_id': '100', 'source_sha': 'a' * 40,
            'artifact_id': '200', 'artifact_sha256': 'b' * 64, 'failure_artifact_id': '300',
            'failure_artifact_sha256': 'c' * 64, 'expected_dmg_sha256': 'd' * 64,
            'verified_pr_run_id': '400', 'interface_scale': '1', 'product_source_sha': 'e' * 40,
            'products_artifact_id': '500', 'products_artifact_sha256': 'f' * 64}
        def resolve(values, selected):
            result = {}
            for key, value in values.items():
                match = re.fullmatch(r'\$\{\{ inputs\.([a-z0-9_]+) \}\}', value)
                result[key] = selected.get(match[1], '') if match else value
            return result
        binding = next(step for step in workflow['jobs']['source']['steps']
            if step.get('run', '').startswith('python3 scripts/scene_pointer_delivery.py bind'))
        source_env = resolve({**workflow['env'], **binding['env']}, inputs)
        forwarded = resolve(workflow['jobs']['native-scene-pointer-delivery']['with'], inputs)
        native_env = resolve(reusable['jobs']['measurement']['env'], forwarded)
        self.assertEqual(diagnostic.validate_inputs(source_env), diagnostic.validate_inputs(native_env))
        self.assertEqual(diagnostic.validate_inputs(native_env)['observerArtifactID'], 500)

    def test_observer_archive_rejects_symlink_or_directory_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            for mode in (0o100755, 0o120777, 0o40755):
                path = Path(directory) / str(mode)
                with zipfile.ZipFile(path, 'w') as archive:
                    item = zipfile.ZipInfo('scene-pointer-delivery/observer-executable')
                    item.create_system = 3; item.external_attr = mode << 16
                    archive.writestr(item, b'bytes')
                if mode == 0o100755:
                    self.assertEqual(diagnostic.observer_archive(path)[item.filename], b'bytes')
                else:
                    with self.subTest(mode=mode), self.assertRaises(ValueError):
                        diagnostic.observer_archive(path)

    def test_observer_selectors_are_all_or_none(self):
        reuse = {'PRODUCT_SHA': 'e' * 40, 'PRODUCTS_ID': '500', 'PRODUCTS_DIGEST': 'f' * 64}
        self.assertNotIn('observerArtifactID', diagnostic.validate_inputs(environment()))
        self.assertEqual(diagnostic.validate_inputs({**environment(), **reuse})['observerArtifactID'], 500)
        for key in reuse:
            for value in ('', 'invalid', True):
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    diagnostic.validate_inputs({**environment(), **reuse, key: value})

    def test_observer_requires_thin_arm64_macos_executable(self):
        header = [0xFEEDFACF, 0x100000C, 0, 2, 1, 24, 0, 0]
        command = [0x32, 24, 1, 0x1B0200, 0x1B0200, 0]
        raw = struct.pack('<8I6I', *header, *command)
        self.assertEqual(diagnostic.observer_macho(raw)['minimumOS'], 0x1B0200)
        for offset, value in ((0, 0xCAFEBABE), (4, 0x1000007), (12, 6), (16, 2),
                              (20, 25), (36, 16), (40, 2), (52, 1)):
            changed = bytearray(raw); struct.pack_into('<I', changed, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                diagnostic.observer_macho(changed)
        with self.assertRaises(ValueError):
            diagnostic.observer_macho(raw[:20])

    def test_observer_compile_recipe_tracks_flags_and_rejects_ambiguity(self):
        source = "subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-o', str(observer_binary)], check=True, timeout=90)"
        self.assertNotEqual(diagnostic.compile_recipe(source), diagnostic.compile_recipe(source.replace("'6'", "'5'")))
        for changed in ('pass', source + '\n' + source):
            with self.subTest(source=changed), self.assertRaises(ValueError):
                diagnostic.compile_recipe(changed)

    def test_exact_input_selection(self):
        selected = diagnostic.validate_inputs(environment())
        self.assertEqual(selected['failureArtifactID'], 300)
        self.assertEqual(selected['sourceSHA'], 'a' * 40)

    def test_selectors_cannot_be_missing_or_malformed(self):
        for name in environment():
            for value in ('', 'unexpected', True):
                with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                    diagnostic.validate_inputs({**environment(), name: value})

    def test_unrelated_input_is_not_ignored(self):
        for name in ('PRODUCT_SHA', 'PRODUCTS_ID', 'PRODUCTS_DIGEST', 'RUNTIME_FAILURE_BINDING',
                     'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'PACKAGING_PRODUCER_SOURCE',
                     'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                diagnostic.validate_inputs({**environment(), name: 'unexpected'})

    def test_only_diagnostic_files_may_change(self):
        diagnostic.validate_changed_paths(['A\tscripts/scene_pointer_observer.swift'])
        for line in ('M\tSources/NexGenVideo/App/AppDelegate.swift',
                     'D\tscripts/scene_pointer_observer.swift',
                     'R100\tscripts/scene_pointer_observer.swift\tother', 'M\tPackage.swift'):
            with self.subTest(line=line), self.assertRaises(ValueError):
                diagnostic.validate_changed_paths([line])

    def test_manifest_extension_preserves_product_and_every_old_ci_path(self):
        previous = {'appSourceSHA': 'a' * 40, 'criteria': {'count': 100}, 'ciPaths': ['scripts/old.py']}
        current = {**previous, 'ciPaths': sorted(set(previous['ciPaths']) | diagnostic.NEW_PATHS)}
        diagnostic.validate_manifest_delta(previous, current)
        for changed in ({**current, 'appSourceSHA': 'b' * 40}, {**current, 'criteria': {'count': 99}},
                        {**current, 'ciPaths': sorted(diagnostic.NEW_PATHS)},
                        {**current, 'ciPaths': sorted(current['ciPaths'] + ['scripts/unreviewed.py'])}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                diagnostic.validate_manifest_delta(previous, changed)

    def test_full_runtime_fixture_positive_and_negative_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); home = root / 'home-probe'
            env = diagnostic.prepare_fixtures(root, home)
            denied = json.loads(env['NGV_BPY_DENIED_PATHS'])
            self.assertEqual(len(denied), 4)
            self.assertTrue(all(Path(path).read_bytes() for path in denied))
            self.assertEqual(denied[-1], str(home))
            approved = Path(env['NGV_BPY_APPROVED_INPUT_DIR'])
            self.assertEqual(json.loads((approved / 'fixture.json').read_text()), {'approved': True})
            self.assertTrue((approved / 'symlink.json').is_symlink())
            self.assertEqual((approved / 'symlink.json').resolve(), Path(denied[0]))
            self.assertEqual((approved / 'hardlink-source').stat().st_ino, (approved / 'hardlink.json').stat().st_ino)
            self.assertEqual((approved / 'hardlink.json').stat().st_nlink, 2)
            self.assertEqual(env['NGV_TEST_SECRET'], 'must-not-cross-xpc')

    def test_original_unobserved_undo_boundary(self):
        result = diagnostic.original_failure(original(), 'a' * 40)
        self.assertEqual(result['window'], 58)
        self.assertIs(result['originalUndoAdmissionObserved'], False)

    def test_actual_admission_or_progress_disqualifies_old_failure(self):
        changes = {'waitCompleted': True, 'ready': False, 'canUndo': False, 'canRedo': True,
            'sceneError': 'error', 'historyIntent': {'id': 'actual'},
            'historyTrace': '{"events":[{"status":"admitted"}]}', 'currentProbe': 'another',
            'canonical': {'revision': 'advanced'}}
        for key, value in changes.items():
            files = original()
            progress = json.loads(files['spatial-scene-100.json'])
            progress['interactions'][-1]['evidence'][key] = value
            files['spatial-scene-100.json'] = json.dumps(progress).encode()
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.original_failure(files, 'a' * 40)

    def test_missing_up_wrong_coordinates_or_duplicate_pointer_rejected(self):
        for change in ('up', 'point', 'duplicate'):
            files = original()
            progress = json.loads(files['spatial-scene-100.json'])
            pointer = progress['interactions'][3]
            if change == 'up':
                pointer['localMonitorUpObserved'] = False
            elif change == 'point':
                pointer['point'][0] += 1
            else:
                progress['interactions'].append(copy.deepcopy(pointer))
            files['spatial-scene-100.json'] = json.dumps(progress).encode()
            with self.subTest(change=change), self.assertRaises(ValueError):
                diagnostic.original_failure(files, 'a' * 40)

    def test_success_marker_cannot_be_classified_as_original_failure(self):
        for key, value in [('result.json', b'{}'), ('runtime-stderr.log', b'SELFTEST_BPY_OK')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.original_failure({**original(), key: value}, 'a' * 40)


class PointerOutcomeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.native, self.observed = root / 'native', root / 'observed'
        self.native.mkdir(); self.observed.mkdir()
        self.binary = root / 'NexGenVideo'; self.binary.write_bytes(b'unchanged candidate')
        self.identity = {'pid': 900, 'startAbsoluteTime': 100, 'executable': str(self.binary.resolve())}
        self.put(self.native, 'process.json', {'pid': 900, 'sourceSHA': 'a' * 40, 'mode': 'runtime'})
        self.put(self.native, 'process-failure.json', {'pid': 900, 'error': 'bpy runtime exited with status 1'})
        self.put(self.observed, 'attachment.json', {'processIdentity': self.identity, 'sourceSHA': 'a' * 40,
            'executableSHA256': diagnostic.sha(self.binary), 'observerPID': 901})
        self.put(self.observed, 'completion.json', {'processIdentity': self.identity,
            'runtimeAccepted': False, 'interventionPosted': True, 'finishedUptime': 20})
        canonical = self.observed / 'canonical-before'; canonical.mkdir()
        self.baseline = {}
        for prefix, key, revision, position in [('', 'manifest', 'edited', 0.5), ('prior-', 'priorManifest', 'prior', 0)]:
            snapshot = {'objects': [{'id': 'cube', 'matrixWorld': [1, 0, 0, position, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]}]}
            raw = json.dumps(snapshot).encode(); scene = str(position).encode()
            value = {'schema': 'spatial-scene-manifest/v1', 'sceneID': 'scene', 'revision': revision,
                'parentRevision': 'prior' if not prefix else 'created',
                'snapshotSHA256': hashlib.sha256(raw).hexdigest(), 'sceneSHA256': hashlib.sha256(scene).hexdigest()}
            encoded = json.dumps(value).encode()
            (canonical / (prefix + 'manifest.json')).write_bytes(encoded)
            (canonical / (prefix + 'snapshot.json')).write_bytes(raw)
            (canonical / (prefix + 'scene.blend')).write_bytes(scene)
            self.baseline[key] = value
            self.baseline[key + 'SHA256'] = hashlib.sha256(encoded).hexdigest()
            self.baseline['priorSnapshot' if prefix else 'snapshot'] = snapshot
        self.baseline['head'] = {'id': 'scene', 'revision': 'edited', 'manifestSHA256': self.baseline['manifestSHA256']}
        index = json.dumps({'schema': 'spatial-scene-index/v1', 'scenes': [self.baseline['head']]}).encode()
        (canonical / 'index.json').write_bytes(index)
        self.baseline['indexSHA256'] = hashlib.sha256(index).hexdigest()
        button = {'identity': 2, 'pid': 900, 'pidStatus': 0, 'unsupportedChildrenCount': 0,
            'attributes': {'AXRole': 'AXButton', 'AXEnabled': True, 'AXTitle': 'Undo',
                'AXPosition': [543.5, 132.5], 'AXSize': [50, 28]},
            'statuses': dict.fromkeys(['AXRole', 'AXEnabled', 'AXPosition', 'AXSize'], 0)}
        window = {'identity': 1, 'pid': 900, 'pidStatus': 0, 'unsupportedChildrenCount': 0,
            'attributes': {'AXRole': 'AXWindow'}}
        self.target = {'pid': 900, 'window': 58, 'CGWindow': {'kCGWindowOwnerPID': 900, 'kCGWindowNumber': 58,
            'kCGWindowIsOnscreen': True, 'kCGWindowBounds': {'X': 0, 'Y': 0, 'Width': 960, 'Height': 640}},
            'screenFrame': [543.5, 132.5, 50, 28], 'screenPoint': [568.5, 146.5], 'button': button,
            'systemHitStatus': 0, 'systemHitPath': [{'pid': 900, 'identity': 2}],
            'AXTree': {'windowIdentity': 1, 'truncated': False, 'visited': 2, 'nodes': [window, button]}}
        self.put(self.observed, 'before.json', {'canonical': self.baseline, 'AX': self.target,
            'progress': json.loads(original()['spatial-scene-100.json'])})
        self.put(self.observed, 'INTERVENTION-STARTED.json', {'processIdentity': self.identity,
            'oneShot': True, 'diagnosticOnly': True, 'stableSeconds': 5.1, 'canonical': self.baseline,
            'AX': self.target})
        self.put(self.observed, 'posting.json', {'diagnosticOnly': True, 'eventDeliveryAcknowledged': False,
            'point': [568.5, 146.5], 'movePostedAt': 10, 'downPostedAt': 11, 'upPostedAt': 12,
            'afterMoveAX': self.target})
        (self.observed / 'before.png').write_bytes(b'retained image')

    def put(self, root, name, value):
        (root / name).write_text(json.dumps(value))

    def evaluate(self):
        return diagnostic.observation_result(self.observed, self.native, 'a' * 40, self.binary, 901)

    def add_restoration(self):
        manifest = {**self.baseline['priorManifest'], 'revision': 'restored', 'parentRevision': 'edited',
            'restoredFromRevision': 'prior'}
        encoded = json.dumps(manifest).encode(); digest = hashlib.sha256(encoded).hexdigest()
        head = {'sceneID': 'scene', 'revision': 'restored', 'manifestSHA256': digest}
        directory = self.observed / 'canonical-after'; directory.mkdir(exist_ok=True)
        (directory / 'manifest.json').write_bytes(encoded)
        for name in ('snapshot.json', 'scene.blend'):
            (directory / name).write_bytes((self.observed / 'canonical-before' / ('prior-' + name)).read_bytes())
        result = {'diagnosticOnly': True, 'observedUptime': 13, 'restoration': {'manifest': manifest,
            'head': head, 'manifestSHA256': digest, 'snapshotSHA256': manifest['snapshotSHA256'],
            'sceneSHA256': manifest['sceneSHA256'],
            'snapshot': self.baseline['priorSnapshot']},
            'progress': {'interactions': [{'evidence': {'action': 'undo', 'waitCompleted': True, 'canonical': head}}]}}
        self.put(self.observed, 'first-progress-after.json', result)
        (self.observed / 'after.png').write_bytes(b'retained image')
        return result

    def test_posts_without_restoration_prove_no_delivery_or_runtime_acceptance(self):
        result = self.evaluate()
        for key in ('singleUndoRestorationObserved', 'runtimeAccepted', 'overallAcceptancePassed', 'eventDeliveryAcknowledged'):
            self.assertIs(result[key], False)

    def test_exact_restoration_remains_diagnostic_only(self):
        self.add_restoration()
        result = self.evaluate()
        self.assertIs(result['singleUndoRestorationObserved'], True)
        self.assertIs(result['diagnosticOnly'], True)
        self.assertIs(result['runtimeAccepted'], False)
        self.assertIs(result['overallAcceptancePassed'], False)

    def test_wrong_parent_double_undo_and_changed_snapshot_rejected(self):
        for key, value in [('parentRevision', 'prior'), ('restoredFromRevision', 'older'),
                           ('snapshotSHA256', 'e' * 64), ('sceneSHA256', 'f' * 64)]:
            result = self.add_restoration()
            result['restoration']['manifest'][key] = value
            self.put(self.observed, 'first-progress-after.json', result)
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.evaluate()

    def test_foreign_pid_and_changed_app_bytes_rejected(self):
        self.put(self.native, 'process.json', {'pid': 902, 'sourceSHA': 'a' * 40, 'mode': 'runtime'})
        with self.assertRaises(ValueError):
            self.evaluate()
        self.put(self.native, 'process.json', {'pid': 900, 'sourceSHA': 'a' * 40, 'mode': 'runtime'})
        self.binary.write_bytes(b'changed candidate')
        with self.assertRaises(ValueError):
            self.evaluate()

    def test_out_of_order_or_unreleased_pointer_rejected(self):
        for up in (9, 11, float('nan'), 30):
            value = json.loads((self.observed / 'posting.json').read_text()); value['upPostedAt'] = up
            self.put(self.observed, 'posting.json', value)
            with self.subTest(up=up), self.assertRaises(ValueError):
                self.evaluate()

    def test_post_move_target_drift_rejected(self):
        for key, value in [('pid', 902), ('window', 59), ('screenPoint', [569.5, 146.5])]:
            posting = json.loads((self.observed / 'posting.json').read_text())
            posting['afterMoveAX'] = copy.deepcopy(self.target)
            posting['afterMoveAX'][key] = value
            self.put(self.observed, 'posting.json', posting)
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.evaluate()

    def test_mutated_canonical_original_rejected(self):
        self.add_restoration()
        (self.observed / 'canonical-after/scene.blend').write_bytes(b'another scene')
        with self.assertRaises(ValueError):
            self.evaluate()

    def test_foreign_system_hit_rejected(self):
        posting = json.loads((self.observed / 'posting.json').read_text())
        posting['afterMoveAX']['systemHitPath'][0]['pid'] = 999
        self.put(self.observed, 'posting.json', posting)
        with self.assertRaises(ValueError):
            self.evaluate()


class PointerPreflightTests(unittest.TestCase):
    def test_invalid_observer_reuse_never_falls_back_to_compile_or_restore(self):
        import retained_release_runtime
        with patch.object(diagnostic.sys, 'platform', 'darwin'), \
                patch.dict(diagnostic.os.environ, {'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS'}), \
                patch.object(diagnostic, 'bind', return_value=({}, {}, {'selected': {'sourceSHA': 'a' * 40},
                    'producer': {}, 'observerReuse': {'executableSHA256': 'b' * 64, 'deployment': {}}})), \
                patch.object(diagnostic, 'observer_archive', return_value={'scene-pointer-delivery/observer-executable': b'tampered'}), \
                patch.object(diagnostic.subprocess, 'run') as compile_call, \
                patch.object(retained_release_runtime, 'restore') as restore, self.assertRaises(ValueError):
            diagnostic.run(self.root / 'measurement')
        compile_call.assert_not_called(); restore.assert_not_called()

    def test_actual_run_scopes_capture_and_preserves_startup_and_cleanup_failures(self):
        import bpy_runtime_acceptance
        import retained_release_runtime
        for mode in ('app-exit1', 'capture-start', 'capture-cleanup', 'capture-early-death'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
                root = Path(directory); output = root / 'measurement'; order = []
                app = root / 'scene-pointer-workspace-999/NexGenVideo.app/Contents/MacOS/NexGenVideo'
                app.parent.mkdir(parents=True); app.write_bytes(b'app')
                observer = Mock(pid=901, returncode=1); observer.poll.return_value = 1
                @contextmanager
                def capture(path):
                    order.append('capture-enter')
                    if mode == 'capture-start':
                        raise AssertionError('capture-start')
                    try:
                        yield
                    finally:
                        order.append('capture-exit')
                        if mode.startswith('capture-'):
                            raise AssertionError(mode)
                def supervise(binary, native, *_):
                    order.append('app')
                    (native / 'process.json').write_text('{"pid":902}')
                    raise AssertionError('bpy runtime exited with status 1')
                def command(args, **_):
                    if args[0] == 'xcrun':
                        Path(args[-1]).write_bytes(b'observer')
                    elif '--self-check-geometry' in args:
                        order.append('geometry')
                        Path(args[2]).write_text(json.dumps(geometry_receipt(args)))
                stack.enter_context(patch.object(diagnostic.sys, 'platform', 'darwin'))
                stack.enter_context(patch.dict(diagnostic.os.environ,
                    {'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS', 'GITHUB_RUN_ID': '999'}))
                stack.enter_context(patch.object(diagnostic, 'bind', return_value=({}, {},
                    {'selected': {'sourceSHA': 'a' * 40}, 'producer': {}})))
                stack.enter_context(patch.object(diagnostic.subprocess, 'run', side_effect=command))
                stack.enter_context(patch.object(diagnostic.subprocess, 'check_output', return_value='native'))
                stack.enter_context(patch.object(diagnostic.subprocess, 'Popen', return_value=observer))
                stack.enter_context(patch.object(retained_release_runtime, 'restore'))
                stack.enter_context(patch.object(diagnostic, 'product_bytes', return_value={'executableSHA256': 'e' * 64}))
                stack.enter_context(patch.object(diagnostic, 'prepare_fixtures', return_value={}))
                stack.enter_context(patch.object(diagnostic, 'wait_observer_ready'))
                stack.enter_context(patch.object(diagnostic, 'verify_open_capture', return_value={}))
                stack.enter_context(patch.object(bpy_runtime_acceptance, 'capture_open_logs', side_effect=capture))
                stack.enter_context(patch.object(bpy_runtime_acceptance, 'supervise', side_effect=supervise))
                reader = Mock(); reader.identity.return_value = None
                reader_factory = stack.enter_context(patch.object(bpy_runtime_acceptance, 'WorkerReader', return_value=reader))
                expected = 'Observer incomplete' if mode == 'app-exit1' else mode
                with self.assertRaisesRegex((ValueError, AssertionError), expected):
                    diagnostic.run(output)
                self.assertEqual(order, ['geometry', 'capture-enter'] if mode == 'capture-start'
                    else ['geometry', 'capture-enter', 'app', 'capture-exit'])
                self.assertTrue(json.loads((output / 'cleanup.json').read_text())['observerReaped'])
                observer.wait.assert_called_once()
                if mode == 'capture-start':
                    reader_factory.assert_not_called(); reader.identity.assert_not_called()
                else:
                    reader_factory.assert_called_once_with(); reader.identity.assert_called_once_with(902)

    def test_native_geometry_receipt_rejects_foreign_incomplete_or_changed_results(self):
        mutations = [('schema', 'wrong'), ('nonce', 'foreign'), ('sourceSHA256', '0' * 64),
            ('executableSHA256', '0' * 64), ('pid', True), ('pid', 0), ('passed', False),
            ('windowConsumer', False), ('buttonConsumer', False), ('screenConsumers', False),
            ('invalidRejected', False), ('position', [12.5, 25.25]), ('size', [960, 641]),
            ('screen', {'screenFrame': [-12.5, 25.25, 50, 28], 'screenPoint': [12.5, 39]}),
            ('oldCGFloatArrayCastsToDouble', None)]
        for mutation in [None, ('oldCGFloatArrayCastsToDouble', True), *mutations]:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                def command(args, **kwargs):
                    self.assertEqual(kwargs['timeout'], 15)
                    self.assertTrue(kwargs['check'])
                    self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
                    value = geometry_receipt(args)
                    if mutation: value[mutation[0]] = mutation[1]
                    Path(args[2]).write_text(json.dumps(value))
                with patch.object(diagnostic.subprocess, 'run', side_effect=command):
                    if mutation in (None, ('oldCGFloatArrayCastsToDouble', True)):
                        diagnostic.check_observer_geometry(root, root / 'observer',
                            {'observerSourceSHA256': 'a' * 64, 'observerExecutableSHA256': 'b' * 64})
                        self.assertTrue((root / 'observer-geometry-verified.json').is_file())
                    else:
                        with self.assertRaises(ValueError):
                            diagnostic.check_observer_geometry(root, root / 'observer',
                                {'observerSourceSHA256': 'a' * 64, 'observerExecutableSHA256': 'b' * 64})
                        self.assertFalse((root / 'observer-geometry-verified.json').exists())

    def test_geometry_selfcheck_failures_stop_before_restore_or_app_start(self):
        import retained_release_runtime
        for mode in ('nonzero', 'timeout', 'missing', 'malformed'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); calls = []
                def command(args, **_):
                    calls.append(args)
                    if args[0] == 'xcrun': Path(args[-1]).write_bytes(b'observer')
                    elif '--self-check-geometry' in args:
                        if mode == 'nonzero': raise subprocess.CalledProcessError(1, args)
                        if mode == 'timeout': raise subprocess.TimeoutExpired(args, 15)
                        if mode == 'malformed': Path(args[2]).write_text('not-json')
                with patch.object(diagnostic.sys, 'platform', 'darwin'), \
                        patch.dict(diagnostic.os.environ, {'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS'}), \
                        patch.object(diagnostic, 'bind', return_value=({}, {},
                            {'selected': {'sourceSHA': 'a' * 40}, 'producer': {}})), \
                        patch.object(diagnostic.subprocess, 'run', side_effect=command), \
                        patch.object(diagnostic.subprocess, 'check_output', return_value='native'), \
                        patch.object(retained_release_runtime, 'restore') as restore, \
                        patch.object(diagnostic, 'product_bytes') as product, \
                        patch.object(diagnostic.subprocess, 'Popen') as launch, \
                        self.assertRaises((ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired)):
                    diagnostic.run(root / 'measurement')
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[1][1], '--self-check-geometry')
                restore.assert_not_called(); product.assert_not_called(); launch.assert_not_called()

    def test_failed_observer_compile_stops_before_runtime_acquisition_or_app_start(self):
        import retained_release_runtime
        output = self.root / 'measurement'
        binding = {'selected': {'sourceSHA': 'a' * 40}, 'producer': {}}
        with patch.object(diagnostic.sys, 'platform', 'darwin'), \
                patch.dict(diagnostic.os.environ, {'GITHUB_ACTIONS': 'true', 'RUNNER_OS': 'macOS'}), \
                patch.object(diagnostic, 'bind', return_value=({}, {}, binding)), \
                patch.object(diagnostic.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['swiftc'])) as compile_call, \
                patch.object(retained_release_runtime, 'restore') as restore, \
                patch.object(diagnostic, 'product_bytes') as product, \
                patch.object(diagnostic.subprocess, 'Popen') as launch, \
                self.assertRaises(subprocess.CalledProcessError):
            diagnostic.run(output)
        compile_call.assert_called_once()
        self.assertEqual(compile_call.call_args.args[0], ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
            'scripts/scene_pointer_observer.swift', '-o', str(output / 'observer-executable')])
        self.assertTrue(compile_call.call_args.kwargs['check'])
        self.assertEqual(compile_call.call_args.kwargs['timeout'], 90)
        self.assertTrue((output / 'observer-compile.log').is_file())
        restore.assert_not_called(); product.assert_not_called(); launch.assert_not_called()

    def setUp(self):
        directory = tempfile.TemporaryDirectory(); self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.binary = self.root / 'NexGenVideo'; self.binary.write_bytes(b'candidate')
        self.observer = Mock(pid=901); self.observer.poll.return_value = None
        self.ready = {'schema': 'nexgenvideo/scene-pointer-observer-ready/1', 'observerPID': 901,
            'sourceSHA': 'a' * 40, 'executable': str(self.binary.resolve()),
            'executableSHA256': diagnostic.sha(self.binary), 'AXTrusted': True, 'postEventAccess': True}

    def wait(self):
        return diagnostic.wait_observer_ready(self.observer, self.root, 'a' * 40,
            self.binary, diagnostic.sha(self.binary))

    def test_exact_live_ready_receipt_allows_app_start(self):
        (self.root / 'ready.json').write_text(json.dumps(self.ready))
        self.assertEqual(self.wait(), self.ready)

    def test_dead_observer_rejects_even_an_existing_ready_receipt(self):
        (self.root / 'ready.json').write_text(json.dumps(self.ready))
        self.observer.poll.return_value = 1
        with self.assertRaises(ValueError):
            self.wait()

    def test_missing_ready_receipt_stops_at_deadline(self):
        with patch.object(diagnostic.time, 'monotonic', side_effect=[0, 11]), self.assertRaises(ValueError):
            self.wait()

    def test_foreign_identity_bytes_or_missing_privilege_rejected(self):
        for key, value in [('observerPID', 902), ('sourceSHA', 'b' * 40), ('executableSHA256', 'c' * 64),
                           ('AXTrusted', False), ('postEventAccess', False)]:
            (self.root / 'ready.json').write_text(json.dumps({**self.ready, key: value}))
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.wait()


class PointerObserverBindingTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(); self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        repo = Path(__file__).resolve().parents[1]
        self.sources = {name: (repo / name).read_bytes() for name in diagnostic.PATHS}
        self.selected = diagnostic.validate_inputs({**environment(), 'PRODUCT_SHA': 'e' * 40,
            'PRODUCTS_ID': '500', 'PRODUCTS_DIGEST': 'f' * 64})
        self.producer = {'app': {'NGVSourceCommit': 'a' * 40, 'executableSHA256': '1' * 64},
            'mountedAppTreeSHA256': '2' * 64, 'packTreeSHA256': '3' * 64}
        product = {'appTreeSHA256': '2' * 64, 'executableSHA256': '1' * 64, 'packTreeSHA256': '3' * 64}
        self.raw = struct.pack('<8I6I', 0xFEEDFACF, 0x100000C, 0, 2, 1, 24, 0, 0,
            0x32, 24, 1, 0x1B0200, 0x1B0200, 0)
        self.records = {
            'binding/binding.json': {'harnessSourceSHA': 'e' * 40, 'executionRunID': '123',
                'selected': diagnostic.validate_inputs(environment()), 'producer': self.producer,
                'sourceFiles': {name: hashlib.sha256(raw).hexdigest() for name, raw in self.sources.items()}},
            'environment.json': {'observerSourceSHA256': hashlib.sha256(self.sources['scripts/scene_pointer_observer.swift']).hexdigest(),
                'observerExecutableSHA256': hashlib.sha256(self.raw).hexdigest(), 'architecture': 'arm64',
                'sourceSHA': 'a' * 40, 'appBuilds': 0, 'nativeUnitRuns': 0},
            'actual-app-pack-before.json': copy.deepcopy(product),
            'actual-app-pack-after.json': copy.deepcopy(product),
            'observer/ready.json': {'schema': 'nexgenvideo/scene-pointer-observer-ready/1',
                'executableSHA256': '1' * 64, 'sourceSHA': 'a' * 40, 'observerPID': 2009,
                'AXTrusted': True, 'postEventAccess': True, 'executable': '/fixture/NexGenVideo'},
            'observer/attachment.json': {'executableSHA256': '1' * 64, 'sourceSHA': 'a' * 40,
                'observerPID': 2009, 'processIdentity': {'pid': 2010, 'startAbsoluteTime': 42,
                    'executable': '/fixture/NexGenVideo'}},
            'cleanup.json': {'observerPID': 2009, 'appPID': 2010, 'ownedAppGone': True,
                'observerReaped': True, 'beforeAfterAppPackExact': True, 'observerExitCode': 1},
            'native/process.json': {'pid': 2010, 'sourceSHA': 'a' * 40, 'mode': 'runtime'},
            'native/runtime-failure-observation.json': {'hostPID': 2010, 'sourceSHA': 'a' * 40,
                'error': 'invalid open request'},
            'native/process-failure.json': {'pid': 2010, 'error': 'bpy runtime exited with status 1'},
        }
        self.run = {'id': 123, 'head_sha': 'e' * 40, 'workflow_id': 355242770, 'run_attempt': 1,
            'repository': {'full_name': 'iret77/nexgenvideo'}, 'path': '.github/workflows/diagnostic-acceptance.yml',
            'event': 'workflow_dispatch', 'actor': {'login': 'iret77'}, 'head_branch': 'iret77/rc-delivery-base-795',
            'status': 'completed', 'conclusion': 'failure'}
        self.job = {'id': 789, 'name': 'native-scene-pointer-delivery / measurement', 'run_id': 123,
            'head_sha': 'e' * 40, 'run_attempt': 1, 'labels': ['macrunner'], 'status': 'completed',
            'conclusion': 'failure', 'started_at': '2026-01-01T00:00:00Z', 'completed_at': '2026-01-01T00:03:00Z',
            'steps': [{'name': 'Measure one HID intervention during the retained full bpy harness', 'conclusion': 'failure'},
                {'name': 'Retain the complete one-shot observation', 'conclusion': 'success'}]}
        self.artifact_changes = {}

    def bind(self):
        archive = self.root / 'fixture.zip'
        with zipfile.ZipFile(archive, 'w') as zipped:
            contents = {name: json.dumps(value).encode() for name, value in self.records.items()}
            contents.update({'observer-executable': self.raw, 'observer-compile.log': b''})
            for name, raw in contents.items():
                item = zipfile.ZipInfo('scene-pointer-delivery/' + name)
                item.create_system = 3; item.external_attr = 0o100755 << 16
                zipped.writestr(item, raw)
        selected = {**self.selected, 'observerArtifactSHA256': diagnostic.sha(archive)}
        artifact = {'id': 500, 'name': 'native-scene-pointer-delivery-123', 'expired': False,
            'workflow_run': {'id': 123, 'head_sha': 'e' * 40}, 'digest': 'sha256:' + diagnostic.sha(archive),
            'size_in_bytes': archive.stat().st_size, 'created_at': '2026-01-01T00:01:00Z',
            'updated_at': '2026-01-01T00:02:00Z', 'expires_at': '2099-01-01T00:00:00Z', **self.artifact_changes}
        replies = {'actions/artifacts/500': artifact, 'actions/runs/123': self.run,
            'actions/runs/123/attempts/1/jobs?per_page=100': {'total_count': 1, 'jobs': [self.job]},
            'actions/runs/123/artifacts?per_page=100': {'total_count': 1, 'artifacts': [artifact]}}
        with tempfile.TemporaryDirectory(dir=self.root) as destination, \
                patch.object(diagnostic, 'api', side_effect=lambda route: copy.deepcopy(replies[route])), \
                patch.object(diagnostic, 'download', side_effect=lambda _, target, maximum: shutil.copyfile(archive, target)), \
                patch.object(diagnostic, 'download_job_log', return_value='4' * 64), \
                patch.object(diagnostic.subprocess, 'check_output', side_effect=lambda args, **_: self.sources[args[2].split(':', 1)[1]]):
            return diagnostic.bind_observer(Path(destination), selected, self.producer)

    def test_original_failed_run_yields_only_its_executed_observer_product(self):
        proof = self.bind()
        self.assertEqual(proof['executableSHA256'], hashlib.sha256(self.raw).hexdigest())
        self.assertEqual(proof['sourceSHA'], 'e' * 40)
        self.assertEqual(proof['compileEnvironment']['sourceSHA'], 'a' * 40)
        self.assertEqual(proof['run']['conclusion'], 'failure')

    def test_foreign_or_tampered_observer_provenance_is_rejected(self):
        cases = [
            (self.run, 'run_attempt', 2), (self.run, 'head_sha', 'f' * 40),
            (self.run, 'repository', {'full_name': 'other/repo'}), (self.run, 'conclusion', 'success'),
            (self.job, 'labels', ['macos-15']), (self.job, 'run_id', 124),
            (self.artifact_changes, 'digest', 'sha256:' + '0' * 64),
            (self.artifact_changes, 'expired', True),
            (self.records['binding/binding.json'], 'harnessSourceSHA', 'f' * 40),
            (self.records['environment.json'], 'observerExecutableSHA256', '0' * 64),
            (self.records['environment.json'], 'observerSourceSHA256', '0' * 64),
            (self.records['observer/ready.json'], 'AXTrusted', False),
            (self.records['observer/ready.json'], 'executableSHA256', '0' * 64),
            (self.records['observer/attachment.json']['processIdentity'], 'pid', 999),
            (self.records['cleanup.json'], 'ownedAppGone', False),
            (self.records['cleanup.json'], 'observerReaped', False),
            (self.records['native/runtime-failure-observation.json'], 'error', 'different failure'),
            (self.records['actual-app-pack-after.json'], 'packTreeSHA256', '0' * 64),
        ]
        missing = object()
        for target, key, changed in cases:
            prior = target.get(key, missing); target[key] = changed
            try:
                with self.subTest(key=key, changed=changed), self.assertRaises(ValueError):
                    self.bind()
            finally:
                if prior is missing:
                    target.pop(key)
                else:
                    target[key] = prior
        name = 'scripts/scene_pointer_delivery.py'
        self.sources[name] = self.sources[name].replace(b"'-swift-version', '6'", b"'-swift-version', '5'")
        self.records['binding/binding.json']['sourceFiles'][name] = hashlib.sha256(self.sources[name]).hexdigest()
        with self.assertRaisesRegex(ValueError, 'compile recipe changed'):
            self.bind()


class PointerOpenCaptureTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(); self.addCleanup(folder.cleanup)
        self.root = Path(folder.name); self.native = self.root / 'native'; self.native.mkdir()
        self.observed = self.root / 'observer'; self.observed.mkdir()
        self.binary = self.root / 'NexGenVideo.app/Contents/MacOS/NexGenVideo'
        self.binary.parent.mkdir(parents=True); self.binary.write_bytes(b'app')
        self.source = 'a' * 40
        self.receipt = {'reaped': True, 'stoppedEarly': False, 'cancelled': [], 'cleanupErrors': [], 'returncode': -15}
        self.put(self.native / 'process.json', {'pid': 100, 'sourceSHA': self.source})
        self.put(self.observed / 'attachment.json', {'sourceSHA': self.source,
            'executableSHA256': diagnostic.sha(self.binary),
            'processIdentity': {'pid': 100, 'startAbsoluteTime': 10, 'executable': str(self.binary)}})
        service = str(self.binary.parent.parent / 'XPCServices/NexGenVideoBpyService0.xpc/Contents/MacOS/NexGenVideoBpyService')
        self.events = [
            {'processID': 200, 'processImagePath': service, 'machTimestamp': 30,
             'subsystem': 'de.h5ventures.nexgenvideo.bpy-service', 'category': 'open-diagnostic',
             'timestamp': '2026-11-13 00:00:01+0000',
             'eventMessage': 'open.prepared session=session owner=owner pid=200 start=20'},
            {'processID': 100, 'processImagePath': str(self.binary), 'machTimestamp': 40,
             'subsystem': 'de.h5ventures.nexgenvideo', 'category': 'bpy-open',
             'timestamp': '2026-11-13 00:00:02+0000',
             'eventMessage': 'open.preparation session=session servicePID=200 serviceStart=20'},
            {'processID': 200, 'processImagePath': service, 'machTimestamp': 50,
             'subsystem': 'de.h5ventures.nexgenvideo.bpy-service', 'category': 'open-diagnostic',
             'timestamp': '2026-11-13 00:00:03+0000',
             'eventMessage': 'open.fail session=session owner=owner pid=200 start=20 stage=reserve domain=NSCocoaErrorDomain code=513'},
        ]
        self.started = diagnostic.datetime(2026, 11, 13, tzinfo=diagnostic.timezone.utc).timestamp()

    def put(self, path, value):
        path.write_text(json.dumps(value))

    def check(self):
        self.put(self.native / 'open-capture.json', self.receipt)
        (self.native / 'open-events.ndjson').write_text('\n'.join(json.dumps(row) for row in self.events))
        return diagnostic.verify_open_capture(self.native, self.observed, self.binary,
            self.source, self.started, self.started + 10)

    def test_owned_failure_discriminator_and_intentional_stream_term_are_retained(self):
        result = self.check()
        self.assertEqual(result['sessions'][0]['failures'][0]['fields']['stage'], 'reserve')
        self.assertEqual(result['hostIdentity']['pid'], 100)

    def test_incomplete_capture_receipt_never_qualifies(self):
        for key, value in (('reaped', False), ('stoppedEarly', True), ('cancelled', [15]),
                           ('cleanupErrors', ['failure']), ('returncode', None)):
            original = self.receipt.copy(); self.receipt[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check()
            self.receipt = original

    def test_foreign_missing_or_reused_service_events_are_rejected(self):
        original = copy.deepcopy(self.events)
        for index, key, value in ((0, 'processID', 201), (0, 'processImagePath', '/other'),
                (0, 'machTimestamp', 19), (1, 'timestamp', '2026-11-12 00:00:00+0000'),
                (2, 'eventMessage', 'open.fail session=session owner=owner pid=200 start=21 stage=reserve domain=D code=1')):
            self.events = copy.deepcopy(original); self.events[index][key] = value
            with self.subTest(index=index, key=key, value=value), self.assertRaises(ValueError):
                self.check()
        self.events = original[1:]
        with self.assertRaises(ValueError):
            self.check()

    def test_same_service_session_foreign_owner_remains_explicit_not_a_matched_request(self):
        self.events[2]['eventMessage'] = self.events[2]['eventMessage'].replace('owner=owner', 'owner=foreign')
        failure = self.check()['sessions'][0]['failures'][0]
        self.assertFalse(failure['ownerMatchesPreparation'])
        self.assertEqual(failure['fields']['owner'], 'foreign')

    def test_generic_app_failure_requires_its_own_service_discriminator(self):
        self.put(self.native / 'runtime-failure-observation.json', {'error': 'invalid open request'})
        response = b'{"ok":false,"message":"invalid open request"}'
        failure = {'hostPID': 100, 'sourceSHA': self.source, 'sessionID': 'other-session',
            'response': base64.b64encode(response).decode(), 'responseSHA256': hashlib.sha256(response).hexdigest()}
        self.put(self.native / 'open-failure-one.json', failure)
        with self.assertRaises(ValueError):
            self.check()
        failure['sessionID'] = 'session'; self.put(self.native / 'open-failure-one.json', failure)
        self.assertEqual(len(self.check()['sessions'][0]['failures']), 1)
        self.events[2]['eventMessage'] = self.events[2]['eventMessage'].replace('owner=owner', 'owner=foreign')
        with self.assertRaises(ValueError):
            self.check()


if __name__ == '__main__':
    unittest.main()
