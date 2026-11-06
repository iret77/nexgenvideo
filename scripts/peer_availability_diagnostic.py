"""Measure the unchanged test host's external AX availability in repository CI."""
import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys
import time
import zipfile

from button_query_diagnostic import source_subset

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'd7eb426e1d3e5ab0c6bd87f2906872bf317c7023'
RUN, JOB, ARTIFACT = 42213973803, 127880239639, 13501418118
DIGEST = '34224c6db872f83840acc5cb55b07b29d030e7f9bef431eff700ade974a937cb'
RAW_DIGEST = 'bd2d78334004370d8a70a8911443de4f9631dbd6b80da03b694c71b81ffbd385'
KIND = 'native-peer-availability'
QUERY = 'Sources/NexGenVideo/App/NativeButtonAccessibility.swift'
PEER = 'Sources/NexGenVideo/App/NativeAXPeer.swift'
FIXTURE = 'Tests/NexGenVideoTests/UI/NativeButtonInteractionTests.swift'
HOST = 'Tests/AppKitTestHost/AppKitTestHost.swift'
SUPPORT = 'Tests/AppKitTestHostSupport/AppKitTestHostSupport.m'
HEADER = 'Tests/AppKitTestHostSupport/include/AppKitTestHostSupport.h'
FILES = (QUERY, PEER, FIXTURE, HOST, SUPPORT, HEADER, *(
    'Sources/NexGenVideo/UI/' + name for name in
    ('CapsuleButton.swift', 'AppTheme.swift', 'DesignSystem.swift', 'PackAccent.swift')))
HARNESS = {'.github/workflows/diagnostic-acceptance.yml', 'scripts/test_diagnostic_acceptance.py',
    'scripts/peer_availability_diagnostic.py', 'scripts/peer_availability_diagnostic.swift',
    'scripts/peer_availability_raw.swift', 'scripts/test_peer_availability_diagnostic.py'}


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def write(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], stdin=subprocess.DEVNULL, timeout=30)


def validate_inputs(env):
    require(env['KIND'] == KIND and env['CANDIDATE_RUN'] == str(RUN)
            and env['CANDIDATE_SOURCE'] == SOURCE and env['CANDIDATE_ARTIFACT'] == str(ARTIFACT)
            and env['CANDIDATE_DIGEST'] == DIGEST, 'Exact Native777 failure required')
    require(re.fullmatch('[1-9][0-9]*', env['VERIFIED_PR']) and env['SCALE'] == '1',
            'Current complete Source proof and normal scale required')
    require(not any(env.get(key, '') for key in ('DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT',
        'JOURNEY_DIGEST', 'EXTRA_SOURCE', 'EXTRA_PRODUCTS', 'EXTRA_PRODUCTS_SHA', 'EXTRA_FAILURE',
        'EXTRA_FAILURE_SHA', 'RUNTIME_FAILURE_BINDING', 'PACKAGING_PRODUCER_SOURCE',
        'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256')),
        'Unused peer diagnostic selectors cannot be ignored')


def failure_archive(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)) == 20 and archive.testzip() is None,
                'Native777 original archive inventory or CRC differs')
        events = [json.loads(line) for line in archive.read(
            '_temp/release-test-evidence/app-swift-testing/events.jsonl').split(b'\n') if line]
        issues = [event['payload'] for event in events
                  if event['kind'] == 'event' and event['payload']['kind'] == 'issueRecorded']
        counts = Counter(issue['testID'] for issue in issues)
        require(len(issues) == 20 and len(counts) == 8 and all(
            identity.startswith('NexGenVideoTests.NativeButtonInteractionTests/') for identity in counts),
            'The actual original eight-method failure differs')
        host = json.loads(archive.read('_temp/release-test-evidence/app-swift-testing/host-receipt.json'))
        require(host['sourceSHA'] == SOURCE and host['completed'] is True
                and host['abiSucceeded'] is False and host['eventRecordCount'] == 13464,
                'Original completed failed host differs')
        return {'issueCounts': dict(counts), 'host': host,
                'memberHashes': {name: digest(archive.read(name)) for name in names}}


def fixture_subset(raw):
    start = b'    @MainActor private final class Fixture {'
    ready = b'        func ready(using session: NativeAXPeer.Session)'
    close = b'        func close() { window.contentView = nil; window.close() }\n    }'
    require(all(raw.count(marker) == 1 for marker in (start, ready, close)), 'Fixture ranges changed')
    left, middle, right = raw.index(start), raw.index(ready), raw.index(close)
    require(left < middle < right, 'Fixture range order changed')
    ranges = [(left, middle), (right, right + len(close))]
    return b''.join(raw[a:b] for a, b in ranges), ranges


def validate_changed_paths(paths):
    require(set(paths) <= HARNESS, 'App or unrelated source changed')


def bind(args):
    env = os.environ
    validate_inputs(env)
    require(env['GITHUB_ACTIONS'] == 'true' and env['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo'
            and env['GITHUB_RUN_ATTEMPT'] == '1', 'First repository CI attempt required')
    require(git('rev-parse', 'HEAD').decode().strip() == env['GITHUB_SHA']
            and not git('status', '--porcelain', '--untracked-files=no').strip(), 'Current source changed')
    git('merge-base', '--is-ancestor', SOURCE, env['GITHUB_SHA'])
    validate_changed_paths(git('diff', '--no-renames', '--name-only', SOURCE, env['GITHUB_SHA']).decode().splitlines())
    proof = json.loads((args.source_proof / 'receipt.json').read_text())
    require(proof['schema'] == 'core-pr-source-composition/v1' and proof['sourceSHA'] == env['GITHUB_SHA']
            and proof['runID'] == env['GITHUB_RUN_ID'] and proof['attempt'] == '1'
            and proof['originalRun']['id'] == int(env['VERIFIED_PR']), 'Current Source proof differs')
    sys.path.insert(0, str(ROOT / 'scripts/external-gui'))
    import test_bundle
    run = test_bundle.api('/actions/runs/' + str(RUN))
    jobs = test_bundle.api('/actions/runs/' + str(RUN) + '/jobs?per_page=100')
    artifact = test_bundle.api('/actions/artifacts/' + str(ARTIFACT))
    require(run['id'] == RUN and run['head_sha'] == SOURCE and run['run_attempt'] == 1
            and run['repository']['full_name'] == 'iret77/nexgenvideo' and run['actor']['login'] == 'iret77'
            and run['path'] == '.github/workflows/release.yml' and run['event'] == 'workflow_dispatch'
            and run['status'] == 'completed' and run['conclusion'] == 'failure', 'Original producer differs')
    require(jobs['total_count'] == len(jobs['jobs']), 'Original jobs incomplete')
    selected = [job for job in jobs['jobs'] if job['id'] == JOB]
    require(len(selected) == 1, 'Original builder missing')
    job = selected[0]
    require(job['run_id'] == RUN and job['head_sha'] == SOURCE and job['run_attempt'] == 1
            and job['name'] == 'release-build' and job['labels'] == ['macrunner']
            and job['status'] == 'completed' and job['conclusion'] == 'failure', 'Original builder differs')
    steps = {step['name']: step['conclusion'] for step in job['steps']}
    require(steps.get('Build the exact release test configuration') == 'success'
            and steps.get('Test the exact release configuration') == 'failure', 'Original compile/test differs')
    require(artifact['id'] == ARTIFACT and artifact['name'] == 'release-test-evidence'
            and artifact['digest'] == 'sha256:' + DIGEST and artifact['expired'] is False
            and artifact['workflow_run']['id'] == RUN and artifact['workflow_run']['head_sha'] == SOURCE,
            'Original artifact differs')
    args.evidence.mkdir(parents=True, exist_ok=False)
    original = args.evidence / 'original-evidence.zip'
    test_bundle.download(artifact, original)
    require(original.stat().st_size == artifact['size_in_bytes'] and digest(original.read_bytes()) == DIGEST,
            'Original archive bytes changed')
    observed = failure_archive(original)
    from verified_pr_source_checks import read_api
    raw = read_api('actions/jobs/' + str(JOB) + '/logs', maximum=8_000_000)
    require(digest(raw) == RAW_DIGEST, 'Original full builder log differs')
    (args.evidence / 'original-builder.log').write_bytes(raw)
    files = {name: git('show', SOURCE + ':' + name) for name in FILES}
    require(all((ROOT / name).read_bytes() == raw for name, raw in files.items()), 'Original sources changed')
    write(args.evidence / 'binding.json', {'schema': 'nexgenvideo/peer-availability-binding/1',
        'sourceSHA': env['GITHUB_SHA'], 'treeSHA': git('rev-parse', 'HEAD^{tree}').decode().strip(),
        'runID': env['GITHUB_RUN_ID'], 'attempt': '1', 'originalRun': run, 'originalJob': job,
        'originalArtifact': artifact, 'originalEvidence': observed, 'sourceProof': proof,
        'originalFullLogSHA256': RAW_DIGEST,
        'sourceFiles': {name: digest(raw) for name, raw in files.items()},
        'harnessFiles': {name: digest((ROOT / name).read_bytes()) for name in sorted(HARNESS)},
        'appAcceptance': False, 'appBuilds': 0, 'nativeRegressionSuiteRepeats': 0,
        'diagnosticFunctionExecutionsExpected': 2})


def command_timeout(deadline, now):
    remaining = deadline - now - 10
    require(remaining > 0, 'Absolute diagnostic deadline reached; reserve cleanup and upload time')
    return min(70, remaining)


def valid_frame(value):
    return isinstance(value, list) and len(value) == 4 and all(
        type(item) in (int, float) and math.isfinite(item) for item in value) and value[2] > 0 and value[3] > 0


def same_frame(actual, expected):
    return valid_frame(actual) and valid_frame(expected) and all(abs(a - b) <= 0.5 for a, b in zip(actual, expected))


def raw_window_bound(observed, request):
    if not all(window.get('PID') == request['PID'] and window.get('PIDStatus') == 0
               and window.get('role') == 'AXWindow' and valid_frame(window.get('frame'))
               for window in observed['windows']):
        return False
    candidates = [window for window in observed['windows'] if window.get('PID') == request['PID']
        and window.get('PIDStatus') == 0 and window.get('role') == 'AXWindow'
        and window.get('matchesRequestedFrame') is True and same_frame(window.get('frame'), request['windowFrame'])]
    cg = []
    for window in observed['CGWindows']:
        bounds = window.get('bounds')
        frame = [bounds.get(key) for key in ('X', 'Y', 'Width', 'Height')] if isinstance(bounds, dict) else None
        if window.get('PID') != request['PID'] or type(window.get('number')) is not int or window['number'] <= 0 \
                or window.get('onscreen') is not True or not valid_frame(frame):
            return False
        if same_frame(frame, request['windowFrame']):
            cg.append(window)
    if len(candidates) != 1 or len(cg) != 1 or cg[0]['number'] != request['windowNumber']:
        return False
    frame = [cg[0]['bounds'].get(key) for key in ('X', 'Y', 'Width', 'Height')]
    return same_frame(frame, request['windowFrame'])


def macho_uuid(path):
    raw = path.read_bytes()
    require(len(raw) >= 32, 'Mach-O header missing')
    magic, cpu, _, _, count, size, _, _ = struct.unpack_from('<8I', raw)
    require(magic == 0xfeedfacf and cpu == 0x0100000c and 0 < count <= 4096
            and 32 + size <= len(raw), 'Actual Mach-O architecture or commands differ')
    offset, found = 32, []
    for _ in range(count):
        require(offset + 8 <= 32 + size, 'Mach-O command header truncated')
        command, length = struct.unpack_from('<II', raw, offset)
        require(length >= 8 and offset + length <= 32 + size, 'Mach-O command truncated')
        if command == 0x1b:
            require(length == 24, 'Mach-O UUID size differs')
            found.append(raw[offset + 8:offset + 24].hex())
        offset += length
    require(offset == 32 + size and len(found) == 1 and found[0] != '0' * 32, 'Mach-O UUID missing or ambiguous')
    return found[0]


def verify_cg_samples(value):
    samples = value['preAXCGStability']['samples']
    require(isinstance(samples, list) and 2 <= len(samples) <= 50, 'Two actual CG stability samples required')
    previous = None
    for sample in samples:
        require(type(sample['at']) in (int, float) and math.isfinite(sample['at'])
                and (previous is None or sample['at'] > previous), 'CG sample times differ')
        previous = sample['at']
    for sample in samples[-2:]:
        request, windows = sample['request'], sample['windows']
        require(request == value['requestBefore'] and valid_frame(request['windowFrame'])
                and valid_frame(request['contentFrame']) and type(request['windowNumber']) is int
                and request['windowNumber'] > 0 and request['PID'] == value['PID'] and windows,
                'Actual stable NS request differs')
        require(all(window['pid'] == value['PID'] and type(window['number']) is int and window['number'] > 0
                    and window['onscreen'] is True and valid_frame(window['frame']) for window in windows),
                'CG stability inventory is unreadable')
        candidates = [window for window in windows if same_frame(window['frame'], request['windowFrame'])]
        require(len(candidates) == 1 and candidates[0]['number'] == request['windowNumber'], 'CG window not uniquely bound')
    require(samples[-1]['at'] <= value['firstPeer']['before']['at'], 'CG samples occur after first Peer started')


class Controller:
    def __init__(self, evidence):
        self.evidence = evidence
        self.deadline = time.monotonic() + 210

    def run(self, command, name, env=None):
        limit = command_timeout(self.deadline, time.monotonic())
        path = self.evidence / (name + '.log')
        started = time.monotonic()
        started_wall = time.time()
        with path.open('xb') as stream:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream,
                stderr=subprocess.STDOUT, env=env, start_new_session=True)
            timed_out = False
            try:
                code = process.wait(timeout=limit)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    code = process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        code = process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        code = None
            stream.flush()
            os.fsync(stream.fileno())
        value = {'command': command, 'PID': process.pid, 'exitCode': code, 'timedOut': timed_out,
            'parentPID': os.getpid(), 'startedWall': started_wall, 'finishedWall': time.time(),
            'processReaped': process.poll() is not None, 'started': started, 'finished': time.monotonic(), 'timeout': limit}
        write(self.evidence / (name + '.process.json'), value)
        require(value['processReaped'] and not timed_out and code == 0,
                'Owned diagnostic command failed; original evidence retained')
        return value


def verify_collection(folder, context, execution):
    value = json.loads((folder / 'observation.json').read_text())
    require(value['schema'] == 'nexgenvideo/peer-availability-observation/1'
            and value['context'] == context and value['collectionCompleted'] is True
            and value['appAcceptance'] is False and value['originalFullAppImage'] is False
            and value['diagnosticFunctionExecutions'] == 1, 'Incomplete diagnostic collection')
    process, products, source = execution['process'], execution['products'], execution['sourceSHA']
    require(set(products) == {'host', 'bundle', 'raw'} and len({item['path'] for item in products.values()}) == 3
            and re.fullmatch('[a-f0-9]{40}', source), 'Actual compiler product or Source identity missing')
    require(type(process['PID']) is int and process['PID'] > 1
            and process['PID'] == value['PID'] and process['parentPID'] == value['parentPID']
            and process['processReaped'] is True and process['exitCode'] == 0 and process['timedOut'] is False
            and process['startedWall'] <= value['startedWall'] <= value['finishedWall'] <= process['finishedWall'],
            'Observation is not bound to the actual started Host process')
    for item in products.values():
        require(digest(Path(item['path']).read_bytes()) == item['SHA256']
                and macho_uuid(Path(item['path'])) == item['uuid'], 'Retained compiler product changed')
    require(process['command'] == [products['host']['path'], '--event-stream-version', '0']
            and value['owner']['PID'] == value['PID'] and value['owner']['executable'] == products['host']['path']
            and type(value['owner']['start']) is int and value['owner']['start'] > 0
            and value['image'] == {'path': products['bundle']['path'], 'uuid': products['bundle']['uuid'],
                                  'SHA256': products['bundle']['SHA256']}
            and value['hostImage'] == {'path': products['host']['path'], 'uuid': products['host']['uuid'],
                                      'SHA256': products['host']['SHA256']}, 'Actual Host or loaded image differs')
    launch = value['launch']
    require(launch['class'] == 'NGVTestRuntimeApplication' and launch['isRunning'] is True
            and type(launch['isFinishedLaunching']) is bool and type(launch['initialPolicy']) is int
            and type(launch['actualPolicy']) is int and isinstance(launch['bundleURL'], str)
            and isinstance(launch['runLoopMode'], (str, type(None))), 'Actual launch metadata incomplete')
    peer = value['firstPeer']
    require(value['requestBefore'] == value['requestAfterPeer'], 'Target geometry changed during the first Peer query')
    snapshot = peer['snapshot']
    reader = snapshot['reader']
    require(reader['ownerPID'] == value['PID'] and reader['ownerStart'] == value['owner']['start']
            and reader['AXTrusted'] is True
            and snapshot['pid'] == value['PID'] and reader['readerPID'] != value['PID']
            and snapshot['expectedWindowFrame'] == value['requestBefore']['windowFrame']
            and snapshot['contentFrame'] == value['requestBefore']['contentFrame'], 'Peer target identity differs')
    require(peer['before']['at'] <= snapshot['startedUptime'] <= snapshot['finishedUptime'] <= peer['after']['at'],
            'First Peer timing lies outside its recorded heartbeat interval')
    require(value['preAXCGStability']['qualified'] is True and value['heartbeat']['truncated'] is False
            and isinstance(value['heartbeat']['timeline'], list), 'CG or heartbeat collection incomplete')
    ticks = value['heartbeat']['timeline']
    heartbeat = value['heartbeat']
    verify_cg_samples(value)
    require(heartbeat['observerValid'] is True and heartbeat['observerOnMainCommonModes'] is True
            and heartbeat['installedAt'] <= value['preAXCGStability']['samples'][0]['at']
            and heartbeat['recordedAt'] >= peer['after']['at'] and ticks,
            'Actual observer installation or tick collection missing')
    require(all(type(tick['at']) in (int, float) and math.isfinite(tick['at'])
                and type(tick['mainThread']) is bool and isinstance(tick['mode'], str)
                and tick['kind'] in ('runLoop', 'dispatch') for tick in ticks)
            and [tick['at'] for tick in ticks] == sorted(tick['at'] for tick in ticks)
            and all(heartbeat['installedAt'] <= tick['at'] <= heartbeat['recordedAt'] for tick in ticks),
            'Heartbeat timeline invalid')
    require(reader['image'] == products['bundle']['path'] and reader['imageSHA256'] == products['bundle']['SHA256']
            and reader['imageUUID'] == products['bundle']['uuid'], 'Peer did not execute the actual diagnostic bundle')
    lifecycle = peer['lifecycle']
    require(lifecycle['pid'] == reader['readerPID'] and lifecycle['processReaped']
            and lifecycle['exitStatus'] == 0 and not lifecycle['forced']
            and lifecycle['stdoutClosed'] and lifecycle['stderrClosed'] and lifecycle['protocolClean'],
            'Peer did not close cleanly')
    raw = value['rawAfterPeer']
    comparisons = []
    require([(item['context'], item['seconds']) for item in raw] == [
        ('background', '0.15'), ('main', '0.15'), ('background', '1')], 'Raw measurement order changed')
    require(heartbeat['recordedAt'] >= raw[-1]['after']['at'], 'Heartbeat evidence ended before the last raw observation')
    for item in raw:
        require(item['kind'] == 'raw-after-peer' and item['primedContext'] is True
                and item['before']['at'] >= peer['after']['at'] and item['reaped'] is True
                and item['timedOut'] is False and item['cancelled'] is False
                and item['exitStatus'] == 0, 'Raw process lifetime differs')
        stem = item['context'] + '-' + item['seconds']
        require(item['stdout'] == stem + '.stdout' and item['stderr'] == stem + '.stderr',
                'Raw evidence path differs')
        require((folder / item['stderr']).is_file(), 'Raw stderr capture missing')
        lines = (folder / item['stdout']).read_bytes().split(b'\n')
        require(len(lines) == 2 and lines[-1] == b'', 'Raw output must be exactly one complete JSON frame')
        observed = json.loads(lines[0])
        require(observed['schema'] == 'nexgenvideo/peer-availability-raw/1'
                and observed['targetPID'] == value['PID'] and observed['parentPID'] == value['PID']
                and observed['readerPID'] == item['PID'] and observed['context'] == item['context']
                and observed['mainThread'] == (item['context'] == 'main'), 'Raw target or thread differs')
        require(observed['ownerStart'] == reader['ownerStart']
                and type(observed['readerStart']) is int and observed['readerStart'] > 0
                and observed['requestedWindow'] == value['requestBefore']['windowNumber']
                and observed['requestedFrame'] == value['requestBefore']['windowFrame']
                and type(observed['AXTrustedBefore']) is bool and type(observed['AXTrustedAfter']) is bool
                and observed['AXTrusted'] == (observed['AXTrustedBefore'] and observed['AXTrustedAfter']),
                'Raw kernel identity, target window or trust interval differs')
        require(observed['readerExecutable'] == observed['imagePath'] == products['raw']['path']
                and observed['imageSHA256'] == products['raw']['SHA256']
                and observed['imageUUID'] == products['raw']['uuid'], 'Raw actual image differs')
        require(observed['ownerExecutable'] == products['host']['path']
                and observed['ownerSHA256'] == products['host']['SHA256'], 'Raw target executable differs')
        require(type(observed['AXTrusted']) is bool and type(observed['AXWindowsStatus']) is int
                and type(observed['timeoutStatus']) is int
                and abs(observed['seconds'] - float(item['seconds'])) < 0.0000001
                and all(type(observed[key]) in (int, float) and math.isfinite(observed[key])
                        for key in ('started', 'finished'))
                and item['before']['at'] <= observed['started'] <= observed['finished'] <= item['after']['at'],
                'Raw timing or AX status evidence differs')
        call = observed['AXWindowsCall']
        require(call['attribute'] == 'AXWindows' and call['status'] == observed['AXWindowsStatus']
                and call['timeoutStatus'] == observed['timeoutStatus']
                and observed['started'] <= call['started'] <= call['finished'] <= observed['finished'],
                'Actual AXWindows call interval differs')
        comparisons.append({'context': item['context'], 'seconds': item['seconds'],
            'status': ('UNQUALIFIED_RAW_CLIENT_TRUST' if not observed['AXTrusted'] else
                'WINDOW_BOUND_OBSERVATION_ONLY' if observed['AXWindowsStatus'] == 0
                and raw_window_bound(observed, value['requestBefore']) else 'APP_AX_AVAILABILITY_ONLY'),
            'rawCallsFollowPeerAndMayPrimeAX': True, 'appAcceptance': False})
    events = [json.loads(line) for line in (folder / 'events.jsonl').read_bytes().split(b'\n') if line]
    functions = {event['payload']['id'] for event in events
                 if event['kind'] == 'test' and event['payload']['kind'] == 'function'}
    kinds = Counter(event['payload']['kind'] for event in events if event['kind'] == 'event')
    started = [event['payload']['testID'] for event in events if event['kind'] == 'event'
               and event['payload']['kind'] == 'testStarted' and event['payload'].get('testID') in functions]
    ended = [event['payload']['testID'] for event in events if event['kind'] == 'event'
             and event['payload']['kind'] == 'testEnded' and event['payload'].get('testID') in functions]
    require(len(functions) == 1 and started == ended and len(started) == 1
            and kinds['runStarted'] == kinds['runEnded'] == 1
            and not any(kinds[key] for key in ('testSkipped', 'issueRecorded', 'testCancelled', 'testCaseCancelled')),
            'Expected exactly one completed new diagnostic function')
    host = json.loads((folder / 'host-receipt.json').read_text())
    require(host['pid'] == value['PID'] and host['started'] and host['completed'] and host['abiSucceeded']
            and host['runReturnedAfterCompletion'] and host['applicationRunningAtStart']
            and host['mainThread'] is True and host['sourceSHA'] == source
            and host['parentPID'] == process['parentPID'] and host['hostExecutable'] == products['host']['path']
            and host['bundleBinary'] == products['bundle']['path']
            and host['eventRecordCount'] == len(events), 'Actual host completion receipt differs')
    value['rawComparisons'] = comparisons
    value['contextComparison'] = ('UNQUALIFIED_REGULAR_POLICY_CHANGE' if context == 'regular'
        and (value.get('setRegularSucceeded') is not True or value['launch']['actualPolicy'] != 0)
        else 'OBSERVATION_ONLY')
    return value


def observe(args):
    require(os.environ['GITHUB_ACTIONS'] == 'true' and os.environ['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo'
            and os.environ['GITHUB_RUN_ATTEMPT'] == '1' and sys.platform == 'darwin', 'Use first macrunner CI attempt')
    args.evidence.mkdir(parents=True, exist_ok=False)
    controller = Controller(args.evidence)
    current = {}
    for name, command in [('tree', ['rev-parse', 'HEAD^{tree}']), ('head', ['rev-parse', 'HEAD']),
                          ('status', ['status', '--porcelain', '--untracked-files=no'])]:
        controller.run(['git', '-C', str(ROOT), *command], 'git-' + name)
        current[name] = (args.evidence / ('git-' + name + '.log')).read_text().strip()
    binding = json.loads((args.binding / 'binding.json').read_text())
    require(binding['schema'] == 'nexgenvideo/peer-availability-binding/1'
            and binding['sourceSHA'] == os.environ['GITHUB_SHA'] and binding['runID'] == os.environ['GITHUB_RUN_ID']
            and binding['attempt'] == '1' and binding['treeSHA'] == current['tree']
            and current['head'] == os.environ['GITHUB_SHA'] and not current['status'], 'Transferred source binding differs')
    require(set(binding['sourceFiles']) == set(FILES) and set(binding['harnessFiles']) == HARNESS
            and all(digest((ROOT / name).read_bytes()) == checksum
                    for name, checksum in {**binding['sourceFiles'], **binding['harnessFiles']}.items()),
            'Transferred framework or harness bytes changed')
    original = args.binding / 'original-evidence.zip'
    require(digest(original.read_bytes()) == DIGEST and failure_archive(original) == binding['originalEvidence'],
            'Transferred original evidence differs')
    require(binding['originalFullLogSHA256'] == RAW_DIGEST
            and digest((args.binding / 'original-builder.log').read_bytes()) == RAW_DIGEST,
            'Transferred full original builder log differs')
    sources = args.evidence / 'sources'
    sources.mkdir()
    originals = {name: (ROOT / name).read_bytes() for name in FILES}
    subset, ranges = source_subset(originals)
    subset['NativeAXPeer.swift'] = originals[PEER]
    fixture, fixture_ranges = fixture_subset(originals[FIXTURE])
    template = (ROOT / 'scripts/peer_availability_diagnostic.swift').read_bytes()
    require(template.count(b'// NGV_DIAGNOSTIC_FIXTURE') == 1, 'Diagnostic fixture marker changed')
    subset['PeerAvailability.swift'] = template.replace(b'// NGV_DIAGNOSTIC_FIXTURE', fixture)
    for name, raw in subset.items():
        (sources / name).write_bytes(raw)
    write(args.evidence / 'source-subsets.json', {'ranges': ranges, 'fixtureRanges': fixture_ranges,
        'emittedHashes': {name: digest(raw) for name, raw in subset.items()},
        'unchangedFullSources': [PEER, QUERY, HOST, SUPPORT, HEADER], 'originalFullAppImage': False})
    include = args.evidence / 'support-module'
    include.mkdir()
    (include / 'AppKitTestHostSupport.h').write_bytes(originals[HEADER])
    (include / 'module.modulemap').write_text('module AppKitTestHostSupport { header "AppKitTestHostSupport.h" export * }\n')
    support = args.evidence / 'host-support.o'
    host = args.evidence / 'NexGenVideoAppKitTestHost'
    bundle = args.evidence / 'PeerAvailability.dylib'
    raw_client = args.evidence / 'peer-availability-raw'
    require(os.uname().machine == 'arm64', 'Original native architecture differs')
    toolchain = {
        'swift': (['swift', '--version'], 'Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)\nTarget: arm64-apple-macosx27.2.0'),
        'xcode': (['xcodebuild', '-version'], 'Xcode 27.2\nBuild version 27B52'),
        'os-version': (['sw_vers', '-productVersion'], '27.2'),
        'os-build': (['sw_vers', '-buildVersion'], '26B123')}
    for name, (command, expected) in toolchain.items():
        controller.run(command, 'toolchain-' + name)
        require((args.evidence / ('toolchain-' + name + '.log')).read_text().strip() == expected,
                'Actual native toolchain differs from Native777: ' + name)
    write(args.evidence / 'python.json', {'actual': sys.version, 'exactOriginalPythonRequiredForAXMeasurement': False})
    controller.run(['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'], 'sdk-platform')
    platform = (args.evidence / 'sdk-platform.log').read_text().strip()
    frameworks = Path(platform) / 'Developer/Library/Frameworks'
    controller.run(['xcrun', 'clang', '-fobjc-arc', '-target', 'arm64-apple-macos26.0', '-I', str(include),
        '-c', str(ROOT / SUPPORT), '-o', str(support)], 'compile-support')
    prefix = ['xcrun', 'swiftc', '-swift-version', '6', '-O', '-enable-testing', '-parse-as-library', '-target', 'arm64-apple-macos26.0']
    controller.run([*prefix, '-I', str(include), str(ROOT / HOST), str(support),
        '-framework', 'AppKit', '-o', str(host)], 'compile-host')
    controller.run([*prefix, '-emit-library', '-module-name', 'PeerAvailability', '-F', str(frameworks),
        '-framework', 'Testing', '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
        *[str(sources / name) for name in sorted(subset)], '-o', str(bundle)], 'compile-bundle')
    controller.run([*prefix, str(sources / 'NativeAXPeer.swift'), str(sources / 'NativeButtonAccessibility.swift'),
        str(ROOT / 'scripts/peer_availability_raw.swift'), '-o', str(raw_client)], 'compile-raw')
    controller.run(['xcrun', 'dwarfdump', '--uuid', str(host), str(bundle), str(raw_client)], 'binary-uuids')
    write(args.evidence / 'product-hashes.json', {path.name: digest(path.read_bytes()) for path in
        [host, bundle, raw_client, support]})
    products = {name: {'path': str(path.resolve()), 'SHA256': digest(path.read_bytes()), 'uuid': macho_uuid(path)}
                for name, path in [('host', host), ('bundle', bundle), ('raw', raw_client)]}
    write(args.evidence / 'compiler-products.json', products)
    results = []
    for context in ('default', 'regular'):
        folder = args.evidence / context
        folder.mkdir()
        env = dict(os.environ, NGV_APPKIT_TEST_BUNDLE=str(bundle.resolve()),
            NGV_APPKIT_TEST_EVENTS=str((folder / 'events.jsonl').resolve()),
            NGV_APPKIT_TEST_RECEIPT=str((folder / 'host-receipt.json').resolve()),
            NGV_APPKIT_EXCEPTION_EVIDENCE=str((folder / 'exception.jsonl').resolve()),
            NGV_AVAILABILITY_CONTEXT=context, NGV_AVAILABILITY_OUTPUT=str(folder.resolve()),
            NGV_AVAILABILITY_RAW_CLIENT=str(raw_client.resolve()))
        process = controller.run([str(host.resolve()), '--event-stream-version', '0'], 'host-' + context, env)
        results.append(verify_collection(folder, context, {'process': process, 'products': products,
            'sourceSHA': os.environ['GITHUB_SHA']}))
    write(args.evidence / 'receipt.json', {'schema': 'nexgenvideo/peer-availability-collection/1',
        'sourceSHA': os.environ['GITHUB_SHA'], 'runID': os.environ['GITHUB_RUN_ID'], 'attempt': '1',
        'appAcceptance': False, 'appBuilds': 0, 'nativeRegressionSuiteRepeats': 0,
        'diagnosticFunctionExecutions': 2, 'observations': results,
        'scope': 'Isolated original host sources with a distinct small diagnostic test image; raw calls follow the first Peer query.'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['bind', 'observe'])
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--source-proof', type=Path)
    parser.add_argument('--binding', type=Path)
    args = parser.parse_args()
    require((args.action == 'bind' and args.source_proof is not None and args.binding is None)
            or (args.action == 'observe' and args.binding is not None and args.source_proof is None),
            'Exact action-specific paths required')
    (bind if args.action == 'bind' else observe)(args)
