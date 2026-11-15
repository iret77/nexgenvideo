"""Reject incomplete or foreign instrumentation before interpreting pointer guards."""
import copy
import hashlib
import io
import zipfile
import json
from pathlib import Path
import plistlib
import unittest
import tempfile
from unittest import mock

import native_pointer_guard_diagnostic as diagnostic


class NativePointerGuardDiagnosticTests(unittest.TestCase):
    def event(self):
        value = diagnostic.fixture()
        return {'inputs': dict(candidate_kind=diagnostic.KIND, run_id=str(value['failureRunID']),
            source_sha=value['failureSourceSHA'], artifact_id=str(value['failureArtifactID']),
            artifact_sha256=value['failureArtifactSHA256'], verified_pr_run_id='123',
            interface_scale='1', journey_scenario='journey')}

    def test_exact_original_failure_rejects_foreign_or_ignored_inputs(self):
        event = self.event()
        value = diagnostic.validate_inputs(event)
        self.assertEqual(value['diagnosticFunctionIDs'], [identity for identity in value['failedFunctionIDs']
            if '/unselectedAndDisabledTargetsKeepDifferentMeaning()/' in identity])
        for key, change in [('run_id', '1'), ('source_sha', 'a' * 40), ('artifact_id', '1'),
                ('artifact_sha256', 'a' * 64), ('verified_pr_run_id', ''), ('interface_scale', '1.5'),
                ('runtime_failure_binding', '{}'), ('test_bundle_run_id', '1'), ('expected_dmg_sha256', 'b' * 64)]:
            changed = copy.deepcopy(event); changed['inputs'][key] = change
            with self.subTest(key=key), self.assertRaises(ValueError): diagnostic.validate_inputs(changed)

    def test_signature_preflight_never_weakens_original_hardened_policy(self):
        self.assertFalse(diagnostic.parse_signature('CodeDirectory v=20400 size=1234 flags=0x2(adhoc) hashes=35+0 location=embedded\nExecutable Segment flags=0x1', '')['hardenedRuntime'])
        allowed = {key: True for key in ['com.apple.security.cs.allow-dyld-environment-variables',
            'com.apple.security.cs.disable-library-validation']}
        encoded = lambda value: plistlib.dumps(value).decode()
        self.assertTrue(diagnostic.parse_signature('CodeDirectory v=20400 size=1234 flags=0x10002(adhoc,runtime) hashes=35+0 location=embedded\nExecutable Segment flags=0x1', encoded(allowed))['hardenedRuntime'])
        for values in [{}, dict(allowed, **{'com.apple.security.cs.disable-library-validation': False})]:
            with self.assertRaises(ValueError): diagnostic.parse_signature('CodeDirectory v=20400 size=1234 flags=0x10002(runtime) hashes=35+0 location=embedded\nExecutable Segment flags=0x1', encoded(values))
        for description, entitlements in [('unknown', ''), ('Executable Segment flags=0x2', ''), ('CodeDirectory v=20400 size=1234 flags=0x2\nCodeDirectory v=20400 size=1234 flags=0x2', ''), ('CodeDirectory v=20400 size=1234 flags=0x2', 'garbage')]:
            with self.assertRaises(ValueError): diagnostic.parse_signature(description, entitlements)

    def test_preflight_reads_codesign_flags_from_the_actual_stderr_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            def logged(folder, label, argv):
                (folder / (label + '.stdout')).write_text('')
                (folder / (label + '.stderr')).write_text('Executable=/host\nCodeDirectory v=20400 size=1234 flags=0x20002(adhoc,linker-signed) hashes=35+0 location=embedded\nExecutable Segment flags=0x1\n'
                    if label.endswith('-signature') else 'Executable=/host\n')
                return ''
            with mock.patch.object(diagnostic.targets, 'logged', side_effect=logged):
                result = diagnostic.signature_preflight(Path('/host'), evidence, 'host')
            self.assertFalse(result['hardenedRuntime'])
            self.assertEqual(result['flags'], 0x20002)

    def retained_binding(self):
        value = diagnostic.fixture()
        return dict(schema='native-pointer-guard-binding/v1', sourceSHA=diagnostic.RETAINED_SOURCE,
            runID=diagnostic.RETAINED_RUN, attempt=1, fixtureSHA256=diagnostic.FIXTURE_SHA,
            nativeExecution=False, fullReleaseAcceptance=False,
            members={name: value[key] for name, (_, key) in diagnostic.MEMBERS.items()},
            sourceFiles={name: (diagnostic.HISTORICAL_C_SHA if name.endswith('.m') else diagnostic.checksum(Path(name)))
                for name in diagnostic.HISTORICAL_SOURCE_FILES})

    def test_retained_original_members_reject_foreign_producers_or_different_C_source(self):
        valid = self.retained_binding()
        diagnostic.verify_retained_binding(valid, diagnostic.fixture())
        for key, value in [('sourceSHA', 'a' * 40), ('runID', 1), ('attempt', 2), ('fixtureSHA256', 'a' * 64),
                ('nativeExecution', True), ('members', {}), ('sourceFiles', {})]:
            changed = copy.deepcopy(valid); changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.verify_retained_binding(changed, diagnostic.fixture())
        changed = copy.deepcopy(valid); changed['sourceFiles']['scripts/native_pointer_guard_snapshot.m'] = 'a' * 64
        with self.assertRaises(ValueError): diagnostic.verify_retained_binding(changed, diagnostic.fixture())

    def test_retained_inspector_requires_exact_bytes_and_all_three_passed_commands(self):
        image = b'qualified-observation-image'
        digest = hashlib.sha256(image).hexdigest()
        def archive(failure=None, changed=False):
            data = io.BytesIO()
            with zipfile.ZipFile(data, 'w') as zipped:
                zipped.writestr('native-pointer-guard-source/binding.json', json.dumps(self.retained_binding()))
                for stage in ('compile-inspector-only', 'sign-inspector-only', 'verify-inspector-only'):
                    zipped.writestr(diagnostic.INSPECTOR_PREFIX + stage + '.exit.json',
                        json.dumps({'exitCode': 1 if stage == failure else 0}))
                zipped.writestr(diagnostic.INSPECTOR_PREFIX + 'pointer-guard-snapshot.dylib', image + (b'changed' if changed else b''))
            data.seek(0); return zipfile.ZipFile(data)
        with mock.patch.object(diagnostic, 'INSPECTOR_SHA', digest), mock.patch.object(diagnostic, 'INSPECTOR_BYTES', len(image)):
            with archive() as zipped: self.assertEqual(diagnostic.inspector_bytes(zipped, diagnostic.fixture()), image)
            for stage in ('compile-inspector-only', 'sign-inspector-only', 'verify-inspector-only'):
                with self.subTest(stage=stage), archive(stage) as zipped, self.assertRaises(ValueError):
                    diagnostic.inspector_bytes(zipped, diagnostic.fixture())
            with archive(changed=True) as zipped, self.assertRaises(ValueError):
                diagnostic.inspector_bytes(zipped, diagnostic.fixture())

    def rows(self):
        self.file_identity = dict(path='/tests', device=1, inode=2)
        root = dict(root='0x1', window=123, windowIdentity='0x2', probe='0x3')
        common = dict(pid=10, diagnosticOnly=True)
        sample = dict(common, **root, kind='guard-snapshot', wallTime=5, sample=1,
            nativeControlType=False, notHidden=True, visibleArea=True, probeContainsHitBounds=True,
            visibleRectContainsPoint=True, nativeAccessibilityEnabled=True, nativeKnownRole=True,
            nativeGuardResult=False, rootPoint=[1, 2], windowPoint=[1, 2], screenPoint=[1, 2], hitPoint=[1, 2],
            probeFrame=[0, 0, 10, 10], hitBoundsInRoot=[0, 0, 10, 10], hitVisibleRect=[0, 0, 10, 10],
            stack=[dict(address='0x4', imageBase='0x5', image='/tests', symbol='target')])
        for key in ['hostingAXChain', 'hitAXChain', 'hitOwnAXChain']:
            sample[key] = dict(elements=[dict(identity='0x2')], end='boundWindow', completeToBoundWindow=True)
        geometry = dict(common, **root, kind='viewport-convert', wallTime=4, sample=1, clip='0x7',
            inputRect=[0, 0, 620, 40], returnedRect=[10, 20, 620, 40], clipBounds=[0, 0, 480, 320],
            rootBounds=[0, 0, 480, 320], probeVisibleRect=[0, 0, 470, 40], widthFits=False, heightFits=True,
            ancestorClips=[dict(clip='0x7', bounds=[0, 0, 480, 320])], stack=copy.deepcopy(sample['stack']))
        return [dict(common, kind='loaded', wallTime=1, parentPID=20, expectedImageIdentity=self.file_identity),
            dict(common, kind='probe-hook-ready', wallTime=2, installed=True, mainThread=True,
                classImageIdentity=self.file_identity, expectedImageIdentity=self.file_identity,
                **{'class': 'NexGenVideo.AppRelaunchClickProbeView', 'typeEncoding': '{CGRect}{CGRect}@'}),
            dict(common, **root, kind='hook-ready', wallTime=3, installed=True, mainThread=True,
                inspectorImage='/inspector', rootAXImageIdentity=self.file_identity, expectedImageIdentity=self.file_identity,
                originalIMP='0x6', typeEncoding='@32@0:8{CGPoint=dd}16'), geometry, sample,
            dict(common, kind='finished', wallTime=6, samples=1, rectSamples=1, outputErrors=0,
                rejectedRecords=0, originalCalls=1, transparentReturns=1, rectCalls=1, rectReturns=1, hookTime=3)]

    def verify(self, rows, truncate=False, negative=False):
        raw = b''.join((json.dumps(row) + '\n').encode() for row in rows)
        return diagnostic.verify_snapshots(raw[:-1] if truncate else raw,
            dict(pid=10, parentPID=20, launchBefore=0, endAfter=7), Path('/inspector'), Path('/tests'),
            expected_identity=self.file_identity, negative=negative)

    def test_false_native_predicate_is_evidence_and_never_release_acceptance(self):
        result = self.verify(self.rows())
        self.assertTrue(result['outputComplete'])
        self.assertTrue(result['diagnosticOnly'])
        self.assertEqual(result['falsePredicatesBySample'], [['nativeControlType']])
        self.assertEqual(result['viewportSizeFailures'], [1])
        rows = self.rows(); rows[4]['hitAXChain'] = dict(elements=[], end='nonProtocol', completeToBoundWindow=False)
        self.assertTrue(self.verify(rows)['outputComplete'])

    def test_viewport_only_evidence_does_not_claim_the_later_target_was_measured(self):
        rows = self.rows(); rows.pop(4); rows[-1].update(samples=0, originalCalls=0, transparentReturns=0)
        measured = self.verify(rows)
        self.assertEqual(measured['samples'], 0)
        self.assertEqual(measured['rectSamples'], 1)
        self.assertEqual(measured['falsePredicatesBySample'], [])
        self.assertTrue(measured['diagnosticOnly'])

    def test_foreign_image_refusal_requires_real_discovery_and_zero_installed_hooks(self):
        rows = self.rows()
        refused = [rows[0], dict(pid=10, diagnosticOnly=True, kind='discovery', wallTime=2,
            classFound=True, imageMatches=False), dict(rows[-1], samples=0, rectSamples=0,
            originalCalls=0, transparentReturns=0, rectCalls=0, rectReturns=0)]
        self.assertTrue(self.verify(refused, negative=True)['negativeImageRefused'])
        for changed in [refused[:1] + refused[2:], rows]:
            with self.assertRaises(ValueError): self.verify(changed, negative=True)

    def test_call_counters_are_required_typed_nonnegative_and_cover_every_sample(self):
        for pair in [('originalCalls', 'transparentReturns'), ('rectCalls', 'rectReturns')]:
            for value in [None, -1, '1', True, 0]:
                rows = self.rows()
                for key in pair:
                    if value is None: rows[-1].pop(key)
                    else: rows[-1][key] = value
                with self.subTest(pair=pair, value=value), self.assertRaises(ValueError): self.verify(rows)
        rows = self.rows()
        refused = [rows[0], dict(pid=10, diagnosticOnly=True, kind='discovery', wallTime=2,
            classFound=True, imageMatches=False), dict(rows[-1], samples=0, rectSamples=0,
            originalCalls=1, transparentReturns=1, rectCalls=0, rectReturns=0)]
        with self.assertRaises(ValueError): self.verify(refused, negative=True)

    def test_viewport_only_requires_nonnull_view_window_and_clip_identities(self):
        for key in ('root', 'probe', 'windowIdentity', 'window', 'clip'):
            for value in (None, 'nil', '0x0', 0):
                rows = self.rows(); rows.pop(4); rows[-1].update(samples=0, originalCalls=0, transparentReturns=0)
                for row in rows:
                    if row['kind'] in ('hook-ready', 'viewport-convert'):
                        if value is None: row.pop(key, None)
                        else: row[key] = value
                if key == 'clip':
                    if value is None: rows[3]['ancestorClips'][0].pop('clip')
                    else: rows[3]['ancestorClips'][0]['clip'] = value
                with self.subTest(key=key, value=value), self.assertRaises(ValueError): self.verify(rows)

    def test_missing_foreign_reordered_truncated_or_lossy_receipts_reject(self):
        for defect in ['no-finish', 'no-hook', 'no-probe-hook', 'no-geometry', 'wrong-pid', 'wrong-image', 'wrong-window',
                'wrong-root', 'wrong-probe', 'late-hook', 'write-error', 'cap-loss', 'lost-return', 'lost-rect-return',
                'count', 'guard-lie', 'nonfinite', 'bad-chain', 'foreign-window-chain', 'no-stack', 'truncated',
                'width-lie', 'unowned-clip', 'duplicate-probe-hook']:
            rows = self.rows()
            if defect == 'no-finish': rows.pop()
            elif defect == 'no-hook': rows.pop(2)
            elif defect == 'no-probe-hook': rows.pop(1)
            elif defect == 'no-geometry': rows.pop(3); rows[-1]['rectSamples'] = 0
            elif defect == 'wrong-pid': rows[4]['pid'] = 11
            elif defect == 'wrong-image': rows[2]['rootAXImageIdentity'] = dict(path='/foreign', device=2, inode=3)
            elif defect == 'wrong-window': rows[4]['windowIdentity'] = '0xff'
            elif defect == 'wrong-root': rows[4]['root'] = '0xff'
            elif defect == 'wrong-probe': rows[4]['probe'] = '0xff'
            elif defect == 'late-hook': rows[2]['wallTime'] = 5.5
            elif defect == 'write-error': rows[-1]['outputErrors'] = 1
            elif defect == 'cap-loss': rows[-1]['rejectedRecords'] = 1
            elif defect == 'lost-return': rows[-1]['transparentReturns'] = 0
            elif defect == 'lost-rect-return': rows[-1]['rectReturns'] = 0
            elif defect == 'count': rows[-1]['samples'] = 2
            elif defect == 'guard-lie': rows[4]['nativeGuardResult'] = True
            elif defect == 'nonfinite': rows[4]['rootPoint'][0] = float('inf')
            elif defect == 'bad-chain': rows[4]['hitAXChain']['end'] = 'depthLimit'
            elif defect == 'foreign-window-chain': rows[4]['hitAXChain']['elements'][-1]['identity'] = '0xff'
            elif defect == 'no-stack': rows[3]['stack'] = []
            elif defect == 'width-lie': rows[3]['widthFits'] = True
            elif defect == 'unowned-clip': rows[3]['clip'] = '0xff'
            elif defect == 'duplicate-probe-hook': rows.insert(2, copy.deepcopy(rows[1]))
            with self.subTest(defect=defect), self.assertRaises(ValueError): self.verify(rows, defect == 'truncated')
