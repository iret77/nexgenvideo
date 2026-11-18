import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import zipfile

from retained_app_test_products import api, checksum, download, require, verify_artifact

FIXTURE = Path(__file__).with_name('fixtures') / 'signed-component-carrier-1170.json'
REBUILT_SUPERVISOR = 'Sources/NexGenVideoBpySupervisor'
FIXTURE_SHA256 = '7046e77d61c974e8b6f888ce08289d2353e43e78b07918398df2a3f31535ec29'


def canonical_sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def origin(value):
    raw = FIXTURE.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == FIXTURE_SHA256, 'Signed component carrier fixture changed')
    selected = json.loads(raw)
    prior, current = selected['componentSourceObjects'], value.get('componentSourceObjects', {})
    require(selected.get('schema') == 'signed-component-carrier-origin/v1'
        and value.get('signedBase') == selected['signedBase'] and isinstance(current, dict) and prior.keys() == current.keys()
        and all(isinstance(blob, str) and re.fullmatch('[a-f0-9]{40}', blob) for blob in current.values())
        and {path for path in prior if prior[path] != current[path]} <= {REBUILT_SUPERVISOR},
        'Signed component carrier changed sources outside the independently rebuilt supervisor')
    return selected


def engine_component_source_binding(head, value):
    if value is None:
        return None
    import app_cohort_v2
    from release_engine_resume import ENGINE_SOURCE_OBJECTS
    prior, current = origin(value)['componentSourceObjects'], value['componentSourceObjects']
    require(app_cohort_v2.objects(head, current) == current, 'Current Engine and component source binding differs')
    path = REBUILT_SUPERVISOR
    if current[path] == prior[path]:
        return None
    require(ENGINE_SOURCE_OBJECTS[path] == prior[path],
        'Retained Engine loses its original Supervisor source identity')
    return {'path': path, 'originalGitObject': prior[path], 'currentGitObject': current[path],
        'role': 'separate-executable', 'engineSourceUnchanged': True}


def record(value):
    selected = origin(value)
    return {'schema': 'signed-component-carrier/v1', 'sourceSHA': selected['sourceSHA'],
        'runID': selected['runID'], 'jobID': selected['jobID'],
        'proofArtifact': selected['proofArtifact'], 'payloadArtifact': selected['payloadArtifact'],
        'manifestSHA256': selected['manifestSHA256'], 'appTreeSHA256': selected['appTreeSHA256'],
        'componentMapSHA256': selected['componentMapSHA256'],
        'componentRecordCount': selected['componentRecordCount'],
        'originalSourceReceiptSHA256': selected['originalSourceReceiptSHA256'],
        'qualifiedRuntimeReviewSHA256': selected['qualifiedRuntimeReviewSHA256']}


def verify_record(receipt, value):
    require(receipt == record(value), 'Signed component transport provenance changed')


def verify_components(components, value):
    selected = origin(value)
    require(isinstance(components, dict) and len(components) == selected['componentRecordCount']
        and canonical_sha(components) == selected['componentMapSHA256'],
        'Signed component bytes, paths, modes or links changed')


def original_source_receipt(manifest, value):
    selected = origin(value)
    assembly = manifest.get('componentAssembly')
    require(isinstance(assembly, dict), 'Signed carrier component assembly is malformed')
    handoff = assembly.get('sourceHandoff')
    require(isinstance(handoff, dict) and isinstance(handoff.get('originalReceipt'), str),
        'Signed carrier original corresponding-source receipt is malformed')
    raw = handoff['originalReceipt'].encode()
    require(handoff.get('schema') == 'compiled-component-source-handoff/v2'
        and handoff.get('state') == 'REUSED' and handoff.get('semanticSourceValidationPerformed') is False
        and hashlib.sha256(raw).hexdigest() == handoff.get('originalReceiptSHA256') == selected['originalSourceReceiptSHA256'],
        'Signed carrier lost its exact original corresponding-source receipt')
    return raw


def verify_manifest(raw, value):
    selected = origin(value)
    require(hashlib.sha256(raw).hexdigest() == selected['manifestSHA256'], 'Signed component carrier manifest changed')
    manifest = json.loads(raw)
    import release_checkpoint
    release_checkpoint.verify_manifest(manifest, selected['sourceSHA'], selected['runID'])
    assembly = manifest.get('componentAssembly', {})
    context = manifest.get('nativeEvidence', {}).get('cohortV2', {})
    require(manifest.get('identity', {}).get('build') == selected['build']
        and manifest.get('appTreeSHA256') == selected['appTreeSHA256'] and manifest.get('files') == selected['files']
        and assembly.get('signedBase') == value['signedBase']
        and type(assembly.get('componentCompilerExecutions')) is int and assembly['componentCompilerExecutions'] == 0
        and context.get('componentSourceObjects') == selected['componentSourceObjects']
        and assembly.get('cohortV2') == context, 'Signed component carrier identity changed')
    verify_components(assembly.get('unchangedSignedComponents'), value)
    original_source_receipt(manifest, value)
    return manifest


def proof_manifest(raw, value):
    selected = origin(value)['proofArtifact']
    require(len(raw) == selected['size_in_bytes']
        and hashlib.sha256(raw).hexdigest() == selected['digest'].removeprefix('sha256:'),
        'Signed component carrier proof archive changed')
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entries = archive.infolist()
        require(len(entries) == 1 and entries[0].filename == 'manifest.json'
            and not entries[0].is_dir() and entries[0].file_size <= 16 * 1024**2
            and stat.S_IFMT(entries[0].external_attr >> 16) in (0, stat.S_IFREG),
            'Signed component carrier proof has an unsafe inventory')
        return verify_manifest(archive.read('manifest.json'), value)


def metadata(value):
    selected = origin(value)
    run = api('actions/runs/' + str(selected['runID']))
    job = api('actions/jobs/' + str(selected['jobID']))
    require(run.get('id') == selected['runID'] and run.get('head_sha') == selected['sourceSHA']
        and run.get('run_attempt') == 1 and run.get('event') == 'workflow_dispatch'
        and run.get('workflow_id') == 303346287 and run.get('path') == '.github/workflows/release.yml'
        and run.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and run.get('actor', {}).get('login') == 'iret77' and run.get('status') == 'completed'
        and job.get('id') == selected['jobID'] and job.get('run_id') == selected['runID']
        and job.get('head_sha') == selected['sourceSHA'] and job.get('run_attempt') == 1
        and job.get('name') == 'release-build' and job.get('labels') == ['macrunner']
        and job.get('status') == 'completed' and job.get('conclusion') == 'success',
        'Signed component carrier producer or successful builder changed')
    artifacts = {}
    for role in ('proof', 'payload'):
        expected = selected[role + 'Artifact']
        actual = api('actions/artifacts/' + str(expected['id']))
        verify_artifact(actual, run, job, expected['id'], expected['digest'].removeprefix('sha256:'), expected['name'])
        require(actual.get('size_in_bytes') == expected['size_in_bytes'], 'Signed component carrier size changed')
        artifacts[role] = actual
    import app_cohort_v2
    for source, expected in ((selected['sourceSHA'], selected['componentSourceObjects']),
            (os.environ['GITHUB_SHA'], value['componentSourceObjects'])):
        require(app_cohort_v2.objects(source, expected) == expected,
            'Signed component carrier or current rebuild has different actual source objects')
    return run, job, artifacts


def provenance(value, product, native_producer):
    import retained_packaging
    selected = origin(value)
    run, job, artifacts = metadata(value)
    raw = retained_packaging.read_api('actions/artifacts/' + str(selected['proofArtifact']['id']) + '/zip',
        maximum=16 * 1024**2)
    manifest = proof_manifest(raw, value)
    return {'nativeProducer': native_producer,
        'carrier': {'schema': 'signed-base-pack-carrier/v1', 'productSourceSHA': product,
            'signedBase': value['signedBase'], 'transport': record(value),
            'producerRunID': run['id'], 'producerJobID': job['id'],
            'proofArtifact': artifacts['proof'], 'payloadArtifact': artifacts['payload'],
            'manifestSHA256': selected['manifestSHA256'], 'pluginsArchive': manifest['files']['plugins.tar.gz'],
            'packArchiveSHA256': value['signedBase']['packArchiveSHA256'],
            'packTreeSHA256': value['signedBase']['packTreeSHA256']}}


def dependencies(value):
    selected = origin(value)
    return [{'id': item['id'], 'name': item['name'], 'sha256': item['digest'].removeprefix('sha256:'),
        'bytes': item['size_in_bytes'], 'runID': selected['runID'], 'sourceSHA': selected['sourceSHA']}
        for item in (selected['proofArtifact'], selected['payloadArtifact'])]


def acquire(root, value):
    import release_checkpoint
    import compiled_app_release
    selected = origin(value)
    _, _, artifacts = metadata(value)
    proof = root / 'signed-base-proof.zip'
    download(artifacts['proof'], proof)
    manifest = proof_manifest(proof.read_bytes(), value)
    payload = root / 'signed-base-payload.zip'
    download(artifacts['payload'], payload)
    folder = root / 'signed-base'
    folder.mkdir()
    with compiled_app_release.verified_zip(payload, 8 * 1024**3,
            qualified_sha=selected['payloadArtifact']['digest'].removeprefix('sha256:')) as archive:
        require(len(archive.infolist()) == len(release_checkpoint.FILES) + 1
            and set(archive.namelist()) == set(release_checkpoint.FILES) | {'manifest.json'}
            and all(not item.is_dir() and stat.S_IFMT(item.external_attr >> 16) in (0, stat.S_IFREG)
                for item in archive.infolist())
            and verify_manifest(release_checkpoint.signed_manifest_bytes(archive), value) == manifest,
            'Signed component carrier payload lost its exact proof')
        for name in release_checkpoint.FILES:
            expected = manifest['files'][name]
            require(archive.getinfo(name).file_size == expected['bytes'], 'Signed component carrier member size changed')
            with archive.open(name) as source, (folder / name).open('xb') as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
            require(checksum(folder / name) == expected['sha256'], 'Signed component carrier member bytes changed')
    return folder, manifest
