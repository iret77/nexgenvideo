import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile

import app_cohort_v2 as cohort
import compiled_core_reuse as core
from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact

FIXTURE = Path(__file__).with_name('fixtures') / 'compiled-current-core-reuse-1047.json'
FIXTURE_SHA = '4c837a106bb3340f61efebe86b62ed7dbfe1296ccfd682972cb0407b4b76ab06'


def origin():
    raw = FIXTURE.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == FIXTURE_SHA, 'Current retained native origin changed')
    value = json.loads(raw)
    require(value.get('schema') == 'compiled-current-core-origin/v1', 'Unsupported current native origin')
    return value


def matches(bound):
    return bound.get('appSourceSHA') == origin()['appSourceSHA']


def context(source):
    value = cohort.manifest(source)
    raw = subprocess.check_output(['git', 'show', source + ':' + cohort.MANIFEST.as_posix()],
        stdin=subprocess.DEVNULL, timeout=30)
    return {'schema': 'verified-native-app-cohort/v2', 'manifestSHA256': hashlib.sha256(raw).hexdigest(),
        'appSourceSHA': value['appSourceSHA'], 'appTreeSHA': value['appTreeSHA'], 'harnessSourceSHA': source,
        'nativeSourceObjects': value['nativeSourceObjects'], 'roleSourceObjects': value['roleSourceObjects'],
        'componentSourceObjects': value['componentSourceObjects']}


def criteria(fixture, current_context):
    source = fixture['originalExecution']['sourceSHA']
    previous = cohort.verify_context(fixture['originalCohort'])
    current = cohort.verify_context(current_context)
    require(fixture['originalCohort']['harnessSourceSHA'] == source
        and current['appSourceSHA'] == previous['appSourceSHA'] == fixture['appSourceSHA']
        and current['nativeSourceObjects'] == previous['nativeSourceObjects'] == fixture['nativeSourceObjects']
        and current['roleSourceObjects'] == previous['roleSourceObjects']
        and current['componentSourceObjects'] == previous['componentSourceObjects']
        and current['retainedXCTestHost'] == previous['retainedXCTestHost'], 'Retained native source or host changed')
    allowed = cohort.consumer_ci_paths(source, current_context['harnessSourceSHA'])
    changed = cohort.git('diff', '--name-only', '--no-renames', source, current_context['harnessSourceSHA']).splitlines()
    require(set(changed) <= allowed, 'Retained native continuation changed outside the CI closure')
    raw = subprocess.check_output(['git', 'show', source + ':' + previous['criteria']['path']],
        stdin=subprocess.DEVNULL, timeout=30)
    require(hashlib.sha256(raw).hexdigest() == fixture['originalCriteriaSHA256'] == previous['criteria']['sha256'],
        'Original native criteria bytes changed')
    original = json.loads(raw)
    key = 'originalEightAppFailureIDsRequiredToEndWithoutIssues'
    corrections = fixture['originalCriteriaCorrections']
    require(len(corrections) == 2 and set(corrections) <= set(original[key]), 'Unexpected native criteria correction')
    original[key] = [corrections.get(identity, identity) for identity in original[key]]
    raw_current = subprocess.check_output(['git', 'show', current_context['harnessSourceSHA'] + ':' + current['criteria']['path']],
        stdin=subprocess.DEVNULL, timeout=30)
    require(hashlib.sha256(raw_current).hexdigest() == fixture['criteriaSHA256'] == current['criteria']['sha256']
        and json.loads(raw_current) == original, 'Native criteria changed beyond the exact two source locations')
    return cohort.criteria(current_context['harnessSourceSHA'])


def derive(folder, fixture, expected, release):
    proof = core.derive(folder, fixture, expected, release)
    proof['schema'] = 'retained-current-native-core/v1'
    return proof


def verify(proof, receipt, release):
    from app_release_v2 import verify_xctest
    fixture = origin()
    require(isinstance(proof, dict) and hashlib.sha256(core.canonical(proof)).hexdigest() == fixture['proofSHA256'],
        'Complete original current native proof changed')
    expected = criteria(fixture, receipt.get('cohortV2'))
    current = cohort.verify_context(receipt['cohortV2'])
    require(proof.get('schema') == 'retained-current-native-core/v1'
        and proof.get('originalExecution') == fixture['originalExecution']
        and proof.get('selected') == receipt.get('selected') == fixture['compiledSelectors']
        and proof.get('nativeSourceObjects') == receipt.get('nativeSourceObjects') == fixture['nativeSourceObjects']
        and proof.get('appSourceSHA') == receipt.get('appSourceSHA') == fixture['appSourceSHA']
        and proof.get('compilerSHA256') == receipt.get('compilerSHA256') == fixture['compilerSHA256']
        and proof.get('criteriaSHA256') == receipt.get('criteriaSHA256') == fixture['criteriaSHA256']
        and proof.get('memberIdentities') == fixture['members']
        and receipt.get('counts') == fixture['counts'] and receipt.get('freshProofs') == {},
        'Retained current scope or original execution identity differs')
    require(set(receipt.get('products', {})) == set(release.PHASES), 'Incomplete retained compiler roles')
    release.selector_identities(json.dumps(receipt['selected']))
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
            'Retained current compiler product differs')
        cohort.compatible_product(product, {'cohortV2': receipt['cohortV2'], 'compilerSHA256': receipt['compilerSHA256'],
            'plans': product.get('recipePlan', {})}, phase)
    source = fixture['originalExecution']['sourceSHA']
    xctest = proof['xctest']; xproof = xctest['verified']
    verify_xctest(xproof, expected['xctest']['exactIndividualPassedIDs'], source, receipt['products']['tests']['receipt'], current)
    core.process_identity(xctest['process'], xproof['pid'], xproof['parentPID'])
    require(xctest['process'].get('parentPID') == xproof['parentPID']
        and xctest['process']['observation'].get('hostSHA256') == xproof['hostSHA256']
        and xctest['process']['observation'].get('hostExecutable') == xproof['hostReceipt']['hostPath']
        and len(xctest['command']) == 6 and xctest['command'][:2] == [xproof['hostReceipt']['hostPath'], xproof['hostReceipt']['bundlePath']]
        and xctest['discovery'].get('passed') is False and xctest['discovery'].get('boundary') == 'discovery-complete'
        and xctest['discovery'].get('schema') == 'native-xctest-host-checkpoint/v1'
        and xctest['discovery'].get('discoveredTestCaseCount') == 48
        and xctest['discovery'].get('bundlePath') == xproof['hostReceipt']['bundlePath']
        and xctest['discovery'].get('hostPath') == xproof['hostReceipt']['hostPath']
        and xctest['discovery'].get('inventoryIDs') == expected['xctest']['exactIndividualPassedIDs']
        and xctest['discovery'].get('sourceSHA') == source and xctest['discovery'].get('pid') == xproof['pid']
        and xctest['discovery'].get('parentPID') == xproof['parentPID'], 'Original current XCTest process or discovery changed')
    app = proof['app']; host = app['hostReceipt']; pid = host.get('pid'); parent = host.get('parentPID')
    core.process_identity(app['process'], pid, parent)
    require(parent == xproof['parentPID'] and host.get('sourceSHA') == source and type(host.get('schema')) is int and host['schema'] == 1
        and host.get('eventRecordCount') == app['events']['recordCount'] and host.get('recordingError') is None and host.get('error') is None
        and all(host.get(key) is True for key in ('mainThread', 'applicationRunningAtStart', 'started', 'completed', 'abiSucceeded', 'runReturnedAfterCompletion'))
        and app['process']['observation'].get('hostExecutable') == host.get('hostExecutable')
        and app['process']['observation'].get('hostSHA256') == release.retained.HOST_SHA
        and host.get('bundleBinary') == str(Path(xproof['hostReceipt']['bundlePath']) / 'Contents/MacOS/NexGenVideoTests')
        and app['command'] == [host['hostExecutable'], '--event-stream-version', '0', '--no-parallel'],
        'Retained current AppKit execution differs')
    core.verify_events_data(app, expected['modules']['app'], 3696, 8)
    require(set(expected['originalEightAppFailureIDsRequiredToEndWithoutIssues']) <= set(app['events']['endedFunctionIDs'])
        and app['eventSHA256'] == fixture['members']['app-swift-testing/events.jsonl']['sha256']
        and app['consoleSHA256'] == fixture['members']['app-swift-testing/console.log']['sha256'], 'Original App scope or stream changed')
    engine = proof['engine']
    core.verify_events_data(engine, expected['modules']['engine'], 896, 14)
    require(engine.get('sourceObjects') == fixture['engineSourceObjects']
        and cohort.objects(receipt['cohortV2']['harnessSourceSHA'], fixture['engineSourceObjects']) == fixture['engineSourceObjects']
        and engine['eventSHA256'] == release.engine.EVENT_DIGEST and engine['consoleSHA256'] == release.engine.CONSOLE_DIGEST
        and engine['originalJobSHA256'] == release.engine.LOG_DIGEST, 'Retained original Engine evidence changed')
    environment = engine['environment']
    require(environment.get('architecture') == 'arm64' and set(environment.get('original', {})) == {'swift', 'xcode', 'python', 'osVersion', 'osBuild'}
        and environment.get('current') == environment['original'] and receipt.get('currentRetainedEnvironment') == environment,
        'Retained native runtime environment changed')
    return receipt


def acquire(root, bound, release):
    from verified_pr_source_checks import read_api
    release.native_guard(root)
    fixture = origin(); selected = fixture['originalExecution']
    current_context = context(os.environ['GITHUB_SHA'])
    cohort.verify_context(current_context, current=True)
    expected = criteria(fixture, current_context)
    require(bound.get('appSourceSHA') == fixture['appSourceSHA'] and bound.get('selected') == fixture['compiledSelectors']
        and bound.get('nativeSourceObjects') == release.source_objects('HEAD') == fixture['nativeSourceObjects']
        and bound.get('sourceSHA') == os.environ['GITHUB_SHA'] and bound.get('runID') == int(os.environ['GITHUB_RUN_ID']),
        'Current retained candidate differs')
    run = api('actions/runs/' + str(selected['runID']))
    jobs = api(f"actions/runs/{selected['runID']}/attempts/1/jobs?per_page=100")
    require(run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo' and run.get('id') == selected['runID']
        and run.get('head_sha') == selected['sourceSHA'] and run.get('run_attempt') == 1
        and run.get('status') == 'completed' and run.get('conclusion') == 'failure' and run.get('workflow_id') == 303346287
        and run.get('path') == '.github/workflows/release.yml' and run.get('event') == 'workflow_dispatch'
        and run.get('actor', {}).get('login') == 'iret77' and jobs.get('total_count') == len(jobs.get('jobs', [])),
        'Original current native producer changed')
    matched = [job for job in jobs['jobs'] if job.get('id') == selected['jobID']]
    require(len(matched) == 1, 'Original current native job missing')
    job = matched[0]
    require(job.get('name') == 'release-build' and job.get('run_id') == selected['runID'] and job.get('head_sha') == selected['sourceSHA']
        and job.get('run_attempt') == 1 and job.get('status') == 'completed' and job.get('conclusion') == 'failure'
        and job.get('labels') == ['macrunner'], 'Original current native job differs')
    artifact = api('actions/artifacts/' + str(selected['artifactID']))
    verify_artifact(artifact, run, job, selected['artifactID'], selected['artifactSHA256'], f"release-compiled-app-evidence-{selected['runID']}-a1")
    folder = root / 'retained-core'; folder.mkdir(exist_ok=False); core.sync_directory(root)
    archive_path = folder / 'original.zip'; download(artifact, archive_path)
    with archive_path.open('rb') as stream: os.fsync(stream.fileno())
    raw_log = read_api(f"actions/jobs/{selected['jobID']}/logs", 4_000_000)
    require(hashlib.sha256(raw_log).hexdigest() == selected['fullRawSHA256'], 'Original current native full log changed')
    core.persist_bytes(folder / 'original-job.log', raw_log)
    core.persist(folder / 'originals-secured.json', {'run': run, 'job': job, 'artifact': artifact,
        'fullRawSHA256': selected['fullRawSHA256'], 'originalArchiveSHA256': selected['artifactSHA256']})
    records = folder / 'original-records'; records.mkdir()
    with zipfile.ZipFile(archive_path) as archive:
        require(sorted(archive.namelist()) == fixture['archiveNames'], 'Original current native archive inventory differs')
        for name, identity in fixture['members'].items():
            raw = archive_bytes(archive, name, 16 * 1024**2)
            require(len(raw) == identity['bytes'] and hashlib.sha256(raw).hexdigest() == identity['sha256'], 'Original current native member changed: ' + name)
            target = records / name; target.parent.mkdir(parents=True, exist_ok=True); core.persist_bytes(target, raw)
    prior = json.loads((records / 'bound.json').read_bytes())
    require(prior.get('schema') == 'compiled-app-release-binding/v1' and prior.get('sourceSHA') == selected['sourceSHA']
        and prior.get('runID') == selected['runID'] and prior.get('selected') == bound['selected']
        and prior.get('nativeSourceObjects') == bound['nativeSourceObjects']
        and prior['prepared']['cohortV2'] == fixture['originalCohort']
        and all(prior['products'][phase]['receipt'] == bound['products'][phase]['receipt'] for phase in release.PHASES)
        and json.loads((records / 'verify-test-bundle.exit.json').read_bytes()) == {'exitCode': 0},
        'Original current native binding or signature check differs')
    proof = derive(records, fixture, expected, release)
    image = Path(bound['products']['tests']['output'])
    require(checksum(image) == proof['xctest']['verified']['bundleImageSHA256']
        and checksum(image.parents[2] / 'Contents/Helpers/NexGenVideoXCTestHost') == proof['xctest']['verified']['hostSHA256']
        and checksum(Path(bound['runtime']) / 'NexGenVideoAppKitTestHost') == release.retained.HOST_SHA
        and checksum(Path(bound['prepared']['plans']['production']['driver']['argv'][0])) == fixture['compilerSHA256'],
        'Current native executable bytes differ')
    environment = release.engine_environment((records / 'retained-engine/original-job.log').read_bytes())
    receipt = {'schema': 'release-native-compiled-app/v6', 'sourceSHA': bound['sourceSHA'], 'runID': bound['runID'],
        'attempt': 1, 'appSourceSHA': fixture['appSourceSHA'], 'nativeSourceObjects': bound['nativeSourceObjects'],
        'compilerSHA256': fixture['compilerSHA256'], 'selected': bound['selected'], 'cohortV2': current_context,
        'products': {phase: {'receipt': bound['products'][phase]['receipt'], 'originalArchiveSHA256': bound['products'][phase]['originalArchiveSHA256']} for phase in release.PHASES},
        'hostSHA256': release.retained.HOST_SHA, 'criteriaSHA256': fixture['criteriaSHA256'], 'passed': True,
        'counts': fixture['counts'], 'freshProofs': {}, 'retainedNative': proof, 'currentRetainedEnvironment': environment}
    release.verify_receipt(receipt, bound['sourceSHA'], bound['runID'])
    core.persist(folder / 'derived-proof.json', proof)
    core.persist(root / 'receipt.json', receipt)
    return receipt
