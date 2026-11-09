import hashlib
import json
import os
from pathlib import Path
import platform
import re
import sys

from retained_app_test_products import checksum, require, write

SOURCE = Path('scripts/native_xctest_host.m')
SUPPORT_SHA = '63964190d2cb1d274ee64635d6ec473e1fd6b9acdf216ada4f80dd6998028b60'
HOST_NAME = 'NexGenVideoXCTestHost'
INPUTS = ('scripts/native_xctest_host.m', 'scripts/native_xctest_host.py',
    'Tests/AppKitTestHostSupport/AppKitTestHostSupport.m',
    'Tests/AppKitTestHostSupport/include/AppKitTestHostSupport.h')


def inputs():
    return {name: checksum(Path(name)) for name in INPUTS}


def persist_proof(path, proof):
    with path.open('x') as stream:
        json.dump(proof, stream, sort_keys=True, indent=2)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(directory)
    finally: os.close(directory)


def build(folder, bundle, prepared, logged):
    require(sys.platform == 'darwin' and platform.machine() == 'arm64' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
        and os.environ.get('GITHUB_JOB') == 'app-target-build' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1',
        'XCTest host compilation requires the qualified owned native target job')
    helper = bundle / 'Contents/Helpers' / HOST_NAME
    require(not helper.exists() and not helper.is_symlink() and not helper.parent.is_symlink(), 'XCTest host output occupied')
    helper.parent.mkdir(exist_ok=False)
    support = Path(prepared['bankBinary']) / 'AppKitTestHostSupport.o'
    require(not support.is_symlink() and checksum(support) == SUPPORT_SHA, 'Qualified unchanged AppKit support object differs')
    compiler = Path(prepared['plans']['tests']['driver']['argv'][0]).parent / 'clang'
    argv_driver = prepared['plans']['tests']['driver']['argv']
    require(argv_driver.count('-sdk') == 1, 'Missing unique reviewed Tests SDK')
    sdk = argv_driver[argv_driver.index('-sdk') + 1]
    measured_sdk = logged('xctest-host-sdk', ['xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip()
    measured_clang = logged('xctest-host-clang', ['xcrun', '--find', 'clang']).strip()
    require(Path(measured_sdk).is_absolute() and Path(measured_sdk).resolve() == Path(sdk).resolve()
        and Path(measured_clang).is_absolute() and Path(measured_clang).resolve() == compiler.resolve()
        and checksum(Path(argv_driver[0])) == prepared['compilerSHA256'], 'XCTest host selected Xcode, compiler or SDK differs')
    frameworks = bundle / 'Contents/Frameworks'
    require(Path(sdk).is_absolute() and frameworks.is_dir(), 'XCTest host SDK or embedded runtimes missing')
    argv = [str(compiler), '-target', 'arm64-apple-macos26.0', '-isysroot', sdk, '-fobjc-arc', '-fmodules',
        '-fmodules-cache-path=' + str(folder / 'xctest-host-module-cache'), '-O2', '-g',
        '-I', 'Tests/AppKitTestHostSupport/include', '-F', str(frameworks),
        str(SOURCE), str(support), '-framework', 'AppKit', '-framework', 'XCTest',
        '-Wl,-rpath,@executable_path/../Frameworks', '-o', str(helper)]
    require(prepared.get('xctestHostInputs') == inputs(), 'Reviewed XCTest host source inputs changed')
    identity = {'schema': 'native-xctest-host-build/v1', 'sourceSHA': prepared['sourceSHA'],
        'appSourceSHA': prepared['appSourceSHA'], 'inputs': inputs(), 'supportObjectSHA256': checksum(support),
        'compilerPath': str(compiler), 'resolvedCompilerPath': str(compiler.resolve()), 'compilerSHA256': checksum(compiler),
        'sdk': sdk, 'resolvedSDK': str(Path(sdk).resolve()), 'measuredSDK': measured_sdk, 'measuredClang': measured_clang, 'argv': argv}
    write(folder / 'xctest-host-build-inputs.json', identity)
    logged('xctest-host-compile-link', argv)
    require(helper.is_file() and not helper.is_symlink(), 'Native XCTest host did not materialize')
    require(identity['inputs'] == inputs(), 'XCTest host source changed during native compile')
    identity['unsignedSHA256'] = checksum(helper)
    identity['image'] = logged('xctest-host-image', ['otool', '-hvL', str(helper)])
    identity['uuid'] = logged('xctest-host-uuid', ['xcrun', 'dwarfdump', '--uuid', str(helper)])
    require('ARM64' in identity['image'] and 'EXECUTE' in identity['image']
        and 'XCTest.framework' in identity['image'] and len(re.findall(r'UUID: [A-Fa-f0-9-]{36} \(arm64\)', identity['uuid'])) == 1,
        'Native XCTest host architecture, runtime or UUID differs')
    return identity


def verify_receipt(receipt, events, expected, *, source, pid, parent, bundle, host):
    require(receipt.get('schema') == 'native-xctest-host/v1' and receipt.get('sourceSHA') == source
        and receipt.get('pid') == pid and receipt.get('parentPID') == parent
        and receipt.get('bundlePath') == str(bundle.resolve()) and receipt.get('hostPath') == str(host.resolve())
        and receipt.get('loadedHostImage') == str(host.resolve())
        and receipt.get('bundleImagePath') == str((bundle / 'Contents/MacOS/NexGenVideoTests').resolve())
        and receipt.get('passed') is True and receipt.get('boundary') == 'suite-returned'
        and receipt.get('mainThread') is True and receipt.get('applicationRunningAtStart') is True
        and receipt.get('rootSuiteStarted') == receipt.get('rootSuiteCompleted') == 1
        and receipt.get('executionCount') == len(expected) and receipt.get('skipCount') == receipt.get('totalFailureCount') == 0
        and receipt.get('hasSucceeded') is True and receipt.get('prematureExecutionCount') == receipt.get('issueCount') == receipt.get('expectedFailureCount') == 0
        and receipt.get('recordingError') is None and receipt.get('error') is None
        and receipt.get('failedIDs') == [], 'Native XCTest host lifecycle or producer differs')
    require(expected and len(expected) == len(set(expected)), 'Invalid independent XCTest inventory')
    for key in ('inventoryIDs', 'startedIDs', 'endedIDs', 'passedIDs'):
        require(sorted(receipt.get(key, [])) == sorted(expected), 'Native XCTest inventory differs: ' + key)
    leaves = receipt.get('leafClasses', [])
    require(len(leaves) == len(expected) and sorted(item['name'] for item in leaves) == sorted(expected)
        and all(item['image'] == receipt['bundleImagePath'] for item in leaves), 'XCTest class-image provenance differs')
    before, loaded, after = (receipt.get(key, []) for key in ('runtimeImagesBefore', 'runtimeImagesAfterLoad', 'runtimeImagesAfter'))
    prefix = str((bundle / 'Contents/Frameworks').resolve()) + '/'
    require(loaded and loaded == after and len({Path(name).name for name in loaded}) == len(loaded)
        and set(before) <= set(loaded) and all(name.startswith(prefix) for name in loaded)
        and receipt.get('caseRuntimeImage') in loaded, 'XCTest runtime images changed or duplicated')
    require(len(events) == receipt.get('eventCount') and events, 'Original XCTest observation events incomplete')
    active, completed = set(), set()
    root_started = root_ended = 0
    for event in events:
        require(event.get('schema') == 'native-xctest-observation/v1' and event.get('pid') == pid
            and event.get('executing') is True, 'Foreign or premature XCTest observation')
        kind, name = event['kind'], event['name']
        require(kind in {'testCaseWillStart', 'testCaseDidFinish', 'testSuiteWillStart', 'testSuiteDidFinish',
            'testBundleWillStart', 'testBundleDidFinish'}, 'Unexpected or suppressed XCTest issue')
        if kind == 'testSuiteWillStart' and event.get('root'):
            require(root_started == root_ended == 0 and not active, 'Repeated XCTest suite start')
            root_started += 1
        elif kind == 'testSuiteDidFinish' and event.get('root'):
            require(root_started == 1 and root_ended == 0 and not active and completed == set(expected), 'Incomplete root XCTest suite')
            root_ended += 1
            require(event.get('run') == {'executionCount': len(expected), 'skipCount': 0,
                'totalFailureCount': 0, 'hasSucceeded': True}, 'Root XCTest aggregate differs')
        elif kind == 'testCaseWillStart':
            require(root_started == 1 and root_ended == 0 and name in expected and name not in active | completed,
                'Duplicate or out-of-order XCTest case start')
            active.add(name)
        elif kind == 'testCaseDidFinish':
            require(name in active and root_ended == 0, 'XCTest end without actual start')
            require(event.get('run') == {'executionCount': 1, 'skipCount': 0, 'totalFailureCount': 0, 'hasSucceeded': True},
                'Individual XCTest failed, skipped or did not execute')
            active.remove(name); completed.add(name)
    require(not active and completed == set(expected) and root_started == root_ended == 1,
        'XCTest observation stream did not complete')
    return receipt


def verify_proof(proof, expected, source, product):
    require(proof.get('schema') == 'native-xctest-host-proof/v1' and proof.get('passed') is True
        and proof.get('originalExitCode') == 0 and proof.get('outputEOF') is True
        and proof.get('individualPassedIDs') == expected
        and type(proof.get('pid')) is int and proof['pid'] > 1
        and type(proof.get('parentPID')) is int and proof['parentPID'] > 1
        and all(re.fullmatch('[a-f0-9]{64}', proof.get(key, '')) for key in
            ('eventSHA256', 'hostReceiptSHA256', 'consoleSHA256', 'bundleImageSHA256', 'hostSHA256')),
        'Fresh XCTest proof lacks the actual complete process or inventory')
    build = product.get('state', {}).get('xctestHost', {})
    require(build.get('schema') == 'native-xctest-host-build/v1' and build.get('inputs') == inputs()
        and build.get('supportObjectSHA256') == SUPPORT_SHA and build.get('signedSHA256') == proof['hostSHA256'],
        'Fresh XCTest proof lost the qualified compiler product')
    for suffix, expected_hash in [('NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests', proof['bundleImageSHA256']),
            ('NexGenVideoTests.xctest/Contents/Helpers/' + HOST_NAME, proof['hostSHA256'])]:
        selected = [item for name, item in product.get('files', {}).items() if name.endswith('/' + suffix)]
        require(len(selected) == 1 and selected[0].get('kind') == 'file' and selected[0].get('sha256') == expected_hash,
            'Fresh XCTest process did not consume its exact signed test product')
    event_bytes = proof.get('originalEventsUTF8', '').encode()
    receipt_bytes = proof.get('originalHostReceiptUTF8', '').encode()
    require(hashlib.sha256(event_bytes).hexdigest() == proof['eventSHA256']
        and hashlib.sha256(receipt_bytes).hexdigest() == proof['hostReceiptSHA256']
        and [json.loads(line) for line in event_bytes.decode().splitlines()] == proof.get('events')
        and json.loads(receipt_bytes) == proof.get('hostReceipt'), 'XCTest original observations or receipt bytes changed')
    receipt = proof.get('hostReceipt', {})
    prefix = 'Products/Release/NexGenVideoTests.xctest/Contents/Frameworks/'
    roots = {name.removeprefix(prefix).split('/')[0] for name in product.get('files', {}) if name.startswith(prefix)}
    kinds = sorted(Path(name).stem if name.endswith('.framework') else name for name in roots if name.endswith(('.framework', '.dylib')))
    require(kinds and receipt.get('runtimeKinds') == kinds, 'XCTest transitive runtime inventory lost its signed product binding')
    verify_receipt(receipt, proof.get('events', []), expected, source=source, pid=proof['pid'], parent=proof['parentPID'],
        bundle=Path(receipt.get('bundlePath', '')), host=Path(receipt.get('hostPath', '')))
    return proof


def run(folder, bound, image, expected):
    from run_macos_tests import prepare_post_mortem, run_process
    folder.mkdir(exist_ok=False)
    bundle = image.parents[2]
    host = bundle / 'Contents/Helpers' / HOST_NAME
    build_proof = bound['products']['tests']['receipt']['state'].get('xctestHost', {})
    require(build_proof.get('schema') == 'native-xctest-host-build/v1' and build_proof.get('inputs') == inputs()
        and build_proof.get('appSourceSHA') == bound['appSourceSHA'] and build_proof.get('supportObjectSHA256') == SUPPORT_SHA
        and build_proof.get('signedSHA256') == checksum(host), 'Fresh XCTest host lost compiler-product identity')
    write(folder / 'expected.json', expected)
    environment = dict(os.environ)
    require(not any(key.startswith('DYLD_') and value for key, value in environment.items()), 'Ambient native loader override')
    frameworks = bundle / 'Contents/Frameworks'
    environment['DYLD_FRAMEWORK_PATH'] = str(frameworks)
    environment['DYLD_LIBRARY_PATH'] = os.pathsep.join((str(frameworks), bound['runtime']))
    write(folder / 'loader-paths.json', {key: value for key, value in environment.items() if key.startswith('DYLD_')})
    require(not any(key.startswith(('NGV_ACCEPTANCE', 'NGV_APP_DIAGNOSTIC', 'NSZombie')) for key in environment),
        'XCTest acceptance cannot use a diagnostic substitute')
    command = [str(host), str(bundle), str(folder / 'expected.json'), str(folder / 'receipt.json'),
        str(folder / 'events.jsonl'), str(folder / 'exception.jsonl')]
    write(folder / 'command.json', command)
    observation = prepare_post_mortem(host)
    code, pid = run_process(command, folder / 'console.log', environment, observation)
    write(folder / 'process.json', {'exitCode': code, 'pid': pid, 'parentPID': os.getpid(), 'observation': observation})
    require(code == 0 and observation.get('outputCapture', {}).get('originalExitCode') == 0
        and observation['outputCapture'].get('eof') is True, 'Native XCTest process or output capture failed')
    receipt = json.loads((folder / 'receipt.json').read_text())
    records = [json.loads(line) for line in (folder / 'events.jsonl').read_text().splitlines()]
    verify_receipt(receipt, records, expected, source=bound['sourceSHA'], pid=pid, parent=os.getpid(), bundle=bundle, host=host)
    console = (folder / 'console.log').read_text()
    require(not re.search(r'Test run started|Testing Library Version|◇ Test|✘ Test|✔ Test', console),
        'Unexpected Swift Testing execution in XCTest host')
    require((folder / 'exception.jsonl').is_file() and (folder / 'exception.jsonl').stat().st_size == 0,
        'Native AppKit exception evidence is missing or nonempty')
    proof = {'schema': 'native-xctest-host-proof/v1', 'pid': pid, 'parentPID': os.getpid(),
        'individualPassedIDs': expected, 'hostReceipt': receipt, 'events': records, 'originalEventsUTF8': (folder / 'events.jsonl').read_text(),
        'originalHostReceiptUTF8': (folder / 'receipt.json').read_text(), 'hostReceiptSHA256': checksum(folder / 'receipt.json'),
        'eventSHA256': checksum(folder / 'events.jsonl'), 'consoleSHA256': checksum(folder / 'console.log'),
        'hostSHA256': checksum(host), 'bundleImageSHA256': checksum(image), 'originalExitCode': code,
        'outputEOF': observation['outputCapture']['eof'], 'passed': True}
    verify_proof(proof, expected, bound['sourceSHA'], bound['products']['tests']['receipt'])
    persist_proof(folder / 'verified.json', proof)
    return proof
