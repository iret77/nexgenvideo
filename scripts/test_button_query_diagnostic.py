import builtins
from contextlib import contextmanager
import copy
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile

import yaml

import button_query_diagnostic as diagnostic


class ButtonQueryDiagnosticTests(unittest.TestCase):
    def reuse_env(self):
        return dict(self.crash_env(), KIND=diagnostic.REUSE_KIND, EXTRA_SOURCE=diagnostic.REUSED_SOURCE,
                    EXTRA_PRODUCTS='60', EXTRA_PRODUCTS_SHA='d' * 64)

    def retained_fixture(self, root):
        args, binding, originals, toolchain = self.observer_fixture(root)
        toolchain['python'] = 'original engine Python fixture'
        original = args.binding / 'original-evidence.zip'
        members = diagnostic.zip_members(original)
        key = '_temp/release-test-evidence/retained-engine-receipt.json'
        members[key] = json.dumps(dict(toolchain=toolchain)).encode()
        with zipfile.ZipFile(original, 'w') as archive:
            for name, raw in members.items(): archive.writestr(name, raw)
        binding['originalArtifact']['digest'] = 'sha256:' + diagnostic.digest(original.read_bytes())
        binding['originalEvidence'] = diagnostic.failure_archive(original)
        prior_source = diagnostic.zip_members(args.binding / 'prior-source-binding.zip')
        prior_source['original-evidence.zip'] = original.read_bytes()
        with zipfile.ZipFile(args.binding / 'prior-source-binding.zip', 'w') as archive:
            for name, raw in prior_source.items(): archive.writestr(name, raw)
        checksum = diagnostic.digest((args.binding / 'prior-source-binding.zip').read_bytes())
        binding['priorCrashes']['artifacts'][1]['digest'] = 'sha256:' + checksum
        binding['priorCrashes']['request']['source_binding_artifact_sha256'] = checksum
        observations = diagnostic.zip_members(args.binding / 'prior-observations.zip')
        binding['priorCrashes'].update(diagnostic.verify_crash_payload(observations, prior_source,
            binding['sourceFiles'], original.read_bytes()))
        source_binding = copy.deepcopy(binding)
        source_binding.update(sourceSHA=diagnostic.REUSED_SOURCE, sourceTree='ab9d2dc76fbd620392d7a712bc08fc37d50909d5',
            runID=str(diagnostic.REUSED_RUN), attempt='1', appAcceptance=False, appBuilds=0, nativeUnitExecutions=0,
            sourceProof=dict(schema='core-pr-source-composition/v1', sourceSHA=diagnostic.REUSED_SOURCE,
                runID=str(diagnostic.REUSED_RUN), attempt='1', originalRun=dict(id=42160256589)))
        source = {'binding.json': json.dumps(source_binding).encode(), 'original-evidence.zip': original.read_bytes(),
            'prior-observations.zip': (args.binding / 'prior-observations.zip').read_bytes(),
            'prior-source-binding.zip': (args.binding / 'prior-source-binding.zip').read_bytes()}
        selected, ranges = diagnostic.source_subset(originals)
        native = {'compiler.log': b'', 'toolchain.json': json.dumps(dict(actual={key: toolchain[key]
            for key in ('xcode', 'osVersion', 'osBuild', 'swift')}, original=toolchain)).encode(),
            'source-subsets.json': json.dumps(dict(originals=binding['sourceFiles'], subsets={name: dict(
                SHA256=diagnostic.digest(raw), bytes=len(raw), originalByteRanges=ranges[name]) for name, raw in selected.items()})).encode()}
        native.update({'sources/' + name: raw for name, raw in selected.items()})
        stem = f'nbq{diagnostic.REUSED_RUN % 10_000_000_000:010d}'
        folder = f'owned-{diagnostic.REUSED_RUN}-a1/'
        code = b'retained executable fixture bytes'
        for suffix in ('', 'c', 't'): native[folder + stem + suffix] = code
        native[folder + stem + '.dSYM/Contents/Info.plist'] = b'debug info fixture'
        native[folder + stem + '.dSYM/Contents/Resources/Relocations/aarch64/' + stem + '.yml'] = b'relocations fixture'
        native[folder + stem + '.dSYM/Contents/Resources/DWARF/' + stem] = b'DWARF fixture'
        command = ['xcrun', 'swiftc', '-swift-version', '6', '-g', '-parse-as-library', '-target', 'arm64-apple-macos26.0',
            *['/fixture/sources/' + name for name in selected], '/repository/scripts/button_query_diagnostic.swift',
            '-o', '/fixture/' + folder + stem]
        native['compiler.process.json'] = json.dumps(dict(pid=100, exitCode=0, processReaped=True, timedOut=False, command=command)).encode()
        results = []
        stages = ['observe-entered', 'fixture-init-before', 'fixture-init-after', 'first-query-before',
            'first-query-returned', 'CG-stability-before', 'CG-stability-returned', 'warm-query-before']
        for index, mode in enumerate(diagnostic.CRASH_MODES):
            process = dict(pid=101 + index, exitCode=-5, processReaped=True, timedOut=False,
                executableSHA256=diagnostic.digest(code), command=['/fixture/' + folder + stem + ('c' if index == 0 else 't')])
            records = [dict(schema='nexgenvideo/button-query-stage/1', pid=process['pid'], mode=mode,
                mainThread=True, stage=stage, uptime=10 + position) for position, stage in enumerate(stages)]
            raw = b'\n'.join(json.dumps(item).encode() for item in records)
            native[mode + '.stages.jsonl'] = raw
            native[mode + '.process.json'] = json.dumps(process).encode()
            native[mode + '.log'] = b''
            results.append(dict(mode=mode, status='failed-observation', process=process,
                stages=dict(SHA256=diagnostic.digest(raw), records=records)))
        native['receipt.json'] = json.dumps(dict(schema='nexgenvideo/button-query-crash-observation/1',
            sourceSHA=diagnostic.REUSED_SOURCE, runID=str(diagnostic.REUSED_RUN), attempt='1',
            bindingSHA256=diagnostic.digest(source['binding.json']), measurementComplete=False,
            appAcceptance=False, appBuilds=0, nativeUnitExecutions=0, originalFailureResolved=False, results=results)).encode()
        return args, binding, originals, toolchain, native, source

    def test_reuse_mode_requires_exact_selectors_and_preserves_all_existing_leafs(self):
        env = self.reuse_env(); diagnostic.validate_inputs(env)
        for key, value in [('EXTRA_SOURCE', 'c' * 40), ('EXTRA_PRODUCTS', ''), ('EXTRA_PRODUCTS_SHA', ''),
                           ('JOURNEY_JOB', '1'), ('DMG_DIGEST', 'a' * 64), ('RUNTIME_FAILURE_BINDING', '{}')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(env, **{key: value}))
        for kind in ('native-button-query', diagnostic.CRASH_KIND):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(env, KIND=kind))
        workflow = yaml.safe_load((diagnostic.ROOT / '.github/workflows/diagnostic-acceptance.yml').read_text())
        leaf = workflow['jobs'][diagnostic.REUSE_KIND]
        self.assertEqual((leaf['needs'], leaf['runs-on'], leaf['timeout-minutes']), ('source', 'macrunner', 5))
        self.assertEqual(leaf['if'], "inputs.candidate_kind == 'native-button-query-crash-reuse'")
        command = next(step['run'] for step in leaf['steps'] if 'run' in step)
        self.assertIn('--reuse-compiler', command)
        self.assertNotIn('swiftc', command)
        guard = next(step for step in workflow['jobs']['source']['steps'] if step.get('name') == 'Require exact public transport continuation inputs')
        code = guard['run'].split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        values = dict(env, JOURNEY_JOB='', JOURNEY_ARTIFACT='', JOURNEY_DIGEST='', PACKAGING_PRODUCER_SOURCE='',
            PACKAGING_PROVENANCE_ARTIFACT_ID='', PACKAGING_PROVENANCE_ARTIFACT_SHA256='')
        with patch.dict(os.environ, values, clear=True): exec(compile(code, '<reuse-input-guard>', 'exec'), {})
        for step in workflow['jobs']['source']['steps']:
            if step.get('name') in ('Bind the original failed button query and unchanged framework sources',
                                    'Reuse complete current merged PR source proof'):
                self.assertIn(diagnostic.REUSE_KIND, step['if'])

    def test_reuse_payload_rejects_changed_sources_flags_products_and_semantic_lineage(self):
        with tempfile.TemporaryDirectory() as directory:
            args, binding, originals, _, native, source = self.retained_fixture(Path(directory))
            verify = lambda product, archive: diagnostic.verify_retained_probe(product, archive, binding['sourceFiles'],
                (args.binding / 'original-evidence.zip').read_bytes(), originals,
                (diagnostic.ROOT / 'scripts/button_query_diagnostic.swift').read_bytes())
            self.assertTrue(verify(native, source)['products'])
            for variant in ('flags', 'exit', 'reaped', 'subset', 'ranges', 'binary', 'dsym', 'toolchain', 'receipt', 'embedded', 'program'):
                product, archive = copy.deepcopy(native), copy.deepcopy(source)
                if variant in ('flags', 'exit', 'reaped'):
                    value = json.loads(product['compiler.process.json'])
                    if variant == 'flags': value['command'].insert(2, '-Ounchecked')
                    elif variant == 'exit': value['exitCode'] = 1
                    else: value['processReaped'] = False
                    product['compiler.process.json'] = json.dumps(value).encode()
                elif variant == 'subset': product['sources/NativeButtonAccessibility.swift'] = b'changed'
                elif variant == 'ranges':
                    value = json.loads(product['source-subsets.json']); value['subsets']['NativeButtonAccessibility.swift']['originalByteRanges'] = []
                    product['source-subsets.json'] = json.dumps(value).encode()
                elif variant in ('binary', 'dsym'):
                    key = next(name for name in product if name.endswith('.dSYM/Contents/Info.plist')) if variant == 'dsym' else next(
                        name for name in product if name.startswith('owned-') and '.dSYM' not in name)
                    product[key] = b''
                elif variant == 'toolchain':
                    value = json.loads(product['toolchain.json']); value['actual']['swift'] = 'different'
                    product['toolchain.json'] = json.dumps(value).encode()
                elif variant == 'receipt':
                    value = json.loads(product['receipt.json']); value['measurementComplete'] = True
                    product['receipt.json'] = json.dumps(value).encode()
                elif variant == 'embedded': archive['original-evidence.zip'] = b'changed'
                else:
                    value = json.loads(archive['binding.json']); value['harnessFiles']['scripts/button_query_diagnostic.swift'] = 'c' * 64
                    archive['binding.json'] = json.dumps(value).encode()
                with self.subTest(variant=variant), self.assertRaises((ValueError, KeyError)):
                    verify(product, archive)

    def test_reuse_binding_requires_original_producer_jobs_artifacts_and_transfer_windows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args, binding, originals, _, native, source = self.retained_fixture(root)
            def archive_bytes(members):
                output = io.BytesIO()
                with zipfile.ZipFile(output, 'w') as archive:
                    for name, raw in members.items(): archive.writestr(name, raw)
                return output.getvalue()
            payloads = {60: archive_bytes(native), 61: archive_bytes(source)}
            env = dict(self.reuse_env(), EXTRA_PRODUCTS_SHA=diagnostic.digest(payloads[60]))
            run = dict(id=diagnostic.REUSED_RUN, head_sha=diagnostic.REUSED_SOURCE, run_attempt=1,
                actor=dict(login='iret77'), repository=dict(full_name='iret77/nexgenvideo'),
                path='.github/workflows/diagnostic-acceptance.yml', event='workflow_dispatch', status='completed', conclusion='failure')
            jobs = dict(total_count=2, jobs=[dict(id=job_id, name=name, conclusion=conclusion, labels=labels,
                run_id=diagnostic.REUSED_RUN, head_sha=diagnostic.REUSED_SOURCE, run_attempt=1, status='completed',
                started_at='2026-11-06T00:00:00Z', completed_at='2026-11-06T02:00:00Z',
                steps=[] if job_id == diagnostic.REUSED_SOURCE_JOB else [dict(
                    name='Capture only the two actual Slow crashes and their owned reports', conclusion='failure')])
                for job_id, name, conclusion, labels in ((diagnostic.REUSED_SOURCE_JOB, 'source', 'success', ['ubuntu-24.04']),
                    (diagnostic.REUSED_NATIVE_JOB, diagnostic.CRASH_KIND, 'failure', ['macrunner']))])
            artifacts = [dict(id=value, name=name, expired=False, size_in_bytes=len(payloads[value]),
                digest='sha256:' + diagnostic.digest(payloads[value]), workflow_run=dict(id=diagnostic.REUSED_RUN, head_sha=diagnostic.REUSED_SOURCE),
                created_at='2026-11-06T01:00:00Z', updated_at='2026-11-06T01:00:01Z', expires_at='2099-01-01T00:00:00Z')
                for value, name in ((60, f'native-button-query-crash-{diagnostic.REUSED_RUN}-a1'), (61, 'native-button-query-crash-source-binding'))]
            for index, variant in enumerate(('valid', 'actor', 'source', 'labels', 'window', 'expired', 'duplicate', 'bytes')):
                changed_run, changed_jobs, changed_artifacts = copy.deepcopy(run), copy.deepcopy(jobs), copy.deepcopy(artifacts)
                if variant == 'actor': changed_run['actor']['login'] = 'another'
                elif variant == 'source': changed_run['head_sha'] = 'c' * 40
                elif variant == 'labels': changed_jobs['jobs'][1]['labels'] = ['ubuntu-24.04']
                elif variant == 'window': changed_artifacts[0]['created_at'] = '2026-11-05T00:00:00Z'
                elif variant == 'expired': changed_artifacts[0]['expired'] = True
                elif variant == 'duplicate': changed_artifacts.append(copy.deepcopy(changed_artifacts[1]))
                def api(route):
                    if '/attempts/1/jobs' in route: return changed_jobs
                    if '/artifacts?per_page=' in route: return dict(total_count=len(changed_artifacts), artifacts=changed_artifacts)
                    if route == '/actions/artifacts/60': return changed_artifacts[0]
                    if route == '/actions/runs/' + str(diagnostic.REUSED_RUN): return changed_run
                    raise AssertionError(route)
                def download(artifact, path): path.write_bytes(b'changed' if variant == 'bytes' else payloads[artifact['id']])
                target = root / ('acquisition-' + str(index)); target.mkdir()
                with self.subTest(variant=variant):
                    if variant == 'valid':
                        self.assertEqual(diagnostic.bind_retained_probe(target, env, api, download, binding['sourceFiles'],
                            (args.binding / 'original-evidence.zip').read_bytes(), originals)['producerRunID'], diagnostic.REUSED_RUN)
                    else:
                        with self.assertRaises(ValueError): diagnostic.bind_retained_probe(target, env, api, download,
                            binding['sourceFiles'], (args.binding / 'original-evidence.zip').read_bytes(), originals)

    def test_reuse_identity_retains_owned_unknown_path_only_as_unqualified(self):
        process, report = self.ips(); identity = report['usedImages'][0]['uuid']
        for variant in ('valid', 'path', 'pid', 'name', 'time', 'uuid'):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                home = Path(directory); reports = home / 'Library/Logs/DiagnosticReports'; reports.mkdir(parents=True)
                evidence = home / 'evidence'; evidence.mkdir(); changed = copy.deepcopy(report)
                if variant == 'path': changed['procPath'] = '/Users/USER/*/' + changed['procName']
                elif variant == 'pid': changed['pid'] += 1
                elif variant == 'name': changed['procName'] = 'another'
                elif variant == 'time': changed['procLaunch'] = '2025-01-01T00:00:00+00:00'
                elif variant == 'uuid': changed['usedImages'][0]['uuid'] = '11111111-2222-3333-4444-555555555555'
                path = reports / (report['procName'] + '-fixture.ips')
                path.write_text(json.dumps({'bug_type': '309'}) + '\n' + json.dumps(changed))
                timestamp = diagnostic.instant(process['finishedWall']).timestamp(); os.utime(path, (timestamp, timestamp))
                with patch.object(diagnostic.Path, 'home', return_value=home):
                    records = diagnostic.collect_reused_reports(evidence, [process], 'a' * 64, identity, seconds=0)
                record = records[process['pid']]; candidate = record['candidates'][0]
                self.assertEqual(candidate['rawRetained'], variant in ('valid', 'path'))
                self.assertEqual(candidate['qualified'], variant == 'valid')
                self.assertEqual(record['qualifiedCount'], int(variant == 'valid'))
                self.assertEqual(len(list(evidence.glob('*.ips'))), int(variant in ('valid', 'path')))
                if variant == 'path':
                    self.assertFalse(candidate['pathQualified'])
                    with self.assertRaises(ValueError): diagnostic.validate_crash(path.read_bytes(), process, 'a' * 64)

    def test_reuse_collector_maps_delayed_reports_to_the_correct_owned_process(self):
        process, report = self.ips(); identity = report['usedImages'][0]['uuid']
        processes, reports_data = [], []
        for index, suffix in enumerate(('c', 't')):
            owner, payload = copy.deepcopy(process), copy.deepcopy(report)
            owner['pid'] += index; owner['command'][0] += suffix
            payload.update(pid=owner['pid'], procName=Path(owner['command'][0]).name, procPath=owner['command'][0])
            processes.append(owner); reports_data.append(payload)
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory); reports = home / 'Library/Logs/DiagnosticReports'; reports.mkdir(parents=True)
            evidence = home / 'evidence'; evidence.mkdir(); sequence = []
            def delayed(_):
                index = 1 if not sequence else 0; sequence.append(index)
                payload = reports_data[index]; path = reports / (payload['procName'] + '-late.ips')
                path.write_text(json.dumps({'bug_type': '309'}) + '\n' + json.dumps(payload))
                timestamp = diagnostic.instant(processes[index]['finishedWall']).timestamp(); os.utime(path, (timestamp, timestamp))
            with patch.object(diagnostic.Path, 'home', return_value=home), \
                    patch.object(diagnostic.time, 'monotonic', side_effect=[0, 0, 1, 31, 31]), \
                    patch.object(diagnostic.time, 'sleep', side_effect=delayed):
                records = diagnostic.collect_reused_reports(evidence, processes, 'a' * 64, identity)
            self.assertEqual(sequence, [1, 0])
            self.assertTrue(all(records[owner['pid']]['qualifiedCount'] == 1 for owner in processes))
            payload = reports_data[0]; duplicate = reports / (payload['procName'] + '-duplicate.ips')
            duplicate.write_text(json.dumps({'bug_type': '309'}) + '\n' + json.dumps(payload))
            timestamp = diagnostic.instant(processes[0]['finishedWall']).timestamp(); os.utime(duplicate, (timestamp, timestamp))
            other = home / 'duplicate-evidence'; other.mkdir()
            with patch.object(diagnostic.Path, 'home', return_value=home):
                duplicate_records = diagnostic.collect_reused_reports(other, processes, 'a' * 64, identity, seconds=0)
            self.assertEqual(duplicate_records[processes[0]['pid']]['qualifiedCount'], 2)

    def test_reuse_observe_executes_only_retained_programs_and_never_a_compiler(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args, binding, originals, toolchain, native, source = self.retained_fixture(root)
            archives = []
            for name, members in (('retained-debug-products.zip', native), ('retained-debug-source.zip', source)):
                path = args.binding / name
                with zipfile.ZipFile(path, 'w') as archive:
                    for member, raw in members.items(): archive.writestr(member, raw)
                archives.append(diagnostic.digest(path.read_bytes()))
            retained = diagnostic.verify_retained_probe(native, source, binding['sourceFiles'],
                (args.binding / 'original-evidence.zip').read_bytes(), originals,
                (diagnostic.ROOT / 'scripts/button_query_diagnostic.swift').read_bytes())
            retained['archiveSHA256'] = archives
            binding.update(schema='nexgenvideo/button-query-crash-reuse-binding/1', diagnosticMode=diagnostic.REUSE_KIND,
                retainedCompiler=retained)
            (args.binding / 'binding.json').write_text(json.dumps(binding)); args.reuse_compiler = True
            home = root / 'home'; reports = home / 'Library/Logs/DiagnosticReports'; reports.mkdir(parents=True)
            _, sample = self.ips(); identity = sample['usedImages'][0]['uuid']; calls = []
            def output(command, **_):
                if command[:3] == ['xcrun', 'dwarfdump', '--uuid']:
                    return 'UUID: ' + identity + ' (arm64) ' + command[-1]
                values = {('uname', '-m'): 'arm64', ('xcodebuild', '-version'): toolchain['xcode'],
                    ('sw_vers', '-productVersion'): toolchain['osVersion'], ('sw_vers', '-buildVersion'): toolchain['osBuild'],
                    ('swift', '--version'): toolchain['swift']}
                return values[tuple(command)]
            def execute(command, log, _):
                self.assertNotEqual(command[0], 'xcrun'); calls.append(command)
                pid = 1000 + len(calls); mode = command[1]
                owner, report = self.ips(); owner.update(pid=pid, command=command,
                    executableSHA256=diagnostic.digest(Path(command[0]).read_bytes()))
                report.update(pid=pid, procName=Path(command[0]).name, procPath=command[0])
                log.write_bytes(b''); log.with_suffix('.process.json').write_text(json.dumps(owner))
                records = [dict(schema='nexgenvideo/button-query-stage/1', pid=pid, mode=mode, mainThread=True,
                    stage='observe-entered', uptime=1)]
                Path(command[-1]).write_bytes(b'\n'.join(json.dumps(item).encode() for item in records))
                path = reports / (report['procName'] + '-fixture.ips')
                path.write_text(json.dumps({'bug_type': '309'}) + '\n' + json.dumps(report))
                timestamp = diagnostic.instant(owner['finishedWall']).timestamp(); os.utime(path, (timestamp, timestamp))
                raise ValueError('Owned framework process failed; original log retained')
            with self.observer_runtime(originals, toolchain), patch.object(diagnostic.Path, 'home', return_value=home), \
                    patch.object(diagnostic.subprocess, 'check_output', side_effect=output), \
                    patch.object(diagnostic, 'owned_command', side_effect=execute):
                diagnostic.observe(args)
            self.assertEqual(len(calls), 2)
            receipt = json.loads((args.evidence / 'receipt.json').read_text())
            self.assertTrue(receipt['measurementComplete'])
            self.assertTrue(all(item['status'] == 'captured-crash' for item in receipt['results']))
            self.assertEqual(receipt['compilerReuse']['compilerExecutions'], 0)
            self.assertFalse((args.evidence / 'compiler.process.json').exists())
            self.assertFalse(receipt['appAcceptance'])

    def observer_fixture(self, root):
        binding_dir = root / 'binding'; binding_dir.mkdir()
        toolchain = dict(xcode='Xcode 27.2', osVersion='27.2', osBuild='26B123', swift='Swift fixture toolchain')
        template = self.archive(root)
        original = binding_dir / 'original-evidence.zip'
        with zipfile.ZipFile(template) as source, zipfile.ZipFile(original, 'w') as target:
            for name in source.namelist():
                raw = source.read(name)
                if name.endswith('retained-engine-receipt.json'):
                    raw = json.dumps(dict(toolchain=toolchain)).encode()
                target.writestr(name, raw)
        originals = {name: (diagnostic.ROOT / name).read_bytes() for name in diagnostic.FILES}
        files = {name: dict(SHA256=diagnostic.digest(raw), gitBlob='b' * 40) for name, raw in originals.items()}
        observations, source, _ = self.crash_payload()
        source_binding = json.loads(source['binding.json']); source_binding['sourceFiles'] = files
        source['binding.json'] = json.dumps(source_binding).encode()
        source['original-evidence.zip'] = original.read_bytes()
        receipt = json.loads(observations['receipt.json'])
        receipt['bindingSHA256'] = diagnostic.digest(source['binding.json'])
        observations['receipt.json'] = json.dumps(receipt).encode()
        artifacts = []
        for index, (filename, name, members) in enumerate((
                ('prior-observations.zip', f'native-button-query-{diagnostic.PRIOR_RUN}-a1', observations),
                ('prior-source-binding.zip', 'native-button-query-source-binding', source))):
            path = binding_dir / filename
            with zipfile.ZipFile(path, 'w') as archive:
                for member, raw in members.items(): archive.writestr(member, raw)
            artifacts.append(dict(id=100 + index, name=name, expired=False,
                digest='sha256:' + diagnostic.digest(path.read_bytes()),
                workflow_run=dict(id=diagnostic.PRIOR_RUN, head_sha=diagnostic.PRIOR_SOURCE)))
        prior = diagnostic.verify_crash_payload(observations, source, files, original.read_bytes())
        prior.update(artifacts=artifacts, request=dict(source_binding_artifact_id=101,
            source_binding_artifact_sha256=artifacts[1]['digest'].removeprefix('sha256:')))
        binding = dict(schema='nexgenvideo/button-query-crash-binding/1', diagnosticMode=diagnostic.CRASH_KIND,
            sourceSHA='a' * 40, sourceTree='b' * 40, runID='123', attempt='1',
            harnessFiles={name: diagnostic.digest((diagnostic.ROOT / name).read_bytes()) for name in diagnostic.HARNESS},
            originalArtifact=dict(digest='sha256:' + diagnostic.digest(original.read_bytes())),
            originalEvidence=diagnostic.failure_archive(original), sourceFiles=files, priorCrashes=prior)
        (binding_dir / 'binding.json').write_text(json.dumps(binding))
        return SimpleNamespace(binding=binding_dir, evidence=root / 'evidence', capture_crashes=True), binding, originals, toolchain

    @contextmanager
    def observer_runtime(self, originals, toolchain):
        def git(*args):
            if args == ('rev-parse', 'HEAD'): return ('a' * 40).encode()
            if args == ('rev-parse', 'HEAD^{tree}'): return ('b' * 40).encode()
            if args == ('status', '--porcelain', '--untracked-files=no'): return b''
            if args[0] == 'show': return originals[args[1].split(':', 1)[1]]
            raise AssertionError(args)
        def output(command, **_):
            values = {('uname', '-m'): 'arm64', ('xcodebuild', '-version'): toolchain['xcode'],
                ('sw_vers', '-productVersion'): toolchain['osVersion'], ('sw_vers', '-buildVersion'): toolchain['osBuild'],
                ('swift', '--version'): toolchain['swift']}
            return values[tuple(command)]
        def legacy_zip(first, second): return builtins.zip(first, second)
        with patch.dict(os.environ, GITHUB_SHA='a' * 40, GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1'), \
                patch.object(diagnostic, 'git', side_effect=git), \
                patch.object(diagnostic.subprocess, 'check_output', side_effect=output), \
                patch.object(diagnostic, 'zip', legacy_zip, create=True), \
                patch.object(diagnostic, 'owned_command', side_effect=RuntimeError('native compiler boundary')) as compiler:
            yield compiler

    def test_crash_observer_entry_reaches_native_boundary_without_keyword_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            args, _, originals, toolchain = self.observer_fixture(Path(directory))
            with self.observer_runtime(originals, toolchain) as compiler, \
                    self.assertRaisesRegex(RuntimeError, '^native compiler boundary$'):
                diagnostic.observe(args)
            compiler.assert_called_once()
            self.assertEqual(compiler.call_args.args[0][:2], ['xcrun', 'swiftc'])
            entry = json.loads((args.evidence / 'observer-entry.json').read_text())
            self.assertEqual(entry['python']['version'], diagnostic.sys.version)
            self.assertEqual(entry['python']['executable'], diagnostic.sys.executable)
            self.assertEqual(entry['python']['versionInfo'], list(diagnostic.sys.version_info))
            self.assertFalse(entry['appAcceptance'])
            subsets = json.loads((args.evidence / 'source-subsets.json').read_text())
            self.assertEqual(set(subsets['originals']), set(diagnostic.FILES))
            self.assertEqual(json.loads((args.evidence / 'toolchain.json').read_text())['actual'], toolchain)

    def test_crash_observer_rejects_missing_extra_reordered_or_changed_archives_before_native(self):
        variants = ('missing', 'extra', 'not-list', 'not-object', 'reordered', 'role', 'run', 'source', 'id',
                    'duplicate-id', 'request-id', 'request-digest', 'digest', 'bytes', 'embedded-original')
        for variant in variants:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                args, binding, originals, toolchain = self.observer_fixture(Path(directory))
                prior = binding['priorCrashes']; artifacts = prior['artifacts']
                if variant == 'missing': prior['artifacts'] = artifacts[:1]
                elif variant == 'extra': artifacts.append(copy.deepcopy(artifacts[0]))
                elif variant == 'not-list': prior['artifacts'] = None
                elif variant == 'not-object': artifacts[0] = None
                elif variant == 'reordered': artifacts.reverse()
                elif variant == 'role': artifacts[0]['name'] = 'another-role'
                elif variant == 'run': artifacts[0]['workflow_run']['id'] = 1
                elif variant == 'source': artifacts[0]['workflow_run']['head_sha'] = 'c' * 40
                elif variant == 'id': artifacts[0]['id'] = True
                elif variant == 'duplicate-id': artifacts[0]['id'] = artifacts[1]['id']
                elif variant == 'request-id': prior['request']['source_binding_artifact_id'] = 1
                elif variant == 'request-digest': prior['request']['source_binding_artifact_sha256'] = 'c' * 64
                elif variant == 'digest': artifacts[0]['digest'] = 'sha256:' + 'c' * 64
                elif variant == 'bytes': (args.binding / 'prior-observations.zip').write_bytes(b'changed')
                else:
                    path = args.binding / 'prior-source-binding.zip'
                    members = diagnostic.zip_members(path); members['original-evidence.zip'] = b'changed'
                    with zipfile.ZipFile(path, 'w') as archive:
                        for name, raw in members.items(): archive.writestr(name, raw)
                    checksum = diagnostic.digest(path.read_bytes())
                    artifacts[1]['digest'] = 'sha256:' + checksum
                    prior['request']['source_binding_artifact_sha256'] = checksum
                (args.binding / 'binding.json').write_text(json.dumps(binding))
                with self.observer_runtime(originals, toolchain) as compiler, self.assertRaises(ValueError):
                    diagnostic.observe(args)
                compiler.assert_not_called()
                failure = json.loads((args.evidence / 'observer-failure.json').read_text())
                self.assertEqual(failure['exceptionType'], 'ValueError')
                self.assertFalse(failure['appAcceptance'])

    def test_crash_observer_retains_actual_interpreter_and_early_exception_without_acceptance(self):
        for variant, expected in [('missing', FileNotFoundError), ('json', json.JSONDecodeError), ('run', ValueError)]:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                args, binding, originals, toolchain = self.observer_fixture(Path(directory))
                if variant == 'missing': args.binding = Path(directory) / 'missing'
                elif variant == 'json': (args.binding / 'binding.json').write_text('{')
                else:
                    binding['runID'] = 'another-run'
                    (args.binding / 'binding.json').write_text(json.dumps(binding))
                with self.observer_runtime(originals, toolchain) as compiler, self.assertRaises(expected) as raised:
                    diagnostic.observe(args)
                compiler.assert_not_called()
                entry = json.loads((args.evidence / 'observer-entry.json').read_text())
                failure = json.loads((args.evidence / 'observer-failure.json').read_text())
                self.assertEqual(entry['python']['implementation'], diagnostic.sys.implementation.name)
                self.assertEqual(entry['pid'], os.getpid())
                self.assertEqual(failure['exceptionType'], type(raised.exception).__name__)
                self.assertEqual(failure['message'], str(raised.exception))
                self.assertFalse(entry['appAcceptance'])
                self.assertFalse(failure['appAcceptance'])

    def crash_env(self):
        binding = dict(schema='nexgenvideo/button-query-crash-request/1', producer_run_id=diagnostic.PRIOR_RUN,
            producer_source_sha=diagnostic.PRIOR_SOURCE, job_id=diagnostic.PRIOR_JOB,
            source_binding_artifact_id=13468987097, source_binding_artifact_sha256='c' * 64)
        return dict(self.env, KIND=diagnostic.CRASH_KIND, CANDIDATE_RUN='42121681154', CANDIDATE_ARTIFACT='13461467380',
            CANDIDATE_DIGEST='a14ad1c9fbcc0feb712ca93ec8ea3e354591be5e7834ae2b7a94bd2bf28a73f7',
            EXTRA_FAILURE='13469067268', EXTRA_FAILURE_SHA='d' * 64, RUNTIME_FAILURE_BINDING=json.dumps(binding))

    def crash_payload(self):
        files = {'original.swift': {'SHA256': 'a' * 64, 'gitBlob': 'b' * 40}}
        binding = dict(schema='nexgenvideo/button-query-binding/1', sourceSHA=diagnostic.PRIOR_SOURCE,
            sourceTree='4b944c7fd973270c072160f48b243b64f9de3567', runID=str(diagnostic.PRIOR_RUN), attempt='1',
            originalRun=dict(id=42121681154, head_sha=diagnostic.SOURCE),
            originalArtifact=dict(id=13461467380, digest='sha256:a14ad1c9fbcc0feb712ca93ec8ea3e354591be5e7834ae2b7a94bd2bf28a73f7'),
            sourceFiles=files, sourceProof=dict(schema='core-pr-source-composition/v1', sourceSHA=diagnostic.PRIOR_SOURCE,
                runID=str(diagnostic.PRIOR_RUN), attempt='1', originalRun=dict(id=42140974612)))
        source = {'binding.json': json.dumps(binding).encode(), 'original-evidence.zip': b'fresh qualified original ZIP bytes'}
        results, observations = [], {}
        for index, mode in enumerate(diagnostic.MODES):
            process = dict(pid=100 + index, exitCode=-5 if mode in diagnostic.CRASH_MODES else 0,
                processReaped=True, timedOut=False)
            results.append(dict(mode=mode, status='failed-observation', process=process))
            observations[mode + '.process.json'] = json.dumps(process).encode()
            observations[mode + '.log'] = b''
        receipt = dict(schema='nexgenvideo/button-query-observation/1', sourceSHA=diagnostic.PRIOR_SOURCE,
            runID=str(diagnostic.PRIOR_RUN), attempt='1', bindingSHA256=diagnostic.digest(source['binding.json']),
            measurementComplete=False, appAcceptance=False, appBuilds=0, nativeUnitExecutions=0,
            originalFailureResolved=False, results=results)
        observations['receipt.json'] = json.dumps(receipt).encode()
        return observations, source, files

    def ips(self):
        command = '/tmp/owned-123-a1/nbq0000000123'
        process = dict(pid=77, command=[command], exitCode=-5, processReaped=True, timedOut=False,
            executableSHA256='a' * 64, startedWall='2026-11-06T01:00:00+00:00', finishedWall='2026-11-06T01:00:02+00:00')
        report = dict(pid=77, procName=Path(command).name, procPath='/Users/USER/private/owned-123-a1/nbq0000000123',
            procLaunch='2026-11-06T01:00:00.100+00:00', captureTime='2026-11-06T01:00:01.900+00:00',
            exception=dict(signal='SIGTRAP', type='EXC_BREAKPOINT'), faultingThread=0,
            threads=[dict(frames=[dict(imageIndex=0, imageOffset=123, symbol='actual failure')])],
            usedImages=[dict(name=Path(command).name, path=command, base=4096, size=4096, uuid='11111111-2222-4333-8444-555555555555')])
        return process, report

    def slow_report(self, mode):
        frame = [0, 0, 600, 200]
        geometry = dict(window=55, frame=frame, CGWindows=[dict(pid=123, number=55, frame=frame, onscreen=True)])
        root = dict(AXRole='AXWindow', pid=123, parent=None, AXPosition=[0, 0], AXSize=[600, 200],
            statuses=dict(attributeNames=0, AXChildren=0, pid=0, AXRole=0, AXPosition=0, AXSize=0),
            attributeNames=['AXRole', 'AXChildren', 'AXPosition', 'AXSize'], attributeNamesType=10,
            **{'advertised:AXChildren': True, 'type:AXChildren': 10, 'childTypes:AXChildren': [99], 'count:AXChildren': 1})
        button = dict(AXRole='AXButton', pid=123, parent=0, AXPosition=[20, 20], AXSize=[50, 28],
            statuses=dict(attributeNames=0, AXChildren=-25212, pid=0, AXRole=0, AXPosition=0, AXSize=0),
            attributeNames=['AXRole', 'AXPosition', 'AXSize'], attributeNamesType=10,
            **{'advertised:AXChildren': False, 'type:AXChildren': None, 'count:AXChildren': None})
        node = dict(pid=123, role='AXButton', enabled=True, title=None, label='Undo', publicScreenFrame=[20, 20, 50, 28],
            statuses=dict(pid=0, AXRole=0, AXEnabled=0, AXPosition=0, AXSize=0))
        warm = dict(pid=123, window=55, expectedWindowFrame=frame, readOnMainThread=False, plane='public-AX',
            truncated=False, failure=None, windowCandidates=1, nodes=[node])
        query = dict(warm, truncated=True, failure='cancelled' if mode == 'slow-cancel' else 'AX-read-AXChildren:-25204',
            startedUptime=2.0, finishedUptime=2.2, nodes=[dict(label='Bounded child', statuses={'AXChildren': -25204, 'timeout:AXChildren': 0})])
        raw = dict(pid=123, window=55, requestFrame=frame, readOnMainThread=False, nodes=[root, button],
            windows=[copy.deepcopy(root)], windowsAfter=[copy.deepcopy(root)], errors=[],
            applicationStatuses=dict(pid=0, AXWindows=0), applicationStatusesAfter=dict(pid=0, AXWindows=0),
            hierarchyEnumerationEnded=True, hierarchyComplete=True, targetStillPresentByCFEqual=True,
            CFArrayTypeID=10, AXUIElementTypeID=99)
        return dict(schema='nexgenvideo/button-query-framework-control/1', mode=mode, pid=123,
            mainLoopRunning=True, mainThread=True, originalQueryBeforeAdditionalAX=True, appAcceptance=False,
            sourceSubsetFrameworkFixture=True, parallelAppTestHost=False, originalFirstQuery=warm,
            originalQueryAfterCGStability=warm, queryAfterAdditionalAX=warm,
            beforeFirstQuery=geometry, beforeWarmQuery=geometry, afterWarmQuery=geometry,
            beforeLastQuery=geometry, beforeRawAttributes=geometry, afterRawAttributes=geometry,
            rawAttributesAfterOriginalQueries=raw,
            slowObservation=dict(status='observed-after-complete-warmup', getterEntered=True, enabledUndoCount=1,
                enteredAt=2.05, returnedAt=2.4, cancelRequestedAt=2.1 if mode == 'slow-cancel' else 0,
                requestedSeconds=1 if mode == 'slow-cancel' else 0.2, query=query))

    def test_crash_mode_requires_exact_failed_producer_without_ignored_selectors(self):
        env = self.crash_env()
        diagnostic.validate_inputs(env)
        for key, value in [('EXTRA_FAILURE', ''), ('EXTRA_FAILURE_SHA', 'bad'), ('RUNTIME_FAILURE_BINDING', ''),
                ('CANDIDATE_RUN', '12'), ('EXTRA_PRODUCTS', '99'), ('JOURNEY_JOB', '1')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(env, **{key: value}))
        for key, value in [('producer_run_id', True), ('producer_run_id', 1), ('producer_source_sha', 'a' * 40),
                ('job_id', 1), ('source_binding_artifact_id', False), ('unexpected', 'x')]:
            changed = json.loads(env['RUNTIME_FAILURE_BINDING']); changed[key] = value
            with self.subTest(binding=key), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(env, RUNTIME_FAILURE_BINDING=json.dumps(changed)))

    def test_prior_crash_payload_requires_exact_source_objects_and_binding_bytes(self):
        observations, source, files = self.crash_payload()
        self.assertEqual(len(diagnostic.verify_crash_payload(observations, source, files, source['original-evidence.zip'])['cases']), 2)
        for archive in ({'binding.json': source['binding.json']}, dict(source, **{'original-evidence.zip': b'other ZIP bytes'})):
            with self.subTest(embedded=list(archive)), self.assertRaises(ValueError):
                diagnostic.verify_crash_payload(observations, archive, files, source['original-evidence.zip'])
        for key, value in [('sourceFiles', {}), ('sourceTree', 'c' * 40), ('originalRun', dict(id=1, head_sha=diagnostic.SOURCE))]:
            changed = json.loads(source['binding.json']); changed[key] = value
            archive = dict(source, **{'binding.json': json.dumps(changed).encode()})
            receipt = json.loads(observations['receipt.json']); receipt['bindingSHA256'] = diagnostic.digest(archive['binding.json'])
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.verify_crash_payload(dict(observations, **{'receipt.json': json.dumps(receipt).encode()}), archive, files, source['original-evidence.zip'])

    def test_prior_slow_failures_cannot_be_substituted_by_timeouts_or_other_signals(self):
        observations, source, files = self.crash_payload()
        for key, value in [('exitCode', 0), ('exitCode', -6), ('timedOut', True), ('processReaped', False), ('pid', 0)]:
            changed = copy.deepcopy(observations)
            process = json.loads(changed['slow-cancel.process.json']); process[key] = value
            changed['slow-cancel.process.json'] = json.dumps(process).encode()
            receipt = json.loads(changed['receipt.json'])
            next(item for item in receipt['results'] if item['mode'] == 'slow-cancel')['process'] = process
            changed['receipt.json'] = json.dumps(receipt).encode()
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.verify_crash_payload(changed, source, files, source['original-evidence.zip'])

    def test_ips_requires_two_objects_exact_pid_executable_and_owned_lifetime(self):
        process, report = self.ips()
        encode = lambda value: (json.dumps({'bug_type': '309'}) + '\n' + json.dumps(value)).encode()
        self.assertEqual(diagnostic.validate_crash(encode(report), process, 'a' * 64)['pid'], 77)
        for key, value in [('pid', 78), ('procName', 'other'), ('procPath', '/tmp/other/nbq0000000123'),
                ('procLaunch', '2026-11-05T01:00:00+00:00'), ('captureTime', '2026-11-06T01:01:00+00:00')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostic.validate_crash(encode(dict(report, **{key: value})), process, 'a' * 64)
        for raw in [json.dumps(report).encode(), encode(report) + b'\n{}']:
            with self.assertRaises(ValueError): diagnostic.validate_crash(raw, process, 'a' * 64)
        for bug_type in (None, '288', 309, '', '309-other'):
            metadata = {} if bug_type is None else {'bug_type': bug_type}
            raw = (json.dumps(metadata) + '\n' + json.dumps(report)).encode()
            with self.subTest(bug_type=bug_type), self.assertRaises(ValueError):
                diagnostic.validate_crash(raw, process, 'a' * 64)

    def test_ips_must_contain_the_actual_sigtrap_and_usable_faulting_stack(self):
        process, report = self.ips()
        for key, value in [('exception', dict(signal='SIGABRT', type='EXC_CRASH')), ('faultingThread', True),
                ('faultingThread', 1), ('threads', [dict(frames=[])]), ('usedImages', []), ('usedImages', [None]),
                ('usedImages', [{}])]:
            raw = (json.dumps({'bug_type': '309'}) + '\n' + json.dumps(dict(report, **{key: value}))).encode()
            with self.subTest(key=key), self.assertRaises(ValueError): diagnostic.validate_crash(raw, process, 'a' * 64)
        image = report['usedImages'][0]
        for key, value in [('base', 0), ('base', True), ('size', 0), ('size', 123), ('size', 2 ** 64),
                ('uuid', None), ('uuid', 'unknown'), ('uuid', '00000000-0000-0000-0000-000000000000')]:
            changed = dict(report, usedImages=[dict(image, **{key: value})])
            raw = (json.dumps({'bug_type': '309'}) + '\n' + json.dumps(changed)).encode()
            with self.subTest(image=key, value=value), self.assertRaises(ValueError):
                diagnostic.validate_crash(raw, process, 'a' * 64)
        changed = dict(report, usedImages=[dict(image, name='', path='')])
        with self.assertRaises(ValueError):
            diagnostic.validate_crash((json.dumps({'bug_type': '309'}) + '\n' + json.dumps(changed)).encode(), process, 'a' * 64)
        raw = (json.dumps({'bug_type': '309'}) + '\n' + json.dumps(report)).encode()
        self.assertEqual(diagnostic.validate_crash(raw, process, 'a' * 64)['resolvedFaultingFrames'][0]['runtimeAddress'], 4219)

    def test_owned_report_acquisition_retains_raw_candidates_but_never_qualifies_wrong_pid(self):
        process, report = self.ips()
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory); reports = home / 'Library/Logs/DiagnosticReports'; reports.mkdir(parents=True)
            evidence = home / 'evidence'; evidence.mkdir()
            for name, pid in [('a', 78), ('b', 77)]:
                target = reports / (report['procName'] + '-' + name + '.ips')
                target.write_text(json.dumps({'bug_type': '309'}) + '\n' + json.dumps(dict(report, pid=pid)))
                timestamp = diagnostic.instant(process['finishedWall']).timestamp()
                os.utime(target, (timestamp, timestamp))
            with patch.object(diagnostic.Path, 'home', return_value=home):
                captured = diagnostic.collect_crash_reports(evidence, process, 'a' * 64, seconds=0)
            self.assertEqual(captured['identity']['pid'], 77)
            acquisition = json.loads((evidence / '77-crash-acquisition.json').read_text())
            self.assertEqual(acquisition['qualifiedCount'], 1)
            self.assertEqual(sum(item['qualified'] for item in acquisition['candidates']), 1)
            self.assertEqual(len(list(evidence.glob('*.ips'))), 1)

    def test_crash_mode_normal_alternative_requires_both_original_native_contracts(self):
        for mode in diagnostic.CRASH_MODES:
            diagnostic.validate_slow_normal(self.slow_report(mode), mode, 123)

    def test_not_reached_slow_observations_cannot_replace_missing_crash_evidence(self):
        for status in ('not-reached-warmup-unqualified', 'not-reached-getter-entry'):
            report = self.slow_report('slow-cancel'); report['slowObservation']['status'] = status
            diagnostic.validate_observation(report, 'slow-cancel', 123)
            with self.subTest(status=status), self.assertRaises(ValueError):
                diagnostic.validate_slow_normal(report, 'slow-cancel', 123)

    def test_normal_slow_timing_cancellation_and_last_child_timeout_are_independent_guards(self):
        for mode in diagnostic.CRASH_MODES:
            for key, value in [('enteredAt', 1), ('returnedAt', 0), ('getterEntered', False), ('enabledUndoCount', True)]:
                report = self.slow_report(mode); report['slowObservation'][key] = value
                with self.subTest(mode=mode, key=key), self.assertRaises(ValueError): diagnostic.validate_slow_normal(report, mode, 123)
            report = self.slow_report(mode); report['slowObservation']['query']['finishedUptime'] = 3
            with self.assertRaises(ValueError): diagnostic.validate_slow_normal(report, mode, 123)
        report = self.slow_report('slow-cancel'); report['slowObservation']['cancelRequestedAt'] = 0
        with self.assertRaises(ValueError): diagnostic.validate_slow_normal(report, 'slow-cancel', 123)
        for status in (0, None, False):
            report = self.slow_report('slow-timeout'); report['slowObservation']['query']['nodes'][0]['statuses']['AXChildren'] = status
            with self.subTest(status=status), self.assertRaises(ValueError): diagnostic.validate_slow_normal(report, 'slow-timeout', 123)

    def test_crash_mode_has_its_own_source_gated_mac_leaf_and_preserves_all_five_default_cases(self):
        workflow = yaml.safe_load((diagnostic.ROOT / '.github/workflows/diagnostic-acceptance.yml').read_text())
        guard = next(step for step in workflow['jobs']['source']['steps']
                     if step.get('name') == 'Require exact public transport continuation inputs')
        code = guard['run'].split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        env = dict(self.crash_env(), JOURNEY_JOB='', JOURNEY_ARTIFACT='', JOURNEY_DIGEST='',
            PACKAGING_PRODUCER_SOURCE='', PACKAGING_PROVENANCE_ARTIFACT_ID='', PACKAGING_PROVENANCE_ARTIFACT_SHA256='')
        with patch.dict(os.environ, env, clear=True):
            exec(compile(code, '<complete-crash-input-guard>', 'exec'), {})
        foreign = dict(KIND=diagnostic.CRASH_KIND, SCALE='1', VERIFIED_PR='123', CANDIDATE_RUN='456',
            CANDIDATE_ARTIFACT='789', CANDIDATE_SOURCE='a' * 40, CANDIDATE_DIGEST='c' * 64,
            PACKAGING_PRODUCER_SOURCE='', PACKAGING_PROVENANCE_ARTIFACT_ID='', PACKAGING_PROVENANCE_ARTIFACT_SHA256='',
            DMG_DIGEST='e' * 64, RUNTIME_FAILURE_BINDING=json.dumps({'diagnostic': {}, 'bpy': {}}))
        with patch.dict(os.environ, foreign, clear=True), self.assertRaisesRegex(ValueError, 'cannot be ignored'):
            exec(compile(code, '<foreign-crash-input-guard>', 'exec'), {})
        leaf = workflow['jobs']['native-button-query-crash']
        self.assertEqual((leaf['needs'], leaf['runs-on'], leaf['timeout-minutes']), ('source', 'macrunner', 5))
        self.assertEqual(leaf['if'], "inputs.candidate_kind == 'native-button-query-crash'")
        command = next(step['run'] for step in leaf['steps'] if 'run' in step)
        self.assertIn('--capture-crashes', command)
        original = workflow['jobs']['native-button-query']
        self.assertNotIn('--capture-crashes', next(step['run'] for step in original['steps'] if 'run' in step))
        self.assertEqual(diagnostic.MODES, ('enabled', 'disabled', 'duplicate', 'slow-cancel', 'slow-timeout'))

    def setUp(self):
        self.env = dict(KIND='native-button-query', CANDIDATE_RUN='12', CANDIDATE_ARTIFACT='34', VERIFIED_PR='56',
                        CANDIDATE_SOURCE=diagnostic.SOURCE, CANDIDATE_DIGEST='b' * 64, SCALE='1', DMG_DIGEST='')
        self.run = dict(id=12, head_sha=diagnostic.SOURCE, run_attempt=1, actor=dict(login='iret77'),
                        repository=dict(full_name='iret77/nexgenvideo'), path='.github/workflows/release.yml',
                        event='workflow_dispatch', status='completed', conclusion='failure')
        self.job = dict(id=78, name='release-build', run_id=12, head_sha=diagnostic.SOURCE, run_attempt=1,
                        labels=['macrunner'], status='completed', conclusion='failure', steps=[
                            dict(name='Build the exact release test configuration', conclusion='success'),
                            dict(name='Test the exact release configuration', conclusion='failure')])
        self.jobs = dict(total_count=1, jobs=[self.job])
        self.artifact = dict(id=34, name='release-test-evidence', expired=False, digest='sha256:' + 'b' * 64,
                             workflow_run=dict(id=12, head_sha=diagnostic.SOURCE))

    def test_inputs_reject_every_unconsumed_selector_and_missing_identity(self):
        diagnostic.validate_inputs(self.env)
        for field, value in [('KIND', 'signed-release'), ('CANDIDATE_RUN', '0'), ('CANDIDATE_ARTIFACT', '-1'),
                             ('VERIFIED_PR', ''), ('CANDIDATE_SOURCE', 'c' * 40), ('CANDIDATE_DIGEST', 'B' * 64),
                             ('SCALE', '1.5'), *[(key, 'unexpected') for key in (
                                 'DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'EXTRA_SOURCE',
                                 'EXTRA_PRODUCTS', 'EXTRA_FAILURE', 'EXTRA_PRODUCTS_SHA', 'EXTRA_FAILURE_SHA',
                                 'RUNTIME_FAILURE_BINDING', 'PACKAGING_PRODUCER_SOURCE', 'PACKAGING_PROVENANCE_ARTIFACT_ID',
                                 'PACKAGING_PROVENANCE_ARTIFACT_SHA256')]]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                diagnostic.validate_inputs(dict(self.env, **{field: value}))

    def test_producer_requires_actual_failed_native_job_and_exact_source_attempt(self):
        self.assertEqual(diagnostic.verify_producer(self.run, self.jobs, self.artifact, self.env), self.job)
        for key, bad in [('id', 13), ('head_sha', 'c' * 40), ('run_attempt', 2), ('conclusion', 'success'),
                         ('actor', dict(login='someone')), ('repository', dict(full_name='other/repository'))]:
            with self.subTest(field=key), self.assertRaises(ValueError):
                diagnostic.verify_producer(dict(self.run, **{key: bad}), self.jobs, self.artifact, self.env)
        for key, bad in [('run_id', 13), ('head_sha', 'c' * 40), ('run_attempt', 2), ('conclusion', 'success'),
                         ('labels', ['ubuntu-24.04']), ('status', 'in_progress')]:
            jobs = dict(total_count=1, jobs=[dict(self.job, **{key: bad})])
            with self.subTest(job=key), self.assertRaises(ValueError):
                diagnostic.verify_producer(self.run, jobs, self.artifact, self.env)

    def test_failed_compile_or_ambiguous_native_job_cannot_authorize_observation(self):
        for variant in ('compile', 'test', 'missing', 'duplicate', 'truncated'):
            jobs = copy.deepcopy(self.jobs)
            if variant == 'compile': jobs['jobs'][0]['steps'][0]['conclusion'] = 'failure'
            elif variant == 'test': jobs['jobs'][0]['steps'][1]['conclusion'] = 'success'
            elif variant == 'missing': jobs = dict(total_count=0, jobs=[])
            elif variant == 'duplicate': jobs = dict(total_count=2, jobs=[self.job, self.job])
            else: jobs['total_count'] = 2
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                diagnostic.verify_producer(self.run, jobs, self.artifact, self.env)

    def test_evidence_identity_cannot_move_between_runs_or_change_digest(self):
        for key, bad in [('id', 35), ('name', 'NexGenVideo-app'), ('expired', True), ('digest', 'sha256:' + 'c' * 64),
                         ('workflow_run', dict(id=13, head_sha=diagnostic.SOURCE)),
                         ('workflow_run', dict(id=12, head_sha='c' * 40))]:
            with self.subTest(field=key), self.assertRaises(ValueError):
                diagnostic.verify_producer(self.run, self.jobs, dict(self.artifact, **{key: bad}), self.env)

    def archive(self, root, change=None):
        prefix = '_temp/release-test-evidence/'
        suite = dict(sourceSHA=diagnostic.SOURCE, completed=False, scope='all', filter='', phases=[
            dict(name=name, exitCode=code) for name, code in [('xctest', 0), ('engine-swift-testing', 0), ('app-swift-testing', 1)]])
        host = dict(sourceSHA=diagnostic.SOURCE, started=True, completed=True, abiSucceeded=False, mainThread=True,
                    runReturnedAfterCompletion=True)
        issues = [dict(kind='event', payload=dict(kind='issueRecorded', issue=dict(isFailure=True, isKnown=False),
            testID='NexGenVideoTests.NativeButtonInteractionTests/' + name + '()/NativeButtonInteractionTests.swift:1:6'))
            for name in sorted(diagnostic.FAILED)]
        issues += copy.deepcopy(issues[:2] * 4)
        if change == 'foreign': issues[0]['payload']['testID'] = 'NexGenVideoTests.OtherTests/other()/OtherTests.swift:1:6'
        if change == 'missing': issues.pop()
        if change == 'host': host['abiSucceeded'] = True
        if change == 'filtered': suite['filter'] = 'NativeButtonInteractionTests'
        path = root / 'original.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, value in [('suite.json', suite), ('app-swift-testing/host-receipt.json', host),
                                ('retained-engine-receipt.json', dict(toolchain=dict(xcode='Xcode 27.2')))]:
                archive.writestr(prefix + name, json.dumps(value))
            archive.writestr(prefix + 'app-swift-testing/events.jsonl', '\n'.join(json.dumps(value) for value in issues))
        return path

    def test_original_failure_archive_keeps_all_issues_and_host_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.archive(Path(directory))
            result = diagnostic.failure_archive(path)
            self.assertEqual(len(result['issues']), 14)
            self.assertEqual(len(result['members']), 4)
            self.assertFalse(result['host']['abiSucceeded'])

    def test_another_failure_branch_or_filtered_original_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for variant in ('foreign', 'missing', 'host', 'filtered'):
                with self.subTest(variant=variant), self.assertRaises(ValueError):
                    diagnostic.failure_archive(self.archive(Path(directory), variant))

    def test_style_subset_preserves_exact_original_byte_ranges_without_stubs(self):
        originals = {path: (diagnostic.ROOT / path).read_bytes() for path in diagnostic.FILES}
        selected, ranges = diagnostic.source_subset(originals)
        self.assertEqual(selected['NativeButtonAccessibility.swift'], originals[diagnostic.QUERY])
        self.assertEqual(selected['CapsuleButton.swift'], originals['Sources/NexGenVideo/UI/CapsuleButton.swift'])
        for name, pieces in ranges.items():
            self.assertEqual(selected[name], b''.join(originals[path][left:right] for path, left, right in pieces))
        self.assertNotIn(b'EditorViewModel', b''.join(selected.values()))
        self.assertNotIn(b'import NexGenEngine', b''.join(selected.values()))
        self.assertIn(b'@Environment(\\.interfaceScale)', selected['CapsuleButton.swift'])

    def test_source_subset_rejects_missing_or_ambiguous_extraction_boundaries(self):
        originals = {path: (diagnostic.ROOT / path).read_bytes() for path in diagnostic.FILES}
        for path, marker in [('Sources/NexGenVideo/UI/AppTheme.swift', b'// MARK: - ClipType color mapping'),
                             ('Sources/NexGenVideo/UI/DesignSystem.swift', b'struct ProjectInterface<Content: View>: View {'),
                             ('Sources/NexGenVideo/UI/PackAccent.swift', b'extension Color {')]:
            for replacement in (b'', marker + marker):
                changed = dict(originals, **{path: originals[path].replace(marker, replacement)})
                with self.subTest(path=path, replacement=replacement), self.assertRaises(ValueError):
                    diagnostic.source_subset(changed)

    def test_owned_timeout_reaps_only_its_fresh_process_group_without_retry(self):
        child = Mock(pid=12345)
        child.wait.side_effect = [subprocess.TimeoutExpired(['probe'], 18), 0]
        with tempfile.TemporaryDirectory() as directory, patch.object(diagnostic.subprocess, 'Popen', return_value=child) as launch, \
                patch.object(diagnostic.os, 'killpg') as kill, self.assertRaisesRegex(ValueError, 'timed out'):
            diagnostic.owned_command(['probe'], Path(directory) / 'probe.log', 18)
        launch.assert_called_once()
        self.assertTrue(launch.call_args.kwargs['start_new_session'])
        self.assertEqual(launch.call_args.kwargs['stdin'], subprocess.DEVNULL)
        kill.assert_called_once_with(12345, signal.SIGTERM)
        self.assertEqual(child.wait.call_count, 2)

    def test_native_observer_needs_both_source_binding_and_current_source_proof(self):
        workflow = yaml.safe_load((diagnostic.ROOT / '.github/workflows/diagnostic-acceptance.yml').read_text())
        native = workflow['jobs']['native-button-query']
        self.assertEqual(native['needs'], 'source')
        self.assertEqual(native['if'], "inputs.candidate_kind == 'native-button-query'")
        self.assertEqual(native['runs-on'], 'macrunner')
        self.assertEqual(native['timeout-minutes'], 5)
        download = next(step for step in native['steps'] if step.get('uses') == 'actions/download-artifact@v4')
        self.assertEqual(download['with']['name'], 'native-button-query-source-binding')
        source = workflow['jobs']['source']['steps']
        proof = next(step for step in source if step.get('name') == 'Reuse complete current merged PR source proof')
        self.assertIn("inputs.candidate_kind == 'native-button-query'", proof['if'])
        binder = next(step for step in source if step.get('name') == 'Bind the original failed button query and unchanged framework sources')
        self.assertLess(source.index(proof), source.index(binder))
        self.assertIn('--source-proof "$RUNNER_TEMP/transport-source-proof"', binder['run'])
        for step in source:
            if step.get('name') == 'Bind the successful release job and immutable artifact':
                self.assertIn("inputs.candidate_kind != 'native-button-query'", step['if'])

    def test_observation_cannot_claim_another_process_or_hide_the_native_child_response(self):
        frame = [0, 0, 600, 200]
        geometry = dict(window=55, frame=frame, CGWindows=[dict(pid=123, number=55, frame=frame, onscreen=True)])
        query = dict(pid=123, window=55, expectedWindowFrame=frame, readOnMainThread=False, plane='public-AX',
                     truncated=True, failure='query-deadline', nodes=[])
        root = dict(AXRole='AXWindow', pid=123, parent=None, AXPosition=[0, 0], AXSize=[600, 200],
                    statuses=dict(attributeNames=0, AXChildren=0, pid=0, AXRole=0, AXPosition=0, AXSize=0),
                    attributeNames=['AXRole', 'AXChildren', 'AXPosition', 'AXSize'], attributeNamesType=10,
                    **{'advertised:AXChildren': True, 'type:AXChildren': 10, 'childTypes:AXChildren': [99], 'count:AXChildren': 1})
        node = dict(AXRole='AXButton', pid=123, parent=0, AXPosition=[20, 20], AXSize=[50, 28],
                    statuses=dict(attributeNames=0, AXChildren=-25212, pid=0, AXRole=0, AXPosition=0, AXSize=0),
                    attributeNames=['AXRole', 'AXPosition', 'AXSize'], attributeNamesType=10,
                    **{'advertised:AXChildren': False, 'type:AXChildren': None, 'count:AXChildren': None})
        raw = dict(pid=123, window=55, requestFrame=frame, readOnMainThread=False, nodes=[root, node],
                   windows=[copy.deepcopy(root)], windowsAfter=[copy.deepcopy(root)], errors=[],
                   applicationStatuses=dict(pid=0, AXWindows=0), applicationStatusesAfter=dict(pid=0, AXWindows=0),
                   hierarchyEnumerationEnded=True, hierarchyComplete=True, targetStillPresentByCFEqual=True,
                   CFArrayTypeID=10, AXUIElementTypeID=99)
        report = dict(schema='nexgenvideo/button-query-framework-control/1', mode='slow-cancel', pid=123,
            mainLoopRunning=True, mainThread=True, originalQueryBeforeAdditionalAX=True, appAcceptance=False,
            sourceSubsetFrameworkFixture=True, parallelAppTestHost=False, originalFirstQuery=query,
            originalQueryAfterCGStability=query, queryAfterAdditionalAX=query,
            beforeFirstQuery=geometry, beforeWarmQuery=geometry, afterWarmQuery=geometry,
            beforeLastQuery=geometry, beforeRawAttributes=geometry, afterRawAttributes=geometry,
            rawAttributesAfterOriginalQueries=raw,
            slowObservation=dict(status='not-reached-warmup-unqualified'))
        diagnostic.validate_observation(report, 'slow-cancel', 123)
        for field, value in [('pid', 124), ('appAcceptance', True), ('originalQueryBeforeAdditionalAX', False),
                             ('slowObservation', dict(status='observed-after-complete-warmup')),
                             ('rawAttributesAfterOriginalQueries', dict(pid=123, readOnMainThread=False, nodes=[]))]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                diagnostic.validate_observation(dict(report, **{field: value}), 'slow-cancel', 123)
        for variant in ('foreign-node', 'other-window', 'unknown-window', 'wrong-root', 'lost-parent',
                        'generic-children', 'lost-child-type', 'hidden-child', 'unfinished', 'deadline',
                        'false-complete', 'unknown-names', 'moved-frame', 'false-status'):
            changed = copy.deepcopy(report)
            value = changed['rawAttributesAfterOriginalQueries']
            if variant == 'foreign-node': value['nodes'][1]['pid'] = 124
            elif variant == 'other-window': value['window'] = 56
            elif variant == 'unknown-window': value['windows'].append(dict(root, AXSize=None))
            elif variant == 'wrong-root': value['nodes'][0]['AXRole'] = 'AXApplication'
            elif variant == 'lost-parent': value['nodes'][1]['parent'] = None
            elif variant == 'generic-children': value['nodes'][1]['statuses']['AXChildren'] = -25200
            elif variant == 'lost-child-type': value['nodes'][0]['childTypes:AXChildren'] = [98]
            elif variant == 'hidden-child': value['nodes'][0]['count:AXChildren'] = 2
            elif variant == 'unfinished': value['hierarchyEnumerationEnded'] = False
            elif variant == 'deadline': value['errors'] = ['deadline']
            elif variant == 'false-complete': value['hierarchyComplete'] = False
            elif variant == 'unknown-names': value['nodes'][1]['attributeNames'] = None
            elif variant == 'moved-frame': changed['afterRawAttributes']['frame'] = [100, 100, 600, 200]
            else: value['nodes'][1]['statuses']['AXChildren'] = False
            with self.subTest(variant=variant), self.assertRaises(ValueError):
                diagnostic.validate_observation(changed, 'slow-cancel', 123)
