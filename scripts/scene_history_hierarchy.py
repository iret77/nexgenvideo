import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import signal
import stat
import struct
import subprocess
import sys
import time
import zipfile
import zlib

MODE = 'native-scene-history-hierarchy'
PATHS = {
    '.github/workflows/diagnostic-acceptance.yml',
    '.github/workflows/scene-history-hierarchy-diagnostic.yml',
    'scripts/scene_history_hierarchy.py', 'scripts/scene_history_ax_observer.swift',
    'scripts/test_scene_history_hierarchy.py', 'scripts/verify_diagnostic_candidate.py',
}
FAILURE_PREFIX = 'Native visual sources: actual enabled button Undo;'
TOLERANCE = 0.5


def require(value, message):
    if not value:
        raise ValueError(message)


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def write(path, value):
    with path.open('xb') as stream:
        stream.write(encoded(value))


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def api(path):
    route = 'repos/iret77/nexgenvideo/' + path
    return json.loads(subprocess.check_output(['gh', 'api', '-H', 'Cache-Control: no-cache',
        route + ('&' if '?' in route else '?') + 'fresh=' + str(time.time_ns())],
        stdin=subprocess.DEVNULL, timeout=40))


def validate_inputs(env):
    require(env.get('KIND', env.get('REPLAY_KIND')) == MODE, 'Wrong History diagnostic mode')
    fields = {'runID': ('PRODUCER_RUN', r'[1-9][0-9]*'), 'sourceSHA': ('PRODUCER_SHA', r'[a-f0-9]{40}'),
        'artifactID': ('DIAGNOSTIC_ID', r'[1-9][0-9]*'), 'artifactSHA256': ('DIAGNOSTIC_DIGEST', r'[a-f0-9]{64}'),
        'failureArtifactID': ('FAILURE_ID', r'[1-9][0-9]*'), 'failureArtifactSHA256': ('FAILURE_DIGEST', r'[a-f0-9]{64}'),
        'dmgSHA256': ('DMG_DIGEST', r'[a-f0-9]{64}'), 'verifiedPRRunID': ('VERIFIED_PR', r'[1-9][0-9]*')}
    result = {}
    for name, (key, pattern) in fields.items():
        value = env.get(key, '')
        require(isinstance(value, str) and re.fullmatch(pattern, value), 'Missing or invalid ' + key)
        result[name] = int(value) if name.endswith('ID') else value
    require(env.get('SCALE') == '1', 'History measurement requires the original standard scale')
    unrelated = ['PRODUCT_SHA', 'PRODUCTS_ID', 'PRODUCTS_DIGEST', 'RUNTIME_FAILURE_BINDING',
        'JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'PACKAGING_PRODUCER_SOURCE',
        'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256']
    require(not any(env.get(key) for key in unrelated), 'Unrelated acceptance inputs cannot be ignored')
    return result


def verify_failure(run, jobs, artifact, selected):
    source, run_id = selected['sourceSHA'], selected['runID']
    require(run.get('id') == run_id and run.get('head_sha') == source
        and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and run.get('path') == '.github/workflows/release.yml' and run.get('event') == 'workflow_dispatch'
        and run.get('actor', {}).get('login') == 'iret77' and run.get('run_attempt') == 1
        and run.get('status') == 'completed' and run.get('conclusion') == 'failure', 'Original failed release differs')
    require(jobs.get('total_count') == len(jobs.get('jobs', [])) <= 100, 'Incomplete original job inventory')
    matches = [j for j in jobs['jobs'] if j.get('name') == 'bpy-runtime / runtime']
    require(len(matches) == 1, 'Ambiguous original Bpy job')
    job = matches[0]
    require(job.get('run_id') == run_id and job.get('head_sha') == source and job.get('run_attempt') == 1
        and job.get('labels') == ['macrunner'] and job.get('status') == 'completed'
        and job.get('conclusion') == 'failure', 'Original Bpy failure identity differs')
    failures = [s for s in job.get('steps', []) if s.get('conclusion') == 'failure']
    require(len(failures) == 1 and failures[0]['name'] == 'Run real bpy acceptance without ambient Blender or Python',
        'Original failed step differs')
    require(artifact.get('id') == selected['failureArtifactID']
        and artifact.get('name') == 'managed-bpy-runtime-evidence-' + source and artifact.get('expired') is False
        and artifact.get('workflow_run', {}).get('id') == run_id
        and artifact.get('workflow_run', {}).get('head_sha') == source
        and artifact.get('digest') == 'sha256:' + selected['failureArtifactSHA256']
        and type(artifact.get('size_in_bytes')) is int and 0 < artifact['size_in_bytes'] <= 64 * 1024 * 1024,
        'Original failed artifact differs')
    instant = lambda value: datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(instant(job['started_at']) <= instant(artifact['created_at']) <= instant(artifact['updated_at'])
        <= instant(job['completed_at']) and instant(artifact['expires_at']) > datetime.now(timezone.utc),
        'Original failed artifact timestamps differ')
    return job


def download(artifact, target, maximum):
    require(0 < artifact['size_in_bytes'] <= maximum, 'Artifact byte bound exceeded')
    with target.open('xb') as stream:
        subprocess.run(['gh', 'api', 'repos/iret77/nexgenvideo/actions/artifacts/' + str(artifact['id']) + '/zip',
            '--allow-escape-sequences'],
            stdin=subprocess.DEVNULL, stdout=stream, check=True, timeout=180)
    require(target.stat().st_size == artifact['size_in_bytes'] and 'sha256:' + sha(target) == artifact['digest'],
        'Downloaded artifact bytes differ')


def download_job_log(job_id, target):
    require(type(job_id) is int and job_id > 0, 'Invalid original job identity')
    with target.open('xb') as stream:
        subprocess.run(['gh', 'api', f'repos/iret77/nexgenvideo/actions/jobs/{job_id}/logs',
            '--allow-escape-sequences'], stdin=subprocess.DEVNULL, stdout=stream, check=True, timeout=120)
    require(target.stat().st_size > 0, 'Original job log is empty')
    return sha(target)


def read_archive(path):
    result = {}
    with zipfile.ZipFile(path) as archive:
        require(len(archive.infolist()) <= 8192, 'Archive member budget exceeded')
        require(sum(i.file_size for i in archive.infolist()) <= 512 * 1024 * 1024, 'Archive expansion budget exceeded')
        for item in archive.infolist():
            name = item.filename
            require(not item.is_dir() and not item.flag_bits & 1 and name not in result
                and not PurePosixPath(name).is_absolute() and '..' not in PurePosixPath(name).parts,
                'Unsafe or duplicate artifact member')
            result[name] = archive.read(item)
    return result


def project_closure(files, outcome):
    record = json.loads(files['spatial-history-project-files.json'])
    require(record.get('schema') == 'nexgenvideo/spatial-history-project/1'
        and record.get('project') == 'spatial-history-project.ngv' and record.get('outcome') == outcome,
        'Canonical History project evidence differs')
    entries = record['files']
    require(isinstance(entries, list) and len(entries) >= 30 and len({e['path'] for e in entries}) == len(entries),
        'Incomplete or duplicate canonical project closure')
    prefix = record['project'] + '/'
    require({name for name in files if name.startswith(prefix)} == {prefix + e['path'] for e in entries},
        'Canonical project file inventory differs')
    for entry in entries:
        relative = PurePosixPath(entry['path'])
        require(not relative.is_absolute() and '..' not in relative.parts, 'Unsafe project-relative path')
        raw = files[prefix + entry['path']]
        require(len(raw) == entry['bytes'] and hashlib.sha256(raw).hexdigest() == entry['sha256'],
            'Canonical project bytes differ')
    return record


def png_size(raw):
    require(raw.startswith(b'\x89PNG\r\n\x1a\n'), 'Invalid screenshot signature')
    offset, chunks, payload, dimensions = 8, [], bytearray(), None
    while offset < len(raw):
        require(offset + 12 <= len(raw), 'Truncated screenshot chunk')
        length = struct.unpack('>I', raw[offset:offset + 4])[0]
        kind = raw[offset + 4:offset + 8]
        require(length <= 64 * 1024 * 1024 and offset + 12 + length <= len(raw), 'Oversized or truncated PNG')
        data = raw[offset + 8:offset + 8 + length]
        require(zlib.crc32(kind + data) & 0xffffffff == struct.unpack('>I', raw[offset + 8 + length:offset + 12 + length])[0],
            'Screenshot CRC differs')
        chunks.append(kind)
        if kind == b'IHDR':
            require(chunks == [b'IHDR'] and length == 13, 'Invalid screenshot header')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', data)
            require(320 <= width <= 8192 and 240 <= height <= 8192 and depth == 8 and color in (2, 6)
                and compression == filtering == interlace == 0, 'Unsupported or incomplete screenshot geometry')
            dimensions = (width, height, 3 if color == 2 else 4)
        if kind == b'IDAT':
            payload.extend(data)
        offset += 12 + length
        if kind == b'IEND':
            require(length == 0 and offset == len(raw), 'Trailing or invalid screenshot bytes')
            break
    require(dimensions is not None and chunks[-1] == b'IEND' and payload, 'Incomplete screenshot')
    width, height, channels = dimensions
    expected = (1 + width * channels) * height
    require(expected <= 64 * 1024 * 1024, 'Screenshot pixel budget exceeded')
    decoder = zlib.decompressobj()
    pixels = decoder.decompress(payload, expected + 1)
    require(decoder.eof and not decoder.unused_data and not decoder.unconsumed_tail and len(pixels) == expected
        and all(pixels[y * (1 + width * channels)] <= 4 for y in range(height)), 'Incomplete screenshot pixel stream')
    return [width, height]


def canonical_history(files, count):
    prefix = 'spatial-history-project.ngv/pipeline/production_design/spatial/'
    index = json.loads(files[prefix + 'index.v1.json'])
    require(index.get('schema') == 'spatial-scene-index/v1' and len(index.get('scenes', [])) == 1,
        'History index must retain exactly the actual scene')
    head = index['scenes'][0]
    scene_prefix = prefix + 'scenes/' + head['id'] + '/revisions/'
    paths = [name for name in files if name.startswith(scene_prefix) and name.endswith('/manifest.v1.json')]
    require(len(paths) == count, 'Canonical History revision count differs')
    revisions = {}
    for path in paths:
        manifest = json.loads(files[path])
        require(manifest.get('schema') == 'spatial-scene-manifest/v1' and manifest.get('sceneID') == head['id']
            and path == scene_prefix + manifest['revision'] + '/manifest.v1.json'
            and manifest['revision'] not in revisions, 'Canonical scene/revision identity differs')
        directory = str(PurePosixPath(path).parent) + '/'
        for name, key in [('scene.blend', 'sceneSHA256'), ('snapshot.v1.json', 'snapshotSHA256')]:
            require(hashlib.sha256(files[directory + name]).hexdigest() == manifest[key]
                == manifest['receipt'][key], 'Actual canonical scene/snapshot bytes differ')
        require(manifest.get('resources') == [] and manifest['resourceClosureSHA256']
            == manifest['receipt']['resourceClosureSHA256'] == hashlib.sha256(b'[]').hexdigest(),
            'Unexpected History fixture resource closure')
        revisions[manifest['revision']] = {'manifest': manifest, 'snapshot': json.loads(files[directory + 'snapshot.v1.json'])}
    require(head['revision'] in revisions and head['manifestSHA256'] == hashlib.sha256(
        files[scene_prefix + head['revision'] + '/manifest.v1.json']).hexdigest(), 'Canonical head manifest differs')
    ordered, current = [], head['revision']
    while current is not None:
        require(current in revisions and current not in {r['manifest']['revision'] for r in ordered},
            'Broken or cyclic canonical History parent chain')
        ordered.append(revisions[current]); current = revisions[current]['manifest'].get('parentRevision')
    require(len(ordered) == count, 'Unlinked canonical History revisions')
    ordered.reverse()
    snapshots = [r['snapshot']['objects'] for r in ordered]
    require(snapshots[0] == [] and len(snapshots[1]) == len(snapshots[2]) == 1
        and snapshots[1][0]['id'] == snapshots[2][0]['id']
        and snapshots[1][0]['matrixWorld'] != snapshots[2][0]['matrixWorld'], 'Initial real cube/edit states differ')
    if count == 3:
        require(all(r['manifest'].get('restoredFromRevision') is None for r in ordered), 'Unexpected prior restore')
    else:
        require(count == 9, 'Unexpected scoped History completion inventory')
        for target, original in [(3, 1), (4, 2), (5, 3), (6, 4), (7, 5)]:
            restored, previous = ordered[target]['manifest'], ordered[original]['manifest']
            require(restored.get('restoredFromRevision') == previous['revision']
                and all(restored[key] == previous[key] for key in ('sceneSHA256', 'snapshotSHA256', 'resourceClosureSHA256')),
                'Restoration did not retain the exact original scene/snapshot/resource bytes')
        require(ordered[8]['manifest'].get('restoredFromRevision') is None and len(snapshots[8]) == 2
            and next((v for v in snapshots[8] if v['id'] == snapshots[1][0]['id']), None) == snapshots[1][0],
            'The final real edit did not retain the restored cube and invalidate Redo')
    return ordered


def expected_locator_failure(files, source, pid):
    process = json.loads(files['process.json'])
    observation = json.loads(files['runtime-failure-observation.json'])
    progress = json.loads(files['spatial-history-admission.json'])
    failure = json.loads(files['spatial-history-failure.json'])
    require(process == {'pid': pid, 'sourceSHA': source, 'mode': 'runtime'}, 'Scoped process identity differs')
    require(observation.get('sourceSHA') == source and observation.get('hostPID') == pid,
        'Failure observation source or PID differs')
    error = progress.get('failure')
    require(isinstance(error, str) and error.startswith(FAILURE_PREFIX)
        and observation.get('error') == failure.get('error') == error
        and progress.get('schema') == 'native-visual-source-progress/v1'
        and progress.get('stage') == 'actual history callback failure'
        and failure.get('busyAfterCleanup') is False, 'The actual failure is outside the recorded locator boundary')
    interactions = progress['interactions']
    require(not any(e.get('kind') == 'pointer' for e in interactions), 'A real pointer was delivered; not the same boundary')
    buttons = [e for e in interactions if e.get('kind') == 'button-accessibility']
    callbacks = [e['evidence'] for e in interactions if e.get('label') == 'actual history callback failure']
    require(len(buttons) == len(callbacks) == 1, 'Missing or ambiguous locator evidence')
    button, callback = buttons[0], callbacks[0]
    require(button.get('id') == 'spatial.undo' and button.get('item') == 'Undo'
        and button.get('elements') == [] and button.get('visited') == 1
        and button.get('truncated') is False and type(button.get('window')) is int and button['window'] > 0,
        'The current locator failure differs')
    require(callback.get('admissionCallbacks') == 0 and callback.get('admitted') is None
        and callback.get('reloadAttemptUptime') is None and callback.get('admissionFailure') is None
        and callback.get('busyBeforeReload') is False and callback.get('busyAfterReload') is False,
        'A real history admission occurred')
    trace = failure.get('historyTrace', {})
    require(trace.get('overflow') is False and [e.get('status') for e in trace.get('events', [])]
        == ['rejectedHistory', 'rejectedBusy'], 'History trace no longer matches the two negative prechecks')
    for name in progress['screenshots']:
        require(name in files, 'Missing actual native screenshot')
        png_size(files[name])
    require(len(progress['screenshots']) >= 2, 'Incomplete failure screenshots')
    project_closure(files, 'failed')
    canonical_history(files, 3)
    return {'expectedLocatorFailure': True, 'windowNumber': button['window'], 'appScopePassed': False}


def scoped_success(files, source, pid):
    require(not any(name in files for name in ('process-failure.json', 'spatial-history-failure.json',
        'runtime-failure-observation.json')), 'Success cannot retain a native failure report')
    value = json.loads(files['result.json'])
    process = json.loads(files['process-result.json'])
    require(process == {'pid': pid, 'sourceSHA': source, 'mode': 'runtime', 'returncode': 0}, 'Scoped exit differs')
    require(value.get('schema') == 'nexgenvideo/scene-history-runtime/1' and value.get('scope') == 'scene-history'
        and value.get('sourceSHA') == source and value.get('operationShutdown') is True
        and value.get('appDelegateShutdown') is True and b'SELFTEST_BPY_HISTORY_OK\n' in files['runtime.log'],
        'Scene-history completion or shutdown evidence is missing')
    history = value['historyAdmission']
    events = history['interactions']
    pointers = [e for e in events if e.get('kind') == 'pointer']
    require([e.get('id') for e in pointers] == ['spatial.undo', 'spatial.redo']
        and all(e.get('localMonitorDownObserved') is True and e.get('localMonitorUpObserved') is True for e in pointers),
        'Both genuine History pointer paths are required')
    callbacks = [e['evidence'] for e in events if e.get('label') == 'actual history callback reload order']
    require([e.get('action') for e in callbacks] == ['undo', 'redo'], 'Both actual admission callbacks are required')
    for item in callbacks:
        admitted, committed, rejected = item['admitted'], item['completed'], item['concurrentRejection']
        require(item.get('admissionCallbacks') == 1 and item.get('admissionFailure') is None
            and item.get('busyBeforeReload') is True and item.get('busyAfterReload') is True
            and item.get('errorAfterRejection') is None and admitted['status'] == 'admitted'
            and admitted['origin'] == 'userInterface' and admitted['busyAtRequest'] is False
            and committed['id'] == admitted['id'] and committed['status'] == 'committed'
            and admitted['action'] == committed['action'] == item['action']
            and admitted['sourceRevision'] == committed['sourceRevision'] == item['expectedSourceRevision']
            and admitted['priorRevision'] == committed['priorRevision'] == item['expectedPriorRevision']
            and rejected['status'] == 'rejectedBusy' and rejected['busyAtRequest'] is True
            and item['observerCreatedUptime'] <= admitted['observedUptime'] <= item['reloadAttemptUptime'],
            'Genuine admission, reload exclusion or committed intent differs')
    complete = [e['evidence'] for e in events if e.get('label') == 'history admission regression complete']
    require(len(complete) == 1, 'Missing final History regression evidence')
    record = complete[0]
    for key in ['emptyRejected', 'busyReloadRejectedWithRetryNotice', 'invalidatedRedoRejectedWithoutRetryInstruction',
                'cancelledBeforeWork', 'awaitedCompletionVerified']:
        require(record.get(key) is True, 'Missing History negative or completion guard: ' + key)
    require(record['historyTrace'].get('overflow') is False, 'History trace overflow')
    trace = record['historyTrace'].get('events', [])
    require(Counter(e.get('status') for e in trace) == Counter(
        rejectedHistory=1, rejectedBusy=4, admitted=6, committed=5, failed=1), 'Incomplete real History intent lifecycle')
    for callback in callbacks:
        identifier = callback['admitted']['id']
        actual = [e for e in trace if e.get('id') == identifier]
        require([e.get('status') for e in actual] == ['admitted', 'committed']
            and all(e.get('action') == callback['action'] and e.get('sourceRevision') == callback['expectedSourceRevision']
                and e.get('priorRevision') == callback['expectedPriorRevision'] for e in actual),
            'The actual clicked History intent lost or duplicated its lifecycle')
    project_closure(files, 'completed')
    canonical = canonical_history(files, 9)
    require(record['sceneID'] == canonical[0]['manifest']['sceneID']
        and [record[key] for key in ('priorRevision', 'editedRevision', 'undoRevision', 'redoRevision')]
        == [canonical[i]['manifest']['revision'] for i in (1, 2, 3, 4)], 'History completion and actual canonical revisions differ')
    project = history.get('canonicalProject', {})
    require(project.get('project') == 'spatial-history-project.ngv'
        and project.get('manifest') == 'spatial-history-project-files.json'
        and project.get('sha256') == hashlib.sha256(files['spatial-history-project-files.json']).hexdigest(),
        'Native scope and exact retained project receipt differ')
    for name in history.get('screenshots', []):
        png_size(files[name])
    require(len(history.get('screenshots', [])) >= 3, 'Missing actual restored History screenshots')
    windows = {e['window'] for e in pointers}
    require(len(windows) == 1, 'History pointer windows differ')
    return {'expectedLocatorFailure': False, 'windowNumber': windows.pop(), 'appScopePassed': True}


def verifier(*args, **kwargs):
    from verify_diagnostic_candidate import verify_scene_history_hierarchy
    verify_scene_history_hierarchy(*args, **kwargs)


def validate_changed_paths(lines):
    for line in lines:
        fields = line.split('\t')
        require(len(fields) == 2 and fields[0] in {'A', 'M'} and fields[1] in PATHS,
            'Renames, deletions or unrelated changed inputs are forbidden')


def bind(root):
    selected = validate_inputs(os.environ)
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
        and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Require original authorized Actions execution')
    root.mkdir(parents=True, exist_ok=False)
    from verified_pr_source_checks import prepare
    prepare(selected['verifiedPRRunID'], root / 'current-source-proof')
    from retained_release_runtime import bind as bind_runtime
    artifact, runtime = bind_runtime(selected['runID'], selected['sourceSHA'], selected['artifactID'],
        selected['artifactSHA256'], verifier=verifier)
    changed = subprocess.check_output(['git', 'diff', '--no-renames', '--name-status',
        selected['sourceSHA'], 'HEAD'], text=True).splitlines()
    validate_changed_paths(changed)
    run = api('actions/runs/' + str(selected['runID']))
    jobs = api(f'actions/runs/{selected["runID"]}/attempts/1/jobs?per_page=100')
    failure = api('actions/artifacts/' + str(selected['failureArtifactID']))
    job = verify_failure(run, jobs, failure, selected)
    download(failure, root / 'original-failure.zip', 64 * 1024 * 1024)
    files = read_archive(root / 'original-failure.zip')
    original_process = json.loads(files['process.json'])
    boundary = expected_locator_failure(files, selected['sourceSHA'], original_process['pid'])
    inventory = api(f'actions/runs/{selected["runID"]}/artifacts?per_page=100')
    require(inventory['total_count'] == len(inventory['artifacts']) <= 100, 'Incomplete producer artifact inventory')
    producers = [a for a in inventory['artifacts'] if a['name'] == 'release-workspace-producer']
    require(len(producers) == 1 and producers[0].get('expired') is False
        and producers[0]['workflow_run']['id'] == selected['runID']
        and producers[0]['workflow_run']['head_sha'] == selected['sourceSHA'], 'Final producer artifact differs')
    download(producers[0], root / 'original-producer.zip', 1024 * 1024)
    producer_files = read_archive(root / 'original-producer.zip')
    require(set(producer_files) == {'release-workspace-producer.json'}, 'Producer archive inventory differs')
    producer = json.loads(producer_files['release-workspace-producer.json'])
    require(producer.get('schema') == 'nexgenvideo/release-workspace-producer/1'
        and producer.get('sourceSHA') == selected['sourceSHA'] and producer.get('runID') == str(selected['runID'])
        and producer.get('runAttempt') == '1' and producer.get('dmgSHA256') == selected['dmgSHA256']
        and producer['app']['NGVSourceCommit'] == selected['sourceSHA']
        and producer['app']['treeSHA256'] == producer['mountedAppTreeSHA256'], 'Final product byte identity differs')
    raw_digest = download_job_log(job['id'], root / 'original-failure-job.log')
    proof = {'schema': 'nexgenvideo/scene-history-hierarchy-binding/1', 'selected': selected,
        'runtimeArtifact': artifact, 'runtimeProof': runtime, 'producer': producer,
        'originalFailureJob': job, 'originalFailureArtifact': failure, 'originalBoundary': boundary,
        'originalRawSHA256': raw_digest,
        'sourceFiles': {name: sha(Path(name)) for name in sorted(PATHS)},
        'harnessSourceSHA': os.environ['GITHUB_SHA'], 'executionRunID': os.environ['GITHUB_RUN_ID']}
    write(root / 'binding.json', proof)
    return artifact, runtime, proof


def tree_digest(root):
    root = root.resolve(strict=True)
    rows = []
    for path in sorted(root.rglob('*'), key=lambda p: PurePosixPath(p.relative_to(root).as_posix())):
        relative = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            target = os.readlink(path)
            require(not os.path.isabs(target) and path.resolve(strict=True).is_relative_to(root), 'Escaping bundle symlink')
            content = ['symlink', target]
        elif stat.S_ISDIR(mode):
            content = ['directory']
        else:
            require(stat.S_ISREG(mode), 'Unsupported bundle member')
            content = ['file', sha(path)]
        rows.append([relative, stat.S_IMODE(mode), *content])
    return hashlib.sha256(json.dumps(rows, ensure_ascii=True, separators=(',', ':')).encode()).hexdigest()


def product_bytes(workspace, producer):
    app, pack = workspace / 'NexGenVideo.app', workspace / 'plugins/musicvideo.ngvpack'
    result = {'appTreeSHA256': tree_digest(app), 'packTreeSHA256': tree_digest(pack),
        'executableSHA256': sha(app / 'Contents/MacOS/NexGenVideo')}
    require(result == {'appTreeSHA256': producer['mountedAppTreeSHA256'],
        'packTreeSHA256': producer['packTreeSHA256'], 'executableSHA256': producer['app']['executableSHA256']},
        'Actual retained App or Pack bytes differ from the final DMG producer')
    return result


def finite_rectangle(position, size):
    require(type(position) is list and type(size) is list and len(position) == len(size) == 2
        and all(type(v) in (int, float) and math.isfinite(v) for v in position + size)
        and min(size) > 0, 'Invalid public AX window geometry')
    return position + size


def associate_window(tree, cg_windows, pid):
    require(tree.get('truncated') is False and 0 < tree.get('visited', 0) <= 2048
        and tree.get('localSwiftObjectTypesObserved') is False, 'Incomplete or incorrectly classified AX traversal')
    nodes = tree['nodes']
    require(len(nodes) == tree['visited'] and len({n['identity'] for n in nodes}) == len(nodes)
        and all(n.get('pid') == pid and n.get('pidStatus') == 0 and n.get('unsupportedChildrenCount') == 0 for n in nodes),
        'Foreign, duplicate or unsupported AX nodes')
    headers = [n for n in nodes if n['attributes'].get('AXRole') == 'AXStaticText'
        and 'History admission control' in [n['attributes'].get(key) for key in ('AXTitle', 'AXDescription', 'AXValue')]]
    undo = [n for n in nodes if n['attributes'].get('AXRole') == 'AXButton'
        and 'Undo' in [n['attributes'].get(key) for key in ('AXTitle', 'AXDescription')]
        and n['attributes'].get('AXEnabled') is True]
    require(len(headers) == len(undo) == 1, 'No unique actual History header and enabled Undo button')
    root = nodes[0]
    require(root['identity'] == tree['windowIdentity'] and root['attributes'].get('AXRole') == 'AXWindow',
        'The AX root is not the selected native window')
    for node in [root, undo[0]]:
        require(all(node['statuses'].get(k) == 0 for k in ('AXRole', 'AXPosition', 'AXSize')),
            'Required AX geometry query failed')
    require(undo[0]['statuses'].get('AXEnabled') == 0, 'The actual enabled-state query failed')
    frame = finite_rectangle(root['attributes']['AXPosition'], root['attributes']['AXSize'])
    button = finite_rectangle(undo[0]['attributes']['AXPosition'], undo[0]['attributes']['AXSize'])
    require(frame[0] <= button[0] and frame[1] <= button[1]
        and button[0] + button[2] <= frame[0] + frame[2]
        and button[1] + button[3] <= frame[1] + frame[3], 'Undo is outside its actual AX window')
    matches = []
    for window in cg_windows:
        if window.get('kCGWindowOwnerPID') != pid or window.get('kCGWindowIsOnscreen') is not True:
            continue
        bounds = window.get('kCGWindowBounds', {})
        values = [bounds.get(k) for k in ('X', 'Y', 'Width', 'Height')]
        if (all(type(v) in (int, float) and math.isfinite(v) for v in values)
                and all(abs(a - b) <= TOLERANCE for a, b in zip(frame, values))):
            matches.append(window)
    require(len(matches) == 1 and type(matches[0].get('kCGWindowNumber')) is int,
        'Missing or ambiguous public AX-to-CG window association')
    return {'windowNumber': matches[0]['kCGWindowNumber'], 'windowFrame': frame, 'undoFrame': button,
        'geometryTolerance': TOLERANCE, 'AXIdentity': tree['windowIdentity']}


def verify_observer(output, source, pid, binary, window_number, observer_pid):
    attachment = json.loads((output / 'attachment.json').read_text())
    completion = json.loads((output / 'observer-completion.json').read_text())
    require(attachment.get('schema') == 'nexgenvideo/scene-history-ax-attachment/1'
        and attachment.get('sourceSHA') == source and attachment.get('AXTrusted') is True
        and attachment.get('geometryTolerance') == TOLERANCE
        and attachment.get('externalQueriesMayInitializeAccessibility') is True
        and attachment.get('localSwiftObjectTypesObserved') is False, 'Observer attachment boundary differs')
    require(attachment.get('observerPID') == observer_pid and observer_pid != pid
        and attachment.get('observerParentPID') == os.getpid(), 'The AX reader is not this owned observer process')
    identity = attachment['processIdentity']
    require(identity.get('pid') == pid and type(identity.get('startAbsoluteTime')) is int
        and identity['startAbsoluteTime'] > 0 and identity.get('executable') == str(binary.resolve(strict=True)),
        'Observer process PID/start/path identity differs')
    require(completion.get('schema') == 'nexgenvideo/scene-history-ax-completion/1'
        and completion.get('sourceSHA') == source and completion.get('processIdentity') == identity
        and completion.get('boundedQueries') is True and completion.get('readOnly') is True,
        'Observer did not complete its bounded read-only scope')
    paths = sorted(output.glob('ax-sample-*.json'))
    require(0 < len(paths) == completion['samples'] <= 720, 'Missing or oversized observer timeline')
    matches, rejected, previous = [], [], attachment['firstQueryUptime']
    for index, path in enumerate(paths):
        sample = json.loads(path.read_text())
        require(sample.get('sample') == index, 'Observer sample sequence differs')
        if sample.get('processAlive') is False:
            continue
        require(sample.get('processAlive') is True and sample.get('processIdentity') == identity
            and previous <= sample['startedUptime'] <= sample['completedUptime'] <= completion['completedUptime'],
            'Observer identity or monotonic sample order differs')
        previous = sample['completedUptime']
        if sample.get('AXWindowsStatus') != 0:
            rejected.append({'sample': index, 'AXWindowsStatus': sample.get('AXWindowsStatus'),
                'reason': 'AX windows unavailable in this sample'})
            continue
        for window in sample['windows']:
            digest = window['treeSHA256']
            require(re.fullmatch('[a-f0-9]{64}', digest), 'Invalid observer tree digest')
            raw = (output / ('ax-tree-' + digest + '.json')).read_bytes()
            require(hashlib.sha256(raw).hexdigest() == digest, 'Observer tree bytes differ')
            tree = json.loads(raw)
            require(tree['windowIdentity'] == window['windowIdentity'], 'Observer tree root differs')
            try:
                match = associate_window(tree, sample['CGWindows'], pid)
            except ValueError as error:
                rejected.append({'sample': index, 'windowIdentity': window['windowIdentity'], 'reason': str(error)})
            else:
                matches.append({'sample': index, **match})
    require(matches and {item['windowNumber'] for item in matches} == {window_number},
        'Observed public window mapping does not uniquely match this actual App interaction window')
    return {'attachment': attachment, 'completion': completion, 'matches': matches, 'rejected': rejected,
        'localNilVersusProtocolDiscardDetermined': False, 'observerCausalityIsolated': False}


def scoped_files(root):
    require(root.is_dir() and not root.is_symlink(), 'Missing scoped native evidence')
    result, total = {}, 0
    for path in root.rglob('*'):
        require(not path.is_symlink(), 'Symlink in scoped evidence')
        if path.is_dir():
            continue
        raw = path.read_bytes()
        total += len(raw)
        require(total <= 256 * 1024 * 1024 and len(result) < 8192, 'Scoped native evidence bound exceeded')
        result[path.relative_to(root).as_posix()] = raw
    return result


def supervise_scope(binary, output, source, supervisor=None):
    if supervisor is None:
        from bpy_runtime_acceptance import supervise
        supervisor = supervise
    try:
        supervisor(binary, output, 'runtime', source, 180)
    except AssertionError as error:
        if str(error) != 'bpy runtime exited with status 1':
            raise
        return str(error)
    return None


def run(root):
    require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('RUNNER_OS') == 'macOS', 'Native execution is only supported in macrunner Actions')
    root.mkdir(parents=True, exist_ok=False)
    artifact, runtime, binding = bind(root / 'binding')
    selected, producer = binding['selected'], binding['producer']
    workspace = root.parent / ('scene-history-workspace-' + os.environ['GITHUB_RUN_ID'])
    from retained_release_runtime import restore
    restore(artifact, runtime, workspace)
    before = product_bytes(workspace, producer)
    write(root / 'actual-app-pack-before.json', before)
    native = root / 'native'
    observed = root / 'observer'
    native.mkdir(); observed.mkdir()
    source = root.parent / ('scene-history-source-' + os.environ['GITHUB_RUN_ID'])
    receipt = workspace.parent / (workspace.name + '-retained-transfer') / 'payload/bpy-source-receipt.json'
    with (root / 'source-bootstrap.log').open('xb') as stream:
        subprocess.run([sys.executable, 'scripts/consume_bpy_distributable_source.py', '--output-directory', str(source),
            '--source-sha', selected['sourceSHA'], '--receipt', str(receipt)],
            stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=480)
    observer_binary = root.parent / ('scene-history-ax-observer-' + os.environ['GITHUB_RUN_ID'])
    with (root / 'observer-compile.log').open('xb') as stream:
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
            'scripts/scene_history_ax_observer.swift', '-o', str(observer_binary)],
            stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=90)
    write(root / 'environment.json', {'sourceSHA': selected['sourceSHA'],
        'os': subprocess.check_output(['sw_vers'], text=True), 'architecture': subprocess.check_output(['uname', '-m'], text=True).strip(),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True),
        'observerSourceSHA256': sha(Path('scripts/scene_history_ax_observer.swift')),
        'observerExecutableSHA256': sha(observer_binary), 'appBuilds': 0, 'nativeUnitRuns': 0})
    fake = root.parent / ('scene-history-no-ambient-' + os.environ['GITHUB_RUN_ID'])
    fake.mkdir()
    for name in ('python3', 'blender'):
        path = fake / name; path.write_text('#!/bin/sh\nexit 99\n'); path.chmod(0o700)
    app_binary = workspace / 'NexGenVideo.app/Contents/MacOS/NexGenVideo'
    done = root / 'app-supervision-complete.json'
    old_environment = dict(os.environ)
    for key in list(os.environ):
        if key.startswith(('NGV_SELFTEST', 'NGV_ACCEPTANCE', 'NGV_BPY_')):
            os.environ.pop(key)
    os.environ.update(NGV_SELFTEST_BPY=str(native), NGV_SELFTEST_BPY_SCOPE='scene-history', PATH=str(fake),
        PYTHONPATH=str(fake / 'unavailable'), BLENDER_USER_CONFIG=str(fake / 'foreign-config'))
    observer = None
    supervisor_error = None
    cleanup_error = None
    pid = None
    result = None
    def interrupted(number, _frame):
        raise InterruptedError('Owned History measurement interrupted: ' + str(number))
    previous_handlers = {number: signal.signal(number, interrupted) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        with (root / 'observer.log').open('xb') as log:
            observer = subprocess.Popen([str(observer_binary), str(native / 'process.json'), str(app_binary),
                selected['sourceSHA'], str(observed), str(done)], stdin=subprocess.DEVNULL, stdout=log,
                stderr=subprocess.STDOUT, env=old_environment)
            try:
                supervisor_error = supervise_scope(app_binary, native, selected['sourceSHA'])
            finally:
                if (native / 'process.json').is_file():
                    process = json.loads((native / 'process.json').read_text())
                    pid = process['pid']
                    write(done, {'pid': pid, 'sourceSHA': selected['sourceSHA'], 'supervisorError': supervisor_error})
                if observer.poll() is None:
                    try:
                        observer.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        observer.terminate()
                        try:
                            observer.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            observer.kill(); observer.wait(timeout=3)
                        cleanup_error = 'The owned AX observer did not finish after App supervision'
                require(observer.returncode == 0 and cleanup_error is None, 'Read-only AX observer failed or needed forced cleanup')
        files = scoped_files(native)
        require(pid is not None, 'No actual supervised App PID')
        if supervisor_error is None:
            outcome = scoped_success(files, selected['sourceSHA'], pid)
        else:
            failure = json.loads(files['process-failure.json'])
            require(failure == {'pid': pid, 'error': supervisor_error}, 'Supervised exit1 evidence differs')
            outcome = expected_locator_failure(files, selected['sourceSHA'], pid)
        observation = verify_observer(observed, selected['sourceSHA'], pid, app_binary, outcome['windowNumber'], observer.pid)
        result = {'schema': 'nexgenvideo/scene-history-hierarchy-measurement/1', 'productSourceSHA': selected['sourceSHA'],
            'harnessSourceSHA': binding['harnessSourceSHA'], 'runtimeProducerRunID': selected['runID'],
            'dmgSHA256': selected['dmgSHA256'], 'appTreeSHA256': before['appTreeSHA256'],
            'appPID': pid, 'measurementComplete': True, **outcome, 'fullBpyPassed': False,
            'originalSceneUIPassed': False, 'overallAcceptancePassed': False, 'supervisorError': supervisor_error,
            'observer': observation, 'appBuilds': 0, 'nativeUnitRuns': 0,
            'scope': 'scene-history', 'publicationAuthorised': False}
    finally:
        os.environ.clear(); os.environ.update(old_environment)
        for number, handler in previous_handlers.items():
            signal.signal(number, handler)
        if observer is not None and observer.poll() is None:
            observer.kill(); observer.wait(timeout=5)
        app_gone = False
        if pid is not None:
            from bpy_runtime_acceptance import WorkerReader
            live = WorkerReader().identity(pid)
            attachment_path = observed / 'attachment.json'
            original = json.loads(attachment_path.read_text())['processIdentity'] if attachment_path.is_file() else None
            app_gone = live is None or (original is not None and live['start'] != original['startAbsoluteTime'])
            require(app_gone, 'The exact owned App process remains alive after supervision')
        after = product_bytes(workspace, producer)
        write(root / 'actual-app-pack-after.json', after)
        write(root / 'cleanup.json', {'sourceSHA': selected['sourceSHA'], 'appPID': pid,
            'observerPID': observer.pid if observer is not None else None,
            'observerExitCode': observer.returncode if observer is not None else None,
            'observerReaped': observer is None or observer.returncode is not None, 'error': cleanup_error,
            'ownedAppGone': app_gone, 'beforeAfterAppPackExact': before == after})
    require(result is not None and app_gone and before == after, 'Missing complete measurement or cleanup evidence')
    write(root / 'measurement.json', result)


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=('bind', 'run'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    (run if args.action == 'run' else bind)(args.output.resolve())


if __name__ == '__main__':
    main()
