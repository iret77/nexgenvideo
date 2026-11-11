import argparse
from collections import Counter
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile
import uuid

import native_app_target_build as targets
import release_checkpoint as checkpoint
import release_engine_resume as engine
import release_test_repair as retained
from release_acceptance_identity import tree_sha256 as canonical_bundle_tree
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
SIGNED_RESUME = {'sourceSHA': '58644c62e3a01c03ffcc46a1969e3f69bd296942', 'runID': 42769966061,
    'builderJobID': 129675318968, 'releaseJobID': 129684301297,
    'artifactID': 13742158537, 'artifactSHA256': 'aa535d533ccf2fd28e77b28a01f2ec393926b226aa64354198d2dbc3e54bd138',
    'artifactBytes': 1696781605, 'proofArtifactID': 13741669433,
    'proofArtifactSHA256': 'aaac4fe7503f6acbd932fdb0ec5d7c4093dcabee7254a57992c7261c21074faf',
    'assemblyArtifactID': 13742357738, 'assemblyArtifactSHA256': '2ba060194952846c6d6a74d7be15f2bfd125b5e78d51bed694eee3a759e95c05',
    'manifestSHA256': 'c67f8c5e46f975c0b0284bab66c637976dc7b365c81f7c5530dbeb28924d39a0',
    'appArchiveSHA256': 'd776b837dc2f9568df57a7e9637ae14556fd4711e7b84c70f965d9d83e3dd5f5',
    'appTreeSHA256': '18f86445d8fe35d58ab484d7613f4280201d3c73a99574d198eed5f375057931',
    'stateArtifactID': 13742671909, 'stateSHA256': 'f89025527630f0dc3e58c9197ca948335e6b840467a72c58e46c3c5857e6407b',
    'sourceReceiptSHA256': 'e28a77d6f63e7c7a6a5282428c202cd5027ae1684949a60e78d9b90dec840a53'}
SIGNATURE_APP_TREE = 'f2b2aa30a5a56a08341c17c22add2225ab1da63fce49e43886cbda3909f6c353'
# These original command bytes were independently qualified from the bound artifact.
SIGNATURE_ORIGIN = {'runID': 42752029331, 'sourceSHA': '7224319479875080119c1e916fc5d846b43405f9',
    'jobID': 129617782305, 'artifactID': 13734666595,
    'artifactSHA256': '27d032bb823e9375720fc178cba10d4b6168717d0daa2dee55432ea521f0af61',
    'artifactBytes': 2871241575}
SIGNATURE_COMMAND = {'argv': ['codesign', '--verify', '--deep', '--strict', '.build/NexGenVideo.app'],
    'exitCode': 0, 'stdout': '', 'stderr': ''}
SIGNATURE_RECORD_SHA256 = {'argv.json': '416d51c8c607ccf886bd87f18fe7f4f3a0529ec439d56ac7a4b7225de5d6ac21',
    'exit.json': 'ff8ae5796bcef71911ff9c5c3eaea341819c471f669549e252b830106edd4305',
    'stdout': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'stderr': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'}
PACK_NATIVE_PROOF = {'jobID': 128864202422, 'artifactBytes': 3627462402,
    'fullRawSHA256': 'd0a7c9a47356757dd2311531c479c49903ca7a1b4b283a77c12580bc3969ec77',
    'fullRawBytes': 442029, 'workflowSHA256': 'b8ccdb85310397135dcfe8a6aecce72c8dec4b469d2d7052f983ba5395bcb2d4',
    'steps': [{'name': 'Notarize and staple downloadable format packs', 'status': 'completed',
        'conclusion': 'success', 'number': 19, 'started_at': '2026-11-08T21:21:32Z', 'completed_at': '2026-11-08T21:21:51Z'},
        {'name': 'Load-test — the SIGNED app actually loads the SIGNED pack from an EXTERNAL dir',
        'status': 'completed', 'conclusion': 'success', 'number': 21,
        'started_at': '2026-11-08T21:21:52Z', 'completed_at': '2026-11-08T21:21:53Z'}],
    'stepRawFragmentSHA256': {'19': '1348d49de175ec94bfc875423cb0e6c2ccbbc6e0680bbe51179bdfe66a2d3206',
        '21': '7444c560e9e0be8b89f2b4c2327849837233407d45b3a378c0f4eb7a3bbf91b7'}}
PHASES = ('production', 'testable', 'tests')
SELECTOR_KEYS = {'runID', 'sourceSHA', 'artifactID', 'artifactSHA256', 'receiptSHA256'}
COMPONENT_BUILD = '107'
LINKED_ENGINE = {'sha256': '8b4b6e0f3a8d11a7260932e64673583cbc696400094ed38d54343a6a6093ac2c',
    'bytes': 14573720, 'uuid': 'CB1CDC7B-9591-32A1-9FC5-735183BA68E2',
    'dsymSHA256': 'ac2b37ffb1a439c2b2e4ae10f9e93dc26abe063a3d6b37af2237ecf1933cf066',
    'moduleSHA256': 'a5ac6db30d91f3dfc8caeaf901f2b6b47f783c50edd4e2649144232a5808fdc5',
    'mainUnsignedSHA256': '6d26be36d9fd01fe2c5b9043d38c7eb55685077bd86cb2610bb156e74ec94eac',
    'retiredImageSHA256': 'ac85e1ee7e43c749afe19a5bf906930d164a044d426975c7feefc5d2ff281d4e',
    'payloadSHA256': '1353c00481ef5b65a83ecfcb8cfce67a6e6323b4ce853497db718571863f1e59',
    'symbolsTreeSHA256': '6f59009b23267b8374f0153aaa621e913217931991da1a4c53d5e8eb46819452'}
MAIN_PRODUCT = {'compiledImageSHA256': '6d26be36d9fd01fe2c5b9043d38c7eb55685077bd86cb2610bb156e74ec94eac',
    'uuid': 'C1AB1815-D829-3F3E-B536-C8F3D703FEE2',
    'payloadSHA256': '53c6f0195c5234061d4ccbb092ca3a33ea62b5d471b181eacaab138e60e8691b',
    'symbolsTreeSHA256': '7f3ddf00eeb73d24988efca0d99f635b2c8aee661486a0243f15d8e3b9c0b187',
    'dwarfSHA256': '6b17928c2d439a0a2c1459e6819fa4ac33c798070f7d16728add201ee38a2fb7'}


def signed_resume_source(run_id, source):
    return (run_id, source) == (SIGNED_RESUME['runID'], SIGNED_RESUME['sourceSHA'])


def verify_signed_resume(producer, builder, payload, proof, manifest_raw, *, verifier=verify_artifact):
    origin = SIGNED_RESUME
    require(signed_resume_source(producer.get('id'), producer.get('head_sha'))
        and producer.get('repository', {}).get('full_name') == REPOSITORY
        and producer.get('actor', {}).get('login') == 'iret77' and producer.get('run_attempt') == 1
        and producer.get('path') == '.github/workflows/release.yml' and producer.get('event') == 'workflow_dispatch'
        and producer.get('status') == 'completed' and producer.get('conclusion') == 'failure',
        'Compiled signed-product origin differs')
    require(builder.get('id') == origin['builderJobID'] and builder.get('run_id') == origin['runID']
        and builder.get('head_sha') == origin['sourceSHA'] and builder.get('run_attempt') == 1
        and builder.get('name') == 'release-build' and builder.get('labels') == ['macrunner']
        and builder.get('status') == 'completed' and builder.get('conclusion') == 'success',
        'Compiled signed-product builder differs')
    for name in ('Assemble and sign the new App with unchanged retained components',
            'Record compiled App signed input without invoking a build', 'Retain signed build input', 'Retain signed build proof'):
        matches = [step for step in builder.get('steps', []) if step.get('name') == name]
        require(len(matches) == 1 and matches[0].get('conclusion') == 'success',
            'Compiled signed-product stage did not pass: ' + name)
    prefix = 'release-signed-input-' + origin['sourceSHA']
    for artifact, identifier, digest, name in (
            (payload, origin['artifactID'], origin['artifactSHA256'], prefix),
            (proof, origin['proofArtifactID'], origin['proofArtifactSHA256'], prefix + '-proof')):
        verifier(artifact, producer, builder, identifier, digest, name)
    require(payload.get('size_in_bytes') == origin['artifactBytes']
        and hashlib.sha256(manifest_raw).hexdigest() == origin['manifestSHA256'],
        'Compiled signed-product payload or manifest differs')
    manifest = checkpoint.verify_manifest(json.loads(manifest_raw), origin['sourceSHA'], origin['runID'])
    require(manifest.get('nativeEvidence', {}).get('schema') == 'release-native-compiled-app/v4'
        and manifest['identity'] == {'version': '1.8.0', 'build': '106', 'sourceSHA': origin['sourceSHA'],
            'catalogURL': 'https://github.com/iret77/nexgenvideo/releases/download/plugins/catalog.json'}
        and manifest['appTreeSHA256'] == origin['appTreeSHA256']
        and manifest['files']['NexGenVideo.zip']['sha256'] == origin['appArchiveSHA256']
        and manifest['files']['bpy-source-receipt.json']['sha256'] == origin['sourceReceiptSHA256'],
        'Compiled signed-product identity or native scope differs')
    return {'schema': 'compiled-signed-product-reuse/v1', 'original': dict(origin),
        'packArchiveSHA256': PACK_SHA, 'packTreeSHA256': PACK_TREE, 'appRootMode': 0o755,
        'freshCompilerCoreAssemblyOrRootSignPerformed': False}


def original_empty_notary(raw, product, producer, run_id):
    return (product == producer == SIGNED_RESUME['sourceSHA'] and run_id == SIGNED_RESUME['runID']
        and hashlib.sha256(raw).hexdigest() == SIGNED_RESUME['stateSHA256'])


def verify_current_signature_reuse(value, binding):
    require(value == {'schema': 'current-app-signature-reuse/v1', 'state': 'REUSED',
        'original': SIGNED_RESUME, 'command': SIGNATURE_COMMAND, 'recordSHA256': SIGNATURE_RECORD_SHA256,
        'current': {'productSourceSHA': binding['productSourceSHA'], 'harnessSourceSHA': binding['producerSourceSHA'],
            'runID': binding['runID'], 'job': 'release', 'appTreeSHA256': SIGNED_RESUME['appTreeSHA256']},
        'currentNativeSignatureVerificationPerformed': False, 'freshTrustStoreOrRevocationClaimed': False},
        'Current App signature reuse proof changed its actual origin or scope')


def reuse_current_signature(root, app, manifest, binding):
    import retained_packaging as packaging
    from compiled_core_reuse import persist
    require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_JOB') == 'release'
        and os.environ.get('GITHUB_RUN_ATTEMPT') == '1' and packaging.compiled_signed_product(binding)
        and manifest == binding['signedInput']['manifest'], 'Unqualified current signed-product reuse')
    origin = SIGNED_RESUME
    temporary, workspace = Path(os.environ['RUNNER_TEMP']), Path(os.environ['GITHUB_WORKSPACE'])
    require(root.resolve() == temporary.resolve() / 'release-signed-binding', 'Current signature proof escaped its owned root')
    root_anchor = source_directory_identity(root, temporary)
    app_anchor = source_directory_identity(app, workspace)
    run, job = api('actions/runs/' + str(origin['runID'])), api('actions/jobs/' + str(origin['builderJobID']))
    artifact = api('actions/artifacts/' + str(origin['assemblyArtifactID']))
    verify_artifact(artifact, run, job, origin['assemblyArtifactID'], origin['assemblyArtifactSHA256'],
        'release-compiled-app-assembly-' + str(origin['runID']) + '-a1')
    require(run.get('head_sha') == origin['sourceSHA'] and run.get('run_attempt') == 1
        and job.get('id') == origin['builderJobID'] and job.get('labels') == ['macrunner'] and job.get('conclusion') == 'success'
        and app.is_dir() and not app.is_symlink() and stat.S_IMODE(app.lstat().st_mode) == 0o755
        and checkpoint.tree_digest(app) == origin['appTreeSHA256'], 'Materialized current signed App changed')
    source_directory_identity(root, temporary, root_anchor)
    source_directory_identity(app, workspace, app_anchor)
    persist(root / 'current-app-signature.reused.json', {'schema': 'current-app-signature-reuse/v1', 'state': 'REUSED',
        'original': origin, 'command': SIGNATURE_COMMAND, 'recordSHA256': SIGNATURE_RECORD_SHA256,
        'current': {'productSourceSHA': binding['productSourceSHA'], 'harnessSourceSHA': binding['producerSourceSHA'],
            'runID': binding['runID'], 'job': 'release', 'appTreeSHA256': origin['appTreeSHA256']},
        'currentNativeSignatureVerificationPerformed': False, 'freshTrustStoreOrRevocationClaimed': False})


def source_directory_identity(directory, root, expected=None):
    path, base = directory.absolute(), root.absolute()
    require(path.is_relative_to(base) and path != base and path.is_dir()
        and not path.is_symlink() and path.resolve().is_relative_to(base.resolve()), 'Source directory escaped its owned root')
    for parent in path.parents:
        if parent == base:
            break
        require(not parent.is_symlink(), 'Source directory has a linked ancestor')
    info = path.lstat()
    actual = (str(path.resolve()), info.st_dev, info.st_ino)
    require(expected is None or actual == expected, 'Source directory was replaced during acquisition')
    return actual


def acquire_source_pair(public, stage):
    import consume_bpy_distributable_source as source
    producer = public['producer']
    anchor = source_directory_identity(stage, stage.parent)
    run = source.api(f"/actions/runs/{producer['runID']}")
    artifacts = source.pages(f"/actions/runs/{producer['runID']}/artifacts", 'artifacts')
    jobs = source.pages(f"/actions/runs/{producer['runID']}/jobs?filter=all", 'jobs')
    artifact = source.require_original_producer(public, run, artifacts, jobs)
    source_directory_identity(stage, stage.parent, anchor)
    source.download(artifact, stage / 'original-bpy-source.zip')
    source_directory_identity(stage, stage.parent, anchor)
    source.extract_original(stage / 'original-bpy-source.zip', stage, public)
    verify_source_pair(stage, public)
    return {'run': run, 'job': next(job for job in jobs if job['id'] == producer['jobID']), 'artifact': artifact}


def commit_source_pair(stage, directory, public, root, anchor):
    from compiled_core_reuse import sync_directory
    source_directory_identity(directory, root, anchor)
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        require((info.st_dev, info.st_ino) == anchor[1:], 'Source directory descriptor changed')
        for name in (public['filename'], public['manifestFilename']):
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
            target = os.open(name, flags, 0o644, dir_fd=descriptor)
            with os.fdopen(target, 'wb') as sink, (stage / name).open('rb') as stream:
                shutil.copyfileobj(stream, sink, 1024 * 1024)
                sink.flush(); os.fsync(sink.fileno())
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    source_directory_identity(directory, root, anchor)
    verify_source_pair(directory, public)
    sync_directory(directory)


def prepare_resumed_source(root, directory):
    import consume_bpy_distributable_source as source
    import retained_packaging as packaging
    from compiled_core_reuse import persist, persist_bytes
    require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
        and os.environ.get('GITHUB_JOB') == 'release' and os.environ.get('NGV_COMPILED_APP_RELEASE') == 'true',
        'Compiled source handoff requires the owned native release job')
    binding = packaging.current_binding()
    from compiled_component_reuse import qualified, reuse_source
    if qualified(binding):
        return reuse_source(directory, binding)
    require(binding is not None and packaging.compiled_signed_product(binding), 'Unqualified compiled source handoff')
    workspace, temporary = Path(os.environ['GITHUB_WORKSPACE']).resolve(), Path(os.environ['RUNNER_TEMP']).resolve()
    require(root.resolve() == temporary / 'release-signed-binding' and root.is_dir() and not root.is_symlink()
        and directory.resolve() == workspace / '.build/bpy-source' and directory.is_dir() and not directory.is_symlink(),
        'Compiled source handoff escaped its owned roots')
    directory_anchor = source_directory_identity(directory, workspace)
    signed_raw = (root / 'binding.json').read_bytes()
    signed = json.loads(signed_raw)
    manifest = binding['signedInput']['manifest']
    require(signed.get('manifest') == manifest and signed.get('sourceSHA') == SIGNED_RESUME['sourceSHA']
        and signed.get('executionRunID') == binding['runID'] and signed.get('producerSourceSHA') == binding['producerSourceSHA']
        and signed.get('packagingInputSHA256') == os.environ.get('RETAINED_PACKAGING_INPUT_SHA256'),
        'Compiled source handoff lost its actual signed restore')
    old_path, immutable = directory / source.RECEIPT, root / 'payload/bpy-source-receipt.json'
    old = old_path.read_bytes()
    require(not old_path.is_symlink() and not immutable.is_symlink()
        and hashlib.sha256(old).hexdigest() == SIGNED_RESUME['sourceReceiptSHA256']
        and immutable.read_bytes() == old, 'Original source handoff receipt changed')
    original = json.loads(old)
    public = source.public_asset(json.loads(source.LOCK_PATH.read_text()))
    source.require_receipt(original, public, RETAINED_SOURCE)
    product = binding['productSourceSHA']
    require(targets.capture.git('rev-parse', product + ':Runtime') == targets.capture.git('rev-parse', 'HEAD:Runtime'),
        'Source handoff changed the product Runtime pins')
    marker, original_path = directory / 'bpy-source-reuse.json', directory / 'bpy-source-original-receipt.json'
    require(all(not path.exists() and not path.is_symlink() for path in (marker, original_path,
        directory / public['filename'], directory / public['manifestFilename'])), 'Source handoff was already consumed')
    with tempfile.TemporaryDirectory(prefix='current-bpy-source-') as staging:
        stage = Path(staging)
        origin_evidence = acquire_source_pair(public, stage)
        commit_source_pair(stage, directory, public, workspace, directory_anchor)
    receipt = dict(original, sourceSHA=product)
    source.require_receipt(receipt, public, product)
    require(root.resolve() == temporary / 'release-signed-binding' and not root.is_symlink()
        and directory.resolve() == workspace / '.build/bpy-source' and not directory.is_symlink()
        and (root / 'binding.json').read_bytes() == signed_raw
        and source.public_asset(json.loads(source.LOCK_PATH.read_text())) == public
        and old_path.is_file() and not old_path.is_symlink() and old_path.read_bytes() == old
        and immutable.is_file() and not immutable.is_symlink() and immutable.read_bytes() == old
        and not (workspace / '.build/NexGenVideo.app').is_symlink()
        and stat.S_IMODE((workspace / '.build/NexGenVideo.app').lstat().st_mode) == 0o755
        and not (workspace / '.build/NexGenVideo.zip').is_symlink()
        and checkpoint.tree_digest(workspace / '.build/NexGenVideo.app') == manifest['appTreeSHA256']
        and checksum(workspace / '.build/NexGenVideo.zip') == SIGNED_RESUME['appArchiveSHA256'],
        'Actual signed product or original receipt changed during source acquisition')
    source_directory_identity(directory, workspace, directory_anchor)
    verify_source_pair(directory, public)
    record = {'schema': 'compiled-bpy-source-receipt-reuse/v1', 'state': 'REUSED',
        'originalReceiptSHA256': SIGNED_RESUME['sourceReceiptSHA256'], 'originalConsumerSourceSHA': RETAINED_SOURCE,
        'productSourceSHA': product, 'harnessSourceSHA': binding['producerSourceSHA'], 'runID': binding['runID'],
        'attempt': 1, 'job': 'release', 'signedProduct': SIGNED_RESUME,
        'publicSourceAsset': public, 'originEvidence': origin_evidence,
        'originalValidation': original['validation'], 'semanticSourceValidationPerformed': False,
        'archiveSHA256': public['sha256'], 'manifestSHA256': public['manifestSHA256'],
        'acquiredAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    verify_source_origin(record['originEvidence'], public, record['acquiredAt'])
    persist_bytes(original_path, old)
    replacement = directory / 'bpy-source-current-receipt.json'
    persist(replacement, receipt)
    replacement.replace(old_path)
    record['derivedReceiptSHA256'] = checksum(old_path)
    persist(marker, record)
    print('BPY_SOURCE_VERIFICATION_REUSED ' + json.dumps(record, sort_keys=True, separators=(',', ':')), flush=True)


def verify_source_reuse(value, product, harness, run_id):
    from compiled_component_reuse import ORIGIN, source_record
    if product == ORIGIN['sourceSHA']:
        return source_record(value, product, harness, run_id)
    names = {'bpy-source-original-receipt.json', 'bpy-source-receipt.json', 'bpy-source-reuse.json'}
    require(type(value) is dict and set(value) == names and all(type(raw) is str for raw in value.values()),
        'Incomplete exact source-reuse proof')
    raw = {name: text.encode() for name, text in value.items()}
    original = json.loads(raw['bpy-source-original-receipt.json'], object_pairs_hook=unique_object)
    receipt = json.loads(raw['bpy-source-receipt.json'], object_pairs_hook=unique_object)
    reuse = json.loads(raw['bpy-source-reuse.json'], object_pairs_hook=unique_object)
    public = json.loads(Path('Runtime/bpy/runtime-lock.json').read_text())['distributionClosure']['publicSourceAsset']
    require(hashlib.sha256(raw['bpy-source-original-receipt.json']).hexdigest() == SIGNED_RESUME['sourceReceiptSHA256']
        and original.get('schema') == 'nexgenvideo/bpy-source-receipt/1' and original.get('sourceSHA') == RETAINED_SOURCE
        and original.get('publicSourceAsset') == public and receipt == dict(original, sourceSHA=product)
        and product == SIGNED_RESUME['sourceSHA'], 'Source qualification origin, consumer or pins differ')
    require(reuse.get('schema') == 'compiled-bpy-source-receipt-reuse/v1' and reuse.get('state') == 'REUSED'
        and reuse.get('signedProduct') == SIGNED_RESUME
        and reuse.get('originalReceiptSHA256') == SIGNED_RESUME['sourceReceiptSHA256']
        and reuse.get('originalConsumerSourceSHA') == RETAINED_SOURCE and reuse.get('productSourceSHA') == product
        and reuse.get('harnessSourceSHA') == harness and reuse.get('runID') == run_id
        and reuse.get('attempt') == 1 and reuse.get('job') == 'release' and reuse.get('publicSourceAsset') == public
        and reuse.get('originalValidation') == original.get('validation')
        and reuse.get('semanticSourceValidationPerformed') is False
        and reuse.get('derivedReceiptSHA256') == hashlib.sha256(raw['bpy-source-receipt.json']).hexdigest()
        and reuse.get('archiveSHA256') == original['validation']['archiveSHA256'] == public['sha256']
        and reuse.get('manifestSHA256') == original['validation']['manifestSHA256'] == public['manifestSHA256'],
        'Source reuse changed its original semantics or current provenance')
    verify_source_origin(reuse.get('originEvidence', {}), public, reuse['acquiredAt'])
    return receipt, reuse


def verify_source_origin(evidence, public, acquired_at):
    producer = public['producer']
    origin_run, job, artifact = (evidence.get(name, {}) for name in ('run', 'job', 'artifact'))
    require(origin_run.get('id') == producer['runID'] and origin_run.get('head_sha') == producer['sourceSHA']
        and origin_run.get('repository', {}).get('full_name') == REPOSITORY
        and origin_run.get('head_repository', {}).get('full_name') == REPOSITORY
        and origin_run.get('run_attempt') == producer['jobAttempt'] == 1
        and origin_run.get('status') == 'completed' and origin_run.get('event') == 'workflow_dispatch'
        and origin_run.get('path') == producer['workflowPath']
        and job.get('name') == ('source' if producer['workflowPath'].endswith('/bpy-source-closure.yml') else 'bpy-qualification / source')
        and job.get('id') == producer['jobID']
        and job.get('run_id') == producer['runID'] and job.get('head_sha') == producer['sourceSHA']
        and job.get('run_attempt') == 1 and job.get('status') == 'completed' and job.get('conclusion') == 'success'
        and 'ubuntu-24.04' in job.get('labels', []) and artifact.get('id') == producer['artifactID']
        and artifact.get('name') == producer['artifactName'] and artifact.get('digest') == producer['artifactDigest']
        and artifact.get('size_in_bytes') == producer['artifactSize'] and artifact.get('expired') is False
        and artifact.get('workflow_run', {}).get('id') == producer['runID']
        and artifact.get('workflow_run', {}).get('head_sha') == producer['sourceSHA'], 'Original source producer differs')
    instant = lambda text: datetime.datetime.fromisoformat(text.replace('Z', '+00:00'))
    require(instant(job['started_at']) <= instant(artifact['created_at']) <= instant(artifact['updated_at'])
        <= instant(job['completed_at']) <= instant(acquired_at) < instant(artifact['expires_at']),
        'Original source acquisition chronology differs')


def capture_source_reuse(directory, binding):
    names = ('bpy-source-original-receipt.json', 'bpy-source-receipt.json', 'bpy-source-reuse.json')
    require(directory.is_dir() and not directory.is_symlink()
        and all((directory / name).is_file() and not (directory / name).is_symlink() for name in names),
        'Source-reuse originals are absent or linked')
    value = {name: (directory / name).read_text() for name in names}
    receipt, reuse = verify_source_reuse(value, binding['productSourceSHA'], binding['producerSourceSHA'], binding['runID'])
    verify_source_pair(directory, receipt['publicSourceAsset'])
    return value


def verify_source_pair(directory, public):
    archive, manifest = (directory / public[name] for name in ('filename', 'manifestFilename'))
    require(directory.is_dir() and not directory.is_symlink()
        and archive.is_file() and not archive.is_symlink() and manifest.is_file() and not manifest.is_symlink()
        and archive.stat().st_size == public['size'] and checksum(archive) == public['sha256']
        and checksum(manifest) == public['manifestSHA256'], 'Materialized qualified source pair changed')


def source_receiver_context(context, parent, *, packaging=None):
    contexts = {'bpy-runtime': ('runtime', 'darwin'), 'workspace-source-preflight': ('runtime', 'linux'),
        'settings-restore': ('acceptance', 'darwin')}
    require(context in contexts and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
        and (os.environ.get('GITHUB_JOB'), sys.platform) == contexts[context], 'Unknown source receiver context')
    harness = os.environ.get('GITHUB_SHA')
    if harness != parent['producerSourceSHA']:
        import retained_packaging as retained
        require(packaging is not None and retained.component_consumer_repair_paths(parent)
            and packaging.get('rawProofSHA256') == retained.digest(retained.encoded(parent)),
            'Source receiver continuation has no exact qualified canonical parent')
        require(retained.consumer_harness(packaging, parent['productSourceSHA'], set()) == harness,
            'Source receiver continuation changed its current harness')
    return harness


def consume_packaging_source(directory, product, receipt_path, packaging, *, context, evidence):
    import consume_bpy_distributable_source as source
    import retained_packaging as retained
    from compiled_core_reuse import persist, persist_bytes
    if packaging is None:
        return None
    parent = retained.consumer_record(packaging, product)
    from compiled_component_reuse import ORIGIN
    if product not in {SIGNED_RESUME['sourceSHA'], ORIGIN['sourceSHA']}:
        return None
    require(retained.retained_compiled_product(parent) and parent.get('stage') == 'complete',
        'Current compiled source receiver has no qualified canonical parent')
    source_receiver_context(context, parent, packaging=packaging)
    temporary = Path(os.environ['RUNNER_TEMP'])
    require(directory.resolve().is_relative_to(temporary.resolve()) and evidence.resolve().is_relative_to(temporary.resolve())
        and not directory.is_symlink() and not evidence.is_symlink(), 'Source receiver escaped its owned temporary root')
    value = parent['final']['bpySourceReuse']
    receipt, original_reuse = verify_source_reuse(value, product, parent['producerSourceSHA'], parent['runID'])
    expected = value['bpy-source-receipt.json'].encode()
    if receipt_path.parent.resolve() != temporary.resolve():
        source_directory_identity(receipt_path.parent, temporary)
    else:
        require(not receipt_path.parent.is_symlink(), 'Runtime source receipt parent is linked')
    require(receipt_path.is_file() and not receipt_path.is_symlink() and receipt_path.read_bytes() == expected
        and hashlib.sha256(expected).hexdigest() == parent['final']['bpySourceReceiptSHA256'],
        'Runtime source receipt differs from its exact final packaging parent')
    public = source.public_asset(json.loads(source.LOCK_PATH.read_text()))
    source.require_receipt(receipt, public, product)
    directory.mkdir(parents=True, exist_ok=True)
    require(directory.is_dir() and not directory.is_symlink() and directory.resolve().is_relative_to(temporary.resolve())
        and all(not (directory / name).exists() and not (directory / name).is_symlink()
            for name in (public['filename'], public['manifestFilename'], source.RECEIPT)), 'Source receiver destination is occupied')
    directory_anchor = source_directory_identity(directory, temporary)
    with tempfile.TemporaryDirectory(prefix='current-bpy-consumer-') as staging:
        stage = Path(staging)
        origin_evidence = acquire_source_pair(public, stage)
        commit_source_pair(stage, directory, public, temporary, directory_anchor)
    require(receipt_path.is_file() and not receipt_path.is_symlink() and receipt_path.read_bytes() == expected
        and source.public_asset(json.loads(source.LOCK_PATH.read_text())) == public
        and directory.resolve().is_relative_to(temporary.resolve()) and not directory.is_symlink(),
        'Source receiver input or physical output changed during acquisition')
    source_directory_identity(directory, temporary, directory_anchor)
    persist_bytes(directory / source.RECEIPT, expected)
    record = {'schema': 'compiled-bpy-source-consumer-reuse/v1', 'state': 'REUSED', 'context': context,
        'productSourceSHA': product, 'harnessSourceSHA': os.environ['GITHUB_SHA'],
        'executionRunID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1, 'job': os.environ['GITHUB_JOB'],
        'parent': packaging, 'parentReceiptSHA256': hashlib.sha256(expected).hexdigest(),
        'originalReuseSHA256': hashlib.sha256(value['bpy-source-reuse.json'].encode()).hexdigest(),
        'publicSourceAsset': public, 'materializationOrigin': {'kind': 'actions', 'producer': public['producer']},
        'originEvidence': origin_evidence, 'acquiredAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'originalValidation': receipt['validation'], 'semanticSourceValidationPerformed': False}
    verify_source_origin(record['originEvidence'], public, record['acquiredAt'])
    evidence.parent.mkdir(parents=True, exist_ok=True)
    require(evidence.parent.resolve().is_relative_to(temporary.resolve()) and not evidence.parent.is_symlink(),
        'Source receiver proof parent escaped its owned root')
    source_directory_identity(evidence.parent, temporary)
    verify_source_pair(directory, public)
    persist(evidence, record)
    print('BPY_SOURCE_CONSUMER_REUSED ' + json.dumps(record, sort_keys=True, separators=(',', ':')), flush=True)
    return {'receipt': receipt, 'reuse': record, 'evidenceSHA256': checksum(evidence)}


def verify_received_source(directory, product, packaging, evidence, *, context):
    import retained_packaging as retained
    if packaging is None:
        return False
    parent = retained.consumer_record(packaging, product)
    from compiled_component_reuse import ORIGIN
    if product not in {SIGNED_RESUME['sourceSHA'], ORIGIN['sourceSHA']}:
        return False
    require(retained.retained_compiled_product(parent) and parent.get('stage') == 'complete'
        and evidence.is_file() and not evidence.is_symlink(), 'Current source receiver proof is missing')
    harness = source_receiver_context(context, parent, packaging=packaging)
    temporary = Path(os.environ['RUNNER_TEMP'])
    source_directory_identity(directory, temporary)
    source_directory_identity(evidence.parent, temporary)
    require((directory / 'bpy-source-receipt.json').is_file() and not (directory / 'bpy-source-receipt.json').is_symlink(),
        'Current source receiver receipt is absent or linked')
    receipt, original = verify_source_reuse(parent['final']['bpySourceReuse'], product, parent['producerSourceSHA'], parent['runID'])
    record = json.loads(evidence.read_bytes(), object_pairs_hook=unique_object)
    require(record.get('schema') == 'compiled-bpy-source-consumer-reuse/v1' and record.get('state') == 'REUSED'
        and record.get('context') == context and record.get('productSourceSHA') == product
        and record.get('harnessSourceSHA') == os.environ['GITHUB_SHA'] == harness
        and record.get('executionRunID') == int(os.environ['GITHUB_RUN_ID']) and record.get('attempt') == 1
        and record.get('job') == os.environ['GITHUB_JOB'] and record.get('parent') == packaging
        and record.get('parentReceiptSHA256') == parent['final']['bpySourceReceiptSHA256']
        and record.get('originalReuseSHA256') == hashlib.sha256(parent['final']['bpySourceReuse']['bpy-source-reuse.json'].encode()).hexdigest()
        and record.get('originalValidation') == receipt['validation'] and record.get('publicSourceAsset') == receipt['publicSourceAsset']
        and record.get('materializationOrigin') == {'kind': 'actions', 'producer': receipt['publicSourceAsset']['producer']}
        and record.get('semanticSourceValidationPerformed') is False
        and (directory / 'bpy-source-receipt.json').read_bytes() == parent['final']['bpySourceReuse']['bpy-source-receipt.json'].encode(),
        'Current source receiver lost its exact canonical parent or honest reused scope')
    verify_source_origin(record.get('originEvidence', {}), receipt['publicSourceAsset'], record['acquiredAt'])
    verify_source_pair(directory, receipt['publicSourceAsset'])
    return True


def retained_runtime_destination(directory):
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY
        and sys.platform == 'darwin' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Unknown retained runtime execution')
    temporary, workspace = Path(os.environ['RUNNER_TEMP']), Path(os.environ['GITHUB_WORKSPACE'])
    job = os.environ.get('GITHUB_JOB')
    expected = {'analyze': workspace / '.build', 'replay': temporary / 'chat-replay',
        'acceptance': temporary / 'settings-runtime'}
    require(job in expected and directory.resolve() == expected[job].resolve()
        and not directory.is_symlink() and not expected[job].is_symlink(),
        'Retained runtime destination differs from its actual caller')
    return workspace if job == 'analyze' else temporary


def verify_retained_runtime_pack(directory, product, receipt, proof, identity):
    import retained_packaging as packaging
    from compiled_core_reuse import persist
    from compiled_component_reuse import ORIGIN
    import app_cohort_v2
    if app_cohort_v2.has_manifest(product) and proof.get('packaging') is None:
        return verify_component_runtime_pack(directory, product, receipt, proof, identity)
    if product == ORIGIN['sourceSHA'] and proof.get('packaging') is None:
        return verify_component_runtime_pack(directory, product, receipt, proof, identity)
    if product not in {SIGNED_RESUME['sourceSHA'], ORIGIN['sourceSHA']}:
        if identity.get('CFBundleVersion') == COMPONENT_BUILD:
            return verify_component_runtime_pack(directory, product, receipt, proof, identity)
        return None
    selected = proof.get('packaging')
    require(selected is not None, 'Current runtime pack has no canonical packaging parent')
    parent = packaging.consumer_record(selected, product, proof.get('producerRunID'))
    require((packaging.retained_compiled_product(parent) or packaging.cohort_signed_product(parent)) and parent.get('stage') == 'complete'
        and parent['final']['app'] == identity and parent['final']['runtimeArchiveSHA256'] == receipt['archiveSHA256']
        and receipt['appTreeSHA256'] == identity['treeSHA256']
        and parent['final']['packTreeSHA256'] == PACK_TREE and parent['final']['packArchiveSHA256'] == PACK_SHA
        and proof.get('harnessSourceSHA') == os.environ.get('GITHUB_SHA')
        and proof.get('executionRunID') == os.environ.get('GITHUB_RUN_ID')
        and proof.get('executionAttempt') == os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
        and os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY
        and sys.platform == 'darwin' and os.environ.get('GITHUB_JOB') in ('replay', 'analyze', 'acceptance'),
        'Retained runtime pack lost its exact current product, archive or execution')
    base = retained_runtime_destination(directory)
    anchor = source_directory_identity(directory, base)
    require(directory.is_dir() and not directory.is_symlink(),
        'Retained runtime pack escaped its physical owned root')
    marker = directory / 'pack-verification.reused.json'
    require(not marker.exists() and not marker.is_symlink(), 'Retained runtime pack admission was consumed')
    run, job, artifact = pack_verification_origin()
    bundle = directory / 'plugins/musicvideo.ngvpack'
    source_directory_identity(directory, base, anchor)
    require(not (directory / 'plugins').is_symlink()
        and not directory.is_symlink() and bundle.is_dir() and not bundle.is_symlink()
        and stat.S_IMODE(bundle.lstat().st_mode) == 0o755 and canonical_bundle_tree(bundle) == PACK_TREE,
        'Actual retained runtime pack differs from its qualified original')
    record = {'schema': 'retained-runtime-pack-copy-reuse/v1', 'state': 'REUSED',
        'context': 'retained-release-runtime', 'original': original_pack_proof(), 'parent': selected,
        'productSourceSHA': product, 'producerSourceSHA': parent['producerSourceSHA'],
        'producerRunID': parent['runID'], 'runtimeArtifactID': proof['runtimeArtifactID'],
        'runtimeArtifactSHA256': proof['runtimeArtifactSHA256'], 'runtimeArchiveSHA256': receipt['archiveSHA256'],
        'harnessSourceSHA': os.environ['GITHUB_SHA'], 'executionRunID': int(os.environ['GITHUB_RUN_ID']),
        'attempt': 1, 'job': os.environ['GITHUB_JOB'], 'packTreeSHA256': PACK_TREE, 'rootMode': 0o755,
        'origin': {'runID': run['id'], 'jobID': job['id'], 'artifactID': artifact['id'], 'artifactDigest': artifact['digest']},
        'currentNativeCodesignOrStaplerPerformed': False, 'freshTrustStoreOrRevocationClaimed': False,
        'currentPackNotarizationPerformed': False, 'newAppPackLoadQualified': False}
    persist(marker, record)
    print('RUNTIME_PACK_VERIFICATION_REUSED ' + json.dumps(record, sort_keys=True, separators=(',', ':')), flush=True)
    return record


def verify_component_runtime_pack(directory, product, receipt, proof, identity):
    from compiled_core_reuse import persist
    import app_cohort_v2
    value = app_cohort_v2.manifest(product) if app_cohort_v2.has_manifest(product) else None
    expected_build, expected_version = (value['build'], value['version']) if value else (COMPONENT_BUILD, '1.8.0')
    sealed = json.dumps([proof, receipt, identity], sort_keys=True, allow_nan=False)
    require(proof.get('schema') == 'nexgenvideo/retained-release-runtime/1'
        and proof.get('productSourceSHA') == product and proof.get('packaging') is None
        and proof.get('harnessSourceSHA') == os.environ.get('GITHUB_SHA')
        and proof.get('executionRunID') == os.environ.get('GITHUB_RUN_ID')
        and proof.get('executionAttempt') == os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
        and identity.get('NGVSourceCommit') == product and identity.get('CFBundleVersion') == expected_build
        and identity.get('CFBundleShortVersionString') == expected_version
        and receipt.get('schema') == 'nexgenvideo/workspace-ui-input/1' and receipt.get('sourceSHA') == product
        and receipt.get('appTreeSHA256') == identity.get('treeSHA256')
        and all(re.fullmatch('[a-f0-9]{64}', proof.get(name, '')) for name in ('runtimeArtifactSHA256',))
        and sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY,
        'Corrected runtime pack lost its exact normal product receipt or execution')
    base = retained_runtime_destination(directory)
    anchor = source_directory_identity(directory, base)
    producer = api('actions/runs/' + str(proof['producerRunID']))
    job = api('actions/jobs/' + str(proof['producerJobID']))
    artifact = api('actions/artifacts/' + str(proof['runtimeArtifactID']))
    require(producer.get('id') == proof['producerRunID'] and producer.get('head_sha') == product
        and producer.get('repository', {}).get('full_name') == REPOSITORY
        and producer.get('actor', {}).get('login') == 'iret77'
        and producer.get('run_attempt') == proof.get('producerAttempt') == 1
        and producer.get('path') == '.github/workflows/release.yml' and producer.get('workflow_id') == 303346287
        and producer.get('event') == 'workflow_dispatch' and producer.get('status') == 'completed'
        and job.get('id') == proof['producerJobID'] and job.get('name') == 'release'
        and job.get('run_id') == producer['id'] and job.get('head_sha') == product and job.get('run_attempt') == 1
        and job.get('labels') == ['macrunner'] and job.get('conclusion') == 'success',
        'Corrected runtime pack differs from its actual release producer')
    verify_artifact(artifact, producer, job, proof['runtimeArtifactID'], proof['runtimeArtifactSHA256'], 'workspace-ui-app')
    bundle, marker = directory / 'plugins/musicvideo.ngvpack', directory / 'pack-verification.reused.json'
    require(not marker.exists() and not marker.is_symlink(), 'Corrected runtime pack admission was consumed')
    original_run, original_job, original_artifact = pack_verification_origin()
    require(json.dumps([proof, receipt, identity], sort_keys=True, allow_nan=False) == sealed,
        'Corrected runtime proof changed during origin verification')
    source_directory_identity(directory, base, anchor)
    require(not (directory / 'plugins').is_symlink() and bundle.is_dir() and not bundle.is_symlink()
        and stat.S_IMODE(bundle.lstat().st_mode) == 0o755 and canonical_bundle_tree(bundle) == PACK_TREE,
        'Corrected runtime pack bytes differ from the qualified original')
    record = {'schema': 'component-runtime-pack-copy-reuse/v1', 'state': 'REUSED',
        'context': 'retained-release-runtime', 'original': original_pack_proof(),
        'productSourceSHA': product, 'producerSourceSHA': product, 'producerRunID': proof['producerRunID'],
        'runtimeArtifactID': proof['runtimeArtifactID'], 'runtimeArtifactSHA256': proof['runtimeArtifactSHA256'],
        'runtimeArchiveSHA256': receipt['archiveSHA256'], 'app': identity,
        'harnessSourceSHA': os.environ['GITHUB_SHA'], 'executionRunID': int(os.environ['GITHUB_RUN_ID']),
        'attempt': 1, 'job': os.environ['GITHUB_JOB'], 'packTreeSHA256': PACK_TREE, 'rootMode': 0o755,
        'origin': {'runID': original_run['id'], 'jobID': original_job['id'], 'artifactID': original_artifact['id'],
            'artifactDigest': original_artifact['digest']},
        'currentNativeCodesignOrStaplerPerformed': False, 'currentPackNotarizationPerformed': False,
        'freshTrustStoreOrRevocationClaimed': False, 'newAppPackLoadQualified': False}
    persist(marker, record)
    return record


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
    import app_cohort_v2
    if app_cohort_v2.has_manifest(selected['sourceSHA']):
        app_cohort_v2.compatible_source(selected['sourceSHA'], role)
    else:
        require(source_objects(selected['sourceSHA']) == source_objects(APP_SOURCE) == source_objects('HEAD'),
            'Compiled App producer and current native sources differ')
    return {'selected': selected, 'run': run, 'job': native[0], 'sourceJob': sources[0], 'artifact': artifact}


def verified_zip(path, limit, *, qualified_sha=None):
    archive = zipfile.ZipFile(path)
    entries = archive.infolist()
    require(entries and len(entries) <= 200_000 and sum(item.file_size for item in entries) <= limit
        and len({item.filename.casefold() for item in entries}) == len(entries),
        'Compiled App archive inventory, bounds or CRC differ')
    if qualified_sha is None:
        require(archive.testzip() is None, 'Compiled App archive CRC differs')
    else:
        require(re.fullmatch('[a-f0-9]{64}', qualified_sha) and checksum(path) == qualified_sha,
            'Qualified original archive identity changed')
    for item in entries:
        name = item.filename.rstrip('/')
        path = PurePosixPath(name)
        mode = stat.S_IFMT(item.external_attr >> 16)
        require(name and str(path) == name and not path.is_absolute() and '..' not in path.parts
            and '\\' not in name and '\0' not in name
            and mode in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), 'Unsafe compiled App archive member')
    return archive


def verify_product(receipt, selected, phase, prepared):
    dynamic = bool(prepared.get('cohortV2'))
    if dynamic:
        import app_cohort_v2
        app_cohort_v2.compatible_product(receipt, prepared, phase)
    require(receipt.get('schema') == 'native-app-target-product/v1' and receipt.get('phase') == phase
        and receipt.get('sourceSHA') == selected['sourceSHA'] and receipt.get('runID') == selected['runID']
        and receipt.get('attempt') == 1 and (dynamic or (receipt.get('appSourceSHA') == APP_SOURCE
        and receipt.get('nativeSourceObjects') == source_objects(APP_SOURCE)))
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
    with verified_zip(root / 'metadata-original.zip', 1024**3, qualified_sha=selected['metadata']['artifactSHA256']) as archive:
        binding = json.loads(archive_bytes(archive, 'binding.json', 32 * 1024**2))
        prepared = json.loads(archive_bytes(archive, 'prepared.json', 32 * 1024**2))
    dynamic = bool(prepared.get('cohortV2'))
    if dynamic:
        import app_cohort_v2
        value = app_cohort_v2.verify_context(prepared['cohortV2'])
        require(source_objects('HEAD') == value['nativeSourceObjects'], 'Release App inputs differ from the compiler candidate')
    app_source = value['appSourceSHA'] if dynamic else APP_SOURCE
    require(binding.get('schema') == 'native-app-target-source-binding/v1'
        and prepared.get('schema') == 'native-app-target-prepared/v1'
        and prepared.get('sourceSHA') == binding.get('sourceSHA') == selected['metadata']['sourceSHA']
        and prepared.get('appSourceSHA') == binding.get('appSourceSHA') == app_source
        and prepared.get('nativeSourceObjects') == binding.get('nativeSourceObjects') == source_objects(app_source)
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
        targets.logged(root, label, argv, timeout=timeout), reuse_crc=True)
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
        with verified_zip(folder / 'original.zip', 12 * 1024**3, qualified_sha=selected[phase]['artifactSHA256']) as outer:
            require(outer.namelist() == [phase + '-products.zip'], 'Unexpected compiled App outer archive')
            with outer.open(phase + '-products.zip') as source, (folder / 'product.zip').open('xb') as destination:
                shutil.copyfileobj(source, destination, 1024 * 1024)
        inner_sha = checksum(folder / 'product.zip')
        with verified_zip(folder / 'product.zip', 12 * 1024**3, qualified_sha=inner_sha) as archive:
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
        'runID': int(os.environ['GITHUB_RUN_ID']), 'appSourceSHA': app_source, 'nativeSourceObjects': source_objects(app_source),
        'selected': selected, 'products': products, 'metadataProducer': metadata, 'prepared': prepared,
        'runtime': str(runtime), 'runtimeManifestSHA256': retained.MANIFEST_SHA,
        'runtimeManifestOrigin': {'artifactID': bank['id'], 'artifactSHA256': bank['digest'].removeprefix('sha256:'),
            'member': 'runtime-manifest.json', 'bytes': len(raw_manifest)}})


def run_tests(root):
    import compiled_core_reuse
    bound = json.loads((root / 'bound.json').read_text())
    dynamic = bool(bound.get('prepared', {}).get('cohortV2'))
    if not dynamic and APP_SOURCE == compiled_core_reuse.origin()['appSourceSHA']:
        native_guard(root)
        bound = json.loads((root / 'bound.json').read_text())
        return compiled_core_reuse.acquire(root, bound, criteria(), sys.modules[__name__])
    from run_macos_tests import app_environment, framework_output, host_receipt, prepare_post_mortem, run_process
    native_guard(root)
    bound = json.loads((root / 'bound.json').read_text())
    require(bound['sourceSHA'] == os.environ['GITHUB_SHA'] and bound['runID'] == int(os.environ['GITHUB_RUN_ID'])
        and bound['nativeSourceObjects'] == source_objects('HEAD'), 'Compiled App test source changed')
    if dynamic:
        import app_cohort_v2
        expected = app_cohort_v2.criteria()
    else:
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
    if dynamic:
        from app_release_v2 import run_xctest
        fresh_xctest = run_xctest(root / 'xctest', bound, image, expected['xctest']['exactIndividualPassedIDs'])
    else:
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
        and events['functionExecutions'] == len(expected['modules']['app']['exactEndedFunctionIDs']),
        'Original eight App cases or full App execution is missing')
    proofs = {'app-swift-testing': {'pid': pid, 'parentPID': os.getpid(), 'consoleSHA256': checksum(folder / 'console.log'),
        'events': events, 'eventSHA256': checksum(folder / 'events.jsonl'),
        'hostReceipt': host_receipt(folder / 'host-receipt.json', events, pid=pid, bundle=image, host=host, source_sha=os.environ['GITHUB_SHA']),
        'hostReceiptSHA256': checksum(folder / 'host-receipt.json'), 'framework': framework_output(folder / 'console.log', 1, 0)}}
    write(folder / 'verified.json', proofs['app-swift-testing'])
    proofs['xctest'] = fresh_xctest
    receipt = {'schema': 'release-native-compiled-app/v5' if dynamic else 'release-native-compiled-app/v3',
        'sourceSHA': bound['sourceSHA'], 'runID': bound['runID'],
        'attempt': 1, 'appSourceSHA': bound['appSourceSHA'], 'nativeSourceObjects': bound['nativeSourceObjects'],
        'compilerSHA256': COMPILER_SHA, 'selected': bound['selected'],
        'products': {phase: {'receipt': bound['products'][phase]['receipt'],
            'originalArchiveSHA256': bound['products'][phase]['originalArchiveSHA256']} for phase in PHASES},
        'hostSHA256': retained.HOST_SHA, 'criteriaSHA256': (app_cohort_v2.manifest()['criteria']['sha256'] if dynamic else checksum(CRITERIA)), 'passed': True,
        'counts': {'freshApp': len(expected['modules']['app']['exactEndedFunctionIDs']), 'freshXCTest': 48,
            'retainedEngine': 896, 'executions': expected['expectedActualExecutions'],
            'appSkips': 8, 'engineSkips': 14},
        'freshProofs': proofs, 'retainedEngine': retained_engine}
    if dynamic:
        receipt['cohortV2'] = bound['prepared']['cohortV2']
    verify_receipt(receipt, bound['sourceSHA'], bound['runID'])
    write(root / 'receipt.json', receipt)


def engine_carrier_origin():
    return {'sourceSHA': '927f3b50c63a69141abca3daf590e7a9beb0bcf1',
     'runID': 42966762592,
     'jobID': 130345792839,
     'artifactID': 13832390642,
     'artifactSHA256': '7e5dde96d7ba9aa84e0d70607b7863bae9c5ac761d29626125d80a8b10d10076',
     'artifactBytes': 2101362024,
     'receiptSHA256': '0867554066568f54a263b968f9c97ffc8235ddb884fa5511f9f65ecc2b19f6d5',
     'receiptBytes': 7131033,
     'dependencies': [{'id': 13832390642,
                       'name': 'release-compiled-app-evidence-42966762592-a1',
                       'sha256': '7e5dde96d7ba9aa84e0d70607b7863bae9c5ac761d29626125d80a8b10d10076',
                       'bytes': 2101362024,
                       'runID': 42966762592,
                       'sourceSHA': '927f3b50c63a69141abca3daf590e7a9beb0bcf1'},
                      {'id': 13769367412,
                       'name': 'release-signed-input-a1375966dbe6d2dd7b918c726f09ac5d1f4f16fb-proof',
                       'sha256': '6a21867ad5474418ef37590da4d3f35b1b409089928796b4a4aeec42c6624ee0',
                       'bytes': 821936,
                       'runID': 42822598973,
                       'sourceSHA': 'a1375966dbe6d2dd7b918c726f09ac5d1f4f16fb'},
                      {'id': 13769391943,
                       'name': 'release-signed-input-a1375966dbe6d2dd7b918c726f09ac5d1f4f16fb',
                       'sha256': '4dd7c9afd04a08039ac8ff0c1d7381d0bd779cbd3b5d405d978e502cf446a583',
                       'bytes': 1696850395,
                       'runID': 42822598973,
                       'sourceSHA': 'a1375966dbe6d2dd7b918c726f09ac5d1f4f16fb'},
                      {'id': 13635913556,
                       'name': 'NexGenVideo-1.8.0-artifact-only',
                       'sha256': '5a3c9eef5134b2ae7479c7af8a465c655fceb3857fbf403a090fe27871e7fcb0',
                       'bytes': 3627462402,
                       'runID': 42522113496,
                       'sourceSHA': 'ebe2d8baf4d953d36fda2abc3835400f052da506'},
                      {'id': 13626102447,
                       'name': 'release-test-runtime-products-42500881402-a1',
                       'sha256': '9d9a40671b071e86cbc5daff9ca11add8d50885a1699d7552e90499c6f96f8af',
                       'bytes': 503903061,
                       'runID': 42500881402,
                       'sourceSHA': '849cdd32d702e0b86219ee0a44f10360f68cbfe6'},
                      {'id': 12209205072,
                       'name': 'managed-bpy-source-26ad91ad98eb8d38f4e92d8f5670ff7bcc639552',
                       'sha256': '8fd90c6cdcd274d4c28d8b1c389eaa3f067a0b8983e21c0b0ee11aee7e516a81',
                       'bytes': 1941299819,
                       'runID': 39295082436,
                       'sourceSHA': '26ad91ad98eb8d38f4e92d8f5670ff7bcc639552'}]}


def retained_engine_carrier(root=None):
    from datetime import datetime, timezone
    origin = engine_carrier_origin()
    dependencies = {}
    for selected in origin['dependencies']:
        item = api('actions/artifacts/' + str(selected['id']))
        require(item.get('id') == selected['id'] and item.get('name') == selected['name']
            and item.get('digest') == 'sha256:' + selected['sha256'] and item.get('size_in_bytes') == selected['bytes']
            and item.get('expired') is False and item.get('workflow_run', {}).get('id') == selected['runID']
            and item['workflow_run'].get('head_sha') == selected['sourceSHA']
            and item['workflow_run'].get('repository_id') == item['workflow_run'].get('head_repository_id') == 1280482148
            and datetime.fromisoformat(item['expires_at'].replace('Z', '+00:00')) > datetime.now(timezone.utc),
            'A transitive compiled App acquisition input is unavailable or changed')
        dependencies[str(selected['id'])] = item
    require(len(dependencies) == len(origin['dependencies']), 'Duplicate compiled App acquisition dependency')
    run = api('actions/runs/' + str(origin['runID']))
    jobs = api(f"actions/runs/{origin['runID']}/attempts/1/jobs?per_page=100")
    require(run.get('repository', {}).get('full_name') == run.get('head_repository', {}).get('full_name') == REPOSITORY
        and run.get('head_sha') == origin['sourceSHA']
        and run.get('run_attempt') == 1 and run.get('status') == 'completed' and run.get('event') == 'workflow_dispatch'
        and run.get('workflow_id') == 303346287 and run.get('path') == '.github/workflows/release.yml'
        and run.get('actor', {}).get('login') == 'iret77' and jobs.get('total_count') == len(jobs.get('jobs', [])),
        'Engine evidence carrier producer differs')
    matched = [job for job in jobs['jobs'] if job.get('id') == origin['jobID'] and job.get('name') == 'release-build']
    require(len(matched) == 1, 'Engine evidence carrier job is missing or ambiguous')
    job = matched[0]
    require(job.get('run_id') == origin['runID'] and job.get('head_sha') == origin['sourceSHA']
        and job.get('run_attempt') == 1 and job.get('status') == 'completed' and job.get('conclusion') == 'success'
        and job.get('labels') == ['macrunner'], 'Engine evidence carrier job did not complete')
    artifact = dependencies[str(origin['artifactID'])]
    verify_artifact(artifact, run, job, origin['artifactID'], origin['artifactSHA256'],
        'release-compiled-app-evidence-' + str(origin['runID']) + '-a1')
    require(artifact['size_in_bytes'] == origin['artifactBytes'], 'Engine evidence carrier size differs')
    acquired = datetime.now(timezone.utc).isoformat()
    result = {'schema': 'retained-engine-carrier-acquisition/1', 'run': run, 'job': job,
        'artifact': artifact, 'dependencies': dependencies, 'acquiredAt': acquired}
    if root is None:
        return result
    target = root / 'retained-engine'
    target.mkdir()
    transit = root / 'engine-carrier-download'
    transit.mkdir()
    archive_path = transit / 'original.zip'
    download(artifact, archive_path)
    with verified_zip(archive_path, 8 * 1024**3, qualified_sha=origin['artifactSHA256']) as archive:
        records = {}
        for name, size, digest in [('receipt.json', origin['receiptBytes'], origin['receiptSHA256']),
                ('retained-engine/original.zip', 1717370, engine.DIGEST),
                ('retained-engine/original-job.log', 3862332, engine.LOG_DIGEST)]:
            require(stat.S_IFMT(archive.getinfo(name).external_attr >> 16) in (0, stat.S_IFREG),
                'Engine carrier selected member is not a regular file')
            raw = archive_bytes(archive, name)
            require(len(raw) == size and hashlib.sha256(raw).hexdigest() == digest,
                'Engine carrier selected original member differs')
            records[name] = raw
    receipt = json.loads(records.pop('receipt.json'))
    require(receipt.get('sourceSHA') == origin['sourceSHA'] and receipt.get('runID') == origin['runID']
        and receipt.get('attempt') == 1 and receipt.get('passed') is True
        and receipt.get('counts', {}).get('retainedEngine') == 896 and receipt['counts'].get('engineSkips') == 14,
        'Engine carrier receipt differs')
    historical = receipt['retainedEngine']
    engine.verify_original(historical['run'], {'total_count': 1, 'jobs': [historical['job']]})
    old = historical['artifact']
    when = lambda value: datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(old.get('id') == engine.ARTIFACT and old.get('name') == 'release-test-evidence'
        and old.get('digest') == 'sha256:' + engine.DIGEST and old.get('size_in_bytes') == 1717370
        and old.get('expired') is False and old.get('workflow_run', {}).get('id') == engine.RUN
        and old['workflow_run'].get('head_sha') == engine.SOURCE
        and when(historical['job']['started_at']) <= when(old['created_at']) <= when(old['updated_at'])
        <= when(historical['job']['completed_at']) <= when(artifact['created_at']) < when(old['expires_at'])
        and historical.get('proof', {}).get('eventsSHA256') == engine.EVENT_DIGEST
        and historical['proof'].get('logSHA256') == engine.CONSOLE_DIGEST,
        'Historical Engine acquisition or exact execution identity differs')
    for name, raw in records.items():
        (target / Path(name).name).write_bytes(raw)
    result.update(original=historical, receiptSHA256=origin['receiptSHA256'],
        bytesAcquiredAt=datetime.now(timezone.utc).isoformat(),
        memberSHA256={'receipt.json': origin['receiptSHA256'],
            'retained-engine/original.zip': engine.DIGEST, 'retained-engine/original-job.log': engine.LOG_DIGEST})
    write(target / 'carrier-acquisition.json', result)
    return result


def retained_engine_evidence(root, expected):
    engine.verify_engine_source_objects(os.environ['GITHUB_SHA'])
    original = api('actions/runs/' + str(engine.RUN))
    jobs = api(f'actions/runs/{engine.RUN}/attempts/1/jobs?per_page=100')
    job = engine.verify_original(original, jobs)
    carrier = retained_engine_carrier(root)
    historical = carrier['original']
    require(historical['run']['id'] == original['id'] and historical['run']['head_sha'] == original['head_sha']
        and historical['job']['id'] == job['id'], 'Carried and live original Engine producer differ')
    artifact = historical['artifact']
    retained_engine = root / 'retained-engine'
    retained_proof = engine.verify_archive(retained_engine / 'original.zip', retained_engine)
    verify_events(retained_engine / 'engine-swift-testing/events.jsonl', expected, 'NexGenEngineTests')
    raw = (retained_engine / 'original-job.log').read_bytes()
    environment = engine_environment(raw)
    write(retained_engine / 'current-environment.json', environment)
    return {'run': original, 'job': job, 'artifact': artifact, 'proof': retained_proof, 'environment': environment,
        'acquisition': {key: value for key, value in carrier.items() if key != 'original'}}


def engine_environment(raw):
    original = engine.toolchain(raw)
    current = {'swift': engine.command('swift', '--version'), 'xcode': engine.command('xcodebuild', '-version'),
        'python': platform.python_version(), 'osVersion': engine.command('sw_vers', '-productVersion'),
        'osBuild': engine.command('sw_vers', '-buildVersion')}
    require(platform.machine() == 'arm64' and current == original, 'Current Release Engine runtime or toolchain differs')
    return {'original': original, 'current': current, 'architecture': 'arm64'}


def verify_receipt(receipt, source, run_id):
    dynamic = receipt.get('schema') == 'release-native-compiled-app/v5'
    if dynamic:
        import app_cohort_v2
        value = app_cohort_v2.verify_context(receipt.get('cohortV2'))
        expected = app_cohort_v2.criteria(receipt['cohortV2']['harnessSourceSHA'])
    app_source = value['appSourceSHA'] if dynamic else APP_SOURCE
    source_inputs = value['nativeSourceObjects'] if dynamic else source_objects(APP_SOURCE)
    criterion_sha = value['criteria']['sha256'] if dynamic else checksum(CRITERIA)
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
    fresh_host = dynamic or receipt.get('schema') == 'release-native-compiled-app/v3'
    continued = receipt.get('schema') == 'release-native-compiled-app/v2'
    require(receipt.get('schema') in ('release-native-compiled-app/v1', 'release-native-compiled-app/v2', 'release-native-compiled-app/v3', 'release-native-compiled-app/v5') and receipt.get('sourceSHA') == source
        and receipt.get('runID') == run_id and receipt.get('attempt') == 1 and receipt.get('appSourceSHA') == app_source
        and receipt.get('nativeSourceObjects') == source_objects(source) == source_inputs
        and receipt.get('compilerSHA256') == COMPILER_SHA and receipt.get('hostSHA256') == retained.HOST_SHA
        and receipt.get('criteriaSHA256') == criterion_sha and receipt.get('passed') is True,
        'Native compiled App acceptance identity differs')
    app_count = len(expected['modules']['app']['exactEndedFunctionIDs']) if dynamic else (3712 if fresh_host else 3708)
    require(receipt.get('counts') == {'freshApp': app_count, 'retainedCurrentXCTest' if continued else 'freshXCTest': 48, 'retainedEngine': 896,
        'executions': app_count + 48 + 896, 'appSkips': 8, 'engineSkips': 14}, 'Native compiled App acceptance counts differ')
    require(set(receipt.get('products', {})) == set(PHASES) and set(receipt.get('freshProofs', {})) == ({'app-swift-testing'} if continued else {'xctest', 'app-swift-testing'}),
        'Native compiled App acceptance roles differ')
    selected_roles = selector_identities(json.dumps(receipt.get('selected')))
    for phase in PHASES:
        selected = selected_roles[phase]
        product = receipt['products'][phase]['receipt']
        raw = (json.dumps(product, indent=2) + '\n').encode()
        if dynamic:
            app_cohort_v2.compatible_product(product, {'cohortV2': receipt['cohortV2'],
                'compilerSHA256': receipt['compilerSHA256'], 'plans': product.get('recipePlan', {})}, phase)
        require(hashlib.sha256(raw).hexdigest() == selected['receiptSHA256']
            and product.get('schema') == 'native-app-target-product/v1'
            and product.get('sourceSHA') == selected['sourceSHA'] and product.get('runID') == selected['runID']
            and product.get('phase') == phase and (dynamic or product.get('appSourceSHA') == APP_SOURCE)
            and product.get('compilerSHA256') == COMPILER_SHA and product.get('attempt') == 1
            and (dynamic or product.get('nativeSourceObjects') == receipt['nativeSourceObjects'])
            and product.get('state', {}).get('compileComplete') is True and product['state'].get('linkComplete') is True
            and receipt['products'][phase]['originalArchiveSHA256'] == selected['artifactSHA256'],
            'Native acceptance compiler product differs')
    if not dynamic:
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
            if dynamic:
                from app_release_v2 import verify_xctest
                verify_xctest(proof, expected['xctest']['exactIndividualPassedIDs'], source,
                    receipt['products']['tests']['receipt'], value)
            else:
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
    require(app['events'].get('functionExecutions') == app_count and app['events'].get('runStarted') == app['events'].get('runEnded') == 1
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


def reuse_retained_signature(root, app, manifest):
    from compiled_core_reuse import persist
    native_guard(root)
    marker = root / 'verify-retained-signature.reused.json'
    require(not marker.exists() and not marker.is_symlink(), 'Retained signature reuse was already recorded')
    origin = SIGNATURE_ORIGIN
    run = api('actions/runs/' + str(origin['runID']))
    job = api('actions/jobs/' + str(origin['jobID']))
    artifact = api('actions/artifacts/' + str(origin['artifactID']))
    require(run.get('id') == origin['runID'] and run.get('head_sha') == origin['sourceSHA']
        and run.get('run_attempt') == 1 and run.get('workflow_id') == 303346287
        and run.get('path') == '.github/workflows/release.yml' and run.get('event') == 'workflow_dispatch'
        and run.get('status') == 'completed' and run.get('conclusion') == 'failure'
        and run.get('repository', {}).get('full_name') == REPOSITORY
        and run.get('actor', {}).get('login') == 'iret77', 'Retained signature execution origin differs')
    require(job.get('id') == origin['jobID'] and job.get('run_id') == origin['runID']
        and job.get('head_sha') == origin['sourceSHA'] and job.get('run_attempt') == 1
        and job.get('name') == 'release-build' and job.get('labels') == ['macrunner']
        and job.get('status') == 'completed' and job.get('conclusion') == 'failure',
        'Retained signature producer differs')
    verify_artifact(artifact, run, job, origin['artifactID'], origin['artifactSHA256'],
        'release-compiled-app-assembly-' + str(origin['runID']) + '-a1')
    require(artifact.get('size_in_bytes') == origin['artifactBytes'], 'Retained signature artifact size differs')
    records = {'argv.json': (json.dumps(SIGNATURE_COMMAND['argv'], indent=2) + '\n').encode(),
        'exit.json': (json.dumps({'exitCode': SIGNATURE_COMMAND['exitCode']}, indent=2) + '\n').encode(),
        'stdout': SIGNATURE_COMMAND['stdout'].encode(), 'stderr': SIGNATURE_COMMAND['stderr'].encode()}
    require({name: hashlib.sha256(raw).hexdigest() for name, raw in records.items()} == SIGNATURE_RECORD_SHA256,
        'Source-pinned original signature command records changed')
    require(manifest.get('sourceSHA') == RETAINED_SOURCE and manifest.get('runID') == RETAINED_RUN
        and manifest.get('appTreeSHA256') == SIGNATURE_APP_TREE, 'Retained signature product manifest differs')
    record = {'schema': 'retained-app-signature-reuse/v1', 'state': 'REUSED',
        'original': {'sourceSHA': origin['sourceSHA'], 'runID': origin['runID'], 'attempt': 1,
            'jobID': origin['jobID'], 'artifactID': origin['artifactID'], 'artifactSHA256': origin['artifactSHA256'],
            'productSourceSHA': RETAINED_SOURCE, 'productRunID': RETAINED_RUN, 'appTreeSHA256': SIGNATURE_APP_TREE,
            'command': SIGNATURE_COMMAND, 'recordSHA256': SIGNATURE_RECORD_SHA256,
            'recordBytes': {name: len(raw) for name, raw in records.items()}},
        'currentMaterialization': {'sourceSHA': os.environ['GITHUB_SHA'], 'runID': int(os.environ['GITHUB_RUN_ID']),
            'appPath': str(app), 'appTreeSHA256': SIGNATURE_APP_TREE, 'appRootMode': 0o755},
        'originEvidence': {'run': run, 'job': job, 'artifact': artifact},
        'currentNativeSignatureVerificationPerformed': False, 'freshTrustStoreOrRevocationClaimed': False}
    require(app.is_dir() and not app.is_symlink() and stat.S_IMODE(app.lstat().st_mode) == 0o755
        and checkpoint.tree_digest(app) == SIGNATURE_APP_TREE,
        'Materialized App differs from the qualified original signature bytes or root')
    persist(marker, record)


def image_uuid(path, filetype):
    raw = path.read_bytes()
    require(len(raw) >= 32, 'Truncated component Mach-O')
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from('<8I', raw)
    require(magic == 0xfeedfacf and cpu == 0x100000c and kind == filetype
        and 0 < count < 4096 and 32 + size <= len(raw), 'Component Mach-O identity differs')
    offset, values = 32, []
    for _ in range(count):
        require(offset + 8 <= 32 + size, 'Truncated component load command')
        command, length = struct.unpack_from('<II', raw, offset)
        require(length >= 8 and offset + length <= 32 + size, 'Invalid component load command')
        if command == 0x1b:
            require(length == 24, 'Invalid component UUID command')
            values.append(str(uuid.UUID(bytes=raw[offset + 8:offset + 24])).upper())
        offset += length
    require(offset == 32 + size and len(values) == 1, 'Component UUID is missing or ambiguous')
    return values[0]


def signed_payload_sha(path, filetype=6):
    raw = bytearray(path.read_bytes())
    require(len(raw) >= 32, 'Truncated signed Engine')
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from('<8I', raw)
    require(magic == 0xfeedfacf and cpu == 0x100000c and filetype in (2, 6) and kind == filetype
        and 0 < count < 4096 and 32 + size <= len(raw), 'Signed Engine header differs')
    offset, signatures, linkedit = 32, [], []
    for _ in range(count):
        require(offset + 8 <= 32 + size, 'Truncated signed Engine load command')
        command, length = struct.unpack_from('<II', raw, offset)
        require(length >= 8 and offset + length <= 32 + size, 'Invalid signed Engine load command')
        if command == 0x1d:
            require(length == 16, 'Invalid Engine signature command')
            start, length_bytes = struct.unpack_from('<II', raw, offset + 8)
            require(start >= 32 + size and start + length_bytes == len(raw), 'Engine signature bounds differ')
            signatures.append(start)
            raw[offset + 8:offset + 16] = bytes(8)
        elif command == 0x19:
            require(length >= 72, 'Invalid Engine segment command')
            if bytes(raw[offset + 8:offset + 24]).rstrip(b'\0') == b'__LINKEDIT':
                linkedit.append(offset)
                raw[offset + 32:offset + 40] = bytes(8)
                raw[offset + 48:offset + 56] = bytes(8)
        offset += length
    require(offset == 32 + size and len(signatures) == len(linkedit) == 1,
        'Engine signature or LINKEDIT is missing or ambiguous')
    return hashlib.sha256(raw[:signatures[0]]).hexdigest()


def install_linked_engine(root, app, bound, sign):
    require(type(sign) is str and (re.fullmatch('[a-fA-F0-9]{40}', sign)
        or sign.startswith('Developer ID Application: ')), 'Linked Engine requires a Developer ID signer')
    app_anchor = source_directory_identity(app, Path.cwd())
    runtime = Path(bound['runtime'])
    manifest_path = root / 'bank-runtime-manifest.json'
    require(runtime == root / 'runtime' and runtime.is_dir() and not runtime.is_symlink()
        and not manifest_path.is_symlink() and checksum(manifest_path) == retained.MANIFEST_SHA,
        'Linked Engine lost its exact retained bank')
    manifest = json.loads(manifest_path.read_text())
    require(manifest['sourceObjects']['Engine'] == source_objects('HEAD')['Engine']
        and manifest['configuration'] == 'release' and manifest['swiftcFlags'] == ['-enable-testing']
        and bound['runtimeManifestSHA256'] == retained.MANIFEST_SHA,
        'Linked Engine source or compiler configuration differs')
    plan = bound['prepared']['plans']['production']
    links = [item for item in plan['operations']['links'] if item['targetGUID'] == plan['driver']['targetGUID']]
    linked_path = str(Path(plan['operations']['arena']) / 'Products/Release/libNexGenEngine.dylib')
    require(len(links) == 1 and links[0]['argv'].count(linked_path) == 1
        and '-lNexGenEngine' not in links[0]['argv'], 'Production App lost its exact Engine linker input')
    engine = runtime / 'libNexGenEngine.dylib'
    module = runtime / 'NexGenEngine.swiftmodule/arm64-apple-macos.swiftmodule'
    symbols = runtime / 'libNexGenEngine.dylib.dSYM'
    prefix = symbols.name
    expected = {name.removeprefix(prefix + '/'): item for name, item in manifest['files'].items()
        if name.startswith(prefix + '/')}
    require(symbols.is_dir() and not symbols.is_symlink() and expected
        and stat.S_IMODE(symbols.lstat().st_mode) == manifest['files'][prefix]['mode'] == 0o755
        and {path.relative_to(symbols).as_posix() for path in symbols.rglob('*')} == set(expected),
        'Linked Engine symbol bundle inventory differs')
    for name, item in expected.items():
        path = symbols / name
        require(not path.is_symlink() and stat.S_IMODE(path.lstat().st_mode) == item['mode']
            and ((item['kind'] == 'directory' and path.is_dir())
                or (item['kind'] == 'file' and path.is_file() and path.stat().st_size == item['bytes']
                    and checksum(path) == item['sha256'])), 'Linked Engine symbol bytes or mode differ')
    dwarf = symbols / 'Contents/Resources/DWARF/libNexGenEngine.dylib'
    require(engine.is_file() and not engine.is_symlink() and checksum(engine) == LINKED_ENGINE['sha256']
        and engine.stat().st_size == LINKED_ENGINE['bytes']
        and stat.S_IMODE(engine.lstat().st_mode) == manifest['files'][engine.name]['mode'] == 0o755
        and manifest['files'][engine.name]['sha256'] == LINKED_ENGINE['sha256']
        and module.is_file() and not module.is_symlink() and checksum(module) == LINKED_ENGINE['moduleSHA256']
        and stat.S_IMODE(module.lstat().st_mode) == manifest['files'][module.relative_to(runtime).as_posix()]['mode'] == 0o644
        and manifest['files'][module.relative_to(runtime).as_posix()]['sha256'] == LINKED_ENGINE['moduleSHA256']
        and checksum(Path(bound['products']['production']['output'])) == LINKED_ENGINE['mainUnsignedSHA256']
        and checksum(dwarf) == LINKED_ENGINE['dsymSHA256']
        and image_uuid(engine, 6) == image_uuid(dwarf, 10) == LINKED_ENGINE['uuid'],
        'Linked Engine image and matching symbols lost their original identity')
    destination, final_symbols = app / 'Contents/Frameworks/libNexGenEngine.dylib', Path('.build/NexGenEngine.dSYM')
    require(destination.is_file() and not destination.is_symlink() and final_symbols.is_dir()
        and not final_symbols.is_symlink() and sign, 'Distribution Engine destinations or signer differ')
    original_sha = checksum(destination)
    require(original_sha == LINKED_ENGINE['retiredImageSHA256'], 'Retired distribution Engine differs')
    source_directory_identity(destination.parent, app)
    destination.rename(root / 'retired-original-engine-image')
    final_symbols.rename(root / 'retired-original-engine-symbols')
    shutil.copy2(engine, destination)
    shutil.copytree(symbols, final_symbols)
    require(checksum(destination) == LINKED_ENGINE['sha256']
        and canonical_bundle_tree(final_symbols) == canonical_bundle_tree(symbols) == LINKED_ENGINE['symbolsTreeSHA256'],
        'Copied linked Engine or symbols differ')
    payload_sha = signed_payload_sha(engine)
    require(payload_sha == LINKED_ENGINE['payloadSHA256'], 'Original Engine payload differs')
    targets.logged(root, 'sign-linked-engine', ['codesign', '--force', '--options', 'runtime', '--timestamp',
        '--sign', sign, str(destination)], timeout=180)
    targets.logged(root, 'verify-linked-engine-signature', ['codesign', '--verify', '--strict', str(destination)])
    source_directory_identity(app, Path.cwd(), app_anchor)
    source_directory_identity(destination.parent, app)
    require(signed_payload_sha(destination) == payload_sha
        and image_uuid(destination, 6) == image_uuid(final_symbols / 'Contents/Resources/DWARF/libNexGenEngine.dylib', 10)
        == LINKED_ENGINE['uuid'], 'Distribution Engine signature changed its image/symbol identity')
    return {'schema': 'compiled-linked-engine-distribution/v1', 'state': 'REUSED_COMPILER_PRODUCT_NEW_DEVELOPER_ID_SIGNATURE',
        'producerRunID': retained.RUN, 'producerSourceSHA': retained.SOURCE,
        'artifactID': retained.ARTIFACTS['runtime'][0], 'artifactSHA256': retained.ARTIFACTS['runtime'][1],
        'manifestSHA256': retained.MANIFEST_SHA, 'original': LINKED_ENGINE,
        'productionLinkerInput': linked_path,
        'retiredImageSHA256': original_sha, 'distributionImageSHA256': checksum(destination),
        'payloadSHA256': payload_sha,
        'symbolsTreeSHA256': canonical_bundle_tree(final_symbols),
        'symbolBundle': 'NexGenEngine.dSYM', 'dwarfMember': 'Contents/Resources/DWARF/libNexGenEngine.dylib',
        'compilerOrLinkerInvoked': False}


def derive_component_source(root, directory):
    import consume_bpy_distributable_source as source
    from compiled_core_reuse import persist, persist_bytes, sync_directory
    original_path = directory / source.RECEIPT
    raw = original_path.read_bytes()
    require(not original_path.is_symlink() and hashlib.sha256(raw).hexdigest() == SIGNED_RESUME['sourceReceiptSHA256'],
        'Component assembly lost the original source receipt')
    public = source.public_asset(json.loads(source.LOCK_PATH.read_text()))
    original = source.qualified_handoff(json.loads(raw), public, RETAINED_SOURCE)
    require(source_objects('HEAD')['Runtime'] == source_objects(RETAINED_SOURCE)['Runtime'],
        'Component assembly changed corresponding-source Runtime pins')
    source.require_pair(directory, public)
    derived = dict(original, sourceSHA=os.environ['GITHUB_SHA'])
    source.qualified_handoff(derived, public, os.environ['GITHUB_SHA'])
    persist_bytes(root / 'component-source-original-receipt.json', raw)
    replacement = directory / 'component-source-current-receipt.json'
    persist_bytes(replacement, (json.dumps(derived, indent=2, sort_keys=True) + '\n').encode())
    replacement.replace(original_path)
    sync_directory(directory)
    value = {'schema': 'compiled-component-source-handoff/v1', 'state': 'REUSED',
        'originalReceipt': raw.decode(), 'originalReceiptSHA256': hashlib.sha256(raw).hexdigest(),
        'qualification': source.QUALIFIED_HANDOFF, 'consumerSourceSHA': os.environ['GITHUB_SHA'],
        'receiptSHA256': checksum(original_path), 'semanticSourceValidationPerformed': False}
    persist(root / 'component-source-handoff.json', value)
    return value


def verify_component_assembly(value, source_sha, run_id, identity, files, native_evidence):
    if native_evidence.get('schema') == 'release-native-compiled-app/v5':
        from app_release_v2 import verify_assembly
        return verify_assembly(value, source_sha, run_id, identity, files, native_evidence)
    import consume_bpy_distributable_source as source
    require(type(value) is dict and value.get('schema') == 'compiled-component-assembly/v1'
        and value.get('sourceSHA') == source_sha and value.get('runID') == run_id
        and value.get('attempt') == 1 and value.get('build') == identity.get('build') == COMPONENT_BUILD,
        'Compiled component assembly lost its current product identity')
    component, handoff, main = value.get('engine', {}), value.get('sourceHandoff', {}), value.get('main', {})
    product = native_evidence.get('products', {}).get('production', {}).get('receipt', {})
    linked_path = str(Path(product.get('arena', '')) / 'Products/Release/libNexGenEngine.dylib')
    require(component.get('schema') == 'compiled-linked-engine-distribution/v1'
        and component.get('state') == 'REUSED_COMPILER_PRODUCT_NEW_DEVELOPER_ID_SIGNATURE'
        and component.get('original') == LINKED_ENGINE and component.get('producerRunID') == retained.RUN
        and component.get('retiredImageSHA256') == LINKED_ENGINE['retiredImageSHA256']
        and component.get('payloadSHA256') == LINKED_ENGINE['payloadSHA256']
        and component.get('symbolsTreeSHA256') == LINKED_ENGINE['symbolsTreeSHA256']
        and component.get('producerSourceSHA') == retained.SOURCE
        and component.get('artifactID') == retained.ARTIFACTS['runtime'][0]
        and component.get('artifactSHA256') == retained.ARTIFACTS['runtime'][1]
        and component.get('manifestSHA256') == retained.MANIFEST_SHA
        and component.get('symbolBundle') == 'NexGenEngine.dSYM'
        and component.get('dwarfMember') == 'Contents/Resources/DWARF/libNexGenEngine.dylib'
        and component.get('compilerOrLinkerInvoked') is False
        and component.get('productionLinkerInput') == linked_path
        and product.get('state', {}).get('unsignedLinkSHA256') == LINKED_ENGINE['mainUnsignedSHA256']
        and all(re.fullmatch('[a-f0-9]{64}', component.get(key, '')) for key in
            ('retiredImageSHA256', 'distributionImageSHA256', 'symbolsTreeSHA256', 'payloadSHA256')),
        'Compiled component assembly lost its actual linked Engine')
    require(main.get('original') == MAIN_PRODUCT
        and re.fullmatch('[a-f0-9]{64}', main.get('distributionImageSHA256', ''))
        and product.get('state', {}).get('unsignedLinkSHA256') == MAIN_PRODUCT['compiledImageSHA256'],
        'Compiled component assembly lost its original Main product and symbols')
    raw = handoff.get('originalReceipt', '').encode()
    require(handoff.get('schema') == 'compiled-component-source-handoff/v1' and handoff.get('state') == 'REUSED'
        and handoff.get('originalReceiptSHA256') == hashlib.sha256(raw).hexdigest() == SIGNED_RESUME['sourceReceiptSHA256']
        and handoff.get('qualification') == source.QUALIFIED_HANDOFF and handoff.get('consumerSourceSHA') == source_sha
        and handoff.get('semanticSourceValidationPerformed') is False,
        'Compiled component assembly lost its original source validation')
    public = source.public_asset(json.loads(source.LOCK_PATH.read_text()))
    original = source.qualified_handoff(json.loads(raw), public, RETAINED_SOURCE)
    derived = dict(original, sourceSHA=source_sha)
    expected = hashlib.sha256((json.dumps(derived, indent=2, sort_keys=True) + '\n').encode()).hexdigest()
    require(handoff.get('receiptSHA256') == expected == files['bpy-source-receipt.json']['sha256'],
        'Compiled component assembly changed its exact derived receipt bytes')
    return value


def verify_engine_materialization(component, app, symbols):
    image = app / 'Contents/Frameworks/libNexGenEngine.dylib'
    dwarf = symbols / component['dwarfMember']
    require(image.is_file() and not image.is_symlink() and stat.S_IMODE(image.lstat().st_mode) == 0o755
        and symbols.is_dir() and not symbols.is_symlink() and stat.S_IMODE(symbols.lstat().st_mode) == 0o755
        and all(not path.is_symlink() for path in symbols.rglob('*'))
        and checksum(image) == component['distributionImageSHA256']
        and signed_payload_sha(image) == component['payloadSHA256'] == LINKED_ENGINE['payloadSHA256']
        and canonical_bundle_tree(symbols) == component['symbolsTreeSHA256'] == LINKED_ENGINE['symbolsTreeSHA256']
        and checksum(dwarf) == LINKED_ENGINE['dsymSHA256']
        and image_uuid(image, 6) == image_uuid(dwarf, 10) == LINKED_ENGINE['uuid'],
        'Actual component image, code payload, mode or complete symbol bundle changed')


def verify_main_inputs(bound):
    image = Path(bound['products']['production']['output'])
    symbols = Path(str(image) + '.dSYM')
    dwarf = symbols / 'Contents/Resources/DWARF/NexGenVideo'
    require(image.is_file() and not image.is_symlink() and stat.S_IMODE(image.lstat().st_mode) == 0o755
        and checksum(image) == MAIN_PRODUCT['compiledImageSHA256']
        and symbols.is_dir() and not symbols.is_symlink() and stat.S_IMODE(symbols.lstat().st_mode) == 0o755
        and all(not path.is_symlink() for path in symbols.rglob('*'))
        and canonical_bundle_tree(symbols) == MAIN_PRODUCT['symbolsTreeSHA256']
        and checksum(dwarf) == MAIN_PRODUCT['dwarfSHA256']
        and image_uuid(image, 2) == image_uuid(dwarf, 10) == MAIN_PRODUCT['uuid'],
        'Original compiled Main or complete Main symbols changed')


def verify_component_materialization(value, app, symbols):
    if value.get('schema') == 'compiled-component-assembly/v2':
        from app_release_v2 import verify_materialization
        return verify_materialization(value, app, symbols)
    verify_engine_materialization(value['engine'], app, symbols)
    main = value.get('main', {})
    image = app / 'Contents/MacOS/NexGenVideo'
    main_symbols = symbols.parent / 'NexGenVideo.dSYM'
    dwarf = main_symbols / 'Contents/Resources/DWARF/NexGenVideo'
    require(main.get('original') == MAIN_PRODUCT
        and image.is_file() and not image.is_symlink() and stat.S_IMODE(image.lstat().st_mode) == 0o755
        and checksum(image) == main.get('distributionImageSHA256')
        and signed_payload_sha(image, 2) == MAIN_PRODUCT['payloadSHA256']
        and main_symbols.is_dir() and not main_symbols.is_symlink()
        and stat.S_IMODE(main_symbols.lstat().st_mode) == 0o755
        and all(not path.is_symlink() for path in main_symbols.rglob('*'))
        and canonical_bundle_tree(main_symbols) == MAIN_PRODUCT['symbolsTreeSHA256']
        and checksum(dwarf) == MAIN_PRODUCT['dwarfSHA256']
        and image_uuid(image, 2) == image_uuid(dwarf, 10) == MAIN_PRODUCT['uuid'],
        'Actual Main image, code payload, mode or original complete symbols changed')


def seal_component_app(root, app, bound, sign, engine_component, source_handoff):
    verify_main_inputs(bound)
    image = app / 'Contents/MacOS/NexGenVideo'
    require(signed_payload_sha(image, 2) == MAIN_PRODUCT['payloadSHA256'], 'Distribution Main payload changed before signing')
    targets.logged(root, 'sign-new-app-root', ['codesign', '--force', '--options', 'runtime', '--timestamp',
        '--sign', sign, '--entitlements', 'scripts/NexGenVideo.entitlements', str(app)], timeout=180)
    targets.logged(root, 'verify-new-app-signature', ['codesign', '--verify', '--deep', '--strict', str(app)])
    targets.logged(root, 'verify-distributable-bpy', ['bash', 'scripts/verify_bpy_bundle.sh', str(app), '--distribution'], timeout=300)
    verify_main_inputs(bound)
    value = {'schema': 'compiled-component-assembly/v1', 'sourceSHA': os.environ['GITHUB_SHA'],
        'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1, 'build': COMPONENT_BUILD,
        'engine': engine_component, 'sourceHandoff': source_handoff,
        'main': {'original': MAIN_PRODUCT, 'distributionImageSHA256': checksum(image)}}
    verify_component_materialization(value, app, Path('.build/NexGenEngine.dSYM'))
    return value


def assemble(root):
    if json.loads((root / 'receipt.json').read_bytes()).get('schema') == 'release-native-compiled-app/v5':
        from app_release_v2 import assemble as assemble_current
        return assemble_current(root)
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
    with verified_zip(payload, 4 * 1024**3, qualified_sha=SIGNED_ARTIFACT[1]) as archive:
        require(set(archive.namelist()) == set(checkpoint.FILES) | {'manifest.json'}, 'Retained signed input inventory differs')
        manifest = checkpoint.verify_manifest(json.loads(checkpoint.signed_manifest_bytes(archive)), RETAINED_SOURCE, RETAINED_RUN)
        write(root / 'retained-signed-manifest.json', manifest)
        for name in checkpoint.FILES:
            record = manifest['files'][name]
            require(archive.getinfo(name).file_size == record['bytes'], 'Retained signed payload size differs')
            with archive.open(name) as source, (retained_root / name).open('xb') as destination:
                shutil.copyfileobj(source, destination, 1024 * 1024)
            require(checksum(retained_root / name) == record['sha256'], 'Retained signed payload bytes differ')
    build = Path('.build')
    app = build / 'NexGenVideo.app'
    require(not app.exists() and not app.is_symlink(), 'New App bundle destination is occupied')
    build.mkdir(exist_ok=True)
    targets.logged(root, 'restore-signed-app', ['/usr/bin/ditto', '-x', '-k', str(retained_root / 'NexGenVideo.zip'), str(build)])
    reuse_retained_signature(root, app, manifest)
    checkpoint.extract_tar(retained_root / 'symbols.tar.gz', build, {
        'NexGenVideo.dSYM', 'NexGenVideoDiagnostics.dSYM', 'NexGenEngine.dSYM', 'MusicvideoPlugin.dSYM'})
    final = retained_payload(root, 'release', *FINAL_ARTIFACT)
    pack_root = build / 'plugins'
    pack_root.mkdir(exist_ok=False)
    source_root = build / 'bpy-source'
    source_root.mkdir(exist_ok=True)
    with verified_zip(final, 6 * 1024**3, qualified_sha=FINAL_ARTIFACT[1]) as archive:
        for name in ('plugins/musicvideo.entry.json', 'plugins/musicvideo.ngvpack.zip', 'plugins/musicvideo.badge.png',
                'bpy-source/bpy-source-receipt.json', 'bpy-source/NexGenVideo-bpy-5.2.2-corresponding-source.tar',
                'bpy-source/NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json'):
            with archive.open(name) as source, (build / name).open('xb') as destination:
                shutil.copyfileobj(source, destination, 1024 * 1024)
    require(checksum(pack_root / 'musicvideo.ngvpack.zip') == PACK_SHA
        and checksum(source_root / 'bpy-source-receipt.json') == manifest['files']['bpy-source-receipt.json']['sha256'],
        'Retained stapled pack or distributable source receipt differs')
    with verified_zip(pack_root / 'musicvideo.ngvpack.zip', 64 * 1024**2, qualified_sha=PACK_SHA) as archive:
        require(all(PurePosixPath(item.filename).parts[0] in ('musicvideo.ngvpack', '__MACOSX')
            for item in archive.infolist()), 'Retained pack archive escapes its bundle')
    targets.logged(root, 'restore-stapled-pack', ['/usr/bin/ditto', '-x', '-k', str(pack_root / 'musicvideo.ngvpack.zip'), str(pack_root)])
    verify_pack(pack_root)
    source_handoff = derive_component_source(root, source_root)
    original_image = app / 'Contents/MacOS/NexGenVideo'
    original_symbols = build / 'NexGenVideo.dSYM'
    original_image.rename(root / 'retired-original-app-image')
    original_symbols.rename(root / 'retired-original-app-symbols')
    production = Path(bound['products']['production']['output'])
    verify_main_inputs(bound)
    shutil.copyfile(production, original_image)
    os.chmod(original_image, 0o755)
    shutil.copytree(Path(str(production) + '.dSYM'), original_symbols, symlinks=True)
    require(canonical_bundle_tree(original_symbols) == canonical_bundle_tree(Path(str(production) + '.dSYM')),
        'Copied production App symbols differ')
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
        CFBundleShortVersionString='1.8.0', CFBundleVersion=COMPONENT_BUILD)
    require(COMPONENT_BUILD == '107' and int(COMPONENT_BUILD) > int(manifest['identity']['build']) + 1,
        'Corrected component product must supersede the failed signed build106')
    require(info['NGVPluginCatalogURL'] == 'https://github.com/iret77/nexgenvideo/releases/download/plugins/catalog.json',
        'Compiled App cannot change its catalog channel')
    info_path.write_bytes(plistlib.dumps(info))
    sign = os.environ.get('SIGN_IDENTITY')
    require(sign, 'Developer ID identity is missing')
    engine_component = install_linked_engine(root, app, bound, sign)
    component_assembly = seal_component_app(root, app, bound, sign, engine_component, source_handoff)
    write(root / 'assembled.json', {'sourceSHA': os.environ['GITHUB_SHA'], 'runID': int(os.environ['GITHUB_RUN_ID']),
        'appTreeSHA256': checkpoint.tree_digest(app), 'identity': checkpoint.identity(build),
        'newCompiledImageSHA256': checksum(production), 'distributionImageSHA256': checksum(original_image),
        'retainedSourceSHA': RETAINED_SOURCE, 'retainedSignedArtifact': SIGNED_ARTIFACT,
        'retainedFinalArtifact': FINAL_ARTIFACT, 'freshResourceSHA256': {name: checksum(Path(name)) for name in sorted(fresh_resources)},
        'retainedPackSHA256': PACK_SHA, 'retainedPackTreeSHA256': PACK_TREE, 'componentAssembly': component_assembly,
        'mainSymbolsTreeSHA256': canonical_bundle_tree(original_symbols),
        'unchangedSourceComponentObjects': {name: targets.capture.git('rev-parse', 'HEAD:' + name) for name in component_paths}})


def pack_verification_origin():
    run = api('actions/runs/' + str(RETAINED_RUN))
    job = api('actions/jobs/' + str(PACK_NATIVE_PROOF['jobID']))
    artifact = api('actions/artifacts/' + str(FINAL_ARTIFACT[0]))
    require(run.get('id') == RETAINED_RUN and run.get('head_sha') == RETAINED_SOURCE
        and run.get('run_attempt') == 1 and run.get('workflow_id') == 303346287
        and run.get('path') == '.github/workflows/release.yml' and run.get('event') == 'workflow_dispatch'
        and run.get('status') == 'completed' and run.get('conclusion') == 'failure'
        and run.get('repository', {}).get('full_name') == REPOSITORY
        and run.get('actor', {}).get('login') == 'iret77', 'Original pack verification execution differs')
    require(job.get('id') == PACK_NATIVE_PROOF['jobID'] and job.get('run_id') == RETAINED_RUN
        and job.get('head_sha') == RETAINED_SOURCE and job.get('run_attempt') == 1
        and job.get('name') == 'release' and job.get('labels') == ['macrunner']
        and job.get('status') == 'completed' and job.get('conclusion') == 'success', 'Original pack producer differs')
    for expected in PACK_NATIVE_PROOF['steps']:
        matches = [step for step in job.get('steps', []) if step.get('number') == expected['number']]
        require(len(matches) == 1 and all(matches[0].get(key) == value for key, value in expected.items()),
            'Original successful pack verification shell step differs')
    verify_artifact(artifact, run, job, FINAL_ARTIFACT[0], FINAL_ARTIFACT[1], 'NexGenVideo-1.8.0-artifact-only')
    require(artifact.get('size_in_bytes') == PACK_NATIVE_PROOF['artifactBytes'], 'Original pack artifact size differs')
    return run, job, artifact


def original_pack_proof():
    return {'sourceSHA': RETAINED_SOURCE, 'runID': RETAINED_RUN, 'attempt': 1,
        'jobID': PACK_NATIVE_PROOF['jobID'], 'artifactID': FINAL_ARTIFACT[0], 'artifactSHA256': FINAL_ARTIFACT[1],
        'qualifiedShellEvidence': PACK_NATIVE_PROOF, 'packArchiveSHA256': PACK_SHA, 'packTreeSHA256': PACK_TREE,
        'exitQualification': 'Derived from original successful set -euo pipefail shell steps; no individual command JSON records.'}


def verify_pack(root):
    from compiled_core_reuse import persist
    require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
        and os.environ.get('GITHUB_JOB') in ('release-build', 'release'), 'Pack verification requires an owned native release job')
    marker = Path(os.environ['RUNNER_TEMP']) / 'retained-pack-verification.reused.json'
    require(not marker.exists() and not marker.is_symlink(), 'Pack verification reuse was already recorded')
    require(root.resolve() == Path(os.environ['GITHUB_WORKSPACE']).resolve() / '.build/plugins'
        and root.is_dir() and not root.is_symlink(), 'Pack materialization is outside the owned build')
    run, job, artifact = pack_verification_origin()
    bundle, archive = root / 'musicvideo.ngvpack', root / 'musicvideo.ngvpack.zip'
    record = {'schema': 'retained-pack-shell-verification-reuse/v1', 'state': 'REUSED',
        'original': original_pack_proof(),
        'currentMaterialization': {'sourceSHA': os.environ['GITHUB_SHA'], 'runID': int(os.environ['GITHUB_RUN_ID']),
            'job': os.environ['GITHUB_JOB'], 'bundlePath': str(bundle), 'rootMode': 0o755,
            'packArchiveSHA256': PACK_SHA, 'packTreeSHA256': PACK_TREE},
        'originEvidence': {'runID': run['id'], 'sourceSHA': run['head_sha'], 'jobID': job['id'],
            'jobStartedAt': job['started_at'], 'jobCompletedAt': job['completed_at'],
            'artifactID': artifact['id'], 'artifactDigest': artifact['digest'],
            'artifactCreatedAt': artifact['created_at'], 'artifactUpdatedAt': artifact['updated_at'],
            'artifactExpiresAt': artifact['expires_at']},
        'currentNativeCodesignOrStaplerPerformed': False, 'freshTrustStoreOrRevocationClaimed': False,
        'currentPackNotarizationPerformed': False, 'newAppPackLoadQualified': False}
    require(archive.is_file() and not archive.is_symlink() and checksum(archive) == PACK_SHA
        and bundle.is_dir() and not bundle.is_symlink() and stat.S_IMODE(bundle.lstat().st_mode) == 0o755
        and canonical_bundle_tree(bundle) == PACK_TREE, 'Retained pack changed')
    persist(marker, record)
    print('PACK_VERIFICATION_REUSED ' + json.dumps(record, sort_keys=True, separators=(',', ':')), flush=True)


def local_pack_runtime_origin(binding, dmg=None, *, expected_dmg_sha256=None):
    import retained_packaging as packaging
    require((dmg is None) != (expected_dmg_sha256 is None), 'Exact current DMG or validated expected digest required')
    require(dmg is None or dmg.is_file() and not dmg.is_symlink(), 'Current DMG is missing or linked')
    dmg_digest = checksum(dmg) if dmg is not None else expected_dmg_sha256
    require(type(dmg_digest) is str and re.fullmatch('[a-f0-9]{64}', dmg_digest), 'Current DMG digest is invalid')
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(), object_pairs_hook=unique_object)
    inputs = event.get('inputs', {})
    require(type(inputs) is dict and type(binding) is dict, 'Local pack reuse lacks its qualified intake')
    local = inputs.get('candidate_kind') == 'signed-journey' and inputs.get('journey_scenario') == 'normal-fresh-local-musicvideo'
    direct = inputs.get('scenario') == 'normal-fresh-local-musicvideo' and inputs.get('artifact_mode') == 'dmg'
    require(local or direct, 'Local pack reuse requires the registered exact-DMG journey')
    names = ('run_id', 'artifact_id', 'artifact_sha256', 'source_sha') if local else (
        'runtime_run_id', 'runtime_artifact_id', 'runtime_artifact_sha256', 'product_source_sha')
    run_id, artifact_id, digest, source = [inputs.get(name, '') for name in names]
    if direct:
        source = source or binding.get('sourceSHA', '')
        if not artifact_id and not digest:
            require(type(run_id) is str and re.fullmatch('[1-9][0-9]*', run_id), 'Local runtime run ID is missing')
            inventory = api('actions/runs/' + run_id + '/artifacts?per_page=100')
            require(inventory.get('total_count') == len(inventory.get('artifacts', [])), 'Incomplete local runtime inventory')
            matches = [item for item in inventory['artifacts'] if item.get('name') == 'release-user-journey-input']
            require(len(matches) == 1, 'Local runtime artifact is missing or ambiguous')
            artifact_id, digest = str(matches[0]['id']), matches[0]['digest'].removeprefix('sha256:')
    require(all(type(value) is str and re.fullmatch('[1-9][0-9]*', value) for value in (run_id, artifact_id))
        and re.fullmatch('[a-f0-9]{64}', digest) and re.fullmatch('[a-f0-9]{40}', source),
        'Local pack reuse lacks exact runtime selectors')
    require(type(binding) is dict and binding.get('sourceSHA') == source
        and binding.get('dmgSHA256') == inputs.get('expected_dmg_sha256') == dmg_digest
        and all(re.fullmatch('[a-f0-9]{64}', binding.get(key, '')) for key in ('appTreeSHA256', 'guideSHA256')),
        'Local pack copy lost its actual DMG, App or guide binding')
    selected = binding.get('packaging')
    parent = packaging.consumer_record(selected, source, int(run_id)) if selected is not None else None
    producer_source = source if parent is None else parent['producerSourceSHA']
    if parent is not None:
        final = parent.get('final', {})
        require(parent.get('stage') == 'complete' and (packaging.retained_compiled_product(parent) or packaging.cohort_signed_product(parent))
            and final.get('dmgSHA256') == dmg_digest and final.get('appTreeSHA256') == binding['appTreeSHA256']
            and final.get('guideSHA256') == binding['guideSHA256'], 'Local copy differs from canonical packaging')
        packaging.consumer_harness(selected, source, packaging.packaging_paths(source))
    require(source != SIGNED_RESUME['sourceSHA'] or parent is not None,
        'Current compiled product requires its canonical packaging provenance')
    import app_cohort_v2 as cohort
    current_cohort = parent is None and cohort.has_manifest(source)
    if current_cohort:
        cohort.consumer_paths(source, os.environ['GITHUB_SHA'])
    conclusions = {'success', 'failure'} if current_cohort or parent is not None and (packaging.component_consumer_repair_paths(parent)
        or packaging.cohort_signed_product(parent)) else {'success'}
    run = api('actions/runs/' + run_id)
    jobs = api('actions/runs/' + run_id + '/attempts/1/jobs?per_page=100')
    artifact = api('actions/artifacts/' + artifact_id)
    require(run.get('id') == int(run_id) and run.get('head_sha') == producer_source and run.get('run_attempt') == 1 and run.get('workflow_id') == 303346287
        and run.get('path') == '.github/workflows/release.yml' and run.get('event') == 'workflow_dispatch'
        and run.get('repository', {}).get('full_name') == REPOSITORY and run.get('actor', {}).get('login') == 'iret77'
        and run.get('status') == 'completed' and run.get('conclusion') in conclusions
        and jobs.get('total_count') == len(jobs.get('jobs', [])), 'Local runtime producer differs')
    producers = [job for job in jobs['jobs'] if job.get('name') == 'release' and job.get('run_id') == int(run_id)
        and job.get('head_sha') == producer_source and job.get('run_attempt') == 1 and job.get('labels') == ['macrunner']
        and job.get('status') == 'completed' and job.get('conclusion') == 'success']
    require(len(producers) == 1, 'Local runtime requires its successful current release producer')
    verify_artifact(artifact, run, producers[0], int(artifact_id), digest, 'release-user-journey-input')
    result = {'runID': int(run_id), 'sourceSHA': source, 'artifactID': int(artifact_id),
        'artifactSHA256': digest, 'producerJobID': producers[0]['id'], 'intakeBinding': binding}
    if parent is not None:
        result.update(producerSourceSHA=producer_source, packaging=selected)
    return result


def verify_pack_copy(bundle, context, archive=None, dmg=None, *, binding=None, evidence=None):
    from compiled_core_reuse import persist
    contexts = {'external-load': 'release', 'pre-dmg': 'release', 'dmg-copy': 'release',
        'installed-dmg': 'release', 'local-dmg': 'acceptance', 'local-installed': 'acceptance'}
    require(context in contexts and sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
        and os.environ.get('GITHUB_JOB') == contexts[context], 'Unknown or foreign pack-copy caller')
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    local = context.startswith('local-')
    proof_root = Path(evidence).resolve() / 'pack-reuse' if evidence is not None else temporary / 'pack-copy-reuse'
    require(proof_root.is_relative_to(temporary), 'Pack-copy evidence escapes the owned job')
    proof_root.mkdir(parents=True, exist_ok=True)
    require(proof_root.is_dir() and not proof_root.is_symlink() and proof_root.resolve().is_relative_to(temporary),
        'Pack-copy proof directory is linked or outside the owned job')
    marker = proof_root / (context + '.json')
    require(not marker.exists() and not marker.is_symlink(), 'Pack-copy admission was already consumed')
    require((context not in ('external-load', 'pre-dmg') or archive is not None)
        and (context not in ('dmg-copy', 'installed-dmg', 'local-dmg', 'local-installed') or dmg is not None),
        'Pack-copy admission lacks its archive or actual DMG')
    parent, parent_digest, runtime = None, None, None
    if local:
        require(evidence is not None and dmg.is_file() and not dmg.is_symlink(), 'Local pack lacks its current DMG evidence')
        runtime = local_pack_runtime_origin(binding, dmg)
    else:
        require(binding is None and evidence is None, 'Release pack-copy cannot ignore unrelated intake selectors')
        parent_path = temporary / 'retained-pack-verification.reused.json'
        require(parent_path.is_file() and not parent_path.is_symlink(), 'Missing same-job pack admission parent')
        parent_raw = parent_path.read_bytes()
        parent_digest = hashlib.sha256(parent_raw).hexdigest()
        parent = json.loads(parent_raw, object_pairs_hook=unique_object)
        current = parent.get('currentMaterialization', {})
        require(parent.get('schema') == 'retained-pack-shell-verification-reuse/v1' and parent.get('state') == 'REUSED'
            and parent.get('original') == original_pack_proof() and parent.get('newAppPackLoadQualified') is False
            and parent.get('currentNativeCodesignOrStaplerPerformed') is False
            and parent.get('currentPackNotarizationPerformed') is False
            and parent.get('freshTrustStoreOrRevocationClaimed') is False
            and current.get('sourceSHA') == os.environ['GITHUB_SHA'] and current.get('runID') == int(os.environ['GITHUB_RUN_ID'])
            and current.get('job') == 'release' and current.get('packTreeSHA256') == PACK_TREE
            and current.get('packArchiveSHA256') == PACK_SHA, 'Pack-copy parent belongs to another execution or product')
    run, job, artifact = pack_verification_origin()
    record = {'schema': 'retained-pack-copy-reuse/v1', 'state': 'REUSED', 'context': context,
        'original': original_pack_proof(), 'currentSourceSHA': os.environ['GITHUB_SHA'],
        'currentRunID': int(os.environ['GITHUB_RUN_ID']), 'currentAttempt': 1, 'currentJob': os.environ['GITHUB_JOB'],
        'bundlePath': str(bundle), 'rootMode': 0o755, 'packTreeSHA256': PACK_TREE,
        'parentSHA256': parent_digest, 'runtimeProducer': runtime,
        'currentArchiveSHA256': checksum(archive) if archive is not None else None,
        'currentDMGSHA256': checksum(dmg) if dmg is not None else None,
        'originProducer': {'runID': run['id'], 'jobID': job['id'], 'artifactID': artifact['id'], 'artifactDigest': artifact['digest']},
        'currentNativeCodesignOrStaplerPerformed': False, 'currentPackNotarizationPerformed': False,
        'freshTrustStoreOrRevocationClaimed': False, 'newAppPackLoadQualified': False}
    require((parent is None or parent_path.is_file() and not parent_path.is_symlink() and checksum(parent_path) == parent_digest)
        and (archive is None or archive.is_file() and not archive.is_symlink() and record['currentArchiveSHA256'] == PACK_SHA)
        and (dmg is None or dmg.is_file() and not dmg.is_symlink())
        and (runtime is None or record['currentDMGSHA256'] == runtime['intakeBinding']['dmgSHA256'])
        and bundle.is_dir() and not bundle.is_symlink() and bundle.suffix == '.ngvpack'
        and stat.S_IMODE(bundle.lstat().st_mode) == 0o755 and canonical_bundle_tree(bundle) == PACK_TREE,
        'Pack copy differs from its qualified original bytes, modes or links')
    persist(marker, record)
    print('PACK_COPY_VERIFICATION_REUSED ' + json.dumps(record, sort_keys=True, separators=(',', ':')), flush=True)
    return record


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
        'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1,
        'appSourceSHA': json.loads((root / 'bound.json').read_bytes())['appSourceSHA'] if (root / 'bound.json').is_file() else None,
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
    component = assembled.get('componentAssembly')
    if 'componentAssembly' in assembled:
        require(type(component) is dict and (receipt.get('schema') == 'release-native-compiled-app/v5' or assembled['identity']['build'] == COMPONENT_BUILD),
            'Component checkpoint type or build differs')
        verify_component_assembly(component, os.environ['GITHUB_SHA'], int(os.environ['GITHUB_RUN_ID']),
            assembled['identity'], {'bpy-source-receipt.json': {
                'sha256': checksum(build / 'bpy-source/bpy-source-receipt.json')}}, receipt)
        verify_component_materialization(component, build / 'NexGenVideo.app', build / 'NexGenEngine.dSYM')
        require(canonical_bundle_tree(build / 'NexGenVideo.dSYM') == assembled['mainSymbolsTreeSHA256'],
            'Current Main symbols changed before checkpoint')
    else:
        require(assembled['identity']['build'] != COMPONENT_BUILD, 'Corrected compiled product lacks its actual component assembly')
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
    if component is not None:
        manifest['componentAssembly'] = component
    checkpoint.validate_app_zip(output / 'NexGenVideo.zip')
    checkpoint.verify_manifest(manifest, os.environ['GITHUB_SHA'], int(os.environ['GITHUB_RUN_ID']))
    checkpoint.write_signed_manifest(output / 'manifest.json', manifest)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action', choices=('validate-inputs', 'acquire', 'test', 'assemble', 'create-signed-input', 'verify-pack', 'verify-pack-copy', 'retain-assembly', 'prepare-resumed-source'))
    parser.add_argument('--root', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--job-status', choices=('success', 'failure', 'cancelled'))
    parser.add_argument('--copy-context', choices=('external-load', 'pre-dmg', 'dmg-copy', 'installed-dmg'))
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--dmg', type=Path)
    args = parser.parse_args()
    require(args.action == 'verify-pack-copy' or all(value is None for value in (args.copy_context, args.archive, args.dmg)),
        'Copy selectors cannot be ignored by another action')
    if args.action == 'validate-inputs':
        event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        raw = event.get('inputs', {}).get('compiled_app_targets_json', '')
        if raw:
            selected = selectors(raw, event)
            for role, value in selected.items():
                producer(value, role)
    elif args.action == 'prepare-resumed-source':
        require(args.root is not None and args.output is not None, 'Exact signed binding and source destination required')
        prepare_resumed_source(args.root, args.output)
    elif args.action == 'verify-pack':
        require(args.root is not None, 'Exact pack root required')
        verify_pack(args.root)
    elif args.action == 'verify-pack-copy':
        require(args.root is not None and args.copy_context is not None, 'Exact pack copy and caller required')
        verify_pack_copy(args.root, args.copy_context, args.archive, args.dmg)
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
