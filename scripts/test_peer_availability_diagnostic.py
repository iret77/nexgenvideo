from pathlib import Path
import copy
import json
import signal
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import peer_availability_diagnostic as diagnostic


class PeerAvailabilityInputTests(unittest.TestCase):
    def setUp(self):
        self.env = dict(KIND=diagnostic.KIND, CANDIDATE_RUN=str(diagnostic.RUN),
            CANDIDATE_SOURCE=diagnostic.SOURCE, CANDIDATE_ARTIFACT=str(diagnostic.ARTIFACT),
            CANDIDATE_DIGEST=diagnostic.DIGEST, VERIFIED_PR='12', SCALE='1',
            EXTRA_FAILURE=str(diagnostic.RESUME_ARTIFACT), EXTRA_FAILURE_SHA=diagnostic.RESUME_DIGEST)

    def test_exact_original_identity_is_required_field_by_field(self):
        diagnostic.validate_inputs(self.env)
        for field in ('KIND', 'CANDIDATE_RUN', 'CANDIDATE_SOURCE', 'CANDIDATE_ARTIFACT', 'CANDIDATE_DIGEST'):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'Exact Native777'):
                diagnostic.validate_inputs(dict(self.env, **{field: 'different'}))

    def test_every_unconsumed_continuation_selector_is_rejected(self):
        for field in ('DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST',
                      'EXTRA_SOURCE', 'EXTRA_PRODUCTS', 'EXTRA_PRODUCTS_SHA',
                      'RUNTIME_FAILURE_BINDING', 'PACKAGING_PRODUCER_SOURCE',
                      'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256'):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'cannot be ignored'):
                diagnostic.validate_inputs(dict(self.env, **{field: 'unexpected'}))

    def test_current_source_receipt_and_scale_cannot_be_missing_or_malformed(self):
        for field, value in [('VERIFIED_PR', ''), ('VERIFIED_PR', '0'), ('VERIFIED_PR', ' 12'),
                             ('VERIFIED_PR', '1.2'), ('SCALE', 'all'), ('SCALE', '1.5')]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(self.env, **{field: value}))

    def test_missing_partial_or_wrong_retained_pair_cannot_repeat_passed_compilation(self):
        for changes in ({'EXTRA_FAILURE': '', 'EXTRA_FAILURE_SHA': ''}, {'EXTRA_FAILURE': ''},
                        {'EXTRA_FAILURE_SHA': ''}, {'EXTRA_FAILURE': '1'}, {'EXTRA_FAILURE_SHA': 'a' * 64}):
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, 'Exact Native785'):
                diagnostic.validate_inputs(dict(self.env, **changes))
        for field in ('EXTRA_FAILURE', 'EXTRA_FAILURE_SHA'):
            missing = dict(self.env)
            del missing[field]
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'Exact Native785'):
                diagnostic.validate_inputs(missing)


class PeerAvailabilityResumeTests(unittest.TestCase):
    def producer(self):
        times = {diagnostic.RESUME_SOURCE_JOB: ('2026-11-06T16:28:42Z', '2026-11-06T16:28:58Z'),
                 diagnostic.RESUME_JOB: ('2026-11-06T16:29:17Z', '2026-11-06T16:29:52Z')}
        run = dict(id=diagnostic.RESUME_RUN, head_sha=diagnostic.RESUME_SOURCE, run_attempt=1,
            repository=dict(full_name='iret77/nexgenvideo'), actor=dict(login='iret77'), workflow_id=355242770,
            path='.github/workflows/diagnostic-acceptance.yml', event='workflow_dispatch',
            status='completed', conclusion='failure')
        jobs = dict(total_count=2, jobs=[dict(id=identity, run_id=diagnostic.RESUME_RUN,
            head_sha=diagnostic.RESUME_SOURCE, run_attempt=1, name=name, status='completed',
            conclusion=conclusion, labels=labels, started_at=times[identity][0], completed_at=times[identity][1])
            for identity, name, conclusion, labels in [
                (diagnostic.RESUME_SOURCE_JOB, 'source', 'success', ['ubuntu-24.04']),
                (diagnostic.RESUME_JOB, diagnostic.KIND, 'failure', ['macrunner'])]])
        artifacts = {identity: dict(id=identity, name=name, digest='sha256:' + checksum, size_in_bytes=size,
            expired=False, expires_at='2099-01-01T00:00:00Z',
            created_at='2026-11-06T16:29:48Z' if identity == diagnostic.RESUME_ARTIFACT else '2026-11-06T16:28:56Z',
            updated_at='2026-11-06T16:29:48Z' if identity == diagnostic.RESUME_ARTIFACT else '2026-11-06T16:28:56Z',
            workflow_run=dict(id=diagnostic.RESUME_RUN, head_sha=diagnostic.RESUME_SOURCE))
            for identity, name, checksum, size in [
                (diagnostic.RESUME_ARTIFACT, diagnostic.KIND + '-' + str(diagnostic.RESUME_RUN) + '-a1',
                    diagnostic.RESUME_DIGEST, 77022),
                (diagnostic.RESUME_BINDING_ARTIFACT, diagnostic.KIND + '-source-binding',
                    diagnostic.RESUME_BINDING_DIGEST, 2346935)]}
        return run, jobs, artifacts

    def test_retained_producer_requires_exact_run_source_jobs_artifacts_and_lifetimes(self):
        diagnostic.resume_producer(*self.producer())
        for key, wrong in [('id', 1), ('head_sha', 'a' * 40), ('run_attempt', 2),
                           ('workflow_id', 1), ('path', 'other'), ('event', 'push'),
                           ('status', 'in_progress'), ('conclusion', 'success'),
                           ('repository', dict(full_name='other/repo')), ('actor', dict(login='other'))]:
            run, jobs, artifacts = self.producer()
            run[key] = wrong
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'Native785 producer'):
                diagnostic.resume_producer(run, jobs, artifacts)
        for index in (0, 1):
            for key, wrong in [('id', 1), ('run_id', 1), ('head_sha', 'a' * 40), ('run_attempt', 2),
                               ('name', 'other'), ('labels', ['macos-latest']),
                               ('status', 'in_progress'), ('conclusion', 'skipped')]:
                run, jobs, artifacts = self.producer()
                jobs['jobs'][index][key] = wrong
                with self.subTest(index=index, key=key), self.assertRaises(ValueError):
                    diagnostic.resume_producer(run, jobs, artifacts)
        for identity in (diagnostic.RESUME_ARTIFACT, diagnostic.RESUME_BINDING_ARTIFACT):
            for key, wrong in [('id', 1), ('name', 'other'), ('digest', 'sha256:' + 'a' * 64),
                               ('size_in_bytes', 1), ('expired', True), ('expires_at', '2000-01-01T00:00:00Z'),
                               ('workflow_run', dict(id=1, head_sha=diagnostic.RESUME_SOURCE))]:
                run, jobs, artifacts = self.producer()
                artifacts[identity][key] = wrong
                with self.subTest(identity=identity, key=key), self.assertRaises(ValueError):
                    diagnostic.resume_producer(run, jobs, artifacts)
        run, jobs, artifacts = self.producer()
        jobs['total_count'] += 1
        with self.assertRaisesRegex(ValueError, 'jobs incomplete'):
            diagnostic.resume_producer(run, jobs, artifacts)
        for index in (0, 1):
            for field in ('started_at', 'completed_at'):
                for wrong in (None, '', 'invalid', '2026-11-06T16:28:30', '2099-01-01T00:00:00Z'):
                    run, jobs, artifacts = self.producer()
                    jobs['jobs'][index][field] = wrong
                    with self.subTest(index=index, field=field, wrong=wrong), self.assertRaises(ValueError):
                        diagnostic.resume_producer(run, jobs, artifacts)
                run, jobs, artifacts = self.producer()
                del jobs['jobs'][index][field]
                with self.subTest(index=index, missing=field), self.assertRaises(ValueError):
                    diagnostic.resume_producer(run, jobs, artifacts)
            run, jobs, artifacts = self.producer()
            job = jobs['jobs'][index]
            job['started_at'], job['completed_at'] = job['completed_at'], job['started_at']
            with self.subTest(index=index, reversed=True), self.assertRaises(ValueError):
                diagnostic.resume_producer(run, jobs, artifacts)
        run, jobs, artifacts = self.producer()
        jobs['jobs'][0]['completed_at'] = '2026-11-06T16:29:30Z'
        with self.assertRaisesRegex(ValueError, 'job order'):
            diagnostic.resume_producer(run, jobs, artifacts)
        for identity in (diagnostic.RESUME_ARTIFACT, diagnostic.RESUME_BINDING_ARTIFACT):
            for field in ('created_at', 'updated_at'):
                for wrong in (None, '', 'invalid', '2026-11-06T16:28:00Z', '2026-11-06T16:30:00Z'):
                    run, jobs, artifacts = self.producer()
                    artifacts[identity][field] = wrong
                    with self.subTest(identity=identity, field=field, wrong=wrong), self.assertRaises(ValueError):
                        diagnostic.resume_producer(run, jobs, artifacts)
                run, jobs, artifacts = self.producer()
                del artifacts[identity][field]
                with self.subTest(identity=identity, missing=field), self.assertRaises(ValueError):
                    diagnostic.resume_producer(run, jobs, artifacts)
            run, jobs, artifacts = self.producer()
            artifacts[identity]['created_at'] = ('2026-11-06T16:29:49Z' if identity == diagnostic.RESUME_ARTIFACT
                                               else '2026-11-06T16:28:57Z')
            with self.subTest(identity=identity, reversed=True), self.assertRaises(ValueError):
                diagnostic.resume_producer(run, jobs, artifacts)

    def test_retained_product_hash_size_architecture_and_file_type_are_independent_requirements(self):
        raw = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 1, 0, 0, 0, 0)
        expected = dict(bytes=len(raw), SHA256=diagnostic.digest(raw), machOType=1)
        diagnostic.retained_product(raw, expected)
        for changed, binding in [(raw + b'x', expected), (raw, dict(expected, bytes=1)),
                                 (raw, dict(expected, SHA256='a' * 64)), (raw, dict(expected, machOType=2))]:
            with self.subTest(binding=binding), self.assertRaises(ValueError):
                diagnostic.retained_product(changed, binding)
        foreign = struct.pack('<8I', 0xfeedfacf, 0x01000007, 0, 1, 0, 0, 0, 0)
        with self.assertRaisesRegex(ValueError, 'Mach-O type'):
            diagnostic.retained_product(foreign, dict(expected, SHA256=diagnostic.digest(foreign)))

    def test_retained_compiler_recipe_and_prior_lifetime_cannot_be_relabelled_as_current(self):
        command, log = ['selected-prior-compiler', '-o', 'retained'], b''
        receipt = dict(command=command, PID=7, parentPID=6, exitCode=0, timedOut=False, processReaped=True,
            separateStderr=False, stderrFile=None, stderrSHA256=None, stdoutSHA256=diagnostic.digest(log),
            started=1, finished=2, startedWall=100, finishedWall=101, timeout=70)
        diagnostic.retained_process(receipt, command, log, 6)
        for key, wrong in [('command', ['new-compiler']), ('exitCode', 1), ('timedOut', True),
                           ('processReaped', False), ('PID', True), ('parentPID', 9), ('separateStderr', True),
                           ('stderrFile', 'other'), ('stdoutSHA256', 'a' * 64), ('finished', 100),
                           ('startedWall', float('nan')), ('timeout', 71)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.retained_process(dict(receipt, **{key: wrong}), command, log, 6)
        with self.assertRaises(ValueError):
            diagnostic.retained_process(receipt, command, b'changed', 6)

    def test_wrong_or_partial_original_archives_fail_before_any_product_is_restored(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / 'retained-native.zip').write_bytes(b'not-the-qualified-artifact')
            with self.assertRaisesRegex(ValueError, 'Exact retained archive bytes'):
                diagnostic.resume_archives(folder, {}, b'', {})
            self.assertEqual(list(folder.glob('*.product.json')), [])


class PeerAvailabilityPluginTests(unittest.TestCase):
    def fixture(self, folder):
        compiler = folder / 'Toolchain/usr/bin/swiftc'
        compiler.parent.mkdir(parents=True)
        compiler.write_bytes(b'selected compiler')
        resource = compiler.parent.parent / 'lib/swift'
        library = resource / 'host/plugins/testing/libTestingMacros.dylib'
        library.parent.mkdir(parents=True)
        library.write_bytes(b'actual plugin bytes')
        value = dict(compilerVersion=diagnostic.SWIFT_VERSION,
            target=dict(triple='arm64-apple-macosx26.0'), paths=dict(runtimeResourcePath=str(resource)))
        return compiler, library, value

    def test_macro_metadata_binds_selected_toolchain_and_actual_library_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            compiler, library, value = self.fixture(Path(temporary))
            result = diagnostic.plugin_metadata(json.dumps(value), compiler)
            self.assertEqual(result['compiler'], str(compiler))
            self.assertEqual(result['compilerSHA256'], diagnostic.digest(compiler.read_bytes()))
            self.assertEqual(result['pluginDirectory'], str(library.parent))
            self.assertEqual(result['pluginSHA256'], diagnostic.digest(library.read_bytes()))

    def test_missing_malformed_foreign_duplicate_or_nonfinite_metadata_is_rejected(self):
        for mutation in ('version', 'target', 'resource', 'relative', 'missing', 'empty', 'duplicate', 'nan', 'merged'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                compiler, library, value = self.fixture(Path(temporary))
                if mutation == 'version': value['compilerVersion'] = 'other'
                elif mutation == 'target': value['target']['triple'] = 'x86_64-apple-macosx26.0'
                elif mutation == 'resource': value['paths']['runtimeResourcePath'] = str(library.parent)
                elif mutation == 'relative': value['paths']['runtimeResourcePath'] = 'lib/swift'
                elif mutation == 'missing': library.rename(library.with_suffix('.retained'))
                elif mutation == 'empty': library.write_bytes(b'')
                raw = json.dumps(value)
                if mutation == 'duplicate': raw = raw[:-1] + ', "paths": {}}'
                elif mutation == 'nan': raw = raw[:-1] + ', "invalid": NaN}'
                elif mutation == 'merged': raw = 'swift-driver version: 1.168.6\n' + raw
                with self.assertRaises((ValueError, FileNotFoundError)):
                    diagnostic.plugin_metadata(raw, compiler)

    def test_symlinked_foreign_macro_library_cannot_escape_the_selected_toolchain(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            compiler, library, value = self.fixture(folder)
            foreign = folder / 'foreign.dylib'
            library.rename(foreign)
            library.symlink_to(foreign)
            with self.assertRaisesRegex(ValueError, 'missing or escaped'):
                diagnostic.plugin_metadata(json.dumps(value), compiler)


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


class PeerAvailabilityIdentityTests(unittest.TestCase):
    expected = 'Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)\nTarget: arm64-apple-macosx27.2.0'
    driver = 'swift-driver version: 1.168.6 '

    def command(self, stdout):
        return [sys.executable, '-c',
            'import sys; sys.stderr.write(' + repr(self.driver) + '); sys.stderr.flush(); '
            'sys.stdout.write(' + repr(stdout + '\n') + '); sys.stdout.flush()']

    def test_identity_compares_real_stdout_and_retains_the_separate_driver_diagnostic(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            result = diagnostic.Controller(folder).identity(self.command(self.expected), 'swift', self.expected)
            self.assertEqual((folder / result['stdoutFile']).read_text(), self.expected + '\n')
            self.assertEqual((folder / result['stderrFile']).read_text(), self.driver)
            self.assertTrue(result['separateStderr'])
            self.assertTrue(result['processReaped'])
            for prefix in ('stdout', 'stderr'):
                self.assertEqual(result[prefix + 'SHA256'],
                    diagnostic.digest((folder / result[prefix + 'File']).read_bytes()))

    def test_separate_driver_output_cannot_qualify_a_wrong_compiler_version_or_target(self):
        mutations = [self.expected.replace('6.4.2', '6.4.3'), self.expected.replace('arm64', 'x86_64'),
            self.driver + self.expected]
        for value in mutations:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as temporary:
                folder = Path(temporary)
                with self.assertRaisesRegex(ValueError, 'Actual native toolchain differs'):
                    diagnostic.Controller(folder).identity(self.command(value), 'swift', self.expected)
                self.assertEqual((folder / 'toolchain-swift.log').read_text(), value + '\n')
                self.assertEqual((folder / 'toolchain-swift.stderr').read_text(), self.driver)

    def test_timed_out_identity_retains_both_closed_channels_and_its_failed_process_receipt(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(diagnostic.subprocess, 'Popen') as spawn, \
                patch.object(diagnostic.os, 'killpg'):
            child = spawn.return_value
            child.pid = 77
            child.wait.side_effect = [subprocess.TimeoutExpired('identity', 70),
                subprocess.TimeoutExpired('identity', 2), -9]
            child.poll.return_value = -9
            folder = Path(temporary)
            with self.assertRaisesRegex(ValueError, 'original evidence retained'):
                diagnostic.Controller(folder).identity(['identity'], 'swift', self.expected)
            result = json.loads((folder / 'toolchain-swift.process.json').read_text())
            self.assertTrue(result['timedOut'])
            self.assertTrue(result['processReaped'])
            self.assertEqual(result['exitCode'], -9)
            self.assertTrue(spawn.call_args.kwargs['stdout'].closed)
            self.assertTrue(spawn.call_args.kwargs['stderr'].closed)
            for prefix in ('stdout', 'stderr'):
                self.assertEqual((folder / result[prefix + 'File']).read_bytes(), b'')
                self.assertEqual(result[prefix + 'SHA256'], diagnostic.digest(b''))


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
