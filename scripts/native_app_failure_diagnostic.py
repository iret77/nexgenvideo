"""Measure the original failed App methods without qualifying a release."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import selectors
import shutil
import signal
import subprocess
import time

import app_cohort_v2 as cohort
import compiled_app_release as release
import native_app_target_build as targets
import release_test_repair as retained
from retained_app_test_products import api, archive_bytes, checksum, download, require, write

KIND = 'native-app-native-failure-diagnostic'
FIXTURE = Path(__file__).with_name('fixtures') / 'native-app-failure-1087.json'
FIXTURE_SHA = '8abef4dbd9b38305d3e6b4c5425733d7d90b432e656884f91c2b7995c9f1aed6'
MEMBERS = {'failure-bound.json': ('bound.json', 'boundSHA256'),
           'failure-events.jsonl': ('app-swift-testing/events.jsonl', 'eventSHA256'),
           'failure-host-receipt.json': ('app-swift-testing/host-receipt.json', 'hostReceiptSHA256')}


def fixture():
    require(checksum(FIXTURE) == FIXTURE_SHA, 'Original failure scope changed')
    return json.loads(FIXTURE.read_bytes())


def validate_inputs(event):
    value = fixture()
    inputs = event.get('inputs', {})
    expected = {'candidate_kind': KIND, 'run_id': str(value['failureRunID']),
        'source_sha': value['failureSourceSHA'], 'artifact_id': str(value['failureArtifactID']),
        'artifact_sha256': value['failureArtifactSHA256'], 'interface_scale': '1', 'journey_scenario': 'journey'}
    require(all(str(inputs.get(key, '')) == expected_value for key, expected_value in expected.items()),
        'Diagnostic inputs differ from the exact original failed scope')
    require(re.fullmatch('[1-9][0-9]*', str(inputs.get('verified_pr_run_id', ''))), 'Missing complete merged source proof')
    require(all(not item for key, item in inputs.items() if key not in {*expected, 'verified_pr_run_id'}),
        'Unrelated diagnostic inputs cannot be ignored')
    return value


def measure(raw, expected_ended, expected_skipped=(), expected_cases=None):
    require(raw.endswith(b'\n'), 'Native event stream has no complete final record')
    records = [json.loads(line) for line in raw.split(b'\n') if line]
    require(records and all(isinstance(row, dict) and row.get('version') == '6.4.0'
        and row.get('kind') in {'test', 'event'} for row in records),
        'Unknown native event schema')
    declarations = [row['payload'] for row in records if row.get('kind') == 'test']
    require(all(isinstance(row, dict) and row.get('kind') in {'suite', 'function'}
        and isinstance(row.get('id'), str) for row in declarations), 'Invalid native discovery')
    tests = {row['id']: row for row in declarations}
    require(len(tests) == len(declarations), 'Duplicate native discovery')
    active, starts, ends, skipped, cases, case_ends, issues = set(), Counter(), Counter(), set(), Counter(), Counter(), []
    run_starts = run_ends = 0
    open_cases = Counter()
    for row in records:
        if row.get('kind') != 'event': continue
        event = row['payload']; kind = event['kind']; identity = event.get('testID')
        require(kind in {'runStarted', 'runEnded', 'testCancelled', 'testCaseCancelled', 'testStarted',
            'testEnded', 'testSkipped', 'issueRecorded', 'testCaseStarted', 'testCaseEnded'}, 'Unknown native event kind')
        if kind == 'runStarted':
            require(run_starts == run_ends == 0, 'Repeated native run'); run_starts += 1
        elif kind == 'runEnded':
            require(run_starts == 1 and run_ends == 0 and not active and not any(open_cases.values()),
                'Incomplete native run'); run_ends += 1
        elif kind in {'testCancelled', 'testCaseCancelled'}:
            raise ValueError('Native diagnostic was cancelled')
        elif kind in {'testStarted', 'testEnded', 'testSkipped', 'issueRecorded', 'testCaseStarted', 'testCaseEnded'}:
            require(run_starts == 1 and run_ends == 0 and identity in tests, 'Unbound native event')
            function = tests[identity]['kind'] == 'function'
            if kind == 'testStarted':
                require(identity not in active, 'Repeated active native test'); active.add(identity)
                if function: starts[identity] += 1
            elif kind == 'testEnded':
                require(identity in active and open_cases[identity] == 0, 'Native test ended without a settled start'); active.remove(identity)
                if function: ends[identity] += 1
            elif kind == 'testSkipped':
                require(function and identity not in skipped, 'Invalid native skip'); skipped.add(identity)
            elif kind == 'issueRecorded':
                issue = event.get('issue')
                require(function and identity in active and isinstance(issue, dict)
                    and issue.get('isFailure') is True and issue.get('isKnown') is False, 'Unknown native issue state')
                issues.append(event)
            else:
                require(function and identity in active, 'Parameter case outside its native function')
                if kind == 'testCaseStarted': open_cases[identity] += 1
                else:
                    require(open_cases[identity] > 0, 'Native parameter case ended before start'); open_cases[identity] -= 1
                (cases if kind == 'testCaseStarted' else case_ends)[identity] += 1
    require(run_starts == run_ends == 1 and not active, 'Native run did not finish')
    require(starts == ends == Counter({identity: 1 for identity in expected_ended})
        and skipped == set(expected_skipped), 'Actual native selection differs')
    require(cases == case_ends and (expected_cases is None or cases == Counter(expected_cases)), 'Native parameter cases differ')
    return {'selectedFunctionIDs': sorted(starts), 'skippedFunctionIDs': sorted(skipped),
        'failedFunctionIDs': sorted({event['testID'] for event in issues}), 'issues': issues,
        'parameterCases': dict(cases), 'records': len(records), 'selectionComplete': True,
        'passed': not issues, 'fullReleaseAcceptance': False}


def scope_filter(identities):
    return '^(' + '|'.join(re.escape(identity.rsplit('/', 1)[0]) for identity in sorted(identities)) + ')(/.*)?$'


def verify_failure_origin(value, run, jobs, artifact):
    require(run.get('id') == value['failureRunID'] and run.get('head_sha') == value['failureSourceSHA']
        and run.get('run_attempt') == 1 and run.get('status') == 'completed' and run.get('conclusion') == 'failure'
        and run.get('path') == '.github/workflows/release.yml' and run.get('event') == 'workflow_dispatch'
        and run.get('actor', {}).get('login') == 'iret77'
        and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo', 'Original failed run differs')
    require(jobs.get('total_count') == len(jobs.get('jobs', [])), 'Incomplete original job inventory')
    found = [job for job in jobs['jobs'] if job.get('id') == value['failureJobID']]
    require(len(found) == 1, 'Original failed native job missing')
    job = found[0]
    require(job.get('name') == 'release-build' and job.get('run_id') == run['id'] and job.get('run_attempt') == 1
        and job.get('head_sha') == run['head_sha'] and job.get('status') == 'completed'
        and job.get('conclusion') == 'failure' and 'macrunner' in job.get('labels', []), 'Original native job differs')
    failed = [step['name'] for step in job.get('steps', []) if step.get('conclusion') == 'failure']
    require(failed == ['Verify the complete new App and XCTest scope'], 'Original failure phase differs')
    release.verify_artifact(artifact, run, job, value['failureArtifactID'], value['failureArtifactSHA256'],
        f"release-compiled-app-evidence-{value['failureRunID']}-a1")
    require(artifact.get('size_in_bytes') == value['failureArtifactBytes'], 'Original failure size differs')
    return job


def verify_bound(bound, value):
    require(bound.get('schema') == 'compiled-app-release-binding/v1' and bound.get('sourceSHA') == value['failureSourceSHA']
        and bound.get('runID') == value['failureRunID'] and bound.get('appSourceSHA') == value['appSourceSHA']
        and bound.get('selected') == value['selected'], 'Original native products differ')
    prepared = bound['prepared']; original = cohort.verify_context(prepared['cohortV2'])
    require(original['nativeSourceObjects'] == cohort.objects(os.environ['GITHUB_SHA'], cohort.NATIVE_OBJECTS)
        == bound['nativeSourceObjects'] and prepared['compilerSHA256'] == release.COMPILER_SHA,
        'Native diagnostic source or compiler differs')
    cohort.consumer_paths(value['failureSourceSHA'], os.environ['GITHUB_SHA'])
    for role in release.PHASES:
        release.verify_product(bound['products'][role]['receipt'], value['selected'][role], role, prepared)
    return prepared


def bind(output):
    value = validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_bytes()))
    require(os.environ.get('GITHUB_JOB') == 'source' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Wrong source binding context')
    output.mkdir(parents=True, exist_ok=False)
    run = api('actions/runs/' + str(value['failureRunID']))
    jobs = api(f"actions/runs/{value['failureRunID']}/attempts/1/jobs?per_page=100")
    artifact = api('actions/artifacts/' + str(value['failureArtifactID']))
    verify_failure_origin(value, run, jobs, artifact)
    original = output.parent / 'original-native-failure.zip'; download(artifact, original)
    require(checksum(original) == value['failureArtifactSHA256'], 'Original failure bytes differ')
    hashes = {}
    with release.verified_zip(original, 4 * 1024**3) as archive:
        for name, (member, digest_key) in MEMBERS.items():
            raw = archive_bytes(archive, member, 32 * 1024**2)
            require(hashlib.sha256(raw).hexdigest() == value[digest_key], 'Original failure member changed')
            (output / name).write_bytes(raw); hashes[name] = value[digest_key]
    bound = json.loads((output / 'failure-bound.json').read_bytes()); verify_bound(bound, value)
    expected = cohort.criteria()['modules']['app']
    measured = measure((output / 'failure-events.jsonl').read_bytes(), expected['exactEndedFunctionIDs'],
        expected['exactSkippedFunctionIDs'], expected['expectedCaseCountsByFunction'])
    require(measured['failedFunctionIDs'] == value['failedFunctionIDs'] and len(measured['issues']) == value['expectedOriginalIssues'],
        'Original failed methods or issues differ')
    proof = Path(os.environ['RUNNER_TEMP']) / 'transport-source-proof'
    from workspace_native_ci import source_composition
    inputs = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_bytes())['inputs']
    composition = source_composition(proof, checksum(proof / 'receipt.json'), int(inputs['verified_pr_run_id']))
    shutil.copytree(proof, output / 'source-proof')
    write(output / 'binding.json', {'schema': 'native-app-failed-method-diagnostic-binding/v1',
        'sourceSHA': os.environ['GITHUB_SHA'], 'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1,
        'fixtureSHA256': FIXTURE_SHA, 'originalRun': run, 'originalJobs': jobs, 'originalArtifact': artifact,
        'members': hashes, 'sourceComposition': composition, 'originalMeasurement': measured,
        'sourceFiles': {str(Path(__file__).relative_to(Path.cwd())): checksum(Path(__file__)),
            'scripts/native_app_window_sampler.swift': checksum(Path('scripts/native_app_window_sampler.swift'))},
        'nativeExecution': False, 'fullReleaseAcceptance': False})


def run_owned(command, log, env, timeout=120, byte_limit=64 * 1024**2):
    started = time.time(); reason = None; eof = False; size = 0
    with log.open('xb') as stream:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, env=env, start_new_session=True)
        deadline = time.monotonic() + timeout; exited_at = None
        try:
            with selectors.DefaultSelector() as selector:
                os.set_blocking(process.stdout.fileno(), False); selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    status = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                    exited = status is not None and status.si_pid == process.pid
                    if exited and exited_at is None: exited_at = time.monotonic()
                    if not exited and time.monotonic() >= deadline:
                        reason = 'timeout'; break
                    if exited and (eof or time.monotonic() - exited_at >= 2): break
                    for key, _ in selector.select(0.02):
                        block = os.read(key.fd, 65536)
                        if not block:
                            eof = True; selector.unregister(process.stdout); continue
                        if size + len(block) > byte_limit:
                            stream.write(block[:byte_limit - size]); size = byte_limit; reason = 'output-cap'; break
                        stream.write(block); size += len(block)
                    if reason: break
        finally:
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                status = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                if status is not None and status.si_pid == process.pid: break
                time.sleep(0.02)
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            try: code = process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                write(log.with_name(log.name + '.unreaped.json'), {'pid': process.pid, 'processReaped': False,
                    'stoppedReason': reason or 'cleanup-reap-timeout', 'fullReleaseAcceptance': False})
                raise ValueError('Owned native child could not be reaped within the cleanup bound') from None
            finally:
                process.stdout.close(); stream.flush(); os.fsync(stream.fileno())
    return {'pid': process.pid, 'parentPID': os.getpid(), 'command': command, 'exitCode': code,
        'launchBefore': started, 'endAfter': time.time(), 'eof': eof, 'stoppedReason': reason,
        'bytes': size, 'processReaped': True, 'fullReleaseAcceptance': False}


def acquire_source(source):
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    require(source == temporary / 'native-app-failure-source' and not source.exists() and not source.is_symlink(),
        'Occupied or foreign diagnostic source destination')
    identity = os.environ.get('NATIVE_FAILURE_BINDING_ID', '')
    digest = os.environ.get('NATIVE_FAILURE_BINDING_DIGEST', '')
    require(re.fullmatch('[1-9][0-9]*', identity) and re.fullmatch('[a-f0-9]{64}', digest), 'Missing exact diagnostic source artifact')
    run = api('actions/runs/' + os.environ['GITHUB_RUN_ID'])
    jobs = api('actions/runs/' + os.environ['GITHUB_RUN_ID'] + '/attempts/1/jobs?per_page=100')
    require(run.get('path') == '.github/workflows/diagnostic-acceptance.yml' and run.get('run_attempt') == 1
        and run.get('head_sha') == os.environ['GITHUB_SHA'] and run.get('event') == 'workflow_dispatch'
        and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and run.get('actor', {}).get('login') == 'iret77'
        and jobs.get('total_count') == len(jobs.get('jobs', [])), 'Foreign diagnostic workflow context')
    found = [job for job in jobs['jobs'] if job.get('name') == 'source']
    require(len(found) == 1 and found[0].get('conclusion') == 'success' and found[0].get('status') == 'completed'
        and found[0].get('head_sha') == os.environ['GITHUB_SHA'] and found[0].get('run_attempt') == 1,
        'Source binding producer is incomplete')
    artifact = api('actions/artifacts/' + identity)
    release.verify_artifact(artifact, run, found[0], int(identity), digest,
        'native-app-failure-source-binding-' + os.environ['GITHUB_RUN_ID'] + '-a1')
    outer = temporary / 'native-app-failure-source.zip'; download(artifact, outer)
    require(checksum(outer) == digest, 'Diagnostic source ZIP changed')
    expected = {'binding.json', *MEMBERS, 'source-proof/receipt.json', 'source-proof/original-proof.zip', 'source-proof/original-job.log'}
    source.mkdir()
    with release.verified_zip(outer, 32 * 1024**2) as archive:
        files = {entry.filename for entry in archive.infolist() if not entry.is_dir()}
        require(files == expected and all(not entry.is_dir() or entry.filename == 'source-proof/'
            for entry in archive.infolist()), 'Diagnostic source ZIP inventory differs')
        for name in sorted(expected):
            destination = source / name; destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(archive_bytes(archive, name, 32 * 1024**2))
    write(source / 'acquisition.json', {'run': run, 'sourceJob': found[0], 'artifact': artifact, 'sha256': digest})


def execute(source, root):
    value = validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_bytes()))
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64'
        and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_JOB') == 'app-native-failure-diagnostic' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1',
        'Wrong native diagnostic context')
    require(root == temporary / 'native-app-failure-diagnostic' and not root.exists() and not root.is_symlink(), 'Occupied diagnostic root')
    binding = json.loads((source / 'binding.json').read_bytes())
    require(binding.get('schema') == 'native-app-failed-method-diagnostic-binding/v1'
        and binding['sourceSHA'] == os.environ['GITHUB_SHA'] and binding['runID'] == int(os.environ['GITHUB_RUN_ID'])
        and binding['attempt'] == 1 and binding['fixtureSHA256'] == FIXTURE_SHA, 'Foreign diagnostic source binding')
    for name, digest in binding['members'].items(): require(checksum(source / name) == digest, 'Original source member changed')
    require(set(binding['members']) == set(MEMBERS), 'Incomplete original source member inventory')
    require(set(binding['sourceFiles']) == {'scripts/native_app_failure_diagnostic.py', 'scripts/native_app_window_sampler.swift'},
        'Incomplete diagnostic helper source inventory')
    for name, digest in binding['sourceFiles'].items(): require(checksum(Path(name)) == digest, 'Diagnostic helper source changed')
    from workspace_native_ci import source_composition
    source_composition(source / 'source-proof', binding['sourceComposition']['receiptSHA256'],
        binding['sourceComposition']['composition']['originalRun']['id'])
    verify_failure_origin(value, api('actions/runs/' + str(value['failureRunID'])),
        api(f"actions/runs/{value['failureRunID']}/attempts/1/jobs?per_page=100"), api('actions/artifacts/' + str(value['failureArtifactID'])))
    bound = json.loads((source / 'failure-bound.json').read_bytes()); prepared = verify_bound(bound, value)
    require(checksum(Path(prepared['plans']['tests']['driver']['argv'][0])) == release.COMPILER_SHA, 'Native compiler identity changed')
    arena = temporary / 'app-build-plan-evidence/testable/derived-data'
    require(Path(prepared['plans']['tests']['operations']['arena']) == arena and not arena.exists()
        and not arena.is_symlink() and arena.parent.resolve().is_relative_to(temporary), 'Foreign or occupied original test arena')
    root.mkdir(); evidence = root / 'evidence'; evidence.mkdir()
    observer = root / 'window-sampler'
    targets.logged(evidence, 'compile-observer-tool-only', ['xcrun', 'swiftc', 'scripts/native_app_window_sampler.swift', '-o', str(observer)])
    origins = {role: release.producer(selected, role) for role, selected in value['selected'].items()}
    restored = targets.restore_product(root, 'tests', prepared, origins['tests'])
    receipt = release.verify_product(restored['receipt'], value['selected']['tests'], 'tests', prepared)
    plan = prepared['plans']['tests']; links = [item for item in plan['operations']['links'] if item['targetGUID'] == plan['driver']['targetGUID']]
    require(len(links) == 1, 'Original native test output is ambiguous')
    image = Path(links[0]['output']); require(image.is_relative_to(arena), 'Original native image escapes its arena')
    require(checksum(image) == value['testImage']['sha256'], 'Original test image changed')
    targets.logged(evidence, 'verify-native-test-container', ['codesign', '--verify', '--deep', '--strict', str(image.parents[2])])
    image_uuid = targets.logged(evidence, 'native-test-image-uuid', ['xcrun', 'dwarfdump', '--uuid', str(image)])
    require(re.findall(release.UUID if hasattr(release, 'UUID') else r'[A-Fa-f0-9-]{36}', image_uuid)[0].upper()
        == value['testImage']['UUIDs'][0], 'Original test UUID changed')
    bank_id, bank_digest = retained.ARTIFACTS['runtime'][:2]
    bank_artifact = api('actions/artifacts/' + str(bank_id)); require(bank_artifact['digest'] == 'sha256:' + bank_digest
        and not bank_artifact['expired'], 'Original runtime bank changed')
    download(bank_artifact, root / 'runtime.zip')
    with release.verified_zip(root / 'runtime.zip', 4 * 1024**3, qualified_sha=bank_digest) as archive:
        raw = archive_bytes(archive, 'runtime-manifest.json', 4 * 1024**2)
    require(hashlib.sha256(raw).hexdigest() == retained.MANIFEST_SHA, 'Original bank manifest changed')
    (root / 'bank-runtime-manifest.json').write_bytes(raw)
    runtime = retained.restore_runtime(root, json.loads(raw), lambda argv, label, timeout=180:
        targets.logged(evidence, label, argv, timeout=timeout), reuse_crc=True)
    host = runtime / 'NexGenVideoAppKitTestHost'; require(checksum(host) == value['originalHostSHA256'], 'Original AppKit host changed')
    host_uuid = targets.logged(evidence, 'native-host-uuid', ['xcrun', 'dwarfdump', '--uuid', str(host)])
    require(value['originalHostUUID'] in host_uuid.lower(), 'Original AppKit host UUID changed')
    sampler = evidence / 'sampler'; sampler.mkdir(); folder = evidence / 'host'; folder.mkdir()
    from run_macos_tests import app_environment
    environment = app_environment(dict(os.environ), runtime, image, folder)
    require(not any(key.startswith(('NGV_ACCEPTANCE', 'NGV_APP_DIAGNOSTIC', 'NSZombie', 'DYLD_INSERT_LIBRARIES'))
        for key in environment), 'Unexpected native diagnostic substitution')
    environment.update(NGV_APPKIT_TEST_BUNDLE=str(image), NGV_APPKIT_TEST_EVENTS=str(folder / 'events.jsonl'),
        NGV_APPKIT_TEST_RECEIPT=str(folder / 'host-receipt.json'), NGV_APPKIT_EXCEPTION_EVIDENCE=str(folder / 'exception.jsonl'))
    command = [str(host), '--event-stream-version', '0', '--no-parallel', '--filter', scope_filter(value['failedFunctionIDs'])]
    write(evidence / 'original-inputs.json', {'binding': binding, 'selected': value['selected'], 'testReceipt': receipt,
        'origins': origins, 'hostSHA256': checksum(host), 'imageSHA256': checksum(image),
        'runtimePath': str(runtime), 'imagePath': str(image), 'originalReleaseRuntimePath': bound['runtime'],
        'pathDomainChanged': str(runtime) != bound['runtime'], 'noAppOrTestCompilation': True, 'fullReleaseAcceptance': False})
    with (sampler / 'process.log').open('xb') as log:
        process = subprocess.Popen([str(observer), str(sampler)], stdin=subprocess.DEVNULL, stdout=log,
            stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not (sampler / 'ready.json').exists() and process.poll() is None and time.monotonic() < deadline: time.sleep(0.02)
            require((sampler / 'ready.json').is_file() and process.poll() is None, 'Observer did not produce its first complete snapshot')
            with (evidence / 'host.STARTED.json').open('x') as marker:
                json.dump({'command': command, 'at': time.time(), 'oneShot': True}, marker); marker.flush(); os.fsync(marker.fileno())
            result = run_owned(command, folder / 'console.log', environment)
            write(folder / 'process.json', result)
        finally:
            try:
                (sampler / 'stop').write_text('stop\n')
            finally:
                reaped = False
                try:
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        try: os.killpg(process.pid, signal.SIGTERM)
                        except ProcessLookupError: pass
                        try: process.wait(timeout=2)
                        except subprocess.TimeoutExpired:
                            try: os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError: pass
                            process.wait(timeout=2)
                    reaped = True
                finally:
                    write(sampler / 'process.json', {'pid': process.pid, 'exitCode': process.returncode, 'processReaped': reaped})
    require(result['eof'] and result['stoppedReason'] is None and process.returncode == 0, 'Native measurement incomplete; preserve originals')
    measurement = measure((folder / 'events.jsonl').read_bytes(), value['failedFunctionIDs'], expected_cases={})
    host_receipt = json.loads((folder / 'host-receipt.json').read_bytes())
    require(host_receipt.get('pid') == result['pid'] and host_receipt.get('parentPID') == os.getpid()
        and host_receipt.get('hostExecutable') == str(host) and host_receipt.get('bundleBinary') == str(image)
        and host_receipt.get('sourceSHA') == os.environ['GITHUB_SHA'] and host_receipt.get('completed') is True
        and host_receipt.get('started') is True and host_receipt.get('runReturnedAfterCompletion') is True
        and host_receipt.get('applicationRunningAtStart') is True and host_receipt.get('mainThread') is True
        and host_receipt.get('getterImagePath') == host_receipt.get('entryPointImagePath')
        and str(host_receipt.get('getterImagePath', '')).endswith('/Testing.framework/Versions/A/Testing')
        and host_receipt.get('eventRecordCount') == measurement['records']
        and host_receipt.get('abiSucceeded') == measurement['passed'] and result['exitCode'] == (0 if measurement['passed'] else 1)
        and (folder / 'exception.jsonl').stat().st_size == 0, 'Original native host did not complete the measured selection')
    require(checksum(host) == value['originalHostSHA256'] and checksum(image) == value['testImage']['sha256'], 'Original native images changed during diagnosis')
    observer_receipt = json.loads((sampler / 'receipt.json').read_bytes())
    ready = json.loads((sampler / 'ready.json').read_bytes())
    require(observer_receipt.get('complete') is True and observer_receipt.get('observerPID') == process.pid
        and ready.get('wallTime', float('inf')) <= result['launchBefore']
        and observer_receipt.get('lastSampleWallTime', 0) >= result['endAfter'], 'Observer did not cover the native process')
    write(evidence / 'measurement.json', {'schema': 'native-app-original-failed-method-measurement/v1', 'measurement': measurement,
        'process': result, 'hostReceipt': host_receipt, 'observerComplete': True, 'fullReleaseAcceptance': False,
        'scopeLimit': 'Selective execution and changed restored paths are an isolation experiment. External WindowServer samples do not prove the private pointer guard snapshot or its TCC context.'})


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('action', choices=['bind', 'run'])
    parser.add_argument('--output', type=Path, required=True); parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    if args.action == 'bind': bind(args.output)
    else:
        require(args.source is not None, 'Missing authenticated source binding')
        acquire_source(args.source); execute(args.source, args.output)


if __name__ == '__main__': main()
