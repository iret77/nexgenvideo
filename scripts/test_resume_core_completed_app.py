import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import resume_core_bundle as bundle
import resume_core_completed_app as resume


HEAD = 'b' * 40
ROOT = Path(__file__).resolve().parents[1]


def producer_fixture():
    run = {'id': resume.RUN, 'head_sha': resume.SOURCE, 'run_attempt': 1, 'status': 'completed',
           'conclusion': 'failure', 'repository': {'full_name': 'iret77/nexgenvideo'},
           'head_repository': {'full_name': 'iret77/nexgenvideo'}, 'event': 'workflow_dispatch',
           'path': '.github/workflows/ci-batch.yml'}
    success = ['Build', 'Stage test runtime inputs', 'Verify assertion continuation source and platform',
               'Verify build did not mutate tracked source', 'Upload App assertion continuation proof',
               'Upload render review test diagnosis']
    skipped = ['HDR export QC', 'Bundle (debug, ad-hoc signed)', 'Upload .app artifact']
    jobs = []
    for suffix, identifier, conclusion in [('Build & Test', resume.JOB, 'failure'),
            ('Light Checks', 121388183959, 'success'), ('Agent UI Evidence', 121389745613, 'success'),
            ('bpy-source / source', 121389745714, 'success'), ('Merge Gate', 121394558324, 'failure')]:
        steps = []
        if identifier == resume.JOB:
            steps = [{'name': name, 'conclusion': result} for result, names in
                     [('success', success), ('skipped', skipped), ('failure', ['Test'])] for name in names]
        if suffix == 'Light Checks':
            steps = [{'name': name, 'conclusion': 'success'} for name in
                     ('Verify CI and fixture tooling', 'Enforce AppTheme', 'Validate pack pipeline contracts',
                 'Require distributable bpy before app transfer')]
        jobs.append({'id': identifier, 'name': resume.PREFIX + suffix, 'run_id': resume.RUN, 'run_attempt': 1,
                     'head_sha': resume.SOURCE, 'status': 'completed', 'conclusion': conclusion, 'steps': steps})
    return run, {'total_count': len(jobs), 'jobs': jobs}


class CompletedAppRecoveryTests(unittest.TestCase):
    def test_only_the_exact_finished_parser_incident_can_supply_proofs(self):
        run, jobs = producer_fixture()
        self.assertEqual(set(resume.producer(run, jobs)), {resume.JOB, 121388183959, 121389745613, 121389745714})
        for key, value in [('id', 123), ('head_sha', HEAD), ('run_attempt', 2), ('status', 'in_progress'),
                           ('conclusion', 'success'), ('event', 'pull_request'), ('path', '.github/workflows/other.yml'),
                           ('repository', {'full_name': 'another/repo'}), ('head_repository', {'full_name': 'another/repo'})]:
            with self.subTest(key=key), self.assertRaises(ValueError): resume.producer({**run, key: value}, jobs)
        for mutate in [lambda j: j.update(total_count=99),
                       lambda j: j['jobs'][0].update(run_attempt=2),
                       lambda j: j['jobs'][0].update(id=123),
                       lambda j: j['jobs'][0].update(head_sha=HEAD),
                       lambda j: j['jobs'][1].update(conclusion='failure'),
                       lambda j: j['jobs'][2].update(status='in_progress'),
                       lambda j: j['jobs'][0]['steps'].append({'name': 'Another step', 'conclusion': 'failure'}),
                       lambda j: j['jobs'][0]['steps'][0].update(conclusion='failure'),
                       lambda j: j['jobs'][0]['steps'][-2].update(conclusion='success')]:
            changed = copy.deepcopy(jobs); mutate(changed)
            with self.subTest(changed=changed), self.assertRaises(ValueError): resume.producer(run, changed)

    def test_current_source_cannot_change_any_native_test_or_product_input(self):
        allowed = '\n'.join(sorted(resume.ALLOWED))
        def digest(path): return resume.assertions.TESTS[str(path)]
        with patch.object(resume, 'command', side_effect=[HEAD, allowed, '', 'run: ' + bundle.BUILD]), \
             patch.object(resume.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
             patch.object(resume, 'checksum', side_effect=digest):
            self.assertEqual(set(resume.sources(HEAD)), resume.ALLOWED)
        for extra in ('Sources/NexGenVideo/App.swift', 'Tests/NexGenVideoTests/Agent/RecognizedLyricsContextTests.swift',
                      'Package.swift', 'Runtime/bpy/runtime-lock.json', 'plugins/musicvideo.json',
                      'scripts/run_macos_tests.py', 'scripts/bundle.sh'):
            with self.subTest(extra=extra), patch.object(resume, 'command', side_effect=[HEAD, allowed + '\n' + extra]), \
                 patch.object(resume.subprocess, 'run'), self.assertRaises(ValueError): resume.sources(HEAD)
        with patch.object(resume, 'command', side_effect=[HEAD, allowed, '']), \
             patch.object(resume.subprocess, 'run'), patch.object(resume, 'checksum', return_value='f' * 64), \
             self.assertRaises(ValueError): resume.sources(HEAD)

    def test_recovery_rejects_tampered_archive_size_digest_and_identity(self):
        run, listing = producer_fixture(); jobs = resume.producer(run, listing)
        raw = b'exact original bytes'; digest = hashlib.sha256(raw).hexdigest()
        spec = {'tests': (8, 'original-tests', digest, len(raw), resume.JOB)}
        item = {'id': 8, 'name': 'original-tests', 'digest': 'sha256:' + digest, 'size_in_bytes': len(raw),
                'expired': False, 'workflow_run': {'id': resume.RUN, 'head_sha': resume.SOURCE},
                'created_at': '2026-10-26T04:14:00Z', 'updated_at': '2026-10-26T04:14:00Z',
                'expires_at': '2099-01-01T00:00:00Z'}
        jobs[resume.JOB].update(started_at='2026-10-26T03:59:00Z', completed_at='2026-10-26T04:14:17Z')
        receipt = {'originalRun': run, 'artifacts': {'tests': item}}
        with tempfile.TemporaryDirectory() as directory, patch.object(resume, 'ARTIFACTS', spec):
            root = Path(directory); path = root / 'tests.zip'; path.write_bytes(raw)
            resume.artifacts(root, receipt, jobs)
            for bad in (raw + b'changed', b'x' * len(raw)):
                path.write_bytes(bad)
                with self.assertRaises(ValueError): resume.artifacts(root, receipt, jobs)
            path.write_bytes(raw)
            for change in ({'id': 9}, {'expired': True}, {'digest': 'sha256:' + 'f' * 64},
                           {'workflow_run': {'id': 123, 'head_sha': resume.SOURCE}},
                           {'workflow_run': {'id': resume.RUN, 'head_sha': HEAD}},
                           {'created_at': '2026-10-26T03:58:59Z'}):
                with self.subTest(change=change), self.assertRaises(ValueError):
                    resume.artifacts(root, {**receipt, 'artifacts': {'tests': {**item, **change}}}, jobs)

    def test_a_different_current_execution_cannot_use_the_recovery_receipt(self):
        receipt = {'schema': 'core-completed-app-resume/v1', 'sourceSHA': HEAD, 'runID': '456', 'attempt': '1'}
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, GITHUB_SHA=HEAD, GITHUB_RUN_ID='456', GITHUB_RUN_ATTEMPT='1'):
            root = Path(directory)
            for key in receipt:
                (root / 'receipt.json').write_text(json.dumps({**receipt, key: 'wrong'}))
                with self.subTest(key=key), patch.object(resume, 'sources') as sources, self.assertRaises(ValueError):
                    resume.verify(root)
                sources.assert_not_called()

    def test_existing_bundle_entry_points_route_only_the_exact_recovery(self):
        with patch.object(resume, 'prepare') as prepare:
            bundle.prepare(resume.RUN, Path('/evidence'))
            prepare.assert_called_once_with(Path('/evidence'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'receipt.json').write_text(json.dumps({'schema': 'core-completed-app-resume/v1'}))
            with patch.object(resume, 'verify', return_value={'bound': True}) as verify:
                self.assertEqual(bundle.verify(root, native=True), {'bound': True})
                verify.assert_called_once_with(root, native=True)

    def test_original_app_metadata_rejects_foreign_profiles_counts_and_ownership(self):
        def attempt(change=None):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                changed = sorted(resume.assertions.TESTS)
                binding = {'sourceSHA': resume.SOURCE, 'runID': str(resume.RUN), 'attempt': '1',
                           'originalSourceSHA': resume.assertions.SOURCE, 'completedAppInventory': {},
                           'proof': {'completedAppInventory': {}}, 'changedPaths': changed, 'toolchain': {'selected': True}}
                host = {'sourceSHA': resume.SOURCE, 'pid': 5789, 'parentPID': 5772, 'eventRecordCount': 12808,
                        'hostExecutable': '/Debug/NexGenVideoAppKitTestHost',
                        'bundleBinary': '/Debug/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests',
                        'getterImagePath': '/Applications/Xcode_27.app/Testing',
                        'entryPointImagePath': '/Applications/Xcode_27.app/Testing',
                        **{key: True for key in ('started', 'completed', 'abiSucceeded', 'mainThread',
                                               'applicationRunningAtStart', 'runReturnedAfterCompletion')}}
                events = {'discoveredFunctionIDs': list(range(3528)), 'functionExecutions': 3520,
                          'skippedFunctionIDs': list(range(8)), 'recordCount': 12808}
                suite = {'schema': 1, 'sourceSHA': resume.SOURCE, 'binPath': '/Debug', 'combinedFrameworks': {'passed': True},
                         'phases': [{'pid': 5789, 'events': events, 'originalHostReceipt': host}]}
                command = ['python3', 'scripts/run_macos_tests.py', '--cache-path', '/cache',
                           '--scope', 'app-swift-testing', '--evidence', '/capture/hosted-suite']
                capture = {'runID': str(resume.RUN), 'runLoopProbe': {'status': 'not-requested'},
                           'command': command, 'actualCommand': command, 'originalCommand': command,
                           'outputCompletion': {'passed': True}}
                report = {'processID': 5789, 'operatingSystem': 'Version 27.0 (Build 26A428)'}
                values = {'binding': binding, 'host': host, 'suite': suite, 'capture': capture, 'report': report,
                          'compiler': '/Applications/Xcode_27.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc',
                          'extraCompletion': False}
                if change: change(values)
                with zipfile.ZipFile(root / 'backends.zip', 'w') as archive:
                    archive.writestr('receipt.json', json.dumps(binding))
                    archive.writestr('original.zip', b'original backend fixture')
                    archive.writestr('original-job.log', b'original backend log fixture')
                    if values['extraCompletion']: archive.writestr('completed.json', '{}')
                raw_report = json.dumps(report).encode()
                with zipfile.ZipFile(root / 'tests.zip', 'w') as archive:
                    for name, value in [('run.json', capture), ('hosted-suite/suite.json', suite),
                                        ('hosted-suite/app-swift-testing/host-receipt.json', host),
                                        ('hosted-suite/app-swift-testing/watchdog/report.json', report),
                                        ('hosted-suite/app-swift-testing/watchdog/receipt.json', {'reports': [
                                            {'file': 'report.json', 'processID': 5789,
                                             'sha256': hashlib.sha256(raw_report).hexdigest()}]})]:
                        archive.writestr(name, json.dumps(value))
                    archive.writestr('hosted-suite/combined.log', b'framework log fixture')
                    archive.writestr('hosted-suite/app-swift-testing/events.jsonl', b'event fixture')
                    archive.writestr('hosted-suite/app-swift-testing/swiftc-path.stdout', values['compiler'])
                log = '(Selected)\t/Applications/Xcode_27.app\nApp assertion continuation failed: Unterminated string starting at: line 1 column 177 (char 176)\n'
                (root / 'original-job.log').write_text(log)
                def complete(destination, *args):
                    (destination / 'completed.json').write_text(json.dumps({'currentApp': suite}))
                with patch.object(resume.assertions, 'verify_binding'), \
                     patch.object(resume.assertions, 'complete_verified_app', side_effect=complete), \
                     patch.object(resume, 'LOG_DIGEST', hashlib.sha256(log.encode()).hexdigest()), \
                     patch.object(resume, 'toolchain', return_value={'selected': True}), \
                     patch.object(resume, 'command', return_value='\n'.join(changed)):
                    return resume.proof(root)
        self.assertEqual(attempt()['compilerPath'].split('/')[-1], 'swiftc')
        mutations = [lambda v: v.update(extraCompletion=True),
                     lambda v: v['binding'].update(sourceSHA=HEAD),
                     lambda v: v['binding'].update(changedPaths=[]),
                     lambda v: v['binding'].update(toolchain={'selected': False}),
                     lambda v: v['capture'].update(runID='123'),
                     lambda v: v['capture']['command'].extend(['--filter', 'One']),
                     lambda v: v['capture'].update(outputCompletion={'passed': False}),
                     lambda v: v['suite'].update(schema=2),
                     lambda v: v['suite']['phases'][0]['events'].update(functionExecutions=3519),
                     lambda v: v['host'].update(pid=5790),
                     lambda v: v['host'].update(parentPID=5773),
                     lambda v: v['report'].update(processID=5790),
                     lambda v: v['report'].update(operatingSystem='Version 27.0 (Build other)'),
                     lambda v: v.update(compiler='/Applications/Other.app/swiftc')]
        for index, change in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(ValueError): attempt(change)

    def test_completion_separates_backend_origin_and_requires_fresh_hdr(self):
        names = ['hosted-suite/suite.json', 'hosted-suite/app-swift-testing/console.log',
                 'hosted-suite/app-swift-testing/events.jsonl', 'hosted-suite/app-swift-testing/host-receipt.json',
                 'hdr-qc.v1.json', 'hdr-reference.mov']
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, RUNNER_TEMP=directory):
            root = Path(directory) / 'evidence'; root.mkdir()
            backend = root / 'original-backends'; backend.mkdir()
            (backend / 'receipt.json').write_text(json.dumps({'originalRun': {}, 'originalJobs': {}}))
            for name in names:
                path = Path(directory) / 'hdr-export-qc' / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'fixture')
            receipt = {'sourceSHA': HEAD, 'runID': '456', 'attempt': '1', 'limitations': 'Original object identity unproven',
                       'pending': ['fresh HDR QC', 'reconstructed bundle', 'pack loading/ABI', 'native UI matrix']}
            with patch.object(bundle, 'hdr_proof', return_value={'passed': True}) as hdr, \
                 patch.object(resume.assertions, 'verify_jobs', return_value={'id': 123}):
                value = resume.finish_evidence(root, receipt)
                hdr.assert_called_once_with(root, HEAD)
                self.assertEqual(value['backendExecution']['runID'], resume.assertions.RUN)
                self.assertEqual(value['freshHDR']['sourceSHA'], HEAD)
                self.assertEqual(value['freshHDR']['runID'], '456')
                self.assertEqual(value['pending'], ['native UI matrix'])
            with patch.object(bundle, 'hdr_proof', side_effect=ValueError('HDR failed')), self.assertRaises(ValueError):
                resume.finish_evidence(root, receipt)

    def test_native_reuse_runs_after_skip_but_stops_failed_selected_tests(self):
        text = (ROOT / '.github/workflows/workspace-ui-acceptance.yml').read_text()
        expressions = {}
        for job in ('runtime', 'acceptance', 'batch-review'):
            section = text.split('  ' + job + ':\n', 1)[1]
            expression = section.split('    if: ${{ ', 1)[1].split(' }}', 1)[0]
            self.assertIn('!cancelled()', expression)
            expressions[job] = expression
        def evaluate(job, build, ready, reuse, runtime='success', cancelled=False):
            values = {'needs.source.result': 'success', 'needs.build.result': build,
                      'needs.build.outputs.app_ready': ready, 'inputs.runtime_artifact': reuse,
                      'inputs.runtime_run_id': '123' if reuse else '', 'needs.runtime.result': runtime,
                      'needs.source.outputs.native': 'true', 'needs.source.outputs.batch': 'true'}
            expression = expressions[job].replace('!cancelled()', str(not cancelled))
            for key, value in values.items(): expression = expression.replace(key, repr(value))
            return eval(expression.replace('&&', 'and').replace('||', 'or'), {'__builtins__': {}}, {})
        for build, ready, reuse, expected in [('success', 'true', '', True), ('skipped', '', 'workspace-ui-app', True),
                                             ('failure', 'true', '', False), ('skipped', '', '', False),
                                             ('success', 'false', '', False)]:
            with self.subTest(build=build, ready=ready, reuse=reuse):
                actual = evaluate('runtime', build, ready, reuse)
                self.assertEqual(actual, expected)
                for job in ('acceptance', 'batch-review'):
                    self.assertEqual(evaluate(job, build, ready, reuse, 'success' if actual else 'skipped'), expected)
                    self.assertFalse(evaluate(job, build, ready, reuse, cancelled=True))

    def test_reconstruction_keeps_pending_hdr_and_never_reruns_the_full_suite(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text().split('  build_test:\n', 1)[1]
        def condition(name):
            return workflow.split('      - name: ' + name + '\n', 1)[1].split('      - ', 1)[0].split('        if: ', 1)[1].splitlines()[0]
        for original, full_suite, hdr in [('', True, True), ('40265902971', False, True), ('123', False, False)]:
            for name, expected in [('Test', full_suite), ('Stage test runtime inputs', hdr), ('HDR export QC', hdr)]:
                expression = condition(name).replace('inputs.completed_full_core_run_id', repr(original)).replace('||', 'or')
                with self.subTest(original=original, step=name):
                    self.assertEqual(eval(expression, {'__builtins__': {}}, {}), expected)
        self.assertIn('run: ' + bundle.BUILD, workflow)


if __name__ == '__main__': unittest.main()
