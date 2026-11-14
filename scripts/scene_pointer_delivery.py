import argparse
import ast
import base64
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import struct
import subprocess
import sys
import time
import zipfile

from scene_history_hierarchy import (api, download, download_job_log, product_bytes,
    read_archive, require, sha, verify_failure, write)

MODE = 'native-scene-pointer-delivery'
PATHS = {
    '.github/workflows/diagnostic-acceptance.yml',
    '.github/workflows/scene-pointer-delivery-diagnostic.yml',
    'scripts/scene_pointer_delivery.py', 'scripts/scene_pointer_observer.swift',
    'scripts/test_scene_pointer_delivery.py', 'scripts/verify_diagnostic_candidate.py',
    'scripts/fixtures/app-cohort.json',
    'scripts/external-gui/test_bundle.py', 'scripts/test_external_gui_test_bundle.py',
    'scripts/compiled_app_release.py', 'scripts/test_retained_release_runtime.py',
    'scripts/test_compiled_component_assembly.py',
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
    reuse = {'observerSourceSHA': ('PRODUCT_SHA', r'[a-f0-9]{40}'),
        'observerArtifactID': ('PRODUCTS_ID', r'[1-9][0-9]*'),
        'observerArtifactSHA256': ('PRODUCTS_DIGEST', r'[a-f0-9]{64}')}
    if any(env.get(key) for key, _ in reuse.values()):
        for name, (key, pattern) in reuse.items():
            value = env.get(key, '')
            require(isinstance(value, str) and re.fullmatch(pattern, value), 'Incomplete observer selector: ' + key)
            result[name] = int(value) if name.endswith('ID') else value
    unrelated = ['RUNTIME_FAILURE_BINDING',
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


def compile_recipe(source):
    calls = [node for node in ast.walk(ast.parse(source)) if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name)
        and node.func.value.id == 'subprocess' and node.func.attr == 'run' and node.args
        and isinstance(node.args[0], ast.List) and len(node.args[0].elts) >= 2
        and all(isinstance(value, ast.Constant) for value in node.args[0].elts[:2])
        and [value.value for value in node.args[0].elts[:2]] == ['xcrun', 'swiftc']]
    require(len(calls) == 1, 'Observer compiler recipe is ambiguous')
    return ast.dump(calls[0], include_attributes=False)


def observer_macho(raw):
    require(len(raw) >= 32, 'Truncated observer executable')
    magic, cpu, subtype, kind, count, size, _, reserved = struct.unpack_from('<8I', raw)
    require((magic, cpu, subtype, kind, reserved) == (0xFEEDFACF, 0x100000C, 0, 2, 0)
        and 0 < count <= 256 and 0 < size <= len(raw) - 32, 'Observer must be a thin arm64 executable')
    offset, builds = 32, []
    for _ in range(count):
        require(offset + 8 <= 32 + size, 'Truncated observer load command')
        command, length = struct.unpack_from('<II', raw, offset)
        require(length >= 8 and length % 8 == 0 and offset + length <= 32 + size,
            'Invalid observer load command')
        if command == 0x32:
            require(length >= 24, 'Truncated observer deployment command')
            _, _, platform, minimum, sdk, tools = struct.unpack_from('<6I', raw, offset)
            require(length == 24 + tools * 8, 'Invalid observer tool commands')
            builds.append({'platform': platform, 'minimumOS': minimum, 'sdk': sdk})
        offset += length
    require(offset == 32 + size and len(builds) == 1 and builds[0]['platform'] == 1,
        'Observer macOS deployment identity differs')
    return builds[0]


def observer_archive(path):
    files = read_archive(path)
    with zipfile.ZipFile(path) as archive:
        item = archive.getinfo('scene-pointer-delivery/observer-executable')
        require(stat.S_ISREG(item.external_attr >> 16) and 0 < item.file_size <= 16 * 1024 * 1024,
            'Observer member is not a bounded regular file')
    return files


def bind_observer(root, selected, producer):
    artifact = api('actions/artifacts/' + str(selected['observerArtifactID']))
    run_id = artifact['workflow_run']['id']
    source = selected['observerSourceSHA']
    run = api('actions/runs/' + str(run_id))
    require(type(run_id) is int and run_id > 0 and run.get('id') == run_id and run.get('head_sha') == source
        and run.get('workflow_id') == 355242770 and run.get('run_attempt') == 1
        and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and run.get('path') == '.github/workflows/diagnostic-acceptance.yml'
        and run.get('event') == 'workflow_dispatch' and run.get('actor', {}).get('login') == 'iret77'
        and run.get('head_branch') == 'iret77/rc-delivery-base-795'
        and run.get('status') == 'completed' and run.get('conclusion') == 'failure', 'Observer producer differs')
    jobs = api(f'actions/runs/{run_id}/attempts/1/jobs?per_page=100')
    inventory = api(f'actions/runs/{run_id}/artifacts?per_page=100')
    require(jobs['total_count'] == len(jobs['jobs']) <= 100
        and inventory['total_count'] == len(inventory['artifacts']) <= 100, 'Incomplete observer inventory')
    matches = [j for j in jobs['jobs'] if j['name'] == 'native-scene-pointer-delivery / measurement']
    require(len(matches) == 1, 'Ambiguous observer producer job')
    job = matches[0]
    require(job.get('run_id') == run_id and job.get('head_sha') == source and job.get('run_attempt') == 1
        and job.get('labels') == ['macrunner'] and job.get('status') == 'completed'
        and job.get('conclusion') == 'failure', 'Observer job identity differs')
    failures = [s['name'] for s in job['steps'] if s.get('conclusion') == 'failure']
    uploads = [s for s in job['steps'] if s['name'] == 'Retain the complete one-shot observation']
    require(failures == ['Measure one HID intervention during the retained full bpy harness']
        and len(uploads) == 1 and uploads[0].get('conclusion') == 'success', 'Observer failure boundary differs')
    matches = [a for a in inventory['artifacts'] if a['name'] == f'native-scene-pointer-delivery-{run_id}']
    require(len(matches) == 1 and matches[0] == artifact
        and artifact['id'] == selected['observerArtifactID'] and artifact['workflow_run']['head_sha'] == source
        and artifact.get('expired') is False
        and artifact['digest'] == 'sha256:' + selected['observerArtifactSHA256'], 'Observer artifact differs')
    instant = lambda value: datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(instant(job['started_at']) <= instant(artifact['created_at']) <= instant(artifact['updated_at'])
        <= instant(job['completed_at']) and instant(artifact['expires_at']) > datetime.now(timezone.utc),
        'Observer artifact attempt time differs')
    archive = root / 'original-observer.zip'
    download(artifact, archive, 64 * 1024 * 1024)
    files = observer_archive(archive)
    prefix = 'scene-pointer-delivery/'
    get = lambda name: json.loads(files[prefix + name])
    binding, environment = get('binding/binding.json'), get('environment.json')
    require(binding['harnessSourceSHA'] == source and binding['executionRunID'] == str(run_id),
        'Observer original source binding differs')
    require(binding['producer'] == producer, 'Observer retained product identity differs')
    for key in ('runID', 'sourceSHA', 'artifactID', 'artifactSHA256', 'failureArtifactID',
                'failureArtifactSHA256', 'dmgSHA256'):
        require(binding['selected'][key] == selected[key], 'Observer product/failure selector differs: ' + key)
    def original(path):
        raw = subprocess.check_output(['git', 'show', source + ':' + path], stdin=subprocess.DEVNULL, timeout=30)
        require(hashlib.sha256(raw).hexdigest() == binding['sourceFiles'][path], 'Observer source hash differs')
        return raw
    require(set(binding['sourceFiles']) == PATHS, 'Observer original source closure differs')
    for path in sorted(PATHS):
        original(path)
    require(hashlib.sha256(original('scripts/scene_pointer_observer.swift')).hexdigest()
        == environment['observerSourceSHA256'] == sha(Path('scripts/scene_pointer_observer.swift')),
        'Observer implementation changed')
    require(compile_recipe(original('scripts/scene_pointer_delivery.py'))
        == compile_recipe(Path('scripts/scene_pointer_delivery.py').read_bytes()), 'Observer compile recipe changed')
    raw = files[prefix + 'observer-executable']
    digest = hashlib.sha256(raw).hexdigest()
    deployment = observer_macho(raw)
    require(digest == environment['observerExecutableSHA256'] and environment['architecture'] == 'arm64'
        and environment['sourceSHA'] == selected['sourceSHA'] and environment['appBuilds'] == 0
        and environment['nativeUnitRuns'] == 0 and files[prefix + 'observer-compile.log'] == b'',
        'Observer compiler evidence differs')
    before, after = get('actual-app-pack-before.json'), get('actual-app-pack-after.json')
    ready, attachment, cleanup = get('observer/ready.json'), get('observer/attachment.json'), get('cleanup.json')
    process, failure = get('native/process.json'), get('native/runtime-failure-observation.json')
    expected_app = binding['producer']['app']
    require(before == after and before['appTreeSHA256'] == binding['producer']['mountedAppTreeSHA256']
        and before['packTreeSHA256'] == binding['producer']['packTreeSHA256']
        and before['executableSHA256'] == expected_app['executableSHA256'] == ready['executableSHA256'] == attachment['executableSHA256']
        and expected_app['NGVSourceCommit'] == selected['sourceSHA'], 'Observer original App bytes differ')
    require(ready['schema'] == 'nexgenvideo/scene-pointer-observer-ready/1'
        and ready['AXTrusted'] is True and ready['postEventAccess'] is True
        and ready['sourceSHA'] == attachment['sourceSHA'] == failure['sourceSHA'] == process['sourceSHA'] == selected['sourceSHA']
        and ready['observerPID'] == attachment['observerPID'] == cleanup['observerPID']
        and type(ready['observerPID']) is int and ready['observerPID'] > 1
        and attachment['processIdentity']['pid'] == process['pid'] == cleanup['appPID'] == failure['hostPID']
        and type(process['pid']) is int and process['pid'] > 1 and process['pid'] != ready['observerPID']
        and attachment['processIdentity']['startAbsoluteTime'] > 0
        and attachment['processIdentity']['executable'] == ready['executable']
        and process['mode'] == 'runtime', 'Observer original execution identity differs')
    require(cleanup['ownedAppGone'] is True and cleanup['observerReaped'] is True
        and cleanup['beforeAfterAppPackExact'] is True and cleanup['observerExitCode'] == 1
        and failure['error'] == 'invalid open request'
        and get('native/process-failure.json') == {'pid': process['pid'], 'error': 'bpy runtime exited with status 1'}
        and prefix + 'measurement.json' not in files and prefix + 'observer/INTERVENTION-STARTED.json' not in files
        and prefix + 'observer/posting.json' not in files,
        'Observer negative producer or cleanup differs')
    raw_digest = download_job_log(job['id'], root / 'original-observer-job.log')
    return {'artifact': artifact, 'run': run, 'job': job, 'rawSHA256': raw_digest,
        'sourceSHA': source, 'executableSHA256': digest, 'compileEnvironment': environment, 'deployment': deployment}


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
    if 'observerArtifactID' in selected:
        proof['observerReuse'] = bind_observer(root, selected, producer)
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


def supervise_with_open_capture(binary, native, source):
    from bpy_runtime_acceptance import capture_open_logs, supervise
    failure = None
    with capture_open_logs(native):
        try:
            supervise(binary, native, 'runtime', source, 900)
        except AssertionError as error:
            if str(error) != 'bpy runtime exited with status 1':
                raise
            failure = str(error)
    return failure


def verify_open_capture(native, observed, binary, source, started, ended):
    receipt = json.loads((native / 'open-capture.json').read_bytes())
    require(receipt.get('reaped') is True and receipt.get('stoppedEarly') is False
        and receipt.get('cancelled') == [] and receipt.get('cleanupErrors') == []
        and type(receipt.get('returncode')) is int, 'Open capture was incomplete')
    process = json.loads((native / 'process.json').read_bytes())
    attachment = json.loads((observed / 'attachment.json').read_bytes())
    identity = attachment['processIdentity']
    require(process['sourceSHA'] == attachment['sourceSHA'] == source and process['pid'] == identity['pid']
        and identity['executable'] == str(binary) and identity['startAbsoluteTime'] > 0
        and attachment['executableSHA256'] == sha(binary), 'Open capture host binding differs')
    records = []
    for line in (native / 'open-events.ndjson').read_text().splitlines():
        if not line.strip() or line.startswith('Filtering the log data using '):
            continue
        event = json.loads(line)
        message = event.get('eventMessage', '')
        if not message.startswith(('open.preparation ', 'open.prepared ', 'open.fail ')):
            continue
        parts = message.split()
        fields = dict(value.split('=', 1) for value in parts[1:])
        require(len(fields) == len(parts) - 1, 'Duplicate open log fields')
        records.append((parts[0], fields, event))
    host = [entry for entry in records if entry[0] == 'open.preparation'
        and entry[2].get('processID') == process['pid']]
    require(host, 'No owned host open event captured')
    sessions = []
    def origin(event, pid, image, subsystem, category):
        require(event.get('processID') == pid and event.get('processImagePath') == image
            and event.get('subsystem') == subsystem and event.get('category') == category,
            'Foreign open log event')
        stamp = datetime.fromisoformat(event['timestamp'].replace('Z', '+00:00'))
        require(stamp.tzinfo is not None and started - 1 <= stamp.timestamp() <= ended + 1
            and type(event.get('machTimestamp')) is int and event['machTimestamp'] > 0,
            'Open log timestamp outside owned capture')
    for _, fields, event in host:
        origin(event, process['pid'], str(binary), 'de.h5ventures.nexgenvideo', 'bpy-open')
        require(event['machTimestamp'] >= identity['startAbsoluteTime'], 'Open event predates host process')
        session, pid, start = fields['session'], int(fields['servicePID']), int(fields['serviceStart'])
        require(pid > 1 and pid != process['pid'] and start > 0, 'Invalid open service identity')
        prepared = [entry for entry in records if entry[0] == 'open.prepared' and entry[1].get('session') == session]
        require(len(prepared) == 1, 'Missing or ambiguous owned service preparation')
        _, prepared_fields, prepared_event = prepared[0]
        image = prepared_event.get('processImagePath', '')
        require(re.fullmatch(re.escape(str(binary.parent.parent))
            + r'/XPCServices/NexGenVideoBpyService[01]\.xpc/Contents/MacOS/NexGenVideoBpyService', image),
            'Foreign service image')
        origin(prepared_event, pid, image, 'de.h5ventures.nexgenvideo.bpy-service', 'open-diagnostic')
        require(prepared_fields.get('pid') == str(pid) and prepared_fields.get('start') == str(start)
            and start <= prepared_event['machTimestamp'] <= event['machTimestamp'], 'Service preparation identity/order differs')
        failures = []
        for _, failed, logged in [entry for entry in records if entry[0] == 'open.fail' and entry[1].get('session') == session]:
            origin(logged, pid, image, 'de.h5ventures.nexgenvideo.bpy-service', 'open-diagnostic')
            require(failed.get('pid') == str(pid) and failed.get('start') == str(start)
                and failed.get('owner') and failed.get('stage')
                and failed.get('domain') and re.fullmatch(r'-?[0-9]+', failed.get('code', ''))
                and logged['machTimestamp'] >= event['machTimestamp'], 'Incomplete open failure discriminator')
            failures.append({'fields': failed, 'event': logged,
                'ownerMatchesPreparation': failed['owner'] == prepared_fields['owner']})
        sessions.append({'sessionID': session, 'servicePID': pid, 'serviceStart': start,
            'hostPreparation': event, 'servicePreparation': prepared_event, 'failures': failures})
    observation = native / 'runtime-failure-observation.json'
    if observation.is_file() and json.loads(observation.read_bytes()).get('error') == 'invalid open request':
        failed_sessions = []
        for path in native.glob('open-failure-*.json'):
            record = json.loads(path.read_bytes())
            require(record.get('hostPID') == process['pid'] and record.get('sourceSHA') == source,
                'Foreign failed open receipt')
            raw = base64.b64decode(record['response'], validate=True)
            require(hashlib.sha256(raw).hexdigest() == record['responseSHA256'], 'Failed open response digest differs')
            response = json.loads(raw)
            if response.get('ok') is False and response.get('message') == 'invalid open request':
                failed_sessions.append(record['sessionID'])
        require(failed_sessions and all(any(row['sessionID'] == session
            and any(failure['ownerMatchesPreparation'] for failure in row['failures']) for row in sessions)
            for session in failed_sessions), 'Actual invalid-open service discriminator is absent')
    return {'schema': 'nexgenvideo/pointer-open-capture/1', 'sourceSHA': source,
        'hostIdentity': identity, 'started': started, 'ended': ended, 'sessions': sessions,
        'rawSHA256': sha(native / 'open-events.ndjson'), 'diagnosticOnly': True}


def check_observer_geometry(root, binary, environment):
    receipt = root / 'observer-geometry-selfcheck.json'
    require(not receipt.exists() and not receipt.is_symlink(), 'Stale observer geometry receipt')
    nonce = os.urandom(16).hex()
    with (root / 'observer-geometry-selfcheck.log').open('xb') as stream:
        subprocess.run([str(binary), '--self-check-geometry', str(receipt),
            environment['observerSourceSHA256'], environment['observerExecutableSHA256'], nonce],
            stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=15)
    require(receipt.is_file() and not receipt.is_symlink() and receipt.stat().st_size <= 65536,
        'Missing or invalid observer geometry receipt')
    value = json.loads(receipt.read_bytes())
    require(isinstance(value, dict) and value.get('schema') == 'nexgenvideo/observer-geometry-selfcheck/1'
        and value.get('nonce') == nonce and value.get('sourceSHA256') == environment['observerSourceSHA256']
        and value.get('executableSHA256') == environment['observerExecutableSHA256']
        and type(value.get('pid')) is int and value['pid'] > 0
        and all(value.get(key) is True for key in ('passed', 'windowConsumer', 'buttonConsumer', 'screenConsumers', 'invalidRejected'))
        and type(value.get('oldCGFloatArrayCastsToDouble')) is bool,
        'Foreign or incomplete observer geometry receipt')
    require(value.get('position') == [-12.5, 25.25] and value.get('size') == [960, 640]
        and value.get('screen') == {'screenFrame': [-12.5, 25.25, 50, 28], 'screenPoint': [12.5, 39.25]},
        'Observer geometry numeric contract differs')
    write(root / 'observer-geometry-verified.json', {'receiptSHA256': sha(receipt), 'environment': environment,
        'nonce': nonce, 'nativeGeometryQualified': True, 'appStarted': False})


def run(root):
    require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('RUNNER_OS') == 'macOS', 'Native execution requires macrunner Actions')
    root.mkdir(parents=True, exist_ok=False)
    artifact, runtime, binding = bind(root / 'binding')
    selected, producer = binding['selected'], binding['producer']
    observer_binary = root / 'observer-executable'
    reuse = binding.get('observerReuse')
    if reuse is not None:
        raw = observer_archive(root / 'binding/original-observer.zip')['scene-pointer-delivery/observer-executable']
        require(hashlib.sha256(raw).hexdigest() == reuse['executableSHA256']
            and observer_macho(raw) == reuse['deployment'], 'Bound observer bytes changed')
        with observer_binary.open('xb') as stream:
            stream.write(raw)
        observer_binary.chmod(0o700)
        write(root / 'observer-reuse.json', reuse)
    else:
        with (root / 'observer-compile.log').open('xb') as stream:
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                'scripts/scene_pointer_observer.swift', '-o', str(observer_binary)], stdin=subprocess.DEVNULL,
                stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=90)
    current_environment = {'sourceSHA': selected['sourceSHA'],
        'os': subprocess.check_output(['sw_vers'], text=True, timeout=10),
        'architecture': subprocess.check_output(['uname', '-m'], text=True, timeout=10).strip(),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True, timeout=30),
        'observerSourceSHA256': sha(Path('scripts/scene_pointer_observer.swift')),
        'observerExecutable': str(observer_binary),
        'observerExecutableSHA256': sha(observer_binary), 'appBuilds': 0, 'nativeUnitRuns': 0,
        'observerCompiles': 0 if reuse is not None else 1}
    if reuse is not None:
        require(all(current_environment[key] == reuse['compileEnvironment'][key] for key in ('os', 'architecture', 'xcode')),
            'Observer native environment changed')
    write(root / 'environment.json', current_environment)
    check_observer_geometry(root, observer_binary, current_environment)
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
            capture_started = time.time()
            try:
                supervisor_error = supervise_with_open_capture(binary, native, selected['sourceSHA'])
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
            write(root / 'open-capture-proof.json', verify_open_capture(native, observed, binary,
                selected['sourceSHA'], capture_started, time.time()))
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
