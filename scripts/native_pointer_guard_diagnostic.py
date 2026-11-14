"""Inspect one original native pointer guard using unchanged test and host images."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import time

import app_cohort_v2 as cohort
import compiled_app_release as release
import native_app_target_build as targets
import release_test_repair as retained
from retained_app_test_products import api, archive_bytes, checksum, download, require, write

from native_app_failure_diagnostic import measure, scope_filter, verify_failure_origin, verify_bound, run_owned

KIND = 'native-pointer-guard-snapshot'
FIXTURE = Path(__file__).with_name('fixtures') / 'native-app-failure-1099.json'
FIXTURE_SHA = '63d9340373d7ed61645880d1c30508320577c851682d8f4097682c5127b0d0f4'
SOURCE_FILES = {'scripts/native_pointer_guard_diagnostic.py', 'scripts/native_pointer_guard_snapshot.m',
    'scripts/native_app_failure_diagnostic.py', 'scripts/fixtures/native-app-failure-1099.json'}
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


def bind(output):
    value = validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_bytes()))
    require(os.environ.get('GITHUB_JOB') == 'source' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Wrong source binding context')
    output.mkdir(parents=True, exist_ok=False)
    run = api('actions/runs/' + str(value['failureRunID']))
    jobs = api(f"actions/runs/{value['failureRunID']}/attempts/1/jobs?per_page=100")
    artifact = api('actions/artifacts/' + str(value['failureArtifactID']))
    verify_failure_origin(value, run, jobs, artifact)
    original = output.parent / 'original-pointer-guard-failure.zip'; download(artifact, original)
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
    write(output / 'binding.json', {'schema': 'native-pointer-guard-binding/v1',
        'sourceSHA': os.environ['GITHUB_SHA'], 'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1,
        'fixtureSHA256': FIXTURE_SHA, 'originalRun': run, 'originalJobs': jobs, 'originalArtifact': artifact,
        'members': hashes, 'sourceComposition': composition, 'originalMeasurement': measured,
        'sourceFiles': {name: checksum(Path(name)) for name in SOURCE_FILES},
        'nativeExecution': False, 'fullReleaseAcceptance': False})


def acquire_source(source):
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    require(source == temporary / 'native-pointer-guard-source' and not source.exists() and not source.is_symlink(),
        'Occupied or foreign diagnostic source destination')
    identity = os.environ.get('POINTER_GUARD_BINDING_ID', '')
    digest = os.environ.get('POINTER_GUARD_BINDING_DIGEST', '')
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
        'native-pointer-guard-source-binding-' + os.environ['GITHUB_RUN_ID'] + '-a1')
    outer = temporary / 'native-pointer-guard-source.zip'; download(artifact, outer)
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



def parse_signature(description, entitlements):
    flags = re.findall(r'flags=0x([a-fA-F0-9]+)', description)
    require(len(flags) == 1, 'Native code signature flags are ambiguous')
    hardened = bool(int(flags[0], 16) & 0x10000)
    if '<plist' in entitlements:
        start = entitlements.index('<plist'); end = entitlements.index('</plist>', start) + len('</plist>')
        values = plistlib.loads(entitlements[start:end].encode())
        require(isinstance(values, dict), 'Unknown code signature entitlements')
    else:
        require(all(not line.strip() or line.startswith('Executable=') or 'no entitlements' in line.lower()
            for line in entitlements.splitlines()), 'Unrecognized entitlement output')
        values = {}
    require(not hardened or all(values.get(key) is True for key in (
        'com.apple.security.cs.allow-dyld-environment-variables', 'com.apple.security.cs.disable-library-validation')),
        'Original hardened image does not permit this diagnostic; never resign or change its entitlements')
    return {'flags': int(flags[0], 16), 'hardenedRuntime': hardened, 'entitlements': values,
        'originalSignatureUnchanged': True}


def signature_preflight(path, evidence, label):
    targets.logged(evidence, label + '-original-signature', ['codesign', '--display', '--verbose=4', str(path)])
    targets.logged(evidence, label + '-original-entitlements', ['codesign', '--display', '--entitlements', '-', str(path)])
    streams = lambda phase: '\n'.join((evidence / (label + '-original-' + phase + '.' + channel)).read_text()
        for channel in ('stdout', 'stderr'))
    return parse_signature(streams('signature'), streams('entitlements'))


def verify_snapshots(raw, process, inspector, image):
    require(raw.endswith(b'\n') and len(raw) <= 1024 * 1024, 'Inspector output is incomplete or oversized')
    rows = [json.loads(line) for line in raw.splitlines()]
    require(4 <= len(rows) <= 19 and all(isinstance(row, dict) and row.get('diagnosticOnly') is True
        and row.get('pid') == process['pid'] for row in rows), 'Foreign or excessive inspector records')
    require([row.get('kind') for row in rows[:2]] == ['loaded', 'hook-ready']
        and rows[-1].get('kind') == 'finished' and all(row.get('kind') == 'guard-snapshot' for row in rows[2:-1]),
        'Inspector did not complete exactly one hook and its snapshots')
    loaded, hook, finished = rows[0], rows[1], rows[-1]; samples = rows[2:-1]
    require(loaded.get('parentPID') == process['parentPID'] and hook.get('installed') is True
        and hook.get('mainThread') is True and hook.get('inspectorImage') == str(inspector)
        and hook.get('rootClassImage') == str(image) and hook.get('originalIMP', '').startswith('0x')
        and isinstance(hook.get('typeEncoding'), str) and hook['typeEncoding'], 'Hook provenance is incomplete')
    times = [row.get('wallTime') for row in rows]
    require(all(isinstance(value, (int, float)) and math.isfinite(value) for value in times)
        and times == sorted(times) and process['launchBefore'] <= times[0] <= times[-1] <= process['endAfter'],
        'Inspector lifetime escapes the original native process')
    require(finished.get('samples') == len(samples) and finished.get('outputErrors') == 0
        and finished.get('rejectedRecords') == 0 and finished.get('originalCalls') == finished.get('transparentReturns')
        and finished.get('originalCalls', 0) >= len(samples) and finished.get('hookTime') == hook['wallTime']
        and finished.get('firstHitTime', 0) >= hook['wallTime'], 'Inspector lost data or original returns')
    predicates = ('nativeControlType', 'notHidden', 'visibleArea', 'probeContainsHitBounds',
        'visibleRectContainsPoint', 'nativeAccessibilityEnabled', 'nativeKnownRole')
    for index, sample in enumerate(samples, 1):
        require(sample.get('sample') == index and all(sample.get(key) == hook.get(key)
            for key in ('root', 'window', 'windowIdentity')) and sample.get('probe') == samples[0].get('probe')
            and all(isinstance(sample.get(key), bool) for key in (*predicates, 'nativeGuardResult'))
            and sample['nativeGuardResult'] == all(sample[key] for key in predicates), 'Unbound or inconsistent guard snapshot')
        for key, count in [('rootPoint', 2), ('windowPoint', 2), ('screenPoint', 2), ('hitPoint', 2),
                           ('probeFrame', 4), ('hitBoundsInRoot', 4), ('hitVisibleRect', 4)]:
            require(isinstance(sample.get(key), list) and len(sample[key]) == count
                and all(isinstance(v, (int, float)) and math.isfinite(v) for v in sample[key]), 'Nonfinite guard geometry')
        require(isinstance(sample.get('stack'), list) and 1 <= len(sample['stack']) <= 64, 'Missing native call provenance')
        for key in ('hostingAXChain', 'hitAXChain', 'hitOwnAXChain'):
            chain = sample.get(key, {})
            require(isinstance(chain.get('elements'), list) and len(chain['elements']) <= 32
                and chain.get('end') in {'nil', 'cycle', 'nonProtocol', 'depthLimit', 'boundWindow'}
                and isinstance(chain.get('completeToBoundWindow'), bool)
                and chain['completeToBoundWindow'] == (chain['end'] == 'boundWindow'), 'Ambiguous accessibility ancestry')
            if chain['completeToBoundWindow']:
                require(chain['elements'] and chain['elements'][-1].get('identity') == hook['windowIdentity'],
                    'Accessibility chain belongs to another window')
    return {'records': len(rows), 'samples': len(samples), 'exactOriginalProcess': True,
        'hookBeforeFirstSnapshot': True, 'outputComplete': True, 'diagnosticOnly': True,
        'falsePredicatesBySample': [[key for key in predicates if not row[key]] for row in samples]}


def execute(source, root):
    value = validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_bytes()))
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64'
        and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_JOB') == 'pointer-guard-snapshot' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1',
        'Wrong native diagnostic context')
    require(root == temporary / 'native-pointer-guard-diagnostic' and not root.exists() and not root.is_symlink(), 'Occupied diagnostic root')
    binding = json.loads((source / 'binding.json').read_bytes())
    require(binding.get('schema') == 'native-pointer-guard-binding/v1'
        and binding['sourceSHA'] == os.environ['GITHUB_SHA'] and binding['runID'] == int(os.environ['GITHUB_RUN_ID'])
        and binding['attempt'] == 1 and binding['fixtureSHA256'] == FIXTURE_SHA, 'Foreign diagnostic source binding')
    for name, digest in binding['members'].items(): require(checksum(source / name) == digest, 'Original source member changed')
    require(set(binding['members']) == set(MEMBERS), 'Incomplete original source member inventory')
    require(set(binding['sourceFiles']) == SOURCE_FILES,
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
    inspector = evidence / 'pointer-guard-snapshot.dylib'
    targets.logged(evidence, 'compile-inspector-only', ['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-fblocks',
        '-Wall', '-Wextra', '-Werror=implicit-function-declaration', '-framework', 'AppKit',
        'scripts/native_pointer_guard_snapshot.m', '-o', str(inspector)])
    targets.logged(evidence, 'sign-inspector-only', ['codesign', '--sign', '-', str(inspector)])
    targets.logged(evidence, 'verify-inspector-only', ['codesign', '--verify', '--strict', str(inspector)])
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
    signatures = {label: signature_preflight(path, evidence, label) for label, path in [('host', host), ('tests', image)]}
    folder = evidence / 'host'; folder.mkdir()
    snapshots = evidence / 'inspector'; snapshots.mkdir()
    from run_macos_tests import app_environment
    environment = app_environment(dict(os.environ), runtime, image, folder)
    require(not any(key.startswith(('NGV_ACCEPTANCE', 'NGV_APP_DIAGNOSTIC', 'NSZombie', 'DYLD_INSERT_LIBRARIES'))
        for key in environment), 'Unexpected native diagnostic substitution')
    environment.update(NGV_APPKIT_TEST_BUNDLE=str(image), NGV_APPKIT_TEST_EVENTS=str(folder / 'events.jsonl'),
        NGV_APPKIT_TEST_RECEIPT=str(folder / 'host-receipt.json'), NGV_APPKIT_EXCEPTION_EVIDENCE=str(folder / 'exception.jsonl'),
        DYLD_INSERT_LIBRARIES=str(inspector), NGV_POINTER_GUARD_SNAPSHOT_DIR=str(snapshots))
    command = [str(host), '--event-stream-version', '0', '--no-parallel', '--filter', scope_filter(value['diagnosticFunctionIDs'])]
    write(evidence / 'original-inputs.json', {'binding': binding, 'selected': value['selected'], 'testReceipt': receipt,
        'origins': origins, 'hostSHA256': checksum(host), 'imageSHA256': checksum(image),
        'runtimePath': str(runtime), 'imagePath': str(image), 'originalReleaseRuntimePath': bound['runtime'],
        'pathDomainChanged': str(runtime) != bound['runtime'], 'noAppOrTestCompilation': True, 'inspectorSHA256': checksum(inspector),
        'signaturePreflight': signatures, 'injectedInstrumentation': True, 'fullReleaseAcceptance': False})
    with (evidence / 'host.STARTED.json').open('x') as marker:
        json.dump({'command': command, 'at': time.time(), 'oneShot': True}, marker); marker.flush(); os.fsync(marker.fileno())
    result = run_owned(command, folder / 'console.log', environment)
    write(folder / 'process.json', result)
    require(result['eof'] and result['stoppedReason'] is None, 'Native measurement incomplete; preserve originals')
    require(b'NGV_POINTER_INSPECTOR_FINALIZATION_FAILED' not in (folder / 'console.log').read_bytes(),
        'Inspector finalization failed')
    measurement = measure((folder / 'events.jsonl').read_bytes(), value['diagnosticFunctionIDs'], expected_cases={})
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
    snapshot = verify_snapshots((snapshots / 'snapshots.jsonl').read_bytes(), result, inspector, image)
    write(evidence / 'measurement.json', {'schema': 'native-pointer-guard-measurement/v1', 'measurement': measurement,
        'process': result, 'hostReceipt': host_receipt, 'snapshot': snapshot, 'fullReleaseAcceptance': False,
        'scopeLimit': 'Injected observation, filtered execution and restored paths can alter timing or accessibility state. '
            'This experiment never qualifies App, tests, runtime or release acceptance.'})


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('action', choices=['bind', 'run'])
    parser.add_argument('--output', type=Path, required=True); parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    if args.action == 'bind': bind(args.output)
    else:
        require(args.source is not None, 'Missing authenticated source binding')
        acquire_source(args.source); execute(args.source, args.output)


if __name__ == '__main__': main()
