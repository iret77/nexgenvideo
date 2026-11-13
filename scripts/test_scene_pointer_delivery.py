import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import scene_pointer_delivery as diagnostic


def environment():
    return {'KIND': 'native-scene-pointer-delivery', 'PRODUCER_RUN': '100', 'PRODUCER_SHA': 'a' * 40,
        'DIAGNOSTIC_ID': '200', 'DIAGNOSTIC_DIGEST': 'b' * 64, 'FAILURE_ID': '300',
        'FAILURE_DIGEST': 'c' * 64, 'DMG_DIGEST': 'd' * 64, 'VERIFIED_PR': '400', 'SCALE': '1'}


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


if __name__ == '__main__':
    unittest.main()
