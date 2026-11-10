#!/usr/bin/env python3
"""Drive the installed app from an independent XCTest runner in a CI desktop."""

from __future__ import annotations

import argparse
import hashlib
import json
import io
import urllib.request
import zipfile
import posixpath
import math
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
sys.path.insert(0, str(REPOSITORY / 'scripts'))
from verify_diagnostic_candidate import SIGNED_JOURNEY_HARNESS_PATHS
import retained_packaging
TEST_INPUTS = ('acceptance.py', 'test_bundle.py', 'transport.py', 'project.yml', 'NexGenVideoExternalUITests/UserJourneyTests.swift')
COLOR_HELPER = 'scripts/export_color_diagnostic.swift'
PACKAGING_INPUTS = retained_packaging.VERIFIER_INPUTS
SHARED_INPUTS = tuple(name for name in dict.fromkeys(('scripts/verify_diagnostic_candidate.py', COLOR_HELPER) + PACKAGING_INPUTS)
                      if name not in {'scripts/external-gui/' + value for value in TEST_INPUTS})
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


def test_source_identity(source_sha, input_root=ROOT, *, allowed_paths=None, packaging=None):
    revision = output(['git', '-C', REPOSITORY, 'rev-parse', 'HEAD']).decode().strip()
    require(re.fullmatch('[a-f0-9]{40}', source_sha) and re.fullmatch('[a-f0-9]{40}', revision),
            'Invalid product or test source SHA')
    record = retained_packaging.consumer_record(packaging, source_sha) if packaging is not None else None
    producer_source = record['producerSourceSHA'] if record is not None else source_sha
    allowed = SIGNED_JOURNEY_HARNESS_PATHS if allowed_paths is None else allowed_paths
    if record is not None:
        allowed = allowed | retained_packaging.component_consumer_repair_paths(record)
    if revision != producer_source:
        output(['git', '-C', REPOSITORY, 'merge-base', '--is-ancestor', producer_source, revision])
        changed = output(['git', '-C', REPOSITORY, 'diff', '--no-renames', '--name-only', '-z', producer_source, revision])
        require(not set(filter(None, changed.decode().split('\0'))) - allowed,
                'Product inputs changed since the retained signed App')
    fingerprints = {}
    for name in TEST_INPUTS:
        path = input_root / name
        require(path.is_file() and not path.is_symlink(), 'Test input is not a regular file: ' + name)
        relative = (ROOT / name).relative_to(REPOSITORY).as_posix()
        committed = output(['git', '-C', REPOSITORY, 'show', revision + ':' + relative])
        digest = sha256(path)
        require(digest == hashlib.sha256(committed).hexdigest(), 'Test input differs from its committed bytes: ' + relative)
        fingerprints[relative] = digest
    for shared in SHARED_INPUTS:
        require((REPOSITORY / shared).is_file() and not (REPOSITORY / shared).is_symlink(),
                'Shared qualification input is not a regular file')
        committed = output(['git', '-C', REPOSITORY, 'show', revision + ':' + shared])
        digest = sha256(REPOSITORY / shared)
        require(digest == hashlib.sha256(committed).hexdigest(), 'Shared qualification input differs from its committed bytes')
        fingerprints[shared] = digest
    return revision, fingerprints


def install(args, evidence, *, allowed_paths=None):
    installed = Path('/Applications/NexGenVideo.app')
    require(not installed.exists(), 'Refusing to replace an already installed app')
    packaging = retained_packaging.file_binding(args)
    test_revision, test_files = test_source_identity(args.source_sha, allowed_paths=allowed_paths, packaging=packaging)
    identity = {'schema': 'nexgenvideo/external-gui-input/1', 'sourceSHA': args.source_sha,
                'testSourceSHA': test_revision, 'testFiles': test_files,
                'scale': args.scale, 'runID': os.environ.get('GITHUB_RUN_ID'),
                'runAttempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
                'osVersion': output(['sw_vers', '-productVersion']).decode().strip()}
    if packaging is not None:
        require(args.dmg, 'Packaging acceptance requires the exact final DMG')
        final = retained_packaging.consumer_record(packaging, args.source_sha)['final']
        require(args.dmg_sha256 == final['dmgSHA256'], 'DMG differs from canonical packaging proof')
        require(retained_packaging.consumer_binding(packaging['producerRunID'], args.source_sha, packaging['selectors'],
                archive_root=evidence / 'packaging-provenance') == packaging, 'GUI packaging evidence changed')
        identity.update(schema='nexgenvideo/external-gui-input/2', packaging=packaging)
        write_json(evidence / 'packaging-consumer.json', packaging)
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
            if getattr(args, 'scenario', None) == LOCAL_MUSICVIDEO:
                packs = list(mount.glob('*.ngvpack'))
                require(len(packs) == 1 and packs[0].name == 'musicvideo.ngvpack'
                        and not packs[0].is_symlink() and tree_sha256(packs[0]) == LOCAL_PACK_TREE,
                        'The exact mounted DMG does not contain the qualified external pack')
                guide = mount / 'Install NexGenVideo.txt'
                require(guide.is_file() and not guide.is_symlink()
                        and sha256(guide) == sha256(REPOSITORY / 'scripts/Install NexGenVideo.txt'),
                        'The actual DMG installation guide differs from the reviewed guide')
                external = evidence / 'musicvideo.ngvpack'
                command(['ditto', packs[0], external], evidence / 'install.log', timeout=120)
                require(tree_sha256(external) == LOCAL_PACK_TREE, 'DMG pack copy changed')
                from compiled_app_release import verify_pack_copy
                from compiled_core_reuse import persist
                pack_reuse = verify_pack_copy(external, 'local-dmg', dmg=dmg, evidence=evidence,
                    binding={'sourceSHA': args.source_sha, 'dmgSHA256': args.dmg_sha256,
                        'appTreeSHA256': identity['app']['treeSHA256'], 'guideSHA256': sha256(guide),
                        **({'packaging': identity['packaging']} if 'packaging' in identity else {})})
                persist(evidence / 'pack-source-signature.log', pack_reuse)
                identity['externalPack'] = {'origin': 'mounted-dmg', 'filename': external.name,
                    'treeSHA256': LOCAL_PACK_TREE, 'dmgSHA256': args.dmg_sha256, 'guideSHA256': sha256(guide),
                    'verificationReuseSHA256': sha256(evidence / 'pack-source-signature.log')}

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


def color_error(report):
    require(isinstance(report, dict) and report.get('schema') == 'nexgenvideo/export-color-diagnostic/1'
            and report.get('classification') == 'native-decoder-color-observation-only'
            and report.get('readFailures') == {}
            and report.get('commonRec709ComparisonAvailable') is True
            and report.get('commonOutputColorSpace') == 'kCGColorSpaceITUR_709',
            'The native comparison did not establish a common Rec.709 color space')
    for role, filename in [('source', 'GUI acceptance source.mp4'), ('export', 'user-export.mp4')]:
        sample = report.get(role, {})
        require(isinstance(sample, dict) and sample.get('filename') == filename
                and type(sample.get('sampleTimeSeconds')) in (int, float) and sample['sampleTimeSeconds'] == 1
                and sample.get('dimensions') == [320, 180] and sample.get('hasEffectiveCIColorSpace') is True
                and sample.get('commonRec709Available') is True
                and isinstance(sample.get('effectiveCIColorSpace'), str) and sample['effectiveCIColorSpace'],
                'The native color comparison has an incomplete or different sample')
    error = report.get('nativeCommonRec709RGBMAE')
    require(type(error) in (int, float) and math.isfinite(error) and 0 <= error < 15,
            'Exported pixels differ from the imported source in the same Rec.709 color space')
    return error


def validate_color_evidence(evidence, movie, source_files):
    proof = movie['colorComparison']
    require(isinstance(source_files.get(COLOR_HELPER), str)
            and re.fullmatch('[a-f0-9]{64}', source_files[COLOR_HELPER])
            and proof.get('reportSHA256') == sha256(evidence / 'native-color.json')
            and proof.get('helperSHA256') == source_files.get(COLOR_HELPER)
            and proof.get('executableSHA256') == sha256(evidence / 'native-color-check'),
            'Native color comparison provenance changed')
    require(sha256(evidence / 'GUI acceptance source.mp4') == proof.get('sourceSHA256') == movie['sourceSHA256']
            and sha256(evidence / 'user-export.mp4') == proof.get('exportSHA256') == movie['sha256'],
            'Native color comparison belongs to different video bytes')
    require(type(movie.get('meanAbsoluteChannelError')) in (int, float)
            and movie['meanAbsoluteChannelError'] == color_error(read_json(evidence / 'native-color.json'))
            and movie.get('maximumMeanAbsoluteChannelError') == 15 and movie.get('sampleTimeSeconds') == 1,
            'Qualified color comparison changed')


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
    unmanaged_error = sum(abs(a - b) for a, b in zip(*frames)) / len(frames[0])
    require(source.resolve(strict=True) == (evidence / 'GUI acceptance source.mp4').resolve(strict=True)
            and movie.resolve(strict=True) == (evidence / 'user-export.mp4').resolve(strict=True),
            'The native comparison input paths differ from the actual journey')
    source_hash, movie_hash = sha256(source), sha256(movie)
    helper_hash = sha256(REPOSITORY / COLOR_HELPER)
    executable = evidence / 'native-color-check'
    command(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', REPOSITORY / COLOR_HELPER,
             '-o', executable], evidence / 'native-color-compiler.log', timeout=90)
    command([executable, evidence], evidence / 'native-color-runtime.log', timeout=40)
    require(sha256(REPOSITORY / COLOR_HELPER) == helper_hash, 'Native comparison helper changed during execution')
    error = color_error(read_json(evidence / 'native-color.json'))
    result = {'sha256': movie_hash, 'sourceSHA256': source_hash, 'sampleTimeSeconds': 1,
            'meanAbsoluteChannelError': error, 'maximumMeanAbsoluteChannelError': 15,
            'unmanagedFFmpegMeanAbsoluteChannelError': unmanaged_error,
            'colorComparison': {'reportSHA256': sha256(evidence / 'native-color.json'),
                                'helperSHA256': helper_hash, 'executableSHA256': sha256(executable),
                                'sourceSHA256': source_hash, 'exportSHA256': movie_hash},
            'frames': {name: sha256(evidence / name) for name in ['source-frame.png', 'export-frame.png']}}
    validate_color_evidence(evidence, result, {COLOR_HELPER: helper_hash})
    return result


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


FRESH_MUSICVIDEO = 'normal-fresh-musicvideo'
LOCAL_MUSICVIDEO = 'normal-fresh-local-musicvideo'
LOCAL_PACK_ZIP_SHA = '37fcee05d1ac334b20eb392c61cc3b7a94af165dc3b967c61602bc79d6dc4388'
LOCAL_PACK_TREE = '365e9a75174191359bb36b02b429a4bfea55f0b764caa81184228bd3072c402e'
LOCAL_STAGES = ['fresh-profile', 'home', 'settings', 'local-pack-panel', 'installed-and-activated',
                'new-musicvideo-project', 'track-intake']
CATALOG_URL = 'https://github.com/iret77/nexgenvideo/releases/download/plugins/catalog.json'
FRESH_STAGES = ['fresh-profile', 'home', 'settings', 'catalog-card', 'installed-and-activated',
                'new-musicvideo-project', 'track-intake']


def fresh_catalog(raw, expected_catalog, expected_pack):
    require(re.fullmatch('[a-f0-9]{64}', expected_catalog or '')
            and re.fullmatch('[a-f0-9]{64}', expected_pack or '')
            and hashlib.sha256(raw).hexdigest() == expected_catalog, 'The normal catalog differs from its reviewed bytes')
    catalog = json.loads(raw)
    require(catalog.get('schema') == 'plugins/v2' and isinstance(catalog.get('plugins'), list), 'Unsupported normal catalog')
    matches = [item for item in catalog['plugins'] if item.get('id') == 'musicvideo' and item.get('version') == '0.6.0']
    require(len(matches) == 1, 'Missing or ambiguous Musicvideo0.6.0 catalog entry')
    entry = matches[0]
    require(entry.get('minAppVersion') == '1.8.0' and entry.get('projectSchema') == 'musicvideo/3.0.0'
            and entry.get('sha256') == expected_pack
            and entry.get('url') == 'https://github.com/iret77/nexgenvideo/releases/download/plugins/musicvideo-0.6.0.ngvpack.zip',
            'The normal catalog selects a different signed pack')
    return entry


def local_catalog(raw, expected_catalog, expected_pack):
    require(re.fullmatch('[a-f0-9]{64}', expected_catalog or '') and expected_pack == LOCAL_PACK_ZIP_SHA
            and hashlib.sha256(raw).hexdigest() == expected_catalog, 'Local-DMG catalog or original ZIP lineage differs')
    value = json.loads(raw)
    require(value.get('schema') == 'plugins/v2' and isinstance(value.get('plugins'), list), 'Unsupported actual stable catalog')
    versions = [row.get('version') for row in value['plugins'] if row.get('id') == 'musicvideo']
    require('0.5.8' in versions and all(isinstance(version, str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version)
            and tuple(map(int, version.split('.'))) < (0, 6, 0) for version in versions),
            'This local-newer-than-catalog case requires the reviewed pre0.6 catalog')
    return value


def fetch_public_bytes(url, maximum):
    require(url.startswith('https://github.com/iret77/nexgenvideo/releases/download/plugins/'), 'Unexpected pack channel')
    with urllib.request.urlopen(url, timeout=90) as response:
        require(response.status == 200 and response.url.startswith('https://'), 'Normal HTTPS retrieval failed')
        raw = response.read(maximum + 1)
    require(0 < len(raw) <= maximum, 'Public pack input exceeds its bound')
    return raw


def validate_fresh_stages(evidence):
    journey = read_json(evidence / 'journey.json')
    require(journey.get('schema') == 'nexgenvideo/external-fresh-musicvideo/1'
            and [row.get('stage') for row in journey.get('stages', [])] == FRESH_STAGES,
            'The normal Musicvideo path is incomplete or reordered')
    require(read_json(evidence / 'profile-before-launch.json').get('installedEntries') == 0
            and journey['stages'][0].get('installedEntries') == 0, 'The profile was not fresh')
    for row in journey['stages']:
        proof = row.get('evidence', {})
        for key in ('screenshot', 'accessibility'):
            name = proof.get(key, '')
            require(name and Path(name).name == name and sha256(evidence / name) == proof.get(key + 'SHA256'),
                    'Missing original screenshot or accessibility evidence')
        require((evidence / proof['screenshot']).read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
                and (evidence / proof['accessibility']).stat().st_size > 0, 'Unreadable native visual evidence')
    settings = journey['stages'][2]
    require(settings.get('scaleLabel') == SCALES['1.5'] and SCALES['1.5'] in settings.get('selectedValue', ''),
            'The normal installation did not use the actual150% setting')
    for row in (journey['stages'][4], journey['stages'][5]):
        require(row.get('packID') == 'musicvideo' and row.get('version') == '0.6.0'
                and row.get('schema') == 'musicvideo/3.0.0', 'The normal path bound another pack')
    for name in ('bootstrap-binding.json', 'fresh-binding.json'):
        binding = read_json(evidence / name)
        require(binding.get('activePlugin') == 'musicvideo' and binding.get('activePluginVersion') == '0.6.0'
                and binding.get('activePluginProjectSchema') == 'musicvideo/3.0.0', 'Persisted format binding differs')
    track = journey['stages'][-1]
    require(track.get('chooseEnabled') is True and track.get('attachEnabled') is False
            and track.get('trackUploaded') is False, 'Required Track intake was bypassed')
    actions = journey.get('actions', [])
    require(len(actions) >= 12 and all(action.get('target') not in ('Attach track', 'Attach lyrics') for action in actions),
            'The bounded installation check performed an intake submission')
    return journey


def validate_local_stages(evidence):
    journey = read_json(evidence / 'journey.json')
    require(journey.get('schema') == 'nexgenvideo/external-local-musicvideo/1'
            and [row.get('stage') for row in journey.get('stages', [])] == LOCAL_STAGES,
            'The normal Musicvideo path is incomplete or reordered')
    require(read_json(evidence / 'profile-before-launch.json').get('installedEntries') == 0
            and journey['stages'][0].get('installedEntries') == 0, 'The profile was not fresh')
    for row in journey['stages']:
        proof = row.get('evidence', {})
        for key in ('screenshot', 'accessibility'):
            name = proof.get(key, '')
            require(name and Path(name).name == name and sha256(evidence / name) == proof.get(key + 'SHA256'),
                    'Missing original screenshot or accessibility evidence')
        require((evidence / proof['screenshot']).read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
                and (evidence / proof['accessibility']).stat().st_size > 0, 'Unreadable native visual evidence')
    panel = journey['stages'][3]
    require(panel.get('packOrigin') == 'mounted-dmg' and panel.get('packFilename') == 'musicvideo.ngvpack',
            'Normal local installer did not select the exact external DMG pack')
    settings = journey['stages'][2]
    require(settings.get('scaleLabel') == SCALES['1.5'] and SCALES['1.5'] in settings.get('selectedValue', ''),
            'The normal installation did not use the actual150% setting')
    for row in (journey['stages'][4], journey['stages'][5]):
        require(row.get('packID') == 'musicvideo' and row.get('version') == '0.6.0'
                and row.get('schema') == 'musicvideo/3.0.0', 'The normal path bound another pack')
    for name in ('fresh-binding.json',):
        binding = read_json(evidence / name)
        require(binding.get('activePlugin') == 'musicvideo' and binding.get('activePluginVersion') == '0.6.0'
                and binding.get('activePluginProjectSchema') == 'musicvideo/3.0.0', 'Persisted format binding differs')
    track = journey['stages'][-1]
    require(track.get('chooseEnabled') is True and track.get('attachEnabled') is False
            and track.get('trackUploaded') is False, 'Required Track intake was bypassed')
    actions = journey.get('actions', [])
    require(len(actions) >= 12 and all(action.get('target') not in ('Attach track', 'Attach lyrics') for action in actions),
            'The bounded installation check performed an intake submission')
    return journey


def verify_downloaded_pack(raw, bundle):
    expected = {}
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        require(archive.testzip() is None, 'Published pack ZIP is incomplete')
        for item in archive.infolist():
            if item.is_dir() or item.filename.startswith('__MACOSX/'): continue
            parts = Path(item.filename).parts
            roots = [index for index, name in enumerate(parts) if name.endswith('.ngvpack')]
            require(len(roots) == 1 and '..' not in parts and not item.filename.startswith('/'), 'Unexpected pack archive path')
            relative = Path(*parts[roots[0] + 1:]).as_posix()
            require(relative and relative not in expected, 'Duplicate pack archive member')
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode):
                value = archive.read(item).decode()
                require(not value.startswith('/') and not posixpath.normpath(posixpath.join(posixpath.dirname(relative), value)).startswith('../'),
                        'Pack symlink escapes its bundle')
                expected[relative] = ('symlink', value)
            else:
                expected[relative] = ('file', hashlib.sha256(archive.read(item)).hexdigest())
    actual = {}
    for path in bundle.rglob('*'):
        if path.is_dir() and not path.is_symlink(): continue
        relative = path.relative_to(bundle).as_posix()
        require(path.resolve(strict=True).is_relative_to(bundle.resolve()), 'Installed pack escapes its bundle')
        actual[relative] = ('symlink', os.readlink(path)) if path.is_symlink() else ('file', sha256(path))
    require(actual == expected and bool(actual), 'Installed pack differs from the published exact ZIP')
    return hashlib.sha256(json.dumps(sorted(actual.items()), separators=(',', ':')).encode()).hexdigest()


def run_fresh_musicvideo(args):
    import test_bundle
    require(args.dmg and not args.app and args.scale == '1.5', 'Fresh Musicvideo requires the exact DMG at150%')
    require(not any(name.startswith('NGV_') and ('ACCEPTANCE' in name or 'SELFTEST' in name or 'EXAMPLE' in name)
                    for name in os.environ), 'Internal acceptance flags must not reach the normal app')
    evidence = Path(args.evidence).resolve(); evidence.mkdir(parents=True, exist_ok=False)
    require(not CONFIG.exists(), 'This VM already has an external GUI configuration')
    result = {'schema': 'nexgenvideo/external-fresh-musicvideo-result/1', 'completed': False, 'sourceSHA': args.source_sha}
    write_json(evidence / 'result.json', result)
    try:
        runtime_environment(evidence)
        app, identity = install(args, evidence)
        with (app / 'Contents/Info.plist').open('rb') as stream: info = plistlib.load(stream)
        require(info.get('NGVPluginCatalogURL') == CATALOG_URL, 'The installed app overrides the stable catalog')
        before = fetch_public_bytes(CATALOG_URL, 1024 * 1024)
        entry = fresh_catalog(before, args.expected_catalog_sha256, args.expected_pack_sha256)
        (evidence / 'catalog-before.json').write_bytes(before)
        runtime = Path(args.test_runtime).resolve(strict=True)
        require(re.fullmatch('[a-f0-9]{64}', args.test_producer_sha256 or '')
                and sha256(runtime / 'tests-producer.json') == args.test_producer_sha256, 'External client producer changed')
        for name in ('tests.tar.gz', 'tests-input.json', 'tests-producer.json'): shutil.copy2(runtime / name, evidence / name)
        work = Path(tempfile.mkdtemp(prefix='ngv-fresh-musicvideo-'))
        xctestrun, tests = test_bundle.consume(evidence, work / 'Products', identity['testSourceSHA'], identity['testFiles'])
        identity['testBundle'] = {key: tests[key] for key in ('runID', 'attempt', 'archiveSHA256', 'productsSHA256', 'xctestrun', 'xcode')}
        identity['testBundle'].update(receiptSHA256=sha256(evidence / 'tests-input.json'), producerSHA256=sha256(evidence / 'tests-producer.json'))
        write_json(evidence / 'identity.json', identity)
        config = {'scenario': FRESH_MUSICVIDEO, 'app': str(app), 'evidence': str(evidence),
                  'bootstrapProject': str(evidence / 'Bootstrap.ngv'), 'project': str(evidence / 'Fresh Musicvideo.ngv'),
                  'scaleLabel': SCALES[args.scale]}
        with CONFIG.open('x') as stream: json.dump(config, stream)
        write_json(evidence / 'configuration.json', config)
        (evidence / 'test-bundle.sha256').write_text(sha256(xctestrun) + '\n')
        code = command(['xcodebuild', 'test-without-building', '-xctestrun', xctestrun,
                        '-only-testing:NexGenVideoExternalUITests/UserJourneyTests/testNormalFreshMusicvideoThroughInstalledApp',
                        '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
                        '-resultBundlePath', evidence / 'tests.xcresult'], evidence / 'tests.log', timeout=720, check=False)
        result['exitCode'] = code
        command(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', evidence / 'tests.xcresult',
                 '--output-path', evidence / 'attachments'], evidence / 'results.log')
        summary = json.loads(output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', evidence / 'tests.xcresult']))
        write_json(evidence / 'summary.json', summary)
        require(code == 0 and summary.get('passedTests') == 1 and summary.get('failedTests') == 0
                and summary.get('skippedTests') == 0, 'Exactly one normal Musicvideo test must execute and pass')
        validate_fresh_stages(evidence)
        after = fetch_public_bytes(CATALOG_URL, 1024 * 1024)
        fresh_catalog(after, args.expected_catalog_sha256, args.expected_pack_sha256)
        require(after == before, 'Normal catalog changed during installation')
        (evidence / 'catalog-after.json').write_bytes(after)
        raw = fetch_public_bytes(entry['url'], 512 * 1024 * 1024)
        require(hashlib.sha256(raw).hexdigest() == args.expected_pack_sha256, 'Published pack archive changed')
        (evidence / 'published-pack.zip').write_bytes(raw)
        bundle = Path.home() / 'Library/Application Support/NexGenVideo/Plugins/musicvideo/0.6.0.ngvpack'
        pack_tree = verify_downloaded_pack(raw, bundle)
        shutil.copytree(bundle, evidence / 'installed-pack', symlinks=True)
        require(verify_downloaded_pack(raw, evidence / 'installed-pack') == pack_tree, 'Installed pack evidence changed while copying')
        command(['codesign', '--verify', '--deep', '--strict', bundle], evidence / 'pack-signature.log')
        require(metadata(app, args.source_sha) == identity['app'], 'The normal app changed during installation')
        result.update(completed=True, identitySHA256=sha256(evidence / 'identity.json'), runtimeSHA256=sha256(evidence / 'runtime.json'),
                      journeySHA256=sha256(evidence / 'journey.json'), mode=identity['mode'], dmgSHA256=identity['dmgSHA256'],
                      catalogSHA256=args.expected_catalog_sha256, packSHA256=args.expected_pack_sha256, packTreeSHA256=pack_tree,
                      packSignatureLogSHA256=sha256(evidence / 'pack-signature.log'))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result['error'] = str(error); raise
    finally:
        try: stop_owned_app(evidence)
        except (OSError, ValueError, subprocess.SubprocessError) as error: result.update(completed=False, cleanupError=str(error))
        write_json(evidence / 'result.json', result)


def run_local_musicvideo(args):
    import test_bundle
    require(args.dmg and not args.app and args.scale == '1.5', 'Fresh Musicvideo requires the exact DMG at150%')
    require(not any(name.startswith('NGV_') and ('ACCEPTANCE' in name or 'SELFTEST' in name or 'EXAMPLE' in name)
                    for name in os.environ), 'Internal acceptance flags must not reach the normal app')
    evidence = Path(args.evidence).resolve(); evidence.mkdir(parents=True, exist_ok=False)
    require(not CONFIG.exists(), 'This VM already has an external GUI configuration')
    result = {'schema': 'nexgenvideo/external-local-musicvideo-result/1', 'completed': False, 'sourceSHA': args.source_sha}
    write_json(evidence / 'result.json', result)
    try:
        runtime_environment(evidence)
        app, identity = install(args, evidence)
        with (app / 'Contents/Info.plist').open('rb') as stream: info = plistlib.load(stream)
        require(info.get('NGVPluginCatalogURL') == CATALOG_URL, 'The installed app overrides the stable catalog')
        before = fetch_public_bytes(CATALOG_URL, 1024 * 1024)
        local_catalog(before, args.expected_catalog_sha256, args.expected_pack_sha256)
        (evidence / 'catalog-before.json').write_bytes(before)
        runtime = Path(args.test_runtime).resolve(strict=True)
        require(re.fullmatch('[a-f0-9]{64}', args.test_producer_sha256 or '')
                and sha256(runtime / 'tests-producer.json') == args.test_producer_sha256, 'External client producer changed')
        for name in ('tests.tar.gz', 'tests-input.json', 'tests-producer.json'): shutil.copy2(runtime / name, evidence / name)
        work = Path(tempfile.mkdtemp(prefix='ngv-fresh-musicvideo-'))
        xctestrun, tests = test_bundle.consume(evidence, work / 'Products', identity['testSourceSHA'], identity['testFiles'])
        identity['testBundle'] = {key: tests[key] for key in ('runID', 'attempt', 'archiveSHA256', 'productsSHA256', 'xctestrun', 'xcode')}
        identity['testBundle'].update(receiptSHA256=sha256(evidence / 'tests-input.json'), producerSHA256=sha256(evidence / 'tests-producer.json'))
        write_json(evidence / 'identity.json', identity)
        config = {'scenario': LOCAL_MUSICVIDEO, 'app': str(app), 'evidence': str(evidence),
                  'externalPack': str(evidence / 'musicvideo.ngvpack'), 'project': str(evidence / 'Fresh Musicvideo.ngv'),
                  'scaleLabel': SCALES[args.scale]}
        with CONFIG.open('x') as stream: json.dump(config, stream)
        write_json(evidence / 'configuration.json', config)
        (evidence / 'test-bundle.sha256').write_text(sha256(xctestrun) + '\n')
        code = command(['xcodebuild', 'test-without-building', '-xctestrun', xctestrun,
                        '-only-testing:NexGenVideoExternalUITests/UserJourneyTests/testNormalFreshLocalMusicvideoFromDMGThroughInstalledApp',
                        '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
                        '-resultBundlePath', evidence / 'tests.xcresult'], evidence / 'tests.log', timeout=720, check=False)
        result['exitCode'] = code
        command(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', evidence / 'tests.xcresult',
                 '--output-path', evidence / 'attachments'], evidence / 'results.log')
        summary = json.loads(output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', evidence / 'tests.xcresult']))
        write_json(evidence / 'summary.json', summary)
        require(code == 0 and summary.get('passedTests') == 1 and summary.get('failedTests') == 0
                and summary.get('skippedTests') == 0, 'Exactly one normal Musicvideo test must execute and pass')
        validate_local_stages(evidence)
        after = fetch_public_bytes(CATALOG_URL, 1024 * 1024)
        local_catalog(after, args.expected_catalog_sha256, args.expected_pack_sha256)
        require(after == before, 'Normal catalog changed during installation')
        (evidence / 'catalog-after.json').write_bytes(after)
        bundle = Path.home() / 'Library/Application Support/NexGenVideo/Plugins/musicvideo/0.6.0.ngvpack'
        require(identity.get('externalPack', {}).get('origin') == 'mounted-dmg'
                and identity['externalPack'].get('dmgSHA256') == args.dmg_sha256
                and identity['externalPack'].get('treeSHA256') == LOCAL_PACK_TREE,
                'Normal local installation lost exact mounted-DMG provenance')
        pack_tree = tree_sha256(bundle)
        require(pack_tree == tree_sha256(evidence / 'musicvideo.ngvpack') == LOCAL_PACK_TREE,
                'Installed local pack differs from the actual mounted DMG payload')
        shutil.copytree(bundle, evidence / 'installed-pack', symlinks=True)
        require(tree_sha256(evidence / 'installed-pack') == pack_tree, 'Installed local pack evidence changed')
        from compiled_app_release import verify_pack_copy
        from compiled_core_reuse import persist
        pack_reuse = verify_pack_copy(bundle, 'local-installed', dmg=Path(args.dmg), evidence=evidence,
            binding={'sourceSHA': args.source_sha, 'dmgSHA256': args.dmg_sha256,
                'appTreeSHA256': identity['app']['treeSHA256'], 'guideSHA256': identity['externalPack']['guideSHA256'],
                **({'packaging': identity['packaging']} if 'packaging' in identity else {})})
        persist(evidence / 'pack-signature.log', pack_reuse)
        require(metadata(app, args.source_sha) == identity['app'], 'The normal app changed during installation')
        result.update(completed=True, identitySHA256=sha256(evidence / 'identity.json'), runtimeSHA256=sha256(evidence / 'runtime.json'),
                      journeySHA256=sha256(evidence / 'journey.json'), mode=identity['mode'], dmgSHA256=identity['dmgSHA256'],
                      catalogSHA256=args.expected_catalog_sha256, packSHA256=args.expected_pack_sha256, packTreeSHA256=pack_tree,
                      packSignatureLogSHA256=sha256(evidence / 'pack-signature.log'))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        result['error'] = str(error); raise
    finally:
        try: stop_owned_app(evidence)
        except (OSError, ValueError, subprocess.SubprocessError) as error: result.update(completed=False, cleanupError=str(error))
        write_json(evidence / 'result.json', result)


def validate_fresh_musicvideo(args):
    import test_bundle
    evidence = Path(args.evidence).resolve(strict=True)
    result, identity = read_json(evidence / 'result.json'), read_json(evidence / 'identity.json')
    require(result.get('schema') == 'nexgenvideo/external-fresh-musicvideo-result/1' and result.get('completed') is True
            and result.get('exitCode') == 0 and result.get('sourceSHA') == identity.get('sourceSHA') == args.source_sha,
            'Incomplete normal Musicvideo evidence')
    require(args.scale == '1.5' and args.dmg_sha256, 'Fresh Musicvideo needs the exact DMG at150%')
    validate_app_identity(evidence, result, identity, args.source_sha, args.scale, args.dmg_sha256)
    validate_runtime(evidence)
    require(retained_packaging.file_binding(args) == identity.get('packaging'), 'Fresh Musicvideo packaging identity changed')
    revision, files = test_source_identity(args.source_sha, packaging=identity.get('packaging'))
    require(identity['testSourceSHA'] == revision and identity['testFiles'] == files, 'Fresh Musicvideo client source changed')
    tests = test_bundle.verify_input(evidence, revision, files)
    expected = {key: tests[key] for key in ('runID', 'attempt', 'archiveSHA256', 'productsSHA256', 'xctestrun', 'xcode')}
    expected.update(receiptSHA256=sha256(evidence / 'tests-input.json'), producerSHA256=sha256(evidence / 'tests-producer.json'))
    require(identity.get('testBundle') == expected, 'Fresh Musicvideo client provenance changed')
    with tempfile.TemporaryDirectory(prefix='ngv-validate-fresh-tests-') as temporary:
        xctestrun, _ = test_bundle.consume(evidence, Path(temporary) / 'Products', revision, files)
        require((evidence / 'test-bundle.sha256').read_text().strip() == sha256(xctestrun),
                'Fresh Musicvideo xctestrun changed')
    for key, name in [('identitySHA256', 'identity.json'), ('runtimeSHA256', 'runtime.json'), ('journeySHA256', 'journey.json'),
                      ('packSignatureLogSHA256', 'pack-signature.log')]:
        require(result.get(key) == sha256(evidence / name), 'Normal Musicvideo proof bytes changed: ' + name)
    fresh_catalog((evidence / 'catalog-before.json').read_bytes(), args.expected_catalog_sha256, args.expected_pack_sha256)
    fresh_catalog((evidence / 'catalog-after.json').read_bytes(), args.expected_catalog_sha256, args.expected_pack_sha256)
    require((evidence / 'catalog-before.json').read_bytes() == (evidence / 'catalog-after.json').read_bytes()
            and sha256(evidence / 'published-pack.zip') == result['packSHA256'] == args.expected_pack_sha256
            and result['catalogSHA256'] == args.expected_catalog_sha256, 'Normal catalog or published pack bytes changed')
    summary = read_json(evidence / 'summary.json')
    require(summary.get('passedTests') == 1 and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0,
            'Normal Musicvideo test did not execute exactly once')
    require(verify_downloaded_pack((evidence / 'published-pack.zip').read_bytes(), evidence / 'installed-pack')
            == result.get('packTreeSHA256'), 'Saved installed pack identity changed')
    validate_fresh_stages(evidence)
    print(json.dumps({'completed': True, 'sourceSHA': args.source_sha, 'dmgSHA256': result['dmgSHA256'],
                      'catalogSHA256': result['catalogSHA256'], 'packSHA256': result['packSHA256']}))


def validate_local_pack_reuse(evidence, identity, revision, source_sha, dmg_sha256):
    from compiled_app_release import original_pack_proof, local_pack_runtime_origin
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
            and os.environ.get('GITHUB_JOB') == 'acceptance' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
            and identity.get('runID') == os.environ.get('GITHUB_RUN_ID') and identity.get('runAttempt') == '1'
            and revision == os.environ.get('GITHUB_SHA'), 'Local pack validator belongs to another current execution')
    binding = {'sourceSHA': source_sha, 'dmgSHA256': dmg_sha256,
        'appTreeSHA256': identity.get('app', {}).get('treeSHA256'), 'guideSHA256': identity.get('externalPack', {}).get('guideSHA256'),
        **({'packaging': identity['packaging']} if 'packaging' in identity else {})}
    expected_producer = local_pack_runtime_origin(binding, expected_dmg_sha256=dmg_sha256)
    require(identity.get('externalPack', {}).get('verificationReuseSHA256') == sha256(evidence / 'pack-source-signature.log'),
            'Mounted-DMG pack admission bytes changed')
    for context, name in [('local-dmg', 'pack-source-signature.log'), ('local-installed', 'pack-signature.log')]:
        proof = read_json(evidence / name)
        producer = proof.get('runtimeProducer', {})
        require(proof.get('schema') == 'retained-pack-copy-reuse/v1' and proof.get('state') == 'REUSED'
                and proof.get('context') == context and proof.get('original') == original_pack_proof()
                and proof.get('currentSourceSHA') == revision and proof.get('currentRunID') == int(identity['runID'])
                and proof.get('currentAttempt') == 1 and proof.get('currentJob') == 'acceptance'
                and proof.get('packTreeSHA256') == LOCAL_PACK_TREE and proof.get('rootMode') == 0o755
                and proof.get('currentDMGSHA256') == dmg_sha256
                and producer.get('sourceSHA') == source_sha
                and producer == expected_producer
                and type(producer.get('runID')) is int and producer['runID'] > 0
                and type(producer.get('artifactID')) is int and producer['artifactID'] > 0
                and re.fullmatch('[a-f0-9]{64}', producer.get('artifactSHA256', ''))
                and producer.get('intakeBinding', {}).get('dmgSHA256') == dmg_sha256
                and proof.get('currentNativeCodesignOrStaplerPerformed') is False
                and proof.get('currentPackNotarizationPerformed') is False
                and proof.get('freshTrustStoreOrRevocationClaimed') is False
                and proof.get('newAppPackLoadQualified') is False,
                'Local pack proof is not its exact qualified reuse admission')
        require(read_json(evidence / 'pack-reuse' / (context + '.json')) == proof,
                'Local pack reuse record differs from its durable admission')


def validate_local_musicvideo(args):
    import test_bundle
    evidence = Path(args.evidence).resolve(strict=True)
    result, identity = read_json(evidence / 'result.json'), read_json(evidence / 'identity.json')
    require(result.get('schema') == 'nexgenvideo/external-local-musicvideo-result/1' and result.get('completed') is True
            and result.get('exitCode') == 0 and result.get('sourceSHA') == identity.get('sourceSHA') == args.source_sha,
            'Incomplete normal Musicvideo evidence')
    require(args.scale == '1.5' and args.dmg_sha256, 'Fresh Musicvideo needs the exact DMG at150%')
    validate_app_identity(evidence, result, identity, args.source_sha, args.scale, args.dmg_sha256)
    validate_runtime(evidence)
    require(retained_packaging.file_binding(args) == identity.get('packaging'), 'Fresh Musicvideo packaging identity changed')
    revision, files = test_source_identity(args.source_sha, packaging=identity.get('packaging'))
    require(identity['testSourceSHA'] == revision and identity['testFiles'] == files, 'Fresh Musicvideo client source changed')
    tests = test_bundle.verify_input(evidence, revision, files)
    expected = {key: tests[key] for key in ('runID', 'attempt', 'archiveSHA256', 'productsSHA256', 'xctestrun', 'xcode')}
    expected.update(receiptSHA256=sha256(evidence / 'tests-input.json'), producerSHA256=sha256(evidence / 'tests-producer.json'))
    require(identity.get('testBundle') == expected, 'Fresh Musicvideo client provenance changed')
    with tempfile.TemporaryDirectory(prefix='ngv-validate-fresh-tests-') as temporary:
        xctestrun, _ = test_bundle.consume(evidence, Path(temporary) / 'Products', revision, files)
        require((evidence / 'test-bundle.sha256').read_text().strip() == sha256(xctestrun),
                'Fresh Musicvideo xctestrun changed')
    for key, name in [('identitySHA256', 'identity.json'), ('runtimeSHA256', 'runtime.json'), ('journeySHA256', 'journey.json'),
                      ('packSignatureLogSHA256', 'pack-signature.log')]:
        require(result.get(key) == sha256(evidence / name), 'Normal Musicvideo proof bytes changed: ' + name)
    validate_local_pack_reuse(evidence, identity, revision, args.source_sha, args.dmg_sha256)
    local_catalog((evidence / 'catalog-before.json').read_bytes(), args.expected_catalog_sha256, args.expected_pack_sha256)
    local_catalog((evidence / 'catalog-after.json').read_bytes(), args.expected_catalog_sha256, args.expected_pack_sha256)
    require((evidence / 'catalog-before.json').read_bytes() == (evidence / 'catalog-after.json').read_bytes()
            and result['packSHA256'] == args.expected_pack_sha256 == LOCAL_PACK_ZIP_SHA
            and result['catalogSHA256'] == args.expected_catalog_sha256, 'Normal catalog or published pack bytes changed')
    summary = read_json(evidence / 'summary.json')
    require(summary.get('passedTests') == 1 and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0,
            'Normal Musicvideo test did not execute exactly once')
    require(tree_sha256(evidence / 'installed-pack') == tree_sha256(evidence / 'musicvideo.ngvpack')
            == result.get('packTreeSHA256') == LOCAL_PACK_TREE
            and identity.get('externalPack', {}).get('origin') == 'mounted-dmg'
            and identity['externalPack'].get('dmgSHA256') == result['dmgSHA256']
            and identity['externalPack'].get('treeSHA256') == LOCAL_PACK_TREE,
            'Local installed pack is not the exact current DMG payload')
    validate_local_stages(evidence)
    print(json.dumps({'completed': True, 'sourceSHA': args.source_sha, 'dmgSHA256': result['dmgSHA256'],
                      'catalogSHA256': result['catalogSHA256'], 'packSHA256': result['packSHA256']}))


def run(args):
    if getattr(args, 'scenario', 'journey') == LOCAL_MUSICVIDEO:
        return run_local_musicvideo(args)
    if getattr(args, 'scenario', 'journey') == FRESH_MUSICVIDEO:
        return run_fresh_musicvideo(args)
    require(not getattr(args, 'expected_catalog_sha256', None) and not getattr(args, 'expected_pack_sha256', None),
            'Normal journey cannot ignore Musicvideo selectors')
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
        xctestrun, tests = test_bundle.consume(evidence, work / 'Products', identity['testSourceSHA'], identity['testFiles'])
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
                        '-only-testing:NexGenVideoExternalUITests/UserJourneyTests/testGenericEditingThroughInstalledApp',
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
    schema = 'nexgenvideo/external-gui-input/1'
    if identity.get('schema') == 'nexgenvideo/external-gui-input/2':
        record = retained_packaging.consumer_record(identity.get('packaging'), source_sha)
        require(dmg_sha256 == record['final']['dmgSHA256']
                and identity.get('app') == record['final']['app'], 'GUI identity differs from canonical packaging proof')
        schema = 'nexgenvideo/external-gui-input/2'
    else:
        require('packaging' not in identity, 'Packaging GUI identity requires its explicit schema')
    require(identity.get('schema') == schema
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
    if getattr(args, 'scenario', 'journey') == LOCAL_MUSICVIDEO:
        return validate_local_musicvideo(args)
    if getattr(args, 'scenario', 'journey') == FRESH_MUSICVIDEO:
        return validate_fresh_musicvideo(args)
    require(not getattr(args, 'expected_catalog_sha256', None) and not getattr(args, 'expected_pack_sha256', None),
            'Normal journey cannot ignore Musicvideo selectors')
    import test_bundle

    evidence = Path(args.evidence).resolve(strict=True)
    result = read_json(evidence / 'result.json')
    identity = read_json(evidence / 'identity.json')
    require(result.get('schema') == 'nexgenvideo/external-gui-result/1' and result.get('completed') is True
            and result.get('exitCode') == 0,
            'External GUI evidence is incomplete')
    require(result['sourceSHA'] == identity['sourceSHA'] == args.source_sha,
            'Evidence belongs to another source revision')
    validate_app_identity(evidence, result, identity, args.source_sha, args.scale, args.dmg_sha256)
    require(result['identitySHA256'] == sha256(evidence / 'identity.json')
            and result['journeySHA256'] == sha256(evidence / 'journey.json'), 'Evidence bytes changed')
    require(result.get('runtimeSHA256') == sha256(evidence / 'runtime.json'), 'Runtime evidence changed')
    validate_runtime(evidence)
    supplied = retained_packaging.file_binding(args)
    require(supplied == identity.get('packaging'), 'GUI packaging selectors changed after execution')
    test_revision, source_files = test_source_identity(args.source_sha, packaging=supplied)
    require(identity.get('testSourceSHA') == test_revision and identity.get('testFiles') == source_files,
            'Qualified test source identity changed')
    tests = test_bundle.verify_input(evidence, test_revision, source_files)
    expected = {key: tests[key] for key in ('runID', 'attempt', 'archiveSHA256', 'productsSHA256', 'xctestrun', 'xcode')}
    expected.update(receiptSHA256=sha256(evidence / 'tests-input.json'),
                    producerSHA256=sha256(evidence / 'tests-producer.json'))
    require(identity.get('testBundle') == expected, 'UI test bundle provenance changed')
    with tempfile.TemporaryDirectory(prefix='ngv-validate-tests-') as temporary:
        xctestrun, _ = test_bundle.consume(evidence, Path(temporary) / 'Products', test_revision, source_files)
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
    validate_color_evidence(evidence, result['export'], source_files)
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
    for command in (execute, check):
        command.add_argument('--scenario', choices=('journey', FRESH_MUSICVIDEO, LOCAL_MUSICVIDEO), default='journey')
        command.add_argument('--expected-catalog-sha256')
        command.add_argument('--expected-pack-sha256')
        command.add_argument('--packaging-binding', type=Path)
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
