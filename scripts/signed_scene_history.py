"""Verify ordinary scene edits and document shutdown on the qualified internal disk image."""

from fractions import Fraction
from functools import lru_cache
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import zipfile
import uuid

import yaml

from isolated_test_home import environment
from retained_app_test_products import api, checksum, command, download, require, verify_artifact, write
from scene_history_hierarchy import scoped_files, scoped_success
from production_spatial_ui_evidence import validate_cases
from spatial_evaluated_geometry_evidence import verify as verify_geometry
from release_checkpoint import internal_image_evidence
from verified_pr_source_checks import prepare

sys.path.insert(0, str(Path(__file__).resolve().parent / 'external-gui'))
from acceptance import metadata, tree_sha256


BASE = 'iret77/rc-delivery-base-795'
INSTALLED = Path('/Applications/NexGenVideo.app')


def validate_dispatch(inputs):
    required = {'candidate_kind', 'run_id', 'source_sha', 'artifact_id', 'artifact_sha256',
                'expected_dmg_sha256', 'verified_pr_run_id'}
    neutral = {'interface_scale': '1', 'journey_scenario': 'journey'}
    require(required <= inputs.keys() and inputs['candidate_kind'] in ('signed-scene-history', 'signed-scene-editing')
            and re.fullmatch('[0-9a-f]{40}', inputs['source_sha'])
            and all(re.fullmatch('[1-9][0-9]*', inputs[k]) for k in ('run_id', 'artifact_id', 'verified_pr_run_id'))
            and all(re.fullmatch('[0-9a-f]{64}', inputs[k]) for k in ('artifact_sha256', 'expected_dmg_sha256'))
            and all(v == neutral.get(k, '') for k, v in inputs.items() if k not in required),
            'Unsupported selector or incomplete signed scene inputs')


def original_item(run, job, name):
    items = api(f"actions/runs/{run['id']}/artifacts?name={name}&per_page=100")
    require(items['total_count'] == len(items['artifacts']) == 1, 'Artifact missing or ambiguous: ' + name)
    item = api("actions/artifacts/" + str(items['artifacts'][0]['id']))
    verify_artifact(item, run, job, item['id'], item['digest'].removeprefix('sha256:'), name)
    return item


def acquire_image(root, inputs, product):
    producer = int(inputs['run_id'])
    expected = inputs['expected_dmg_sha256']
    run = api(f'actions/runs/{producer}/attempts/1')
    require(run['id'] == producer and run['run_attempt'] == 1 and run['head_sha'] == product
            and run['repository']['full_name'] == 'iret77/nexgenvideo' and run['actor']['login'] == 'iret77'
            and run['path'] == '.github/workflows/release.yml' and run['head_branch'] == BASE
            and run['event'] == 'workflow_dispatch' and run['status'] == 'completed', 'Unknown private image producer')
    inventory = api(f'actions/runs/{producer}/attempts/1/jobs?per_page=100')
    require(inventory['total_count'] == len(inventory['jobs']), 'Incomplete internal producer inventory')
    pending = [j for j in inventory['jobs'] if j['name'] == 'acceptance-pending']
    require(len(pending) == 1 and pending[0]['conclusion'] == 'failure' and pending[0]['run_attempt'] == 1
            and pending[0]['run_id'] == producer and pending[0]['head_sha'] == product, 'Unexpected release gate result')
    mounted = internal_image_evidence(run, inventory, product)
    require(mounted['dmgSHA256'] == expected and mounted['app']['CFBundleVersion'] == '145'
            and mounted['app']['CFBundleShortVersionString'] == '1.8.0', 'The original mounted receipt differs')
    release, = [job for job in inventory['jobs'] if job['name'] == 'release']
    item = original_item(run, release, 'release-user-journey-input')
    require(item['id'] == int(inputs['artifact_id']) and item['digest'] == 'sha256:' + inputs['artifact_sha256']
            and 0 < item['size_in_bytes'] < 8 * 1024**3, 'Unexpected signed journey artifact')
    original = root / 'journey.zip'
    download(item, original)
    dmg = root / 'NexGenVideo.dmg'
    with zipfile.ZipFile(original) as archive:
        members = [x for x in archive.infolist() if x.filename == dmg.name]
        require(len(members) == 1 and 0 < members[0].file_size < 8 * 1024**3, 'Missing or ambiguous disk image')
        with archive.open(members[0]) as src, dmg.open('xb') as out:
            shutil.copyfileobj(src, out, 1024 * 1024)
    require(checksum(dmg) == expected, 'The actual inner image differs')
    return dmg, mounted, item


def validate_timing(proof, stream, frames):
    request = proof['request']
    number = request['endFrame'] - request['startFrame'] + 1
    require(1 < number == len(frames) == int(stream['nb_read_frames'])
            and [frame['frame'] for frame in proof['state']['frames']] == list(range(request['startFrame'], request['endFrame'] + 1)),
            'Decoded frame count or requested frame sequence differs')
    require(stream['width'] == request['width'] and stream['height'] == request['height']
            and stream['codec_name'] == 'h264'
            and all(stream.get(key) == 'bt709' for key in ('color_primaries', 'color_transfer', 'color_space')),
            'Decoded Clay dimensions, codec or color space differ')
    unit = Fraction(stream['time_base'])
    period = Fraction(proof['timebaseDenominator'], proof['timebaseNumerator'])
    duration = Fraction(proof['timing']['numerator'], proof['timing']['denominator'])
    require((number - 1) * period < duration <= number * period and int(stream['start_pts']) == 0
            and int(stream['duration_ts']) * unit == duration
            and all(int(frame['pts']) * unit == index * period for index, frame in enumerate(frames)),
            'Decoded Clay presentation timestamps or shot duration differ')


@lru_cache(maxsize=2)
def sealed_renderer(runtime_root):
    files = {'rendererBinarySHA256': 'site-packages/bpy/__init__.so', 'runtimeLockSHA256': 'runtime-lock.json',
             'rendererScriptSHA256': 'scene_operations.py', 'workerSHA256': 'worker.py'}
    return ({key: checksum(runtime_root / name) for key, name in files.items()},
            json.loads((runtime_root / 'runtime-lock.json').read_bytes())['bpyWheelLayout']['expectedRuntimeBinaryEvidence'])


def verifier_runtime(verified, installed):
    module = Path(verified['bpyModule']).resolve(strict=True)
    services = installed / 'Contents/XPCServices'
    roots = [services / f'NexGenVideoBpyService{slot}.xpc/Contents/Resources/BpyRuntime' for slot in (0, 1)]
    root, = [r for r in roots if module == (r / 'site-packages/bpy/__init__.so').resolve(strict=True)]
    require(Path(verified['executable']).resolve(strict=True).is_relative_to(root.resolve()),
            'Blender executable and module came from different services')
    return root


def verify_saved_render(folder, proof, descriptors, worker_pid, installed):
    file = folder / 'verification.json'
    descriptor = descriptors[file.name]
    require(checksum(file) == descriptor['sha256'] and file.stat().st_size == descriptor['byteCount'],
            'Independent Blender verification file differs from its job descriptor')
    verified = json.loads(file.read_bytes())
    require(verified['jobID'].upper() == proof['jobID'].upper() and verified['fingerprint'] == proof['jobFingerprint']
            and verified['sceneSHA256'] == descriptors['scene.blend']['sha256']
            and type(verified['processIdentifier']) is int and verified['processIdentifier'] > 0
            and verified['processIdentifier'] != worker_pid, 'Independent Blender verifier or saved scene differs')
    root = verifier_runtime(verified, installed)
    hashes, binary = sealed_renderer(root)
    require(all(proof[key] == digest for key, digest in hashes.items())
            and verified['blenderBuildHash'] == proof['blenderBuildHash'] == binary['buildHash']
            and all(verified['libraryVersions'][name]['version'] == version for name, version in binary['libraryVersions'].items()),
            'Loaded Blender runtime differs from its signed binary, sources or libraries')
    scene, = verified['scenes']
    require(scene['engine'] == 'CYCLES' and scene['cyclesDevice'] == 'CPU'
            and (scene['effectiveWidth'], scene['effectiveHeight']) == (proof['request']['width'], proof['request']['height']),
            'Saved scene device or dimensions differ from the finished render')
    return verified['processIdentifier']


def validate_worker_render(observations, proof, installed=INSTALLED):
    job = str(uuid.UUID(proof['jobID'])).upper()
    folder = observations / job
    receipt = json.loads((folder / 'job.json').read_bytes())
    require(receipt['jobID'] == job and receipt['jobFingerprint'] == proof['jobFingerprint']
            and receipt['sourceRevision'] == proof['scene']['revision'], 'Renderer job or source revision differs')
    entries = receipt['outputs']
    descriptors = {entry['name']: entry for entry in entries}
    frames = folder / 'clay-frames.json'
    require(len(entries) == len(descriptors) and checksum(frames) == descriptors[frames.name]['sha256']
            and frames.stat().st_size == descriptors[frames.name]['byteCount'], 'Renderer frame descriptor differs')
    poses = json.loads(frames.read_bytes())
    request = proof['request']
    require([p['frame'] for p in poses] == list(range(request['startFrame'], request['endFrame'] + 1)),
            'Incomplete in-process render observations')
    require([{k: v for k, v in pose.items() if k != 'execution'} for pose in poses] == proof['framePoses'],
            'Job poses do not match the published derivation')
    outputs = {entry['filename']: entry for entry in proof['outputs']}
    pids = set()
    for pose in poses:
        actual = pose['execution']
        frame = pose['frame']
        name = f'clay-{frame:08d}.png'
        require(actual['before'] == actual['after'] == ['CYCLES', 'CPU'] and actual['result'] == 'FINISHED'
                and type(actual['pid']) is int and actual['pid'] > 0 and actual['filename'] == name
                and actual['frame'] == frame and actual['cameraID'] == request['cameraID']
                and descriptors[name]['sha256'] == outputs[name]['sha256']
                and descriptors[name]['byteCount'] == outputs[name]['byteCount'],
                'Renderer settings, finished frame, camera or original PNG descriptor differs')
        pids.add(actual['pid'])
    require(len(pids) == 1, 'One render job reported multiple worker processes')
    pid = pids.pop()
    verifier_pid = verify_saved_render(folder, proof, descriptors, pid, installed)
    return dict(jobID=job, fingerprint=receipt['jobFingerprint'], frames=len(poses), workerPID=pid, verifierPID=verifier_pid)


def validate_assignment(directory, label, state, scene, tools, view=None):
    root = directory / 'spatial-assignments'
    references = json.loads((root / (label + '.json')).read_bytes())
    def original(reference):
        digest = reference['sha256']
        require(re.fullmatch('[a-f0-9]{64}', digest) is not None, 'Invalid spatial reference digest')
        path = root / 'objects' / digest
        require(path.is_file() and not path.is_symlink() and checksum(path) == digest, 'Spatial assignment original differs')
        return path
    for reference in references:
        original(reference)
    def current(name, path, role):
        reference, = [entry for entry in references if (entry['id'], entry['path'], entry['role']) == (name, path, role)]
        return original(reference)
    records = [json.loads(original(ref).read_bytes()) for ref in references if ref['role'] == 'core.spatial-adoption']
    if view is None:
        timing = json.loads(current('assigned-timing', 'storyboard/timing-current.v1.json', 'core.storyboard-timing').read_bytes())
        shot, = [s for s in timing['shots'] if s['id'] == state['shotID']]
        moment, = [m for m in shot['moments'] if m['id'] == state['momentID']]
        asset = moment['asset']
        sketch = json.loads(original(asset['proof']).read_bytes())
        derivation_reference = sketch['source']['spatialDerived']['proof']
        adoption, = [r for r in records if r['schema'] == 'spatial-derivation-adoption/v1' and r['proof'] == derivation_reference]
        source = adoption['ownerArtifact']
        binding = adoption['storyboardBinding']
        require(sketch['schema'] == 'storyboard-sketch-proof/v1' and sketch['shotID'] == binding['shotID'] == shot['id']
                and sketch['momentID'] == binding['momentID'] == moment['id'] and sketch['image'] == asset['image']
                and all(sketch[key] == binding[key] for key in ('intentSHA256', 'framingSHA256'))
                and asset['image'] in adoption['media'].values() and source['role'] == 'core.storyboard-timing'
                and asset['proof']['sha256'] == state['proofSHA256'], 'Storyboard moment does not own the original sketch')
        image = asset['image']
        expected = state['imageSHA256']
        owner = 'storyboard'
    else:
        bible = yaml.safe_load(current('assigned-bible', 'bible/bible.yaml', 'core.assigned-bible').read_bytes())
        adoption, = [r for r in records if r['schema'] == 'spatial-bible-view-adoption/v1' and r['binding']['viewID'] == view]
        binding = adoption['binding']
        location, = [loc for loc in bible['locations'] if loc['id'] == binding['locationID']]
        image = adoption['image']
        source = adoption['sourceBible']
        require(location['sheets'][view] == image['path'] and location['view_purpose'][view] == binding['purpose'],
                'The saved Bible view differs from its assignment')
        expected = state['imageSHA256'] if view == state['viewID'] else state['recoveredImageSHA256']
        owner = 'bible'
    require(all(ref in references for ref in (source, image, adoption['proof'])), 'Assignment original missing from inventory')
    derivation = json.loads(original(adoption['proof']).read_bytes())
    item, = derivation['outputs']
    require(derivation['id'] == adoption['id'] and derivation['request']['owner'] == owner
            and derivation['scene']['id'] == scene['sceneID'] and derivation['request']['cameraID'] == scene['cameraID']
            and derivation['scene']['manifestSHA256'] == adoption['sceneManifest']['sha256'] == scene['manifestSHA256']
            and derivation['request']['ownerArtifactSHA256'] == source['sha256']
            and item['sha256'] == image['sha256'] == expected and item['mediaKind'] == 'image/png'
            and original(image).stat().st_size == item['byteCount'], 'Assigned image differs from the rendered frame')
    stream, = json.loads(command([str(tools / 'ffprobe'), '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=codec_name,width,height', '-of', 'json', str(original(image))], timeout=60))['streams']
    require(stream['codec_name'] == 'png' and all(stream[key] == item[key] == derivation['request'][key]
            for key in ('width', 'height')), 'Assigned image dimensions differ from the requested render')
    return validate_worker_render(directory / 'render-observations', derivation)


def validate_chunks(directory, proof, outputs):
    request = proof['request']
    jobs = []
    chunks = proof['chunks']
    require(len(chunks) == len({c['jobID'] for c in chunks}) == len({c['proofFilename'] for c in chunks}),
            'Repeated render job or chunk evidence')
    next_frame = request['startFrame']
    for chunk in chunks:
        name = chunk['proofFilename']
        require(Path(name).name == name and checksum(directory / name) == chunk['proofSHA256'],
                'Sequence chunk proof differs')
        part = json.loads((directory / name).read_bytes())
        start, end = chunk['startFrame'], chunk['endFrame']
        part_images = {item['filename'] for item in part['outputs'] if item['filename'].endswith('.png')}
        require(start == next_frame and start <= end <= request['endFrame']
                and (part['request']['startFrame'], part['request']['endFrame']) == (start, end)
                and part_images == {f'clay-{number:08d}.png' for number in range(start, end + 1)}
                and part['scene'] == proof['scene'] and part['request']['cameraID'] == request['cameraID'],
                'Render chunk skipped or duplicated requested scene frames')
        next_frame = end + 1
        require(part['jobID'] == chunk['jobID'] and part['jobFingerprint'] == chunk['jobFingerprint']
                and all(outputs[item['filename']]['sha256'] == item['sha256'] for item in part['outputs']
                        if item['filename'].endswith('.png')), 'Sequence PNG and render chunk differ')
        jobs.append(validate_worker_render(directory.parent / 'render-observations', part))
    require(jobs and next_frame == request['endFrame'] + 1 and sum(job['frames'] for job in jobs) == request['endFrame'] - request['startFrame'] + 1, 'Incomplete render job frame count')
    return jobs


def validate_render(directory, state, scene, pose, tools):
    movie = directory / 'clay.mov'
    receipt = directory / 'sequence.v1.json'
    require(checksum(movie) == state['videoSHA256'] and checksum(receipt) == state['proofSHA256'],
            'Saved render or associated production proof differs from native playback')
    proof = json.loads(receipt.read_bytes())
    require(proof.get('schema') == 'spatial-derivation-sequence/v1', 'Unrecognized shot render proof')
    request = proof['request']
    require(request['stateSHA256'] == pose['stateSHA256'] and state['shotID'] == pose['shotID']
            and request['cameraID'] == scene['cameraID'] and proof['scene']['manifestSHA256'] == scene['manifestSHA256'],
            'Shot render differs from the confirmed camera or poses')
    count = request['endFrame'] - request['startFrame'] + 1
    require(1 < count == len(proof['state']['frames']), 'Incomplete shot frame range')
    outputs = {item['filename']: item for item in proof['outputs']}
    images = {f'clay-{frame:08d}.png' for frame in range(request['startFrame'], request['endFrame'] + 1)}
    require(images == {n for n in outputs if n.endswith('.png')} and len(outputs) == len(proof['outputs'])
            and set(outputs) | {receipt.name} == {p.name for p in directory.iterdir()},
            'Original shot output inventory differs')
    for name, item in outputs.items():
        file = directory / name
        require(file.name == name and file.is_file() and not file.is_symlink() and file.stat().st_size == item['byteCount']
                and checksum(file) == item['sha256'], 'Original shot payload differs: ' + name)
    jobs = validate_chunks(directory, proof, outputs)
    shot = outputs['clay.mov']
    require(shot['sha256'] == state['videoSHA256'] and [shot[k] for k in ('width', 'height', 'frameCount')] ==
            [request['width'], request['height'], count], 'Final shot differs from its sequence')
    decoded = json.loads(command([str(tools / 'ffprobe'), '-v', 'error', '-select_streams', 'v', '-count_frames',
        '-show_frames', '-show_streams', '-show_entries', 'stream:frame=pts', '-of', 'json', str(movie)], timeout=120))
    stream, = decoded['streams']
    validate_timing(proof, stream, decoded['frames'])
    subprocess.run([str(tools / 'ffmpeg'), '-nostdin', '-v', 'error', '-xerror', '-i', str(movie),
                    '-map', '0:v:0', '-f', 'null', '-'], stdin=subprocess.DEVNULL, check=True, timeout=120)
    return dict(videoSHA256=state['videoSHA256'], proofSHA256=state['proofSHA256'], jobs=jobs, stream=stream,
                presentationTimestamps=[int(f['pts']) for f in decoded['frames']])


def editing_result(directory, product, pid, installed):
    value = json.loads((directory / 'result.json').read_bytes())
    require(value.get('sourceSHA') == product and value.get('hostPID') == pid
            and value.get('schema') == 'nexgenvideo/scene-editing-runtime/1' and value.get('scope') == 'scene-editing'
            and value.get('operationShutdown') is True and value.get('appDelegateShutdown') is True
            and b'SELFTEST_BPY_EDITING_OK\n' in (directory / 'runtime.log').read_bytes()
            and not (directory / 'runtime-failure-observation.json').exists(), 'Scene editing did not finish normally')
    require(validate_cases(value, directory, ('nativeSceneUI', 'nativePoseUI', 'nativeClayUI', 'nativeSpatialStoryboardUI', 'nativeBibleUI')),
            'Missing original scene, camera, pose, rendering or playback evidence')
    for row in value['nativeSceneUI']:
        choice, = [e for e in row['interactions'] if e.get('kind') == 'menu' and e.get('id') == 'spatial.camera.select']
        require(choice['closed'] is True and choice['path'] == ['Wide camera'] and 'Wide camera' in choice['titles'],
                'Native camera picker selection is missing')
    scene, = [e['evidence'] for e in value['nativeSceneUI'][-1]['interactions'] if e.get('label') == 'native scene camera transform undo redo']
    pose, = [e['evidence'] for e in value['nativePoseUI'][-1]['interactions'] if e.get('label') == 'native complete shot poses']
    tools = Path(os.environ['MOVIE_TOOLS'])
    decoders = {name: {'binarySHA256': checksum(tools / name), 'version': command([str(tools / name), '-version']).splitlines()[0]}
                for name in ('ffprobe', 'ffmpeg')}
    movies = []
    for row in value['nativeClayUI']:
        state, = [i['evidence'] for i in row['interactions'] if i.get('label') == 'native full shot Clay render and inspect']
        folder = directory / f"clay-render-{round(row['scale'] * 100)}"
        movies.append(dict(scale=row['scale'], **validate_render(folder, state, scene, pose, tools)))
    assignments = []
    for row in value['nativeSpatialStoryboardUI']:
        state, = [e['evidence'] for e in row['interactions'] if e.get('label') == 'native location sketch assigned']
        assignments.append(validate_assignment(directory, f"storyboard-{round(row['scale'] * 100)}", state, scene, tools))
    for row in value['nativeBibleUI']:
        require(all(row[key] is True for key in ('nativeSceneAndCameraSelection', 'requiredPurpose', 'realRenderedPreview',
                'nativeImageInspection', 'exactPreviewAssigned', 'preparedCancelUnchanged', 'staleAssignmentUnchanged',
                'reloadAndAssign', 'cancelDuringHash', 'closeDuringLoading')), 'Incomplete Bible assignment coverage')
        for view in (row['viewID'], row['recoveredViewID']):
            assignments.append(validate_assignment(directory, 'bible-' + view, row, scene, tools, view))
    verification = json.loads((directory / 'evaluated-deformation/scene-verification.json').read_bytes())
    geometry = verify_geometry(directory, verifier_runtime(verification, installed))
    return dict(appScopePassed=True, movies=movies, decoders=decoders, assignmentRenders=assignments, geometry=geometry)


def verify_launch_presentation(proof, pid):
    number = proof['windowNumber']
    screen = proof['onScreenWindowNumbers']
    shown, ordered, observed = proof['shownUptime'], proof['orderedOutUptime'], proof['observedUptime']
    require(type(proof['pid']) is int and proof['pid'] == pid
            and type(number) is int and number > 0 and isinstance(screen, list) and screen
            and all(type(item) is int and item > 0 for item in screen) and number not in screen
            and all(type(t) in (int, float) and math.isfinite(t) for t in (shown, ordered, observed))
            and 0 < shown <= ordered <= observed, 'The real splash must leave the screen before scene input')


def execute_history(installed, root, evidence, product, scope='scene-history'):
    executable = installed / 'Contents/MacOS/NexGenVideo'
    child = environment(os.environ, root / 'home')
    for key in list(child):
        if key.startswith(('NGV_', 'GITHUB_', 'ACTIONS_')) or key in ('GH_TOKEN', 'GIT_ASKPASS'):
            child.pop(key)
    native = evidence / 'scene'
    native.mkdir()
    child.update(NGV_SELFTEST_BPY=str(native), NGV_SELFTEST_BPY_SCOPE=scope)
    args = [str(executable), '-hangDiagnosticMode', 'disabled',
            '-de.h5ventures.nexgenvideo.notifications.enabled', 'NO', '-agentBackend', 'anthropicAPI',
            '-de.h5ventures.nexgenvideo.mcp.enabled', 'NO']
    with (native / 'runtime.log').open('xb') as stdout, (native / 'runtime-stderr.log').open('xb') as stderr:
        process = subprocess.Popen(args, env=child, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
        launch = dict(pid=process.pid, sourceSHA=product, scope=scope, arguments=args)
        try:
            write(evidence / 'scene-launch.json', launch)
            code = process.wait(timeout=5400 if scope == 'scene-editing' else 300)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            with (native / 'runtime-stderr.log').open('rb') as log:
                launch['notificationOptOutObserved'] = any(
                    line.rstrip(b'\r\n') == b'[app] NOTICE: notifications disabled in settings' for line in log)
            write(evidence / 'scene-launch.json', launch)
    require(code == 0, f'Scene history exited with {code}')
    require(launch['notificationOptOutObserved'], 'The App did not confirm its notification preference')
    presentation = json.loads((native / 'launch-presentation.json').read_bytes())
    verify_launch_presentation(presentation, process.pid)
    write(native / 'process-result.json', dict(pid=process.pid, sourceSHA=product, mode='runtime', returncode=code))
    if scope == 'scene-editing':
        return editing_result(native, product, process.pid, installed)
    return scoped_success(scoped_files(native), product, process.pid)


def main():
    env = os.environ
    product = env['GITHUB_SHA']
    inputs = json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes())['inputs']
    validate_dispatch(inputs)
    producer = int(inputs['run_id'])
    require(sys.platform == 'darwin' and platform.machine() == 'arm64' and command(['sw_vers', '-productVersion']).split('.')[0] == '27'
            and env['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo' and env['GITHUB_ACTOR'] == 'iret77'
            and env['GITHUB_REF_NAME'] == BASE and env['GITHUB_RUN_ATTEMPT'] == '1'
            and env['GITHUB_JOB'] == 'signed-scene-history' and inputs['source_sha'] == product
            and env['GITHUB_EVENT_NAME'] == 'workflow_dispatch', 'Unexpected scene-history job')
    root = Path(env['RUNNER_TEMP']).resolve(strict=True) / 'signed-scene-history'
    evidence = root / 'evidence'
    evidence.mkdir(parents=True)
    source_proof = root / 'source-proof'
    prepare(int(inputs['verified_pr_run_id']), source_proof)
    harness = json.loads((source_proof / 'receipt.json').read_bytes())
    expected = inputs['expected_dmg_sha256']
    dmg, original, item = acquire_image(root, inputs, product)
    mount = root / 'volume'
    mount.mkdir()
    installed = INSTALLED
    require(not installed.exists() and not installed.is_symlink(), 'Installation destination is occupied')
    log = evidence / 'installation.log'
    def invoke(*args):
        with log.open('ab') as stream:
            subprocess.run(args, stdout=stream, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, check=True, timeout=180)
    invoke('hdiutil', 'verify', dmg)
    invoke('xcrun', 'stapler', 'validate', dmg)
    invoke('hdiutil', 'attach', dmg, '-readonly', '-nobrowse', '-mountpoint', mount)
    try:
        app = mount / installed.name
        pack = mount / 'musicvideo.ngvpack'
        require(metadata(app, product) == original['app'] and original['app']['treeSHA256'] == original['mountedAppTreeSHA256']
                and tree_sha256(pack) == original['mountedPackTreeSHA256'] == original['packTreeSHA256'],
                'Mounted product differs from its independent producer receipt')
        invoke('ditto', app, installed)
    finally:
        invoke('hdiutil', 'detach', mount)
    require(metadata(installed, product) == original['app']
            and command(['lipo','-archs', str(installed / 'Contents/MacOS/NexGenVideo')]) == 'arm64', 'Installed app changed')
    invoke('codesign', '--verify', '--deep', '--strict', installed)
    invoke('xcrun', 'stapler', 'validate', installed)
    proof = dict(harness=harness, producer=producer, product=product, artifact=item['id'], artifactDigest=item['digest'],
                 innerSHA256=expected, app=original['app'], packTreeSHA256=original['packTreeSHA256'],
                 macOS=command(['sw_vers', '-productVersion']), architecture=platform.machine())
    write(evidence / 'input.json', proof)
    scope = inputs['candidate_kind'].removeprefix('signed-')
    outcome = execute_history(installed, root, evidence, product, scope)
    require(outcome['appScopePassed'] is True and checksum(dmg) == expected and metadata(installed, product) == original['app'],
            'Scene history did not finish on the original product')
    write(evidence / 'verified.json', dict(input=proof, scope=scope, **{'history' if scope == 'scene-history' else 'editing': outcome}))


if __name__ == '__main__':
    main()
