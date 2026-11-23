"""Verify ordinary scene edits and document shutdown on the qualified internal disk image."""

from fractions import Fraction
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import zipfile

from isolated_test_home import environment
from retained_app_test_products import api, checksum, command, download, require, verify_artifact, write
from scene_history_hierarchy import scoped_files, scoped_success
from production_spatial_ui_evidence import validate_cases
from release_checkpoint import internal_image_evidence
from verified_pr_source_checks import prepare

sys.path.insert(0, str(Path(__file__).resolve().parent / 'external-gui'))
from acceptance import metadata, tree_sha256


BASE = 'iret77/rc-delivery-base-795'


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
    require(mounted['dmgSHA256'] == expected and mounted['app']['CFBundleVersion'] == '142'
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
    shot = outputs['clay.mov']
    require(shot['sha256'] == state['videoSHA256'] and [shot[k] for k in ('width', 'height', 'frameCount')] ==
            [request['width'], request['height'], count], 'Final shot differs from its sequence')
    decoded = json.loads(command([str(tools / 'ffprobe'), '-v', 'error', '-select_streams', 'v', '-count_frames',
        '-show_frames', '-show_streams', '-show_entries', 'stream:frame=pts', '-of', 'json', str(movie)], timeout=120))
    stream, = decoded['streams']
    validate_timing(proof, stream, decoded['frames'])
    subprocess.run([str(tools / 'ffmpeg'), '-nostdin', '-v', 'error', '-xerror', '-i', str(movie),
                    '-map', '0:v:0', '-f', 'null', '-'], stdin=subprocess.DEVNULL, check=True, timeout=120)
    return dict(videoSHA256=state['videoSHA256'], proofSHA256=state['proofSHA256'], stream=stream,
                presentationTimestamps=[int(f['pts']) for f in decoded['frames']])


def editing_result(directory, product, pid):
    value = json.loads((directory / 'result.json').read_bytes())
    require(value.get('sourceSHA') == product and value.get('hostPID') == pid
            and value.get('schema') == 'nexgenvideo/scene-editing-runtime/1' and value.get('scope') == 'scene-editing'
            and value.get('operationShutdown') is True and value.get('appDelegateShutdown') is True
            and b'SELFTEST_BPY_EDITING_OK\n' in (directory / 'runtime.log').read_bytes()
            and not (directory / 'runtime-failure-observation.json').exists(), 'Scene editing did not finish normally')
    require(validate_cases(value, directory, ('nativeSceneUI', 'nativePoseUI', 'nativeClayUI')),
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
    return dict(appScopePassed=True, movies=movies, decoders=decoders)


def execute_history(installed, root, evidence, product, scope='scene-history'):
    executable = installed / 'Contents/MacOS/NexGenVideo'
    child = environment(os.environ, root / 'home')
    for key in list(child):
        if key.startswith(('NGV_', 'GITHUB_', 'ACTIONS_')) or key in ('GH_TOKEN', 'GIT_ASKPASS'):
            child.pop(key)
    native = evidence / 'scene'
    native.mkdir()
    child.update(NGV_SELFTEST_BPY=str(native), NGV_SELFTEST_BPY_SCOPE=scope)
    args = [str(executable), '-hangDiagnosticMode', 'disabled', '-agentBackend', 'anthropicAPI',
            '-de.h5ventures.nexgenvideo.mcp.enabled', 'NO']
    with (native / 'runtime.log').open('xb') as stdout, (native / 'runtime-stderr.log').open('xb') as stderr:
        process = subprocess.Popen(args, env=child, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
        try:
            code = process.wait(timeout=2400 if scope == 'scene-editing' else 300)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    require(code == 0, f'Scene history exited with {code}')
    write(native / 'process-result.json', dict(pid=process.pid, sourceSHA=product, mode='runtime', returncode=code))
    if scope == 'scene-editing':
        return editing_result(native, product, process.pid)
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
    installed = Path('/Applications/NexGenVideo.app')
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
