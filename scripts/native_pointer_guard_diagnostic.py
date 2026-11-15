"""Inspect current native pointer and window guards using unchanged test and host images."""
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
FIXTURE = Path(__file__).with_name('fixtures') / 'native-app-failure-1110.json'
FIXTURE_SHA = '788cb699f927a280614ddfbc3f769fd72ba60fe3052ccc4fc442f84e1f18aa8e'
LEGACY_FIXTURE = FIXTURE.with_name('native-app-failure-1099.json')
LEGACY_FIXTURE_SHA = '63d9340373d7ed61645880d1c30508320577c851682d8f4097682c5127b0d0f4'
RETAINED_RUN = 43629283870
RETAINED_SOURCE = '0b43415624ab9188c81f2f98cd7cd7ed9e5cfb37'
RETAINED_ARTIFACTS = {
    'source': (14127930309, '3be74906858bccdf3b60d2f4038803deb9bfa2812f3594899508ceb41ee62e4f', 1733042,
        'native-pointer-guard-source-binding-43629283870-a1'),
    'inspector': (14127441715, 'cbfc182ef5384875f3cdf728f8848bbcc6b20fd3be4701d0063bac63c3f77c5b', 1999945,
        'native-pointer-guard-measurement-43629283870-a1')}
INSPECTOR_SHA = '731100a5cda360b9d58b2d471638db2de4d1a991396575c3af33de70377613b3'
INSPECTOR_BYTES = 91696
INSPECTOR_PREFIX = 'native-pointer-guard-diagnostic/evidence/'
HISTORICAL_C_SHA = 'b7413fbf5849efa42b8563ec04d74f7a012ae343878610d0150e194a5fb4ab21'
HISTORICAL_SOURCE_FILES = {'scripts/native_pointer_guard_diagnostic.py', 'scripts/native_pointer_guard_snapshot.m',
    'scripts/native_app_failure_diagnostic.py', 'scripts/fixtures/native-app-failure-1099.json'}
SOURCE_FILES = HISTORICAL_SOURCE_FILES | {'scripts/native_pointer_guard_selftest.swift',
    'scripts/fixtures/native-app-failure-1110.json'}
SELFTEST_SOURCE_SHA = '32ab7da761fc1dd7745964cbad6e91918c5d2a71e7568a1bfb2283648e71e8cb'
SELFTEST_TOOL_SHA = '8d5d8c7734614b186e92a96026630af2573bbbd25cd6d6a8b905c7725cfd2bd1'
SELFTEST_TOOL_BYTES = 134736
SELFTEST_PRODUCER = (43657087733, '535eac81fd0b3e2ea1f6b83ba0e1e39dbc86f1db', 132637995947)
SELFTEST_ARTIFACT = (14137979075, 'ce6157c3ba80ab47be907bcb9e845638fad424ea52d3530dd36d830bb4dfbd29', 1807030)
SELFTEST_PRODUCER_FILES = {
    'scripts/native_pointer_guard_selftest.swift': SELFTEST_SOURCE_SHA,
    'scripts/native_pointer_guard_snapshot.m': '4938f09f942cd8694f7cbddb3d3fe710986983972d8698efa74fecc5037f1f6e',
    'scripts/native_pointer_guard_diagnostic.py': 'd95211ca087f675f5a03888fff2264a33bd3250b69f6f25974e872b1500a47d9',
    'scripts/native_app_failure_diagnostic.py': '40a7143c57b994cecb429a8e8927015962e2aa9b6580f64562e3dfa1a7f7a278',
    'scripts/fixtures/native-app-failure-1099.json': LEGACY_FIXTURE_SHA}
MEMBERS = {'failure-bound.json': ('bound.json', 'boundSHA256'),
           'failure-events.jsonl': ('app-swift-testing/events.jsonl', 'eventSHA256'),
           'failure-host-receipt.json': ('app-swift-testing/host-receipt.json', 'hostReceiptSHA256')}


def fixture():
    require(checksum(FIXTURE) == FIXTURE_SHA, 'Original failure scope changed')
    return json.loads(FIXTURE.read_bytes())


def legacy_fixture():
    require(checksum(LEGACY_FIXTURE) == LEGACY_FIXTURE_SHA, 'Retained tool legacy scope changed')
    return json.loads(LEGACY_FIXTURE.read_bytes())


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



def retained_origin(role):
    require(role in RETAINED_ARTIFACTS, 'Unknown retained diagnostic role')
    run = api('actions/runs/' + str(RETAINED_RUN))
    jobs = api(f'actions/runs/{RETAINED_RUN}/attempts/1/jobs?per_page=100')
    require(run.get('id') == RETAINED_RUN and run.get('head_sha') == RETAINED_SOURCE
        and run.get('run_attempt') == 1 and run.get('status') == 'completed' and run.get('conclusion') == 'failure'
        and run.get('workflow_id') == 355242770 and run.get('path') == '.github/workflows/diagnostic-acceptance.yml'
        and run.get('actor', {}).get('login') == 'iret77' and run.get('event') == 'workflow_dispatch'
        and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and jobs.get('total_count') == len(jobs.get('jobs', [])) == 30
        and len({job['id'] for job in jobs['jobs']}) == 30
        and all(job.get('run_id') == RETAINED_RUN and job.get('head_sha') == RETAINED_SOURCE
            and job.get('run_attempt') == 1 for job in jobs['jobs']), 'Retained diagnostic producer differs')
    expected = {'source': 132552072033, 'pointer-guard-snapshot': 132552434059}
    selected = {job['name']: job for job in jobs['jobs'] if job['name'] in expected}
    require(set(selected) == set(expected) and len([job for job in jobs['jobs'] if job['name'] in expected]) == 2,
        'Retained diagnostic jobs are ambiguous')
    for name, identity in expected.items():
        job = selected[name]
        require(job.get('id') == identity and job.get('run_id') == RETAINED_RUN
            and job.get('run_attempt') == 1 and job.get('head_sha') == RETAINED_SOURCE
            and job.get('status') == 'completed' and job.get('conclusion') == ('success' if name == 'source' else 'failure'),
            'Retained diagnostic job differs')
    require('macrunner' in selected['pointer-guard-snapshot'].get('labels', [])
        and [step['name'] for step in selected['pointer-guard-snapshot'].get('steps', []) if step.get('conclusion') == 'failure']
            == ['Observe one original failed pointer guard without compiling App or tests']
        and all(job.get('status') == 'completed' and job.get('conclusion') == 'skipped'
            for job in jobs['jobs'] if job['name'] not in expected), 'Retained failure phase differs')
    identity, digest, size, name = RETAINED_ARTIFACTS[role]
    artifact = api('actions/artifacts/' + str(identity))
    release.verify_artifact(artifact, run, selected['source' if role == 'source' else 'pointer-guard-snapshot'],
        identity, digest, name)
    require(artifact.get('size_in_bytes') == size, 'Retained diagnostic artifact size differs')
    cohort.consumer_paths(RETAINED_SOURCE, os.environ['GITHUB_SHA'])
    return artifact


def verify_retained_binding(binding, value):
    require(binding.get('schema') == 'native-pointer-guard-binding/v1'
        and binding.get('sourceSHA') == RETAINED_SOURCE and binding.get('runID') == RETAINED_RUN
        and binding.get('attempt') == 1 and binding.get('fixtureSHA256') == LEGACY_FIXTURE_SHA
        and binding.get('nativeExecution') is False and binding.get('fullReleaseAcceptance') is False
        and binding.get('members') == {name: value[key] for name, (_, key) in MEMBERS.items()}
        and set(binding.get('sourceFiles', {})) == HISTORICAL_SOURCE_FILES
        and binding['sourceFiles']['scripts/native_pointer_guard_snapshot.m']
            == HISTORICAL_C_SHA, 'Retained original input producer differs')


def inspector_bytes(archive, value):
    binding = json.loads(archive_bytes(archive, 'native-pointer-guard-source/binding.json', 4 * 1024**2))
    verify_retained_binding(binding, value)
    for stage in ('compile-inspector-only', 'sign-inspector-only', 'verify-inspector-only'):
        require(json.loads(archive_bytes(archive, INSPECTOR_PREFIX + stage + '.exit.json', 1024)) == {'exitCode': 0},
            'Retained inspector did not complete compilation, signing and verification')
    raw = archive_bytes(archive, INSPECTOR_PREFIX + 'pointer-guard-snapshot.dylib', 1024**2)
    require(len(raw) == INSPECTOR_BYTES and hashlib.sha256(raw).hexdigest() == INSPECTOR_SHA,
        'Retained inspector image changed')
    return raw


def build_inspector(inspector, evidence):
    targets.logged(evidence, 'compile-current-inspector-only', ['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-fblocks',
        '-Wall', '-Wextra', '-Werror=implicit-function-declaration', '-framework', 'AppKit', '-framework', 'CoreGraphics',
        'scripts/native_pointer_guard_snapshot.m', '-o', str(inspector)])
    targets.logged(evidence, 'sign-current-inspector-only', ['codesign', '--sign', '-', str(inspector)])
    targets.logged(evidence, 'verify-current-inspector-only', ['codesign', '--verify', '--strict', str(inspector)])


def selftest_tool_bytes(archive):
    binding = json.loads(archive_bytes(archive, 'native-pointer-guard-source/binding.json', 4 * 1024**2))
    require(binding.get('schema') == 'native-pointer-guard-binding/v1'
        and binding.get('runID') == SELFTEST_PRODUCER[0] and binding.get('sourceSHA') == SELFTEST_PRODUCER[1]
        and binding.get('attempt') == 1 and binding.get('sourceFiles') == SELFTEST_PRODUCER_FILES
        and binding.get('fixtureSHA256') == LEGACY_FIXTURE_SHA and binding.get('nativeExecution') is False
        and binding.get('fullReleaseAcceptance') is False,
        'Retained selftest tool source differs')
    for stage in ('compile-observer-selftest-tool', 'sign-observer-selftest-tool', 'verify-observer-selftest-tool'):
        require(json.loads(archive_bytes(archive, INSPECTOR_PREFIX + stage + '.exit.json', 1024)) == {'exitCode': 0},
            'Retained selftest tool preparation is incomplete')
    raw = archive_bytes(archive, INSPECTOR_PREFIX + 'pointer-observer-selftest', 1024**2)
    require(len(raw) == SELFTEST_TOOL_BYTES and hashlib.sha256(raw).hexdigest() == SELFTEST_TOOL_SHA,
        'Retained selftest tool image changed')
    return raw


def restore_selftest_tool(tool, evidence):
    require(checksum(Path('scripts/native_pointer_guard_selftest.swift')) == SELFTEST_SOURCE_SHA,
        'Selftest source changed; retained tool cannot be substituted')
    version = platform.mac_ver()[0]
    require(re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', version) is not None
        and tuple((list(map(int, version.split('.'))) + [0, 0, 0])[:3]) >= (27, 2, 0),
        'Retained selftest tool requires macOS 27.2 or newer')
    run_id, source_sha, job_id = SELFTEST_PRODUCER
    tool_source = 'scripts/native_pointer_guard_selftest.swift'
    require(cohort.objects(source_sha, [tool_source]) == cohort.objects(os.environ['GITHUB_SHA'], [tool_source]),
        'Retained selftest compiler input changed')
    run = api('actions/runs/' + str(run_id))
    jobs = api(f'actions/runs/{run_id}/attempts/1/jobs?per_page=100')
    require(run.get('id') == run_id and run.get('head_sha') == source_sha and run.get('run_attempt') == 1
        and run.get('workflow_id') == 355242770 and run.get('path') == '.github/workflows/diagnostic-acceptance.yml'
        and run.get('event') == 'workflow_dispatch' and run.get('actor', {}).get('login') == 'iret77'
        and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and run.get('status') == 'completed' and run.get('conclusion') == 'failure'
        and jobs.get('total_count') == len(jobs.get('jobs', [])) == 30
        and len({job['id'] for job in jobs['jobs']}) == 30
        and all(job.get('run_id') == run_id and job.get('head_sha') == source_sha and job.get('run_attempt') == 1
            and job.get('status') == 'completed' for job in jobs['jobs']), 'Retained selftest tool producer differs')
    found = [job for job in jobs['jobs'] if job.get('name') == 'pointer-guard-snapshot']
    source_jobs = [job for job in jobs['jobs'] if job.get('name') == 'source']
    require(len(found) == 1 and found[0].get('id') == job_id and found[0].get('conclusion') == 'failure'
        and 'macrunner' in found[0].get('labels', []) and len(source_jobs) == 1
        and source_jobs[0].get('id') == 132637909857 and source_jobs[0].get('conclusion') == 'success'
        and all(job.get('conclusion') == 'skipped' for job in jobs['jobs']
            if job.get('name') not in {'source', 'pointer-guard-snapshot'}), 'Retained selftest native job differs')
    identity, digest, size = SELFTEST_ARTIFACT
    artifact = api('actions/artifacts/' + str(identity))
    release.verify_artifact(artifact, run, found[0], identity, digest,
        'native-pointer-guard-measurement-' + str(run_id) + '-a1')
    require(artifact.get('size_in_bytes') == size, 'Retained selftest artifact size differs')
    outer = evidence / 'retained-selftest-tool.zip'; download(artifact, outer)
    require(checksum(outer) == digest, 'Retained selftest archive changed')
    with release.verified_zip(outer, 64 * 1024**2) as archive: raw = selftest_tool_bytes(archive)
    tool.write_bytes(raw); tool.chmod(0o755)
    targets.logged(evidence, 'verify-retained-observer-selftest-tool', ['codesign', '--verify', '--strict', str(tool)])
    require(checksum(tool) == SELFTEST_TOOL_SHA, 'Retained selftest verification changed its bytes')
    write(evidence / 'retained-observer-selftest-tool.json', {'producer': artifact, 'run': run, 'job': found[0],
        'sha256': SELFTEST_TOOL_SHA, 'bytes': SELFTEST_TOOL_BYTES, 'sourceSHA256': SELFTEST_SOURCE_SHA,
        'actualMacOS': version, 'minimumMacOS': '27.2.0', 'compiledOrResigned': False})


def bind(output):
    value = validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_bytes()))
    require(os.environ.get('GITHUB_JOB') == 'source' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Wrong source binding context')
    output.mkdir(parents=True, exist_ok=False)
    run = api('actions/runs/' + str(value['failureRunID']))
    jobs = api(f"actions/runs/{value['failureRunID']}/attempts/1/jobs?per_page=100")
    artifact = api('actions/artifacts/' + str(value['failureArtifactID']))
    verify_failure_origin(value, run, jobs, artifact)
    original = output.parent / 'original-current-pointer-failure.zip'; download(artifact, original)
    require(checksum(original) == value['failureArtifactSHA256'], 'Current failure ZIP changed')
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
    flags = re.findall(r'^CodeDirectory v=[a-fA-F0-9]+ size=[0-9]+ flags=0x([a-fA-F0-9]+)(?:[ (]|$)', description, re.MULTILINE)
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


def image_identity(path):
    resolved = path.resolve(strict=True); value = resolved.stat()
    return {'path': str(resolved), 'device': value.st_dev, 'inode': value.st_ino}


def contains_point(bounds, point):
    x, y, width, height = bounds
    return width != 0 and height != 0 and min(x, x + width) <= point[0] < max(x, x + width) \
        and min(y, y + height) <= point[1] < max(y, y + height)


def contains_rect(outer, inner):
    x, y, width, height = outer
    left, bottom, across, up = inner
    return min(x, x + width) <= min(left, left + across) and min(y, y + height) <= min(bottom, bottom + up) \
        and max(left, left + across) <= max(x, x + width) and max(bottom, bottom + up) <= max(y, y + height)


def native_predicates(row):
    flags = ('hitNSControl', 'hitNSTextView', 'hitHidden', 'rolePresent', 'roleNonEmpty',
        'roleNotUnknown', 'nativeAccessibilityEnabled')
    require(all(type(row.get(key)) is bool for key in flags) and isinstance(row.get('nativeRole'), str),
        'Untyped native guard operands')
    role = row['nativeRole']
    require((row['rolePresent'] or role == 'nil')
        and row['roleNonEmpty'] == (row['rolePresent'] and bool(role))
        and row['roleNotUnknown'] == (row['rolePresent'] and role != 'AXUnknown'), 'Native role operands disagree')
    x, y, width, height = row['probeFrame']
    visible = row['hitVisibleRect']
    return {'nativeControlType': row['hitNSControl'] or row['hitNSTextView'], 'notHidden': not row['hitHidden'],
        'visibleArea': visible[2] != 0 and visible[3] != 0,
        'probeContainsHitBounds': contains_rect([x - 1, y - 1, width + 2, height + 2], row['hitBoundsInRoot']),
        'visibleRectContainsPoint': contains_point(visible, row['hitPoint']),
        'nativeAccessibilityEnabled': row['nativeAccessibilityEnabled'],
        'nativeKnownRole': row['rolePresent'] and row['roleNonEmpty'] and row['roleNotUnknown']}


def window_predicates(row):
    value = row.get('windowGuard')
    require(isinstance(value, dict) and type(value.get('screenAvailable')) is bool
        and type(value.get('cgWindowListAvailable')) is bool and type(value.get('windowAtPoint')) is int
        and type(value.get('ownerPID')) is int and value['ownerPID'] == row['pid']
        and type(value.get('windowNumber')) is int and value['windowNumber'] == row['window'],
        'Window guard operands are missing or foreign')
    screen, quartz = value.get('firstScreenFrame'), value.get('quartzPoint')
    if value['screenAvailable']:
        require(isinstance(screen, list) and len(screen) == 4
            and all(type(n) in (int, float) and math.isfinite(n) for n in screen), 'Nonfinite first-screen geometry')
        require(quartz == [row['screenPoint'][0], screen[1] + screen[3] - row['screenPoint'][1]],
            'Window Quartz point differs from the original coordinate conversion')
    else:
        require(screen == quartz == [], 'Unavailable screen has invented geometry')
    windows = value.get('cgWindows')
    require(isinstance(windows, list) and len(windows) <= 1024
        and (value['cgWindowListAvailable'] or not windows), 'Window list is incomplete or excessive')
    matches = []
    def coordinate(number):
        if type(number) in (int, float):
            require(math.isfinite(number), 'Nonfinite window coordinate lacks its explicit encoding')
            return number
        if isinstance(number, dict) and set(number) == {'nonfinite'} and number['nonfinite'] in ('nan', '+inf', '-inf'):
            return float(number['nonfinite'])
        require(number is None, 'Unknown window coordinate encoding')
        return None
    for window in windows:
        require(isinstance(window, dict) and set(window) == {'ownerPID', 'number', 'boundsAvailable', 'bounds'}
            and all(window[key] is None or type(window[key]) is int for key in ('ownerPID', 'number'))
            and type(window['boundsAvailable']) is bool and isinstance(window['bounds'], dict)
            and set(window['bounds']) == {'X', 'Y', 'Width', 'Height'}, 'Unknown window list member')
        numbers = [coordinate(window['bounds'][key]) for key in ('X', 'Y', 'Width', 'Height')]
        require(window['boundsAvailable'] or all(number is None for number in numbers),
            'Unavailable window bounds have invented coordinates')
        if window['ownerPID'] == row['pid'] and window['number'] == row['window']:
            matches.append((window, numbers))
    require(type(value.get('matchingWindowCount')) is int and value['matchingWindowCount'] == len(matches),
        'Window match count disagrees with the complete raw list')
    unique = len(matches) == 1
    readable = unique and matches[0][0]['boundsAvailable']
    frame = matches[0][1] if readable else [None] * 4
    decoded = readable and all(number is not None for number in frame)
    finite = decoded and all(math.isfinite(number) for number in frame)
    require(value.get('cgFrame') == (frame if finite else []), 'Decoded window frame disagrees with raw bounds')
    width, height = decoded and abs(frame[2]) > 0, decoded and abs(frame[3]) > 0
    return {'windowAtPointMatches': value['windowAtPoint'] == row['window'], 'uniqueOwnWindow': unique,
        'boundsAvailable': readable, 'boundsDecoded': decoded, 'frameFinite': finite,
        'positiveWidth': width, 'positiveHeight': height,
        'containsQuartzPoint': bool(finite and value['screenAvailable'] and contains_point(frame, quartz))}


def verify_snapshots(raw, process, inspector, image, expected_identity=None, negative=False):
    require(raw.endswith(b'\n') and len(raw) <= 1024 * 1024, 'Inspector output is incomplete or oversized')
    rows = [json.loads(line) for line in raw.split(b'\n') if line]
    expected_identity = image_identity(image) if expected_identity is None else expected_identity
    allowed = {'loaded', 'discovery', 'probe-hook-ready', 'eligibility', 'hook-ready', 'viewport-convert', 'guard-snapshot', 'finished'}
    require(2 <= len(rows) <= 84 and all(isinstance(row, dict) and row.get('diagnosticOnly') is True
        and row.get('pid') == process['pid'] and row.get('kind') in allowed for row in rows), 'Foreign or excessive inspector records')
    require(rows[0]['kind'] == 'loaded' and rows[-1]['kind'] == 'finished'
        and sum(row['kind'] == 'loaded' for row in rows) == sum(row['kind'] == 'finished' for row in rows) == 1,
        'Inspector lifecycle is incomplete')
    loaded, finished = rows[0], rows[-1]
    times = [row.get('wallTime') for row in rows]
    require(all(isinstance(value, (int, float)) and math.isfinite(value) for value in times)
        and times == sorted(times) and process['launchBefore'] <= times[0] <= times[-1] <= process['endAfter']
        and loaded.get('parentPID') == process['parentPID'] and loaded.get('expectedImageIdentity') == expected_identity,
        'Inspector lifetime or declared image escapes the original process')
    counters = ('outputErrors', 'rejectedRecords', 'originalCalls', 'transparentReturns',
        'rectCalls', 'rectReturns', 'samples', 'rectSamples')
    require(all(type(finished.get(key)) is int and finished[key] >= 0 for key in counters),
        'Inspector counters are missing, negative or untyped')
    require(finished.get('outputErrors') == finished.get('rejectedRecords') == 0
        and finished.get('originalCalls') == finished.get('transparentReturns')
        and finished.get('rectCalls') == finished.get('rectReturns'), 'Inspector lost data or original returns')
    groups = {kind: [row for row in rows if row['kind'] == kind] for kind in allowed}
    geometry = groups['viewport-convert']; samples = groups['guard-snapshot']
    require(finished.get('rectSamples') == len(geometry) <= 32 and finished.get('samples') == len(samples) <= 16
        and len(groups['discovery']) + len(groups['eligibility']) <= 32
        and finished['originalCalls'] >= len(samples) and finished['rectCalls'] >= len(geometry),
        'Inspector counters differ from complete records')
    if negative:
        require(not groups['hook-ready'] and not geometry and not samples
            and finished['originalCalls'] == finished['transparentReturns'] == 0,
            'Refused selftest installed a root hook or observed a foreign scope')
        if negative == 'duplicate-probe':
            require(len(groups['probe-hook-ready']) == 1 and groups['probe-hook-ready'][0].get('installed') is True
                and groups['probe-hook-ready'][0].get('classImageIdentity') == expected_identity
                and groups['eligibility'] and any(row.get('uniqueProbeMatches') is False and row.get('eligible') is False
                    and row.get('classImageMatches') is True and row.get('ownAXImageMatches') is True
                    and all(row.get(key) is True for key in ('runtimeLineageMatches', 'effectiveAXMatches', 'declaredOwnAX'))
                    and all(isinstance(row.get(key), str) and row[key] and row[key] != 'nil'
                        for key in ('rootClass', 'runtimeRootClass'))
                    for row in groups['eligibility']), 'Duplicate-probe selftest did not exercise the refusal')
            return {'duplicateProbeRefused': True, 'records': len(rows), 'diagnosticOnly': True}
        require(finished['rectCalls'] == finished['rectReturns'] == 0 and not groups['probe-hook-ready']
            and groups['discovery'] and any(row.get('classFound') is True and row.get('imageMatches') is False
                for row in groups['discovery']), 'Foreign-image selftest did not exercise the refusal')
        return {'negativeImageRefused': True, 'records': len(rows), 'diagnosticOnly': True}
    require(len(groups['probe-hook-ready']) == len(groups['hook-ready']) == 1 and geometry,
        'Inspector did not install exactly one pair of hooks and observe the viewport')
    probe_hook, hook = groups['probe-hook-ready'][0], groups['hook-ready'][0]
    def pointer(value):
        return isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]+', value) is not None and int(value, 16) > 0
    require(all(pointer(hook.get(key)) for key in ('root', 'probe', 'windowIdentity'))
        and type(hook.get('window')) is int and hook['window'] > 0, 'Original window and view identities are missing')
    require(all(isinstance(hook.get(key), str) and hook[key] and hook[key] != 'nil'
                for key in ('rootClass', 'runtimeRootClass'))
        and all(hook.get(key) is True for key in ('runtimeLineageMatches', 'effectiveAXMatches', 'declaredOwnAX'))
        and pointer(hook.get('originalAXIMP')), 'Declared hosting class or runtime dispatch is unqualified')
    require(probe_hook.get('installed') is True and probe_hook.get('mainThread') is True
        and probe_hook.get('classImageIdentity') == probe_hook.get('expectedImageIdentity') == expected_identity
        and probe_hook.get('class') == 'NexGenVideo.AppRelaunchClickProbeView'
        and hook.get('installed') is True and hook.get('mainThread') is True
        and hook.get('rootAXImageIdentity') == hook.get('expectedImageIdentity') == expected_identity
        and hook.get('rootDeclaredImageIdentity') == expected_identity
        and hook.get('inspectorImage') == str(inspector) and hook.get('originalIMP', '').startswith('0x')
        and all(isinstance(row.get('typeEncoding'), str) and row['typeEncoding'] for row in (probe_hook, hook)),
        'Hook origin or ABI provenance is incomplete')
    require(probe_hook['wallTime'] <= hook['wallTime'] <= min(row['wallTime'] for row in geometry + samples)
        and finished.get('hookTime') == hook['wallTime'], 'Observation preceded its complete hook binding')
    def finite(row, key, count):
        require(isinstance(row.get(key), list) and len(row[key]) == count
            and all(type(value) in (int, float) and math.isfinite(value) for value in row[key]), 'Nonfinite observer geometry')
    for kind, measured in [('viewport-convert', geometry), ('guard-snapshot', samples)]:
        for index, row in enumerate(measured, 1):
            require(row.get('sample') == index and all(row.get(key) == hook.get(key)
                for key in ('root', 'probe', 'window', 'windowIdentity'))
                and isinstance(row.get('stack'), list) and 1 <= len(row['stack']) <= 64, 'Unbound observation or missing call stack')
    for row in geometry:
        for key in ('inputRect', 'returnedRect', 'clipBounds', 'rootBounds', 'probeVisibleRect'): finite(row, key, 4)
        require(pointer(row.get('clip')) and type(row.get('widthFits')) is bool and type(row.get('heightFits')) is bool
            and row['widthFits'] == (row['returnedRect'][2] <= row['clipBounds'][2])
            and row['heightFits'] == (row['returnedRect'][3] <= row['clipBounds'][3])
            and isinstance(row.get('ancestorClips'), list) and 1 <= len(row['ancestorClips']) <= 32
            and any(clip.get('clip') == row.get('clip') and clip.get('bounds') == row['clipBounds']
                for clip in row['ancestorClips']), 'Viewport predicates or ancestor ownership differ')
    predicates = ('nativeControlType', 'notHidden', 'visibleArea', 'probeContainsHitBounds',
        'visibleRectContainsPoint', 'nativeAccessibilityEnabled', 'nativeKnownRole')
    for row in samples:
        for key in ('rootPoint', 'windowPoint', 'screenPoint', 'hitPoint'): finite(row, key, 2)
        for key in ('probeFrame', 'hitBoundsInRoot', 'hitVisibleRect'): finite(row, key, 4)
        actual = native_predicates(row)
        require(all(type(row.get(key)) is bool and row[key] == actual[key] for key in predicates)
            and type(row.get('nativeGuardResult')) is bool and row['nativeGuardResult'] == all(actual.values()),
            'Inconsistent target predicates')
        window = window_predicates(row)
        supplied = row['windowGuard'].get('predicates')
        require(isinstance(supplied, dict) and set(supplied) == set(window)
            and all(type(supplied[key]) is bool and supplied[key] == window[key] for key in window)
            and type(row['windowGuard'].get('result')) is bool and row['windowGuard']['result'] == all(window.values()),
            'Inconsistent window predicates')
        for key in ('hostingAXChain', 'hitAXChain', 'hitOwnAXChain'):
            chain = row.get(key, {})
            require(isinstance(chain.get('elements'), list) and len(chain['elements']) <= 32
                and chain.get('end') in {'nil', 'cycle', 'nonProtocol', 'depthLimit', 'boundWindow'}
                and type(chain.get('completeToBoundWindow')) is bool
                and chain['completeToBoundWindow'] == (chain['end'] == 'boundWindow'), 'Ambiguous accessibility ancestry')
            if chain['completeToBoundWindow']:
                require(chain['elements'] and chain['elements'][-1].get('identity') == hook['windowIdentity'], 'Foreign AX window')
    return {'records': len(rows), 'samples': len(samples), 'rectSamples': len(geometry),
        'exactOriginalProcess': True, 'hookBeforeFirstSnapshot': True, 'outputComplete': True, 'diagnosticOnly': True,
        'viewportSizeFailures': [row['sample'] for row in geometry if not row['widthFits'] or not row['heightFits']],
        'falsePredicatesBySample': [[key for key in predicates if not row[key]] for row in samples],
        'falseWindowPredicatesBySample': [[key for key, value in row['windowGuard']['predicates'].items() if not value]
            for row in samples]}


def observer_selftest(evidence, inspector):
    tool = evidence / 'pointer-observer-selftest'
    restore_selftest_tool(tool, evidence)
    results = {}
    for name in ('owned-image', 'foreign-image', 'already-key', 'duplicate-probe'):
        folder = evidence / ('selftest-' + name); folder.mkdir()
        expected = Path('/usr/bin/true') if name == 'foreign-image' else tool
        environment = dict(os.environ)
        require(not any(key.startswith(('NGV_ACCEPTANCE', 'NGV_APP_DIAGNOSTIC', 'NSZombie', 'DYLD_INSERT_LIBRARIES'))
            for key in environment), 'Unexpected selftest substitution')
        environment.update(NGV_POINTER_GUARD_SNAPSHOT_DIR=str(folder), NGV_POINTER_GUARD_EXPECTED_IMAGE=str(expected))
        if name != 'already-key': environment['DYLD_INSERT_LIBRARIES'] = str(inspector)
        result = run_owned([str(tool), str(folder / 'witness.json'), name, str(inspector)], folder / 'console.log', environment, timeout=15)
        require(result['exitCode'] == 0 and result['processReaped'] and result['eof'] and result['stoppedReason'] is None,
            'Observer selftest did not complete normally')
        require(b'NGV_POINTER_INSPECTOR_FINALIZATION_FAILED' not in (folder / 'console.log').read_bytes(), 'Selftest output lost')
        witness = json.loads((folder / 'witness.json').read_bytes())
        require(witness.get('schema') == 'pointer-observer-selftest-witness/v1' and witness.get('pid') == result['pid']
            and witness.get('parentPID') == os.getpid() and witness.get('returnUnchanged') is True
            and witness.get('returnedRect') == witness.get('expectedRect')
            and witness.get('nilUnchanged') is True and witness.get('superclassUnchanged') is True
            and isinstance(witness.get('superclassMethods'), list) and len(witness['superclassMethods']) == 2
            and all(isinstance(value, str) and re.fullmatch('[1-9a-fA-F][0-9a-fA-F]*', value) for value in witness['superclassMethods'])
            and witness.get('scenario') == name, 'Independent selftest return witness differs')
        raw = (folder / 'snapshots.jsonl').read_bytes()
        measured = verify_snapshots(raw, result, inspector, expected, negative=name if name in {'foreign-image', 'duplicate-probe'} else False)
        if name in {'owned-image', 'already-key'}:
            rows = [json.loads(line) for line in raw.split(b'\n') if line]
            matches = [row for row in rows if row['kind'] == 'viewport-convert'
                and all(row.get(key) == witness.get(key) for key in ('root', 'probe', 'window', 'windowIdentity', 'clip'))
                and row.get('returnedRect') == witness['expectedRect'] and row.get('clipBounds') == witness['clipBounds']]
            require(matches and any(row['kind'] == 'guard-snapshot' and row.get('hit') == witness.get('hit') for row in rows),
                'Observer does not match the independently computed native fixture geometry and hit return')
        results[name] = {'process': result, 'witness': witness, 'measurement': measured}
        require(checksum(tool) == SELFTEST_TOOL_SHA, 'Selftest execution changed the retained tool')
    write(evidence / 'observer-selftest.json', {'results': results, 'complete': True, 'fullReleaseAcceptance': False})


def collect_selections(value, evidence, runtime, image, host, inspector):
    from run_macos_tests import app_environment
    collected = {}
    for index, identity in enumerate(value['diagnosticFunctionIDs'], 1):
        selection = evidence / ('selection-' + str(index)); selection.mkdir()
        folder = selection / 'host'; folder.mkdir()
        snapshots = selection / 'inspector'; snapshots.mkdir()
        environment = app_environment(dict(os.environ), runtime, image, folder)
        require(not any(key.startswith(('NGV_ACCEPTANCE', 'NGV_APP_DIAGNOSTIC', 'NSZombie', 'DYLD_INSERT_LIBRARIES'))
            for key in environment), 'Unexpected native diagnostic substitution')
        environment.update(NGV_APPKIT_TEST_BUNDLE=str(image), NGV_APPKIT_TEST_EVENTS=str(folder / 'events.jsonl'),
            NGV_APPKIT_TEST_RECEIPT=str(folder / 'host-receipt.json'), NGV_APPKIT_EXCEPTION_EVIDENCE=str(folder / 'exception.jsonl'),
            DYLD_INSERT_LIBRARIES=str(inspector), NGV_POINTER_GUARD_SNAPSHOT_DIR=str(snapshots),
            NGV_POINTER_GUARD_EXPECTED_IMAGE=str(image))
        command = [str(host), '--event-stream-version', '0', '--no-parallel', '--filter', scope_filter([identity])]
        with (selection / 'host.STARTED.json').open('x') as marker:
            json.dump({'command': command, 'at': time.time(), 'oneShot': True}, marker); marker.flush(); os.fsync(marker.fileno())
        result = run_owned(command, folder / 'console.log', environment)
        write(folder / 'process.json', result)
        require(result['processReaped'] and not result['cleanupSignalErrors'] and not result['logFinalizationErrors'],
            'Owned diagnostic child cleanup is incomplete')
        require(checksum(host) == value['originalHostSHA256'] and checksum(image) == value['testImage']['sha256'],
            'Original native images changed during diagnosis')
        collected[identity] = {'folder': folder, 'snapshots': snapshots, 'process': result}
    return collected


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
    build_inspector(inspector, evidence)
    observer_selftest(evidence, inspector)
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
    write(evidence / 'original-inputs.json', {'binding': binding, 'selected': value['selected'], 'testReceipt': receipt,
        'origins': origins, 'hostSHA256': checksum(host), 'imageSHA256': checksum(image),
        'runtimePath': str(runtime), 'imagePath': str(image), 'originalReleaseRuntimePath': bound['runtime'],
        'pathDomainChanged': str(runtime) != bound['runtime'], 'noAppOrTestCompilation': True, 'inspectorSHA256': checksum(inspector),
        'signaturePreflight': signatures, 'injectedInstrumentation': True, 'fullReleaseAcceptance': False})
    collected = collect_selections(value, evidence, runtime, image, host, inspector)
    selections = {}
    for identity, acquired in collected.items():
        folder, snapshots, result = acquired['folder'], acquired['snapshots'], acquired['process']
        selection = folder.parent
        require(result['eof'] and result['stoppedReason'] is None, 'Native measurement incomplete; preserve originals')
        require(b'NGV_POINTER_INSPECTOR_FINALIZATION_FAILED' not in (folder / 'console.log').read_bytes(),
            'Inspector finalization failed')
        measurement = measure((folder / 'events.jsonl').read_bytes(), [identity], expected_cases={})
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
        require(checksum(host) == value['originalHostSHA256'] and checksum(image) == value['testImage']['sha256'],
            'Original native images changed during diagnosis')
        snapshot = verify_snapshots((snapshots / 'snapshots.jsonl').read_bytes(), result, inspector, image)
        require(snapshot['samples'] > 0, 'Current field guard operands were not observed')
        selections[identity] = {'measurement': measurement, 'process': result, 'hostReceipt': host_receipt, 'snapshot': snapshot}
        write(selection / 'measurement.json', dict(selections[identity], fullReleaseAcceptance=False))
    write(evidence / 'measurement.json', {'schema': 'native-pointer-guard-measurement/v2', 'selections': selections,
        'allSelectionsComplete': set(selections) == set(value['diagnosticFunctionIDs']), 'fullReleaseAcceptance': False,
        'scopeLimit': 'Injected observation, filtered execution and restored paths can alter timing or accessibility state. '
            'Snapshot predicates precede the original guards; native events retain their actual outcomes. '
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
