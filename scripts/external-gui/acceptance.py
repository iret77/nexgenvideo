#!/usr/bin/env python3
"""Drive the installed app from an independent XCTest runner in a CI desktop."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent
REPOSITORY = ROOT.parents[1]
TEST_INPUTS = ('acceptance.py', 'test_bundle.py', 'project.yml', 'NexGenVideoExternalUITests/UserJourneyTests.swift')
CONFIG = Path('/tmp/nexgenvideo-external-gui-config.json')
STAGES = ['home', 'settings', 'new-project', 'media-import', 'source-insert',
          'timeline-split', 'timeline-undo', 'close', 'reopen', 'export']
SCALES = {'1': 'Standard', '1.25': 'Larger · 125%', '1.5': 'Largest · 150%'}


def require(value, message):
    if not value:
        raise ValueError(message)


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    Path(path).write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def tree_sha256(path):
    root = Path(path)
    require(root.is_dir() and not root.is_symlink(), 'Expected a real bundle directory')
    records = []
    for child in sorted(root.rglob('*')):
        mode = child.lstat().st_mode
        record = [child.relative_to(root).as_posix(), stat.S_IMODE(mode)]
        if child.is_symlink():
            target = child.resolve(strict=True)
            require(target.is_relative_to(root.resolve()), 'Bundle symlink escapes the app')
            record += ['symlink', os.readlink(child)]
        elif child.is_file():
            record += ['file', sha256(child)]
        else:
            require(child.is_dir(), 'Unexpected special file in bundle')
            record += ['directory']
        records.append(record)
    return hashlib.sha256(json.dumps(records, ensure_ascii=True, separators=(',', ':')).encode()).hexdigest()


def command(arguments, log, timeout=60, check=True, cwd=None):
    with Path(log).open('ab') as handle:
        with subprocess.Popen([str(item) for item in arguments], stdin=subprocess.DEVNULL,
                              stdout=handle, stderr=subprocess.STDOUT, cwd=cwd,
                              start_new_session=True) as process:
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
            code = process.returncode
    if check:
        require(code == 0, f'{arguments[0]} failed; see {Path(log).name}')
    return code


def output(arguments, timeout=30):
    return subprocess.check_output([str(item) for item in arguments], stdin=subprocess.DEVNULL,
                                   stderr=subprocess.PIPE, timeout=timeout)


def metadata(app, source_sha):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == 'de.h5ventures.nexgenvideo', 'Wrong application bundle')
    require(info.get('CFBundleExecutable') == 'NexGenVideo', 'Wrong executable')
    require(info.get('NGVSourceCommit') == source_sha, 'App source SHA differs from this qualification')
    require(info.get('LSMinimumSystemVersion') == '26.0', 'Unexpected product deployment floor')
    executable = app / 'Contents/MacOS/NexGenVideo'
    require(executable.is_file(), 'App executable missing')
    return {key: info.get(key) for key in ['CFBundleIdentifier', 'CFBundleShortVersionString',
            'CFBundleVersion', 'NGVSourceCommit', 'LSMinimumSystemVersion']} | {
                'executableSHA256': sha256(executable), 'treeSHA256': tree_sha256(app)}


def test_source_identity(source_sha, input_root=ROOT):
    revision = output(['git', '-C', REPOSITORY, 'rev-parse', 'HEAD']).decode().strip()
    require(revision == source_sha, 'Test checkout differs from the app source SHA')
    fingerprints = {}
    for name in TEST_INPUTS:
        path = input_root / name
        require(path.is_file() and not path.is_symlink(), 'Test input is not a regular file: ' + name)
        relative = (ROOT / name).relative_to(REPOSITORY).as_posix()
        committed = output(['git', '-C', REPOSITORY, 'show', source_sha + ':' + relative])
        digest = sha256(path)
        require(digest == hashlib.sha256(committed).hexdigest(), 'Test input differs from its committed bytes: ' + relative)
        fingerprints[relative] = digest
    return revision, fingerprints


def install(args, evidence):
    installed = Path('/Applications/NexGenVideo.app')
    require(not installed.exists(), 'Refusing to replace an already installed app')
    test_revision, test_files = test_source_identity(args.source_sha)
    identity = {'schema': 'nexgenvideo/external-gui-input/1', 'sourceSHA': args.source_sha,
                'testSourceSHA': test_revision, 'testFiles': test_files,
                'scale': args.scale, 'runID': os.environ.get('GITHUB_RUN_ID'),
                'runAttempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
                'osVersion': output(['sw_vers', '-productVersion']).decode().strip()}
    if args.dmg:
        dmg = Path(args.dmg).resolve(strict=True)
        require(re.fullmatch('[a-f0-9]{64}', args.dmg_sha256 or ''), 'DMG mode requires its expected SHA-256')
        require(sha256(dmg) == args.dmg_sha256, 'DMG bytes differ from the expected publication transaction')
        identity.update(mode='dmg', dmgSHA256=args.dmg_sha256)
        command(['hdiutil', 'verify', dmg], evidence / 'install.log', timeout=120)
        command(['xcrun', 'stapler', 'validate', dmg], evidence / 'install.log')
        mount = Path(tempfile.mkdtemp(prefix='ngv-external-dmg-'))
        attached = False
        try:
            command(['hdiutil', 'attach', dmg, '-readonly', '-nobrowse', '-mountpoint', mount],
                    evidence / 'install.log')
            attached = True
            apps = list(mount.glob('*.app'))
            require(len(apps) == 1 and apps[0].name == 'NexGenVideo.app', 'Expected exactly the NexGenVideo app in the DMG')
            source = apps[0]
            identity['app'] = metadata(source, args.source_sha)
            command(['ditto', source, installed], evidence / 'install.log', timeout=120)
        finally:
            if attached:
                command(['hdiutil', 'detach', mount], evidence / 'install.log')
        command(['codesign', '--verify', '--deep', '--strict', '--verbose=2', installed], evidence / 'install.log')
        command(['xcrun', 'stapler', 'validate', installed], evidence / 'install.log')
    else:
        source = Path(args.app).resolve(strict=True)
        require(re.fullmatch('[a-f0-9]{64}', args.app_tree_sha256 or ''),
                'App mode requires the expected app tree SHA-256 from the verified runtime artifact')
        identity['app'] = metadata(source, args.source_sha)
        require(identity['app']['treeSHA256'] == args.app_tree_sha256, 'App differs from the verified runtime artifact')
        identity['mode'] = 'app-artifact'
        command(['ditto', source, installed], evidence / 'install.log', timeout=120)
    require(metadata(installed, args.source_sha) == identity['app'], 'Installation changed app bytes or metadata')
    write_json(evidence / 'identity.json', identity)
    return installed, identity


def create_source(evidence):
    source = evidence / 'GUI acceptance source.mp4'
    command(['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
             'testsrc2=size=320x180:rate=30', '-t', '4', '-an', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', source],
            evidence / 'source.log')
    return source


def clips(value):
    return [clip for track in value['tracks'] for clip in track['clips']]


def validate_journey(evidence):
    journey = read_json(evidence / 'journey.json')
    require(journey.get('schema') == 'nexgenvideo/external-gui-journey/1', 'Wrong journey evidence schema')
    require([row.get('stage') for row in journey['stages']] == STAGES, 'Missing or duplicated user stages')
    for row in journey['stages']:
        proof = row['evidence']
        for field in ['screenshot', 'accessibility']:
            name = proof[field]
            require(Path(name).name == name, 'Evidence reference escapes its directory')
            path = evidence / name
            require(sha256(path) == proof[field + 'SHA256'], 'Captured GUI evidence changed')
            if field == 'screenshot':
                require(path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), 'Screenshot is not a PNG')
            else:
                require('Application' in path.read_text(), 'Accessibility attachment is empty')
    require(len(journey['actions']) >= 40, 'Native interaction evidence is incomplete')
    imported = read_json(evidence / 'media-import-project.json')
    require(not clips(imported), 'Library import modified the timeline')
    inserted = read_json(evidence / 'source-insert-project.json')
    require((inserted['fps'], inserted['width'], inserted['height']) == (30, 320, 180), 'Wrong source settings')
    before = clips(inserted)
    require(len(before) == 1 and before[0]['startFrame'] == 0 and before[0]['durationFrames'] == 120,
            'Source insert did not preserve all 120 frames')
    split = sorted(clips(read_json(evidence / 'timeline-split-project.json')), key=lambda item: item['startFrame'])
    require([(item['startFrame'], item['durationFrames']) for item in split] == [(0, 30), (30, 90)], 'Incorrect split ranges')
    require([(item['trimStartFrame'], item['trimEndFrame']) for item in split] == [(0, 90), (30, 0)],
            'Split did not preserve the exact source in/out ranges')
    require(all(item['mediaRef'] == before[0]['mediaRef'] for item in split), 'Split changed source identity')
    require(read_json(evidence / 'timeline-undo-project.json') == inserted, 'Undo did not restore exact project state')
    require(read_json(evidence / 'reopen-project.json') == inserted, 'Reopen changed persisted project state')
    manifest = read_json(evidence / 'media-import-media.json')['entries']
    require(len(manifest) == 1 and manifest[0]['originalFilename'] == 'GUI acceptance source.mp4', 'Import lost original filename')
    require(manifest[0]['id'] == before[0]['mediaRef'], 'Timeline did not bind the imported asset')
    relative = Path(manifest[0]['source']['project']['relativePath'])
    require(not relative.is_absolute() and '..' not in relative.parts, 'Imported source escapes the project')
    package = evidence / 'External GUI.ngv'
    imported_source = (package / relative).resolve(strict=True)
    require(imported_source.is_relative_to(package.resolve()), 'Imported source follows a symlink outside the project')
    require(sha256(imported_source) == sha256(evidence / 'GUI acceptance source.mp4'), 'Import changed the source bytes')
    require(next(row for row in journey['stages'] if row['stage'] == 'source-insert').get('clearRangeEnabled') is False,
            'Unexpected enabled Clear Range on a fresh source')
    return journey


def stop_owned_app(evidence):
    request = evidence / 'launch-request.json'
    if not request.exists():
        return
    app = '/Applications/NexGenVideo.app'
    require(read_json(request).get('app') == app, 'Unexpected app cleanup ownership record')
    executable = app + '/Contents/MacOS/NexGenVideo'
    rows = output(['/bin/ps', '-axo', 'pid=,comm=']).decode().splitlines()
    owned = [int(row.strip().split(None, 1)[0]) for row in rows
             if len(row.strip().split(None, 1)) == 2 and row.strip().split(None, 1)[1] == executable]
    for pid in owned:
        try:
            os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if subprocess.run(['/bin/ps', '-p', str(pid)], stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5).returncode != 0:
                    break
                time.sleep(0.2)
            else:
                current = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'comm='],
                                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, text=True, timeout=5)
                require(current.returncode in (0, 1), 'Unable to inspect owned process during cleanup')
                if current.returncode == 0 and current.stdout.strip() == executable:
                    os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    write_json(evidence / 'cleanup.json', {'ownedExecutable': executable, 'terminatedPIDs': owned})


def verify_movie(evidence, config):
    movie = Path(config['movie'])
    source = Path(config['source'])
    probe = json.loads(output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', movie]))
    write_json(evidence / 'export-ffprobe.json', probe)
    streams = [stream for stream in probe['streams'] if stream['codec_type'] == 'video']
    require(len(streams) == 1 and streams[0]['codec_name'] == 'h264', 'Expected one H.264 output stream')
    stream = streams[0]
    require((stream['width'], stream['height'], stream['r_frame_rate']) == (320, 180, '30/1'), 'Export changed size or frame rate')
    require(abs(float(probe['format']['duration']) - 4) <= 1 / 30, 'Export changed film duration')
    require(not any(item['codec_type'] == 'audio' for item in probe['streams']), 'Silent fixture gained an audio stream')
    frames = []
    for name, path in [('source', source), ('export', movie)]:
        raw = output(['ffmpeg', '-nostdin', '-v', 'error', '-ss', '1', '-i', path, '-frames:v', '1',
                      '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-threads', '1', '-'], timeout=30)
        require(len(raw) == 320 * 180 * 3, 'Decoded frame has unexpected dimensions')
        frames.append(raw)
        command(['ffmpeg', '-nostdin', '-v', 'error', '-ss', '1', '-i', path, '-frames:v', '1',
                 evidence / (name + '-frame.png')], evidence / 'decode.log')
    error = sum(abs(a - b) for a, b in zip(*frames)) / len(frames[0])
    require(error < 15, 'Exported pixels differ from the imported source at the same time')
    return {'sha256': sha256(movie), 'sourceSHA256': sha256(source), 'sampleTimeSeconds': 1,
            'meanAbsoluteChannelError': error, 'maximumMeanAbsoluteChannelError': 15,
            'frames': {name: sha256(evidence / name) for name in ['source-frame.png', 'export-frame.png']}}


def require_runtime_host(runtime):
    version = runtime.get('osVersion')
    match = re.fullmatch(r'(\d+)\.\d+(?:\.\d+)?', version) if isinstance(version, str) else None
    require(runtime.get('githubActions') is True and runtime.get('runnerEnvironment') == 'self-hosted'
            and runtime.get('platform') == 'darwin' and runtime.get('architecture') == 'arm64'
            and match is not None and int(match[1]) >= 26
            and isinstance(runtime.get('osBuild'), str) and bool(runtime['osBuild'].strip())
            and isinstance(runtime.get('runnerName'), str) and bool(runtime['runnerName'].strip()),
            'External GUI runtime requires self-hosted macOS 26 or later, arm64')


def runtime_environment(evidence):
    runtime = {'schema': 'nexgenvideo/external-gui-runtime/1', 'platform': sys.platform,
               'architecture': platform.machine(), 'osVersion': output(['sw_vers', '-productVersion']).decode().strip(),
               'osBuild': output(['sw_vers', '-buildVersion']).decode().strip(),
               'githubActions': os.environ.get('GITHUB_ACTIONS') == 'true',
               'runnerEnvironment': os.environ.get('RUNNER_ENVIRONMENT'),
               'runnerName': os.environ.get('RUNNER_NAME'),
               'imageOS': os.environ.get('ImageOS'), 'imageVersion': os.environ.get('ImageVersion')}
    write_json(evidence / 'runtime.json', runtime)
    require_runtime_host(runtime)
    uid = os.getuid()
    runtime['consoleUID'] = int(output(['stat', '-f', '%u', '/dev/console']).decode().strip())
    runtime['jobUID'] = uid
    write_json(evidence / 'runtime.json', runtime)
    require(uid > 0 and runtime['consoleUID'] == uid, 'The CI user has no foreground console session')
    command(['launchctl', 'print', f'gui/{uid}'], evidence / 'gui-session.log')
    status = output(['/usr/sbin/DevToolsSecurity', '-status']).decode().strip()
    runtime['developerSecurity'] = status
    runtime['xcode'] = output(['xcodebuild', '-version']).decode().strip()
    write_json(evidence / 'runtime.json', runtime)
    require(status == 'Developer mode is currently enabled.', 'Developer authorization is unavailable')
    command(['screencapture', '-x', evidence / 'desktop.png'], evidence / 'prerequisites.log')
    require((evidence / 'desktop.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),
            'The desktop did not produce a screenshot')
    runtime.update(aquaSession=True, desktopSHA256=sha256(evidence / 'desktop.png'))
    write_json(evidence / 'runtime.json', runtime)
    return runtime


def validate_runtime(evidence):
    runtime = read_json(evidence / 'runtime.json')
    require_runtime_host(runtime)
    require(runtime.get('schema') == 'nexgenvideo/external-gui-runtime/1'
            and type(runtime.get('jobUID')) is int and runtime['jobUID'] > 0
            and runtime.get('consoleUID') == runtime['jobUID'] and runtime.get('aquaSession') is True
            and runtime.get('developerSecurity') == 'Developer mode is currently enabled.'
            and runtime.get('desktopSHA256') == sha256(evidence / 'desktop.png')
            and runtime.get('xcode', '').startswith('Xcode '), 'Missing original self-hosted GUI prerequisites')


def run(args):
    import test_bundle

    require(re.fullmatch('[a-f0-9]{40}', args.source_sha), 'Expected an exact source SHA')
    require(not any(name.startswith('NGV_') and ('ACCEPTANCE' in name or 'SELFTEST' in name or 'EXAMPLE' in name)
                    for name in os.environ), 'Internal acceptance flags must not reach this user journey')
    for tool in ['xcodebuild', 'xcrun', 'ffmpeg', 'ffprobe', 'screencapture']:
        require(shutil.which(tool), 'Missing CI tool: ' + tool)
    evidence = Path(args.evidence).resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    require(not CONFIG.exists(), 'This VM already has an external GUI configuration')
    result = {'schema': 'nexgenvideo/external-gui-result/1', 'completed': False, 'sourceSHA': args.source_sha}
    write_json(evidence / 'result.json', result)
    try:
        runtime_environment(evidence)
        app, identity = install(args, evidence)
        test_input = Path(args.test_runtime).resolve(strict=True)
        require(re.fullmatch('[a-f0-9]{64}', args.test_producer_sha256)
                and sha256(test_input / 'tests-producer.json') == args.test_producer_sha256,
                'UI test producer identity changed after the original qualification job')
        for name in ('tests.tar.gz', 'tests-input.json', 'tests-producer.json'):
            shutil.copy2(test_input / name, evidence / name)
        work = Path(tempfile.mkdtemp(prefix='ngv-external-tests-'))
        xctestrun, tests = test_bundle.consume(evidence, work / 'Products', args.source_sha, identity['testFiles'])
        identity['testBundle'] = {key: tests[key] for key in (
            'runID', 'attempt', 'archiveSHA256', 'productsSHA256', 'xctestrun', 'xcode')}
        identity['testBundle'].update(receiptSHA256=sha256(evidence / 'tests-input.json'),
                                     producerSHA256=sha256(evidence / 'tests-producer.json'))
        write_json(evidence / 'identity.json', identity)
        source = create_source(evidence)
        config = {'app': str(app), 'evidence': str(evidence), 'source': str(source),
                  'project': str(evidence / 'External GUI.ngv'), 'movie': str(evidence / 'user-export.mp4'),
                  'scaleLabel': SCALES[args.scale]}
        with CONFIG.open('x') as handle:
            json.dump(config, handle)
        write_json(evidence / 'configuration.json', config)
        (evidence / 'test-bundle.sha256').write_text(sha256(xctestrun) + '\n')
        code = command(['xcodebuild', 'test-without-building', '-xctestrun', xctestrun,
                        '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
                        '-resultBundlePath', evidence / 'tests.xcresult'], evidence / 'tests.log', timeout=720, check=False)
        result['exitCode'] = code
        bundle = evidence / 'tests.xcresult'
        if bundle.exists():
            command(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', bundle,
                     '--output-path', evidence / 'attachments'], evidence / 'results.log')
            summary = json.loads(output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', bundle]))
            write_json(evidence / 'summary.json', summary)
        else:
            raise ValueError('No XCTest result bundle was produced')
        require(code == 0, 'External GUI journey failed; see tests.log and screenshot/AX attachments')
        require(summary.get('passedTests') == 1 and summary.get('failedTests') == 0
                and summary.get('skippedTests') == 0, 'Exactly the one external journey must execute and pass')
        journey = validate_journey(evidence)
        movie = verify_movie(evidence, config)
        require(journey['stages'][-1]['movieSHA256'] == movie['sha256'], 'Movie changed after the visible completion')
        require(metadata(app, args.source_sha) == identity['app'], 'The app changed while being qualified')
        result.update(completed=True, identitySHA256=sha256(evidence / 'identity.json'),
                      runtimeSHA256=sha256(evidence / 'runtime.json'),
                      journeySHA256=sha256(evidence / 'journey.json'), export=movie,
                      mode=identity['mode'], dmgSHA256=identity.get('dmgSHA256'))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result['error'] = str(error)
        raise
    finally:
        try:
            stop_owned_app(evidence)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            result.update(completed=False, cleanupError=str(error))
        write_json(evidence / 'result.json', result)
    require(result['completed'], 'External GUI cleanup failed')


def validate_app_identity(evidence, result, identity, source_sha, scale, dmg_sha256):
    require(identity.get('schema') == 'nexgenvideo/external-gui-input/1'
            and identity.get('app', {}).get('NGVSourceCommit') == source_sha
            and result.get('mode') == identity.get('mode'), 'Qualified app identity changed')
    require(scale in SCALES and identity.get('scale') == scale, 'Evidence belongs to another interface scale')
    if dmg_sha256:
        require(re.fullmatch('[a-f0-9]{64}', dmg_sha256)
                and identity.get('mode') == 'dmg'
                and identity.get('dmgSHA256') == result.get('dmgSHA256') == dmg_sha256,
                'This is not GUI acceptance of the exact publication DMG')
    else:
        runtime = read_json(evidence / 'runtime-input.json')
        require(identity.get('mode') == 'app-artifact'
                and runtime.get('schema') == 'nexgenvideo/workspace-ui-input/1'
                and runtime.get('sourceSHA') == source_sha
                and re.fullmatch('[a-f0-9]{64}', runtime.get('appTreeSHA256', ''))
                and identity['app'].get('treeSHA256') == runtime['appTreeSHA256'],
                'Qualified app differs from the original runtime receipt')


def validate(args):
    import test_bundle

    evidence = Path(args.evidence).resolve(strict=True)
    result = read_json(evidence / 'result.json')
    identity = read_json(evidence / 'identity.json')
    require(result.get('schema') == 'nexgenvideo/external-gui-result/1' and result.get('completed') is True
            and result.get('exitCode') == 0,
            'External GUI evidence is incomplete')
    require(result['sourceSHA'] == identity['sourceSHA'] == identity['testSourceSHA'] == args.source_sha,
            'Evidence belongs to another source revision')
    validate_app_identity(evidence, result, identity, args.source_sha, args.scale, args.dmg_sha256)
    require(result['identitySHA256'] == sha256(evidence / 'identity.json')
            and result['journeySHA256'] == sha256(evidence / 'journey.json'), 'Evidence bytes changed')
    require(result.get('runtimeSHA256') == sha256(evidence / 'runtime.json'), 'Runtime evidence changed')
    validate_runtime(evidence)
    _, source_files = test_source_identity(args.source_sha)
    require(identity.get('testFiles') == source_files, 'Qualified test source files changed')
    tests = test_bundle.verify_input(evidence, args.source_sha, source_files)
    expected = {key: tests[key] for key in ('runID', 'attempt', 'archiveSHA256', 'productsSHA256', 'xctestrun', 'xcode')}
    expected.update(receiptSHA256=sha256(evidence / 'tests-input.json'),
                    producerSHA256=sha256(evidence / 'tests-producer.json'))
    require(identity.get('testBundle') == expected, 'UI test bundle provenance changed')
    with tempfile.TemporaryDirectory(prefix='ngv-validate-tests-') as temporary:
        xctestrun, _ = test_bundle.consume(evidence, Path(temporary) / 'Products', args.source_sha, source_files)
        require((evidence / 'test-bundle.sha256').read_text().strip() == sha256(xctestrun),
                'Qualified xctestrun changed')
    summary = read_json(evidence / 'summary.json')
    require(summary.get('passedTests') == 1 and summary.get('failedTests') == 0
            and summary.get('skippedTests') == 0, 'External test did not execute and pass')
    journey = validate_journey(evidence)
    require(journey['stages'][-1].get('movieSHA256') == result['export']['sha256'],
            'Qualified movie differs from the visible completion')
    require(sha256(evidence / 'user-export.mp4') == result['export']['sha256'], 'Qualified movie changed')
    require(sha256(evidence / 'GUI acceptance source.mp4') == result['export']['sourceSHA256'], 'Imported fixture changed')
    for name, digest in result['export']['frames'].items():
        require(sha256(evidence / name) == digest, 'Decoded frame evidence changed')
    print(json.dumps({'completed': True, 'sourceSHA': args.source_sha, 'mode': result['mode'],
                      'dmgSHA256': result.get('dmgSHA256')}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    execute = commands.add_parser('run')
    inputs = execute.add_mutually_exclusive_group(required=True)
    inputs.add_argument('--app')
    inputs.add_argument('--dmg')
    execute.add_argument('--app-tree-sha256')
    execute.add_argument('--dmg-sha256')
    execute.add_argument('--scale', choices=SCALES, default='1')
    execute.add_argument('--source-sha', required=True)
    execute.add_argument('--evidence', required=True)
    execute.add_argument('--test-runtime', required=True)
    execute.add_argument('--test-producer-sha256', required=True)
    check = commands.add_parser('validate')
    check.add_argument('--source-sha', required=True)
    check.add_argument('--evidence', required=True)
    check.add_argument('--scale', choices=SCALES, required=True)
    check.add_argument('--dmg-sha256', help='Required by a publication caller; app-artifact evidence cannot satisfy it')
    tree = commands.add_parser('tree-sha256')
    tree.add_argument('--app', required=True)
    args = parser.parse_args()
    if args.command == 'run':
        run(args)
    elif args.command == 'validate':
        validate(args)
    else:
        print(tree_sha256(Path(args.app).resolve(strict=True)))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
