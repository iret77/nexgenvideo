import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import zipfile

import native_app_target_build as targets
import release_checkpoint as checkpoint
import release_engine_resume as engine
import release_test_repair as retained
from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact, write


REPOSITORY = 'iret77/nexgenvideo'
APP_SOURCE = targets.cohort.APP_SOURCE
COMPILER_SHA = '020a521df9efc127b6817a2ed2f1560155108f0a0ead1ee1fa98147f5944eb4f'
CRITERIA = Path('scripts/fixtures/compiled-app-native-inventory.json')
RETAINED_SOURCE = 'ebe2d8baf4d953d36fda2abc3835400f052da506'
RETAINED_RUN = 42522113496
SIGNED_ARTIFACT = (13633938906, '1b2743fb43e017a337565c3a6c046bf9d8606acd16d4394791a9bf0b8eae7686')
FINAL_ARTIFACT = (13635913556, '5a3c9eef5134b2ae7479c7af8a465c655fceb3857fbf403a090fe27871e7fcb0')
PACK_SHA = '37fcee05d1ac334b20eb392c61cc3b7a94af165dc3b967c61602bc79d6dc4388'
PACK_TREE = '365e9a75174191359bb36b02b429a4bfea55f0b764caa81184228bd3072c402e'
PHASES = ('production', 'testable', 'tests')
SELECTOR_KEYS = {'runID', 'sourceSHA', 'artifactID', 'artifactSHA256', 'receiptSHA256'}


def unique_object(items):
    result = {}
    for key, value in items:
        require(key not in result, 'Duplicate compiled App selector')
        result[key] = value
    return result


def selector_identities(raw):
    require(isinstance(raw, str) and raw, 'Exact compiled App selectors required')
    value = json.loads(raw, object_pairs_hook=unique_object)
    require(isinstance(value, dict) and set(value) == set(PHASES) | {'metadata'}, 'Incomplete compiled App roles')
    for role, selected in value.items():
        keys = SELECTOR_KEYS - {'receiptSHA256'} if role == 'metadata' else SELECTOR_KEYS
        require(isinstance(selected, dict) and set(selected) == keys, 'Unexpected compiled App selector fields')
        require(all(type(selected[key]) is int and selected[key] > 0 for key in ('runID', 'artifactID'))
            and isinstance(selected['sourceSHA'], str) and re.fullmatch('[a-f0-9]{40}', selected['sourceSHA'])
            and all(isinstance(selected[key], str) and re.fullmatch('[a-f0-9]{64}', selected[key])
                for key in keys & {'artifactSHA256', 'receiptSHA256'}), 'Invalid compiled App selector identity')
    return value


def selectors(raw, event):
    value = selector_identities(raw)
    inputs = event.get('inputs', {})
    require(inputs.get('artifact_only') in (True, 'true') and inputs.get('dry_run') in (True, 'true')
        and inputs.get('version') == '1.8.0', 'Compiled App candidates require artifact-only RC mode')
    conflicts = ('completed_release_tests_run_id', 'completed_engine_tests_run_id', 'signed_build_run_id',
        'notary_progress_run_id', 'retained_product_source_sha', 'retained_product_source_pr_run_id',
        'prior_packaging_producer_source_sha', 'prior_packaging_provenance_artifact_id',
        'prior_packaging_provenance_artifact_sha256')
    require(not any(inputs.get(name) for name in conflicts) and inputs.get('verified_pr_run_id'),
        'Compiled App selectors conflict with another continuation')
    return value


def source_objects(source):
    return {name: targets.capture.git('rev-parse', source + ':' + name) for name in targets.capture.INPUT_OBJECTS}


def producer(selected, role):
    run = api('actions/runs/' + str(selected['runID']))
    inventory = api(f"actions/runs/{selected['runID']}/attempts/1/jobs?per_page=100")
    require(run.get('repository', {}).get('full_name') == REPOSITORY and run.get('workflow_id') == 355242770
        and run.get('path') == '.github/workflows/diagnostic-acceptance.yml' and run.get('actor', {}).get('login') == 'iret77'
        and run.get('head_sha') == selected['sourceSHA'] and run.get('event') == 'workflow_dispatch'
        and run.get('status') == 'completed' and run.get('conclusion') in ('success', 'failure')
        and run.get('run_attempt') == 1 and inventory.get('total_count') == len(inventory.get('jobs', [])),
        'Compiled App producer identity differs')
    native = [job for job in inventory['jobs'] if job['name'] == 'app-target-build']
    sources = [job for job in inventory['jobs'] if job['name'] == 'source']
    require(len(native) == len(sources) == 1 and native[0]['labels'] == ['macrunner']
        and native[0]['status'] == 'completed' and sources[0]['conclusion'] == 'success'
        and native[0]['run_attempt'] == sources[0]['run_attempt'] == 1, 'Compiled App producer jobs differ')
    if role != 'metadata':
        step = {'production': 'Build only the current production App target',
            'testable': 'Build only the current testable App target',
            'tests': 'Build only the dependent App tests target'}[role]
        require([item.get('conclusion') for item in native[0]['steps'] if item['name'] == step] == ['success'],
            'Selected compiled App phase did not complete')
    artifact = api('actions/artifacts/' + str(selected['artifactID']))
    name = 'app-target-build-evidence' if role == 'metadata' else 'app-target-' + role + '-products'
    verify_artifact(artifact, run, native[0], selected['artifactID'], selected['artifactSHA256'], name)
    require(source_objects(selected['sourceSHA']) == source_objects(APP_SOURCE) == source_objects('HEAD'),
        'Compiled App producer and current native sources differ')
    return {'selected': selected, 'run': run, 'job': native[0], 'sourceJob': sources[0], 'artifact': artifact}


def verified_zip(path, limit):
    archive = zipfile.ZipFile(path)
    entries = archive.infolist()
    require(entries and len(entries) <= 200_000 and sum(item.file_size for item in entries) <= limit
        and len({item.filename.casefold() for item in entries}) == len(entries) and archive.testzip() is None,
        'Compiled App archive inventory, bounds or CRC differ')
    for item in entries:
        name = item.filename.rstrip('/')
        path = PurePosixPath(name)
        mode = stat.S_IFMT(item.external_attr >> 16)
        require(name and str(path) == name and not path.is_absolute() and '..' not in path.parts
            and '\\' not in name and '\0' not in name
            and mode in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), 'Unsafe compiled App archive member')
    return archive


def verify_product(receipt, selected, phase, prepared):
    require(receipt.get('schema') == 'native-app-target-product/v1' and receipt.get('phase') == phase
        and receipt.get('sourceSHA') == selected['sourceSHA'] and receipt.get('runID') == selected['runID']
        and receipt.get('attempt') == 1 and receipt.get('appSourceSHA') == APP_SOURCE
        and receipt.get('nativeSourceObjects') == source_objects(APP_SOURCE)
        and receipt.get('compilerSHA256') == COMPILER_SHA
        and receipt.get('recipeSHA256') == targets.recipe_identity(prepared, phase)
        and receipt.get('arena') == prepared['plans'][phase]['operations']['arena'],
        'Compiled App product lost its source, recipe or producer')
    state = receipt.get('state', {})
    require(state.get('compileComplete') is True and state.get('linkComplete') is True
        and state.get('linkerCommandSucceeded') is True and re.fullmatch('[a-f0-9]{64}', state.get('unsignedLinkSHA256', ''))
        and isinstance(receipt.get('files'), dict) and receipt['files'], 'Compiled App target is incomplete')
    if phase == 'production':
        uuids = lambda value: re.findall(r'UUID: ([A-Fa-f0-9-]{36}) \(arm64\)', value)
        require(state.get('dsymComplete') is True and len(uuids(state.get('imageUUID', ''))) == 1
            and uuids(state['imageUUID']) == uuids(state.get('dsymUUID', '')),
            'Production App symbols do not match')
    return receipt


def criteria():
    value = json.loads(CRITERIA.read_text())
    require(value.get('schema') == 'compiled-app-native-inventory/v1' and value.get('appSourceSHA') == APP_SOURCE
        and value.get('nativeSourceObjects') == source_objects(APP_SOURCE)
        and value.get('expectedActualExecutions') == 4656, 'Independent native inventory differs')
    for expected in value['modules'].values():
        ended, skipped = expected['exactEndedFunctionIDs'], expected['exactSkippedFunctionIDs']
        require(len(ended) == len(set(ended)) and len(skipped) == len(set(skipped))
            and not set(ended).intersection(skipped), 'Independent native inventory contains duplicate roles')
        expected['exactDiscoveredFunctionIDs'] = sorted(set(ended) | set(skipped))
    return value


def verify_events(path, expected, module):
    from run_macos_tests import swift_events
    parsed = swift_events(path, module)
    for key, expected_key in [('discoveredFunctionIDs', 'exactDiscoveredFunctionIDs'),
            ('startedFunctionIDs', 'exactEndedFunctionIDs'), ('endedFunctionIDs', 'exactEndedFunctionIDs'),
            ('skippedFunctionIDs', 'exactSkippedFunctionIDs')]:
        require(parsed[key] == sorted(expected[expected_key]), 'Native function coverage differs: ' + key)
    with path.open(encoding='utf-8') as stream:
        records = [json.loads(line) for line in stream]
    starts, ends = Counter(), Counter()
    for row in records:
        if row.get('kind') != 'event':
            continue
        event = row['payload']
        if event.get('kind') == 'testCaseStarted':
            starts[event['testID']] += 1
        elif event.get('kind') == 'testCaseEnded':
            ends[event['testID']] += 1
    require(starts == ends == Counter(expected['expectedCaseCountsByFunction']),
        'Native parameter-case coverage differs')
    return parsed


def native_guard(root):
    require(sys.platform == 'darwin' and platform.machine() == 'arm64'
        and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_JOB') == 'release-build' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1',
        'Compiled App consumption requires the owned native release build')
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    require(root.is_absolute() and root.resolve().is_relative_to(temporary) and not root.is_symlink(),
        'Compiled App evidence root escapes this job')
    proof = json.loads((temporary / 'native-test-python.json').read_text())
    require(proof.get('passed') is True and proof.get('platform') == 'darwin' and proof.get('machine') == 'arm64'
        and proof.get('version', '').startswith('3.13.')
        and Path(proof.get('executable', '')).resolve() == Path(sys.executable).resolve()
        and all(proof.get('interfaces', {}).get(name) is True for name in (
            'waitid', 'P_PID', 'WEXITED', 'WNOHANG', 'WNOWAIT', 'CLD_EXITED', 'CLD_KILLED', 'CLD_DUMPED')),
        'Native Python capability proof differs')
    return temporary


def acquire_products(root):
    temporary = native_guard(root)
    root.mkdir(parents=True, exist_ok=False)
    selected = selectors(os.environ['COMPILED_APP_TARGETS'], json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()))
    metadata = producer(selected['metadata'], 'metadata')
    download(metadata['artifact'], root / 'metadata-original.zip')
    with verified_zip(root / 'metadata-original.zip', 1024**3) as archive:
        binding = json.loads(archive_bytes(archive, 'binding.json', 32 * 1024**2))
        prepared = json.loads(archive_bytes(archive, 'prepared.json', 32 * 1024**2))
    require(binding.get('schema') == 'native-app-target-source-binding/v1'
        and prepared.get('schema') == 'native-app-target-prepared/v1'
        and prepared.get('sourceSHA') == binding.get('sourceSHA') == selected['metadata']['sourceSHA']
        and prepared.get('appSourceSHA') == binding.get('appSourceSHA') == APP_SOURCE
        and prepared.get('nativeSourceObjects') == binding.get('nativeSourceObjects') == source_objects(APP_SOURCE)
        and prepared.get('compilerSHA256') == COMPILER_SHA
        and binding['metadata']['artifact']['id'] == 13647433566
        and binding['metadata']['artifact']['digest'] == 'sha256:b6f5e0ef652fd5996760ce5f59f19239760563216d2504ff6ee056fa4dee74a9',
        'Compiled App metadata source or original recipe differs')
    for phase in PHASES:
        profile = 'production' if phase == 'production' else 'testable'
        arena = str(temporary / 'app-build-plan-evidence' / profile / 'derived-data')
        require(prepared['plans'][phase]['operations']['arena'] == arena, 'Compiled App arena differs')
    bank = binding['retainedBank']['runtimeArtifact']
    require((bank['id'], bank['digest'], bank['name']) == (
        retained.ARTIFACTS['runtime'][0], 'sha256:' + retained.ARTIFACTS['runtime'][1], retained.ARTIFACTS['runtime'][2]),
        'Compiled App retained runtime bank differs')
    actual_bank = api('actions/artifacts/' + str(bank['id']))
    require(actual_bank == bank and not actual_bank['expired'], 'Retained runtime metadata changed')
    download(actual_bank, root / 'runtime.zip')
    with zipfile.ZipFile(root / 'runtime.zip') as archive:
        raw_manifest = archive_bytes(archive, 'runtime-manifest.json', 4 * 1024**2)
    require(hashlib.sha256(raw_manifest).hexdigest() == retained.MANIFEST_SHA, 'Retained runtime manifest differs')
    with (root / 'bank-runtime-manifest.json').open('xb') as output: output.write(raw_manifest)
    manifest = json.loads(raw_manifest)
    binary = retained.restore_runtime(root, manifest, lambda argv, label, timeout=180:
        targets.logged(root, label, argv, timeout=timeout))
    runtime = root / 'runtime'
    def ignored(directory, names):
        if Path(directory) == binary:
            return {'NexGenVideo', 'NexGenVideo.swiftmodule', 'NexGenVideoTests.swiftmodule',
                'NexGenVideoTests.xctest', 'NexGenVideoTests.xctest.dSYM', 'NexGenVideo.dSYM'}.intersection(names)
        if Path(directory) == binary / 'ExecutableModules':
            return {Path(retained.APP_OBJECT).name}.intersection(names)
        return set()
    shutil.copytree(binary, runtime, symlinks=True, ignore=ignored)
    products = {}
    for phase in PHASES:
        origin = producer(selected[phase], phase)
        folder = root / phase
        folder.mkdir()
        download(origin['artifact'], folder / 'original.zip')
        with verified_zip(folder / 'original.zip', 12 * 1024**3) as outer:
            require(outer.namelist() == [phase + '-products.zip'], 'Unexpected compiled App outer archive')
            with outer.open(phase + '-products.zip') as source, (folder / 'product.zip').open('xb') as destination:
                shutil.copyfileobj(source, destination, 1024 * 1024)
        with verified_zip(folder / 'product.zip', 12 * 1024**3) as archive:
            raw = archive_bytes(archive, 'product-receipt.json', 16 * 1024**2)
            require(hashlib.sha256(raw).hexdigest() == selected[phase]['receiptSHA256'], 'Compiled product receipt changed')
            receipt = verify_product(json.loads(raw), selected[phase], phase, prepared)
            expected = {'outputs/' + name for name in receipt['files']}
            require(expected | {'product-receipt.json'} <= set(archive.namelist())
                and all(name in expected or name == 'product-receipt.json' or name.startswith('evidence/')
                    for name in archive.namelist()), 'Compiled App output inventory differs')
            restored = folder / 'restored'
            restored.mkdir()
            links = []
            require(len({name.casefold() for name in receipt['files']}) == len(receipt['files']),
                'Compiled App output paths collide')
            for name, item in receipt['files'].items():
                relative = PurePosixPath(name)
                require(not relative.is_absolute() and str(relative) == name and '..' not in relative.parts
                    and '\\' not in name and '\0' not in name and type(item.get('mode')) is int
                    and item['mode'] & ~0o777 == 0, 'Unsafe compiled App output path or permissions')
                destination = restored / name
                if item['kind'] == 'symlink':
                    target = item['target']
                    require(isinstance(target, str) and not Path(target).is_absolute() and '\\' not in target
                        and '\0' not in target and destination.parent.joinpath(target).resolve().is_relative_to(restored.resolve())
                        and archive.read('outputs/' + name).decode() == target, 'Compiled App output link escapes')
                    links.append((destination, target))
                else:
                    require(item['kind'] == 'file' and archive.getinfo('outputs/' + name).file_size == item['bytes'],
                        'Compiled App output size differs')
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open('outputs/' + name) as source, destination.open('xb') as output:
                        shutil.copyfileobj(source, output, 1024 * 1024)
                    os.chmod(destination, item['mode'])
                    require(checksum(destination) == item['sha256'], 'Compiled App output bytes differ')
            for destination, target in links:
                destination.parent.mkdir(parents=True, exist_ok=True)
                require(not destination.exists() and not destination.is_symlink(), 'Compiled App link output occupied')
                destination.symlink_to(target)
            require(all(path.resolve().is_relative_to(restored.resolve()) for path, _ in links),
                'Compiled App output link chain escapes')
        plan = prepared['plans'][phase]
        links = [item for item in plan['operations']['links'] if item['targetGUID'] == plan['driver']['targetGUID']]
        require(len(links) == 1, 'Compiled App target has no unique linker output')
        output = restored / Path(links[0]['output']).relative_to(receipt['arena'])
        require(output.is_file() and not output.is_symlink(), 'Compiled App linker output is missing')
        products[phase] = {'producer': origin, 'receipt': receipt, 'output': str(output),
            'archiveSHA256': checksum(folder / 'product.zip'), 'originalArchiveSHA256': checksum(folder / 'original.zip')}
    require(checksum(runtime / 'NexGenVideoAppKitTestHost') == retained.HOST_SHA,
        'Retained AppKit host changed during runtime materialization')
    write(root / 'bound.json', {'schema': 'compiled-app-release-binding/v1', 'sourceSHA': os.environ['GITHUB_SHA'],
        'runID': int(os.environ['GITHUB_RUN_ID']), 'appSourceSHA': APP_SOURCE, 'nativeSourceObjects': source_objects(APP_SOURCE),
        'selected': selected, 'products': products, 'metadataProducer': metadata, 'prepared': prepared,
        'runtime': str(runtime), 'runtimeManifestSHA256': retained.MANIFEST_SHA,
        'runtimeManifestOrigin': {'artifactID': bank['id'], 'artifactSHA256': bank['digest'].removeprefix('sha256:'),
            'member': 'runtime-manifest.json', 'bytes': len(raw_manifest)}})


def run_tests(root):
    import compiled_core_reuse
    if APP_SOURCE == compiled_core_reuse.origin()['appSourceSHA']:
        native_guard(root)
        bound = json.loads((root / 'bound.json').read_text())
        return compiled_core_reuse.acquire(root, bound, criteria(), sys.modules[__name__])
    from run_macos_tests import app_environment, framework_output, host_receipt, prepare_post_mortem, run_process
    native_guard(root)
    bound = json.loads((root / 'bound.json').read_text())
    require(bound['sourceSHA'] == os.environ['GITHUB_SHA'] and bound['runID'] == int(os.environ['GITHUB_RUN_ID'])
        and bound['nativeSourceObjects'] == source_objects('HEAD'), 'Compiled App test source changed')
    expected = criteria()
    retained_engine = retained_engine_evidence(root, expected['modules']['engine'])
    runtime = Path(bound['runtime'])
    host = runtime / 'NexGenVideoAppKitTestHost'
    image = Path(bound['products']['tests']['output'])
    require(checksum(host) == retained.HOST_SHA and checksum(Path(bound['prepared']['plans']['production']['driver']['argv'][0])) == COMPILER_SHA,
        'Native test host or toolchain changed')
    targets.logged(root, 'verify-test-bundle', ['codesign', '--verify', '--deep', '--strict', str(image.parents[2])])
    with (root / 'native-tests.STARTED.json').open('x') as stream:
        json.dump({'sourceSHA': bound['sourceSHA'], 'runID': bound['runID'], 'products': bound['selected']}, stream)
        stream.flush()
        os.fsync(stream.fileno())
    import native_xctest_host
    fresh_xctest = native_xctest_host.run(root / 'xctest', bound, image, expected['xctest']['exactIndividualPassedIDs'])
    folder = root / 'app-swift-testing'
    folder.mkdir()
    environment = app_environment(dict(os.environ), runtime, image, folder)
    require(not any(key.startswith(('NGV_ACCEPTANCE', 'NGV_APP_DIAGNOSTIC', 'NSZombie')) for key in environment),
        'Native acceptance cannot use a diagnostic substitute')
    environment.update(NGV_APPKIT_TEST_BUNDLE=str(image.resolve()), NGV_APPKIT_TEST_EVENTS=str(folder / 'events.jsonl'),
        NGV_APPKIT_TEST_RECEIPT=str(folder / 'host-receipt.json'), NGV_APPKIT_EXCEPTION_EVIDENCE=str(folder / 'exception.jsonl'),
        SWIFT_BACKTRACE='enable=yes,interactive=no,demangle=yes,cache=no')
    command = [str(host), '--event-stream-version', '0', '--no-parallel']
    observation = prepare_post_mortem(host)
    write(folder / 'command.json', command)
    code, pid = run_process(command, folder / 'console.log', environment, observation)
    write(folder / 'process.json', {'exitCode': code, 'pid': pid, 'observation': observation})
    require(code == 0 and observation.get('outputCapture', {}).get('originalExitCode') == 0
        and observation['outputCapture'].get('eof') is True, 'Native process failed or original output is incomplete')
    events = verify_events(folder / 'events.jsonl', expected['modules']['app'], 'NexGenVideoTests')
    require(set(expected['originalEightAppFailureIDsRequiredToEndWithoutIssues']) <= set(events['endedFunctionIDs'])
        and events['functionExecutions'] == 3712, 'Original eight App cases or full App execution is missing')
    proofs = {'app-swift-testing': {'pid': pid, 'parentPID': os.getpid(), 'consoleSHA256': checksum(folder / 'console.log'),
        'events': events, 'eventSHA256': checksum(folder / 'events.jsonl'),
        'hostReceipt': host_receipt(folder / 'host-receipt.json', events, pid=pid, bundle=image, host=host, source_sha=os.environ['GITHUB_SHA']),
        'hostReceiptSHA256': checksum(folder / 'host-receipt.json'), 'framework': framework_output(folder / 'console.log', 1, 0)}}
    write(folder / 'verified.json', proofs['app-swift-testing'])
    proofs['xctest'] = fresh_xctest
    receipt = {'schema': 'release-native-compiled-app/v3', 'sourceSHA': bound['sourceSHA'], 'runID': bound['runID'],
        'attempt': 1, 'appSourceSHA': APP_SOURCE, 'nativeSourceObjects': bound['nativeSourceObjects'],
        'compilerSHA256': COMPILER_SHA, 'selected': bound['selected'],
        'products': {phase: {'receipt': bound['products'][phase]['receipt'],
            'originalArchiveSHA256': bound['products'][phase]['originalArchiveSHA256']} for phase in PHASES},
        'hostSHA256': retained.HOST_SHA, 'criteriaSHA256': checksum(CRITERIA), 'passed': True,
        'counts': {'freshApp': 3712, 'freshXCTest': 48, 'retainedEngine': 896, 'executions': 4656,
            'appSkips': 8, 'engineSkips': 14},
        'freshProofs': proofs, 'retainedEngine': retained_engine}
    verify_receipt(receipt, bound['sourceSHA'], bound['runID'])
    write(root / 'receipt.json', receipt)


def retained_engine_evidence(root, expected):
    from verified_pr_source_checks import read_api
    engine.verify_engine_source_objects(os.environ['GITHUB_SHA'])
    original = api('actions/runs/' + str(engine.RUN))
    jobs = api(f'actions/runs/{engine.RUN}/attempts/1/jobs?per_page=100')
    job = engine.verify_original(original, jobs)
    artifact = api('actions/artifacts/' + str(engine.ARTIFACT))
    verify_artifact(artifact, original, job, engine.ARTIFACT, engine.DIGEST, 'release-test-evidence')
    retained_engine = root / 'retained-engine'
    retained_engine.mkdir()
    download(artifact, retained_engine / 'original.zip')
    retained_proof = engine.verify_archive(retained_engine / 'original.zip', retained_engine)
    verify_events(retained_engine / 'engine-swift-testing/events.jsonl', expected, 'NexGenEngineTests')
    raw = read_api(f'actions/jobs/{engine.JOB}/logs', 4_000_000)
    require(hashlib.sha256(raw).hexdigest() == engine.LOG_DIGEST, 'Original complete Engine producer log differs')
    (retained_engine / 'original-job.log').write_bytes(raw)
    environment = engine_environment(raw)
    write(retained_engine / 'current-environment.json', environment)
    return {'run': original, 'job': job, 'artifact': artifact, 'proof': retained_proof, 'environment': environment}


def engine_environment(raw):
    original = engine.toolchain(raw)
    current = {'swift': engine.command('swift', '--version'), 'xcode': engine.command('xcodebuild', '-version'),
        'python': platform.python_version(), 'osVersion': engine.command('sw_vers', '-productVersion'),
        'osBuild': engine.command('sw_vers', '-buildVersion')}
    require(platform.machine() == 'arm64' and current == original, 'Current Release Engine runtime or toolchain differs')
    return {'original': original, 'current': current, 'architecture': 'arm64'}


def verify_receipt(receipt, source, run_id):
    if receipt.get('schema') == 'release-native-compiled-app/v4':
        import compiled_core_reuse
        require(receipt.get('sourceSHA') == source and type(receipt.get('runID')) is int and receipt['runID'] == run_id
            and type(receipt.get('attempt')) is int and receipt['attempt'] == 1 and receipt.get('appSourceSHA') == APP_SOURCE
            and receipt.get('nativeSourceObjects') == source_objects(source) == source_objects(APP_SOURCE)
            and receipt.get('compilerSHA256') == COMPILER_SHA and receipt.get('hostSHA256') == retained.HOST_SHA
            and receipt.get('criteriaSHA256') == checksum(CRITERIA) and receipt.get('passed') is True
            and all(type(value) is int for value in receipt.get('counts', {}).values()),
            'Retained complete native acceptance identity differs')
        selector_identities(json.dumps(receipt.get('selected')))
        return compiled_core_reuse.verify(receipt.get('retainedNative'), receipt, criteria(), sys.modules[__name__])
    fresh_host = receipt.get('schema') == 'release-native-compiled-app/v3'
    continued = receipt.get('schema') == 'release-native-compiled-app/v2'
    require(receipt.get('schema') in ('release-native-compiled-app/v1', 'release-native-compiled-app/v2', 'release-native-compiled-app/v3') and receipt.get('sourceSHA') == source
        and receipt.get('runID') == run_id and receipt.get('attempt') == 1 and receipt.get('appSourceSHA') == APP_SOURCE
        and receipt.get('nativeSourceObjects') == source_objects(source) == source_objects(APP_SOURCE)
        and receipt.get('compilerSHA256') == COMPILER_SHA and receipt.get('hostSHA256') == retained.HOST_SHA
        and receipt.get('criteriaSHA256') == checksum(CRITERIA) and receipt.get('passed') is True,
        'Native compiled App acceptance identity differs')
    require(receipt.get('counts') == {'freshApp': 3712 if fresh_host else 3708, 'retainedCurrentXCTest' if continued else 'freshXCTest': 48, 'retainedEngine': 896,
        'executions': 4656 if fresh_host else 4652, 'appSkips': 8, 'engineSkips': 14}, 'Native compiled App acceptance counts differ')
    require(set(receipt.get('products', {})) == set(PHASES) and set(receipt.get('freshProofs', {})) == ({'app-swift-testing'} if continued else {'xctest', 'app-swift-testing'}),
        'Native compiled App acceptance roles differ')
    selected_roles = selector_identities(json.dumps(receipt.get('selected')))
    for phase in PHASES:
        selected = selected_roles[phase]
        product = receipt['products'][phase]['receipt']
        raw = (json.dumps(product, indent=2) + '\n').encode()
        require(hashlib.sha256(raw).hexdigest() == selected['receiptSHA256']
            and product.get('schema') == 'native-app-target-product/v1'
            and product.get('sourceSHA') == selected['sourceSHA'] and product.get('runID') == selected['runID']
            and product.get('phase') == phase and product.get('appSourceSHA') == APP_SOURCE
            and product.get('compilerSHA256') == COMPILER_SHA and product.get('attempt') == 1
            and product.get('nativeSourceObjects') == receipt['nativeSourceObjects']
            and product.get('state', {}).get('compileComplete') is True and product['state'].get('linkComplete') is True
            and receipt['products'][phase]['originalArchiveSHA256'] == selected['artifactSHA256'],
            'Native acceptance compiler product differs')
    expected = criteria()
    app = receipt['freshProofs']['app-swift-testing']
    for key, expected_key in [('discoveredFunctionIDs', 'exactDiscoveredFunctionIDs'),
            ('startedFunctionIDs', 'exactEndedFunctionIDs'), ('endedFunctionIDs', 'exactEndedFunctionIDs'),
            ('skippedFunctionIDs', 'exactSkippedFunctionIDs')]:
        require(app.get('events', {}).get(key) == sorted(expected['modules']['app'][expected_key]),
            'Native acceptance exact App coverage differs')
    if continued:
        import compiled_xctest_reuse
        compiled_xctest_reuse.verify(receipt.get('retainedCurrentXCTest', {}), expected['xctest']['exactIndividualPassedIDs'],
            receipt['selected'], receipt['nativeSourceObjects'], receipt.get('retainedEngine', {}).get('environment', {}))
    else:
        require(sorted(receipt['freshProofs']['xctest'].get('individualPassedIDs', []))
            == sorted(expected['xctest']['exactIndividualPassedIDs']), 'Native acceptance exact XCTest coverage differs')
    for role, proof in receipt['freshProofs'].items():
        if role == 'xctest' and fresh_host:
            import native_xctest_host
            native_xctest_host.verify_proof(proof, expected['xctest']['exactIndividualPassedIDs'], source, receipt['products']['tests']['receipt'])
            continue
        runs = {'swiftTesting': 1, 'xctest': 0} if role == 'app-swift-testing' else {'swiftTesting': 0, 'xctest': 1}
        framework = proof.get('framework', {})
        require(framework.get('passed') is True and framework.get('expectedRuns') == runs
            and framework.get('startedRuns') == framework.get('completedRuns') == runs and framework.get('failures') == []
            and re.fullmatch('[a-f0-9]{64}', proof.get('consoleSHA256', '')),
            'Native acceptance framework completion or original console identity is missing')
    host = app.get('hostReceipt', {})
    require(app['events'].get('functionExecutions') == (3712 if fresh_host else 3708) and app['events'].get('runStarted') == app['events'].get('runEnded') == 1
        and host.get('sourceSHA') == source and host.get('pid') == app.get('pid')
        and host.get('parentPID') == app.get('parentPID') and host.get('eventRecordCount') == app['events'].get('recordCount')
        and host.get('recordingError') is None and host.get('error') is None
        and all(host.get(key) is True for key in ('mainThread', 'applicationRunningAtStart', 'started',
            'completed', 'abiSucceeded', 'runReturnedAfterCompletion'))
        and all(re.fullmatch('[a-f0-9]{64}', app.get(key, '')) for key in ('eventSHA256', 'hostReceiptSHA256')),
        'Native acceptance lacks the complete owned AppKit ABI execution')
    retained_proof = receipt.get('retainedEngine', {})
    require(retained_proof.get('run', {}).get('id') == engine.RUN
        and retained_proof['run'].get('head_sha') == engine.SOURCE
        and retained_proof.get('artifact', {}).get('id') == engine.ARTIFACT
        and retained_proof['artifact'].get('digest') == 'sha256:' + engine.DIGEST
        and retained_proof.get('proof', {}).get('eventsSHA256') == engine.EVENT_DIGEST
        and retained_proof['proof'].get('logSHA256') == engine.CONSOLE_DIGEST
        and retained_proof.get('environment', {}).get('architecture') == 'arm64'
        and set(retained_proof['environment'].get('original', {})) == {'swift', 'xcode', 'python', 'osVersion', 'osBuild'}
        and retained_proof['environment'].get('current') == retained_proof['environment']['original'],
        'Native acceptance retained Engine identity differs')
    return receipt


def retained_payload(root, role, identifier, digest):
    run = api('actions/runs/' + str(RETAINED_RUN))
    jobs = api(f'actions/runs/{RETAINED_RUN}/attempts/1/jobs?per_page=100')
    require(run.get('repository', {}).get('full_name') == REPOSITORY and run.get('head_sha') == RETAINED_SOURCE
        and run.get('path') == '.github/workflows/release.yml' and run.get('actor', {}).get('login') == 'iret77'
        and run.get('event') == 'workflow_dispatch' and run.get('run_attempt') == 1 and run.get('status') == 'completed'
        and jobs.get('total_count') == len(jobs.get('jobs', [])), 'Retained signed payload producer differs')
    selected = [job for job in jobs['jobs'] if job['name'] == role]
    require(len(selected) == 1 and selected[0]['labels'] == ['macrunner']
        and selected[0]['conclusion'] == 'success', 'Retained signed payload job did not pass')
    artifact = api('actions/artifacts/' + str(identifier))
    name = 'release-signed-input-' + RETAINED_SOURCE if role == 'release-build' else 'NexGenVideo-1.8.0-artifact-only'
    verify_artifact(artifact, run, selected[0], identifier, digest, name)
    path = root / (role + '-original.zip')
    download(artifact, path)
    write(root / (role + '-producer.json'), {'run': run, 'job': selected[0], 'artifact': artifact,
        'originalArchiveSHA256': checksum(path)})
    return path


def assemble(root):
    import plistlib
    native_guard(root)
    bound = json.loads((root / 'bound.json').read_text())
    receipt = json.loads((root / 'receipt.json').read_text())
    verify_receipt(receipt, os.environ['GITHUB_SHA'], int(os.environ['GITHUB_RUN_ID']))
    component_paths = ['Engine', 'Runtime', 'Metal', 'Vendor', 'plugins', 'assets', 'Package.swift', 'Package.resolved',
        'scripts/NexGenVideo.entitlements']
    component_paths += ['Sources/' + name for name in targets.capture.git('ls-tree', '--name-only', 'HEAD:Sources').splitlines()
        if name != 'NexGenVideo']
    for name in component_paths:
        require(targets.capture.git('rev-parse', 'HEAD:' + name)
            == targets.capture.git('rev-parse', RETAINED_SOURCE + ':' + name),
            'Retained signed component source changed: ' + name)
    resource_root = 'Sources/NexGenVideo/Resources'
    fresh_resources = {resource_root + '/Info.plist', resource_root + '/Changelog/changelog.json'}
    require(set(targets.capture.git('diff', '--name-only', '--no-renames', RETAINED_SOURCE, 'HEAD', '--', resource_root).splitlines())
        == fresh_resources, 'Retained App resources changed beyond the two reviewed current resources')
    payload = retained_payload(root, 'release-build', *SIGNED_ARTIFACT)
    retained_root = root / 'signed-payload'
    retained_root.mkdir()
    with verified_zip(payload, 4 * 1024**3) as archive:
        require(set(archive.namelist()) == set(checkpoint.FILES) | {'manifest.json'}, 'Retained signed input inventory differs')
        manifest = checkpoint.verify_manifest(json.loads(archive_bytes(archive, 'manifest.json')), RETAINED_SOURCE, RETAINED_RUN)
        write(root / 'retained-signed-manifest.json', manifest)
        for name in checkpoint.FILES:
            record = manifest['files'][name]
            require(archive.getinfo(name).file_size == record['bytes'], 'Retained signed payload size differs')
            with archive.open(name) as source, (retained_root / name).open('xb') as destination:
                shutil.copyfileobj(source, destination, 1024 * 1024)
            require(checksum(retained_root / name) == record['sha256'], 'Retained signed payload bytes differ')
    checkpoint.validate_app_zip(retained_root / 'NexGenVideo.zip')
    build = Path('.build')
    app = build / 'NexGenVideo.app'
    require(not app.exists() and not app.is_symlink(), 'New App bundle destination is occupied')
    build.mkdir(exist_ok=True)
    targets.logged(root, 'restore-signed-app', ['/usr/bin/ditto', '-x', '-k', str(retained_root / 'NexGenVideo.zip'), str(build)])
    require(checkpoint.tree_digest(app) == manifest['appTreeSHA256'], 'Retained signed App tree differs')
    targets.logged(root, 'verify-retained-signature', ['codesign', '--verify', '--deep', '--strict', str(app)])
    checkpoint.extract_tar(retained_root / 'symbols.tar.gz', build, {
        'NexGenVideo.dSYM', 'NexGenVideoDiagnostics.dSYM', 'NexGenEngine.dSYM', 'MusicvideoPlugin.dSYM'})
    final = retained_payload(root, 'release', *FINAL_ARTIFACT)
    pack_root = build / 'plugins'
    pack_root.mkdir(exist_ok=False)
    source_root = build / 'bpy-source'
    source_root.mkdir(exist_ok=True)
    with verified_zip(final, 6 * 1024**3) as archive:
        for name in ('plugins/musicvideo.entry.json', 'plugins/musicvideo.ngvpack.zip', 'plugins/musicvideo.badge.png',
                'bpy-source/bpy-source-receipt.json', 'bpy-source/NexGenVideo-bpy-5.2.2-corresponding-source.tar',
                'bpy-source/NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json'):
            with archive.open(name) as source, (build / name).open('xb') as destination:
                shutil.copyfileobj(source, destination, 1024 * 1024)
    require(checksum(pack_root / 'musicvideo.ngvpack.zip') == PACK_SHA
        and checksum(source_root / 'bpy-source-receipt.json') == manifest['files']['bpy-source-receipt.json']['sha256'],
        'Retained stapled pack or distributable source receipt differs')
    with verified_zip(pack_root / 'musicvideo.ngvpack.zip', 64 * 1024**2) as archive:
        require(all(PurePosixPath(item.filename).parts[0] in ('musicvideo.ngvpack', '__MACOSX')
            for item in archive.infolist()), 'Retained pack archive escapes its bundle')
    targets.logged(root, 'restore-stapled-pack', ['/usr/bin/ditto', '-x', '-k', str(pack_root / 'musicvideo.ngvpack.zip'), str(pack_root)])
    require(checkpoint.tree_digest(pack_root / 'musicvideo.ngvpack') == PACK_TREE, 'Retained stapled pack tree differs')
    verify_pack(pack_root)
    original_image = app / 'Contents/MacOS/NexGenVideo'
    original_symbols = build / 'NexGenVideo.dSYM'
    original_image.rename(root / 'retired-original-app-image')
    original_symbols.rename(root / 'retired-original-app-symbols')
    production = Path(bound['products']['production']['output'])
    shutil.copyfile(production, original_image)
    os.chmod(original_image, 0o755)
    shutil.copytree(Path(str(production) + '.dSYM'), original_symbols, symlinks=True)
    targets.logged(root, 'distribution-rpath', ['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(original_image)])
    info_path = app / 'Contents/Info.plist'
    retained_info = plistlib.loads(info_path.read_bytes())
    info = plistlib.loads(Path('Sources/NexGenVideo/Resources/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == retained_info.get('CFBundleIdentifier'), 'Current App identity changed')
    if 'SentryDSN' in retained_info:
        info['SentryDSN'] = retained_info['SentryDSN']
    changelog = Path('Sources/NexGenVideo/Resources/Changelog/changelog.json')
    for destination in (app / 'Contents/Resources/Changelog/changelog.json',):
        require(not destination.is_symlink() and destination.is_file(), 'Retained changelog destination missing or linked')
        destination.write_bytes(changelog.read_bytes())
    info.update(NGVSourceCommit=os.environ['GITHUB_SHA'], NGVBuildConfiguration='release', NGVBuildSDK='27.2',
        CFBundleShortVersionString='1.8.0', CFBundleVersion=str(int(manifest['identity']['build']) + 1))
    require(info['NGVPluginCatalogURL'] == 'https://github.com/iret77/nexgenvideo/releases/download/plugins/catalog.json',
        'Compiled App cannot change its catalog channel')
    info_path.write_bytes(plistlib.dumps(info))
    sign = os.environ.get('SIGN_IDENTITY')
    require(sign, 'Developer ID identity is missing')
    targets.logged(root, 'sign-new-app-root', ['codesign', '--force', '--options', 'runtime', '--timestamp',
        '--sign', sign, '--entitlements', 'scripts/NexGenVideo.entitlements', str(app)], timeout=180)
    targets.logged(root, 'verify-new-app-signature', ['codesign', '--verify', '--deep', '--strict', str(app)])
    targets.logged(root, 'verify-distributable-bpy', ['bash', 'scripts/verify_bpy_bundle.sh', str(app), '--distribution'], timeout=300)
    write(root / 'assembled.json', {'sourceSHA': os.environ['GITHUB_SHA'], 'runID': int(os.environ['GITHUB_RUN_ID']),
        'appTreeSHA256': checkpoint.tree_digest(app), 'identity': checkpoint.identity(build),
        'newCompiledImageSHA256': checksum(production), 'distributionImageSHA256': checksum(original_image),
        'retainedSourceSHA': RETAINED_SOURCE, 'retainedSignedArtifact': SIGNED_ARTIFACT,
        'retainedFinalArtifact': FINAL_ARTIFACT, 'freshResourceSHA256': {name: checksum(Path(name)) for name in sorted(fresh_resources)},
        'retainedPackSHA256': PACK_SHA, 'retainedPackTreeSHA256': PACK_TREE,
        'unchangedSourceComponentObjects': {name: targets.capture.git('rev-parse', 'HEAD:' + name) for name in component_paths}})


def verify_pack(root):
    require(checksum(root / 'musicvideo.ngvpack.zip') == PACK_SHA
        and checkpoint.tree_digest(root / 'musicvideo.ngvpack') == PACK_TREE, 'Retained pack changed')
    subprocess.run(['codesign', '--verify', '--strict', str(root / 'musicvideo.ngvpack')],
        stdin=subprocess.DEVNULL, check=True, timeout=60)
    subprocess.run(['xcrun', 'stapler', 'validate', str(root / 'musicvideo.ngvpack')],
        stdin=subprocess.DEVNULL, check=True, timeout=60)


def retain_assembly(root, output, job_status):
    native_guard(root)
    root.mkdir(parents=True, exist_ok=True)
    build = Path('.build')
    products = {name: {'treeSHA256': checkpoint.tree_digest(build / name),
        'rootMode': stat.S_IMODE((build / name).lstat().st_mode)}
        for name in ('NexGenVideo.app', 'NexGenVideo.dSYM') if (build / name).is_dir()}
    for name, product in products.items():
        folder = build / name
        entries = {}
        for path in sorted(folder.rglob('*')):
            record = {'mode': stat.S_IMODE(path.lstat().st_mode)}
            if path.is_symlink():
                record.update(kind='symlink', target=os.readlink(path))
            elif path.is_dir():
                record['kind'] = 'directory'
            else:
                require(path.is_file(), 'Partial App product contains a special file')
                record.update(kind='file', bytes=path.stat().st_size, sha256=checksum(path))
            entries[path.relative_to(folder).as_posix()] = record
        product['entries'] = entries
    archives = {name: {'bytes': (output / name).stat().st_size, 'sha256': checksum(output / name)}
        for name in (*checkpoint.FILES, 'manifest.json') if (output / name).is_file()}
    state = {'schema': 'compiled-app-assembly-retention/v1', 'sourceSHA': os.environ['GITHUB_SHA'],
        'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1, 'appSourceSHA': APP_SOURCE,
        'jobStatusAtRetention': job_status, 'products': products, 'signedInputFiles': archives,
        'status': 'RETAINED_UNQUALIFIED_BYTES', 'functionalRCAccepted': False,
        'partialArchivesRequireIndependentQualification': True}
    write(root / 'assembly-retention.json', state)
    if products and job_status in ('failure', 'cancelled'):
        archive = root / 'unqualified-app-products.tar'
        require(not archive.exists(), 'Partial App retention archive is already occupied')
        targets.logged(root, 'retain-partial-new-app', ['tar', '-cf', str(archive), '-C', str(build), *products], timeout=300)
        state['rawProductsArchive'] = {'bytes': archive.stat().st_size, 'sha256': checksum(archive),
            'preservesModesAndSymlinks': True, 'qualified': False}
        write(root / 'assembly-retention.json', state)


def create_signed_input(root, output):
    native_guard(root)
    receipt = json.loads((root / 'receipt.json').read_text())
    verify_receipt(receipt, os.environ['GITHUB_SHA'], int(os.environ['GITHUB_RUN_ID']))
    assembled = json.loads((root / 'assembled.json').read_text())
    build = Path('.build')
    require(assembled['sourceSHA'] == os.environ['GITHUB_SHA'] and assembled['runID'] == int(os.environ['GITHUB_RUN_ID'])
        and assembled['appTreeSHA256'] == checkpoint.tree_digest(build / 'NexGenVideo.app')
        and assembled['identity'] == checkpoint.identity(build), 'Assembled App changed before signed checkpoint')
    output.mkdir(parents=True, exist_ok=False)
    targets.logged(root, 'archive-new-signed-app', ['/usr/bin/ditto', '-c', '-k', '--keepParent',
        str(build / 'NexGenVideo.app'), str(output / 'NexGenVideo.zip')], timeout=300)
    for name, paths in [('symbols.tar.gz', ['NexGenVideo.dSYM', 'NexGenVideoDiagnostics.dSYM',
            'NexGenEngine.dSYM', 'MusicvideoPlugin.dSYM']), ('plugins.tar.gz', ['plugins'])]:
        targets.logged(root, 'checkpoint-' + name, ['tar', '-czf', str(output / name), '-C', str(build), *paths], timeout=300)
    shutil.copyfile(build / 'bpy-source/bpy-source-receipt.json', output / 'bpy-source-receipt.json')
    manifest = {'schema': 'release-signed-input/v1', 'repository': REPOSITORY, 'sourceSHA': os.environ['GITHUB_SHA'],
        'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1, 'identity': assembled['identity'],
        'appTreeSHA256': assembled['appTreeSHA256'], 'nativeEvidence': receipt,
        'files': {name: {'bytes': (output / name).stat().st_size, 'sha256': checksum(output / name)} for name in checkpoint.FILES}}
    checkpoint.validate_app_zip(output / 'NexGenVideo.zip')
    checkpoint.verify_manifest(manifest, os.environ['GITHUB_SHA'], int(os.environ['GITHUB_RUN_ID']))
    write(output / 'manifest.json', manifest)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=('validate-inputs', 'acquire', 'test', 'assemble', 'create-signed-input', 'verify-pack', 'retain-assembly'))
    parser.add_argument('--root', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--job-status', choices=('success', 'failure', 'cancelled'))
    args = parser.parse_args()
    if args.action == 'validate-inputs':
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        raw = event.get('inputs', {}).get('compiled_app_targets_json', '')
        if raw:
            selected = selectors(raw, event)
            for role, value in selected.items():
                producer(value, role)
    elif args.action == 'verify-pack':
        require(args.root is not None, 'Exact pack root required')
        verify_pack(args.root)
    else:
        require(args.root is not None, 'Exact compiled App root required')
        if args.action == 'acquire': acquire_products(args.root)
        elif args.action == 'test': run_tests(args.root)
        elif args.action == 'assemble': assemble(args.root)
        elif args.action == 'retain-assembly':
            require(args.output is not None and args.job_status is not None, 'Exact assembly retention context required')
            retain_assembly(args.root, args.output, args.job_status)
        else:
            require(args.output is not None, 'Exact signed input output required')
            create_signed_input(args.root, args.output)
