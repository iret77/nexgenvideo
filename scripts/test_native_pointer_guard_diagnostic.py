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
            sourceFiles={name: diagnostic.checksum(Path(name)) for name in diagnostic.SOURCE_FILES})

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
        root = dict(root='0x1', window=123, windowIdentity='0x2')
        common = dict(pid=10, diagnosticOnly=True)
        sample = dict(common, **root, kind='guard-snapshot', wallTime=3, sample=1, probe='0x3',
            nativeControlType=False, notHidden=True, visibleArea=True, probeContainsHitBounds=True,
            visibleRectContainsPoint=True, nativeAccessibilityEnabled=True, nativeKnownRole=True,
            nativeGuardResult=False, rootPoint=[1, 2], windowPoint=[1, 2], screenPoint=[1, 2], hitPoint=[1, 2],
            probeFrame=[0, 0, 10, 10], hitBoundsInRoot=[0, 0, 10, 10], hitVisibleRect=[0, 0, 10, 10],
            stack=[dict(address='0x4', imageBase='0x5', image='/tests', symbol='target')])
        for key in ['hostingAXChain', 'hitAXChain', 'hitOwnAXChain']:
            sample[key] = dict(elements=[dict(identity='0x2')], end='boundWindow', completeToBoundWindow=True)
        return [dict(common, kind='loaded', wallTime=1, parentPID=20),
            dict(common, **root, kind='hook-ready', wallTime=2, installed=True, mainThread=True,
                inspectorImage='/inspector', rootClassImage='/tests', originalIMP='0x6', typeEncoding='@32@0:8{CGPoint=dd}16'),
            sample, dict(common, kind='finished', wallTime=4, samples=1, outputErrors=0,
                rejectedRecords=0, originalCalls=1, transparentReturns=1, hookTime=2, firstHitTime=3)]

    def verify(self, rows, truncate=False):
        raw = b''.join((json.dumps(row) + '\n').encode() for row in rows)
        return diagnostic.verify_snapshots(raw[:-1] if truncate else raw,
            dict(pid=10, parentPID=20, launchBefore=0, endAfter=5), Path('/inspector'), Path('/tests'))

    def test_false_native_predicate_is_evidence_and_never_release_acceptance(self):
        result = self.verify(self.rows())
        self.assertTrue(result['outputComplete'])
        self.assertTrue(result['diagnosticOnly'])
        self.assertEqual(result['falsePredicatesBySample'], [['nativeControlType']])
        rows = self.rows(); rows[2]['hitAXChain'] = dict(elements=[], end='nonProtocol', completeToBoundWindow=False)
        self.assertTrue(self.verify(rows)['outputComplete'])

    def test_missing_foreign_reordered_truncated_or_lossy_receipts_reject(self):
        for defect in ['no-finish', 'no-hook', 'no-sample', 'wrong-pid', 'wrong-image', 'wrong-window',
                'wrong-root', 'wrong-probe', 'late-hook', 'write-error', 'cap-loss', 'lost-return',
                'count', 'guard-lie', 'nonfinite', 'bad-chain', 'foreign-window-chain', 'no-stack', 'truncated']:
            rows = self.rows()
            if defect == 'no-finish': rows.pop()
            elif defect == 'no-hook': rows.pop(1)
            elif defect == 'no-sample': rows.pop(2)
            elif defect == 'wrong-pid': rows[2]['pid'] = 11
            elif defect == 'wrong-image': rows[1]['rootClassImage'] = '/foreign'
            elif defect == 'wrong-window': rows[2]['windowIdentity'] = '0xff'
            elif defect == 'wrong-root': rows[2]['root'] = '0xff'
            elif defect == 'wrong-probe':
                extra = copy.deepcopy(rows[2]); extra.update(sample=2, probe='0xff'); rows.insert(3, extra)
                rows[-1].update(samples=2, originalCalls=2, transparentReturns=2)
            elif defect == 'late-hook': rows[1]['wallTime'] = 3.5
            elif defect == 'write-error': rows[-1]['outputErrors'] = 1
            elif defect == 'cap-loss': rows[-1]['rejectedRecords'] = 1
            elif defect == 'lost-return': rows[-1]['transparentReturns'] = 0
            elif defect == 'count': rows[-1]['samples'] = 2
            elif defect == 'guard-lie': rows[2]['nativeGuardResult'] = True
            elif defect == 'nonfinite': rows[2]['rootPoint'][0] = float('inf')
            elif defect == 'bad-chain': rows[2]['hitAXChain']['end'] = 'depthLimit'
            elif defect == 'foreign-window-chain': rows[2]['hitAXChain']['elements'][-1]['identity'] = '0xff'
            elif defect == 'no-stack': rows[2]['stack'] = []
            with self.subTest(defect=defect), self.assertRaises(ValueError): self.verify(rows, defect == 'truncated')
