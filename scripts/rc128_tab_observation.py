"""Measure the first camera-name Tab in the unchanged, filtered RC128 AppKit test."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import struct
import subprocess
import sys
import tempfile

from isolated_test_home import environment as isolated_home
from native_app_failure_diagnostic import measure, scope_filter
from run_macos_tests import app_environment, write_json

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = '28aeb663d3e7cfc2d75bf73ca3de7cd2c1081136'
TEST_SHA = '9c276833f894d5755d08b447c7db62842be2fda75b9dc50a771d1c264c4eb27b'
SWIFTC_SHA = '020a521df9efc127b6817a2ed2f1560155108f0a0ead1ee1fa98147f5944eb4f'
BANK_HOST_SHA = '70330e80bf88fa7e23032d80b9b2df2b855e9baaa00c87c1195a5093edc333f5'
SWIFT = ROOT / 'Tests/AppKitTestHost/AppKitTestHost.swift'
SUPPORT = ROOT / 'Tests/AppKitTestHostSupport/AppKitTestHostSupport.m'
HEADER = SUPPORT.parent / 'include/AppKitTestHostSupport.h'
PROBE = Path(__file__).with_suffix('.m')
TEST_ID = ('NexGenVideoTests.NativePointerInteractionTests/canonicalNativeAccessibilityHitKeepsSystemInputAndRealFieldFocus()'
           '/NativeButtonInteractionTests.swift:1767:6')
ORIGINALS = {SWIFT: '6e8a82fc31bb4a2c122ef68955cdd74f6abaa1071605a59aaad22cbecf602e14',
             SUPPORT: '4d4c03b837533e75afde728d65c2189c3ef51b7c5e8f08cb87b8381ee8004459',
             HEADER: 'f963caf32840304e80c1779eae640f002ccfd6bd92c94caa734a9565cd168d6a'}
METHODS = '''
- (void)postEvent:(NSEvent *)event atStart:(BOOL)start {
    tabPosting(event);
    [super postEvent:event atStart:start];
}
- (void)sendEvent:(NSEvent *)event {
    BOOL observed = tabDispatch(event);
    if (observed) tabRow(@"before-super", event, nil);
    [super sendEvent:event];
    if (observed) tabDispatched(event);
}
'''


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def compile_host(work, output, env):
    require(all(sha(path) == digest for path, digest in ORIGINALS.items()), 'Original AppKit host source differs')
    def resolve(*arguments):
        result = subprocess.check_output(['/usr/bin/xcrun', *arguments], env=env, stdin=subprocess.DEVNULL,
                                         text=True, timeout=30).strip()
        path = Path(result)
        require(path.is_absolute() and path.exists() and '\n' not in result, 'Unexpected Xcode tool or SDK')
        return path
    swiftc, clang, sdk = resolve('--find', 'swiftc'), resolve('--find', 'clang'), resolve('--sdk', 'macosx', '--show-sdk-path')
    require(sha(swiftc) == SWIFTC_SHA and clang.parent == swiftc.parent, 'Xcode compiler differs from the bound native build')
    module = work / 'module'
    module.mkdir()
    (module / 'AppKitTestHostSupport.h').write_bytes(HEADER.read_bytes())
    (module / 'module.modulemap').write_text('module AppKitTestHostSupport { header "AppKitTestHostSupport.h" export * }\n')
    anchor = '@implementation NGVTestRuntimeApplication\n'
    original = SUPPORT.read_text()
    require(original.count(anchor) == 1, 'Missing unique original NSApplication implementation')
    instrumented = work / SUPPORT.name
    instrumented.write_text(original.replace(anchor, '#include "rc128_tab_observation.m"\n' + anchor + METHODS))
    obj, host, target = work / 'Support.o', work / 'NexGenVideoAppKitTestHost', 'arm64-apple-macos26.0'
    commands = [
        [clang, '-target', target, '-isysroot', sdk, '-fobjc-arc', '-fmodules', '-O2', '-g',
         '-fmodules-cache-path=' + str(work / 'cache'), '-I', module, '-I', PROBE.parent, '-c', instrumented, '-o', obj],
        [swiftc, '-parse-as-library', '-swift-version', '6', '-O', '-g', '-target', target, '-sdk', sdk,
         '-module-name', 'NexGenVideoAppKitTestHost', '-module-cache-path', work / 'cache', '-I', module,
         SWIFT, obj, '-framework', 'AppKit', '-o', host],
    ]
    proof = {'sourceSHA': env['GITHUB_SHA'], 'productSHA': PRODUCT, 'testImageSHA256': TEST_SHA,
             'originals': {str(path.relative_to(ROOT)): digest for path, digest in ORIGINALS.items()},
             'observationSHA256': sha(PROBE), 'driverSHA256': sha(Path(__file__)),
             'instrumentedSupportSHA256': sha(instrumented), 'swiftcSHA256': sha(swiftc), 'clangSHA256': sha(clang),
             'commands': [[str(value) for value in command] for command in commands]}
    write_json(output / 'build.json', proof)
    with (output / 'compiler.log').open('xb') as log:
        for command in commands:
            subprocess.run(command, cwd=work, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                           timeout=120, check=True)
    proof['hostSHA256'] = sha(host)
    write_json(output / 'build.json', proof)
    return host


def fixture_tabs(raw, output):
    paths = list(raw.glob('native-pointer-canonical-tab-traversal-*/fixture-context.json'))
    if len(paths) != 1:
        return []
    context = json.loads(paths[0].read_bytes())
    progress_path = paths[0].with_name('tab-traversal.json')
    if progress_path.is_file():
        progress = json.loads(progress_path.read_bytes())
        write_json(output / 'fixture-progress.json', {'stage': progress.get('stage'),
                   'sourceSHA256': sha(progress_path), 'hasFailure': bool(progress.get('failure'))})
    rows = [{'type': 'down' if item['type'] == 10 else 'up', 'window': item['window'],
             'stampBits': struct.pack('>d', item['timestamp']).hex()}
            for item in context['keyEvents'] if item['keyCode'] == 48 and item['type'] in (10, 11)
            and item['matchesFixtureWindow']]
    write_json(output / 'fixture-tabs.json', {'sourceSHA256': sha(paths[0]), 'dropped': context['droppedKeyEvents'],
                                            'returnsOriginal': context['keyMonitorReturnsOriginalEvent'], 'tabs': rows})
    return rows if context['droppedKeyEvents'] == 0 and context['keyMonitorReturnsOriginalEvent'] is True else []


def classify(rows, original):
    def one(stage, kind):
        matches = [row for row in rows if row['stage'] == stage and row.get('type') == kind]
        return matches[0] if len(matches) == 1 else None
    pairs = [(one('post', kind), one('local', kind), one('after-super', kind)) for kind in ('down', 'up')]
    if not all(all(pair) for pair in pairs) or len(original) < 2:
        return {'decision': 'incomplete-tab-observation'}
    down, up = pairs
    if any((initial['window'], initial['stampBits'], initial['type']) != (local['eventWindow'], local['stampBits'], local['type'])
           for initial, (_, local, _) in zip(original[:2], pairs)):
        return {'decision': 'independent-fixture-monitor-disagrees'}
    if not (down[0]['ordinal'] < up[0]['ordinal'] and down[1]['ordinal'] < up[1]['ordinal'] and
            down[2]['ordinal'] < up[2]['ordinal'] and len({row['window'] for pair in pairs for row in pair}) == 1):
        return {'decision': 'inconsistent-tab-order-or-window'}
    matches = {local['type']: local['stampBits'] == local['originalBitsAtRead'] for _, local, _ in pairs}
    settled = next((row for row in rows if row['stage'] == 'settled'), None)
    ended = [row['movement'] for row in rows if row['stage'] == 'end-editing' and row['source'] == 'name']
    owner = down[1]['owner'] == 'name' and down[1]['sameEditorAsAtPost'] and down[1]['keyWindow']
    traversal = ('reached-fov' if any(row['owner'] == 'fov' for row in [down[2], up[1], up[2], settled or {'owner': ''}])
                 else 'settled-on-name' if settled and settled['owner'] == 'name' else 'other-or-unsettled')
    correlation = ('timestamp-mismatch' if not all(matches.values()) else
                   'source-owner-mismatch' if not owner else 'matched-at-independent-monitor')
    return {'decision': 'measured', 'correlation': correlation, 'exactStampMatch': matches,
            'sourceOwnedAtLocalDown': owner, 'traversal': traversal, 'ownerAfterDown': down[2]['owner'],
            'ownerAfterUp': up[2]['owner'], 'settledOwner': settled and settled['owner'], 'nameEditingEndMovements': ended,
            'nameEndedByTab': any(row.get('tabMovement') is True and row.get('source') == 'name' for row in rows)}


def run_arm(mode, host, image, runtime, work, output, base):
    folder, raw = output / mode, work / mode
    folder.mkdir()
    raw.mkdir()
    env = isolated_home(base, raw / 'home')
    env = app_environment(env, runtime, image, folder)
    env.update(NGV_APPKIT_TEST_BUNDLE=str(image), NGV_APPKIT_TEST_EVENTS=str(raw / 'events.jsonl'),
               NGV_APPKIT_TEST_RECEIPT=str(folder / 'host-receipt.json'),
               NGV_APPKIT_EXCEPTION_EVIDENCE=str(folder / 'exception.jsonl'),
               NGV_RC128_TAB_OBSERVATION=str(folder / 'tab.jsonl'))
    if mode == 'rebuild':
        env['NGV_RC128_REBUILD_LOOP'] = '1'
    command = [str(host), '--event-stream-version', '0', '--filter', scope_filter([TEST_ID]), '--no-parallel']
    with (folder / 'console.log').open('xb') as log, subprocess.Popen(
            command, env=env, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True) as process:
        try:
            code = process.wait(timeout=100)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            # Preserve the original ABI stream, even if the host stops before its receipt.
            if (raw / 'events.jsonl').is_file():
                (raw / 'events.jsonl').replace(folder / 'events.jsonl')
            fixture = fixture_tabs(raw, folder)
            write_json(folder / 'execution.json', {'pid': process.pid, 'exitCode': process.returncode, 'argv': command})
    stream = (folder / 'events.jsonl').read_bytes()
    native = measure(stream, [TEST_ID])
    receipt = json.loads((folder / 'host-receipt.json').read_bytes())
    require(receipt['pid'] == process.pid and receipt['parentPID'] == os.getpid() and
            receipt['bundleBinary'] == str(image) and receipt['hostExecutable'] == str(host)
            and receipt['sourceSHA'] == base['GITHUB_SHA'] and all(receipt[key] is True for key in
                ('completed', 'started', 'mainThread', 'applicationRunningAtStart', 'runReturnedAfterCompletion'))
            and not receipt.get('error') and not receipt.get('recordingError')
            and receipt['eventRecordCount'] == native['records'] and receipt['abiSucceeded'] is native['passed']
            and code == (0 if native['passed'] else 1), 'Native host exit or ABI receipt differs from the selected test')
    path = folder / 'tab.jsonl'
    rows = [json.loads(line) for line in path.read_bytes().splitlines()] if path.exists() else []
    require(len(rows) <= 48, 'Unbounded Tab observation')
    result = classify(rows, fixture)
    result.update(nativeExit=code, unchangedMethodPassed=native['passed'], actualMethod=TEST_ID, condition=mode,
                  originalNameTimeout=any('Tab delivery from name' in message.get('text', '')
                                          for issue in native['issues'] for message in issue.get('messages', [])))
    write_json(folder / 'result.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    for name in ('tests', 'runtime', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    require(sys.platform == 'darwin' and platform.machine() == 'arm64' and os.environ.get('GITHUB_ACTIONS') == 'true',
            'This measurement runs in the macrunner job')
    temporary = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    output = args.output.resolve()
    require(output != temporary and output.is_relative_to(temporary) and not args.output.is_symlink(), 'Use a fresh runner-temp output')
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not any(output.iterdir()), 'Diagnostic output is occupied')
    summary = {'schema': 'rc128-tab-observation/1', 'productSHA': PRODUCT, 'releaseAcceptance': False, 'complete': False}
    try:
        bundle, runtime = args.tests.resolve(strict=True), args.runtime.resolve(strict=True)
        image = bundle / 'Contents/MacOS/NexGenVideoTests'
        require(bundle.name == 'NexGenVideoTests.xctest' and not image.is_symlink() and sha(image) == TEST_SHA and
                sha(runtime / 'NexGenVideoAppKitTestHost') == BANK_HOST_SHA, 'Test image or runtime bank host differs from A1')
        base = {key: os.environ[key] for key in ('GITHUB_ACTIONS', 'GITHUB_SHA', 'DEVELOPER_DIR', 'LANG', 'TMPDIR') if key in os.environ}
        base['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
        with tempfile.TemporaryDirectory(prefix='rc128-tab-', dir=temporary) as temp:
            work = Path(temp)
            host = compile_host(work, output, isolated_home(base, work / 'build-home'))
            baseline = run_arm('passive', host, image, runtime, work, output, base)
            summary['passive'] = baseline
            write_json(output / 'summary.json', summary)
            if baseline['originalNameTimeout'] and baseline.get('traversal') == 'settled-on-name':
                summary['rebuild'] = run_arm('rebuild', host, image, runtime, work, output, base)
            require(sha(image) == TEST_SHA, 'The original test image changed')
        summary['complete'] = all(arm['decision'] == 'measured' for arm in
                                  [baseline] + ([summary['rebuild']] if 'rebuild' in summary else []))
        if not summary['complete']:
            summary['comparison'] = 'incomplete'
        elif not baseline['originalNameTimeout']:
            summary['comparison'] = 'original-name-timeout-not-reproduced'
        elif 'rebuild' not in summary:
            summary['comparison'] = 'baseline-did-not-settle-on-name'
        else:
            summary['comparison'] = {'rebuildTraversal': summary['rebuild']['traversal'],
                                     'baselineTraversal': baseline['traversal'],
                                     'correlationChanged': baseline['exactStampMatch'] != summary['rebuild']['exactStampMatch']}
        return baseline['nativeExit'] if summary['complete'] else 2
    except Exception as error:
        summary['error'] = str(error)
        raise
    finally:
        write_json(output / 'summary.json', summary)


if __name__ == '__main__':
    raise SystemExit(main())
