import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from scene_history_hierarchy import (api, download, download_job_log, product_bytes,
    read_archive, require, sha, verify_failure, write)

MODE = 'native-scene-pointer-delivery'
PATHS = {
    '.github/workflows/diagnostic-acceptance.yml',
    '.github/workflows/scene-pointer-delivery-diagnostic.yml',
    'scripts/scene_pointer_delivery.py', 'scripts/scene_pointer_observer.swift',
    'scripts/test_scene_pointer_delivery.py', 'scripts/verify_diagnostic_candidate.py',
    'scripts/fixtures/app-cohort.json',
}
NEW_PATHS = {'.github/workflows/scene-pointer-delivery-diagnostic.yml',
    'scripts/scene_pointer_delivery.py', 'scripts/scene_pointer_observer.swift',
    'scripts/test_scene_pointer_delivery.py'}
STAGE = 'native scene revision committed after undo'


def validate_inputs(env):
    require(env.get('KIND', env.get('REPLAY_KIND')) == MODE, 'Wrong pointer diagnostic mode')
    fields = {'runID': ('PRODUCER_RUN', r'[1-9][0-9]*'), 'sourceSHA': ('PRODUCER_SHA', r'[a-f0-9]{40}'),
        'artifactID': ('DIAGNOSTIC_ID', r'[1-9][0-9]*'), 'artifactSHA256': ('DIAGNOSTIC_DIGEST', r'[a-f0-9]{64}'),
        'failureArtifactID': ('FAILURE_ID', r'[1-9][0-9]*'), 'failureArtifactSHA256': ('FAILURE_DIGEST', r'[a-f0-9]{64}'),
        'dmgSHA256': ('DMG_DIGEST', r'[a-f0-9]{64}'), 'verifiedPRRunID': ('VERIFIED_PR', r'[1-9][0-9]*')}
    result = {}
    for name, (key, pattern) in fields.items():
        value = env.get(key, '')
        require(isinstance(value, str) and re.fullmatch(pattern, value), 'Missing or invalid ' + key)
        result[name] = int(value) if name.endswith('ID') else value
    require(env.get('SCALE') == '1', 'Pointer measurement requires standard scale')
    unrelated = ['PRODUCT_SHA', 'PRODUCTS_ID', 'PRODUCTS_DIGEST', 'RUNTIME_FAILURE_BINDING',
        'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'PACKAGING_PRODUCER_SOURCE',
        'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256']
    require(not any(env.get(key) for key in unrelated), 'Unrelated inputs cannot be ignored')
    return result


def original_failure(files, source):
    process = json.loads(files['process.json'])
    require(process.get('sourceSHA') == source and process.get('mode') == 'runtime'
        and type(process.get('pid')) is int and process['pid'] > 0, 'Original process differs')
    failure = json.loads(files['process-failure.json'])
    require(failure == {'pid': process['pid'], 'error': 'bpy runtime exited with status 1'}, 'Original exit differs')
    progress = json.loads(files['spatial-scene-100.json'])
    observation = json.loads(files['runtime-failure-observation.json'])
    prefix = 'Native visual sources: ' + STAGE + ';'
    require(progress.get('failure', '').startswith(prefix)
        and observation.get('sourceSHA') == source and observation.get('hostPID') == process['pid']
        and observation.get('error') == progress['failure'], 'Original compact Undo failure differs')
    require('result.json' not in files and 'SELFTEST_BPY_OK' not in files['runtime-stderr.log'].decode()
        and 'SELFTEST_BPY_FAIL ' + progress['failure'] in files['runtime-stderr.log'].decode(),
        'Original runtime completion contradicts failure')
    interactions = progress['interactions']
    pointers = [x for x in interactions if x.get('kind') == 'pointer' and x.get('id') == 'spatial.undo']
    require(len(pointers) == 1, 'Expected exactly one original Undo pointer')
    pointer = pointers[0]
    frame = pointer['frame']
    require(len(frame) == 4 and all(type(v) in (int, float) and math.isfinite(v) for v in frame)
        and frame[0] >= 0 and frame[1] >= 0 and frame[2] > 0 and frame[3] > 0
        and frame[0] + frame[2] <= 960 and frame[1] + frame[3] <= 640, 'Original frame differs')
    require(pointer.get('point') == [frame[0] + frame[2] / 2, frame[1] + frame[3] / 2]
        and pointer.get('windowPoint') == [pointer['point'][0], 640 - pointer['point'][1]]
        and pointer.get('localMonitorDownObserved') is True and pointer.get('localMonitorUpObserved') is True,
        'Original local pointer delivery differs')
    revisions = [x['evidence'] for x in interactions if x.get('label') == 'native scene revision observation']
    require([x.get('action') for x in revisions] == ['create location', 'add cube', 'apply transform', 'undo'],
        'Original scene sequence differs')
    require(all(x.get('waitCompleted') is True for x in revisions[:3]), 'Original setup did not complete')
    before, after = revisions[2:]
    require(after.get('waitCompleted') is False and after.get('ready') is True and after.get('canUndo') is True
        and after.get('canRedo') is False and after.get('sceneError') is None
        and after.get('historyIntent') is None and json.loads(after['historyTrace'])['events'] == []
        and before['canonical'] == after['canonical'] and before['currentProbe'] == after['currentProbe'],
        'Original failure is not the unobserved Undo transition')
    return {'pid': process['pid'], 'window': pointer['window'], 'frame': frame,
        'canonical': after['canonical'], 'sequence': revisions, 'originalUndoAdmissionObserved': False}


def validate_changed_paths(lines):
    for line in lines:
        fields = line.split('\t')
        require(len(fields) == 2 and fields[0] in {'A', 'M'} and fields[1] in PATHS,
            'Only reviewed pointer diagnostic source may differ')


def validate_manifest_delta(previous, current):
    require({k: v for k, v in previous.items() if k != 'ciPaths'}
        == {k: v for k, v in current.items() if k != 'ciPaths'}, 'Compiled cohort identity or criteria changed')
    require(current.get('ciPaths') == sorted(set(previous['ciPaths']) | NEW_PATHS),
        'Cohort closure must add exactly the four diagnostic files')


def verifier(*args, **kwargs):
    from verify_diagnostic_candidate import verify_scene_pointer_delivery
    verify_scene_pointer_delivery(*args, **kwargs)


def bind(root):
    selected = validate_inputs(os.environ)
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
        and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Require original authorized Actions execution')
    root.mkdir(parents=True, exist_ok=False)
    from verified_pr_source_checks import prepare
    prepare(selected['verifiedPRRunID'], root / 'current-source-proof')
    manifest = 'scripts/fixtures/app-cohort.json'
    previous = json.loads(subprocess.check_output(['git', 'show', selected['sourceSHA'] + ':' + manifest],
        stdin=subprocess.DEVNULL, timeout=30))
    validate_manifest_delta(previous, json.loads(Path(manifest).read_text()))
    from retained_release_runtime import bind as bind_runtime
    artifact, runtime = bind_runtime(selected['runID'], selected['sourceSHA'], selected['artifactID'],
        selected['artifactSHA256'], verifier=verifier)
    changed = subprocess.check_output(['git', 'diff', '--no-renames', '--name-status',
        selected['sourceSHA'], 'HEAD'], text=True, stdin=subprocess.DEVNULL, timeout=30).splitlines()
    validate_changed_paths(changed)
    run = api('actions/runs/' + str(selected['runID']))
    jobs = api(f'actions/runs/{selected["runID"]}/attempts/1/jobs?per_page=100')
    failure = api('actions/artifacts/' + str(selected['failureArtifactID']))
    job = verify_failure(run, jobs, failure, selected)
    download(failure, root / 'original-failure.zip', 64 * 1024 * 1024)
    files = read_archive(root / 'original-failure.zip')
    boundary = original_failure(files, selected['sourceSHA'])
    raw_digest = download_job_log(job['id'], root / 'original-failure-job.log')
    inventory = api(f'actions/runs/{selected["runID"]}/artifacts?per_page=100')
    require(inventory['total_count'] == len(inventory['artifacts']) <= 100, 'Incomplete producer inventory')
    producers = [a for a in inventory['artifacts'] if a['name'] == 'release-workspace-producer']
    require(len(producers) == 1 and producers[0].get('expired') is False
        and producers[0]['workflow_run']['id'] == selected['runID']
        and producers[0]['workflow_run']['head_sha'] == selected['sourceSHA'], 'Producer differs')
    download(producers[0], root / 'original-producer.zip', 1024 * 1024)
    producer_files = read_archive(root / 'original-producer.zip')
    require(set(producer_files) == {'release-workspace-producer.json'}, 'Producer inventory differs')
    producer = json.loads(producer_files['release-workspace-producer.json'])
    require(producer.get('schema') == 'nexgenvideo/release-workspace-producer/1'
        and producer.get('sourceSHA') == selected['sourceSHA'] and producer.get('runID') == str(selected['runID'])
        and producer.get('runAttempt') == '1' and producer.get('dmgSHA256') == selected['dmgSHA256']
        and producer['app']['NGVSourceCommit'] == selected['sourceSHA']
        and producer['app']['treeSHA256'] == producer['mountedAppTreeSHA256'], 'Product identity differs')
    proof = {'schema': 'nexgenvideo/scene-pointer-binding/1', 'selected': selected,
        'runtimeArtifact': artifact, 'runtimeProof': runtime, 'producer': producer,
        'originalFailureJob': job, 'originalFailureArtifact': failure, 'originalBoundary': boundary,
        'originalRawSHA256': raw_digest, 'sourceFiles': {name: sha(Path(name)) for name in sorted(PATHS)},
        'harnessSourceSHA': os.environ['GITHUB_SHA'], 'executionRunID': os.environ['GITHUB_RUN_ID']}
    write(root / 'binding.json', proof)
    return artifact, runtime, proof


def verify_target(before, final, moved, pid):
    pointer = [e for e in before['progress']['interactions']
        if e.get('kind') == 'pointer' and e.get('id') == 'spatial.undo']
    require(len(pointer) == 1 and pointer[0].get('localMonitorDownObserved') is True
        and pointer[0].get('localMonitorUpObserved') is True, 'Original pointer missing')
    original = before['AX']
    for actual in (original, final, moved):
        require(all(actual.get(key) == original.get(key)
            for key in ('window', 'pid', 'CGWindow', 'screenFrame', 'screenPoint'))
            and actual['AXTree']['windowIdentity'] == original['AXTree']['windowIdentity']
            and actual['button']['identity'] == original['button']['identity'], 'Pointer target identity or geometry changed')
        cg, tree, button = actual['CGWindow'], actual['AXTree'], actual['button']
        require(actual['pid'] == cg.get('kCGWindowOwnerPID') == pid
            and actual['window'] == cg.get('kCGWindowNumber') == pointer[0]['window']
            and cg.get('kCGWindowIsOnscreen') is True and tree.get('truncated') is False
            and tree.get('visited') == len(tree['nodes']) and button in tree['nodes']
            and all(n.get('pid') == pid and n.get('pidStatus') == 0
                and n.get('unsupportedChildrenCount') == 0 for n in tree['nodes']), 'Incomplete or foreign target tree')
        require(tree['nodes'][0]['identity'] == tree['windowIdentity']
            and tree['nodes'][0]['attributes'].get('AXRole') == 'AXWindow'
            and len({n['identity'] for n in tree['nodes']}) == len(tree['nodes']), 'Ambiguous AX window or node identity')
        attributes, statuses = button['attributes'], button['statuses']
        require(actual.get('systemHitStatus') == 0 and 0 < len(actual['systemHitPath']) <= 16
            and all(n.get('pid') == pid for n in actual['systemHitPath'])
            and actual['systemHitPath'][-1]['identity'] == button['identity'], 'System pointer target is not the owned Undo')
        require(attributes.get('AXRole') == 'AXButton' and attributes.get('AXEnabled') is True
            and 'Undo' in (attributes.get('AXTitle'), attributes.get('AXDescription'))
            and all(statuses.get(k) == 0 for k in ('AXRole', 'AXEnabled', 'AXPosition', 'AXSize')),
            'Actual enabled Undo is unproven')
        bounds, frame = cg['kCGWindowBounds'], pointer[0]['frame']
        expected = [bounds['X'] + frame[0], bounds['Y'] + bounds['Height'] - 640 + frame[1], frame[2], frame[3]]
        require(all(type(x) in (int, float) and math.isfinite(x) for x in expected)
            and actual['screenFrame'] == expected and actual['screenPoint']
                == [expected[0] + expected[2] / 2, expected[1] + expected[3] / 2]
            and len(attributes['AXPosition']) == len(attributes['AXSize']) == 2
            and all(abs(a - b) <= 0.5 for a, b in zip(attributes['AXPosition'] + attributes['AXSize'], expected)),
            'Public Undo geometry differs from the original target')


def retained_bytes(root, name, maximum=64 * 1024 * 1024):
    path = root / name
    require(path.resolve(strict=True).is_relative_to(root.resolve(strict=True))
        and not path.is_symlink() and path.is_file() and 0 < path.stat().st_size <= maximum,
        'Invalid retained canonical original')
    return path.read_bytes()


def verify_canonical_originals(observed, before, after=None):
    root = observed / 'canonical-before'
    index = retained_bytes(root, 'index.json')
    require(hashlib.sha256(index).hexdigest() == before['indexSHA256']
        and json.loads(index).get('schema') == 'spatial-scene-index/v1'
        and before['head'] in json.loads(index)['scenes'], 'Retained original index differs')
    for prefix, manifest_key, snapshot_key in (('', 'manifest', 'snapshot'), ('prior-', 'priorManifest', 'priorSnapshot')):
        manifest = retained_bytes(root, prefix + 'manifest.json')
        snapshot = retained_bytes(root, prefix + 'snapshot.json')
        scene = retained_bytes(root, prefix + 'scene.blend')
        value = json.loads(manifest)
        require(value == before[manifest_key] and json.loads(snapshot) == before[snapshot_key]
            and value.get('schema') == 'spatial-scene-manifest/v1'
            and value['snapshotSHA256'] == hashlib.sha256(snapshot).hexdigest()
            and value['sceneSHA256'] == hashlib.sha256(scene).hexdigest()
            and before[manifest_key + 'SHA256'] == hashlib.sha256(manifest).hexdigest(),
            'Retained pre-intervention canonical bytes differ')
    require(before['manifest']['parentRevision'] == before['priorManifest']['revision']
        and before['manifest']['sceneID'] == before['priorManifest']['sceneID'] == before['head']['id']
        and before['manifest']['revision'] == before['head']['revision']
        and before['manifestSHA256'] == before['head']['manifestSHA256'], 'Original canonical lineage differs')
    current_objects, old_objects = before['snapshot']['objects'], before['priorSnapshot']['objects']
    require(len(current_objects) == len(old_objects) == 1 and current_objects[0]['id'] == old_objects[0]['id'],
        'Original cube identity differs')
    current_matrix, old_matrix = current_objects[0]['matrixWorld'], old_objects[0]['matrixWorld']
    require(len(current_matrix) == len(old_matrix) == 16
        and all(type(x) in (int, float) and math.isfinite(x) for x in current_matrix + old_matrix)
        and abs(current_matrix[3] - 0.5) < 0.000001 and abs(old_matrix[3]) < 0.000001,
        'Original transformed and prior cube matrices differ')
    if after is not None:
        root = observed / 'canonical-after'
        manifest = retained_bytes(root, 'manifest.json')
        snapshot = retained_bytes(root, 'snapshot.json')
        scene = retained_bytes(root, 'scene.blend')
        require(json.loads(manifest) == after['manifest'] and json.loads(snapshot) == after['snapshot']
            and after['manifest'].get('schema') == 'spatial-scene-manifest/v1'
            and after['head']['manifestSHA256'] == after['manifestSHA256'] == hashlib.sha256(manifest).hexdigest()
            and after['head']['sceneID'] == after['manifest']['sceneID']
            and after['head']['revision'] == after['manifest']['revision']
            and snapshot == retained_bytes(observed / 'canonical-before', 'prior-snapshot.json')
            and scene == retained_bytes(observed / 'canonical-before', 'prior-scene.blend'),
            'Retained restoration bytes or manifest identity differ')


def observation_result(observed, native, source, binary, observer_pid):
    process = json.loads((native / 'process.json').read_text())
    attachment = json.loads((observed / 'attachment.json').read_text())
    identity = attachment['processIdentity']
    require(process == {'pid': identity['pid'], 'sourceSHA': source, 'mode': 'runtime'}
        and identity['executable'] == str(binary.resolve(strict=True))
        and type(identity['startAbsoluteTime']) is int and identity['startAbsoluteTime'] > 0
        and attachment.get('observerPID') == observer_pid and observer_pid != identity['pid']
        and attachment.get('sourceSHA') == source and attachment.get('executableSHA256') == sha(binary),
        'External observer identity differs')
    success_path, failure_path = native / 'process-result.json', native / 'process-failure.json'
    require(success_path.is_file() != failure_path.is_file(), 'Missing or ambiguous supervised exit')
    if success_path.is_file():
        require(json.loads(success_path.read_text()) == {**process, 'returncode': 0}, 'Supervised native result differs')
        native_exit = 0
    else:
        require(json.loads(failure_path.read_text()) == {'pid': identity['pid'], 'error': 'bpy runtime exited with status 1'},
            'Native execution did not reach a normal supervised exit1')
        native_exit = 1
    completion = json.loads((observed / 'completion.json').read_text())
    marker = json.loads((observed / 'INTERVENTION-STARTED.json').read_text())
    posting = json.loads((observed / 'posting.json').read_text())
    before = json.loads((observed / 'before.json').read_text())
    verify_target(before, marker['AX'], posting['afterMoveAX'], identity['pid'])
    verify_canonical_originals(observed, before['canonical'])
    require(completion.get('processIdentity') == marker.get('processIdentity') == identity
        and completion.get('runtimeAccepted') is False and completion.get('interventionPosted') is True
        and marker.get('oneShot') is True and marker.get('diagnosticOnly') is True
        and type(marker.get('stableSeconds')) in (int, float) and 5 <= marker['stableSeconds'] < 90
        and marker.get('canonical') == before.get('canonical')
        and posting.get('diagnosticOnly') is True and posting.get('eventDeliveryAcknowledged') is False,
        'Incomplete or incorrectly classified one-shot intervention')
    times = [posting[k] for k in ('movePostedAt', 'downPostedAt', 'upPostedAt')]
    require(all(type(t) in (int, float) and math.isfinite(t) for t in times)
        and times[0] < times[1] < times[2] <= completion['finishedUptime']
        and posting.get('point') == marker['AX']['screenPoint'], 'Posting order or target differs')
    restored = (observed / 'first-progress-after.json').is_file()
    if restored:
        after = json.loads((observed / 'first-progress-after.json').read_text())
        baseline, result = before['canonical'], after['restoration']
        verify_canonical_originals(observed, baseline, result)
        manifest, prior, new = baseline['manifest'], baseline['priorManifest'], result['manifest']
        undos = [e['evidence'] for e in after['progress']['interactions']
            if e.get('evidence', {}).get('action') == 'undo']
        require(after.get('diagnosticOnly') is True and after['observedUptime'] >= times[-1]
            and len(undos) == 1 and undos[0].get('waitCompleted') is True
            and result['head'] == undos[0]['canonical']
            and new['sceneID'] == manifest['sceneID'] and new['revision'] != manifest['revision']
            and new['parentRevision'] == manifest['revision'] and new['restoredFromRevision'] == prior['revision']
            and new['snapshotSHA256'] == result['snapshotSHA256'] == prior['snapshotSHA256']
            and new['sceneSHA256'] == result['sceneSHA256'] == prior['sceneSHA256']
            and result['snapshot'] == baseline['priorSnapshot'], 'Not exactly the expected single restoration')
        require((observed / 'after.png').is_file(), 'Missing post-transition screenshot')
    require((observed / 'before.png').is_file(), 'Missing pre-intervention screenshot')
    return {'appPID': identity['pid'], 'singleUndoRestorationObserved': restored,
        'nativeProcessExitCode': native_exit,
        'diagnosticOnly': True, 'runtimeAccepted': False, 'overallAcceptancePassed': False,
        'causality': 'Combined elapsed-time, AX observation, pointer-motion, hover and HID intervention only',
        'eventDeliveryAcknowledged': False}


def prepare_fixtures(root, home):
    denied, approved = root / 'denied', root / 'approved-input'
    (denied / 'foreign-project').mkdir(parents=True, exist_ok=False)
    approved.mkdir()
    files = {denied / 'provider-secret': b'provider-secret',
        denied / 'canonical-artifact': b'canonical-project-truth',
        denied / 'foreign-project/scene.blend': b'foreign-project',
        home: b'host-home-secret', approved / 'fixture.json': b'{"approved":true}',
        approved / 'hardlink-source': b'hardlink'}
    for path, content in files.items():
        with path.open('xb') as stream:
            stream.write(content)
    (approved / 'symlink.json').symlink_to(denied / 'provider-secret')
    os.link(approved / 'hardlink-source', approved / 'hardlink.json')
    selected = [str(path) for path in list(files)[:4]]
    write(root / 'fixtures.json', {'deniedPaths': selected, 'approvedDirectory': str(approved),
        'files': [{'path': str(path), 'bytes': len(content), 'sha256': hashlib.sha256(content).hexdigest()}
            for path, content in files.items()], 'syntheticFixturesOnly': True})
    return {'NGV_TEST_SECRET': 'must-not-cross-xpc', 'NGV_BPY_DENIED_PATHS': json.dumps(selected),
        'NGV_BPY_APPROVED_INPUT_DIR': str(approved), 'PYTHONPATH': str(denied / 'foreign-python'),
        'BLENDER_USER_CONFIG': str(denied / 'foreign-blender')}


def wait_observer_ready(observer, output, source, binary, executable_hash):
    deadline = time.monotonic() + 10
    while True:
        require(observer.poll() is None, 'Observer preflight failed; App must not start')
        require(time.monotonic() < deadline, 'Observer preflight timed out; App must not start')
        if (output / 'ready.json').is_file():
            ready = json.loads(retained_bytes(output, 'ready.json', maximum=8192))
            require(ready == {'schema': 'nexgenvideo/scene-pointer-observer-ready/1',
                'observerPID': observer.pid, 'sourceSHA': source, 'executable': str(binary.resolve(strict=True)),
                'executableSHA256': executable_hash, 'AXTrusted': True, 'postEventAccess': True}
                and observer.poll() is None, 'Observer ready identity or native privileges differ')
            return ready
        time.sleep(0.05)


def run(root):
    require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('RUNNER_OS') == 'macOS', 'Native execution requires macrunner Actions')
    root.mkdir(parents=True, exist_ok=False)
    artifact, runtime, binding = bind(root / 'binding')
    selected, producer = binding['selected'], binding['producer']
    workspace = root.parent / ('scene-pointer-workspace-' + os.environ['GITHUB_RUN_ID'])
    from retained_release_runtime import restore
    restore(artifact, runtime, workspace)
    before = product_bytes(workspace, producer)
    write(root / 'actual-app-pack-before.json', before)
    native, observed = root / 'native', root / 'observer'
    native.mkdir(); observed.mkdir()
    source = root.parent / ('scene-pointer-source-' + os.environ['GITHUB_RUN_ID'])
    receipt = workspace.parent / (workspace.name + '-retained-transfer') / 'payload/bpy-source-receipt.json'
    with (root / 'source-bootstrap.log').open('xb') as stream:
        subprocess.run([sys.executable, 'scripts/consume_bpy_distributable_source.py', '--output-directory', str(source),
            '--source-sha', selected['sourceSHA'], '--receipt', str(receipt)], stdin=subprocess.DEVNULL,
            stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=480)
    observer_binary = root.parent / ('scene-pointer-observer-' + os.environ['GITHUB_RUN_ID'])
    with (root / 'observer-compile.log').open('xb') as stream:
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
            'scripts/scene_pointer_observer.swift', '-o', str(observer_binary)], stdin=subprocess.DEVNULL,
            stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=90)
    write(root / 'environment.json', {'sourceSHA': selected['sourceSHA'],
        'os': subprocess.check_output(['sw_vers'], text=True, timeout=10),
        'architecture': subprocess.check_output(['uname', '-m'], text=True, timeout=10).strip(),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True, timeout=30),
        'observerSourceSHA256': sha(Path('scripts/scene_pointer_observer.swift')),
        'observerExecutableSHA256': sha(observer_binary), 'appBuilds': 0, 'nativeUnitRuns': 0})
    fake = root.parent / ('scene-pointer-no-ambient-' + os.environ['GITHUB_RUN_ID'])
    fake.mkdir()
    for name in ('python3', 'blender'):
        path = fake / name; path.write_text('#!/bin/sh\nexit 99\n'); path.chmod(0o700)
    fixtures = prepare_fixtures(root, Path.home() / ('ngv-bpy-pointer-home-' + os.environ['GITHUB_RUN_ID']))
    binary = workspace / 'NexGenVideo.app/Contents/MacOS/NexGenVideo'
    done = root / 'app-supervision-complete.json'
    environment = dict(os.environ)
    observer, pid, supervisor_error, outcome = None, None, None, None
    def interrupted(number, _frame):
        raise InterruptedError('Owned pointer measurement interrupted: ' + str(number))
    handlers = {number: signal.signal(number, interrupted) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        for key in list(os.environ):
            if key.startswith(('NGV_SELFTEST', 'NGV_ACCEPTANCE', 'NGV_BPY_')):
                os.environ.pop(key)
        os.environ.update(fixtures)
        os.environ.update(NGV_SELFTEST_BPY=str(native), PATH=str(fake))
        with (root / 'observer.log').open('xb') as log:
            observer = subprocess.Popen([str(observer_binary), str(native), str(binary), selected['sourceSHA'],
                before['executableSHA256'], str(observed), str(done)], stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT, env=environment)
            wait_observer_ready(observer, observed, selected['sourceSHA'], binary, before['executableSHA256'])
            try:
                from bpy_runtime_acceptance import supervise
                supervise(binary, native, 'runtime', selected['sourceSHA'], 900)
            except AssertionError as error:
                if str(error) != 'bpy runtime exited with status 1':
                    raise
                supervisor_error = str(error)
            finally:
                if (native / 'process.json').is_file():
                    pid = json.loads((native / 'process.json').read_text())['pid']
                write(done, {'pid': pid, 'sourceSHA': selected['sourceSHA'], 'supervisorError': supervisor_error})
                try:
                    observer.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    observer.terminate()
                    try:
                        observer.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        observer.kill(); observer.wait(timeout=3)
                    raise ValueError('Owned observer needed forced cleanup')
            require(observer.returncode == 0, 'Observer incomplete; retain evidence without a diagnostic conclusion')
        outcome = observation_result(observed, native, selected['sourceSHA'], binary, observer.pid)
    finally:
        os.environ.clear(); os.environ.update(environment)
        if observer is not None and observer.poll() is None:
            observer.kill(); observer.wait(timeout=5)
        for number, handler in handlers.items():
            signal.signal(number, handler)
        app_gone = False
        if pid is not None:
            from bpy_runtime_acceptance import WorkerReader
            live = WorkerReader().identity(pid)
            attachment = observed / 'attachment.json'
            initial = json.loads(attachment.read_text())['processIdentity'] if attachment.is_file() else None
            app_gone = live is None or (initial is not None and live['start'] != initial['startAbsoluteTime'])
        after = product_bytes(workspace, producer)
        write(root / 'actual-app-pack-after.json', after)
        write(root / 'cleanup.json', {'appPID': pid, 'ownedAppGone': app_gone,
            'observerPID': observer.pid if observer is not None else None,
            'observerExitCode': observer.returncode if observer is not None else None,
            'observerReaped': observer is None or observer.returncode is not None,
            'beforeAfterAppPackExact': before == after})
    require(outcome is not None and app_gone and before == after, 'Incomplete measurement or cleanup')
    write(root / 'measurement.json', {'schema': 'nexgenvideo/scene-pointer-measurement/1', **outcome,
        'productSourceSHA': selected['sourceSHA'], 'harnessSourceSHA': binding['harnessSourceSHA'],
        'runtimeProducerRunID': selected['runID'], 'dmgSHA256': selected['dmgSHA256'],
        'supervisorError': supervisor_error, 'appBuilds': 0, 'nativeUnitRuns': 0,
        'publicationAuthorised': False})


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=('bind', 'run'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    (run if args.action == 'run' else bind)(args.output.resolve())


if __name__ == '__main__':
    main()
