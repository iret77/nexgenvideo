from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact


FIXTURE = Path(__file__).with_name('fixtures') / 'compiled-core-reuse-886.json'
FIXTURE_SHA = 'e8d290a0be18ce7a4fe3527439cfa537f30b951ec197df974844e119c921fe5a'


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def persist_bytes(path, raw):
    with path.open('xb') as stream:
        stream.write(raw); stream.flush(); os.fsync(stream.fileno())
    sync_directory(path.parent)


def persist(path, value):
    persist_bytes(path, (json.dumps(value, indent=2, allow_nan=False) + '\n').encode())


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True, allow_nan=False).encode()


def origin():
    raw = FIXTURE.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == FIXTURE_SHA, 'Retained native origin fixture changed')
    value = json.loads(raw)
    require(value.get('schema') == 'compiled-complete-core-origin/v1', 'Unsupported retained native origin')
    return value


def event_proof(folder, prefix, expected, module, release):
    events = release.verify_events(folder / prefix / 'events.jsonl', expected, module)
    starts, ends = Counter(), Counter()
    with (folder / prefix / 'events.jsonl').open(encoding='utf-8') as stream:
        for line in stream:
            record = json.loads(line)
            if record.get('kind') != 'event':
                continue
            event = record['payload']
            if event['kind'] == 'testCaseStarted':
                starts[event['testID']] += 1
            elif event['kind'] == 'testCaseEnded':
                ends[event['testID']] += 1
    require(starts == ends == Counter(expected['expectedCaseCountsByFunction']), 'Retained parameter cases changed')
    return {'events': events, 'parameterCaseCounts': dict(sorted(starts.items())),
        'eventSHA256': checksum(folder / prefix / 'events.jsonl')}


def derive(folder, fixture, expected, release):
    from run_macos_tests import framework_output
    read = lambda name: json.loads((folder / name).read_text())
    app = event_proof(folder, 'app-swift-testing', expected['modules']['app'], 'NexGenVideoTests', release)
    app.update(process=read('app-swift-testing/process.json'), hostReceipt=read('app-swift-testing/host-receipt.json'),
        command=read('app-swift-testing/command.json'), consoleSHA256=checksum(folder / 'app-swift-testing/console.log'),
        framework=framework_output(folder / 'app-swift-testing/console.log', 1, 0))
    engine = event_proof(folder, 'retained-engine/engine-swift-testing', expected['modules']['engine'], 'NexGenEngineTests', release)
    engine.update(environment=read('retained-engine/current-environment.json'),
        consoleSHA256=checksum(folder / 'retained-engine/engine-swift-testing/console.log'),
        originalJobSHA256=checksum(folder / 'retained-engine/original-job.log'),
        framework=framework_output(folder / 'retained-engine/engine-swift-testing/console.log', 1, 0),
        sourceObjects=fixture['engineSourceObjects'])
    return {'schema': 'retained-complete-native-core/v1', 'originalExecution': fixture['originalExecution'],
        'appSourceSHA': fixture['appSourceSHA'], 'nativeSourceObjects': fixture['nativeSourceObjects'],
        'compilerSHA256': fixture['compilerSHA256'], 'selected': fixture['compiledSelectors'],
        'criteriaSHA256': fixture['criteriaSHA256'], 'memberIdentities': fixture['members'], 'app': app, 'engine': engine,
        'xctest': {'verified': read('xctest/verified.json'), 'process': read('xctest/process.json'),
            'command': read('xctest/command.json'), 'discovery': read('xctest/discovery.json')}}


def process_identity(process, pid, parent):
    observed = process.get('observation', {})
    capture = observed.get('outputCapture', {})
    require(type(pid) is int and pid > 1 and type(parent) is int and parent > 1
        and process.get('pid') == observed.get('pid') == pid and observed.get('parentPID') == parent
        and type(process.get('exitCode')) is int and process['exitCode'] == 0
        and type(capture.get('originalExitCode')) is int and capture['originalExitCode'] == 0
        and capture.get('eof') is True, 'Original complete native process or EOF differs')


def verify_events_data(proof, expected, executions, skips):
    events = proof.get('events', {})
    for key, expected_key in [('discoveredFunctionIDs', 'exactDiscoveredFunctionIDs'),
            ('startedFunctionIDs', 'exactEndedFunctionIDs'), ('endedFunctionIDs', 'exactEndedFunctionIDs'),
            ('skippedFunctionIDs', 'exactSkippedFunctionIDs')]:
        require(events.get(key) == sorted(expected[expected_key]), 'Retained native function coverage differs: ' + key)
    require(type(events.get('functionExecutions')) is int and events['functionExecutions'] == executions
        and len(events['skippedFunctionIDs']) == skips and type(events.get('recordCount')) is int and events['recordCount'] > 0
        and type(events.get('runStarted')) is int and type(events.get('runEnded')) is int
        and events['runStarted'] == events['runEnded'] == 1
        and proof.get('parameterCaseCounts') == expected['expectedCaseCountsByFunction'], 'Retained executions or cases differ')
    framework = proof.get('framework', {})
    require(framework.get('passed') is True and framework.get('failures') == []
        and all(framework.get(key) == {'swiftTesting': 1, 'xctest': 0}
            for key in ('expectedRuns', 'startedRuns', 'completedRuns')), 'Retained framework did not complete')


def verify(proof, receipt, expected, release):
    import native_xctest_host
    fixture = origin()
    require(isinstance(proof, dict) and hashlib.sha256(canonical(proof)).hexdigest() == fixture['proofSHA256'],
        'Original retained native proof changed')
    require(proof.get('schema') == 'retained-complete-native-core/v1'
        and proof.get('originalExecution') == fixture['originalExecution']
        and proof.get('selected') == receipt['selected'] == fixture['compiledSelectors']
        and proof.get('nativeSourceObjects') == receipt['nativeSourceObjects'] == fixture['nativeSourceObjects']
        and proof.get('appSourceSHA') == receipt['appSourceSHA'] == fixture['appSourceSHA']
        and proof.get('compilerSHA256') == receipt['compilerSHA256'] == fixture['compilerSHA256']
        and proof.get('criteriaSHA256') == receipt['criteriaSHA256'] == fixture['criteriaSHA256']
        and proof.get('memberIdentities') == fixture['members'], 'Retained complete native scope or producer differs')
    require(receipt.get('counts') == fixture['counts'] and receipt.get('freshProofs') == {},
        'Retained processes cannot be represented as current executions')
    require(native_xctest_host.inputs() == fixture['hostInputs'], 'Retained XCTest compiler inputs changed')
    for phase in release.PHASES:
        selected = receipt['selected'][phase]
        product = receipt['products'][phase]['receipt']
        require(hashlib.sha256((json.dumps(product, indent=2) + '\n').encode()).hexdigest() == selected['receiptSHA256']
            and product.get('schema') == 'native-app-target-product/v1' and product.get('phase') == phase
            and product.get('sourceSHA') == selected['sourceSHA'] and product.get('runID') == selected['runID']
            and product.get('attempt') == 1 and product.get('appSourceSHA') == fixture['appSourceSHA']
            and product.get('nativeSourceObjects') == fixture['nativeSourceObjects']
            and product.get('compilerSHA256') == fixture['compilerSHA256']
            and product.get('state', {}).get('compileComplete') is True and product['state'].get('linkComplete') is True
            and receipt['products'][phase].get('originalArchiveSHA256') == selected['artifactSHA256'],
            'Retained native compiler product differs')
    source = fixture['originalExecution']['sourceSHA']
    xctest = proof['xctest']; xproof = xctest['verified']
    native_xctest_host.verify_proof(xproof, expected['xctest']['exactIndividualPassedIDs'], source,
        receipt['products']['tests']['receipt'])
    process_identity(xctest['process'], xproof['pid'], xproof['parentPID'])
    require(xctest['process'].get('parentPID') == xproof['parentPID']
        and xctest['process']['observation'].get('hostSHA256') == xproof.get('hostSHA256')
        and xctest['process']['observation'].get('hostExecutable') == xproof.get('hostReceipt', {}).get('hostPath')
        and len(xctest['command']) == 6 and xctest['command'][:2] == [xproof['hostReceipt']['hostPath'], xproof['hostReceipt']['bundlePath']]
        and xctest['discovery'].get('passed') is False, 'Original XCTest discovery, command, image or parent changed')
    app = proof['app']; host = app['hostReceipt']; parent = host.get('parentPID'); pid = host.get('pid')
    process_identity(app['process'], pid, parent)
    require(parent == xproof['parentPID'] and host.get('sourceSHA') == source and type(host.get('schema')) is int
        and host['schema'] == 1 and host.get('eventRecordCount') == app['events']['recordCount']
        and host.get('recordingError') is None and host.get('error') is None
        and all(host.get(key) is True for key in ('mainThread', 'applicationRunningAtStart', 'started',
            'completed', 'abiSucceeded', 'runReturnedAfterCompletion'))
        and app['process']['observation'].get('hostExecutable') == host.get('hostExecutable')
        and app['process']['observation'].get('hostSHA256') == release.retained.HOST_SHA
        and app['command'] == [host['hostExecutable'], '--event-stream-version', '0', '--no-parallel'],
        'Retained original AppKit ABI execution differs')
    verify_events_data(app, expected['modules']['app'], 3712, 8)
    require(set(expected['originalEightAppFailureIDsRequiredToEndWithoutIssues']) <= set(app['events']['endedFunctionIDs']),
        'Original eight App functions did not complete')
    require(app['eventSHA256'] == fixture['members']['app-swift-testing/events.jsonl']['sha256']
        and app['consoleSHA256'] == fixture['members']['app-swift-testing/console.log']['sha256'], 'Original App stream changed')
    engine = proof['engine']
    verify_events_data(engine, expected['modules']['engine'], 896, 14)
    require(engine.get('sourceObjects') == fixture['engineSourceObjects']
        and engine['eventSHA256'] == release.engine.EVENT_DIGEST
        and engine['consoleSHA256'] == release.engine.CONSOLE_DIGEST
        and engine['originalJobSHA256'] == release.engine.LOG_DIGEST, 'Retained Engine source or observations differ')
    environment = engine.get('environment', {})
    require(environment.get('architecture') == 'arm64'
        and set(environment.get('original', {})) == {'swift', 'xcode', 'python', 'osVersion', 'osBuild'}
        and environment.get('current') == environment['original']
        and receipt.get('currentRetainedEnvironment') == environment, 'Retained native runtime context differs')
    return receipt


def acquire(root, bound, expected, release):
    from verified_pr_source_checks import read_api
    fixture = origin(); selected = fixture['originalExecution']
    require(bound.get('appSourceSHA') == fixture['appSourceSHA'] and bound.get('selected') == fixture['compiledSelectors']
        and bound.get('nativeSourceObjects') == fixture['nativeSourceObjects']
        and bound.get('sourceSHA') == os.environ['GITHUB_SHA'] and bound.get('runID') == int(os.environ['GITHUB_RUN_ID'])
        and release.source_objects('HEAD') == fixture['nativeSourceObjects'], 'Closed retained native candidate changed')
    require(checksum(release.CRITERIA) == fixture['criteriaSHA256'], 'Retained native independent inventory changed')
    run = api('actions/runs/' + str(selected['runID']))
    jobs = api(f"actions/runs/{selected['runID']}/attempts/1/jobs?per_page=100")
    require(run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and run.get('id') == selected['runID'] and run.get('head_sha') == selected['sourceSHA']
        and run.get('run_attempt') == 1 and run.get('status') == 'completed' and run.get('conclusion') == 'failure'
        and run.get('workflow_id') == 303346287 and run.get('path') == '.github/workflows/release.yml'
        and run.get('event') == 'workflow_dispatch' and run.get('actor', {}).get('login') == 'iret77'
        and jobs.get('total_count') == len(jobs.get('jobs', [])), 'Original retained native workflow differs')
    matched = [job for job in jobs['jobs'] if job.get('id') == selected['jobID']]
    require(len(matched) == 1, 'Original complete native producer is missing')
    job = matched[0]
    require(job.get('name') == 'release-build' and job.get('run_id') == selected['runID']
        and job.get('head_sha') == selected['sourceSHA'] and job.get('run_attempt') == 1
        and job.get('status') == 'completed' and job.get('conclusion') == 'failure' and job.get('labels') == ['macrunner'],
        'Original retained native job differs')
    artifact = api('actions/artifacts/' + str(selected['artifactID']))
    verify_artifact(artifact, run, job, selected['artifactID'], selected['artifactSHA256'],
        f"release-compiled-app-evidence-{selected['runID']}-a1")
    folder = root / 'retained-core'; folder.mkdir(exist_ok=False); sync_directory(root)
    archive_path = folder / 'original.zip'
    download(artifact, archive_path)
    with archive_path.open('rb') as stream:
        os.fsync(stream.fileno())
    raw_log = read_api(f"actions/jobs/{selected['jobID']}/logs", 4_000_000)
    require(hashlib.sha256(raw_log).hexdigest() == selected['fullRawSHA256'], 'Original full native producer log changed')
    persist_bytes(folder / 'original-job.log', raw_log)
    persist(folder / 'originals-secured.json', {'run': run, 'job': job, 'artifact': artifact,
        'fullRawSHA256': selected['fullRawSHA256'], 'originalArchiveSHA256': selected['artifactSHA256']})
    records = folder / 'original-records'; records.mkdir()
    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(name.casefold() for name in names)) <= 200_000,
            'Retained native archive contains duplicate members')
        require(sorted(names) == fixture['archiveNames'], 'Original complete native archive inventory changed')
        for name, identity in fixture['members'].items():
            raw = archive_bytes(archive, name, 16 * 1024**2)
            require(len(raw) == identity['bytes'] and hashlib.sha256(raw).hexdigest() == identity['sha256'],
                'Original retained native record changed: ' + name)
            target = records / name; target.parent.mkdir(parents=True, exist_ok=True); persist_bytes(target, raw)
    prior = json.loads((records / 'bound.json').read_text())
    require(prior.get('schema') == 'compiled-app-release-binding/v1' and prior.get('sourceSHA') == selected['sourceSHA']
        and prior.get('runID') == selected['runID'] and prior.get('selected') == bound['selected']
        and prior.get('nativeSourceObjects') == bound['nativeSourceObjects']
        and all(prior['products'][phase]['receipt'] == bound['products'][phase]['receipt'] for phase in release.PHASES),
        'Original complete native product binding changed')
    require(json.loads((records / 'verify-test-bundle.exit.json').read_text()) == {'exitCode': 0},
        'Original native test signature verification did not succeed')
    require({name: release.targets.capture.git('rev-parse', 'HEAD:' + name) for name in fixture['engineSourceObjects']}
        == fixture['engineSourceObjects'], 'Retained Engine source changed')
    proof = derive(records, fixture, expected, release)
    image = Path(bound['products']['tests']['output'])
    require(checksum(image) == proof['xctest']['verified']['bundleImageSHA256']
        and checksum(image.parents[2] / 'Contents/Helpers/NexGenVideoXCTestHost') == proof['xctest']['verified']['hostSHA256']
        and checksum(Path(bound['runtime']) / 'NexGenVideoAppKitTestHost') == release.retained.HOST_SHA
        and checksum(Path(bound['prepared']['plans']['production']['driver']['argv'][0])) == fixture['compilerSHA256'],
        'Current retained executable products differ')
    context = release.engine_environment((records / 'retained-engine/original-job.log').read_bytes())
    receipt = {'schema': 'release-native-compiled-app/v4', 'sourceSHA': bound['sourceSHA'], 'runID': bound['runID'],
        'attempt': 1, 'appSourceSHA': fixture['appSourceSHA'], 'nativeSourceObjects': bound['nativeSourceObjects'],
        'compilerSHA256': fixture['compilerSHA256'], 'selected': bound['selected'],
        'products': {phase: {'receipt': bound['products'][phase]['receipt'],
            'originalArchiveSHA256': bound['products'][phase]['originalArchiveSHA256']} for phase in release.PHASES},
        'hostSHA256': release.retained.HOST_SHA, 'criteriaSHA256': fixture['criteriaSHA256'], 'passed': True,
        'counts': fixture['counts'], 'freshProofs': {}, 'retainedNative': proof, 'currentRetainedEnvironment': context}
    release.verify_receipt(receipt, bound['sourceSHA'], bound['runID'])
    persist(folder / 'verified.json', proof)
    persist(root / 'receipt.json', receipt)
    return receipt
