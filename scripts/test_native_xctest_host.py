import copy
import tempfile
import unittest
from pathlib import Path

import native_xctest_host as host


class NativeXCTestHostTests(unittest.TestCase):
    def fixture(self, root):
        bundle = root / 'NexGenVideoTests.xctest'
        executable = bundle / 'Contents/Helpers' / host.HOST_NAME
        image = str(bundle / 'Contents/MacOS/NexGenVideoTests')
        runtime = str(bundle / 'Contents/Frameworks/XCTestCore.framework/Versions/A/XCTestCore')
        ids = ['-[NexGenVideoTests.NativeCase first]', '-[NexGenVideoTests.NativeCase second]']
        identities = {name: {'name': name, 'class': 'NexGenVideoTests.NativeCase',
            'method': name.split(' ', 1)[1][:-1], 'reportedName': name.replace('NexGenVideoTests.', ''),
            'image': image} for name in ids}
        observations = {name: {'class': row['class'], 'image': image, 'reportedName': row['reportedName'],
            'identity': copy.deepcopy(row), 'invocationPresent': True, 'invocationSelector': row['method'],
            'respondsToInvocationSelector': True, 'observationError': None, 'rejectionReason': None}
            for name, row in identities.items()}
        run = {'executionCount': 1, 'skipCount': 0, 'totalFailureCount': 0, 'hasSucceeded': True}
        events = []
        def event(kind, name, *, count=None, is_root=False):
            events.append({'schema': 'native-xctest-observation/v1', 'kind': kind, 'name': name,
                'pid': 123, 'executing': True, 'root': is_root,
                'detail': {'caseIdentity': copy.deepcopy(identities[name]), 'caseObservation': copy.deepcopy(observations[name])}
                    if kind.startswith('testCase') else {},
                'run': dict(run, executionCount=count) if count is not None else None})
        event('testSuiteWillStart', 'root', is_root=True)
        for name in ids:
            event('testCaseWillStart', name)
            event('testCaseDidFinish', name, count=1)
        event('testSuiteDidFinish', 'root', count=2, is_root=True)
        receipt = {'schema': 'native-xctest-host/v1', 'sourceSHA': 'a' * 40, 'pid': 123, 'parentPID': 99,
            'bundlePath': str(bundle), 'hostPath': str(executable), 'loadedHostImage': str(executable), 'bundleImagePath': image,
            'passed': True, 'boundary': 'suite-returned', 'mainThread': True, 'applicationRunningAtStart': True,
            'executionScheduler': 'main-cf-run-loop', 'mainQueueAdmission': {'completed': True, 'pid': 123,
                'mainThread': True, 'applicationRunning': True, 'suiteExecuting': False,
                'startedUptime': 100.0, 'deadlineUptime': 105.0, 'completedUptime': 101.0, 'checkedUptime': 101.1},
            'rootSuiteStarted': 1, 'rootSuiteCompleted': 1, 'executionCount': 2, 'skipCount': 0,
            'totalFailureCount': 0, 'hasSucceeded': True, 'prematureExecutionCount': 0, 'issueCount': 0, 'expectedFailureCount': 0,
            'recordingError': None, 'error': None, 'failedIDs': [], 'inventoryIDs': ids,
            'startedIDs': ids, 'endedIDs': ids, 'passedIDs': ids,
            'leafClasses': list(identities.values()),
            'caseObservations': list(observations.values()), 'discoveredTestCaseCount': len(ids),
            'runtimeImagesBefore': [runtime], 'runtimeImagesAfterLoad': [runtime], 'runtimeImagesAfter': [runtime],
            'caseRuntimeImage': runtime, 'runtimeKinds': ['XCTestCore'], 'eventCount': len(events)}
        arguments = dict(source='a' * 40, pid=123, parent=99, bundle=bundle, host=executable)
        return receipt, events, ids, arguments

    def test_exact_observed_execution_requires_start_before_end_and_one_complete_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt, events, ids, arguments = self.fixture(Path(temporary))
            self.assertIs(host.verify_receipt(receipt, events, ids, **arguments), receipt)
            variants = [events[1:] + events[:1], [events[0], events[2], events[1], *events[3:]],
                [*events[:-1], events[1], events[-1]], events[:-1]]
            for stream in variants:
                changed = dict(receipt, eventCount=len(stream))
                with self.subTest(stream=stream), self.assertRaises(ValueError):
                    host.verify_receipt(changed, stream, ids, **arguments)

    def test_checkpoint_or_missing_main_queue_progress_cannot_qualify_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt, events, ids, arguments = self.fixture(Path(temporary))
            variants = [dict(receipt, schema='native-xctest-host-checkpoint/v1', boundary='discovery-complete', passed=False),
                dict(receipt, executionScheduler='main-dispatch-queue'), dict(receipt, mainQueueAdmission=None)]
            for field, value in [('completed', False), ('completed', 1), ('mainThread', False), ('mainThread', 1),
                    ('applicationRunning', False), ('applicationRunning', 1), ('suiteExecuting', True),
                    ('suiteExecuting', 0), ('pid', 124), ('pid', True), ('completedUptime', 105.1),
                    ('completedUptime', 99.9), ('checkedUptime', 105.1), ('checkedUptime', 100.9),
                    ('deadlineUptime', 106.0), ('startedUptime', 0)]:
                changed = copy.deepcopy(receipt); changed['mainQueueAdmission'][field] = value; variants.append(changed)
            for field in ('startedUptime', 'deadlineUptime', 'completedUptime', 'checkedUptime'):
                for value in (True, '101.0', float('nan'), float('inf'), -float('inf')):
                    changed = copy.deepcopy(receipt); changed['mainQueueAdmission'][field] = value; variants.append(changed)
            for field in receipt['mainQueueAdmission']:
                changed = copy.deepcopy(receipt); del changed['mainQueueAdmission'][field]; variants.append(changed)
            for changed in variants:
                with self.subTest(value=changed), self.assertRaises(ValueError):
                    host.verify_receipt(changed, events, ids, **arguments)

    def test_observer_rejects_suppressed_issues_discovery_execution_and_fabricated_pass_counts(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt, events, ids, arguments = self.fixture(Path(temporary))
            for kind in ('testCaseIssue', 'testSuiteIssue', 'testCaseExpectedFailure', 'testSuiteExpectedFailure'):
                stream = copy.deepcopy(events)
                stream.insert(2, dict(stream[1], kind=kind, detail={'description': 'actual failure'}))
                with self.subTest(kind=kind), self.assertRaises(ValueError):
                    host.verify_receipt(dict(receipt, eventCount=len(stream)), stream, ids, **arguments)
            for field, value in [('executing', False), ('pid', 456), ('root', 0), ('run', {'hasSucceeded': True}),
                    ('run', {'executionCount': True, 'skipCount': 0, 'totalFailureCount': 0, 'hasSucceeded': True}),
                    ('run', {'executionCount': 1, 'skipCount': 0, 'totalFailureCount': 0, 'hasSucceeded': 1})]:
                stream = copy.deepcopy(events); stream[2][field] = value
                with self.subTest(field=field), self.assertRaises(ValueError):
                    host.verify_receipt(receipt, stream, ids, **arguments)

    def test_class_runtime_source_and_partial_failure_identity_cannot_cross_candidates(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt, events, ids, arguments = self.fixture(Path(temporary))
            variants = []
            for key, value in [('sourceSHA', 'b' * 40), ('parentPID', 12), ('hostPath', '/other/host'),
                    ('boundary', 'discovery'), ('passed', False), ('prematureExecutionCount', 1),
                    ('inventoryIDs', ids[:-1]), ('issueCount', 1), ('recordingError', 'incomplete'),
                    ('passed', 1), ('mainThread', 1), ('applicationRunningAtStart', 1)]:
                variants.append(dict(receipt, **{key: value}))
            changed = copy.deepcopy(receipt); changed['leafClasses'][0]['image'] = '/foreign/current.xctest'; variants.append(changed)
            changed = copy.deepcopy(receipt); changed['runtimeImagesAfter'] += ['/foreign/XCTestCore']; variants.append(changed)
            changed = copy.deepcopy(receipt)
            duplicate = str(arguments['bundle'] / 'Contents/Frameworks/duplicate/XCTestCore')
            changed['runtimeImagesAfterLoad'].append(duplicate); changed['runtimeImagesAfter'].append(duplicate); variants.append(changed)
            for value in variants:
                with self.subTest(value=value), self.assertRaises(ValueError): host.verify_receipt(value, events, ids, **arguments)

    def test_short_and_qualified_reported_names_keep_the_same_actual_class_and_invocation(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt, events, ids, arguments = self.fixture(Path(temporary))
            self.assertIs(host.verify_receipt(receipt, events, ids, **arguments), receipt)
            for leaf in receipt['leafClasses']: leaf['reportedName'] = leaf['name']
            for observation in receipt['caseObservations']:
                observation['reportedName'] = observation['identity']['name']
                observation['identity']['reportedName'] = observation['identity']['name']
            for event in events:
                if event['kind'].startswith('testCase'):
                    event['detail']['caseIdentity']['reportedName'] = event['name']
                    event['detail']['caseObservation']['reportedName'] = event['name']
                    event['detail']['caseObservation']['identity']['reportedName'] = event['name']
            self.assertIs(host.verify_receipt(receipt, events, ids, **arguments), receipt)

    def test_case_class_public_method_and_original_name_cannot_be_substituted_in_discovery_or_callbacks(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt, events, ids, arguments = self.fixture(Path(temporary))
            variants = [('class', 'Foreign.NativeCase'), ('class', 'NativeCase'), ('class', ''),
                ('method', 'foreign'), ('method', ''), ('method', 'first second'), ('reportedName', '-[Foreign.NativeCase first]'),
                ('reportedName', '-[NativeCase second]'), ('reportedName', ''), ('name', '-[NativeCase first]')]
            for field, value in variants:
                changed = copy.deepcopy(receipt)
                changed['leafClasses'][0][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    host.verify_receipt(changed, events, ids, **arguments)
            for field in ('class', 'method', 'reportedName', 'image', 'name'):
                for index in (1, 2):
                    stream = copy.deepcopy(events)
                    stream[index]['detail']['caseIdentity'][field] = 'substituted'
                    with self.subTest(field=field, callback=index), self.assertRaises(ValueError):
                        host.verify_receipt(receipt, stream, ids, **arguments)
            stream = copy.deepcopy(events); stream[1]['detail'] = {}
            with self.assertRaises(ValueError): host.verify_receipt(receipt, stream, ids, **arguments)

    def test_public_identity_covers_throwing_async_and_absent_invocation_without_selector_mapping(self):
        with tempfile.TemporaryDirectory() as temporary:
            for suffix, present, responds in [('', True, True), ('AndReturnError:', True, True),
                    ('WithCompletionHandler:', True, True), ('opaqueImplementation:', True, False), (None, False, None)]:
                receipt, events, ids, arguments = self.fixture(Path(temporary))
                rows = receipt['caseObservations'] + [event['detail']['caseObservation']
                    for event in events if event['kind'].startswith('testCase')]
                for row in rows:
                    row['invocationPresent'] = present
                    row['invocationSelector'] = row['identity']['method'] + suffix if suffix is not None else None
                    row['respondsToInvocationSelector'] = responds
                with self.subTest(suffix=suffix):
                    self.assertIs(host.verify_receipt(receipt, events, ids, **arguments), receipt)

    def test_every_discovery_and_callback_requires_complete_unrejected_original_observations(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt, events, ids, arguments = self.fixture(Path(temporary))
            variants = [dict(receipt, caseObservations=receipt['caseObservations'][:-1]),
                dict(receipt, caseObservations=[receipt['caseObservations'][0]] * 2),
                dict(receipt, discoveredTestCaseCount=3)]
            for field, value in [('class', 'Foreign.NativeCase'), ('image', '/foreign/image'), ('reportedName', '-[NativeCase other]'),
                    ('invocationPresent', 1), ('invocationSelector', 3), ('respondsToInvocationSelector', 1),
                    ('observationError', 'actual getter exception'), ('rejectionReason', 'actual class rejection'), ('identity', None)]:
                changed = copy.deepcopy(receipt); changed['caseObservations'][0][field] = value; variants.append(changed)
            for changed in variants:
                with self.subTest(changed=changed), self.assertRaises(ValueError): host.verify_receipt(changed, events, ids, **arguments)
            for index in (1, 2):
                for field in ('caseObservation',):
                    stream = copy.deepcopy(events); stream[index]['detail'].pop(field)
                    with self.subTest(callback=index), self.assertRaises(ValueError): host.verify_receipt(receipt, stream, ids, **arguments)

    def test_completed_xctest_proof_is_persisted_before_a_following_app_host_failure(self):
        import hashlib
        import json
        import os
        from unittest.mock import patch
        import compiled_app_release as release
        import run_macos_tests as native
        changed_app_source = 'c' * 40
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            receipt, events, ids, arguments = self.fixture(root)
            receipt['parentPID'] = os.getpid()
            image = Path(receipt['bundleImagePath']); image.parent.mkdir(parents=True); image.write_bytes(b'current tests')
            executable = arguments['host']; executable.parent.mkdir(parents=True); executable.write_bytes(b'current helper')
            generic = root / 'runtime/NexGenVideoAppKitTestHost'; generic.parent.mkdir(); generic.write_bytes(b'qualified host')
            compiler = root / 'swiftc'; compiler.write_bytes(b'qualified compiler')
            sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            product = {'state': {'xctestHost': {'schema': 'native-xctest-host-build/v1',
                'appSourceSHA': changed_app_source, 'inputs': host.inputs(), 'supportObjectSHA256': host.SUPPORT_SHA,
                'signedSHA256': sha(executable)}}, 'files': {}}
            for name, path in [('Contents/MacOS/NexGenVideoTests', image), ('Contents/Helpers/' + host.HOST_NAME, executable)]:
                product['files']['Products/Release/NexGenVideoTests.xctest/' + name] = {'kind': 'file', 'sha256': sha(path)}
            product['files']['Products/Release/NexGenVideoTests.xctest/Contents/Frameworks/XCTestCore.framework/Versions/A/XCTestCore'] = {'kind': 'file', 'sha256': 'f' * 64}
            bound = {'sourceSHA': 'a' * 40, 'runID': 101, 'appSourceSHA': changed_app_source,
                'nativeSourceObjects': {'Sources': 'b' * 40}, 'runtime': str(generic.parent), 'selected': {},
                'products': {phase: {'output': str(image), 'receipt': product, 'originalArchiveSHA256': 'f' * 64}
                    for phase in release.PHASES}, 'prepared': {'plans': {'production': {'driver': {'argv': [str(compiler)]}}}}}
            (root / 'bound.json').write_text(json.dumps(bound))
            observation = {'outputCapture': {'originalExitCode': 0, 'eof': True}}
            def process(command, console, environment, observed):
                if command[0] == str(executable):
                    Path(command[3]).write_text(json.dumps(receipt))
                    Path(command[4]).write_text(''.join(json.dumps(item) + '\n' for item in events))
                    Path(command[5]).write_bytes(b'')
                    console.write_bytes(b'')
                    return 0, 123
                saved = json.loads((root / 'xctest/verified.json').read_text())
                self.assertTrue(saved['passed'])
                self.assertEqual(saved['individualPassedIDs'], ids)
                self.assertEqual(saved['hostSHA256'], sha(executable))
                observed['outputCapture']['originalExitCode'] = 1
                return 1, 456
            def checksum(path):
                return release.retained.HOST_SHA if path == generic else release.COMPILER_SHA if path == compiler else sha(path)
            inventory = {'xctest': {'exactIndividualPassedIDs': ids}, 'modules': {'engine': {}}}
            with patch.object(release, 'APP_SOURCE', changed_app_source), \
                    patch.object(release, 'native_guard'), patch.object(release, 'source_objects', return_value=bound['nativeSourceObjects']), \
                    patch.object(release, 'criteria', return_value=inventory), patch.object(release, 'checksum', side_effect=checksum), \
                    patch.object(release, 'retained_engine_evidence', return_value={}), patch.object(release.targets, 'logged'), \
                    patch.object(native, 'prepare_post_mortem', side_effect=lambda *args: {'outputCapture': dict(observation['outputCapture'])}), \
                    patch.object(native, 'run_process', side_effect=process) as processes, \
                    patch.object(native, 'app_environment', return_value={}), \
                    patch.dict(os.environ, {'GITHUB_SHA': bound['sourceSHA'], 'GITHUB_RUN_ID': '101'}, clear=True):
                with self.assertRaisesRegex(ValueError, 'Native process failed'): release.run_tests(root)
            self.assertEqual(processes.call_count, 2)
            saved = json.loads((root / 'xctest/verified.json').read_text())
            host.verify_proof(saved, ids, bound['sourceSHA'], product)
            original = (root / 'xctest/verified.json').read_bytes()
            with self.assertRaises(FileExistsError): host.persist_proof(root / 'xctest/verified.json', {'passed': False})
            self.assertEqual((root / 'xctest/verified.json').read_bytes(), original)
            self.assertFalse((root / 'receipt.json').exists())
            self.assertTrue((root / 'xctest/events.jsonl').is_file())



if __name__ == '__main__':
    unittest.main()
