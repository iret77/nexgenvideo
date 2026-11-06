from pathlib import Path
import copy
import json
import signal
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import peer_availability_diagnostic as diagnostic


class PeerAvailabilityInputTests(unittest.TestCase):
    def setUp(self):
        self.env = dict(KIND=diagnostic.KIND, CANDIDATE_RUN=str(diagnostic.RUN),
            CANDIDATE_SOURCE=diagnostic.SOURCE, CANDIDATE_ARTIFACT=str(diagnostic.ARTIFACT),
            CANDIDATE_DIGEST=diagnostic.DIGEST, VERIFIED_PR='12', SCALE='1')

    def test_exact_original_identity_is_required_field_by_field(self):
        diagnostic.validate_inputs(self.env)
        for field in ('KIND', 'CANDIDATE_RUN', 'CANDIDATE_SOURCE', 'CANDIDATE_ARTIFACT', 'CANDIDATE_DIGEST'):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'Exact Native777'):
                diagnostic.validate_inputs(dict(self.env, **{field: 'different'}))

    def test_every_unconsumed_continuation_selector_is_rejected(self):
        for field in ('DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST',
                      'EXTRA_SOURCE', 'EXTRA_PRODUCTS', 'EXTRA_PRODUCTS_SHA', 'EXTRA_FAILURE',
                      'EXTRA_FAILURE_SHA', 'RUNTIME_FAILURE_BINDING', 'PACKAGING_PRODUCER_SOURCE',
                      'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256'):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'cannot be ignored'):
                diagnostic.validate_inputs(dict(self.env, **{field: 'unexpected'}))

    def test_current_source_receipt_and_scale_cannot_be_missing_or_malformed(self):
        for field, value in [('VERIFIED_PR', ''), ('VERIFIED_PR', '0'), ('VERIFIED_PR', ' 12'),
                             ('VERIFIED_PR', '1.2'), ('SCALE', 'all'), ('SCALE', '1.5')]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(self.env, **{field: value}))


class PeerAvailabilityScopeTests(unittest.TestCase):
    def test_fixture_keeps_its_actual_window_init_content_request_and_close(self):
        original = (diagnostic.ROOT / diagnostic.FIXTURE).read_bytes()
        selected, ranges = diagnostic.fixture_subset(original)
        self.assertEqual(selected, b''.join(original[a:b] for a, b in ranges))
        self.assertIn(b'let window = NSWindow(contentRect:', selected)
        self.assertIn(b'window.contentView = NSHostingView(rootView:', selected)
        self.assertIn(b'.buttonStyle(.capsule())', selected)
        self.assertIn(b'windowFrame:', selected)
        self.assertIn(b'contentFrame:', selected)
        self.assertIn(b'func close()', selected)
        self.assertNotIn(b'func ready(', selected)
        self.assertNotIn(b'@Test', selected)

    def test_missing_duplicate_or_reordered_fixture_boundaries_fail_closed(self):
        original = (diagnostic.ROOT / diagnostic.FIXTURE).read_bytes()
        marker = b'    @MainActor private final class Fixture {'
        following = b'    @MainActor private final class LastChildRoot: NSView {'
        for bad in (original.replace(marker, b'changed', 1), original + marker,
                    original.replace(following, b'changed', 1), original + following,
                    b'        func ready(using session: NativeAXPeer.Session)' + original.replace(
                        b'        func ready(using session: NativeAXPeer.Session)', b'changed', 1)):
            with self.subTest(data=bad[:40]), self.assertRaises(ValueError):
                diagnostic.fixture_subset(bad)

    def test_identical_sibling_close_is_excluded_but_duplicate_inside_fixture_is_rejected(self):
        original = (diagnostic.ROOT / diagnostic.FIXTURE).read_bytes()
        close = b'        func close() { window.contentView = nil; window.close() }\n    }'
        following = b'    @MainActor private final class LastChildRoot: NSView {'
        self.assertEqual(original.count(close), 2)
        selected, ranges = diagnostic.fixture_subset(original)
        self.assertEqual(selected.count(close), 1)
        self.assertLessEqual(ranges[-1][1], original.index(following))
        appended = original + b'\n    @MainActor private final class AnotherFixture {\n' + close
        self.assertEqual(diagnostic.fixture_subset(appended), (selected, ranges))
        split = original.index(following)
        duplicated = original[:split] + close + original[split:]
        with self.assertRaisesRegex(ValueError, 'Fixture ranges changed'):
            diagnostic.fixture_subset(duplicated)

    def test_absolute_budget_clips_commands_and_retains_cleanup_reserve(self):
        self.assertEqual(diagnostic.command_timeout(210, 0), 70)
        self.assertEqual(diagnostic.command_timeout(210, 185), 15)
        for now in (200, 201, 210, 211):
            with self.subTest(now=now), self.assertRaisesRegex(ValueError, 'reserve cleanup'):
                diagnostic.command_timeout(210, now)

    def test_actual_host_and_reader_are_inputs_not_permitted_change_paths(self):
        diagnostic.validate_changed_paths([])
        diagnostic.validate_changed_paths(sorted(diagnostic.HARNESS))
        for name in (diagnostic.HOST, diagnostic.SUPPORT, diagnostic.HEADER, diagnostic.QUERY, diagnostic.PEER):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'App or unrelated source'):
                diagnostic.validate_changed_paths([*diagnostic.HARNESS, name])

    def test_raw_output_cannot_enter_a_report_without_a_complete_diagnostic_collection(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / 'observation.json').write_text('{"schema":"nexgenvideo/peer-availability-observation/1",'
                '"context":"default","collectionCompleted":false}')
            with self.assertRaisesRegex(ValueError, 'Incomplete diagnostic collection'):
                diagnostic.verify_collection(folder, 'default', {})

    def test_timed_out_owned_command_is_killed_reaped_and_recorded_before_failure(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(diagnostic.subprocess, 'Popen') as spawn, \
                patch.object(diagnostic.os, 'killpg') as kill:
            child = spawn.return_value
            child.pid = 77
            child.wait.side_effect = [subprocess.TimeoutExpired('owned', 70),
                subprocess.TimeoutExpired('owned', 2), -9]
            child.poll.return_value = -9
            controller = diagnostic.Controller(Path(temporary))
            with self.assertRaisesRegex(ValueError, 'original evidence retained'):
                controller.run(['owned-diagnostic'], 'owned')
            self.assertEqual(kill.call_args_list[0].args, (77, signal.SIGTERM))
            self.assertEqual(kill.call_args_list[1].args, (77, signal.SIGKILL))
            receipt = json.loads((Path(temporary) / 'owned.process.json').read_text())
            self.assertTrue(receipt['processReaped'])
            self.assertTrue(receipt['timedOut'])
            self.assertEqual(receipt['exitCode'], -9)
            self.assertEqual(spawn.call_args.kwargs['stdin'], subprocess.DEVNULL)


class PeerAvailabilityCollectionTests(unittest.TestCase):
    def populate(self, folder):
        products = {}
        for name, byte in [('bundle', 17), ('host', 34), ('raw', 51)]:
            path = folder / (name + '.bin')
            raw = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0)
            raw += struct.pack('<II', 0x1b, 24) + bytes([byte]) * 16
            path.write_bytes(raw)
            products[name] = dict(path=str(path.resolve()), SHA256=diagnostic.digest(raw), uuid=(bytes([byte]) * 16).hex())
        execution = dict(sourceSHA='f' * 40, products=products, process=dict(PID=42, parentPID=41,
            processReaped=True, exitCode=0, timedOut=False, startedWall=1000, finishedWall=1010,
            command=[products['host']['path'], '--event-stream-version', '0']))
        request = dict(PID=42, windowNumber=50, windowFrame=[1, 2, 30, 40], contentFrame=[1, 2, 30, 20])
        reader = dict(ownerPID=42, readerPID=43, ownerStart=123, AXTrusted=True,
            image=products['bundle']['path'], imageSHA256=products['bundle']['SHA256'], imageUUID=products['bundle']['uuid'])
        peer = dict(before=dict(at=1), after=dict(at=3), snapshot=dict(pid=42,
            expectedWindowFrame=request['windowFrame'], contentFrame=request['contentFrame'],
            startedUptime=2, finishedUptime=2.2, reader=reader),
            lifecycle=dict(pid=43, processReaped=True, exitStatus=0, forced=False,
                stdoutClosed=True, stderrClosed=True, protocolClean=True))
        raw = []
        for index, (context, seconds) in enumerate([('background', '0.15'), ('main', '0.15'), ('background', '1')]):
            stem = context + '-' + seconds
            before = 4 + index
            item = dict(kind='raw-after-peer', primedContext=True, context=context, seconds=seconds,
                PID=44 + index, timedOut=False, cancelled=False, reaped=True, exitStatus=0,
                before=dict(at=before), after=dict(at=before + 0.9), stdout=stem + '.stdout', stderr=stem + '.stderr')
            observed = dict(schema='nexgenvideo/peer-availability-raw/1', targetPID=42, parentPID=42,
                readerPID=44 + index, readerStart=200 + index, ownerStart=123, context=context,
                mainThread=context == 'main', AXTrustedBefore=True, AXTrustedAfter=True, AXTrusted=True,
                requestedWindow=50, requestedFrame=request['windowFrame'], seconds=float(seconds),
                started=before + 0.1, finished=before + 0.8, timeoutStatus=0, AXWindowsStatus=-25204,
                readerExecutable=products['raw']['path'], imagePath=products['raw']['path'],
                imageSHA256=products['raw']['SHA256'], imageUUID=products['raw']['uuid'],
                ownerExecutable=products['host']['path'], ownerSHA256=products['host']['SHA256'],
                AXWindowsCall=dict(attribute='AXWindows', status=-25204, timeoutStatus=0,
                    started=before + 0.2, finished=before + 0.7), windows=[], CGWindows=[])
            (folder / item['stdout']).write_text(json.dumps(observed) + '\n')
            (folder / item['stderr']).write_text('')
            raw.append(item)
        events = [dict(kind='test', payload=dict(kind='function', id='PeerAvailability/collectPeerAvailability()'))]
        for kind in ('runStarted', 'testStarted', 'testEnded', 'runEnded'):
            events.append(dict(kind='event', payload=dict(kind=kind, testID='PeerAvailability/collectPeerAvailability()')))
        (folder / 'events.jsonl').write_text(''.join(json.dumps(value) + '\n' for value in events))
        (folder / 'host-receipt.json').write_text(json.dumps(dict(pid=42, started=True, completed=True,
            abiSucceeded=True, runReturnedAfterCompletion=True, applicationRunningAtStart=True, eventRecordCount=len(events),
            mainThread=True, parentPID=41, sourceSHA=execution['sourceSHA'], hostExecutable=products['host']['path'],
            bundleBinary=products['bundle']['path'])))
        report = dict(schema='nexgenvideo/peer-availability-observation/1', context='default', PID=42,
            parentPID=41, startedWall=1001, finishedWall=1009,
            collectionCompleted=True, appAcceptance=False, originalFullAppImage=False, diagnosticFunctionExecutions=1,
            requestBefore=request, requestAfterPeer=request, firstPeer=peer, rawAfterPeer=raw,
            owner=dict(PID=42, start=123, executable=products['host']['path']),
            image={**products['bundle']}, hostImage={**products['host']},
            launch=dict(**{'class': 'NGVTestRuntimeApplication'}, initialPolicy=2, actualPolicy=2,
                isRunning=True, isFinishedLaunching=True, bundleURL=str(folder), runLoopMode='kCFRunLoopDefaultMode'),
            preAXCGStability=dict(qualified=True, samples=[dict(at=instant, request=request,
                windows=[dict(pid=42, number=50, frame=request['windowFrame'], onscreen=True)]) for instant in (0.1, 0.2)]),
            heartbeat=dict(truncated=False, installedAt=0.05, recordedAt=7.9, observerValid=True,
                observerOnMainCommonModes=True, timeline=[dict(kind='dispatch', at=0.15, mainThread=True,
                    mode='kCFRunLoopDefaultMode', activity=0)]))
        (folder / 'observation.json').write_text(json.dumps(report))
        return report, execution

    def test_real_ax_failure_is_a_measured_result_and_untrusted_raw_is_explicitly_unqualified(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            _, execution = self.populate(folder)
            result = diagnostic.verify_collection(folder, 'default', execution)
            self.assertTrue(all(item['status'] == 'APP_AX_AVAILABILITY_ONLY' for item in result['rawComparisons']))
            path = folder / 'background-0.15.stdout'
            value = json.loads(path.read_text())
            value.update(AXTrustedBefore=False, AXTrusted=False)
            path.write_text(json.dumps(value) + '\n')
            self.assertEqual(diagnostic.verify_collection(folder, 'default', execution)['rawComparisons'][0]['status'],
                'UNQUALIFIED_RAW_CLIENT_TRUST')
            value.update(AXTrustedBefore=True, AXTrusted=True, AXWindowsStatus=0)
            value['AXWindowsCall']['status'] = 0
            value['windows'] = [dict(PID=42, PIDStatus=0, role='AXWindow', frame=[1, 2, 30, 40], matchesRequestedFrame=True)]
            value['CGWindows'] = [dict(PID=42, number=50, onscreen=True, bounds=dict(X=1, Y=2, Width=30, Height=40))]
            path.write_text(json.dumps(value) + '\n')
            self.assertEqual(diagnostic.verify_collection(folder, 'default', execution)['rawComparisons'][0]['status'],
                'WINDOW_BOUND_OBSERVATION_ONLY')
            value['CGWindows'].append(dict(PID=None, number=None, onscreen=None, bounds=None, unknownOwner=True))
            path.write_text(json.dumps(value) + '\n')
            self.assertEqual(diagnostic.verify_collection(folder, 'default', execution)['rawComparisons'][0]['status'],
                'APP_AX_AVAILABILITY_ONLY')

    def test_wrong_lifetime_partial_frames_and_nan_times_cannot_qualify_collection(self):
        for mutation in ('trailing', 'owner', 'nan', 'host-pid', 'source', 'samples', 'timeline', 'image',
                         'unreaped', 'missing-report', 'product-uuid', 'product-file', 'observer', 'stale-host'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary)
                report, execution = self.populate(folder)
                path = folder / 'background-0.15.stdout'
                value = json.loads(path.read_text())
                if mutation == 'trailing':
                    path.write_text(path.read_text() + '{"partial":')
                elif mutation in ('owner', 'nan'):
                    value['ownerStart' if mutation == 'owner' else 'started'] = 999 if mutation == 'owner' else float('nan')
                    path.write_text(json.dumps(value) + '\n')
                else:
                    if mutation == 'host-pid': execution['process']['PID'] = 999
                    elif mutation == 'source': execution['sourceSHA'] = 'e' * 40
                    elif mutation == 'samples': report['preAXCGStability']['samples'] = []
                    elif mutation == 'timeline': report['heartbeat']['timeline'] = []
                    elif mutation == 'image': report['hostImage']['uuid'] = 'a' * 32
                    elif mutation == 'unreaped': report['firstPeer']['lifecycle']['processReaped'] = False
                    elif mutation == 'product-uuid': execution['products']['host']['uuid'] = 'a' * 32
                    elif mutation == 'product-file':
                        file = Path(execution['products']['host']['path'])
                        file.write_bytes(file.read_bytes() + b'changed')
                    elif mutation == 'observer': report['heartbeat']['observerValid'] = False
                    elif mutation == 'stale-host': execution['process']['startedWall'] = 1005
                    if mutation != 'missing-report':
                        (folder / 'observation.json').write_text(json.dumps(report))
                    else:
                        (folder / 'observation.json').rename(folder / 'retained-report.json')
                with self.assertRaises((ValueError, FileNotFoundError)):
                    diagnostic.verify_collection(folder, 'default', execution)

    def test_unknown_ax_or_cg_rivals_and_a_foreign_window_number_prevent_window_binding(self):
        request = dict(PID=42, windowNumber=50, windowFrame=[1, 2, 30, 40])
        observed = dict(windows=[dict(PID=42, PIDStatus=0, role='AXWindow', frame=[1, 2, 30, 40],
            matchesRequestedFrame=True)], CGWindows=[dict(PID=42, number=50, onscreen=True,
                bounds=dict(X=1, Y=2, Width=30, Height=40))])
        self.assertTrue(diagnostic.raw_window_bound(observed, request))
        for mutation in ('unknown-ax', 'unknown-cg', 'unknown-owner-cg', 'duplicate-cg', 'foreign-id'):
            changed = copy.deepcopy(observed)
            if mutation == 'unknown-ax':
                changed['windows'].append(dict(PID=42, PIDStatus=0, role='AXWindow', frame=None))
            elif mutation == 'unknown-cg':
                changed['CGWindows'].append(dict(PID=42, number=51, onscreen=True, bounds=None))
            elif mutation == 'unknown-owner-cg':
                changed['CGWindows'].append(dict(PID=None, number=None, onscreen=None, bounds=None, unknownOwner=True))
            elif mutation == 'duplicate-cg':
                changed['CGWindows'].append(dict(changed['CGWindows'][0], number=51))
            else:
                changed['CGWindows'][0]['number'] = 51
            with self.subTest(mutation=mutation):
                self.assertFalse(diagnostic.raw_window_bound(changed, request))
