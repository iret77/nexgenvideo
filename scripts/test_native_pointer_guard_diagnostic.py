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
    def trace_rows(self, selftest=False):
        image = dict(path='/tests', device=1, inode=2)
        host = copy.deepcopy(image) if selftest else dict(path='/host', device=3, inode=4)
        rows = [dict(kind='loaded', expectedImageIdentity=image, expectedHostIdentity=host,
            actualHostIdentity=host, selftestMode=selftest, observerImageIdentity=dict(path='/observer', device=1, inode=5))]
        methods = ['windowNumberAtPoint:belowWindowWithWindowNumber:', 'windowNumber', 'CGWindowListCopyWindowInfo',
            'postEvent:atStart:', 'sendEvent:', 'sendAction:to:from:', 'keyDown:', 'selectAll:',
            'window.performKeyEquivalent:', 'menu.performKeyEquivalent:', 'doCommandBySelector:', 'selectedRange', 'selectedRange']
        for method in sorted(set(methods)):
            equivalent = method in ('window.performKeyEquivalent:', 'menu.performKeyEquivalent:')
            rows.append(dict(kind='hook', selector='performKeyEquivalent:' if equivalent else method, installed=True,
                **{'class': 'NSWindow' if method.startswith('window.') else 'NSMenu' if equivalent else 'NSApplication'},
                typeEncoding='{_NSRange=QQ}16@0:8' if method == 'selectedRange' else 'v24@0:8@16'))
        context = dict(queryOrigin='ADDITIONAL_CONTEXT', contextOrdinal=1,
            keyWindowIdentity='0x40' if selftest else 'nil', keyWindow=40 if selftest else 0,
            additionalQueryCounts=dict(CGWindowListCopyWindowInfo=1))
        event = dict(identity='0xa', type=10, timestamp=2.0, timestampUnits='seconds-since-startup',
            flags=0, keyCode=7, characters='x', charactersIgnoringModifiers='x', getterOrigin='ADDITIONAL_OBSERVATION')
        counts = {}
        for index, method in enumerate(methods, 1):
            arguments = dict(event=copy.deepcopy(event)) if method in ('postEvent:atStart:', 'sendEvent:') else {}
            if method == 'sendEvent:': arguments['selftestPumpDispatch'] = selftest
            if method in ('window.performKeyEquivalent:', 'menu.performKeyEquivalent:'):
                arguments = dict(event=dict(event, characters='a', charactersIgnoringModifiers='a', flags=1 << 20, keyCode=0))
            if method == 'windowNumberAtPoint:belowWindowWithWindowNumber:': arguments = dict(point=[1, 2], below=0)
            if method == 'doCommandBySelector:': arguments = dict(command='selectAll:', receiver='0x41')
            if method in ('sendAction:to:from:', 'window.performKeyEquivalent:', 'menu.performKeyEquivalent:'):
                arguments['scope'] = dict(queryOrigin='ADDITIONAL_SCOPE_OBSERVATION', ownedCaller=not selftest,
                    ownedKeyWindow=selftest, ownedTargetWindow=False, ownedEventWindow=False,
                    actualKeyWindowIdentity='0x40' if selftest else 'nil', targetWindowIdentity='nil', eventWindowIdentity='nil')
            returned = [0, 2] if index == len(methods) else [1, 0] if method == 'selectedRange' else True
            if method == 'window.performKeyEquivalent:': returned = False
            if method == 'doCommandBySelector:': returned = dict(range=dict(selection=[0, 2]))
            rows.append(dict(kind='call', call=index, method=method, arguments=arguments,
                context=copy.deepcopy(context), queryOrigin='ORIGINAL_EXECUTION',
                stack=[dict(image='/tests', address='0x20', imageBase='0x10')]))
            if method == 'sendEvent:': rows.append(dict(kind='receive', event=copy.deepcopy(event)))
            rows.append(dict(kind='return', call=index, method=method, returned=returned,
                context=copy.deepcopy(context), queryOrigin='ORIGINAL_EXECUTION'))
            counts[method] = counts.get(method, 0) + 1
        if selftest:
            nil_context = dict(context, keyWindowIdentity='nil', keyWindow=0)
            for number, method in enumerate(('sendAction:to:from:', 'menu.performKeyEquivalent:'), 90):
                arguments = dict(target='0x41') if number == 90 else dict(receiver='0x42', event=dict(event, characters='a', charactersIgnoringModifiers='a', keyCode=0, flags=1 << 20))
                arguments['scope'] = dict(queryOrigin='ADDITIONAL_SCOPE_OBSERVATION', ownedCaller=False,
                    ownedKeyWindow=False, ownedTargetWindow=number == 90, ownedEventWindow=number == 91,
                    actualKeyWindowIdentity='nil', targetWindowIdentity='0x40' if number == 90 else 'nil',
                    eventWindowIdentity='0x40' if number == 91 else 'nil')
                rows.append(dict(kind='call', call=number, method=method, arguments=arguments, context=copy.deepcopy(nil_context),
                    queryOrigin='ORIGINAL_EXECUTION', stack=[dict(image='/tests', address='0x20', imageBase='0x10')], fixtureUptime=3.2 + (number - 90) * 0.1))
                rows.append(dict(kind='return', call=number, method=method, returned=True, context=copy.deepcopy(nil_context),
                    queryOrigin='ORIGINAL_EXECUTION', fixtureUptime=3.25 + (number - 90) * 0.1))
                counts[method] += 1
            for number, method in enumerate(('sendAction:to:from:', 'menu.performKeyEquivalent:'), 1):
                arguments = dict(target='0x51') if number == 1 else dict(receiver='0x52', event=dict(event, characters='a', charactersIgnoringModifiers='a', keyCode=0, flags=1 << 20))
                scope = dict(queryOrigin='ADDITIONAL_SCOPE_OBSERVATION', ownedCaller=False, ownedKeyWindow=False,
                    ownedTargetWindow=False, ownedEventWindow=False, actualKeyWindowIdentity='nil',
                    targetWindowIdentity='0x50' if number == 1 else 'nil', eventWindowIdentity='0x50' if number == 2 else 'nil')
                rows.append(dict(kind='selftest-scope-call', call=number, method=method, arguments=arguments, scope=scope,
                    queryOrigin='SELFTEST_ONLY_SCOPE_REFUSAL', fixtureUptime=4.0 + number * 0.1))
                rows.append(dict(kind='selftest-scope-return', call=number, method=method, returned=True,
                    queryOrigin='SELFTEST_ONLY_SCOPE_REFUSAL', fixtureUptime=4.05 + number * 0.1))
            ready = dict(queryOrigin='SELFTEST_ONLY', active=True, visible=True, key=True,
                keyWindowIdentity='0x40', windowIdentity='0x40', responderIdentity='0x41', textIdentity='0x41',
                acceptsFirstResponder=True, makeFirstResponderReturn=True)
            rows.append(dict(kind='selftest', ready=True, readiness=copy.deepcopy(ready), readinessStart=1.0,
                readinessDeadline=3.0, readinessEnd=1.1, readinessEvents=[], queueStart=2.0, queueDeadline=4.0, queueEnd=2.2,
                dequeueMask=1 << 10, dequeueMode='kCFRunLoopDefaultMode', dequeue=True, queueResult='IDENTICAL_EVENT',
                postedEvent=copy.deepcopy(event), createdEvent=copy.deepcopy(event), posted=True,
                timeUnits='seconds-since-startup', expirationUnits='seconds-since-Unix-epoch', cleanupComplete=True, selectionAfterCommand=[0, 2],
                selftestOwner=dict(windowIdentity='0x40', textIdentity='0x41', **{'class': 'NGVTraceSelftestTextView'},
                    classImageIdentity=dict(path='/observer', device=1, inode=5)),
                nilKeyStart=3.0, nilKeyDeadline=5.0, nilKeyEnd=3.1, nilKeyWindow=True, nilKeyAfterForeign=True,
                nilActionReturn=True, nilMenuReturn=True, nilActionSelection=[0, 2], nilMenuSelection=[0, 2],
                foreignActionReturn=True, foreignMenuReturn=True, foreignActionSelection=[0, 2], foreignMenuSelection=[0, 2],
                ownedTextIdentity='0x41', ownedMenuIdentity='0x42', foreignTextIdentity='0x51', foreignMenuIdentity='0x52',
                dequeues=[dict(event=copy.deepcopy(event), dequeuedAt=2.1, expiration=100.0,
                    readiness=copy.deepcopy(ready), requestedAt=2.05, sameIdentity=True, dispatched=True)], complete=True, queueIdentityUnchanged=True, inserted='xb',
                selectionAfterKey=[1, 0], selectionAfterAction=[0, 2], actionReturn=True,
                windowEquivalentReturn=False, menuEquivalentReturn=True, selectionAfterMenu=[0, 2]))
        rows.append(dict(kind='finished', calls=counts, returns=copy.deepcopy(counts), errors=0,
            selftestMode=selftest, selftestCompleted=selftest, contextCount=20,
            additionalGetterQueryCounts=dict(CGWindowListCopyWindowInfo=20, **{'scope.evaluation': 12})))
        clock = 0.0
        for index, row in enumerate(rows, 1):
            if row.get('method') == 'postEvent:atStart:': clock = 2.01 if row['kind'] == 'call' else 2.02
            elif row.get('method') == 'sendEvent:': clock = 2.12 if row['kind'] == 'call' else 2.14
            elif row['kind'] == 'receive': clock = 2.13
            elif clock >= 2.14: clock = max(clock, 2.3) + 0.01
            else: clock += 0.01
            clock = row.pop('fixtureUptime', clock)
            row.update(sequence=index, pid=10, parentPID=20, mainThread=True, wallTime=index,
                uptime=clock, diagnosticOnly=True)
        return rows, (image, host)

    def trace_verify(self, rows, identities, selftest=False):
        return diagnostic.verify_event_trace(b''.join((json.dumps(row) + '\n').encode() for row in rows),
            dict(pid=10, parentPID=20, launchBefore=0, endAfter=1000), Path('/tests'), Path('/host'),
            identities=identities, selftest=selftest)

    def test_event_trace_requires_every_original_return_and_true_operand_provenance(self):
        rows, identities = self.trace_rows()
        self.assertTrue(self.trace_verify(rows, identities)['allOriginalCallsReturnedOnce'])
        for defect in ('lost-return', 'foreign-stack', 'wrong-process', 'context-as-original', 'bool-counter', 'missing-ABI', 'numeric-installed', 'wrong-host', 'scope-unowned', 'scope-numeric', 'scope-false-window', 'scope-substitution'):
            changed = copy.deepcopy(rows)
            call = next(row for row in changed if row['kind'] == 'call')
            if defect == 'lost-return':
                changed.pop(next(i for i, row in enumerate(changed) if row['kind'] == 'return'))
                for index, row in enumerate(changed, 1): row['sequence'] = index
            elif defect == 'foreign-stack': call['stack'][0]['image'] = '/foreign'
            elif defect == 'wrong-process': call['pid'] = 99
            elif defect == 'context-as-original': call['context']['queryOrigin'] = 'ORIGINAL_EXECUTION'
            elif defect == 'bool-counter': changed[-1]['calls'][call['method']] = True
            elif defect == 'missing-ABI': next(row for row in changed if row['kind'] == 'hook')['installed'] = False
            elif defect == 'numeric-installed': next(row for row in changed if row['kind'] == 'hook')['installed'] = 1
            elif defect == 'wrong-host': changed[0]['actualHostIdentity'] = identities[0]
            elif defect.startswith('scope-'):
                route = next(row for row in changed if row.get('method') == 'sendAction:to:from:' and row['kind'] == 'call')
                scope = route['arguments']['scope']
                if defect == 'scope-unowned': scope['ownedCaller'] = False
                elif defect == 'scope-numeric': scope['ownedCaller'] = 1
                elif defect == 'scope-false-window': scope.update(ownedCaller=False, ownedTargetWindow=True)
                elif defect == 'scope-substitution': scope['actualKeyWindowIdentity'] = '0x40'
            with self.subTest(defect=defect), self.assertRaises(ValueError): self.trace_verify(changed, identities)

    def test_app_authored_keys_do_not_need_quartz_and_unsigned_range_corruption_is_rejected(self):
        rows, identities = self.trace_rows()
        self.trace_verify(rows, identities)
        for defect in ('key-CG-conversion', 'wrong-unit', 'negative-range', 'bool-range'):
            changed = copy.deepcopy(rows)
            if defect in ('key-CG-conversion', 'wrong-unit'):
                event = next(row['arguments']['event'] for row in changed if row.get('method') == 'postEvent:atStart:' and row['kind'] == 'call')
                if defect == 'key-CG-conversion': event['CGPosition'] = [0, 0]
                else: event['timestampUnits'] = 'nanoseconds-since-startup'
            else:
                row = next(row for row in changed if row.get('method') == 'selectedRange' and row['kind'] == 'return')
                row['returned'] = [-1, 0] if defect == 'negative-range' else [True, 0]
            with self.subTest(defect=defect), self.assertRaises(ValueError): self.trace_verify(changed, identities)

    def test_native_key_range_witness_requires_identical_event_and_actual_range_returns(self):
        rows, identities = self.trace_rows(selftest=True)
        self.assertTrue(self.trace_verify(rows, identities, selftest=True)['selftest'])
        for defect in ('changed-characters', 'wrong-selection', 'missing-range-return', 'unknown-range-ABI', 'wrong-menu-return', 'numeric-queue-identity', 'numeric-complete', 'selftest-in-original-child', 'inactive', 'wrong-responder', 'ready-numeric',
                'readiness-expired', 'dequeue-nil', 'dequeue-foreign', 'dequeue-expired', 'missing-receive',
                'missing-command', 'wrong-command-return', 'cleanup-failed', 'post-before-start', 'nonfinite-uptime',
                'reordered-uptime', 'wrong-expiration-unit', 'missing-native-nil', 'foreign-scope-admitted', 'missing-foreign-return', 'wrong-owner-image'):
            changed = copy.deepcopy(rows)
            if defect == 'changed-characters': next(row for row in changed if row['kind'] == 'call' and row['method'] == 'sendEvent:')['arguments']['event']['characters'] = 'y'
            elif defect == 'wrong-selection': next(row for row in changed if row['kind'] == 'selftest')['selectionAfterAction'] = [1, 0]
            elif defect == 'missing-range-return':
                for row in changed:
                    if row['kind'] == 'return' and row['method'] == 'selectedRange': row['returned'] = [1, 0]
            elif defect == 'unknown-range-ABI': next(row for row in changed if row['kind'] == 'hook' and row['selector'] == 'selectedRange')['typeEncoding'] = '{_NSRange=II}16@0:8'
            elif defect == 'wrong-menu-return': next(row for row in changed if row['kind'] == 'return' and row['method'] == 'menu.performKeyEquivalent:')['returned'] = False
            elif defect == 'numeric-queue-identity': next(row for row in changed if row['kind'] == 'selftest')['queueIdentityUnchanged'] = 1
            elif defect == 'numeric-complete': next(row for row in changed if row['kind'] == 'selftest')['complete'] = 1
            elif defect in ('inactive', 'wrong-responder', 'ready-numeric', 'readiness-expired',
                    'dequeue-nil', 'dequeue-foreign', 'dequeue-expired', 'cleanup-failed'):
                witness = next(row for row in changed if row['kind'] == 'selftest')
                if defect == 'inactive': witness['readiness']['active'] = False
                elif defect == 'wrong-responder': witness['readiness']['responderIdentity'] = '0x42'
                elif defect == 'ready-numeric': witness['ready'] = 1
                elif defect == 'readiness-expired': witness['readinessEnd'] = 3.1
                elif defect == 'dequeue-nil': witness['dequeues'][0]['event'] = None
                elif defect == 'dequeue-foreign': witness['dequeues'][0]['event']['identity'] = '0xb'
                elif defect == 'dequeue-expired': witness['dequeues'][0]['dequeuedAt'] = 4.1; witness['queueEnd'] = 4.2
                elif defect == 'cleanup-failed': witness['cleanupComplete'] = False
            elif defect == 'missing-receive': next(row for row in changed if row['kind'] == 'receive')['event']['identity'] = '0xb'
            elif defect == 'post-before-start':
                for row in changed:
                    if row.get('method') == 'postEvent:atStart:': row['uptime'] = 1.9
            elif defect == 'nonfinite-uptime': changed[0]['uptime'] = float('nan')
            elif defect == 'reordered-uptime': changed[-1]['uptime'] = 0.0
            elif defect == 'wrong-expiration-unit': next(row for row in changed if row['kind'] == 'selftest')['expirationUnits'] = 'seconds-since-startup'
            elif defect == 'missing-native-nil':
                for row in changed:
                    if row['kind'] == 'call' and row.get('call') in (90, 91):
                        row['context']['keyWindowIdentity'] = '0x40'; row['arguments']['scope']['actualKeyWindowIdentity'] = '0x40'
            elif defect == 'foreign-scope-admitted': next(row for row in changed if row['kind'] == 'selftest-scope-call')['scope']['ownedTargetWindow'] = True
            elif defect == 'missing-foreign-return':
                changed.pop(next(i for i, row in enumerate(changed) if row['kind'] == 'selftest-scope-return'))
                for index, row in enumerate(changed, 1): row['sequence'] = index
            elif defect == 'wrong-owner-image': next(row for row in changed if row['kind'] == 'selftest')['selftestOwner']['classImageIdentity']['inode'] = 6
            elif defect == 'wrong-command-return': next(row for row in changed if row['kind'] == 'return' and row.get('method') == 'doCommandBySelector:')['returned']['range']['selection'] = [0, 1]
            elif defect == 'missing-command': next(row for row in changed if row['kind'] == 'call' and row.get('method') == 'doCommandBySelector:')['arguments']['command'] = 'deleteBackward:'
            with self.subTest(defect=defect), self.assertRaises(ValueError): self.trace_verify(changed, identities, selftest=defect != 'selftest-in-original-child')

    def test_canonical_only_trace_and_standalone_pass_never_qualify_mutation_refusal(self):
        rows, identities = self.trace_rows()
        result = self.trace_verify(rows, identities)
        self.assertFalse(result['mutationCoverageOrRootCauseQualified'])
        self.assertTrue(result['independentActualCallsiteAndPredicateReviewRequired'])
        old = self.rows()
        rows = [old[0], old[1], dict(old[-1], samples=0, rectSamples=0, originalCalls=0,
            transparentReturns=0, rectCalls=0, rectReturns=0)]
        raw = b''.join((json.dumps(row) + '\n').encode() for row in rows)
        measured = diagnostic.verify_snapshots(raw, dict(pid=10, parentPID=20, launchBefore=0, endAfter=7),
            Path('/inspector'), Path('/tests'), expected_identity=self.file_identity, no_probe=True)
        self.assertTrue(measured['noHostingProbeInOriginalSelection'])
        process = dict(pid=10, parentPID=20, launchBefore=0, endAfter=7)
        optional = diagnostic.verify_snapshots(raw, process, Path('/inspector'), Path('/tests'),
            expected_identity=self.file_identity, optional_probe=True)
        self.assertTrue(optional['noHostingProbeInOriginalSelection'])
        partial = copy.deepcopy(rows); partial[-1].update(rectCalls=1, rectReturns=1)
        with self.assertRaises(ValueError):
            diagnostic.verify_snapshots(b''.join((json.dumps(row) + '\n').encode() for row in partial), process,
                Path('/inspector'), Path('/tests'), expected_identity=self.file_identity, optional_probe=True)
        with self.assertRaises(ValueError):
            diagnostic.verify_snapshots(b''.join((json.dumps(row) + '\n').encode() for row in partial), process,
                Path('/inspector'), Path('/tests'), expected_identity=self.file_identity, no_probe=True)
        full = b''.join((json.dumps(row) + '\n').encode() for row in self.rows())
        self.assertEqual(diagnostic.verify_snapshots(full, process, Path('/inspector'), Path('/tests'),
            expected_identity=self.file_identity, optional_probe=True)['samples'], 1)
        with self.assertRaises(ValueError):
            diagnostic.verify_snapshots(full, process, Path('/inspector'), Path('/tests'),
                expected_identity=self.file_identity, no_probe=True)
        with self.assertRaises(ValueError):
            diagnostic.verify_snapshots(raw, dict(pid=10, parentPID=20, launchBefore=0, endAfter=7),
                Path('/inspector'), Path('/tests'), expected_identity=self.file_identity)

    def event(self):
        value = diagnostic.fixture()
        return {'inputs': dict(candidate_kind=diagnostic.KIND, run_id=str(value['failureRunID']),
            source_sha=value['failureSourceSHA'], artifact_id=str(value['failureArtifactID']),
            artifact_sha256=value['failureArtifactSHA256'], verified_pr_run_id='123',
            interface_scale='1', journey_scenario='journey')}

    def test_exact_original_failure_rejects_foreign_or_ignored_inputs(self):
        event = self.event()
        value = diagnostic.validate_inputs(event)
        self.assertEqual([identity.rsplit('/', 1)[1] for identity in value['diagnosticFunctionIDs']],
            ['NativeButtonInteractionTests.swift:' + str(line) + ':6' for line in (1002, 1035, 1256, 1525, 1579, 1675)])
        self.assertEqual(len(set(value['diagnosticFunctionIDs']) & set(value['failedFunctionIDs'])), 5)
        self.assertEqual(len(value['failedFunctionIDs']), 13)
        self.assertEqual(value['actualOriginalAppResults'], dict(passed=3709, failed=13, skipped=8,
            XCTestPassed=48, retainedEnginePassed=896, retainedEngineSkipped=14))
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
        value = diagnostic.legacy_fixture()
        return dict(schema='native-pointer-guard-binding/v1', sourceSHA=diagnostic.RETAINED_SOURCE,
            runID=diagnostic.RETAINED_RUN, attempt=1, fixtureSHA256=diagnostic.LEGACY_FIXTURE_SHA,
            nativeExecution=False, fullReleaseAcceptance=False,
            members={name: value[key] for name, (_, key) in diagnostic.MEMBERS.items()},
            sourceFiles={name: (diagnostic.HISTORICAL_C_SHA if name.endswith('.m') else diagnostic.checksum(Path(name)))
                for name in diagnostic.HISTORICAL_SOURCE_FILES})

    def test_retained_original_members_reject_foreign_producers_or_different_C_source(self):
        valid = self.retained_binding()
        diagnostic.verify_retained_binding(valid, diagnostic.legacy_fixture())
        for key, value in [('sourceSHA', 'a' * 40), ('runID', 1), ('attempt', 2), ('fixtureSHA256', 'a' * 64),
                ('nativeExecution', True), ('members', {}), ('sourceFiles', {})]:
            changed = copy.deepcopy(valid); changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.verify_retained_binding(changed, diagnostic.legacy_fixture())
        changed = copy.deepcopy(valid); changed['sourceFiles']['scripts/native_pointer_guard_snapshot.m'] = 'a' * 64
        with self.assertRaises(ValueError): diagnostic.verify_retained_binding(changed, diagnostic.legacy_fixture())

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
            with archive() as zipped: self.assertEqual(diagnostic.inspector_bytes(zipped, diagnostic.legacy_fixture()), image)
            for stage in ('compile-inspector-only', 'sign-inspector-only', 'verify-inspector-only'):
                with self.subTest(stage=stage), archive(stage) as zipped, self.assertRaises(ValueError):
                    diagnostic.inspector_bytes(zipped, diagnostic.legacy_fixture())
            with archive(changed=True) as zipped, self.assertRaises(ValueError):
                diagnostic.inspector_bytes(zipped, diagnostic.legacy_fixture())

    def rows(self):
        self.file_identity = dict(path='/tests', device=1, inode=2)
        root = dict(root='0x1', window=123, windowIdentity='0x2', probe='0x3')
        common = dict(pid=10, diagnosticOnly=True)
        sample = dict(common, **root, kind='guard-snapshot', wallTime=5, sample=1,
            nativeControlType=False, notHidden=True, visibleArea=True, probeContainsHitBounds=True,
            visibleRectContainsPoint=True, nativeAccessibilityEnabled=True, nativeKnownRole=True,
            nativeGuardResult=False, nativeRole='AXTextField', hitNSControl=False, hitNSTextView=False,
            hitHidden=False, rolePresent=True, roleNonEmpty=True, roleNotUnknown=True,
            rootPoint=[1, 2], windowPoint=[1, 2], screenPoint=[1, 2], hitPoint=[1, 2],
            probeFrame=[0, 0, 10, 10], hitBoundsInRoot=[0, 0, 10, 10], hitVisibleRect=[0, 0, 10, 10],
            stack=[dict(address='0x4', imageBase='0x5', image='/tests', symbol='target')])
        sample['windowGuard'] = dict(windowAtPoint=123, ownerPID=10, windowNumber=123,
            screenAvailable=True, firstScreenFrame=[0, 0, 100, 100], quartzPoint=[1, 98],
            cgWindowListAvailable=True, matchingWindowCount=1, cgFrame=[0, 0, 100, 100],
            cgWindows=[dict(ownerPID=10, number=123, boundsAvailable=True,
                bounds=dict(X=0, Y=0, Width=100, Height=100))],
            predicates=dict(windowAtPointMatches=True, uniqueOwnWindow=True, boundsAvailable=True,
                boundsDecoded=True, frameFinite=True, positiveWidth=True, positiveHeight=True, containsQuartzPoint=True), result=True)
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
                rootClass='FixtureHosting', runtimeRootClass='ObservedFixtureHosting', originalAXIMP='0x8',
                runtimeLineageMatches=True, effectiveAXMatches=True, declaredOwnAX=True,
                inspectorImage='/inspector', rootAXImageIdentity=self.file_identity, expectedImageIdentity=self.file_identity,
                rootDeclaredImageIdentity=self.file_identity,
                originalIMP='0x6', typeEncoding='@32@0:8{CGPoint=dd}16'), geometry, sample,
            dict(common, kind='finished', wallTime=6, samples=1, rectSamples=1, outputErrors=0,
                rejectedRecords=0, originalCalls=1, transparentReturns=1, rectCalls=1, rectReturns=1, hookTime=3)]

    def test_retained_selftest_tool_requires_exact_source_bytes_and_three_passed_commands(self):
        image = b'signed-native-selftest-fixture'
        stages = ('compile-observer-selftest-tool', 'sign-observer-selftest-tool', 'verify-observer-selftest-tool')
        def archive(defect=None):
            binding = dict(schema='native-pointer-guard-binding/v1', runID=diagnostic.SELFTEST_PRODUCER[0],
                sourceSHA=diagnostic.SELFTEST_PRODUCER[1], attempt=1,
                sourceFiles=dict(diagnostic.SELFTEST_PRODUCER_FILES), fixtureSHA256=diagnostic.LEGACY_FIXTURE_SHA,
                nativeExecution=False, fullReleaseAcceptance=False)
            if defect == 'source': binding['sourceFiles']['scripts/native_pointer_guard_selftest.swift'] = 'a' * 64
            if defect == 'producer': binding['runID'] += 1
            if defect == 'attempt': binding['attempt'] = 2
            data = io.BytesIO()
            with zipfile.ZipFile(data, 'w') as zipped:
                zipped.writestr('native-pointer-guard-source/binding.json', json.dumps(binding))
                for stage in stages:
                    if defect != 'missing-' + stage:
                        zipped.writestr(diagnostic.INSPECTOR_PREFIX + stage + '.exit.json',
                            json.dumps({'exitCode': 1 if defect == stage else 0}))
                zipped.writestr(diagnostic.INSPECTOR_PREFIX + 'pointer-observer-selftest',
                    image + (b'changed' if defect == 'image' else b''))
            data.seek(0); return zipfile.ZipFile(data)
        with mock.patch.object(diagnostic, 'SELFTEST_TOOL_SHA', hashlib.sha256(image).hexdigest()), \
                mock.patch.object(diagnostic, 'SELFTEST_TOOL_BYTES', len(image)):
            with archive() as zipped: self.assertEqual(diagnostic.selftest_tool_bytes(zipped), image)
            for defect in ['source', 'producer', 'attempt', 'image', *stages, *('missing-' + stage for stage in stages)]:
                with self.subTest(defect=defect), archive(defect) as zipped, self.assertRaises(ValueError):
                    diagnostic.selftest_tool_bytes(zipped)

    def test_retained_selftest_runtime_refusal_precedes_any_acquisition(self):
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            for version in ('27.1.9', '26.9', '', 'unknown'):
                with self.subTest(version=version), \
                        mock.patch.object(diagnostic, 'checksum', return_value=diagnostic.SELFTEST_SOURCE_SHA), \
                        mock.patch.object(diagnostic.platform, 'mac_ver', return_value=(version, (), 'arm64')), \
                        mock.patch.object(diagnostic, 'api') as acquire:
                    with self.assertRaises(ValueError): diagnostic.restore_selftest_tool(evidence / 'tool', evidence)
                    acquire.assert_not_called()
                    self.assertEqual(list(evidence.iterdir()), [])

        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            with mock.patch.object(diagnostic, 'checksum', return_value=diagnostic.SELFTEST_SOURCE_SHA), \
                    mock.patch.object(diagnostic.platform, 'mac_ver', return_value=('27.2', (), 'arm64')), \
                    mock.patch.dict(diagnostic.os.environ, {'GITHUB_SHA': 'b' * 40}), \
                    mock.patch.object(diagnostic.cohort, 'objects', side_effect=[{'tool': 'a' * 40}, {'tool': 'b' * 40}]), \
                    mock.patch.object(diagnostic, 'api') as acquire:
                with self.assertRaisesRegex(ValueError, 'compiler input changed'):
                    diagnostic.restore_selftest_tool(evidence / 'tool', evidence)
                acquire.assert_not_called()
                self.assertEqual(list(evidence.iterdir()), [])

    def test_hosting_class_admission_requires_declared_and_runtime_guards(self):
        def duplicate(rows):
            eligibility = dict(rows[2], kind='eligibility', uniqueProbeMatches=False, eligible=False,
                classImageMatches=True, ownAXImageMatches=True)
            return [rows[0], rows[1], eligibility, dict(rows[-1], samples=0, rectSamples=0,
                originalCalls=0, transparentReturns=0)]
        self.assertTrue(self.verify(duplicate(self.rows()), negative='duplicate-probe')['duplicateProbeRefused'])
        unexercised = duplicate(self.rows()); unexercised[-1].update(rectCalls=0, rectReturns=0)
        with self.assertRaises(ValueError): self.verify(unexercised, negative='duplicate-probe')
        for key in ('runtimeLineageMatches', 'effectiveAXMatches', 'declaredOwnAX'):
            for value in (None, False, 1):
                rows = self.rows()
                if value is None: rows[2].pop(key)
                else: rows[2][key] = value
                with self.subTest(key=key, value=value), self.assertRaises(ValueError): self.verify(rows)
                with self.subTest(negative=key, value=value), self.assertRaises(ValueError):
                    self.verify(duplicate(rows), negative='duplicate-probe')
        for key in ('rootClass', 'runtimeRootClass', 'originalAXIMP'):
            rows = self.rows(); rows[2][key] = 'nil'
            with self.subTest(key=key), self.assertRaises(ValueError): self.verify(rows)
            if key != 'originalAXIMP':
                with self.subTest(negative=key), self.assertRaises(ValueError):
                    self.verify(duplicate(rows), negative='duplicate-probe')
        rows = self.rows(); rows[2]['rootDeclaredImageIdentity'] = dict(path='/foreign', device=2, inode=3)
        with self.assertRaises(ValueError): self.verify(rows)

    def test_boolean_wire_fields_reject_numeric_truth_values(self):
        for key in ('widthFits', 'heightFits'):
            rows = self.rows(); rows[3][key] = int(rows[3][key])
            with self.subTest(key=key), self.assertRaises(ValueError): self.verify(rows)
        rows = self.rows(); rows[4]['nativeGuardResult'] = 0
        with self.assertRaises(ValueError): self.verify(rows)
        for key in ('hitNSControl', 'hitNSTextView', 'hitHidden', 'rolePresent', 'roleNonEmpty', 'roleNotUnknown'):
            rows = self.rows(); rows[4][key] = int(rows[4][key])
            with self.subTest(native=key), self.assertRaises(ValueError): self.verify(rows)
        for key in ('screenAvailable', 'cgWindowListAvailable', 'result'):
            rows = self.rows(); rows[4]['windowGuard'][key] = int(rows[4]['windowGuard'][key])
            with self.subTest(window=key), self.assertRaises(ValueError): self.verify(rows)
        for key in self.rows()[4]['windowGuard']['predicates']:
            rows = self.rows(); rows[4]['windowGuard']['predicates'][key] = 1
            with self.subTest(windowPredicate=key), self.assertRaises(ValueError): self.verify(rows)

        rows = self.rows()
        negative = [rows[0], dict(pid=10, diagnosticOnly=True, kind='discovery', wallTime=2,
            classFound=1, imageMatches=False), dict(rows[-1], samples=0, rectSamples=0,
            originalCalls=0, transparentReturns=0, rectCalls=0, rectReturns=0)]
        with self.assertRaises(ValueError): self.verify(negative, negative=True)

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
        self.assertEqual(result['falseWindowPredicatesBySample'], [[]])
        rows = self.rows(); window = rows[4]['windowGuard']
        window['windowAtPoint'] = 999; window['predicates']['windowAtPointMatches'] = False; window['result'] = False
        self.assertEqual(self.verify(rows)['falseWindowPredicatesBySample'], [['windowAtPointMatches']])
        rows = self.rows(); window = rows[4]['windowGuard']
        window.update(cgWindows=[], matchingWindowCount=0, cgFrame=[], result=False)
        false = ['uniqueOwnWindow', 'boundsAvailable', 'boundsDecoded', 'frameFinite',
            'positiveWidth', 'positiveHeight', 'containsQuartzPoint']
        window['predicates'].update({key: False for key in false})
        self.assertEqual(self.verify(rows)['falseWindowPredicatesBySample'], [false])
        rows = self.rows(); window = rows[4]['windowGuard']
        window['cgWindows'][0]['bounds']['Width'] = 0; window['cgFrame'][2] = 0
        window['predicates'].update(positiveWidth=False, containsQuartzPoint=False); window['result'] = False
        self.assertEqual(self.verify(rows)['falseWindowPredicatesBySample'], [['positiveWidth', 'containsQuartzPoint']])
        rows = self.rows(); window = rows[4]['windowGuard']
        window['cgWindows'][0]['bounds'].update(X=100, Y=100, Width=-100, Height=-100)
        window['cgFrame'] = [100, 100, -100, -100]
        self.assertEqual(self.verify(rows)['falseWindowPredicatesBySample'], [[]])
        for bounds in ([5, 5, 0, 0], [10, 10, -10, -10]):
            rows = self.rows(); rows[4]['hitBoundsInRoot'] = bounds
            self.assertEqual(self.verify(rows)['falsePredicatesBySample'], [['nativeControlType']])
        rows = self.rows(); rows[4]['hitVisibleRect'] = [10, 10, -10, -10]
        self.assertEqual(self.verify(rows)['falsePredicatesBySample'], [['nativeControlType']])
        rows = self.rows(); rows[4]['hitPoint'] = [10, 2]; rows[4]['visibleRectContainsPoint'] = False
        self.assertEqual(self.verify(rows)['falsePredicatesBySample'], [['nativeControlType', 'visibleRectContainsPoint']])

        rows = self.rows(); rows[4]['hitAXChain'] = dict(elements=[], end='nonProtocol', completeToBoundWindow=False)
        self.assertTrue(self.verify(rows)['outputComplete'])

    def test_viewport_only_evidence_does_not_claim_the_later_target_was_measured(self):
        rows = self.rows(); rows.pop(4); rows[-1].update(samples=0, originalCalls=0, transparentReturns=0)
        measured = self.verify(rows)
        self.assertEqual(measured['samples'], 0)
        self.assertEqual(measured['rectSamples'], 1)
        self.assertEqual(measured['falsePredicatesBySample'], [])
        self.assertTrue(measured['diagnosticOnly'])
        for failure in (None, 'cleanup', 'image'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); evidence = root / 'evidence'; evidence.mkdir()
                host, image = root / 'host', root / 'tests'
                host.write_bytes(b'original-host'); image.write_bytes(b'original-tests')
                value = dict(diagnostic.fixture(), originalHostSHA256=diagnostic.checksum(host),
                    testImage={'sha256': diagnostic.checksum(image)})
                calls = []
                def collect(command, log, environment):
                    calls.append(command)
                    log.write_bytes(b'complete original console\n')
                    Path(environment['NGV_APPKIT_TEST_EVENTS']).write_bytes(b'unknown original event form\n')
                    if failure == 'image': image.write_bytes(b'changed-tests')
                    return dict(processReaped=True, eof=True, exitCode=1, stoppedReason=None,
                        cleanupSignalErrors=['failed'] if failure == 'cleanup' else [], logFinalizationErrors=[])
                with mock.patch('run_macos_tests.app_environment', side_effect=lambda *_: {}), \
                        mock.patch.object(diagnostic, 'run_owned', side_effect=collect), \
                        mock.patch.object(diagnostic, 'measure', side_effect=AssertionError('premature event semantics')), \
                        mock.patch.object(diagnostic, 'verify_snapshots', side_effect=AssertionError('premature snapshot semantics')):
                    if failure:
                        with self.assertRaises(ValueError):
                            diagnostic.collect_selections(value, evidence, root / 'runtime', image, host, root / 'inspector')
                        self.assertEqual(len(calls), 1)
                    else:
                        acquired = diagnostic.collect_selections(value, evidence, root / 'runtime', image, host, root / 'inspector')
                        self.assertEqual(list(acquired), value['diagnosticFunctionIDs'])
                        self.assertEqual(len(calls), 6)
                        for index, identity in enumerate(value['diagnosticFunctionIDs'], 1):
                            self.assertEqual(calls[index - 1][-1], diagnostic.scope_filter([identity]))
                            self.assertTrue((evidence / ('selection-' + str(index)) / 'host.STARTED.json').is_file())
                            self.assertTrue((acquired[identity]['folder'] / 'process.json').is_file())
                            self.assertFalse((acquired[identity]['snapshots'] / 'snapshots.jsonl').exists())

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
                'width-lie', 'unowned-clip', 'duplicate-probe-hook', 'native-type-lie', 'native-role-lie',
                'native-hit-bounds-lie', 'native-visible-lie', 'window-guard-lie', 'window-match-count',
                'window-owner', 'window-coordinate', 'window-frame', 'missing-window']:
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
            elif defect == 'native-type-lie': rows[4]['hitNSControl'] = True
            elif defect == 'native-role-lie': rows[4]['nativeRole'] = ''
            elif defect == 'native-hit-bounds-lie': rows[4]['hitBoundsInRoot'][2] = 100
            elif defect == 'native-visible-lie': rows[4]['hitVisibleRect'][2] = 0
            elif defect == 'window-guard-lie': rows[4]['windowGuard']['result'] = False
            elif defect == 'window-match-count': rows[4]['windowGuard']['matchingWindowCount'] = 2
            elif defect == 'window-owner': rows[4]['windowGuard']['ownerPID'] = 999
            elif defect == 'window-coordinate': rows[4]['windowGuard']['quartzPoint'][1] += 1
            elif defect == 'window-frame': rows[4]['windowGuard']['cgFrame'][2] += 1
            elif defect == 'missing-window': rows[4].pop('windowGuard')

            with self.subTest(defect=defect), self.assertRaises(ValueError): self.verify(rows, defect == 'truncated')
