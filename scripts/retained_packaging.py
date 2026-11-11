"""Bind retained signed products to separately qualified packaging executions."""
import argparse
from contextlib import contextmanager
from contextvars import ContextVar
import hashlib
import datetime
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import zipfile

from retained_app_test_products import api as live_api, checksum as file_checksum, download, require, verify_artifact as live_verify_artifact
from verified_pr_source_checks import original_receipt, read_api as live_read_api, test_completion, verify_run_identity, verify_steps, verify_tree


REPOSITORY = "iret77/nexgenvideo"
MAX_PROOF_BYTES = 32 * 1024**2
MAX_CHAIN = 8
COMPLETE_ARTIFACT = "release-packaging-provenance"
RESTORED_ARTIFACT = "release-packaging-restored-proof"
PROOF_FILES = {"harness-source.json", "harness-source-original-proof.zip", "harness-source-original-job.log",
               "product-source.json", "product-source-original-proof.zip", "product-source-original-job.log",
               "signed-proof.zip", "prior-notary-state.zip", "original-api-evidence.zip"}
SOURCE_REUSE_FILES = {"bpy-source-original-receipt.json", "bpy-source-receipt.json", "bpy-source-reuse.json"}
OPTIONAL_PROOF_FILES = {"original-notary-state.zip", "submitted-dmg-proof.zip", "current-app-signature.reused.json", "component-native-checks.reused.json", "component-notary-observations.zip"} | SOURCE_REUSE_FILES
PRODUCT_OBJECTS = ("Sources", "Engine", "Tests", "Runtime", "Metal", "Vendor", "plugins",
                   "Package.swift", "Package.resolved", "assets")
VERIFIER_INPUTS = ('scripts/retained_packaging.py', 'scripts/retained_app_test_products.py',
                   'scripts/verified_pr_source_checks.py', 'scripts/release_checkpoint.py',
                   'scripts/release_native_proof.py', 'scripts/release_engine_resume.py', 'scripts/release_test_repair.py',
                   'scripts/app_host_zombie_diagnostic.py', 'scripts/run_macos_tests.py',
                   'scripts/verify_swift_test_output.py', 'scripts/verify_diagnostic_candidate.py',
                   'scripts/release_acceptance_identity.py', 'scripts/external-gui/acceptance.py')
VERIFIER_INPUTS += ('scripts/native_current_cohort.py', 'scripts/native_xctest_host.py', 'scripts/native_xctest_host.m',
                    'scripts/compiled_core_reuse.py', 'scripts/fixtures/compiled-core-reuse-886.json',
                    'scripts/compiled_app_release.py', 'scripts/compiled_xctest_reuse.py', 'scripts/fixtures/compiled-app-native-inventory.json',
                    'scripts/native_app_target_build.py', 'scripts/native_app_target_recipe.py',
                    'scripts/native_app_build_plan.py', 'scripts/fixtures/native-test-entry-point.json')
VERIFIER_INPUTS += ('scripts/consume_bpy_distributable_source.py',)
VERIFIER_INPUTS += ('scripts/compiled_component_reuse.py', 'scripts/notary_continuation.py')
VERIFIER_INPUTS += ('scripts/app_cohort_v2.py', 'scripts/app_release_v2.py',
                   'scripts/fixtures/app-cohort.json', 'scripts/fixtures/app-cohort-native-inventory.json')
PACKAGING_PATHS = {
    "scripts/plan_dmg_capacity.py", "scripts/test_release_dmg_packaging.py",
    "scripts/retained_packaging.py", "scripts/test_retained_packaging.py",
    "scripts/release_checkpoint.py", "scripts/test_release_recovery.py", "scripts/notarize.sh", "scripts/notary_submission.py",
    "scripts/test_notarize.py", "scripts/workspace_native_ci.py", "scripts/test_workspace_native_ci.py",
    "scripts/verify_diagnostic_candidate.py", "scripts/test_diagnostic_acceptance.py",
    "scripts/retained_release_runtime.py", "scripts/test_retained_release_runtime.py",
    "scripts/release_acceptance_identity.py", "scripts/test_release_acceptance_identity.py",
    "scripts/external-gui/acceptance.py", "scripts/external-gui/test_bundle.py",
    "scripts/external-gui/transport.py", "scripts/external-gui/transport_fixture.py", "scripts/test_external_gui_test_bundle.py",
    "scripts/test_external_transport.py", "scripts/chat_hang_replay.py",
    ".github/workflows/release.yml", ".github/workflows/bpy-runtime-acceptance.yml",
    ".github/workflows/external-gui-acceptance.yml", ".github/workflows/chat-hang-replay.yml",
    ".github/workflows/private-example-analysis.yml", ".github/workflows/workspace-ui-acceptance.yml",
    ".github/workflows/settings-owner-acceptance.yml", ".github/workflows/ci-batch.yml",
    ".github/workflows/diagnostic-acceptance.yml",
    "scripts/test_release_workflow.py", "scripts/test_private_example_workflow.py",
    "scripts/test_ci_workflow.py",
    ".github/actions/prepare-bpy-source/action.yml",
    "scripts/consume_bpy_distributable_source.py", "scripts/test_consume_bpy_distributable_source.py",
}
COMPILED_PACKAGING_PATHS = {'scripts/compiled_app_release.py', 'scripts/test_compiled_app_release.py',
    'scripts/native_current_cohort.py', 'scripts/test_native_current_cohort.py'}
CAPTURE = ContextVar('packaging_evidence_capture', default=None)
REPLAY = ContextVar('authenticated_packaging_evidence_replay', default=None)
BUDGET = ContextVar('packaging_expansion_budget', default=None)
COMPONENT_CAPTURE_GAP = {
    'runID': 42882367248, 'producerSourceSHA': 'a77d46545180d1d3dcc0bf311d307fb08f6bbed9',
    'productSourceSHA': 'a1375966dbe6d2dd7b918c726f09ac5d1f4f16fb', 'artifactID': 13797268238,
    'artifactSHA256': '92eb06bd223d7b40f84cdc023fb93ba44a457eea0981e35ea1a4c43c795120ad',
    'recordSHA256': '401c05b1c90b3bbc87813e8cdcdb1d1a7809794726a397c58f33f090cd6758b5',
    'acquisitionSHA256': '64f3060df5c33a18042149b28260c7caf0692c626060fa9d253d9b2e36079339'}
COMPONENT_CONSUMER_REPAIR_PATHS = {
    'scripts/retained_packaging.py', 'scripts/test_retained_packaging.py',
    'scripts/verify_diagnostic_candidate.py', 'scripts/test_diagnostic_acceptance.py',
    'scripts/compiled_app_release.py', 'scripts/test_compiled_app_release.py',
    'scripts/external-gui/acceptance.py', 'scripts/test_external_gui_test_bundle.py',
    'scripts/test_retained_runtime_failure_diagnostic.py',
    'scripts/test_private_example_workflow.py',
    '.github/workflows/release.yml', '.github/workflows/diagnostic-acceptance.yml',
    '.github/workflows/bpy-runtime-acceptance.yml', '.github/workflows/external-gui-acceptance.yml',
    '.github/workflows/workspace-ui-acceptance.yml', '.github/workflows/settings-owner-acceptance.yml',
    '.github/workflows/chat-hang-replay.yml', '.github/workflows/private-example-analysis.yml',
    '.github/workflows/ci-batch.yml', '.github/workflows/retained-runtime-failure-diagnostic.yml'}


def instant(value):
    return datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def api(route):
    replay = REPLAY.get()
    if replay is not None and not route.startswith(('git/', 'compare/', 'pulls/')):
        require(route in replay['json'], 'Original API evidence is missing: ' + route)
        return json.loads(json.dumps(replay['json'][route]))
    value = live_api(route)
    if CAPTURE.get() is not None and replay is None:
        CAPTURE.get()['json'][route] = json.loads(json.dumps(value))
    return value


def read_api(route, *args, **kwargs):
    replay = REPLAY.get()
    if replay is not None:
        require(route in replay['bytes'], 'Original API bytes are missing: ' + route)
        raw = replay['bytes'][route]
        maximum = kwargs.get('maximum', args[0] if args else 32 * 1024**2)
        require(len(raw) <= maximum, 'Historical original exceeds its read bound')
        return raw
    raw = live_read_api(route, *args, **kwargs)
    if CAPTURE.get() is not None:
        CAPTURE.get()['bytes'][route] = raw
    return raw


def verify_artifact(artifact, producer, job, artifact_id, checksum, name):
    replay = REPLAY.get()
    if replay is None:
        return live_verify_artifact(artifact, producer, job, artifact_id, checksum, name)
    require(artifact.get('id') == artifact_id and artifact.get('name') == name
            and artifact.get('digest') == 'sha256:' + checksum and artifact.get('expired') is False
            and artifact.get('workflow_run', {}).get('id') == producer['id']
            and artifact.get('workflow_run', {}).get('head_sha') == producer['head_sha'], 'Historical artifact identity differs')
    require(instant(job['started_at']) <= instant(artifact['created_at']) <= instant(artifact['updated_at']) <= instant(job['completed_at'])
            and instant(artifact['expires_at']) > replay['asOf'], 'Historical artifact was invalid at acquisition')


def encoded_api_evidence(captured, record):
    metadata = {'schema': 'nexgenvideo/packaging-api-acquisition/1', 'repository': REPOSITORY,
                'productSourceSHA': record['productSourceSHA'], 'producerSourceSHA': record['producerSourceSHA'],
                'runID': record['runID'], 'recordedAt': utc_now(),
                'json': captured['json'], 'legacy': captured['legacy'], 'bytes': {}}
    members = {}
    for route, raw in captured['bytes'].items():
        name = digest(raw) + '.bin'
        members[name] = raw
        metadata['bytes'][route] = {'name': name, 'bytes': len(raw), 'sha256': digest(raw)}
    members['acquisition.json'] = encoded(metadata)
    require(sum(map(len, members.values())) <= MAX_PROOF_BYTES, 'Original API evidence exceeds its bound')
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, raw in members.items(): archive.writestr(name, raw)
    return buffer.getvalue()


def component_consumer_repair_paths(record):
    return COMPONENT_CONSUMER_REPAIR_PATHS if digest(encoded(record)) == COMPONENT_CAPTURE_GAP['recordSHA256'] else set()


def supplement_execution():
    value = {key: os.environ.get(key, '') for key in
             ('GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB', 'GITHUB_SHA')}
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and value['GITHUB_REPOSITORY'] == REPOSITORY
            and re.fullmatch('[1-9][0-9]*', value['GITHUB_RUN_ID']) and value['GITHUB_RUN_ATTEMPT'] == '1'
            and re.fullmatch('[A-Za-z0-9_-]+', value['GITHUB_JOB'])
            and re.fullmatch('[a-f0-9]{40}', value['GITHUB_SHA']), 'Supplement requires an actual owned Actions execution')
    return value


def persist_supplement_member(path, raw):
    require(not path.exists() and not path.is_symlink(), 'Supplement destination was already consumed')
    with path.open('xb') as stream:
        stream.write(raw); stream.flush(); os.fsync(stream.fileno())
    descriptor = os.open(path.parent, os.O_RDONLY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)


def component_origin_supplement(raw, record, container, acquisition, originals):
    gap = COMPONENT_CAPTURE_GAP
    if record.get('runID') != gap['runID']:
        return None
    require(digest(encoded(record)) == gap['recordSHA256'] and digest(raw) == gap['acquisitionSHA256']
            and record.get('productSourceSHA') == gap['productSourceSHA']
            and record.get('producerSourceSHA') == gap['producerSourceSHA'] and record.get('stage') == 'complete'
            and record.get('attempt') == 1 and container.get('id') == gap['artifactID']
            and container.get('digest') == 'sha256:' + gap['artifactSHA256']
            and container.get('workflow_run', {}).get('id') == gap['runID']
            and container.get('workflow_run', {}).get('head_sha') == gap['producerSourceSHA'],
            'Component capture gap is not the exact immutable original')
    from compiled_component_reuse import ORIGIN
    origin = ORIGIN['runID']
    json_values, derivations = {}, {}
    for kind, field, identifier in (('jobs', 'jobs', ORIGIN['releaseJobID']),
                                     ('artifacts', 'artifacts', ORIGIN['assemblyArtifactID'])):
        inventory_route = f'actions/runs/{origin}/' + ('attempts/1/jobs' if kind == 'jobs' else kind) + '?per_page=100'
        inventory = acquisition['json'].get(inventory_route, {})
        entries = inventory.get(field, [])
        require(type(entries) is list and inventory.get('total_count') == len(entries)
                and len({item.get('id') for item in entries}) == len(entries), 'Supplement inventory is incomplete')
        selected = [item for item in entries if item.get('id') == identifier]
        route = f'actions/{kind}/{identifier}'
        require(len(selected) == 1 and route not in acquisition['json'], 'Supplement route is absent, duplicate or already recorded')
        json_values[route] = selected[0]
        derivations[route] = {'inventoryRoute': inventory_route, 'inventorySHA256': digest(encoded(inventory)),
                              'valueSHA256': digest(encoded(selected[0]))}
    logs = {f"actions/jobs/{ORIGIN[key]}/logs": ORIGIN[checksum]
            for key, checksum in (('builderJobID', 'builderRawSHA256'), ('releaseJobID', 'releaseRawSHA256'))}
    require(not set(logs) & set(originals), 'Supplement cannot replace acquired original bytes')
    execution = supplement_execution()
    root = Path(os.environ['RUNNER_TEMP'])
    require(root.is_absolute() and root.is_dir() and not root.is_symlink(), 'Supplement temporary root is not physical')
    for parent in root.parents:
        require(not parent.is_symlink(), 'Supplement temporary root traverses a link')
    directory = root / 'retained-packaging-supplements'
    directory.mkdir(exist_ok=True)
    require(directory.is_dir() and not directory.is_symlink(), 'Supplement evidence root is not physical')
    import fcntl
    lock = directory / '.acquisition.lock'
    descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        require(stat.S_ISREG(os.fstat(descriptor).st_mode), 'Supplement lock is not regular')
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        destination = directory / (gap['recordSHA256'] + '.zip')
        require(not destination.is_symlink(), 'Supplement archive is linked')
        if destination.exists():
            require(destination.is_file(), 'Supplement archive is not regular')
            supplement = destination.read_bytes()
        else:
            started = {'schema': 'nexgenvideo/component-origin-supplement-start/1', 'original': gap,
                       'execution': execution, 'startedAt': utc_now()}
            persist_supplement_member(directory / (gap['recordSHA256'] + '.STARTED.json'), encoded(started))
            current = live_api('actions/runs/' + execution['GITHUB_RUN_ID'])
            require(current.get('id') == int(execution['GITHUB_RUN_ID']) and current.get('run_attempt') == 1
                    and current.get('head_sha') == execution['GITHUB_SHA']
                    and current.get('repository', {}).get('full_name') == REPOSITORY
                    and current.get('actor', {}).get('login') == 'iret77'
                    and current.get('event') == 'workflow_dispatch', 'Supplement current run differs')
            acquired = {}
            for route, checksum in logs.items():
                acquired[route] = live_read_api(route, maximum=1024 * 1024)
                persist_supplement_member(directory / (checksum + '.acquired.bin'), acquired[route])
            require(all(digest(acquired[route]) == expected for route, expected in logs.items()),
                    'Fresh component origin raw log differs from its immutable original')
            metadata = {'schema': 'nexgenvideo/component-origin-supplement/1', 'original': gap,
                        'execution': execution, 'currentRun': current, 'startedAt': started['startedAt'],
                        'completedAt': utc_now(), 'derivedJSON': derivations,
                        'rawLogs': {route: {'sha256': logs[route], 'bytes': len(value)} for route, value in acquired.items()},
                        'historicalAcquisitionRewritten': False}
            output = io.BytesIO()
            with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('supplement.json', encoded(metadata))
                for route, value in acquired.items(): archive.writestr(logs[route] + '.bin', value)
            supplement = output.getvalue()
            persist_supplement_member(destination, supplement)
            sync = os.open(directory, os.O_RDONLY)
            try: os.fsync(sync)
            finally: os.close(sync)
        members = read_proof_archive(supplement)
        require(set(members) == {'supplement.json'} | {value + '.bin' for value in logs.values()},
                'Supplement members differ')
        metadata = json.loads(members['supplement.json'])
        require(encoded(metadata) == members['supplement.json']
                and set(metadata) == {'schema', 'original', 'execution', 'currentRun', 'startedAt', 'completedAt',
                                     'derivedJSON', 'rawLogs', 'historicalAcquisitionRewritten'}
                and metadata['schema'] == 'nexgenvideo/component-origin-supplement/1'
                and metadata['original'] == gap and metadata['execution'] == execution
                and metadata['derivedJSON'] == derivations and metadata['historicalAcquisitionRewritten'] is False
                and instant(metadata['startedAt']) <= instant(metadata['completedAt']) <= instant(utc_now()),
                'Supplement scope, execution or derivation changed')
        current = metadata['currentRun']
        require(current.get('id') == int(execution['GITHUB_RUN_ID']) and current.get('run_attempt') == 1
                and current.get('head_sha') == execution['GITHUB_SHA']
                and current.get('repository', {}).get('full_name') == REPOSITORY
                and current.get('actor', {}).get('login') == 'iret77' and current.get('event') == 'workflow_dispatch'
                and instant(current['created_at']) <= instant(metadata['startedAt']), 'Supplement current origin changed')
        expected_logs = {route: {'sha256': value, 'bytes': len(members[value + '.bin'])} for route, value in logs.items()}
        require(metadata['rawLogs'] == expected_logs
                and all(digest(members[value + '.bin']) == value for value in logs.values()), 'Supplement original raw bytes changed')
        acquisition['json'].update(json_values)
        originals.update({route: members[value + '.bin'] for route, value in logs.items()})
        return supplement
    finally:
        os.close(descriptor)


@contextmanager
def authenticated_originals(raw, record, container, producer_job):
    members = read_proof_archive(raw)
    require('acquisition.json' in members, 'Missing original acquisition context')
    acquisition = json.loads(members.pop('acquisition.json'))
    anchor = instant(container['created_at'])
    require(acquisition.get('schema') == 'nexgenvideo/packaging-api-acquisition/1'
            and acquisition.get('repository') == REPOSITORY
            and acquisition.get('productSourceSHA') == record['productSourceSHA']
            and acquisition.get('producerSourceSHA') == record['producerSourceSHA']
            and acquisition.get('runID') == record['runID']
            and instant(acquisition['recordedAt']) <= anchor
            and type(acquisition.get('json')) is dict and type(acquisition.get('bytes')) is dict
            and type(acquisition.get('legacy')) is dict, 'Historical acquisition context differs')
    expected = {value.get('name') for value in acquisition['bytes'].values()}
    require(set(members) == expected, 'Historical acquisition members differ')
    originals = {}
    for route, value in acquisition['bytes'].items():
        raw_value = members.get(value.get('name'), b'')
        require(value.get('name') == digest(raw_value) + '.bin'
                and value.get('sha256') == digest(raw_value) and value.get('bytes') == len(raw_value), 'Historical original bytes changed')
        originals[route] = raw_value
    supplement = component_origin_supplement(raw, record, container, acquisition, originals)
    cached = acquisition['json']
    current_run = cached.get('actions/runs/' + str(record['runID']), {})
    require(current_run.get('id') == record['runID'] and current_run.get('head_sha') == record['producerSourceSHA']
            and current_run.get('head_branch') == record['ref']
            and instant(current_run['created_at']) <= instant(acquisition['recordedAt']), 'Historical current run differs')
    cached = dict(cached)
    cached[f"actions/runs/{record['runID']}/attempts/1/jobs?per_page=100"] = {'total_count': 1, 'jobs': [producer_job]}
    token = REPLAY.set({'json': cached, 'bytes': originals, 'legacy': acquisition['legacy'], 'asOf': anchor})
    try:
        yield supplement
    finally:
        REPLAY.reset(token)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def revision(value):
    require(isinstance(value, str) and re.fullmatch("[a-f0-9]{40}", value), "Invalid packaging source")
    return value


def provenance_chain(*, current=False):
    return {"seen": set(), "depth": 1 if current else 0, "archives": {}, "expandedBytes": 0}


def enter_provenance(chain, identity):
    require(chain["depth"] < MAX_CHAIN and identity not in chain["seen"], "Packaging provenance chain is cyclic or too deep")
    chain["seen"].add(identity); chain["depth"] += 1


def git(*arguments):
    return subprocess.check_output(["git", *arguments], stdin=subprocess.DEVNULL, timeout=30)


def committed_inputs(paths, root=None):
    root = Path.cwd() if root is None else root
    head = git('rev-parse', 'HEAD').decode().strip()
    require(head == os.environ['GITHUB_SHA'], 'Verifier checkout source differs')
    values = {}
    for name in sorted(set(paths)):
        path = root / name
        require(path.is_file() and not path.is_symlink(), 'Verifier input is not a regular file: ' + name)
        checksum = digest(path.read_bytes())
        require(checksum == digest(git('show', head + ':' + name)), 'Verifier input differs from committed bytes: ' + name)
        values[name] = checksum
    return values


def verify_app_bytes(app, binding):
    from release_acceptance_identity import gui_tools
    product = binding['productSourceSHA']
    record = consumer_record(binding, product)
    actual = gui_tools().metadata(app, product)
    require(actual == record['final']['app'] and actual['treeSHA256'] == record['final']['appTreeSHA256'],
            'Executed App differs from canonical final App bytes')
    return actual


def selectors(producer, artifact, checksum):
    values = (producer, artifact, checksum)
    if not any(values):
        return None
    require(all(isinstance(value, str) and value for value in values), "Incomplete packaging provenance selectors")
    revision(producer)
    require(re.fullmatch("[1-9][0-9]*", artifact) and re.fullmatch("[a-f0-9]{64}", checksum),
            "Invalid packaging provenance selectors")
    return {"producerSourceSHA": producer, "artifactID": int(artifact), "artifactSHA256": checksum}


def consumer_arguments(parser):
    for name in ("packaging-producer-source", "packaging-provenance-artifact-id", "packaging-provenance-artifact-sha256"):
        parser.add_argument("--" + name, default="")


def argument_selectors(args):
    return selectors(getattr(args, 'packaging_producer_source', ''), getattr(args, 'packaging_provenance_artifact_id', ''),
                     getattr(args, 'packaging_provenance_artifact_sha256', ''))


def environment_selectors():
    return selectors(os.environ.get('PACKAGING_PRODUCER_SOURCE', ''),
                     os.environ.get('PACKAGING_PROVENANCE_ARTIFACT_ID', ''),
                     os.environ.get('PACKAGING_PROVENANCE_ARTIFACT_SHA256', ''))


def file_binding(args):
    path = getattr(args, 'packaging_binding', None)
    if path is None:
        return None
    binding = json.loads(Path(path).read_bytes())
    consumer_record(binding, args.source_sha)
    return binding


def consumer_binding(run_id, product, selected, *, archive_root=None):
    if selected is None:
        return None
    loaded = load_provenance(run_id, product, selected)
    if archive_root is not None:
        persist_archives({"archives": loaded["archives"]}, Path(archive_root))
    return {"schema": "nexgenvideo/packaging-consumer/1", "productSourceSHA": product,
            "producerRunID": run_id, "selectors": selected, "rawProofSHA256": loaded["rawProofSHA256"]}


def consumer_record(binding, product, run_id=None):
    require(type(binding) is dict and set(binding) == {"schema", "productSourceSHA", "producerRunID", "selectors", "rawProofSHA256"}
            and binding.get("schema") == "nexgenvideo/packaging-consumer/1"
            and binding.get("productSourceSHA") == product
            and (run_id is None or binding.get("producerRunID") == run_id), "Packaging consumer binding differs")
    selected = binding.get('selectors')
    require(type(selected) is dict and set(selected) == {'producerSourceSHA', 'artifactID', 'artifactSHA256'}
            and type(selected.get('artifactID')) is int
            and selectors(selected.get('producerSourceSHA'), str(selected.get('artifactID')), selected.get('artifactSHA256')) == selected,
            'Packaging consumer selectors differ')
    loaded = load_provenance(binding["producerRunID"], product, binding["selectors"])
    require(loaded["rawProofSHA256"] == binding.get("rawProofSHA256"), "Packaging canonical proof changed")
    return loaded["record"]


def consumer_source(product, binding):
    return consumer_record(binding, product)["producerSourceSHA"] if binding is not None else product


def consumer_harness(binding, product, allowed_paths):
    record = consumer_record(binding, product)
    producer = record['producerSourceSHA']
    allowed_paths = allowed_paths | component_consumer_repair_paths(record)
    current = git('rev-parse', 'HEAD').decode().strip()
    if cohort_signed_product(record):
        import app_cohort_v2
        allowed_paths = allowed_paths | app_cohort_v2.consumer_paths(product, current)
    require(current == os.environ['GITHUB_SHA'] and not git('diff', '--name-only', 'HEAD', '--').strip(),
            'Consumer checkout differs from its committed source')
    if current != producer:
        changes = comparison(producer, current)
        require({entry['filename'] for entry in changes['files']} <= allowed_paths,
                'Unsupported consumer changes since the packaging producer')
    return current


def validate_runtime_receipt(receipt, product, binding):
    record = consumer_record(binding, product)
    final = record["final"]
    require(set(receipt) == {"schema", "sourceSHA", "producerSourceSHA", "packagingProvenanceSHA256", "archiveSHA256", "appTreeSHA256"}
            and receipt.get("schema") == "nexgenvideo/workspace-ui-input/2"
            and receipt.get("sourceSHA") == product and receipt.get("producerSourceSHA") == record["producerSourceSHA"]
            and receipt.get("packagingProvenanceSHA256") == binding["rawProofSHA256"]
            and receipt.get("archiveSHA256") == final["runtimeArchiveSHA256"]
            and receipt.get("appTreeSHA256") == final["appTreeSHA256"], "Runtime receipt differs from canonical packaging proof")
    return record


def comparison(base, head):
    revision(base); revision(head)
    value = api("compare/" + base + "..." + head)
    require(value.get("base_commit", {}).get("sha") == base
            and value.get("merge_base_commit", {}).get("sha") == base
            and value.get("status") == "ahead"
            and 0 < len(value.get("commits", [])) == value.get("total_commits") <= 250
            and len({entry.get("sha") for entry in value["commits"]}) == value["total_commits"]
            and value["commits"][-1].get("sha") == head
            and 0 < len(value.get("files", [])) < 300
            and len({entry.get("filename") for entry in value["files"]}) == len(value["files"])
            and all(entry.get("status") in {"added", "modified"} and not entry.get("previous_filename")
                    for entry in value["files"]), "Incomplete or unsupported packaging source history")
    return value


def root_objects(source):
    commit = api("git/commits/" + revision(source))
    require(commit.get("sha") == source, "Packaging commit identity differs")
    tree_sha = revision(commit.get("tree", {}).get("sha"))
    tree = api("git/trees/" + tree_sha)
    require(tree.get("sha") == tree_sha and tree.get("truncated") is False, "Incomplete product tree")
    entries = {entry["path"]: {key: entry[key] for key in ("mode", "type", "sha")} for entry in tree["tree"]}
    require(all(name in entries for name in PRODUCT_OBJECTS), "Product source objects are missing")
    return tree_sha, {name: entries[name] for name in PRODUCT_OBJECTS}


def source_closure(product, producer, *, local=False):
    require(product != producer, "Retained packaging requires distinct product and packaging sources")
    changed = comparison(product, producer)
    allowed = packaging_paths(product, producer)
    require({entry["filename"] for entry in changed["files"]} <= allowed,
            "Retained packaging changed product or unsupported harness inputs")
    product_tree, objects = root_objects(product)
    producer_tree, producer_objects = root_objects(producer)
    require(objects == producer_objects, "Retained packaging changed native product objects")
    if local:
        require(not git("status", "--porcelain", "--untracked-files=no").strip(), "Packaging source is dirty")
        require(git("rev-parse", "HEAD").decode().strip() == producer == os.environ["GITHUB_SHA"]
                and git("rev-parse", "HEAD^{tree}").decode().strip() == producer_tree,
                "Packaging checkout differs from its execution")
        require(git("merge-base", product, producer).decode().strip() == product,
                "Product is not the packaging ancestor")
        commits = git("rev-list", product + ".." + producer).decode().splitlines()
        require(len(commits) == len(set(commits)) == changed["total_commits"]
                and set(commits) == {entry["sha"] for entry in changed["commits"]},
                "Packaging commit graph differs from GitHub")
        fields = git("diff", "--no-renames", "--name-status", "-z", product, producer).decode().split("\0")
        require(fields[-1] == "" and len(fields[:-1]) % 2 == 0, "Incomplete local packaging diff")
        changes = list(zip(fields[:-1:2], fields[1:-1:2]))
        expected = {("A" if entry["status"] == "added" else "M", entry["filename"]) for entry in changed["files"]}
        require(len(changes) == len(expected) and set(changes) == expected, "Local packaging diff differs from GitHub")
    return {"productSourceSHA": product, "productTreeSHA": product_tree, "producerSourceSHA": producer,
            "producerTreeSHA": producer_tree, "productObjects": objects,
            "commits": [entry["sha"] for entry in changed["commits"]],
            "changes": [{"path": entry["filename"], "status": entry["status"]} for entry in changed["files"]]}


def validate_source(record, proof, log, target, expected_ref):
    require(record.get("schema") == "nexgenvideo/packaging-qualified-source/1"
            and record.get("sourceSHA") == target and record.get("sourceRef") == expected_ref,
            "Packaging source receipt context differs")
    run_id = record.get("runID")
    require(type(run_id) is int and run_id > 0, "Invalid packaging source receipt producer")
    run = api(f"actions/runs/{run_id}")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    job = verify_run_identity(run, jobs, run_id)
    artifact = api("actions/artifacts/" + str(record["artifact"]["id"]))
    matching_artifact(record['artifact'], artifact)
    read_proof_archive(proof)
    receipt = original_receipt(artifact, proof, run)
    verify_artifact(artifact, run, job, artifact['id'], digest(proof), f'verified-pr-source-{run_id}-a1')
    verify_steps(job, receipt)
    commit = api("git/commits/" + receipt["checkoutSHA"])
    pr = api("pulls/" + str(receipt["pullRequest"]))
    target_commit = api("git/commits/" + revision(target))
    verify_tree(receipt, pr, commit, target, target_commit["tree"]["sha"], expected_ref)
    result = test_completion(log)
    require(read_api(f"actions/jobs/{job['id']}/logs") == log, "Source log differs from its actual original job")
    require(record.get("treeSHA") == target_commit["tree"]["sha"]
            and record.get("receipt") == receipt and record.get("result") == result
            and record.get("proofSHA256") == digest(proof) and record.get("logSHA256") == digest(log),
            "Packaging source receipt bytes or complete test result differ")
    return receipt


def collect_source(run_id, target, expected_ref, *, historical=False):
    require((historical and expected_ref is None) or (not historical and isinstance(expected_ref, str) and expected_ref),
            "Source proof requires its actual execution ref")
    run = api(f"actions/runs/{run_id}")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    job = verify_run_identity(run, jobs, run_id)
    inventory = api(f"actions/runs/{run_id}/artifacts?per_page=100")
    require(inventory.get("total_count") == len(inventory.get("artifacts", [])), "Incomplete source artifact inventory")
    matches = [entry for entry in inventory["artifacts"] if entry.get("name") == f"verified-pr-source-{run_id}-a1"]
    require(len(matches) == 1, "Missing or ambiguous packaging source proof")
    artifact = api("actions/artifacts/" + str(matches[0]["id"]))
    proof = read_api(f"actions/artifacts/{artifact['id']}/zip", maximum=100_000)
    receipt = original_receipt(artifact, proof, run)
    if historical:
        expected_ref = receipt["baseRef"]
    log = read_api(f"actions/jobs/{job['id']}/logs")
    record = {"schema": "nexgenvideo/packaging-qualified-source/1", "sourceSHA": target,
              "treeSHA": api("git/commits/" + revision(target))["tree"]["sha"],
              "sourceRef": expected_ref, "runID": run_id, "artifact": artifact,
              "receipt": receipt, "proofSHA256": digest(proof), "logSHA256": digest(log),
              "result": test_completion(log)}
    validate_source(record, proof, log, target, expected_ref)
    return record, proof, log


def proof_bytes(raw):
    budget = BUDGET.get()
    if budget is None:
        return raw
    checksum = digest(raw)
    known = budget.setdefault('expandedRecords', {})
    if checksum in known:
        require(known[checksum] == raw, 'Authenticated proof bytes changed')
        return known[checksum]
    total = budget.get('expandedBytes', 0) + len(raw)
    require(total <= MAX_PROOF_BYTES, 'Packaging provenance chain exceeds its shared byte bound')
    budget['expandedBytes'] = total
    known[checksum] = raw
    return raw


def proof_member(archive, entry):
    budget = BUDGET.get()
    if budget is None or budget.get('expandedBytes', 0) + entry.file_size <= MAX_PROOF_BYTES:
        return proof_bytes(archive.read(entry))
    checksum = hashlib.sha256()
    with archive.open(entry) as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(block)
    known = budget.get('expandedRecords', {}).get(checksum.hexdigest())
    require(known is not None and len(known) == entry.file_size,
            'Packaging provenance chain exceeds its shared byte bound')
    return known


def read_proof_archive(raw):
    require(0 < len(raw) <= MAX_PROOF_BYTES, "Packaging provenance archive exceeds its bound")
    budget = BUDGET.get()
    checksum = digest(raw)
    cached = budget.setdefault('decodedArchives', {}).get(checksum) if budget is not None else None
    if cached is not None:
        return dict(cached)
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        names = archive.namelist()
        require(names and len(names) == len(set(names)) and all("/" not in name and name not in {".", ".."} for name in names),
                "Packaging provenance has duplicate or unsafe members")
        require(all(not entry.is_dir() and stat.S_IFMT(entry.external_attr >> 16) in {0, stat.S_IFREG}
                    for entry in archive.infolist()), "Packaging provenance contains a link or special member")
        expanded = sum(entry.file_size for entry in archive.infolist())
        require(expanded <= MAX_PROOF_BYTES,
                "Packaging provenance expands beyond its bound")
        records = {entry.filename: proof_member(archive, entry) for entry in archive.infolist()}
    if budget is not None:
        budget['decodedArchives'][checksum] = records
    return dict(records)


def signed_input(run_id, product):
    from release_checkpoint import SIGNED_MANIFEST_MAX_BYTES, verify_manifest
    require(type(run_id) is int and run_id > 0, "Invalid original signed producer")
    producer = api(f"actions/runs/{run_id}")
    require(producer.get("id") == run_id and producer.get("head_sha") == revision(product)
            and producer.get("repository", {}).get("full_name") == REPOSITORY
            and producer.get("path") == ".github/workflows/release.yml"
            and producer.get("event") == "workflow_dispatch" and producer.get("run_attempt") == 1
            and producer.get("actor", {}).get("login") == "iret77"
            and producer.get("status") == "completed", "Original signed producer differs")
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete original signed job inventory")
    builders = [job for job in jobs["jobs"] if job.get("name") == "release-build"]
    require(len(builders) == 1, "Missing or duplicate original signed builder")
    builder = builders[0]
    require(builder.get("run_id") == run_id and builder.get("head_sha") == product
            and builder.get("run_attempt") == 1 and builder.get("labels") == ["macrunner"]
            and builder.get("status") == "completed" and builder.get("conclusion") == "success",
            "Original signed builder did not pass")
    from compiled_app_release import signed_resume_source, verify_signed_resume
    import compiled_component_reuse as component
    compiled = signed_resume_source(run_id, product)
    import app_cohort_v2
    dynamic = app_cohort_v2.has_manifest(product)
    required_steps = ('Assemble and sign the new App with unchanged retained components',
        'Record compiled App signed input without invoking a build', 'Retain signed build input', 'Retain signed build proof') if compiled or dynamic else (
        'Build and sign app', 'Retain signed build input', 'Retain signed build proof')
    if component.matches(run_id, product):
        required_steps = component.STEPS
    for name in required_steps:
        steps = [step for step in builder.get("steps", []) if step.get("name") == name]
        require(len(steps) == 1 and steps[0].get("conclusion") == "success", "Original signed stage did not pass: " + name)
    inventory = api(f"actions/runs/{run_id}/artifacts?per_page=100")
    require(inventory.get("total_count") == len(inventory.get("artifacts", [])), "Incomplete original signed artifacts")
    prefix = "release-signed-input-" + product
    artifacts = {}
    for name in (prefix, prefix + "-proof"):
        matches = [entry for entry in inventory["artifacts"] if entry.get("name") == name]
        require(len(matches) == 1, "Missing or duplicate original signed artifact")
        artifact = api("actions/artifacts/" + str(matches[0]["id"]))
        checksum = artifact.get("digest", "")
        require(isinstance(checksum, str) and re.fullmatch("sha256:[a-f0-9]{64}", checksum), "Missing original signed digest")
        verify_artifact(artifact, producer, builder, artifact["id"], checksum[7:], name)
        artifacts[name] = artifact
    proof = read_api("actions/artifacts/" + str(artifacts[prefix + "-proof"]["id"]) + "/zip", maximum=SIGNED_MANIFEST_MAX_BYTES)
    require(len(proof) == artifacts[prefix + "-proof"]["size_in_bytes"]
            and "sha256:" + digest(proof) == artifacts[prefix + "-proof"]["digest"], "Original signed proof bytes differ")
    members = read_proof_archive(proof)
    require(set(members) == {'manifest.json'} and len(members['manifest.json']) <= SIGNED_MANIFEST_MAX_BYTES,
            'Unexpected or oversized original signed proof entries')
    manifest = verify_manifest(json.loads(members['manifest.json']), product, run_id)
    compiled_product = verify_signed_resume(producer, builder, artifacts[prefix], artifacts[prefix + '-proof'], members['manifest.json'], verifier=verify_artifact) if compiled else None
    component_product = component.verify_origin(producer, builder, artifacts[prefix], artifacts[prefix + '-proof'], members['manifest.json'], verifier=verify_artifact) if component.matches(run_id, product) else None
    if component_product:
        component.verify_native_originals(producer, builder)
    if dynamic:
        from app_release_v2 import signed_product
        require(manifest['nativeEvidence'].get('schema') == 'release-native-compiled-app/v5', 'Typed cohort lacks its actual fresh native receipt')
        cohort_product = signed_product(manifest)
    else:
        cohort_product = None
    if dynamic:
        original_notary, original_state = original_journals(producer, product, jobs, inventory, allow_pre_submit=True)
    else:
        original_notary, original_state = original_journals(producer, product, jobs, inventory)
    return {"producer": producer, "builder": builder, "payloadArtifact": artifacts[prefix],
            "proofArtifact": artifacts[prefix + "-proof"], "manifest": manifest,
            "originalNotary": original_notary, **({"compiledProduct": compiled_product} if compiled_product else {}),
            **({"cohortProduct": cohort_product} if cohort_product else {}),
            **({"componentProduct": component_product} if component_product else {})}, proof, original_state


def artifact_bytes(artifact, maximum):
    require(type(artifact.get("id")) is int and artifact["id"] > 0
            and type(artifact.get("size_in_bytes")) is int and 0 < artifact["size_in_bytes"] <= maximum
            and isinstance(artifact.get("digest"), str)
            and re.fullmatch("sha256:[a-f0-9]{64}", artifact["digest"]), "Invalid packaging artifact identity")
    raw = read_api(f"actions/artifacts/{artifact['id']}/zip", maximum=maximum)
    require(len(raw) == artifact["size_in_bytes"] and "sha256:" + digest(raw) == artifact["digest"],
            "Packaging artifact bytes differ")
    return raw


def dmg_artifact_proof(producer, job, inventory, payload, product):
    name = "release-dmg-proof-" + product
    matches = [entry for entry in inventory["artifacts"] if entry.get("name") == name]
    require(len(matches) == 1, "DMG continuation requires the exact small checkpoint proof")
    artifact = api("actions/artifacts/" + str(matches[0]["id"]))
    checksum = artifact.get("digest", "")
    require(isinstance(checksum, str) and re.fullmatch("sha256:[a-f0-9]{64}", checksum), "Missing DMG checkpoint proof digest")
    verify_artifact(artifact, producer, job, artifact["id"], checksum[7:], name)
    members = read_proof_archive(artifact_bytes(artifact, 4 * 1024**2))
    require(set(members) == {"manifest.json"}, "Unexpected DMG checkpoint proof members")
    proof = json.loads(members["manifest.json"])
    checkpoint = validate_dmg_descriptor(proof, producer, job, payload, product, artifact)
    return {"artifact": artifact, "checkpoint": checkpoint, "rawProofSHA256": digest(members["manifest.json"])}


def validate_dmg_descriptor(proof, producer, job, payload, product, proof_artifact):
    require(proof.get("schema") == "nexgenvideo/dmg-artifact-proof/1" and proof.get("sourceSHA") == product
            and proof.get("producerSourceSHA") == producer["head_sha"] and proof.get("runID") == producer["id"],
            "DMG checkpoint proof source differs")
    matching_artifact(proof.get("payloadArtifact", {}), payload)
    require(type(payload.get('id')) is int and payload['id'] > 0
            and type(payload.get('size_in_bytes')) is int and 0 < payload['size_in_bytes'] < 8 * 1024**3
            and re.fullmatch('sha256:[a-f0-9]{64}', payload.get('digest', '')), 'Invalid submitted DMG payload metadata')
    verify_artifact(payload, producer, job, payload['id'], payload['digest'][7:], 'release-dmg-input-' + product)
    require(instant(payload['updated_at']) <= instant(proof_artifact['created_at']), 'DMG payload was not acquired before its proof')
    checkpoint = proof.get("checkpoint", {})
    context = checkpoint.get("context", {})
    require(checkpoint.get("schema") == "release-dmg-checkpoint/v2"
            and context.get("schema") == "release-notary-context/v2" and context.get("repository") == REPOSITORY
            and context.get("sourceSHA") == product and context.get("producerSourceSHA") == producer["head_sha"]
            and context.get("runID") == producer["id"] and type(context.get("buildRunID")) is int,
            "DMG checkpoint proof context differs")
    require(all(re.fullmatch('[a-f0-9]{64}', checkpoint.get(key, '')) for key in ('appTreeSHA256', 'appRuntimeTreeSHA256')),
            'DMG checkpoint lacks separate signed and runtime tree identities')
    for key in ("NexGenVideo.dmg", "plugins.tar.gz"):
        value = checkpoint.get("files", {}).get(key, {})
        require(type(value.get("bytes")) is int and value["bytes"] > 0
                and re.fullmatch("[a-f0-9]{64}", value.get("sha256", "")), "Incomplete DMG checkpoint payload proof")
    return checkpoint


def legacy_dmg_proof(producer, payload, product):
    require(producer['head_sha'] == product and 0 < payload.get('size_in_bytes', 0) < 8 * 1024**3,
            'Invalid legacy DMG payload')
    if REPLAY.get() is not None:
        recorded = REPLAY.get()['legacy'].get(str(payload['id']))
        require(type(recorded) is dict and recorded.get('schema') == 'nexgenvideo/legacy-dmg-acquisition/1'
                and recorded.get('archiveBytes') == payload['size_in_bytes']
                and recorded.get('archiveSHA256') == payload['digest'][7:], 'Missing historical legacy DMG acquisition')
        matching_artifact(recorded.get('payloadArtifact', {}), payload)
        checkpoint = recorded['checkpoint']
        context = checkpoint.get('context', {})
        require(checkpoint.get('schema') == 'release-dmg-checkpoint/v1' and context.get('sourceSHA') == product
                and context.get('runID') == producer['id'] and context.get('schema') == 'release-notary-context/v1',
                'Historical legacy checkpoint changed its source meaning')
        return {'artifact': payload, 'checkpoint': checkpoint, 'rawProofSHA256': digest(encoded(recorded)), 'legacyAcquisition': recorded}
    with tempfile.TemporaryDirectory(prefix='ngv-original-dmg-proof-') as temporary:
        archive = Path(temporary) / 'original.zip'
        download(payload, archive)
        require(archive.stat().st_size == payload['size_in_bytes'] and file_checksum(archive) == payload['digest'][7:],
                'Legacy DMG GitHub payload bytes changed')
        with zipfile.ZipFile(archive) as bundle:
            members = bundle.infolist()
            require(len(members) == 3 and {member.filename for member in members} == {'NexGenVideo.dmg', 'plugins.tar.gz', 'dmg-checkpoint.json'}
                    and all(not member.is_dir() and stat.S_IFMT(member.external_attr >> 16) in {0, stat.S_IFREG} for member in members),
                    'Unexpected legacy DMG checkpoint members')
            require(bundle.getinfo('dmg-checkpoint.json').file_size <= 4 * 1024**2, 'Oversized legacy checkpoint')
            checkpoint = json.loads(bundle.read('dmg-checkpoint.json'))
            context = checkpoint.get('context', {})
            require(checkpoint.get('schema') == 'release-dmg-checkpoint/v1'
                    and context.get('schema') == 'release-notary-context/v1' and context.get('repository') == REPOSITORY
                    and context.get('sourceSHA') == product and context.get('runID') == producer['id']
                    and 'producerSourceSHA' not in context and type(context.get('buildRunID')) is int and context['buildRunID'] > 0
                    and re.fullmatch('[a-f0-9]{64}', checkpoint.get('appTreeSHA256', ''))
                    and set(checkpoint.get('files', {})) == {'NexGenVideo.dmg', 'plugins.tar.gz'}, 'Legacy checkpoint context differs')
            for name in ('NexGenVideo.dmg', 'plugins.tar.gz'):
                expected = checkpoint['files'][name]
                require(type(expected.get('bytes')) is int and 0 < expected['bytes'] < 12 * 1024**3
                        and bundle.getinfo(name).file_size == expected['bytes'], 'Legacy checkpoint member size differs')
                checksum = hashlib.sha256()
                with bundle.open(name) as source:
                    for block in iter(lambda: source.read(1024 * 1024), b''): checksum.update(block)
                require(checksum.hexdigest() == expected.get('sha256'), 'Legacy checkpoint member bytes differ')
    certificate = {'schema': 'nexgenvideo/legacy-dmg-acquisition/1', 'payloadArtifact': payload, 'checkpoint': checkpoint,
                   'archiveBytes': payload['size_in_bytes'], 'archiveSHA256': payload['digest'][7:]}
    if CAPTURE.get() is not None:
        CAPTURE.get()['legacy'][str(payload['id'])] = certificate
    return {'artifact': payload, 'checkpoint': checkpoint, 'rawProofSHA256': digest(encoded(certificate)), 'legacyAcquisition': certificate}


def read_notary_intent(item, name, producer, job):
    artifact = api("actions/artifacts/" + str(item["id"]))
    checksum = artifact.get("digest", "")
    size = artifact.get("size_in_bytes")
    require(isinstance(checksum, str) and re.fullmatch("sha256:[a-f0-9]{64}", checksum)
            and type(size) is int and 0 < size <= 65536, "Invalid Apple intent artifact")
    verify_artifact(artifact, producer, job, item["id"], checksum[7:], name)
    members = read_proof_archive(artifact_bytes(artifact, 65536))
    require(set(members) == {"intent.json"}, "Unexpected Apple intent archive")
    return json.loads(members["intent.json"])


def state_records(raw, product, producer, run_id, *, pre_submit=None):
    records = read_proof_archive(raw)
    require("context.json" in records, "Missing saved notarization context")
    context = json.loads(records["context.json"])
    require(context.get("schema") in {"release-notary-context/v1", "release-notary-context/v2"}
            and context.get("repository") == REPOSITORY and context.get("sourceSHA") == product
            and context.get("runID") == run_id and type(context.get("buildRunID")) is int
            and context["buildRunID"] > 0, "Saved notarization context differs")
    if context["schema"] == "release-notary-context/v1":
        require(producer == product and "producerSourceSHA" not in context, "Legacy notary context changed its source meaning")
    else:
        require(context.get("producerSourceSHA") == producer and producer != product,
                "Retained notary producer source differs")
    journals = {}
    for name, encoded in records.items():
        if name == "context.json":
            continue
        require(re.fullmatch("[a-f0-9]{64}\\.json", name), "Unexpected saved notary member")
        value = json.loads(encoded)
        require(value.get("schema") == "release-notary/v1" and value.get("sourceSHA") == product
                and value.get("sha256") == name[:-5]
                and isinstance(value.get("submissionID"), str)
                and re.fullmatch(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", value["submissionID"]),
                "Saved notary payload or Apple ID differs")
        journals[name[:-5]] = value
    from compiled_app_release import original_empty_notary
    require(journals or set(records) == {'context.json'} and (original_empty_notary(raw, product, producer, run_id) or pre_submit is not None
                and pre_submit == {'schema': 'release-proven-pre-submit/v1', 'sourceSHA': producer,
                    'runID': run_id, 'jobID': pre_submit.get('jobID'), 'appleStagesAllSkipped': True}
                and type(pre_submit.get('jobID')) is int and pre_submit['jobID'] > 0),
            'Saved notarization has no qualified Apple submission or exact compiled pre-first-notary origin')
    return context, journals


def original_journals(producer, product, jobs, inventory, *, allow_pre_submit=False):
    from release_checkpoint import notary_state_entry, require_notary_checkpoint, require_notary_payload_coverage
    for job in jobs["jobs"]:
        if job.get("name") == "release":
            require_notary_checkpoint(inventory["artifacts"], product, job)
    selected = notary_state_entry(inventory["artifacts"], product)
    if selected is None:
        return None, None
    name = selected["name"]
    packaging = [job for job in jobs["jobs"] if job.get("name") == "release"]
    require(len(packaging) == 1, "Missing original signed packaging job")
    job = packaging[0]
    require(job.get("run_id") == producer["id"] and job.get("head_sha") == product
            and job.get("run_attempt") == 1 and job.get("labels") == ["macrunner"]
            and job.get("status") == "completed", "Original Apple state job differs")
    artifact = api("actions/artifacts/" + str(selected["id"]))
    checksum = artifact.get("digest", "")
    require(isinstance(checksum, str) and re.fullmatch("sha256:[a-f0-9]{64}", checksum), "Missing original Apple state digest")
    verify_artifact(artifact, producer, job, artifact["id"], checksum[7:], name)
    raw = artifact_bytes(artifact, 4 * 1024**2)
    from app_release_v2 import pre_submit
    certificate = pre_submit(producer, job) if allow_pre_submit else None
    context, journals = state_records(raw, product, product, producer["id"], pre_submit=certificate)
    require_notary_payload_coverage(inventory["artifacts"], product, producer, job, journals,
        lambda item, name: read_notary_intent(item, name, producer, job))
    require(context["buildRunID"] == producer["id"], "Original Apple state selected another signed build")
    return {"artifact": artifact, "job": job, "context": context, "journals": journals}, raw


def previous_signed_build(previous):
    if previous.get('schema') == 'release-pre-submit-origin/v1':
        require(previous.get('stateArtifact') is None and previous.get('dmgArtifact') is None
                and previous.get('journals') == {} and 'context' not in previous,
                'Pre-submit origin invented Apple state')
        return previous['signedBuildRunID']
    return previous['context']['buildRunID']


def prior_origin(mode, product, *, chain=None):
    signed = mode.get('signedBuildRunID')
    require(bool(signed) != bool(mode.get('priorNotaryRunID')), 'Select a signed build or a saved notary producer')
    return prior_notary(signed or mode['priorNotaryRunID'], product,
        packaging=mode.get('priorPackagingProof'), chain=chain, allow_pre_submit_without_state=bool(signed))


def prior_notary(run_id, product, *, packaging=None, chain=None, allow_pre_submit_without_state=False):
    from release_checkpoint import notary_state_entry, notary_state_names, require_notary_checkpoint, require_notary_payload_coverage
    require(type(run_id) is int and run_id > 0, "Invalid previous notarization producer")
    producer = api(f"actions/runs/{run_id}")
    require(producer.get("id") == run_id and producer.get("repository", {}).get("full_name") == REPOSITORY
            and producer.get("path") == ".github/workflows/release.yml"
            and producer.get("event") == "workflow_dispatch" and producer.get("run_attempt") == 1
            and producer.get("actor", {}).get("login") == "iret77" and producer.get("status") == "completed"
            and producer.get("conclusion") in {"failure", "cancelled"}, "Previous notarization producer differs")
    producer_source = revision(producer.get("head_sha"))
    if producer_source == product:
        require(packaging is None, "Legacy notary producer cannot ignore packaging selectors")
    else:
        require(packaging is not None and packaging.get("producerSourceSHA") == producer_source,
                "Retained notary producer requires complete explicit packaging provenance")
        parent = load_provenance(run_id, product, packaging, allow_failed=True, chain=chain)
    jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete previous notarization jobs")
    selected = [job for job in jobs["jobs"] if job.get("name") == "release"]
    require(len(selected) == 1, "Missing or duplicate previous packaging job")
    job = selected[0]
    require(job.get("run_id") == run_id and job.get("head_sha") == producer_source
            and job.get("run_attempt") == 1 and job.get("labels") == ["macrunner"]
            and job.get("status") == "completed" and job.get("conclusion") in {"failure", "cancelled"},
            "Previous packaging job is not the failed part")
    inventory = api(f"actions/runs/{run_id}/artifacts?per_page=100")
    require(inventory.get("total_count") == len(inventory.get("artifacts", [])), "Incomplete previous notary artifacts")
    require_notary_checkpoint(inventory["artifacts"], product, job)
    artifacts = {}
    for name in (*notary_state_names(product), "release-dmg-input-" + product):
        matches = [entry for entry in inventory["artifacts"] if entry.get("name") == name]
        require(len(matches) <= 1, "Duplicate previous notary artifact")
        if matches:
            artifact = api("actions/artifacts/" + str(matches[0]["id"]))
            checksum = artifact.get("digest", "")
            require(isinstance(checksum, str) and re.fullmatch("sha256:[a-f0-9]{64}", checksum), "Missing saved notary digest")
            verify_artifact(artifact, producer, job, artifact["id"], checksum[7:], name)
            artifacts[name] = artifact
    state = notary_state_entry(list(artifacts.values()), product)
    if allow_pre_submit_without_state:
        from app_release_v2 import pre_submit
        certificate = pre_submit(producer, job)
        names = [entry.get('name', '') for entry in inventory['artifacts']]
        prefixes = ('release-notary-state-', 'release-app-notary-', 'release-dmg-notary-', 'release-dmg-input-')
        require(producer_source == product and packaging is None and certificate is not None
                and state is None and not artifacts
                and all(isinstance(name, str) and not name.startswith(prefixes) for name in names),
                'Signed build cannot discard entered or ambiguous Apple operations; use saved notarization')
        return {'schema': 'release-pre-submit-origin/v1', 'producer': producer, 'job': job,
                'signedBuildRunID': run_id, 'preSubmit': certificate, 'artifactInventory': inventory['artifacts'],
                'stateArtifact': None, 'dmgArtifact': None, 'dmgProof': None, 'journals': {}}, None
    require(state is not None, "Previous notarization state is missing")
    raw = artifact_bytes(state, 4 * 1024**2)
    from app_release_v2 import pre_submit
    certificate = pre_submit(producer, job) if producer_source == product or cohort_signed_product(parent['record']) else None
    context, journals = state_records(raw, product, producer_source, run_id, pre_submit=certificate)
    require_notary_payload_coverage(inventory["artifacts"], product, producer, job, journals,
        lambda item, name: read_notary_intent(item, name, producer, job))
    if producer_source != product:
        require(all(journals.get(key) == value for key, value in parent["record"]["previousNotary"]["journals"].items()),
                "Parent notary state dropped or changed a known Apple submission")
    checkpoint = artifacts.get("release-dmg-input-" + product)
    checkpoint_proof = None
    if checkpoint:
        for name in ("Record DMG before notarization", "Retain DMG before notarization"):
            steps = [step for step in job.get("steps", []) if step.get("name") == name]
            require(len(steps) == 1 and steps[0].get("conclusion") == "success", "Previous DMG checkpoint did not pass: " + name)
        steps = {step.get("name"): step.get("conclusion") for step in job.get("steps", [])}
        require(steps.get("Build and sign DMG") == "success" or steps.get("Build and sign DMG") == "skipped"
                and steps.get("Restore saved notarization and DMG") == "success", "Previous DMG was neither built nor restored")
        checkpoint_proof = (legacy_dmg_proof(producer, checkpoint, product) if producer_source == product
                            else dmg_artifact_proof(producer, job, inventory, checkpoint, product))
        require(checkpoint_proof["checkpoint"]["context"] == context, "Saved DMG and Apple state contexts differ")
    if producer_source != product:
        previous_known = parent["record"]["previousNotary"]["journals"]
        added = set(journals) - set(previous_known)
        allowed = {checkpoint_proof["checkpoint"]["files"]["NexGenVideo.dmg"]["sha256"]} if checkpoint_proof else set()
        if cohort_signed_product(parent['record']):
            allowed.add(parent['record']['signedInput']['manifest']['files']['NexGenVideo.zip']['sha256'])
        if compiled_signed_product(parent['record']):
            from compiled_app_release import SIGNED_RESUME
            app = parent['record']['signedInput']['manifest']['files']['NexGenVideo.zip']['sha256']
            require(app == SIGNED_RESUME['appArchiveSHA256'], 'Parent App submission differs from its retained signed product')
            allowed.add(app)
        require(added <= allowed, "New Apple journal is not bound to the signed App or actual DMG checkpoint")
        if parent["record"]["stage"] == "complete":
            require(journals == parent["record"]["final"].get("notaryJournals"), "Completed parent Apple state changed")
    result = {"producer": producer, "job": job, "stateArtifact": state, "dmgArtifact": checkpoint,
              "context": context, "journals": journals, "dmgProof": checkpoint_proof,
              **({"preSubmit": certificate} if certificate is not None else {})}
    if producer_source != product:
        require(parent["record"]["originalSignedBuildRunID"] == context["buildRunID"], "Parent packaging proof selected another signed build")
        result["parentProvenance"] = {**packaging, "runID": run_id, "productSourceSHA": product,
                                     "rawProofSHA256": parent["rawProofSHA256"]}
        from compiled_component_reuse import qualified
        if checkpoint is not None and qualified(parent['record']):
            from notary_continuation import observation_members, observation_scope, verify_observations
            name = 'release-existing-app-notary-observations-' + str(run_id) + '-a1'
            matches = [item for item in inventory['artifacts'] if item.get('name') == name]
            require(len(matches) == 1, 'Saved component DMG lost its accepted App observation artifact')
            artifact = api('actions/artifacts/' + str(matches[0]['id']))
            checksum = artifact.get('digest', '').removeprefix('sha256:')
            require(re.fullmatch('[a-f0-9]{64}', checksum), 'Saved App observation artifact lacks its digest')
            verify_artifact(artifact, producer, job, artifact['id'], checksum, name)
            observation = artifact_bytes(artifact, 512 * 1024)
            verify_observations(observation_members(observation), parent['record'])
            steps = {step.get('name'): step.get('conclusion') for step in job.get('steps', [])}
            require(steps.get('Notarize and staple app') == 'success' or
                steps.get('Notarize and staple app') == 'skipped' and steps.get('Restore saved notarization and DMG') == 'success',
                'Saved component DMG has no successful original App notarization or authenticated restore')
            result['acceptedAppNotary'] = {'schema': 'component-accepted-app-notary-reuse/v1', 'state': 'REUSED',
                'artifact': artifact, 'archiveSHA256': checksum, 'archiveHex': observation.hex(),
                'originScope': parent['record']['previousNotary']['acceptedAppNotary']['originScope']
                    if parent['record']['previousNotary'].get('acceptedAppNotary') is not None else observation_scope(parent['record']),
                'newAppleOperationPerformed': False}
    return result, raw


def mode_inputs(values):
    product = values.get("productSourceSHA", "")
    product_run = values.get("productSourceRunID", "")
    prior = selectors(values.get("priorProducerSourceSHA", ""), values.get("priorProvenanceArtifactID", ""),
                      values.get("priorProvenanceArtifactSHA256", ""))
    if not product and not product_run and prior is None:
        return None
    revision(product)
    require(product != os.environ["GITHUB_SHA"] and values.get("artifactOnly") == values.get("dryRun") == "true",
            "Retained product packaging is exclusive to artifact-only dry runs")
    for name in ("productSourceRunID", "verifiedSourceRunID"):
        require(isinstance(values.get(name), str) and re.fullmatch("[1-9][0-9]*", values[name]),
                "Retained packaging requires complete source and notary inputs")
    signed, notary = values.get('signedBuildRunID', ''), values.get('priorNotaryRunID', '')
    require(bool(signed) != bool(notary) and isinstance(signed or notary, str)
            and re.fullmatch('[1-9][0-9]*', signed or notary), 'Select one exact signed build or saved notarization')
    require(not signed or prior is None, 'Pre-submit signed build cannot select previous packaging provenance')
    require(not any(values.get(name) for name in ("completedReleaseTestsRunID", "completedEngineTestsRunID", "testBundleRunID")),
            "Retained packaging cannot combine native, signed or test-client selectors")
    require(isinstance(values.get("version"), str) and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", values["version"]),
            "Invalid retained product version")
    return {"productSourceSHA": product, "productSourceRunID": int(product_run),
            "verifiedSourceRunID": int(values["verifiedSourceRunID"]),
            "priorNotaryRunID": int(notary) if notary else None, "priorPackagingProof": prior,
            **({'signedBuildRunID': int(signed)} if signed else {}),
            "version": values["version"], "artifactOnly": True, "dryRun": True}


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def collect_binding(values, *, archive_root=None):
    require(CAPTURE.get() is None and REPLAY.get() is None, 'Fresh packaging acquisition cannot use historical evidence')
    captured = {'json': {}, 'bytes': {}, 'legacy': {}}
    chain = provenance_chain(current=True)
    token = CAPTURE.set(captured)
    budget_token = BUDGET.set(chain)
    try:
        record, files = collect_original_binding(values, archive_root=archive_root, chain=chain)
        raw = encoded_api_evidence(captured, record)
        files = dict(files, **{'original-api-evidence.zip': raw})
        files = {name: proof_bytes(value) for name, value in files.items()}
        read_proof_archive(raw)
    finally:
        BUDGET.reset(budget_token)
        CAPTURE.reset(token)
    record['files'] = {name: {'bytes': len(raw), 'sha256': digest(raw)} for name, raw in files.items()}
    return record, files


def collect_original_binding(values, *, archive_root=None, chain=None):
    mode = mode_inputs(values)
    require(mode is not None and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("GITHUB_REPOSITORY") == REPOSITORY
            and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and os.environ.get("GITHUB_RUN_ATTEMPT") == "1", "Retained packaging requires an owned Actions execution")
    producer = revision(os.environ["GITHUB_SHA"])
    product = mode["productSourceSHA"]
    run_id = int(os.environ["GITHUB_RUN_ID"])
    execution = api(f"actions/runs/{run_id}")
    require(execution.get("id") == run_id and execution.get("head_sha") == producer
            and execution.get("head_branch") == os.environ["GITHUB_REF_NAME"]
            and execution.get("repository", {}).get("full_name") == REPOSITORY
            and execution.get("actor", {}).get("login") == "iret77" and execution.get("run_attempt") == 1
            and execution.get("event") == "workflow_dispatch"
            and execution.get("path") == ".github/workflows/release.yml", "Current packaging execution differs")
    closure = source_closure(product, producer, local=True)
    harness, harness_zip, harness_log = collect_source(mode["verifiedSourceRunID"], producer, os.environ["GITHUB_REF_NAME"])
    original, original_zip, original_log = collect_source(mode["productSourceRunID"], product, None, historical=True)
    require(chain is not None and chain['depth'] == 1, 'Fresh packaging acquisition requires its reserved current node')
    previous, state = prior_origin(mode, product, chain=chain)
    original_build = previous_signed_build(previous)
    signed, signed_zip, original_state = signed_input(original_build, product)
    require(not mode.get('signedBuildRunID') or signed.get('cohortProduct') is not None,
            'Pre-submit continuation requires a fully verified typed signed App')
    require(signed["manifest"]["identity"]["version"] == mode["version"], "Requested retained version differs")
    app_zip = signed["manifest"]["files"]["NexGenVideo.zip"]["sha256"]
    first_compiled = compiled_first_notary({'signedInput': signed, 'previousNotary': previous,
        'originalSignedBuildRunID': original_build, 'productSourceSHA': product})
    require(app_zip in previous['journals'] or first_compiled, 'Previous state lost the original App Apple submission')
    if signed["originalNotary"] is not None:
        require(all(previous["journals"].get(key) == value for key, value in signed["originalNotary"]["journals"].items()),
                "Previous state lost an original Apple SHA or submission ID")
    files = {"harness-source.json": encoded(harness), "harness-source-original-proof.zip": harness_zip,
             "harness-source-original-job.log": harness_log, "product-source.json": encoded(original),
             "product-source-original-proof.zip": original_zip, "product-source-original-job.log": original_log,
             "signed-proof.zip": signed_zip}
    files['prior-notary-state.zip' if state is not None else 'pre-submit-origin.json'] = state if state is not None else encoded(previous)
    if original_state is not None:
        files["original-notary-state.zip"] = original_state
    record = {"schema": "nexgenvideo/retained-packaging-provenance/1", "stage": "input",
              "productSourceSHA": product, "producerSourceSHA": producer,
              "productTreeSHA": closure["productTreeSHA"], "producerTreeSHA": closure["producerTreeSHA"],
              "runID": run_id, "attempt": 1, "ref": os.environ["GITHUB_REF_NAME"],
              "originalSignedBuildRunID": original_build, "mode": mode,
              "closure": closure, "signedInput": signed, "previousNotary": previous,
              "files": {name: {"bytes": len(raw), "sha256": digest(raw)} for name, raw in files.items()}}
    if archive_root is not None:
        persist_archives(chain, archive_root)
    return record, files


def persist_archives(chain, root):
    for (run_id, artifact_id), acquired in chain["archives"].items():
        directory = root / "parents"
        directory.mkdir(parents=True, exist_ok=True)
        name = str(run_id) + "-" + str(artifact_id) + "-" + acquired["artifact"]["digest"][7:]
        archive = directory / (name + ".zip")
        raw = acquired["raw"]
        if archive.exists():
            require(archive.read_bytes() == raw, "Cached original parent archive changed")
        else:
            with archive.open("xb") as stream:
                stream.write(raw); stream.flush(); os.fsync(stream.fileno())
            metadata = {key: value for key, value in acquired.items() if key != "raw"}
            metadata.update(schema="nexgenvideo/original-packaging-archive-acquisition/1", bytes=len(raw), sha256=digest(raw))
            with (directory / (name + ".complete.json")).open("xb") as stream:
                stream.write(encoded(metadata)); stream.flush(); os.fsync(stream.fileno())


def event_values():
    value = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_bytes()).get("inputs")
    require(type(value) is dict, "Missing release dispatch inputs")
    names = {"productSourceSHA": "retained_product_source_sha", "productSourceRunID": "retained_product_source_pr_run_id",
             "verifiedSourceRunID": "verified_pr_run_id", "priorNotaryRunID": "notary_progress_run_id",
             "priorProducerSourceSHA": "prior_packaging_producer_source_sha",
             "priorProvenanceArtifactID": "prior_packaging_provenance_artifact_id",
             "priorProvenanceArtifactSHA256": "prior_packaging_provenance_artifact_sha256",
             "artifactOnly": "artifact_only", "dryRun": "dry_run", "version": "version",
             "completedReleaseTestsRunID": "completed_release_tests_run_id",
             "completedEngineTestsRunID": "completed_engine_tests_run_id", "signedBuildRunID": "signed_build_run_id",
             "testBundleRunID": "test_bundle_run_id"}
    result = {}
    for key, name in names.items():
        original = value.get(name, "")
        require(type(original) in {str, bool}, "Invalid release dispatch input type")
        result[key] = str(original).lower() if type(original) is bool else original
    return result


def bind_current(root):
    record, files = collect_binding(event_values(), archive_root=root)
    directory = save_stage(root, record, files)
    checksum = digest((directory / "packaging-provenance.json").read_bytes())
    with Path(os.environ["GITHUB_ENV"]).open("a") as output:
        output.write("RETAINED_PACKAGING_ROOT=" + str(root.resolve()) + "\n")
        output.write("RETAINED_PACKAGING_INPUT_SHA256=" + checksum + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write("product_source_sha=" + record["productSourceSHA"] + "\n")
    return checksum


def compiled_signed_product(record):
    from compiled_app_release import SIGNED_RESUME, PACK_SHA, PACK_TREE
    return (record.get('productSourceSHA') == SIGNED_RESUME['sourceSHA']
        and record.get('originalSignedBuildRunID') == SIGNED_RESUME['runID']
        and record.get('signedInput', {}).get('compiledProduct') == {
            'schema': 'compiled-signed-product-reuse/v1', 'original': SIGNED_RESUME,
            'packArchiveSHA256': PACK_SHA, 'packTreeSHA256': PACK_TREE, 'appRootMode': 0o755,
            'freshCompilerCoreAssemblyOrRootSignPerformed': False})


def cohort_signed_product(record):
    manifest = record.get('signedInput', {}).get('manifest', {})
    if manifest.get('nativeEvidence', {}).get('schema') != 'release-native-compiled-app/v5':
        return False
    from app_release_v2 import signed_product
    return (manifest.get('sourceSHA') == record.get('productSourceSHA')
        and manifest.get('runID') == record.get('originalSignedBuildRunID')
        and record['signedInput'].get('cohortProduct') == signed_product(manifest))


def retained_compiled_product(record):
    from compiled_component_reuse import qualified
    return compiled_signed_product(record) or qualified(record)


def packaging_paths(product, producer=None):
    import app_cohort_v2
    if app_cohort_v2.has_manifest(product):
        return app_cohort_v2.consumer_ci_paths(product, producer or product) | PACKAGING_PATHS
    from compiled_app_release import SIGNED_RESUME
    from compiled_component_reuse import ORIGIN, PATHS
    if product == ORIGIN['sourceSHA']:
        return set(PATHS)
    return PACKAGING_PATHS | COMPILED_PACKAGING_PATHS if product == SIGNED_RESUME['sourceSHA'] else PACKAGING_PATHS


def compiled_first_notary(record):
    if cohort_signed_product(record):
        from app_release_v2 import pre_submit
        previous = record.get('previousNotary', {})
        certificate = pre_submit(previous.get('producer', {}), previous.get('job', {}))
        return certificate is not None and previous.get('preSubmit') == certificate and previous.get('journals') == {}
    from compiled_app_release import SIGNED_RESUME
    previous = record.get('previousNotary', {})
    return (compiled_signed_product(record) and previous.get('journals') == {}
        and previous.get('stateArtifact', {}).get('id') == SIGNED_RESUME['stateArtifactID']
        and previous['stateArtifact'].get('digest') == 'sha256:' + SIGNED_RESUME['stateSHA256']
        and previous.get('context') == {'schema': 'release-notary-context/v1', 'repository': REPOSITORY,
            'sourceSHA': SIGNED_RESUME['sourceSHA'], 'buildRunID': SIGNED_RESUME['runID'], 'runID': SIGNED_RESUME['runID']})


def qualified_pack_archives(packs, record):
    from compiled_app_release import PACK_SHA
    if retained_compiled_product(record) or cohort_signed_product(record):
        return packs == {'.build/plugins/musicvideo.ngvpack.zip': PACK_SHA}
    return bool(packs) and all(value in record['previousNotary']['journals'] for value in packs.values())


def record_restored(root, signed_root):
    record, files = read_stage(root, "input")
    validate_binding(record, files, execution=True)
    restored = json.loads((signed_root / "restored.json").read_bytes())
    manifest = record["signedInput"]["manifest"]
    require(restored == {"sourceSHA": record["productSourceSHA"], "producerRun": record["originalSignedBuildRunID"],
                         "appTreeSHA256": manifest["appTreeSHA256"], "identity": manifest["identity"]},
            "Signed restore did not preserve the original product")
    packs = {path.as_posix(): file_checksum(path) for path in Path(".build/plugins").glob("*.ngvpack.zip")}
    require(qualified_pack_archives(packs, record),
            "Original pack archive lost its saved Apple submission")
    if compiled_signed_product(record):
        from compiled_app_release import verify_current_signature_reuse
        signature = signed_root / 'current-app-signature.reused.json'
        require(signature.is_file() and not signature.is_symlink(), 'Current App signature reuse proof is missing')
        raw = signature.read_bytes()
        verify_current_signature_reuse(json.loads(raw), record)
        files = dict(files, **{signature.name: raw})
    from compiled_component_reuse import qualified, verify_native_record
    if qualified(record):
        signature = signed_root / 'component-native-checks.reused.json'
        require(signature.is_file() and not signature.is_symlink(), 'Component native reuse proof is missing')
        raw = signature.read_bytes()
        verify_native_record(json.loads(raw), record)
        files = dict(files, **{signature.name: raw})
    copied = dict(record, stage="restored", restoredOriginal=restored, originalPackArchives=packs)
    copied['files'] = {name: {'bytes': len(raw), 'sha256': digest(raw)} for name, raw in files.items()}
    directory = save_stage(root, copied, files)
    with Path(os.environ["GITHUB_ENV"]).open("a") as output:
        output.write("RETAINED_PACKAGING_RESTORED_SHA256=" + digest((directory / "packaging-provenance.json").read_bytes()) + "\n")
    return directory


def record_dmg_payload(root, artifact_id, checksum):
    binding = current_binding()
    require(binding is not None and type(artifact_id) is int and artifact_id > 0
            and re.fullmatch("[a-f0-9]{64}", checksum), "Invalid DMG payload selector")
    checkpoint = json.loads(Path(os.environ["RETAINED_PACKAGING_DMG_CHECKPOINT"]).read_bytes())
    expected_context = {"schema": "release-notary-context/v2", "repository": REPOSITORY,
                        "sourceSHA": binding["productSourceSHA"], "producerSourceSHA": binding["producerSourceSHA"],
                        "buildRunID": binding["originalSignedBuildRunID"], "runID": binding["runID"]}
    require(checkpoint.get("schema") == "release-dmg-checkpoint/v2" and checkpoint.get("context") == expected_context,
            "DMG payload checkpoint source differs")
    require(all(re.fullmatch('[a-f0-9]{64}', checkpoint.get(key, '')) for key in ('appTreeSHA256', 'appRuntimeTreeSHA256')),
            'DMG payload lacks separate signed and runtime tree identities')
    artifact = api("actions/artifacts/" + str(artifact_id))
    require(artifact.get("id") == artifact_id and artifact.get("digest") == "sha256:" + checksum
            and artifact.get("name") == "release-dmg-input-" + binding["productSourceSHA"]
            and artifact.get("expired") is False and artifact.get("workflow_run", {}).get("id") == binding["runID"]
            and artifact.get("workflow_run", {}).get("head_sha") == binding["producerSourceSHA"], "Uploaded DMG payload identity differs")
    proof = {"schema": "nexgenvideo/dmg-artifact-proof/1", "sourceSHA": binding["productSourceSHA"],
             "producerSourceSHA": binding["producerSourceSHA"], "runID": binding["runID"],
             "payloadArtifact": artifact, "checkpoint": checkpoint}
    output = root / "dmg-proof"; output.mkdir(parents=True, exist_ok=False)
    with (output / "manifest.json").open("xb") as stream:
        stream.write(encoded(proof)); stream.flush(); os.fsync(stream.fileno())
    return proof


def current_notary_state(binding, *, initial_app=False):
    directory = Path(os.environ["NOTARY_STATE_DIR"])
    source = io.BytesIO()
    with zipfile.ZipFile(source, "w") as archive:
        for path in sorted(directory.glob("*.json")):
            require(path.is_file() and not path.is_symlink(), "Notary state member is not a regular file")
            archive.writestr(path.name, path.read_bytes())
    raw = source.getvalue()
    records = read_proof_archive(raw)
    if initial_app and compiled_first_notary(binding) and set(records) == {'context.json'}:
        context = json.loads(records['context.json'])
        require(context == {'schema': 'release-notary-context/v2', 'repository': REPOSITORY,
            'sourceSHA': binding['productSourceSHA'], 'producerSourceSHA': binding['producerSourceSHA'],
            'buildRunID': binding['originalSignedBuildRunID'], 'runID': binding['runID']},
            'Initial compiled App notary context differs')
        journals = {}
    else:
        context, journals = state_records(raw, binding['productSourceSHA'], binding['producerSourceSHA'], binding['runID'])
    require(context["buildRunID"] == binding["originalSignedBuildRunID"]
            and all(journals.get(key) == value for key, value in binding["previousNotary"]["journals"].items()),
            "Current notary state lost or changed a known submission")
    return context, journals


def notary_product_source(artifact, checkpoint=None):
    binding = current_binding()
    require(binding is not None, "Retained notarization requires a complete local binding")
    root = Path(os.environ["RETAINED_PACKAGING_ROOT"])
    restored, restored_files = read_stage(root, "restored")
    require(digest((root / "restored/packaging-provenance.json").read_bytes()) == os.environ.get("RETAINED_PACKAGING_RESTORED_SHA256"),
            "Immutable signed-restore proof changed")
    validate_binding(restored, restored_files, execution=True)
    require(restored.get("runID") == binding["runID"] and restored.get("producerSourceSHA") == binding["producerSourceSHA"]
            and restored.get("productSourceSHA") == binding["productSourceSHA"]
            and restored.get("restoredOriginal", {}).get("appTreeSHA256") == binding["signedInput"]["manifest"]["appTreeSHA256"],
            "Retained notarization has no matching signed restore")
    require(artifact.is_file() and not artifact.is_symlink(), "Notary artifact is not a regular file")
    checksum = file_checksum(artifact)
    relative = artifact.resolve().relative_to(Path.cwd().resolve()).as_posix()
    manifest = binding["signedInput"]["manifest"]
    first = compiled_first_notary(binding)
    context, journals = current_notary_state(binding, initial_app=first and relative == '.build/NexGenVideo.zip')
    if relative == ".build/NexGenVideo.zip":
        require(checksum == manifest["files"]["NexGenVideo.zip"]["sha256"]
                and (first and (not journals or checksum in journals)
                    or checksum in binding['previousNotary']['journals'] and checksum in journals),
                'Original App bytes or authenticated first submission differs')
    elif relative in restored.get("originalPackArchives", {}):
        require(checksum == restored["originalPackArchives"][relative]
                and checksum in binding["previousNotary"]["journals"] and checksum in journals,
                "Original pack bytes or saved Apple ID changed")
    else:
        require(relative == ".build/NexGenVideo.dmg" and checkpoint is not None, "Only the checked new DMG may be submitted")
        value = json.loads(checkpoint.read_bytes())
        current_context = {"schema": "release-notary-context/v2", "repository": REPOSITORY,
                           "sourceSHA": binding["productSourceSHA"], "producerSourceSHA": binding["producerSourceSHA"],
                           "buildRunID": binding["originalSignedBuildRunID"], "runID": binding["runID"]}
        require(value.get("schema") == "release-dmg-checkpoint/v2"
                and value.get("context") == current_context
                and value.get("files", {}).get("NexGenVideo.dmg") == {"bytes": artifact.stat().st_size, "sha256": checksum},
                "DMG does not match its verified copy checkpoint")
    return binding["productSourceSHA"]


def record_complete(root, app, archive_sha, source_receipt_sha, pack_archive):
    binding = current_binding()
    require(binding is not None, "Complete retained packaging requires its validated original input")
    restored, files = read_stage(root, "restored")
    from compiled_component_reuse import qualified
    if qualified(binding):
        from notary_continuation import ARCHIVE, verify_observations
        from consume_bpy_distributable_source import physical_directory
        directory = Path(os.environ['NOTARY_STATE_DIR']) / 'observations' / ARCHIVE
        physical_directory(directory)
        require(all(path.is_file() and not path.is_symlink() for path in directory.iterdir()), 'App observation originals are linked or special')
        observations = {path.name: path.read_bytes() for path in directory.iterdir()}
        verify_observations(observations, binding)
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, raw in sorted(observations.items()): archive.writestr(name, raw)
        observation_raw = buffer.getvalue()
    require(digest((root / "restored/packaging-provenance.json").read_bytes()) == os.environ.get("RETAINED_PACKAGING_RESTORED_SHA256"),
            "Original restore proof changed before completion")
    validate_binding(restored, files, execution=True)
    if qualified(binding):
        files = dict(files, **{'component-notary-observations.zip': observation_raw})
    manifest = binding["signedInput"]["manifest"]
    require(app.get("NGVSourceCommit") == binding["productSourceSHA"]
            and app.get("CFBundleShortVersionString") == manifest["identity"]["version"]
            and str(app.get("CFBundleVersion")) == manifest["identity"]["build"]
            and app.get("treeSHA256") == os.environ["NGV_RELEASE_MOUNTED_APP_TREE_SHA256"],
            "Final installed App differs from the retained product")
    dmg = file_checksum(Path(".build/NexGenVideo.dmg"))
    pack = file_checksum(pack_archive)
    require(dmg == os.environ["NGV_RELEASE_DMG_SHA256"] and pack == os.environ["NGV_RELEASE_PACK_ZIP_SHA256"]
            and all(isinstance(value, str) and re.fullmatch("[a-f0-9]{64}", value) for value in (archive_sha, source_receipt_sha)),
            "Final distribution bytes changed")
    final = {"app": app, "appTreeSHA256": app["treeSHA256"], "dmgSHA256": dmg,
             "runtimeArchiveSHA256": archive_sha, "bpySourceReceiptSHA256": source_receipt_sha,
             "packArchive": pack_archive.name, "packArchiveSHA256": pack,
             "packTreeSHA256": os.environ["NGV_RELEASE_PACK_TREE_SHA256"]}
    context, journals = current_notary_state(binding)
    checkpoint = json.loads(Path(os.environ['RETAINED_PACKAGING_DMG_CHECKPOINT']).read_bytes())
    submitted = checkpoint.get('files', {}).get('NexGenVideo.dmg', {}).get('sha256')
    require(submitted in journals and checkpoint.get('context') == context
            and checkpoint.get('appRuntimeTreeSHA256') == app['treeSHA256'], 'Submitted DMG lost its copy or Apple binding')
    inventory = api(f"actions/runs/{binding['runID']}/artifacts?per_page=100")
    require(inventory.get('total_count') == len(inventory.get('artifacts', [])), 'Incomplete current DMG proof inventory')
    found = [item for item in inventory['artifacts'] if item.get('name') == 'release-dmg-proof-' + binding['productSourceSHA']]
    require(len(found) == 1, 'Missing current submitted DMG proof')
    artifact = api('actions/artifacts/' + str(found[0]['id']))
    raw = artifact_bytes(artifact, 4 * 1024**2)
    members = read_proof_archive(raw)
    require(set(members) == {'manifest.json'} and json.loads(members['manifest.json']) == json.loads((root / 'dmg-proof/manifest.json').read_bytes()),
            'Uploaded submitted DMG proof changed')
    submission = json.loads(members['manifest.json'])
    require(submission.get('checkpoint') == checkpoint and submission.get('sourceSHA') == binding['productSourceSHA']
            and submission.get('producerSourceSHA') == binding['producerSourceSHA'] and submission.get('runID') == binding['runID'],
            'Submitted DMG proof belongs to another execution')
    payload = api('actions/artifacts/' + str(submission.get('payloadArtifact', {}).get('id')))
    matching_artifact(submission.get('payloadArtifact', {}), payload)
    now = datetime.datetime.now(datetime.timezone.utc)
    producer = api('actions/runs/' + str(binding['runID']))
    for value, name in [(artifact, 'release-dmg-proof-' + binding['productSourceSHA']),
                        (payload, 'release-dmg-input-' + binding['productSourceSHA'])]:
        require(type(value.get('id')) is int and value['id'] > 0 and value.get('name') == name and value.get('expired') is False
                and type(value.get('size_in_bytes')) is int and value['size_in_bytes'] > 0
                and re.fullmatch('sha256:[a-f0-9]{64}', value.get('digest', ''))
                and value.get('workflow_run', {}).get('id') == binding['runID']
                and value.get('workflow_run', {}).get('head_sha') == binding['producerSourceSHA']
                and instant(producer['created_at']) <= instant(value['created_at']) <= instant(value['updated_at']) <= now
                and instant(value['expires_at']) > now, 'Current DMG proof or payload origin differs')
    require(instant(payload['updated_at']) <= instant(artifact['created_at']), 'DMG payload was not acquired before its proof')
    require(manifest['files']['NexGenVideo.zip']['sha256'] in journals, 'Complete packaging lacks the actual App Apple submission')
    if cohort_signed_product(binding):
        guide = Path('scripts/Install NexGenVideo.txt')
        require(guide.is_file() and not guide.is_symlink()
            and guide.read_bytes() == git('show', binding['producerSourceSHA'] + ':' + guide.as_posix()),
            'Actual reviewed installation guide changed')
        final['guideSHA256'] = file_checksum(guide)
    if retained_compiled_product(binding):
        from compiled_app_release import capture_source_reuse, PACK_SHA, PACK_TREE
        source_reuse = capture_source_reuse(Path('.build/bpy-source'), binding)
        require(source_receipt_sha == digest(source_reuse['bpy-source-receipt.json'].encode())
            and pack == PACK_SHA and final['packTreeSHA256'] == PACK_TREE, 'Final compiled source or pack identity differs')
        final['bpySourceReuse'] = source_reuse
        guide = Path('scripts/Install NexGenVideo.txt')
        require(guide.is_file() and not guide.is_symlink()
            and guide.read_bytes() == git('show', binding['producerSourceSHA'] + ':' + guide.as_posix()),
            'Actual reviewed installation guide changed')
        final['guideSHA256'] = file_checksum(guide)
        files = dict(files, **{name: raw.encode() for name, raw in source_reuse.items()})
    final.update(notaryContext=context, notaryJournals=journals, submittedDMGSHA256=submitted,
                 dmgSubmissionArtifact=artifact, dmgSubmissionPayloadArtifact=payload)
    files = dict(files, **{'submitted-dmg-proof.zip': raw})
    record = dict(restored, stage="complete", final=final)
    record['files'] = {name: {'bytes': len(raw), 'sha256': digest(raw)} for name, raw in files.items()}
    directory = save_stage(root, record, files)
    checksum = digest((directory / "packaging-provenance.json").read_bytes())
    with Path(os.environ["GITHUB_ENV"]).open("a") as output:
        output.write("RETAINED_PACKAGING_COMPLETE_SHA256=" + checksum + "\n")
    return checksum


def matching_artifact(recorded, actual):
    require(all(recorded.get(key) == actual.get(key) for key in ("id", "name", "size_in_bytes", "digest"))
            and recorded.get("workflow_run", {}).get("id") == actual.get("workflow_run", {}).get("id")
            and recorded.get("workflow_run", {}).get("head_sha") == actual.get("workflow_run", {}).get("head_sha"),
            "Recorded packaging artifact differs from its actual original")


def proof_files(record):
    if record.get('previousNotary', {}).get('schema') == 'release-pre-submit-origin/v1':
        return PROOF_FILES - {'prior-notary-state.zip'} | {'pre-submit-origin.json'}
    return PROOF_FILES


def validate_binding(record, files, *, execution=False, chain=None):
    if chain is None:
        chain = provenance_chain(current=True)
    required_files = proof_files(record)
    require(record.get("schema") == "nexgenvideo/retained-packaging-provenance/1"
            and record.get("stage") in {"input", "restored", "complete"}
            and record.get("attempt") == 1 and type(record.get("runID")) is int and record["runID"] > 0
            and set(files) == set(record.get("files", {}))
            and required_files <= set(files) <= required_files | OPTIONAL_PROOF_FILES, "Incomplete packaging provenance")
    require(('submitted-dmg-proof.zip' in files) == (record['stage'] == 'complete'), 'Packaging proof has the wrong submission stage')
    require((set(files) & SOURCE_REUSE_FILES) == (SOURCE_REUSE_FILES if record['stage'] == 'complete' and retained_compiled_product(record) else set()),
            'Source qualification proof has the wrong compiled stage')
    require(('current-app-signature.reused.json' in files) == (record['stage'] in {'restored', 'complete'} and compiled_signed_product(record)),
            'Current App signature proof has the wrong compiled stage')
    if 'current-app-signature.reused.json' in files:
        from compiled_app_release import verify_current_signature_reuse
        verify_current_signature_reuse(json.loads(files['current-app-signature.reused.json']), record)
    from compiled_component_reuse import qualified, verify_native_record
    require(('component-notary-observations.zip' in files) == (record['stage'] == 'complete' and qualified(record)),
            'Existing App notary observations have the wrong canonical stage')
    if 'component-notary-observations.zip' in files:
        from notary_continuation import verify_observations
        verify_observations(read_proof_archive(files['component-notary-observations.zip']), record)
    require(('component-native-checks.reused.json' in files) == (record['stage'] in {'restored', 'complete'} and qualified(record)),
            'Component native reuse proof has the wrong stage')
    if 'component-native-checks.reused.json' in files:
        verify_native_record(json.loads(files['component-native-checks.reused.json']), record)
    for name, raw in files.items():
        require(record["files"][name] == {"bytes": len(raw), "sha256": digest(raw)}, "Packaging evidence bytes changed")
    product = revision(record.get("productSourceSHA"))
    producer = revision(record.get("producerSourceSHA"))
    mode = record.get("mode", {})
    require(mode.get("artifactOnly") is True and mode.get("dryRun") is True
            and mode.get("productSourceSHA") == product and isinstance(record.get("ref"), str) and record["ref"],
            "Packaging mode or source context differs")
    run = api("actions/runs/" + str(record["runID"]))
    require(run.get("id") == record["runID"] and run.get("head_sha") == producer
            and run.get("head_branch") == record["ref"] and run.get("run_attempt") == 1
            and run.get("repository", {}).get("full_name") == REPOSITORY
            and run.get("actor", {}).get("login") == "iret77" and run.get("event") == "workflow_dispatch"
            and run.get("path") == ".github/workflows/release.yml", "Packaging execution identity changed")
    require(source_closure(product, producer) == record.get("closure")
            and record["closure"]["productTreeSHA"] == record.get("productTreeSHA")
            and record["closure"]["producerTreeSHA"] == record.get("producerTreeSHA"), "Packaging source closure changed")
    harness = json.loads(files["harness-source.json"])
    original = json.loads(files["product-source.json"])
    require(harness.get("runID") == mode.get("verifiedSourceRunID")
            and original.get("runID") == mode.get("productSourceRunID"), "Packaging source proof producer changed")
    validate_source(harness, files["harness-source-original-proof.zip"], files["harness-source-original-job.log"],
                    producer, run["head_branch"])
    validate_source(original, files["product-source-original-proof.zip"], files["product-source-original-job.log"],
                    product, original.get("sourceRef"))
    previous, state = prior_origin(mode, product, chain=chain)
    if state is None:
        require(cohort_signed_product(record) and mode.get('signedBuildRunID') == previous_signed_build(previous)
                and previous == record.get('previousNotary') and files['pre-submit-origin.json'] == encoded(previous),
                'Pre-submit origin or its actual typed signed build changed')
    else:
        require(state == files["prior-notary-state.zip"] and previous["context"] == record.get("previousNotary", {}).get("context")
                and previous["journals"] == record.get("previousNotary", {}).get("journals")
                and previous.get('preSubmit') == record.get('previousNotary', {}).get('preSubmit'), "Previous notary evidence changed")
        matching_artifact(record["previousNotary"]["stateArtifact"], previous["stateArtifact"])
    require(record['previousNotary'].get('acceptedAppNotary') == previous.get('acceptedAppNotary'),
            'Previous accepted App notarization provenance changed')
    if previous["dmgArtifact"] is None:
        require(record["previousNotary"].get("dmgArtifact") is None and record["previousNotary"].get("dmgProof") is None,
                "Packaging invented a previous DMG checkpoint")
    else:
        matching_artifact(record["previousNotary"]["dmgArtifact"], previous["dmgArtifact"])
        recorded_dmg = record["previousNotary"].get("dmgProof", {})
        require(recorded_dmg.get("checkpoint") == previous["dmgProof"]["checkpoint"]
                and recorded_dmg.get("rawProofSHA256") == previous["dmgProof"]["rawProofSHA256"], "Previous DMG proof changed")
        matching_artifact(recorded_dmg.get("artifact", {}), previous["dmgProof"]["artifact"])
    require(record["previousNotary"].get("parentProvenance") == previous.get("parentProvenance"), "Parent provenance selector changed")
    instant = lambda value: datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(instant(previous["producer"]["created_at"]) < instant(run["created_at"])
            and instant(previous["job"]["completed_at"]) <= instant(run["created_at"]), "Packaging ancestry has invalid chronology")
    previous_source = previous["producer"]["head_sha"]
    if previous_source not in {product, producer}:
        continuation = comparison(previous_source, producer)
        allowed = packaging_paths(product, producer)
        require({entry["filename"] for entry in continuation["files"]} <= allowed,
                "Packaging continuation changed unsupported inputs")
    original_build = previous_signed_build(previous)
    require(original_build == record.get("originalSignedBuildRunID"), "Packaging selected another original signed build")
    signed, proof, original_state = signed_input(original_build, product)
    require(proof == files["signed-proof.zip"] and signed["manifest"] == record.get("signedInput", {}).get("manifest")
            and signed["manifest"]["identity"]["version"] == mode.get("version"), "Original signed product changed")
    for name in ("payloadArtifact", "proofArtifact"):
        matching_artifact(record["signedInput"][name], signed[name])
    if original_state is None:
        require("original-notary-state.zip" not in files and record["signedInput"].get("originalNotary") is None,
                "Packaging invented an original Apple state")
    else:
        require(files.get("original-notary-state.zip") == original_state
                and record["signedInput"].get("originalNotary", {}).get("context") == signed["originalNotary"]["context"]
                and record["signedInput"]["originalNotary"].get("journals") == signed["originalNotary"]["journals"],
                "Original Apple state bytes or IDs changed")
        matching_artifact(record["signedInput"]["originalNotary"]["artifact"], signed["originalNotary"]["artifact"])
        require(all(previous["journals"].get(key) == value for key, value in signed["originalNotary"]["journals"].items()),
                "Previous state dropped or changed an original Apple submission")
    require(signed.get('compiledProduct') == record.get('signedInput', {}).get('compiledProduct'), 'Compiled signed-product qualification changed')
    require(signed.get('cohortProduct') == record.get('signedInput', {}).get('cohortProduct'), 'Cohort signed-product qualification changed')
    require(signed.get('componentProduct') == record.get('signedInput', {}).get('componentProduct'), 'Component signed-product qualification changed')
    require(signed["manifest"]["files"]["NexGenVideo.zip"]["sha256"] in previous["journals"] or compiled_first_notary(record),
            "Original App Apple submission disappeared")
    if record["stage"] != "input":
        require(record.get("restoredOriginal") == {"sourceSHA": product, "producerRun": original_build,
                "appTreeSHA256": signed["manifest"]["appTreeSHA256"], "identity": signed["manifest"]["identity"]},
                "Restored provenance differs from the original signed product")
        packs = record.get("originalPackArchives")
        require(type(packs) is dict and packs and all(name.startswith(".build/plugins/") and name.endswith(".ngvpack.zip") for name in packs)
                and qualified_pack_archives(packs, record), "Restored pack provenance differs")
    if record["stage"] == "complete":
        manifest_app_sha = signed["manifest"]["files"]["NexGenVideo.zip"]["sha256"]
        final = record.get("final", {})
        app = final.get("app", {})
        require(app.get("NGVSourceCommit") == product
                and app.get("CFBundleShortVersionString") == signed["manifest"]["identity"]["version"]
                and str(app.get("CFBundleVersion")) == signed["manifest"]["identity"]["build"]
                and app.get("treeSHA256") == final.get("appTreeSHA256")
                and all(isinstance(final.get(key), str) and re.fullmatch("[a-f0-9]{64}", final[key])
                        for key in ("appTreeSHA256", "dmgSHA256", "runtimeArchiveSHA256", "bpySourceReceiptSHA256",
                                    "packArchiveSHA256", "packTreeSHA256", "submittedDMGSHA256")), "Complete packaging proof is incomplete")
        require(final.get("notaryContext") == {"schema": "release-notary-context/v2", "repository": REPOSITORY,
                    "sourceSHA": product, "producerSourceSHA": producer, "buildRunID": original_build, "runID": record["runID"]}
                and type(final.get("notaryJournals")) is dict
                and all(final["notaryJournals"].get(key) == value for key, value in previous["journals"].items())
                and final["submittedDMGSHA256"] in final["notaryJournals"], "Complete proof lost known Apple submissions")
        require(manifest_app_sha in final['notaryJournals'], 'Complete packaging lost the actual App Apple submission')
        if cohort_signed_product(record):
            require(final.get('guideSHA256') == digest(git('show', producer + ':scripts/Install NexGenVideo.txt')),
                'Complete installation guide differs from its reviewed source')
        if retained_compiled_product(record):
            from compiled_app_release import verify_source_reuse, PACK_SHA, PACK_TREE
            source_reuse = final.get('bpySourceReuse')
            require(type(source_reuse) is dict and set(source_reuse) == SOURCE_REUSE_FILES
                and all(source_reuse[name].encode() == files[name] for name in SOURCE_REUSE_FILES),
                'Complete source qualification bytes changed')
            verify_source_reuse(source_reuse, product, producer, record['runID'])
            require(final['bpySourceReceiptSHA256'] == digest(files['bpy-source-receipt.json'])
                and final['packArchiveSHA256'] == PACK_SHA and final['packTreeSHA256'] == PACK_TREE,
                'Complete compiled source or pack qualification differs')
            require(final.get('guideSHA256') == digest(git('show', producer + ':scripts/Install NexGenVideo.txt')),
                'Complete installation guide differs from its reviewed source')
        require('submitted-dmg-proof.zip' in files, 'Complete proof lacks the exact DMG submission payload proof')
        members = read_proof_archive(files['submitted-dmg-proof.zip'])
        require(set(members) == {'manifest.json'}, 'Unexpected submitted DMG proof members')
        submission = json.loads(members['manifest.json'])
        checkpoint = submission.get('checkpoint', {})
        require(submission.get('schema') == 'nexgenvideo/dmg-artifact-proof/1' and submission.get('sourceSHA') == product
                and submission.get('producerSourceSHA') == producer and submission.get('runID') == record['runID']
                and checkpoint.get('schema') == 'release-dmg-checkpoint/v2' and checkpoint.get('context') == final['notaryContext']
                and checkpoint.get('appRuntimeTreeSHA256') == final['appTreeSHA256']
                and checkpoint.get('files', {}).get('NexGenVideo.dmg', {}).get('sha256') == final['submittedDMGSHA256'],
                'Complete proof substituted the submitted DMG identity')
        jobs = api(f"actions/runs/{record['runID']}/attempts/1/jobs?per_page=100")
        releases = [job for job in jobs.get('jobs', []) if job.get('name') == 'release']
        require(jobs.get('total_count') == len(jobs.get('jobs', [])) and len(releases) == 1, 'Incomplete current packaging jobs')
        artifact = final.get('dmgSubmissionArtifact', {})
        require(artifact.get('size_in_bytes') == len(files['submitted-dmg-proof.zip'])
                and artifact.get('digest') == 'sha256:' + digest(files['submitted-dmg-proof.zip']), 'Submitted DMG proof bytes changed')
        verify_artifact(artifact, run, releases[0], artifact.get('id'), artifact.get('digest', '')[7:], 'release-dmg-proof-' + product)
        validate_dmg_descriptor(submission, run, releases[0], final.get('dmgSubmissionPayloadArtifact', {}), product, artifact)
    if execution:
        execution_source(record)
    return product


def execution_source(record):
    require(str(record["runID"]) == os.environ["GITHUB_RUN_ID"] and record["producerSourceSHA"] == os.environ["GITHUB_SHA"]
            and record["ref"] == os.environ["GITHUB_REF_NAME"] and os.environ["GITHUB_RUN_ATTEMPT"] == "1"
            and git("rev-parse", "HEAD").decode().strip() == record["producerSourceSHA"], "Local packaging execution changed")
    dirty = set(git("diff", "--no-renames", "--name-only", "HEAD", "--").decode().splitlines())
    require(dirty <= {"Sources/NexGenVideo/Resources/Info.plist"}, "Packaging code changed after qualification")


def save_stage(root, record, files):
    required_files = proof_files(record)
    require(record.get("stage") in {"input", "restored", "complete"}
            and required_files <= set(files) <= required_files | OPTIONAL_PROOF_FILES,
            "Invalid packaging proof snapshot")
    directory = root / record["stage"]
    directory.mkdir(parents=True, exist_ok=False)
    for name, raw in {**files, "packaging-provenance.json": encoded(record)}.items():
        with (directory / name).open("xb") as stream:
            stream.write(raw); stream.flush(); os.fsync(stream.fileno())
    return directory


def read_stage(root, stage):
    require(stage in {"input", "restored", "complete"}, "Unknown packaging proof stage")
    directory = root / stage
    require(directory.is_dir() and not directory.is_symlink(), "Packaging proof snapshot is missing")
    metadata = directory / 'packaging-provenance.json'
    require(metadata.is_file() and not metadata.is_symlink() and metadata.stat().st_size <= MAX_PROOF_BYTES,
            'Packaging metadata is missing or oversized')
    record = json.loads(metadata.read_bytes())
    required_files = proof_files(record)
    names = {path.name for path in directory.iterdir()}
    require(required_files | {"packaging-provenance.json"} <= names <= required_files | OPTIONAL_PROOF_FILES | {"packaging-provenance.json"}
            and all(path.is_file() and not path.is_symlink() for path in directory.iterdir()), "Packaging snapshot members changed")
    files = {name: (directory / name).read_bytes() for name in names - {"packaging-provenance.json"}}
    require(sum(map(len, files.values())) <= MAX_PROOF_BYTES, "Local packaging proof exceeds its bound")
    require(record.get("stage") == stage, "Packaging proof changed its stage")
    return record, files


def current_binding():
    root = os.environ.get("RETAINED_PACKAGING_ROOT", "")
    checksum = os.environ.get("RETAINED_PACKAGING_INPUT_SHA256", "")
    if not root and not checksum:
        return None
    require(root and re.fullmatch("[a-f0-9]{64}", checksum), "Incomplete local packaging source binding")
    record, files = read_stage(Path(root), "input")
    require(digest((Path(root) / "input/packaging-provenance.json").read_bytes()) == checksum,
            "Local packaging source binding changed")
    validate_binding(record, files, execution=True)
    return record


def current_product_source():
    binding = current_binding()
    return binding["productSourceSHA"] if binding is not None else os.environ["GITHUB_SHA"]


def load_provenance(run_id, product, selected, *, allow_failed=False, chain=None):
    require(type(run_id) is int and run_id > 0 and type(selected) is dict
            and type(selected.get("artifactID")) is int and selected["artifactID"] > 0,
            "Complete packaging provenance selectors are required")
    producer = revision(selected.get("producerSourceSHA"))
    require(producer != revision(product) and re.fullmatch("[a-f0-9]{64}", selected.get("artifactSHA256", "")),
            "Packaging provenance source or digest differs")
    if chain is None:
        chain = provenance_chain()
    identity = (run_id, selected["artifactID"])
    enter_provenance(chain, identity)
    budget_token = BUDGET.set(chain)
    try:
        run = api(f"actions/runs/{run_id}")
        require(run.get("id") == run_id and run.get("head_sha") == producer
                and run.get("repository", {}).get("full_name") == REPOSITORY
                and run.get("actor", {}).get("login") == "iret77" and run.get("run_attempt") == 1
                and run.get("path") == ".github/workflows/release.yml" and run.get("event") == "workflow_dispatch",
                "Packaging provenance producer differs")
        jobs = api(f"actions/runs/{run_id}/attempts/1/jobs?per_page=100")
        require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete packaging producer jobs")
        releases = [job for job in jobs["jobs"] if job.get("name") == "release"]
        require(len(releases) == 1, "Missing or duplicate packaging producer job")
        job = releases[0]
        require(job.get("run_id") == run_id and job.get("head_sha") == producer and job.get("run_attempt") == 1
                and job.get("labels") == ["macrunner"] and job.get("status") == "completed"
                and job.get("conclusion") in ({"success", "failure", "cancelled"} if allow_failed else {"success"}),
                "Packaging producer job did not reach the required completion")
        artifact = api("actions/artifacts/" + str(selected["artifactID"]))
        require(artifact.get("digest") == "sha256:" + selected["artifactSHA256"], "Packaging provenance artifact digest changed")
        name = artifact.get("name")
        require(name in ({COMPLETE_ARTIFACT, RESTORED_ARTIFACT} if allow_failed else {COMPLETE_ARTIFACT}),
                "Partial packaging evidence cannot qualify a runtime")
        verify_artifact(artifact, run, job, selected["artifactID"], selected["artifactSHA256"], name)
        raw = artifact_bytes(artifact, MAX_PROOF_BYTES)
        members = read_proof_archive(raw)
        require("packaging-provenance.json" in members, "Missing canonical packaging proof")
        encoded_record = members.pop("packaging-provenance.json")
        record = json.loads(encoded_record)
        require(encoded(record) == encoded_record and record.get("runID") == run_id
                and record.get("productSourceSHA") == product and record.get("producerSourceSHA") == producer,
                "Canonical packaging proof source or encoding differs")
        require(record.get("stage") in ({"restored", "complete"} if allow_failed else {"complete"})
                and (record["stage"] == "complete") == (name == COMPLETE_ARTIFACT), "Packaging proof stage changed")
        if record["stage"] == "restored":
            restored = [step for step in job.get("steps", []) if step.get("name") == "Restore exact signed build"]
            require(len(restored) == 1 and restored[0].get("conclusion") == "success", "Parent signed restore never passed")
        require('original-api-evidence.zip' in members, 'Canonical proof lacks full original acquisition evidence')
        with authenticated_originals(members['original-api-evidence.zip'], record, artifact, job) as supplement:
            validate_binding(record, members, chain=chain)
        raw_checksum = digest(encoded_record)
        if "rawProofSHA256" in selected:
            require(selected["rawProofSHA256"] == raw_checksum, "Parent canonical proof bytes changed")
        chain["archives"][identity] = {"raw": raw, "artifact": artifact, "run": run, "job": job,
                                       "rawProofSHA256": raw_checksum,
                                       "acquiredAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
        if supplement is not None:
            chain["archives"][identity]["supplementSHA256"] = digest(supplement)
        return {"record": record, "files": members, "rawProofSHA256": raw_checksum,
                "artifact": artifact, "run": run, "job": job, "archives": chain["archives"]}
    finally:
        BUDGET.reset(budget_token)
        chain["depth"] -= 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest='mode', required=True)
    for name in ('bind', 'restored', 'dmg-proof'):
        command = commands.add_parser(name)
        command.add_argument('--root', required=True, type=Path)
        if name == 'restored': command.add_argument('--signed-root', required=True, type=Path)
        if name == 'dmg-proof':
            command.add_argument('--artifact-id', required=True, type=int)
            command.add_argument('--artifact-sha256', required=True)
    commands.add_parser('source')
    commands.add_parser('validate-inputs')
    notary = commands.add_parser('notary-source')
    notary.add_argument('--artifact', required=True, type=Path)
    notary.add_argument('--checkpoint', type=Path)
    consumer = commands.add_parser('consumer')
    consumer.add_argument('--run-id', required=True, type=int)
    consumer.add_argument('--product-source', required=True)
    consumer.add_argument('--output', required=True, type=Path)
    consumer_arguments(consumer)
    args = parser.parse_args()
    if args.mode == 'bind': bind_current(args.root)
    elif args.mode == 'restored': record_restored(args.root, args.signed_root)
    elif args.mode == 'dmg-proof': record_dmg_payload(args.root, args.artifact_id, args.artifact_sha256)
    elif args.mode == 'source': print(current_product_source())
    elif args.mode == 'validate-inputs': mode_inputs(event_values())
    elif args.mode == 'notary-source': print(notary_product_source(args.artifact, args.checkpoint))
    else:
        require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY,
                'Prepare packaging consumers only in owned Actions')
        binding = consumer_binding(args.run_id, args.product_source, argument_selectors(args), archive_root=args.output)
        require(binding is not None, 'Explicit packaging provenance is required')
        args.output.mkdir(parents=True, exist_ok=True)
        with (args.output / 'consumer.json').open('xb') as stream:
            stream.write(encoded(binding)); stream.flush(); os.fsync(stream.fileno())


if __name__ == "__main__":
    import retained_packaging
    retained_packaging.main()
