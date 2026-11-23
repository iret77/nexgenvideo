"""Verify ordinary scene edits and document shutdown on the qualified internal disk image."""

from contextlib import contextmanager, nullcontext
from fractions import Fraction
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
import zipfile

from isolated_test_home import environment
from retained_app_test_products import api, checksum, command, download, require, verify_artifact, write
from scene_history_hierarchy import scoped_files, scoped_success
from production_spatial_ui_evidence import validate_cases
from release_checkpoint import internal_image_evidence, internal_image_originals
import verified_pr_source_checks as source_checks

sys.path.insert(0, str(Path(__file__).resolve().parent / 'external-gui'))
from acceptance import metadata, tree_sha256


BASE = 'iret77/rc-delivery-base-795'
DESKTOP_BRANCH = 'iret77/rc-142-scene-desktop'
PRODUCT = 'd81c249811b31954c0e0366ef7740856c8cf8655'
HARNESS_FILES = {'scripts/release_checkpoint.py', 'scripts/signed_scene_history.py',
                 'scripts/scene_desktop_observer.swift', 'scripts/test_signed_scene_history.py'}


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


def bind_desktop_harness(run_id):
    head = os.environ['GITHUB_SHA']
    require(command(['git', 'rev-parse', 'HEAD']) == head and not command(['git', 'status', '--porcelain'])
            and not command(['git', 'merge-base', '--is-ancestor', PRODUCT, head])
            and set(command(['git', 'diff', '--no-renames', '--name-only', PRODUCT, head]).splitlines()) == HARNESS_FILES,
            'Unexpected scene harness checkout or product change')
    run = api(f'actions/runs/{run_id}')
    job = source_checks.verify_run_identity(run, api(f'actions/runs/{run_id}/attempts/1/jobs?per_page=100'), run_id)
    require(run['head_sha'] == head and run['head_branch'] == DESKTOP_BRANCH and job['labels'] == ['macrunner'],
            'Source checks belong to a different harness')
    item = original_item(run, job, f'verified-pr-source-{run_id}-a1')
    raw = source_checks.read_api(f"actions/artifacts/{item['id']}/zip", 100000)
    receipt = source_checks.original_receipt(item, raw, run)
    pr = api(f"pulls/{receipt['pullRequest']}")
    require(receipt['schema'] == 'verified-pr-source/v2' and receipt['headSHA'] == head
            and receipt['baseRef'] == BASE and pr['base']['ref'] == BASE and pr['base']['sha'] == PRODUCT
            and pr['head']['repo']['full_name'] == pr['base']['repo']['full_name'] == 'iret77/nexgenvideo'
            and pr['head']['sha'] == head and pr['head']['ref'] == DESKTOP_BRANCH and pr['user']['login'] == 'iret77'
            and pr['state'] == 'open' and receipt['treeSHA'] == command(['git', 'rev-parse', 'HEAD^{tree}']),
            'Source check receipt differs from the current RC or harness')
    merge = api('git/commits/' + receipt['checkoutSHA'])
    require(merge['tree']['sha'] == receipt['treeSHA'] and [p['sha'] for p in merge['parents']] == [PRODUCT, head],
            'Tested source tree or parents differ')
    source_checks.verify_steps(job, receipt)
    log = source_checks.read_api(f"actions/jobs/{job['id']}/logs")
    case = 'test_desktop_observer_typechecks_on_macos'
    require(len(re.findall(rf'(?m) {case} \(test_signed_scene_history\.SignedSceneHistoryTests\.{case}\) \.\.\. ok\r?$', log.decode())) == 1,
            'The original Mac source run did not typecheck the desktop observer')
    summary = source_checks.test_completion(log)
    require(summary['summary'] == 'OK', 'Incomplete standalone harness source checks')
    return dict(head=head, tree=receipt['treeSHA'], sourceRun=run_id, sourceArtifact=item['id'], sourceResult=summary)


def acquire_image(root, inputs, product, *, standalone=False):
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
    mounted = (internal_image_originals if standalone else internal_image_evidence)(run, inventory, product)
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


@contextmanager
def observe_desktop(root, evidence):
    executable = root / 'scene-desktop-observer'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', 'scripts/scene_desktop_observer.swift', '-o', executable],
                   check=True, stdin=subprocess.DEVNULL, timeout=120)
    with (evidence / 'desktop-observations.jsonl').open('xb') as out, (evidence / 'desktop-observer.log').open('xb') as err:
        observer = subprocess.Popen([executable, root], stdout=out, stderr=err, stdin=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 15
            while not (root / 'scene-desktop-ready').is_file():
                require(observer.poll() is None and time.monotonic() < deadline, 'Desktop observer did not record its baseline')
                time.sleep(0.1)
            require(observer.poll() is None, 'Desktop observer stopped at its baseline')
            yield observer
        finally:
            (root / 'scene-desktop-done').touch()
            try:
                observer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                observer.kill()
                observer.wait(timeout=5)
        require(observer.returncode == 0, 'Desktop observation did not finish')


def execute_history(installed, root, evidence, product, scope='scene-history', observer=None):
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
            if observer is not None:
                write(root / 'scene-observed-app.json', dict(pid=process.pid, executable=str(executable)))
            code = process.wait(timeout=2400 if scope == 'scene-editing' else 300)
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
    write(native / 'process-result.json', dict(pid=process.pid, sourceSHA=product, mode='runtime', returncode=code))
    if scope == 'scene-editing':
        return editing_result(native, product, process.pid)
    return scoped_success(scoped_files(native), product, process.pid)


def main():
    env = os.environ
    inputs = json.loads(Path(env['GITHUB_EVENT_PATH']).read_bytes())['inputs']
    validate_dispatch(inputs)
    product = inputs['source_sha']
    standalone = env['GITHUB_REF_NAME'] == DESKTOP_BRANCH
    producer = int(inputs['run_id'])
    require(sys.platform == 'darwin' and platform.machine() == 'arm64' and command(['sw_vers', '-productVersion']).split('.')[0] == '27'
            and env['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo' and env['GITHUB_ACTOR'] == 'iret77'
            and (env['GITHUB_REF_NAME'] == BASE or standalone) and env['GITHUB_RUN_ATTEMPT'] == '1'
            and env['GITHUB_JOB'] == 'signed-scene-history' and (product == PRODUCT if standalone else product == env['GITHUB_SHA'])
            and env['GITHUB_EVENT_NAME'] == 'workflow_dispatch', 'Unexpected scene-history job')
    root = Path(env['RUNNER_TEMP']).resolve(strict=True) / 'signed-scene-history'
    evidence = root / 'evidence'
    evidence.mkdir(parents=True)
    source_proof = root / 'source-proof'
    if standalone:
        require(producer == 45242564408 and inputs['expected_dmg_sha256'] ==
                '1a96e92c210e3c4accda088b4e904c0ae00c6e0e641513952f7a62d93c8f7a92',
                'Standalone desktop verification requires the original Build 142 disk image')
        harness = bind_desktop_harness(int(inputs['verified_pr_run_id']))
    else:
        source_checks.prepare(int(inputs['verified_pr_run_id']), source_proof)
        harness = json.loads((source_proof / 'receipt.json').read_bytes())
    expected = inputs['expected_dmg_sha256']
    dmg, original, item = acquire_image(root, inputs, product, standalone=standalone)
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
    desktop = observe_desktop(root, evidence) if standalone and scope == 'scene-history' else nullcontext()
    with desktop as observer:
        outcome = execute_history(installed, root, evidence, product, scope, observer)
    require(outcome['appScopePassed'] is True and checksum(dmg) == expected and metadata(installed, product) == original['app'],
            'Scene history did not finish on the original product')
    write(evidence / 'verified.json', dict(input=proof, scope=scope, **{'history' if scope == 'scene-history' else 'editing': outcome}))


if __name__ == '__main__':
    main()
